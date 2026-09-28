import AVFoundation
import Foundation
import UIKit

/// End-to-end check run by CI on the iOS simulator:
///   Nazzel --selftest http://127.0.0.1:8765
/// Prints lines starting with "NAZZEL_SELFTEST:" and exits.
enum SelfTest {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--screens")
    }
    static var isScreens: Bool { CommandLine.arguments.contains("--screens") }
    private static let started = Date()

    static var watchdogFile: URL { Paths.caches.appendingPathComponent("watchdog.txt") }

    private static var baseURL: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(where: { $0 == "--selftest" || $0 == "--screens" }),
              index + 1 < args.count, args[index + 1].hasPrefix("http") else { return nil }
        return args[index + 1]
    }

    static func start() {
        setvbuf(stdout, nil, _IONBF, 0)
        Task { @MainActor in
            if isScreens {
                await runScreens()
            } else {
                await run()
            }
        }
    }

    /// Walks through the main screens so CI can take screenshots of each one.
    @MainActor
    private static func runScreens() async {
        let router = AppRouter.shared
        let player = PlayerController.shared
        func screen(_ name: String, wait: Double = 1.8) async {
            // let animations settle, then the app photographs its own window
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            capture(name)
            out("SCREEN \(name)")
        }
        try? FileManager.default.removeItem(at: screensFolder)
        PythonEngine.shared.bootInBackground(warmUp: false)
        let warm = await PythonEngine.shared.callAsync("warmup")
        EngineStatus.shared.update(with: warm)
        guard let base = baseURL else { exit(1) }

        var audio = await DownloadManager.shared.enqueueAndWait(base + "/dash/manifest.mpd", mode: .audio, timeout: 60)
        if audio?.files.isEmpty ?? true {
            // a freshly booted simulator sometimes times out on its very first local connection
            audio = await DownloadManager.shared.enqueueAndWait(base + "/dash/manifest.mpd", mode: .audio, timeout: 60)
        }
        let video = await DownloadManager.shared.enqueueAndWait(base + "/vertical.mp4", mode: .video, timeout: 60)
        _ = await DownloadManager.shared.enqueueAndWait(base + "/progressive.mp4", mode: .video, timeout: 60)
        _ = await DownloadManager.shared.enqueueAndWait(base + "/photo.jpg", mode: .photos, timeout: 60)

        router.tab = .download
        await screen("1-download")

        if let file = audio?.files.first?.url {
            player.play(file)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await screen("2-minibar")
            player.showFullPlayer = true
            await screen("3-player-audio", wait: 3.5)
            player.showFullPlayer = false
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if let file = video?.files.first?.url {
            player.play(file)
            player.showFullPlayer = true
            await screen("4-player-video", wait: 3.5)
            player.showFullPlayer = false
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        router.tab = .library
        LibraryStore.shared.reload()
        await screen("5-library")
        router.tab = .browse
        await screen("6-browser")
        router.tab = .settings
        await screen("7-settings")
        player.stop()
        out("SCREENS_DONE")
        try? await Task.sleep(nanoseconds: 500_000_000)
        exit(0)
    }

    private static func out(_ text: String) {
        let t = String(format: "%6.1f", Date().timeIntervalSince(started))
        print("NAZZEL_SELFTEST: [\(t)s] " + text)
        fflush(stdout)
    }

    /// Timing breadcrumbs from the download pipeline (only printed during the self-test).
    static func trace(_ text: String) {
        guard isRequested else { return }
        out("trace " + text)
    }

    private static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return String(describing: object) }
        return text
    }

    @MainActor
    private static func run() async {
        var failures: [String] = []
        out("start args=\(CommandLine.arguments.dropFirst().joined(separator: " "))")

        PythonEngine.shared.bootInBackground(warmUp: false)
        let warm = await PythonEngine.shared.callAsync("warmup")
        out("warmup \(json(warm))")
        if warm["ok"] as? Bool != true || warm["yt_dlp"] as? String == nil {
            failures.append("warmup")
        }
        if warm["gallery_dl"] as? String == nil { failures.append("gallery-dl") }
        EngineStatus.shared.update(with: warm)

        let report = await PythonEngine.shared.callAsync("selftest", ["js": true])
        out("engine \(json(report))")
        let checks = report["checks"] as? [String: Any] ?? [:]
        if (checks["https_pypi"] as? String)?.hasPrefix("ok") != true { failures.append("https") }
        if ((checks["extractors"] as? Int) ?? 0) < 500 { failures.append("extractors") }
        if (checks["webkit_js"] as? String) != "ok 42" { failures.append("webkit_js") }

        // Ad-block rules must compile in real WebKit.
        do {
            _ = try await BrowserModel.compileRules()
            out("adblock rules OK")
        } catch {
            out("adblock rules FAIL \(error.localizedDescription)")
            failures.append("adblock-rules")
        }

        var playable: URL?
        var audioFile: URL?
        if let base = baseURL {
            let cases: [(name: String, path: String, mode: DownloadMode, video: Bool, audio: Bool, image: Bool, required: Bool)] = [
                ("progressive", "/progressive.mp4", .video, true, true, false, true),
                ("dash-merge", "/dash/manifest.mpd", .video, true, true, false, true),
                ("dash-audio", "/dash/manifest.mpd", .audio, false, true, false, true),
                ("photo", "/photo.jpg", .photos, false, false, true, true),
                ("hls-ts", "/hls/index.m3u8", .video, true, true, false, true),
            ]
            for test in cases {
                let t0 = Date()
                guard let job = await DownloadManager.shared.enqueueAndWait(base + test.path, mode: test.mode, timeout: 90) else {
                    failures.append(test.name)
                    continue
                }
                var detail: [String: Any] = [
                    "phase": "\(job.phase)", "status": job.status,
                    "error": job.error ?? "", "detail": job.errorDetail ?? "",
                    "seconds": Int(Date().timeIntervalSince(t0)),
                ]
                var ok = job.phase == .done && !job.files.isEmpty
                var fileInfo: [[String: Any]] = []
                for file in job.files {
                    if test.image {
                        let isImage = MediaTools.isImage(file.url) && FileManager.default.fileExists(atPath: file.url.path)
                        fileInfo.append(["name": file.url.lastPathComponent, "image": isImage])
                        if !isImage { ok = false }
                        continue
                    }
                    let hasVideo = await MediaTools.hasTrack(file.url, .video)
                    let hasAudio = await MediaTools.hasTrack(file.url, .audio)
                    let duration = await MediaTools.duration(of: file.url) ?? 0
                    fileInfo.append(["name": file.url.lastPathComponent, "video": hasVideo, "audio": hasAudio,
                                     "duration": duration, "note": file.note ?? ""])
                    if hasVideo != test.video || hasAudio != test.audio || duration < 1 { ok = false }
                    if ok, test.name == "progressive" { playable = file.url }
                    if ok, test.name == "dash-audio" { audioFile = file.url }
                }
                detail["files"] = fileInfo
                if test.name == "hls-ts" { detail["remux"] = TSRemuxer.lastDiagnostics }
                out("download \(test.name) \(ok ? "OK" : "FAIL") \(json(detail))")
                if !ok && test.required { failures.append(test.name) }
                if test.name == "hls-ts", ok, Date().timeIntervalSince(t0) > 10 { failures.append("remux-slow") }
                if Date().timeIntervalSince(t0) > 40 { dumpWatchdog() }
            }

            // Turbo: 12 MB where every connection is capped at 1 MB/s (like real CDNs).
            // One connection would need ~12 s; turbo must finish far faster with an intact file.
            do {
                let t0 = Date()
                let job = await DownloadManager.shared.enqueueAndWait(base + "/slow/big.mp4", mode: .video, timeout: 90)
                let seconds = Date().timeIntervalSince(t0)
                let file = job?.files.first?.url
                let size = file.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
                let intact = job?.phase == .done && size == 12_582_912
                let speed = Double(size) / max(seconds, 0.01) / 1_048_576
                out("download turbo \(intact ? "OK" : "FAIL") size=\(size) seconds=\(String(format: "%.1f", seconds)) speed=\(String(format: "%.1f", speed)) MiB/s status=\(job?.status ?? "-") error=\(job?.errorDetail ?? "-")")
                if !intact { failures.append("turbo") }
                if intact && seconds > 9 { failures.append("turbo-speed") }
                if let file { try? FileManager.default.removeItem(at: file) }
            }

            // Player: plays a downloaded file (informational — CI machines may have no audio device).
            if let playable {
                PlayerController.shared.play(playable)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let t = PlayerController.shared.currentTime
                out("player \(t > 0.3 ? "OK" : "WARN") time=\(String(format: "%.2f", t)) duration=\(PlayerController.shared.duration) title=\(PlayerController.shared.title)")
                // What tapping the mini bar does: open the full player, seek, skip, close. Must not crash.
                PlayerController.shared.showFullPlayer = true
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                PlayerController.shared.skip(by: PlayerController.skipSeconds)
                PlayerController.shared.seek(to: 1)
                PlayerController.shared.skip(by: -PlayerController.skipSeconds)
                try? await Task.sleep(nanoseconds: 800_000_000)
                PlayerController.shared.showFullPlayer = false
                try? await Task.sleep(nanoseconds: 800_000_000)
                out("full player OK (opened, skipped, closed)")
                PlayerController.shared.stop()
            }
            if let audioFile {
                PlayerController.shared.play(audioFile)
                PlayerController.shared.showFullPlayer = true
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                PlayerController.shared.skip(by: PlayerController.skipSeconds)
                PlayerController.shared.showFullPlayer = false
                try? await Task.sleep(nanoseconds: 800_000_000)
                out("full player (audio) OK")
                PlayerController.shared.stop()
            }

            // Browser: user scripts + message bridge in real WebKit (informational).
            let browser = BrowserModel.shared
            if let page = URL(string: base + "/page.html") {
                browser.open(page)
                var reported = false
                for _ in 0..<50 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    if browser.lastReportedPage?.contains("page.html") == true { reported = true; break }
                }
                out("browser bridge \(reported ? "OK" : "WARN") page=\(browser.lastReportedPage ?? "-")")
            }
        }

        // Real-world probe (informational only: CI machines are often blocked by video sites).
        if CommandLine.arguments.contains("--online") {
            let job = await DownloadManager.shared.enqueueAndWait(
                "https://www.youtube.com/watch?v=jNQXAC9IVRw", mode: .video, quality: .q480, timeout: 180)
            out("online youtube phase=\(String(describing: job?.phase)) status=\(job?.status ?? "-") error=\(job?.error ?? "-") detail=\(job?.errorDetail ?? "-") files=\(job?.files.map { $0.url.lastPathComponent } ?? [])")
        }

        let log = await PythonEngine.shared.callAsync("log", ["lines": 80])
        for line in (log["log"] as? [String] ?? []) { out("log \(line)") }
        if !failures.isEmpty { dumpWatchdog() }

        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        if failures.isEmpty {
            out("RESULT PASS in \(seconds)s")
            exit(0)
        } else {
            out("RESULT FAIL \(failures.joined(separator: ",")) in \(seconds)s")
            exit(1)
        }
    }

    static var screensFolder: URL { Paths.caches.appendingPathComponent("screens", isDirectory: true) }

    /// Renders the whole window (including an open sheet) to a PNG.
    @MainActor
    private static func capture(_ name: String) {
        try? FileManager.default.createDirectory(at: screensFolder, withIntermediateDirectories: true)
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else {
            out("capture \(name): no window")
            return
        }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        do {
            try image.pngData()?.write(to: screensFolder.appendingPathComponent("\(name).png"))
        } catch {
            out("capture \(name) failed: \(error)")
        }
    }

    /// Python thread stacks written by faulthandler (shows what a slow step was doing).
    private static func dumpWatchdog() {
        guard let text = try? String(contentsOf: watchdogFile, encoding: .utf8), !text.isEmpty else { return }
        for line in text.split(separator: "\n").suffix(80) { out("stack \(line)") }
    }
}

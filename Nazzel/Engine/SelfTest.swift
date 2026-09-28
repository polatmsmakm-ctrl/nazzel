import AVFoundation
import Foundation

/// End-to-end check run by CI on the iOS simulator:
///   Nazzel --selftest http://127.0.0.1:8765
/// Prints lines starting with "NAZZEL_SELFTEST:" and exits.
enum SelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("--selftest") }
    private static let started = Date()

    static var watchdogFile: URL { Paths.caches.appendingPathComponent("watchdog.txt") }

    private static var baseURL: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--selftest"), index + 1 < args.count,
              args[index + 1].hasPrefix("http") else { return nil }
        return args[index + 1]
    }

    static func start() {
        setvbuf(stdout, nil, _IONBF, 0)
        Task { @MainActor in
            await run()
        }
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
        if let base = baseURL {
            let cases: [(name: String, path: String, mode: DownloadMode, video: Bool, audio: Bool, image: Bool, required: Bool)] = [
                ("progressive", "/progressive.mp4", .video, true, true, false, true),
                ("dash-merge", "/dash/manifest.mpd", .video, true, true, false, true),
                ("dash-audio", "/dash/manifest.mpd", .audio, false, true, false, true),
                ("photo", "/photo.jpg", .photos, false, false, true, true),
                ("hls-ts", "/hls/index.m3u8", .video, true, true, false, false),
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
                }
                detail["files"] = fileInfo
                if test.name == "hls-ts" { detail["remux"] = TSRemuxer.lastDiagnostics }
                out("download \(test.name) \(ok ? "OK" : "FAIL") \(json(detail))")
                if !ok && test.required { failures.append(test.name) }
                if Date().timeIntervalSince(t0) > 40 { dumpWatchdog() }
            }

            // Player: plays a downloaded file (informational — CI machines may have no audio device).
            if let playable {
                PlayerController.shared.play(playable)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let t = PlayerController.shared.currentTime
                out("player \(t > 0.3 ? "OK" : "WARN") time=\(String(format: "%.2f", t)) duration=\(PlayerController.shared.duration) title=\(PlayerController.shared.title)")
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

    /// Python thread stacks written by faulthandler (shows what a slow step was doing).
    private static func dumpWatchdog() {
        guard let text = try? String(contentsOf: watchdogFile, encoding: .utf8), !text.isEmpty else { return }
        for line in text.split(separator: "\n").suffix(80) { out("stack \(line)") }
    }
}

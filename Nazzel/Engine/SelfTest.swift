import ActivityKit
import AVFoundation
import Foundation
import UIKit
import WebKit

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

        let video = await DownloadManager.shared.enqueueAndWait(base + "/vertical.mp4", mode: .video, timeout: 60)
        _ = await DownloadManager.shared.enqueueAndWait(base + "/progressive.mp4", mode: .video, timeout: 60)
        let subbed = await DownloadManager.shared.enqueueAndWait(base + "/subs/subs.mpd", mode: .video, timeout: 60)
        _ = await DownloadManager.shared.enqueueAndWait(base + "/photo.jpg", mode: .photos, timeout: 60)
        var audio: DownloadJob?
        for _ in 0..<3 where audio?.files.isEmpty ?? true {
            // a freshly booted simulator sometimes times out on its first local connections
            audio = await DownloadManager.shared.enqueueAndWait(base + "/dash/manifest.mpd", mode: .audio, timeout: 60)
        }

        router.tab = .download
        await screen("1-download")
        router.showQualityPicker = true
        await screen("1b-quality", wait: 2.2)
        router.showQualityPicker = false
        try? await Task.sleep(nanoseconds: 900_000_000)
        router.collection = CollectionRequest(url: base + "/feed.rss", mode: .video, quality: .best)
        await screen("1c-playlist", wait: 3.5)
        router.collection = nil
        try? await Task.sleep(nanoseconds: 900_000_000)

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
        if let file = subbed?.files.first?.url {
            player.play(file)
            player.showFullPlayer = true
            player.seek(to: 0.3)
            await screen("4b-player-subtitles", wait: 2.0)
            player.enterFullscreen()
            player.pause()
            await screen("4c-fullscreen", wait: 3.0)
            player.exitFullscreen()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            player.showFullPlayer = false
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        router.tab = .library
        LibraryStore.shared.createFolder(named: "مقاطع مفضلة")
        LibraryStore.shared.reload()
        await screen("5-library")
        if let item = LibraryStore.shared.items.first(where: { $0.isVideo && $0.canPlay }) {
            router.trimItem = item
            await screen("5b-trim", wait: 2.8)
            router.trimItem = nil
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
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

            await featureTests(base: base, playable: playable, failures: &failures)

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

        // Watching YouTube in the in-app browser (informational: YouTube may refuse CI machines).
        if CommandLine.arguments.contains("--youtube") {
            await youtubeProbe()
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

    /// Plays a long YouTube video in the in-app browser with the ad blocker on, then off,
    /// and samples the page's <video> every 2 seconds: is the clock moving, is it buffering,
    /// did an ad show, and what did our scripts do about it.
    @MainActor
    private static func youtubeProbe() async {
        let browser = BrowserModel.shared
        let router = AppRouter.shared
        let video = "0e3GPea1Tyg"   // 25 minutes, monetised (mid-roll ads)
        let original = UserDefaults.standard.object(forKey: "adblock") as? Bool ?? true
        router.tab = .browse
        let sampleJS = """
        const v = document.querySelector('video');
        const p = document.querySelector('.html5-video-player');
        if (v && !v.__nzProbe) {
          v.__nzProbe = true; window.__nzWaits = 0; window.__nzErrors = 0;
          v.addEventListener('waiting', () => { window.__nzWaits++; });
          v.addEventListener('error', () => { window.__nzErrors++; });
        }
        if (v && kick && v.paused && !v.ended) { v.muted = true; try { v.play().catch(() => {}); } catch (e) {} }
        let buffered = 0;
        try { if (v && v.buffered.length) buffered = v.buffered.end(v.buffered.length - 1); } catch (e) {}
        const cls = p ? p.className.split(' ').filter(c => /^(ad-|playing|paused|buffering|ended|unstarted)/.test(c)).join(',') : '';
        const log = window.__nazzelAdLog || [];
        return JSON.stringify({
          t: v ? Math.round(v.currentTime * 10) / 10 : -1, d: v ? Math.round(v.duration) : -1,
          paused: v ? v.paused : null, rs: v ? v.readyState : -1, buf: Math.round(buffered),
          cls: cls, waits: window.__nzWaits || 0, errors: window.__nzErrors || 0,
          pruned: window.__nazzelStats ? window.__nazzelStats.pruned : -1,
          enforcement: document.querySelector('ytm-enforcement-message-view-model, ytd-enforcement-message-view-model') ? 1 : 0,
          ad: log.slice(-3).join(' | '), title: document.title.slice(0, 50), path: location.pathname
        });
        """

        for adblockOn in [true, false] {
            UserDefaults.standard.set(adblockOn, forKey: "adblock")
            browser.applySettings()
            if adblockOn { _ = try? await BrowserModel.compileRules() }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let url = URL(string: "https://m.youtube.com/watch?v=\(video)") else { return }
            browser.open(url)
            // wait for YouTube's page (and its <video>) to be there
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let ready = await evaluate(browser.webView,
                    "return location.hostname + '|' + (document.querySelector('video') ? 1 : 0);", [:], timeout: 3)
                if ready?.hasSuffix("youtube.com|1") == true { break }
            }
            var samples: [[String: Any]] = []
            let started = Date()
            for i in 0..<25 {
                // never let a page that stops answering hang the whole test
                let text = await evaluate(browser.webView, sampleJS, ["kick": i < 3], timeout: 4) ?? "{\"timeout\":1}"
                let sample = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
                samples.append(sample)
                out("youtube adblock=\(adblockOn ? "on" : "off") +\(Int(Date().timeIntervalSince(started)))s \(text)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            // summary: how far did the video get, and how often did the clock stop while playing
            let times = samples.compactMap { $0["t"] as? Double }.filter { $0 >= 0 }
            var frozen = 0
            for (a, b) in zip(samples, samples.dropFirst()) {
                if let t1 = a["t"] as? Double, let t2 = b["t"] as? Double, t1 >= 0,
                   (b["paused"] as? Bool) == false, t2 - t1 < 0.5 {
                    frozen += 1
                }
            }
            let advanced = (times.last ?? 0) - (times.first ?? 0)
            out("youtube SUMMARY adblock=\(adblockOn ? "on" : "off") advanced=\(String(format: "%.1f", advanced))s "
                + "over=\(Int(Date().timeIntervalSince(started)))s frozenSamples=\(frozen) "
                + "waits=\(samples.last?["waits"] ?? "-") title=\(samples.last?["title"] ?? "-")")
            capture("yt-adblock-\(adblockOn ? "on" : "off")")
        }
        UserDefaults.standard.set(original, forKey: "adblock")
        browser.applySettings()
    }

    /// Runs JavaScript in the page and gives up after `timeout` seconds.
    @MainActor
    private static func evaluate(_ web: WKWebView, _ body: String, _ args: [String: Any], timeout: Double) async -> String? {
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            web.callAsyncJavaScript(body, arguments: args, in: nil, in: .page) { result in
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: (try? result.get()) as? String)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: nil)
            }
        }
    }

    /// Play without downloading, playlists, subtitles, cutting, ringtones, folders, fullscreen.
    @MainActor
    private static func featureTests(base: String, playable: URL?, failures: inout [String]) async {
        let player = PlayerController.shared

        // 1. streams: one file, HLS, and separate picture + sound joined on the fly
        for (name, path, audioOnly) in [("file", "/progressive.mp4", false), ("hls", "/hls/index.m3u8", false),
                                        ("pair", "/pair/pair.mpd", false), ("audio", "/pair/pair.mpd", true)] {
            let error = await StreamLauncher.play(base + path, audioOnly: audioOnly, openPlayer: false)
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            let t = player.currentTime
            let ok = error == nil && player.isStream && t > 0.4
            out("stream \(name) \(ok ? "OK" : "FAIL") time=\(String(format: "%.2f", t)) video=\(player.hasVideo) error=\(error ?? "-")")
            if !ok { failures.append("stream-\(name)") }
            player.stop()
        }

        // 2. playlist / feed listing
        let list = await PythonEngine.shared.callAsync("list", ["url": base + "/feed.rss"])
        let count = (list["entries"] as? [Any])?.count ?? 0
        out("list \(count == 3 ? "OK" : "FAIL") entries=\(count) title=\(list["title"] ?? "-") error=\(list["error"] ?? "-")")
        if count != 3 { failures.append("list") }
        out("link kinds collection=\(LinkKinds.isCollection("https://www.youtube.com/@name")) "
            + "\(LinkKinds.isCollection("https://www.youtube.com/playlist?list=PL1")) "
            + "video=\(LinkKinds.isCollection("https://www.youtube.com/watch?v=abc")) "
            + "inside=\(LinkKinds.playlistInsideVideo("https://www.youtube.com/watch?v=a&list=PLx") ?? "-") "
            + "handle=\(LinkKinds.instagramHandle("@some.user") ?? "-") time=\(LinkKinds.parseTime("١:٣٠") ?? -1)")

        // 3. subtitles come down with the video and show in the player
        if let job = await DownloadManager.shared.enqueueAndWait(base + "/subs/subs.mpd", mode: .video, timeout: 90),
           let file = job.files.first?.url {
            let tracks = Subtitles.sidecars(for: file)
            let cues = tracks.first.map { Subtitles.load($0.url) } ?? []
            player.play(file)
            try? await Task.sleep(nanoseconds: 900_000_000)
            let shown = player.subtitleText ?? ""
            let ok = tracks.count == 2 && cues.count == 2 && !shown.isEmpty
            out("subtitles \(ok ? "OK" : "FAIL") tracks=\(tracks.map(\.lang)) cues=\(cues.count) shown=\(shown)")
            if !ok { failures.append("subtitles") }
            player.stop()
        } else {
            out("subtitles FAIL download")
            failures.append("subtitles")
        }

        // 4. cutting, ringtone, and "download only a part"
        if let playable {
            let cut = Paths.work.appendingPathComponent("cut-test.mp4")
            let trimmed = try? await MediaTools.trim(playable, from: 0.5, to: 2.0, output: cut)
            var length = 0.0
            if let trimmed { length = await MediaTools.duration(of: trimmed) ?? 0 }
            let ok = abs(length - 1.5) < 0.6
            out("trim \(ok ? "OK" : "FAIL") length=\(String(format: "%.2f", length))")
            if !ok { failures.append("trim") }

            let tone = try? await MediaTools.ringtone(playable, from: 0, seconds: 2,
                                                       output: Paths.work.appendingPathComponent("tone-test.m4r"))
            var toneLength = 0.0
            if let tone { toneLength = await MediaTools.duration(of: tone) ?? 0 }
            let toneOK = tone?.pathExtension == "m4r" && toneLength > 1
            out("ringtone \(toneOK ? "OK" : "FAIL") length=\(String(format: "%.2f", toneLength))")
            if !toneOK { failures.append("ringtone") }
        }
        let clipJob = DownloadManager.shared.enqueue(base + "/vertical.mp4?clip=1", mode: .video,
                                                     quality: .best, clip: 1.0...2.5)
        while clipJob?.isActive == true { try? await Task.sleep(nanoseconds: 200_000_000) }
        let clipFile = clipJob?.files.first?.url
        var clipLength = 0.0
        if let clipFile { clipLength = await MediaTools.duration(of: clipFile) ?? 0 }
        let clipOK = abs(clipLength - 1.5) < 0.7
        out("clip download \(clipOK ? "OK" : "FAIL") length=\(String(format: "%.2f", clipLength)) file=\(clipFile?.lastPathComponent ?? "-")")
        if !clipOK { failures.append("clip") }

        // 5. folders
        let store = LibraryStore.shared
        store.reload()
        if let folder = store.createFolder(named: "اختبار"), let item = store.items.first(where: \.isVideo) {
            let moved = store.move(item, to: folder)
            let inside = store.contents(of: folder).items.contains { $0.url.lastPathComponent == moved?.lastPathComponent }
            out("folders \(inside ? "OK" : "FAIL") folder=\(folder.lastPathComponent)")
            if !inside { failures.append("folders") }
        } else {
            out("folders FAIL create")
            failures.append("folders")
        }

        // 6. fullscreen player opens and closes without trouble
        if let playable {
            player.play(playable)
            player.showFullPlayer = true
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            player.enterFullscreen()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            player.skip(by: 1)
            player.exitFullscreen()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            player.showFullPlayer = false
            try? await Task.sleep(nanoseconds: 800_000_000)
            out("fullscreen OK (entered, left, closed) mask=\(OrientationLock.mask.rawValue)")
            player.stop()
        }

        // 7. the Shortcuts / Siri action, and the Lock Screen progress it shows
        if #available(iOS 17.0, *) {
            let before = DownloadManager.shared.jobs.count
            let intent = DownloadLinkIntent(link: base + "/slow/big.mp4?intent=1", kind: .video)
            _ = try? await intent.perform()
            let job = DownloadManager.shared.jobs.first
            let added = DownloadManager.shared.jobs.count > before
            var liveSeen = 0
            while job?.isActive == true {
                liveSeen = max(liveSeen, Activity<DownloadActivityAttributes>.activities.count)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let ok = added && job?.phase == .done
            out("shortcut action \(ok ? "OK" : "FAIL") phase=\(job.map { "\($0.phase)" } ?? "-") "
                + "liveActivity=\(liveSeen) enabled=\(ActivityAuthorizationInfo().areActivitiesEnabled)")
            if !ok { failures.append("shortcut") }
            if let file = job?.files.first?.url { try? FileManager.default.removeItem(at: file) }
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

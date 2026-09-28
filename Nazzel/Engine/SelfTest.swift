import AVFoundation
import Foundation

/// End-to-end check run by CI on the iOS simulator:
///   Nazzel --selftest http://127.0.0.1:8765
/// Prints lines starting with "NAZZEL_SELFTEST:" and exits.
enum SelfTest {
    static var isRequested: Bool { CommandLine.arguments.contains("--selftest") }

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
        print("NAZZEL_SELFTEST: " + text)
        fflush(stdout)
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
        let started = Date()
        out("start args=\(CommandLine.arguments.dropFirst().joined(separator: " "))")

        PythonEngine.shared.bootInBackground(warmUp: false)
        let warm = await PythonEngine.shared.callAsync("warmup")
        out("warmup \(json(warm)) in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        if warm["ok"] as? Bool != true || warm["yt_dlp"] as? String == nil {
            failures.append("warmup")
        }
        EngineStatus.shared.update(with: warm)

        let report = await PythonEngine.shared.callAsync("selftest", ["js": true])
        out("engine \(json(report))")
        let checks = report["checks"] as? [String: Any] ?? [:]
        if (checks["https_pypi"] as? String)?.hasPrefix("ok") != true { failures.append("https") }
        if ((checks["extractors"] as? Int) ?? 0) < 500 { failures.append("extractors") }
        if (checks["webkit_js"] as? String) != "ok 42" { failures.append("webkit_js") }

        if let base = baseURL {
            let cases: [(name: String, path: String, mode: DownloadMode, video: Bool, audio: Bool, required: Bool)] = [
                ("progressive", "/progressive.mp4", .video, true, true, true),
                ("dash-merge", "/dash/manifest.mpd", .video, true, true, true),
                ("dash-audio", "/dash/manifest.mpd", .audio, false, true, true),
                ("hls-ts", "/hls/index.m3u8", .video, true, true, false),
            ]
            for test in cases {
                let t0 = Date()
                guard let job = await DownloadManager.shared.enqueueAndWait(base + test.path, mode: test.mode, timeout: 120) else {
                    failures.append(test.name)
                    continue
                }
                var detail: [String: Any] = [
                    "phase": "\(job.phase)", "status": job.status,
                    "error": job.error ?? "", "seconds": Int(Date().timeIntervalSince(t0)),
                ]
                var ok = job.phase == .done && !job.files.isEmpty
                var fileInfo: [[String: Any]] = []
                for file in job.files {
                    let hasVideo = await MediaTools.hasTrack(file.url, .video)
                    let hasAudio = await MediaTools.hasTrack(file.url, .audio)
                    let duration = await MediaTools.duration(of: file.url) ?? 0
                    fileInfo.append(["name": file.url.lastPathComponent, "video": hasVideo, "audio": hasAudio,
                                     "duration": duration, "note": file.note ?? ""])
                    if hasVideo != test.video || hasAudio != test.audio || duration < 1 { ok = false }
                    try? FileManager.default.removeItem(at: file.url)
                }
                detail["files"] = fileInfo
                out("download \(test.name) \(ok ? "OK" : "FAIL") \(json(detail))")
                if !ok && test.required { failures.append(test.name) }
            }
        }

        // Real-world probe (informational only: CI machines are often blocked by video sites).
        if CommandLine.arguments.contains("--online") {
            let job = await DownloadManager.shared.enqueueAndWait(
                "https://www.youtube.com/watch?v=jNQXAC9IVRw", mode: .video, quality: .q480, timeout: 180)
            out("online youtube phase=\(String(describing: job?.phase)) status=\(job?.status ?? "-") error=\(job?.error ?? "-") detail=\(job?.errorDetail ?? "-") files=\(job?.files.map { $0.url.lastPathComponent } ?? [])")
        }

        let log = await PythonEngine.shared.callAsync("log", ["lines": 60])
        for line in (log["log"] as? [String] ?? []) { out("log \(line)") }

        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        if failures.isEmpty {
            out("RESULT PASS in \(seconds)s")
            exit(0)
        } else {
            out("RESULT FAIL \(failures.joined(separator: ",")) in \(seconds)s")
            exit(1)
        }
    }
}

import Foundation
import SwiftUI
import UIKit

enum DownloadMode: String, CaseIterable, Identifiable {
    case video
    case audio

    var id: String { rawValue }
    var title: String { self == .video ? "فيديو" : "صوت فقط" }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case best
    case q1080 = "1080"
    case q720 = "720"
    case q480 = "480"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .best: return "أعلى جودة"
        case .q1080: return "1080p"
        case .q720: return "720p"
        case .q480: return "480p (أخف)"
        }
    }
}

struct DownloadedFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var savedToPhotos = false
    var note: String?
}

@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case queued, preparing, downloading, processing, done, failed, cancelled
    }

    let id: String
    let url: String
    let mode: DownloadMode
    let quality: VideoQuality
    let created = Date()

    @Published var phase: Phase = .queued
    @Published var title: String?
    @Published var uploader: String?
    @Published var thumbnail: URL?
    @Published var fraction: Double?
    @Published var status: String = "في الانتظار"
    @Published var error: String?
    @Published var errorDetail: String?
    @Published var files: [DownloadedFile] = []
    @Published var warnings: [String] = []

    var cancelRequested = false

    init(url: String, mode: DownloadMode, quality: VideoQuality) {
        self.id = UUID().uuidString
        self.url = url
        self.mode = mode
        self.quality = quality
    }

    var isActive: Bool { [.queued, .preparing, .downloading, .processing].contains(phase) }
    var isFinished: Bool { !isActive }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
    }
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var jobs: [DownloadJob] = []
    /// Set when a link arrives from outside (nazzel:// URL, Shortcuts).
    @Published var incomingLink: String?
    @Published var incomingToken = 0

    private var runningJob: DownloadJob?

    var autoSaveToPhotos: Bool {
        if SelfTest.isRequested { return false }
        return UserDefaults.standard.object(forKey: "autoSaveToPhotos") as? Bool ?? true
    }

    // MARK: - Queue

    @discardableResult
    func enqueue(_ text: String, mode: DownloadMode, quality: VideoQuality) -> DownloadJob? {
        guard let link = Self.extractURL(from: text) else { return nil }
        let job = DownloadJob(url: link, mode: mode, quality: quality)
        jobs.insert(job, at: 0)
        pump()
        return job
    }

    func cancel(_ job: DownloadJob) {
        job.cancelRequested = true
        if job.phase == .queued {
            job.phase = .cancelled
            job.status = "تم الإلغاء"
            return
        }
        job.status = "جاري الإلغاء…"
        let jobID = job.id
        Task.detached { _ = await PythonEngine.shared.callAsync("cancel", ["job": jobID]) }
    }

    func retry(_ job: DownloadJob) {
        remove(job)
        enqueue(job.url, mode: job.mode, quality: job.quality)
    }

    func remove(_ job: DownloadJob) {
        if job.isActive { cancel(job) }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        jobs.removeAll { $0.isFinished }
    }

    func handleIncoming(_ url: URL) {
        // nazzel://download?url=<link>  or  nazzel://<link>
        var link: String?
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            link = components.queryItems?.first(where: { $0.name == "url" || $0.name == "link" })?.value
        }
        if link == nil {
            let raw = url.absoluteString.replacingOccurrences(of: "nazzel://", with: "")
            link = Self.extractURL(from: raw.removingPercentEncoding ?? raw)
        }
        guard let link, Self.extractURL(from: link) != nil else { return }
        incomingLink = link
        incomingToken += 1
        let autoStart = UserDefaults.standard.object(forKey: "autoStartShared") as? Bool ?? true
        if autoStart {
            let mode = DownloadMode(rawValue: UserDefaults.standard.string(forKey: "defaultMode") ?? "") ?? .video
            let quality = VideoQuality(rawValue: UserDefaults.standard.string(forKey: "defaultQuality") ?? "") ?? .best
            enqueue(link, mode: mode, quality: quality)
            incomingLink = nil
        }
    }

    private func pump() {
        guard runningJob == nil,
              let next = jobs.last(where: { $0.phase == .queued }) else { return }
        runningJob = next
        Task {
            await run(next)
            runningJob = nil
            pump()
        }
    }

    // MARK: - One download

    private func run(_ job: DownloadJob) async {
        job.phase = .preparing
        job.status = "جاري قراءة الرابط…"
        job.error = nil
        job.errorDetail = nil

        let workdir = Paths.work.appendingPathComponent(job.id, isDirectory: true)
        try? FileManager.default.removeItem(at: workdir)
        try? FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)

        await CookieStore.exportForEngine()

        let activity = BackgroundActivity()
        activity.begin()
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            activity.end()
        }

        let jobID = job.id
        let poller = Task { [weak self] in
            while !Task.isCancelled {
                let progress = await PythonEngine.shared.callAsync("progress", ["job": jobID])
                if Task.isCancelled { break }
                self?.apply(progress, to: job)
                try? await Task.sleep(nanoseconds: 350_000_000)
            }
        }

        let args: [String: Any] = [
            "job": job.id,
            "url": job.url,
            "mode": job.mode.rawValue,
            "quality": job.quality.rawValue,
            "workdir": workdir.path,
            "cookies": Paths.cookies.path,
        ]
        let result = await PythonEngine.shared.callAsync("download", args)
        poller.cancel()

        if result["cancelled"] as? Bool == true || job.cancelRequested {
            job.phase = .cancelled
            job.status = "تم الإلغاء"
            job.fraction = nil
        } else if result["ok"] as? Bool != true {
            job.phase = .failed
            job.error = result["error"] as? String ?? "صار خطأ غير متوقع"
            job.errorDetail = result["detail"] as? String
            job.status = "فشل التحميل"
            job.fraction = nil
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        } else {
            if let title = result["title"] as? String, !title.isEmpty { job.title = title }
            job.warnings = result["warnings"] as? [String] ?? []
            await finish(job, items: result["items"] as? [[String: Any]] ?? [])
        }

        try? FileManager.default.removeItem(at: workdir)
        _ = await PythonEngine.shared.callAsync("forget", ["job": job.id])
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
    }

    private func apply(_ progress: [String: Any], to job: DownloadJob) {
        guard job.isActive, !job.cancelRequested else { return }
        if let title = progress["title"] as? String, !title.isEmpty { job.title = title }
        if let uploader = progress["uploader"] as? String { job.uploader = uploader }
        if job.thumbnail == nil, let thumb = progress["thumbnail"] as? String { job.thumbnail = URL(string: thumb) }

        switch progress["status"] as? String {
        case "extracting":
            job.phase = .preparing
            job.status = "جاري قراءة الرابط…"
        case "downloading":
            job.phase = .downloading
            let done = (progress["downloaded"] as? NSNumber)?.doubleValue ?? 0
            let total = (progress["total"] as? NSNumber)?.doubleValue
            if let total, total > 0 { job.fraction = min(1, done / total) }
            var parts: [String] = []
            switch progress["stage"] as? String {
            case "video": parts.append("الفيديو")
            case "audio": parts.append("الصوت")
            default: break
            }
            if let count = progress["item_count"] as? Int, count > 1, let index = progress["item_index"] as? Int {
                parts.append("\(index)/\(count)")
            }
            if let fraction = job.fraction { parts.append(Formatters.percent(fraction)) }
            if let speed = (progress["speed"] as? NSNumber)?.doubleValue, speed > 0 {
                parts.append(Formatters.bytes(speed) + "/ث")
            }
            if let total, total > 0 { parts.append(Formatters.bytes(total)) }
            job.status = parts.isEmpty ? "جاري التحميل…" : "جاري التحميل · " + parts.joined(separator: " · ")
        case "finishing":
            job.status = "جاري الإنهاء…"
        default:
            break
        }
    }

    private func finish(_ job: DownloadJob, items: [[String: Any]]) async {
        job.phase = .processing
        job.fraction = nil
        job.status = "جاري تجهيز الملف…"

        var results: [DownloadedFile] = []
        for item in items {
            for var file in await finalize(item, mode: job.mode) {
                let destination = Paths.uniqueDestination(for: file.url.lastPathComponent, in: Paths.downloads)
                do {
                    try FileManager.default.moveItem(at: file.url, to: destination)
                } catch {
                    continue
                }
                let moved = destination
                file = DownloadedFile(url: moved, savedToPhotos: false, note: file.note)
                if autoSaveToPhotos, job.mode == .video, PhotoSaver.canSave(moved) {
                    job.status = "جاري الحفظ في الصور…"
                    do {
                        try await PhotoSaver.save(moved)
                        file.savedToPhotos = true
                    } catch {
                        file.note = file.note ?? error.localizedDescription
                    }
                }
                results.append(file)
            }
        }

        job.files = results
        if results.isEmpty {
            job.phase = .failed
            job.error = "تم التحميل بس ما قدرت أجهز الملف"
            job.status = "فشل"
        } else {
            job.phase = .done
            let saved = results.filter(\.savedToPhotos).count
            if saved > 0 {
                job.status = saved == results.count ? "تم ✓ محفوظ في الصور" : "تم ✓"
            } else {
                job.status = "تم ✓ موجود في الملفات"
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    /// Turns what yt-dlp downloaded into files iOS can play and save.
    private func finalize(_ item: [String: Any], mode: DownloadMode) async -> [DownloadedFile] {
        let kind = item["kind"] as? String
        if kind == "merge",
           let videoPath = item["video"] as? String,
           let audioPath = item["audio"] as? String {
            let video = URL(fileURLWithPath: videoPath)
            let audio = URL(fileURLWithPath: audioPath)
            let output = URL(fileURLWithPath: item["output"] as? String ?? videoPath + ".merged.mp4")
            do {
                let merged = try await MediaTools.merge(video: video, audio: audio, output: output)
                return [DownloadedFile(url: merged)]
            } catch {
                // Keep both parts rather than losing the download.
                return [
                    DownloadedFile(url: video, note: "تعذر دمج الصوت مع الفيديو (\(error.localizedDescription))"),
                    DownloadedFile(url: audio, note: "ملف الصوت"),
                ]
            }
        }

        guard let path = item["path"] as? String else { return [] }
        let url = URL(fileURLWithPath: path)

        if mode == .audio, MediaTools.isVideo(url) || url.pathExtension.lowercased() == "mp4" {
            if await MediaTools.hasTrack(url, .video) {
                let output = url.deletingPathExtension().appendingPathExtension("m4a")
                if let audio = try? await MediaTools.extractAudio(url, output: output) {
                    try? FileManager.default.removeItem(at: url)
                    return [DownloadedFile(url: audio)]
                }
            } else if url.pathExtension.lowercased() == "mp4" {
                // audio-only MP4: give it the extension players expect
                let renamed = url.deletingPathExtension().appendingPathExtension("m4a")
                if (try? FileManager.default.moveItem(at: url, to: renamed)) != nil {
                    return [DownloadedFile(url: renamed)]
                }
            }
        }

        if item["container"] as? String == "mpegts" {
            let output = url.deletingPathExtension().appendingPathExtension("mp4")
            if let mp4 = try? await MediaTools.remux(url, output: output) {
                try? FileManager.default.removeItem(at: url)
                return [DownloadedFile(url: mp4)]
            }
            return [DownloadedFile(url: url, note: "الملف بصيغة TS: شغّله من تطبيق الملفات أو VLC")]
        }

        return [DownloadedFile(url: url)]
    }

    // MARK: - Helpers

    /// Finds the first web link in pasted text ("Check this out https://vt.tiktok.com/…").
    static func extractURL(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            for match in detector.matches(in: trimmed, options: [], range: range) {
                if let url = match.url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                    return url.absoluteString
                }
            }
        }
        if !trimmed.contains(" "), trimmed.contains("."), let url = URL(string: "https://" + trimmed), url.host != nil {
            return url.absoluteString
        }
        return nil
    }

    /// Used by the self-test.
    func enqueueAndWait(_ link: String, mode: DownloadMode, quality: VideoQuality = .best,
                        timeout: TimeInterval = 300) async -> DownloadJob? {
        guard let job = enqueue(link, mode: mode, quality: quality) else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while job.isActive {
            if Date() > deadline, !job.cancelRequested { cancel(job) }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return job
    }
}

/// Keeps a download alive for a short while if the user switches apps.
@MainActor
final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin() {
        end()
        identifier = UIApplication.shared.beginBackgroundTask(withName: "nazzel-download", expirationHandler: { [weak self] in
            self?.end()
        })
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

extension Notification.Name {
    static let libraryChanged = Notification.Name("NazzelLibraryChanged")
}

enum Formatters {
    static func bytes(_ value: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: Int64(value))
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))٪"
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

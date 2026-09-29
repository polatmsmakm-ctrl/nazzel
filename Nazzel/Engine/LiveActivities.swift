import ActivityKit
import Foundation
import UIKit

/// Keeps one Live Activity (Lock Screen + Dynamic Island) in step with the downloads.
@MainActor
final class DownloadActivityController {
    static let shared = DownloadActivityController()

    private var activityID: String?
    private var lastPush = Date.distantPast
    private var lastSignature = ""
    private var finishedInRun = 0
    private var pendingTask: Task<Void, Never>?

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "liveActivity") as? Bool ?? true
    }

    /// Ends activities left over from an earlier launch (the app may have been closed mid-download).
    func cleanUpOnLaunch() {
        guard #available(iOS 16.2, *) else { return }
        Task {
            for activity in Activity<DownloadActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Call whenever a download starts, moves or finishes.
    func refresh(jobs: [DownloadJob]) {
        guard #available(iOS 16.2, *), isEnabled else { return }
        let active = jobs.filter(\.isActive)
        if active.isEmpty {
            finish(jobs: jobs)
            return
        }
        // the oldest running download is the one on screen
        let job = active.last(where: { $0.phase == .downloading || $0.phase == .processing }) ?? active.last!
        let state = DownloadActivityAttributes.ContentState(
            title: job.displayTitle,
            fraction: job.phase == .downloading ? job.fraction : (job.phase == .processing ? 1 : nil),
            detail: Self.shortDetail(job),
            active: active.count,
            finished: false)
        let signature = "\(state.title)|\(Int(((state.fraction ?? -0.01) * 100).rounded()))|\(state.active)|\(job.phase)"
        guard signature != lastSignature else { return }
        // ActivityKit wants calm updates: at most about one a second
        if Date().timeIntervalSince(lastPush) < 1, activityID != nil {
            schedule(jobs: jobs)
            return
        }
        lastSignature = signature
        lastPush = Date()
        push(state)
    }

    // MARK: - Private

    @available(iOS 16.2, *)
    private var current: Activity<DownloadActivityAttributes>? {
        guard let activityID else { return nil }
        return Activity<DownloadActivityAttributes>.activities.first { $0.id == activityID }
    }

    @available(iOS 16.2, *)
    private func push(_ state: DownloadActivityAttributes.ContentState) {
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
        if let activity = current {
            Task { await activity.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            let activity = try Activity.request(attributes: DownloadActivityAttributes(), content: content, pushType: nil)
            activityID = activity.id
            finishedInRun = 0
        } catch {
            // e.g. the app is in the background and was not started by a Shortcut: fine, no Live Activity
            SelfTest.trace("live activity not started: \(error.localizedDescription)")
        }
    }

    private func schedule(jobs: [DownloadJob]) {
        guard pendingTask == nil else { return }
        pendingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            self?.pendingTask = nil
            self?.refresh(jobs: DownloadManager.shared.jobs)
        }
    }

    private func finish(jobs: [DownloadJob]) {
        guard #available(iOS 16.2, *), let activity = current else { return }
        let done = jobs.filter { $0.phase == .done }
        let failed = jobs.filter { $0.phase == .failed }
        let title: String
        if let first = done.first {
            title = done.count > 1 ? "خلص تحميل \(done.count) ملفات ✓" : first.displayTitle
        } else if !failed.isEmpty {
            title = "ما قدرت أحمل"
        } else {
            title = "انتهى"
        }
        let detail = failed.isEmpty ? "موجودة في نزّل" : "افتح نزّل عشان تشوف السبب"
        let state = DownloadActivityAttributes.ContentState(title: title, fraction: 1, detail: detail,
                                                            active: 0, finished: true)
        activityID = nil
        lastSignature = ""
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil),
                               dismissalPolicy: .after(Date().addingTimeInterval(6)))
        }
    }

    private static func shortDetail(_ job: DownloadJob) -> String {
        switch job.phase {
        case .queued: return "في الانتظار"
        case .preparing: return "جاري قراءة الرابط…"
        case .processing: return "جاري تجهيز الملف…"
        default:
            // "جاري التحميل · الفيديو · 45٪ · ⚡ 12 MB/ث" → drop the first part
            let parts = job.status.components(separatedBy: " · ")
            return parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : job.status
        }
    }
}

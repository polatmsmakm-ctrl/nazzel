import Foundation
import UIKit

/// Where new versions of the app are published.
enum AppInfo {
    static let repository = "polatmsmakm-ctrl/nazzel"
    static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases/latest")! }
    static var issuesPage: URL { URL(string: "https://github.com/\(repository)/issues")! }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// The CI build number (the same number as the release "build-N").
    static var build: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }
}

/// Tells you when a newer build of the app is on GitHub (checked at most twice a day).
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    @Published private(set) var availableBuild: Int?
    @Published private(set) var lastChecked: Date?

    private let lastCheckKey = "appUpdateLastCheck"
    private let dismissedKey = "appUpdateDismissedBuild"

    func checkIfDue() {
        guard !SelfTest.isRequested else { return }
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date ?? .distantPast
        if let cached = UserDefaults.standard.object(forKey: "appUpdateLatestBuild") as? Int { apply(cached) }
        guard Date().timeIntervalSince(last) > 12 * 3600 else { return }
        Task { await check() }
    }

    @discardableResult
    func check() async -> Int? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let build = Int(tag.replacingOccurrences(of: "build-", with: "")) else { return nil }
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        UserDefaults.standard.set(build, forKey: "appUpdateLatestBuild")
        lastChecked = Date()
        apply(build)
        return build
    }

    func dismiss() {
        if let availableBuild { UserDefaults.standard.set(availableBuild, forKey: dismissedKey) }
        availableBuild = nil
    }

    private func apply(_ latest: Int) {
        let dismissed = UserDefaults.standard.integer(forKey: dismissedKey)
        availableBuild = (AppInfo.build > 0 && latest > AppInfo.build && latest > dismissed) ? latest : nil
    }
}

/// Keeps the download engine fresh: sites change often, and an old engine stops working.
@MainActor
enum EngineAutoUpdater {
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: "engineAutoUpdate") as? Bool ?? true }
    private static let lastKey = "engineAutoUpdateLast"
    private static var running = false

    /// At most once a week, quietly in the background.
    static func runIfDue() {
        guard isEnabled, !SelfTest.isRequested, !running else { return }
        let last = UserDefaults.standard.object(forKey: lastKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 7 * 24 * 3600 else { return }
        running = true
        Task { @MainActor in
            defer { running = false }
            // let the app settle first
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            let check = await PythonEngine.shared.callAsync("check_update")
            guard check["ok"] as? Bool == true else { return }
            UserDefaults.standard.set(Date(), forKey: lastKey)
            guard check["update_available"] as? Bool == true, DownloadManager.shared.activeCount == 0 else { return }
            let result = await PythonEngine.shared.callAsync("update_engine")
            if result["ok"] as? Bool == true {
                let info = await PythonEngine.shared.callAsync("info")
                EngineStatus.shared.update(with: info)
            }
        }
    }
}

/// Notices a link you copied in another app, so the download screen can offer it.
@MainActor
final class ClipboardWatcher: ObservableObject {
    static let shared = ClipboardWatcher()

    @Published private(set) var hasLink = false
    private var dismissedChange = -1
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in ClipboardWatcher.shared.check() }
        }
    }

    /// Only asks whether there is a link (this never shows iOS's "pasted from" notice).
    func check() {
        guard !SelfTest.isRequested else { return }
        let board = UIPasteboard.general
        hasLink = board.changeCount != dismissedChange && board.hasURLs
    }

    func dismiss() {
        dismissedChange = UIPasteboard.general.changeCount
        hasLink = false
    }
}

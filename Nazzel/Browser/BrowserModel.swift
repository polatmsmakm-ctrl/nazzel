import SwiftUI
import UIKit
import WebKit

struct BrowserSite: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let url: URL
    let tint: Color

    static let all: [BrowserSite] = [
        BrowserSite(id: "youtube", name: "يوتيوب", symbol: "play.rectangle.fill",
                    url: URL(string: "https://m.youtube.com/")!, tint: .red),
        BrowserSite(id: "instagram", name: "إنستقرام", symbol: "camera.fill",
                    url: URL(string: "https://www.instagram.com/")!, tint: .pink),
        BrowserSite(id: "tiktok", name: "تيك توك", symbol: "music.note",
                    url: URL(string: "https://www.tiktok.com/")!, tint: .primary),
        BrowserSite(id: "x", name: "إكس", symbol: "at",
                    url: URL(string: "https://x.com/")!, tint: .primary),
        BrowserSite(id: "facebook", name: "فيسبوك", symbol: "person.2.fill",
                    url: URL(string: "https://m.facebook.com/")!, tint: .blue),
        BrowserSite(id: "snapchat", name: "سناب", symbol: "bolt.fill",
                    url: URL(string: "https://www.snapchat.com/spotlight")!, tint: .yellow),
        BrowserSite(id: "reddit", name: "ريديت", symbol: "bubble.left.and.bubble.right.fill",
                    url: URL(string: "https://www.reddit.com/")!, tint: .orange),
        BrowserSite(id: "pinterest", name: "بنترست", symbol: "pin.fill",
                    url: URL(string: "https://www.pinterest.com/")!, tint: .red),
        BrowserSite(id: "threads", name: "ثريدز", symbol: "at.circle.fill",
                    url: URL(string: "https://www.threads.com/")!, tint: .primary),
    ]

    func matches(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased(), let own = self.url.host?.lowercased() else { return false }
        let base = own.replacingOccurrences(of: "www.", with: "").replacingOccurrences(of: "m.", with: "")
        if id == "x" { return host.hasSuffix("x.com") || host.hasSuffix("twitter.com") }
        return host == base || host.hasSuffix("." + base)
    }
}

/// The in-app browser: your accounts stay signed in, ads are blocked,
/// and every post gets a download button.
@MainActor
final class BrowserModel: NSObject, ObservableObject {
    static let shared = BrowserModel()

    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var started = false
    @Published private(set) var lastReportedPage: String?
    @Published var toast: String?

    private var observations: [NSKeyValueObservation] = []
    private var ruleList: WKContentRuleList?
    private var toastTask: Task<Void, Never>?

    var adblockEnabled: Bool { UserDefaults.standard.object(forKey: "adblock") as? Bool ?? true }
    var badgesEnabled: Bool { UserDefaults.standard.object(forKey: "downloadBadges") as? Bool ?? true }

    private(set) lazy var webView: WKWebView = makeWebView()

    var currentSite: BrowserSite? { BrowserSite.all.first { $0.matches(url) } }

    /// True when the open page is a single video / post (the floating button downloads it).
    var isMediaPage: Bool {
        guard let url else { return false }
        let text = url.absoluteString
        let patterns = ["/watch?v=", "/shorts/", "/reel/", "/reels/", "/p/", "/tv/", "/status/", "/video/",
                        "/photo/", "/pin/", "/spotlight/", "/comments/", "/post/", "/videos/", "/clip/"]
        return patterns.contains { text.contains($0) }
    }

    // MARK: - Setup

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let controller = configuration.userContentController
        controller.add(WeakScriptHandler(self), name: "nazzel")
        installScripts(into: controller)

        let web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = CookieStore.safariUserAgent
        web.allowsBackForwardNavigationGestures = true
        web.navigationDelegate = self
        web.uiDelegate = self
        web.scrollView.contentInsetAdjustmentBehavior = .always
        observe(web)

        if adblockEnabled {
            Task { @MainActor in
                if let list = try? await Self.compileRules() {
                    self.ruleList = list
                    if self.adblockEnabled { controller.add(list) }
                }
            }
        }
        CookieStore.startWatching()
        return web
    }

    private func installScripts(into controller: WKUserContentController) {
        controller.removeAllUserScripts()
        let config = "window.__nazzelConfig = {badges: \(badgesEnabled), adblock: \(adblockEnabled)};"
        controller.addUserScript(WKUserScript(source: config, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Runs before YouTube's own code: removes the ad schedule so ads never start.
        if let file = Bundle.main.url(forResource: "nazzel-early", withExtension: "js"),
           let source = try? String(contentsOf: file, encoding: .utf8) {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if let file = Bundle.main.url(forResource: "nazzel-inject", withExtension: "js"),
           let source = try? String(contentsOf: file, encoding: .utf8) {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
    }

    private func observe(_ web: WKWebView) {
        observations = [
            web.observe(\.url, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? nil
                Task { @MainActor in self?.url = value }
            },
            web.observe(\.title, options: [.new]) { [weak self] _, change in
                let value = (change.newValue ?? nil) ?? ""
                Task { @MainActor in self?.title = value }
            },
            web.observe(\.canGoBack, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in self?.canGoBack = value }
            },
            web.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in self?.canGoForward = value }
            },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? 0
                Task { @MainActor in self?.progress = value }
            },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in self?.isLoading = value }
            },
        ]
    }

    static func compileRules() async throws -> WKContentRuleList {
        guard let file = Bundle.main.url(forResource: "adblock-rules", withExtension: "json"),
              let json = try? String(contentsOf: file, encoding: .utf8) else {
            throw NSError(domain: "Nazzel", code: 1, userInfo: [NSLocalizedDescriptionKey: "rules file missing"])
        }
        return try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "nazzel-adblock-2", encodedContentRuleList: json) { list, error in
                if let list {
                    continuation.resume(returning: list)
                } else {
                    continuation.resume(throwing: error ?? NSError(domain: "Nazzel", code: 2))
                }
            }
        }
    }

    /// Called when the ad-block or download-button switches change.
    func applySettings() {
        let controller = webView.configuration.userContentController
        installScripts(into: controller)
        controller.removeAllContentRuleLists()
        if adblockEnabled {
            if let ruleList {
                controller.add(ruleList)
            } else {
                Task { @MainActor in
                    if let list = try? await Self.compileRules() {
                        self.ruleList = list
                        controller.add(list)
                    }
                }
            }
        }
        if started { webView.reload() }
    }

    // MARK: - Navigation

    func open(_ site: BrowserSite) {
        open(site.url)
    }

    func open(_ target: URL) {
        started = true
        webView.load(URLRequest(url: target))
    }

    /// Opens a typed address, or searches for it.
    func openTyped(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let link = DownloadManager.extractURL(from: trimmed), let url = URL(string: link) {
            open(url)
        } else {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            if let url = components.url { open(url) }
        }
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    func goHome() {
        started = false
    }

    // MARK: - Downloads

    func downloadCurrentPage(mode: DownloadMode) {
        Task { @MainActor in
            let media = try? await webView.evaluateJavaScript("window.__nazzel ? window.__nazzel.currentMedia() : ''")
            let link = (media as? String).flatMap { $0.isEmpty ? nil : $0 } ?? webView.url?.absoluteString
            guard let link else { return }
            if !isMediaPage && mode != .photos {
                show("افتح الفيديو أو المنشور أول، أو اضغط زر ⬇ اللي على المنشور")
                return
            }
            startDownload(link, mode: mode)
        }
    }

    func startDownload(_ link: String, mode: DownloadMode? = nil) {
        let chosen = mode ?? DownloadManager.defaultMode
        guard DownloadManager.shared.enqueue(link, mode: chosen, quality: DownloadManager.defaultQuality) != nil else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch chosen {
        case .audio: show("بدأ تحميل الصوت ⬇")
        case .photos: show("بدأ تحميل المنشور ⬇")
        case .video: show("بدأ التحميل ⬇")
        }
    }

    func show(_ message: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.3)) { toast = message }
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { self?.toast = nil }
        }
    }

    fileprivate func handle(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "download":
            if let link = message["url"] as? String { startDownload(link) }
        case "page":
            lastReportedPage = message["url"] as? String
        default:
            break
        }
    }
}

// MARK: - WebKit delegates

extension BrowserModel: WKNavigationDelegate, WKUIDelegate {
    // The completion-handler form (not the async one): WebKit requires the decision on the
    // main thread, exactly once, and this keeps that guaranteed.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        decisionHandler(Self.policy(for: navigationAction))
    }

    private static func policy(for navigationAction: WKNavigationAction) -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return .allow }
        if ["http", "https"].contains(scheme) {
            // Stay inside Nazzel instead of jumping to the Instagram / YouTube apps (universal links).
            if navigationAction.targetFrame?.isMainFrame ?? true {
                return WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow
            }
            return .allow
        }
        if ["about", "data", "blob", "javascript"].contains(scheme) {
            return .allow
        }
        // instagram://, youtube://, intent://, itms-apps:// ... never leave the app
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        CookieStore.refreshInBackground()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank links open in the same view
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

/// Avoids a retain cycle between the content controller and the model.
@MainActor
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    private weak var target: BrowserModel?

    init(_ target: BrowserModel) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handle(message.body)
    }
}

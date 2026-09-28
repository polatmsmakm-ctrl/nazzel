import SwiftUI
import WebKit

/// In-app browser for signing in to a site. Cookies stay in the app's web data store
/// and are handed to the download engine.
struct LoginView: View {
    let site: LoginSite
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = WebModel()

    var body: some View {
        NavigationStack {
            WebView(url: site.loginURL, model: model)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .top) {
                    if model.progress < 1 {
                        ProgressView(value: model.progress)
                            .progressViewStyle(.linear)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Text("سجّل دخولك عادي، وبعد ما تدخل اضغط «تم».")
                        .font(.footnote)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
                .navigationTitle(site.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("تم") { dismiss() }
                            .bold()
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button {
                            model.reload()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
        }
    }
}

@MainActor
final class WebModel: ObservableObject {
    @Published var progress: Double = 0
    weak var webView: WKWebView?
    var observation: NSKeyValueObservation?

    func reload() {
        webView?.reload()
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    let model: WebModel

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = CookieStore.safariUserAgent
        webView.allowsBackForwardNavigationGestures = true
        model.webView = webView
        model.observation = webView.observe(\.estimatedProgress, options: [.new]) { [weak model] _, change in
            let value = change.newValue ?? 0
            Task { @MainActor in
                model?.progress = value
            }
        }
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

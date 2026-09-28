import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "نزّل" in the share sheet: pick video / audio / post, and the app opens and downloads it.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        model.onChoose = { [weak self] mode in self?.send(mode: mode) }
        model.onClose = { [weak self] in self?.close() }

        let host = UIHostingController(rootView: ShareSheetView(model: model))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        Task { @MainActor in
            model.link = await findLink()
            model.state = model.link == nil ? .notFound : .ready
        }
    }

    private func findLink() async -> String? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return nil }
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) {
                    if let url = value as? URL, url.scheme?.hasPrefix("http") == true { return url.absoluteString }
                    if let text = value as? String, let link = Self.firstLink(in: text) { return link }
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil),
                   let text = value as? String, let link = Self.firstLink(in: text) {
                    return link
                }
            }
            if let text = item.attributedContentText?.string, let link = Self.firstLink(in: text) {
                return link
            }
        }
        return nil
    }

    static func firstLink(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, options: [], range: range) {
            if let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return url.absoluteString
            }
        }
        return nil
    }

    private func send(mode: String) {
        guard let link = model.link else { return }
        var components = URLComponents()
        components.scheme = "nazzel"
        components.host = "download"
        components.queryItems = [URLQueryItem(name: "url", value: link), URLQueryItem(name: "mode", value: mode)]
        guard let url = components.url else { return }

        if openHostApp(url) {
            model.state = .opened
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.close() }
        } else {
            UIPasteboard.general.string = link
            model.state = .copied
        }
    }

    /// Extensions cannot call UIApplication.open directly; walk the responder chain instead.
    private func openHostApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current !== self,
               current.responds(to: selector),
               NSStringFromClass(type(of: current)).contains("Application") {
                typealias OpenURL = @convention(c) (NSObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let implementation = current.method(for: selector)
                let open = unsafeBitCast(implementation, to: OpenURL.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

final class ShareModel: ObservableObject {
    enum State { case loading, ready, notFound, opened, copied }

    @Published var state: State = .loading
    @Published var link: String?
    var onChoose: (String) -> Void = { _ in }
    var onClose: () -> Void = {}
}

struct ShareSheetView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title)
                        .foregroundStyle(Color(red: 0.05, green: 0.58, blue: 0.53))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("نزّل").font(.headline)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button { model.onClose() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }

                switch model.state {
                case .loading:
                    ProgressView().padding()
                case .ready:
                    VStack(spacing: 10) {
                        choice("تحميل فيديو", "film", "video")
                        choice("تحميل صوت فقط", "waveform", "audio")
                        choice("صور / المنشور كامل", "photo.on.rectangle.angled", "photos")
                    }
                case .notFound:
                    Text("ما لقيت رابط في اللي شاركته. جرّب «نسخ الرابط» بدلها.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .padding(.vertical, 8)
                case .opened:
                    Label("بدأ التحميل في نزّل ✓", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .padding(.vertical, 8)
                case .copied:
                    VStack(spacing: 10) {
                        Text("انسخ الرابط ✓ افتح نزّل واضغط «لصق».")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                        Button("تم") { model.onClose() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(.systemBackground)))
            .shadow(color: .black.opacity(0.2), radius: 20, y: 6)
            .padding(12)
        }
        .environment(\.layoutDirection, .rightToLeft)
        .background(Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { model.onClose() })
    }

    private var subtitle: String {
        guard let link = model.link, let host = URL(string: link)?.host else { return "تحميل الفيديوهات والصور" }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    private func choice(_ title: String, _ symbol: String, _ mode: String) -> some View {
        Button { model.onChoose(mode) } label: {
            HStack {
                Image(systemName: symbol).frame(width: 26)
                Text(title).font(.body.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.left").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }
}

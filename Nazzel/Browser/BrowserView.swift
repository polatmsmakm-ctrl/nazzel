import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject private var model = BrowserModel.shared
    @EnvironmentObject private var downloads: DownloadManager
    @State private var editingAddress = false
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if model.isLoading && model.started {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(height: 2)
            } else {
                Divider()
            }
            ZStack(alignment: .bottomTrailing) {
                if model.started {
                    WebViewContainer(webView: model.webView)
                } else {
                    StartPage { model.open($0) }
                }
                if model.started {
                    floatingButton
                        .padding(.trailing, 16)
                        .padding(.bottom, 14)
                }
            }
            .overlay(alignment: .top) {
                if let toast = model.toast {
                    Text(toast)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .background(Color(.systemBackground))
    }

    // MARK: Top bar

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if model.started {
                    Button { model.goBack() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!model.canGoBack)
                    Button { model.goForward() } label: { Image(systemName: "chevron.forward") }
                        .disabled(!model.canGoForward)
                }
                addressField
                if model.started {
                    Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    Menu {
                        if let url = model.url {
                            ShareLink(item: url) { Label("مشاركة الرابط", systemImage: "square.and.arrow.up") }
                            Button {
                                UIPasteboard.general.string = url.absoluteString
                                model.show("انسخ الرابط ✓")
                            } label: { Label("نسخ الرابط", systemImage: "doc.on.doc") }
                        }
                        Button { model.goHome() } label: { Label("الصفحة الرئيسية", systemImage: "square.grid.2x2") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BrowserSite.all) { site in
                        Button { model.open(site) } label: {
                            Label(site.name, systemImage: site.symbol)
                                .font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule().fill(model.currentSite == site
                                                   ? Color.accentColor.opacity(0.18)
                                                   : Color(.tertiarySystemFill))
                                )
                                .foregroundStyle(model.currentSite == site ? Color.accentColor : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: model.url?.scheme == "https" ? "lock.fill" : "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            if editingAddress {
                TextField("ابحث أو اكتب رابط", text: $address)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit {
                        model.openTyped(address)
                        editingAddress = false
                    }
                    .environment(\.layoutDirection, .leftToRight)
            } else {
                Text(model.started ? (model.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "…")
                                   : "ابحث أو اكتب رابط")
                    .font(.subheadline)
                    .foregroundStyle(model.started ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(.tertiarySystemFill)))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !editingAddress else { return }
            address = model.started ? (model.url?.absoluteString ?? "") : ""
            editingAddress = true
            addressFocused = true
        }
        .onChange(of: addressFocused) { focused in
            if !focused { editingAddress = false }
        }
    }

    // MARK: Floating download button

    private var floatingButton: some View {
        Menu {
            Button { model.downloadCurrentPage(mode: .video) } label: {
                Label("تحميل الفيديو", systemImage: "film")
            }
            Button { model.downloadCurrentPage(mode: .audio) } label: {
                Label("تحميل الصوت فقط", systemImage: "waveform")
            }
            Button { model.downloadCurrentPage(mode: .photos) } label: {
                Label("تحميل الصور / المنشور كامل", systemImage: "photo.on.rectangle.angled")
            }
        } label: {
            ZStack(alignment: .topLeading) {
                Image(systemName: "arrow.down")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(model.isMediaPage ? Color.accentColor : Color.gray.opacity(0.85)))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                if downloads.activeCount > 0 {
                    Text("\(downloads.activeCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Circle().fill(Color.red))
                        .offset(x: -4, y: -4)
                }
            }
        } primaryAction: {
            model.downloadCurrentPage(mode: DownloadManager.defaultMode == .photos ? .photos : .video)
        }
        .accessibilityLabel("تحميل")
    }
}

// MARK: - Start page

private struct StartPage: View {
    let open: (BrowserSite) -> Void
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("تصفّح وحمّل")
                        .font(.largeTitle.bold())
                    Text("سجّل دخولك بحساباتك مرة وحدة وتبقى محفوظة. اضغط زر ⬇ على أي فيديو أو منشور ويتحمل وأنت مكانك، والإعلانات مخفية.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(BrowserSite.all) { site in
                        Button { open(site) } label: {
                            VStack(spacing: 10) {
                                Image(systemName: site.symbol)
                                    .font(.title)
                                    .foregroundStyle(site.tint)
                                    .frame(width: 58, height: 58)
                                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(site.tint.opacity(0.12)))
                                Text(site.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color(.secondarySystemGroupedBackground)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Label("زر ⬇ الصغير يطلع على كل منشور وفيديو", systemImage: "arrow.down.circle.fill")
                    Label("الزر الكبير تحت يحمّل الصفحة المفتوحة (فيديو، صوت، أو صور)", systemImage: "hand.tap.fill")
                    Label("إعلانات يوتيوب تنتخطى والمنشورات الممولة تنخفي", systemImage: "nosign")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
    }
}

/// Hosts the shared WKWebView (it survives tab switches).
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

import SwiftUI
import UIKit

struct DownloadView: View {
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var engine: EngineStatus
    @AppStorage("defaultMode") private var modeRaw = DownloadMode.video.rawValue
    @AppStorage("defaultQuality") private var qualityRaw = VideoQuality.best.rawValue
    @State private var link = ""
    @State private var invalidLink = false
    @FocusState private var fieldFocused: Bool

    private var mode: DownloadMode { DownloadMode(rawValue: modeRaw) ?? .video }
    private var quality: VideoQuality { VideoQuality(rawValue: qualityRaw) ?? .best }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let error = engine.bootError {
                        EngineErrorBanner(message: error)
                    }
                    inputCard
                    if manager.jobs.isEmpty {
                        EmptyHint()
                    } else {
                        jobsList
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("نزّل")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !manager.jobs.isEmpty {
                        Button("مسح المنتهية") {
                            withAnimation { manager.clearFinished() }
                        }
                    }
                }
            }
            .onChange(of: manager.incomingToken) { _ in
                if let incoming = manager.incomingLink {
                    link = incoming
                    manager.incomingLink = nil
                }
            }
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextField("الصق رابط الفيديو هنا", text: $link, axis: .vertical)
                    .lineLimit(1...3)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($fieldFocused)
                    .onSubmit(startDownload)
                if !link.isEmpty {
                    Button {
                        link = ""
                        invalidLink = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("مسح")
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.tertiarySystemFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(invalidLink ? Color.red : Color.clear, lineWidth: 1.5)
            )

            if invalidLink {
                Text("ما لقيت رابط صحيح في النص. انسخ رابط الفيديو من زر المشاركة.")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Picker("النوع", selection: $modeRaw) {
                ForEach(DownloadMode.allCases) { item in
                    Text(item.title).tag(item.rawValue)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                if mode == .video {
                    Menu {
                        Picker("الجودة", selection: $qualityRaw) {
                            ForEach(VideoQuality.allCases) { item in
                                Text(item.title).tag(item.rawValue)
                            }
                        }
                    } label: {
                        Label(quality.title, systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.medium))
                    }
                } else if mode == .audio {
                    Label("ملف صوت M4A", systemImage: "waveform")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                } else {
                    Label("كل الصور والفيديوهات", systemImage: "photo.stack")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                PasteButton(payloadType: String.self) { strings in
                    guard let first = strings.first else { return }
                    Task { @MainActor in
                        link = first
                        startDownload()
                    }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .tint(.accentColor)
            }

            Button(action: startDownload) {
                Label("تحميل", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var jobsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("التحميلات")
                .font(.title3.bold())
                .padding(.horizontal, 4)
            ForEach(manager.jobs) { job in
                JobCard(job: job)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: manager.jobs.map(\.id))
    }

    private func startDownload() {
        let added = manager.enqueueAll(link, mode: mode, quality: quality)
        guard added > 0 else {
            withAnimation { invalidLink = true }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        invalidLink = false
        link = ""
        fieldFocused = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}

private struct EngineErrorBanner: View {
    let message: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("المحرك ما اشتغل", systemImage: "exclamationmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
            DisclosureGroup("التفاصيل", isExpanded: $expanded) {
                Text(message)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .environment(\.layoutDirection, .leftToRight)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.footnote)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.red.opacity(0.1)))
    }
}

private struct EmptyHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text("كيف تحمّل؟")
                    .font(.headline)
            }
            HintRow(number: "١", text: "من التطبيق اللي فيه الفيديو اضغط «مشاركة» ثم «نسخ الرابط».")
            HintRow(number: "٢", text: "ارجع هنا واضغط «لصق» ويبدأ التحميل على طول.")
            HintRow(number: "٣", text: "الفيديو ينحفظ في الصور، وتلقاه كمان في تبويب «الملفات» وتقدر تسمعه بالخلفية.")
            HintRow(number: "٤", text: "أو افتح تبويب «تصفّح» وسجّل دخولك، واضغط ⬇ على أي منشور.")
            Divider()
            Text("يدعم تيك توك، إنستقرام، إكس، يوتيوب، سناب شات، فيسبوك، ثريدز، بنترست، ريديت، تمبلر، فيميو، ومئات المواقع الثانية. تقدر تلصق أكثر من رابط مرة وحدة.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}

private struct HintRow: View {
    let number: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

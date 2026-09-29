import SwiftUI
import UIKit

struct DownloadView: View {
    @EnvironmentObject private var manager: DownloadManager
    @EnvironmentObject private var engine: EngineStatus
    @AppStorage("defaultMode") private var modeRaw = DownloadMode.video.rawValue
    @AppStorage("defaultQuality") private var qualityRaw = VideoQuality.best.rawValue
    @State private var link = ""
    @State private var invalidLink = false
    @State private var crashReport: String? = CrashReporter.lastReport
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var clipboard = ClipboardWatcher.shared
    @ObservedObject private var updater = AppUpdater.shared
    @FocusState private var fieldFocused: Bool
    @State private var clipOn = false
    @State private var clipFrom = ""
    @State private var clipTo = ""
    @State private var clipError = false
    @State private var playlistChoice: PlaylistChoice?
    @State private var streaming = false
    @State private var notice: String?

    struct PlaylistChoice: Identifiable {
        let id = UUID()
        let video: String
        let list: String
    }

    private var mode: DownloadMode { DownloadMode(rawValue: modeRaw) ?? .video }
    private var quality: VideoQuality { VideoQuality(rawValue: qualityRaw) ?? .best }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let error = engine.bootError {
                        EngineErrorBanner(message: error)
                    }
                    if let report = crashReport {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("التطبيق طفى المرة الماضية. انسخ التقرير وأرسله.")
                                .font(.footnote)
                            Spacer(minLength: 4)
                            Button("نسخ") {
                                UIPasteboard.general.string = report
                                crashReport = nil
                            }
                            .font(.footnote.weight(.semibold))
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.12)))
                    }
                    if let build = updater.availableBuild {
                        UpdateBanner(build: build) { updater.dismiss() }
                    }
                    if clipboard.hasLink, link.isEmpty {
                        clipboardBanner
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
            .sheet(isPresented: $router.showQualityPicker) {
                QualityPickerSheet(selection: $qualityRaw)
            }
            .sheet(item: $router.collection) { request in
                PlaylistPickerSheet(request: request) { count in
                    if count > 0 { showNotice("انضاف \(count) للتحميل ⬇") }
                }
            }
            .confirmationDialog("هذا الفيديو من قائمة تشغيل", isPresented: Binding(
                get: { playlistChoice != nil },
                set: { if !$0 { playlistChoice = nil } }
            ), titleVisibility: .visible, presenting: playlistChoice) { choice in
                Button("هذا الفيديو بس") {
                    enqueue([choice.video])
                    playlistChoice = nil
                }
                Button("أختار من القائمة كاملة") {
                    router.collection = CollectionRequest(url: choice.list, mode: mode, quality: quality)
                    clearInput()
                    playlistChoice = nil
                }
            }
            .overlay(alignment: .top) {
                if let notice {
                    Text(notice)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onAppear {
                clipboard.check()
                updater.checkIfDue()
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

            if let handle = LinkKinds.instagramHandle(link) {
                HStack(spacing: 10) {
                    Button {
                        enqueue([LinkKinds.instagramStories(handle)], mode: .photos)
                    } label: {
                        Label("ستوريات @\(handle)", systemImage: "circle.dashed")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    Button {
                        enqueue([LinkKinds.instagramHighlights(handle)], mode: .photos)
                    } label: {
                        Label("الهايلايت", systemImage: "star.circle")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                }
                Text("من انستقرام. لازم تكون مسجّل دخولك من الإعدادات.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("النوع", selection: $modeRaw) {
                ForEach(DownloadMode.allCases) { item in
                    Text(item.title).tag(item.rawValue)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                if mode == .video {
                    Button {
                        router.showQualityPicker = true
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
                if mode != .photos {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { clipOn.toggle() }
                    } label: {
                        Image(systemName: "scissors")
                            .font(.subheadline.weight(.semibold))
                            .padding(7)
                            .background(Circle().fill(clipOn ? Color.accentColor.opacity(0.18) : Color.clear))
                    }
                    .accessibilityLabel("نزّل جزء بس")
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

            if clipOn, mode != .photos {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text("من")
                        TextField("0:00", text: $clipFrom)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.center)
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                            .environment(\.layoutDirection, .leftToRight)
                        Text("إلى")
                        TextField("1:30", text: $clipTo)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.center)
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                            .environment(\.layoutDirection, .leftToRight)
                        Spacer()
                    }
                    .font(.subheadline)
                    Text(clipError ? "اكتب الوقت مثل 1:30، والنهاية بعد البداية."
                                   : "ينزل الفيديو وبعدين يقص الجزء اللي كتبته بس.")
                        .font(.caption)
                        .foregroundStyle(clipError ? Color.red : Color.secondary)
                }
                .transition(.opacity)
            }

            HStack(spacing: 10) {
                Button(action: startDownload) {
                    Label("تحميل", systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .controlSize(.large)

                Button(action: playWithoutDownloading) {
                    Group {
                        if streaming {
                            ProgressView()
                        } else {
                            Label("شغّل", systemImage: "play.fill")
                        }
                    }
                    .font(.headline)
                    .frame(minWidth: 70)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 14))
                .controlSize(.large)
                .disabled(streaming || mode == .photos)
                .accessibilityLabel("شغّل بدون تحميل")
            }
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

    private var clipboardBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .foregroundStyle(Color.accentColor)
            Text("عندك رابط منسوخ")
                .font(.subheadline.weight(.medium))
            Spacer(minLength: 4)
            PasteButton(payloadType: String.self) { strings in
                guard let first = strings.first else { return }
                Task { @MainActor in
                    clipboard.dismiss()
                    link = first
                    startDownload()
                }
            }
            .labelStyle(.titleOnly)
            .buttonBorderShape(.capsule)
            .tint(.accentColor)
            Button {
                clipboard.dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("إخفاء")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.accentColor.opacity(0.1)))
    }

    private func startDownload() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if let handle = LinkKinds.instagramHandle(text) {
            enqueue([LinkKinds.instagramStories(handle)], mode: .photos)
            return
        }
        let links = DownloadManager.extractURLs(from: text)
        guard !links.isEmpty else {
            withAnimation { invalidLink = true }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }
        if links.count == 1 {
            if LinkKinds.isCollection(links[0]) {
                router.collection = CollectionRequest(url: links[0], mode: mode, quality: quality)
                clearInput()
                return
            }
            if let list = LinkKinds.playlistInsideVideo(links[0]) {
                playlistChoice = PlaylistChoice(video: links[0], list: list)
                return
            }
        }
        enqueue(links)
    }

    private func enqueue(_ links: [String], mode chosen: DownloadMode? = nil) {
        var clip: ClosedRange<Double>?
        if clipOn, (chosen ?? mode) != .photos {
            let fromValue = LinkKinds.parseTime(clipFrom.isEmpty ? "0" : clipFrom)
            let toValue = LinkKinds.parseTime(clipTo)
            guard let from = fromValue, let to = toValue, to > from else {
                withAnimation { clipError = true }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
            clip = from...to
        }
        for item in links {
            manager.enqueue(item, mode: chosen ?? mode, quality: quality, clip: clip)
        }
        clearInput()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func clearInput() {
        invalidLink = false
        clipError = false
        link = ""
        fieldFocused = false
    }

    private func playWithoutDownloading() {
        guard let single = DownloadManager.extractURL(from: link) else {
            withAnimation { invalidLink = true }
            return
        }
        streaming = true
        fieldFocused = false
        Task { @MainActor in
            let error = await StreamLauncher.play(single, audioOnly: mode == .audio)
            streaming = false
            if let error {
                showNotice(error)
            } else {
                link = ""
            }
        }
    }

    private func showNotice(_ text: String) {
        withAnimation { notice = text }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation { if notice == text { notice = nil } }
        }
    }
}

private struct UpdateBanner: View {
    let build: Int
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.app.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("فيه نسخة جديدة من نزّل")
                    .font(.subheadline.weight(.semibold))
                Text("بناء \(build) · نزّلها وثبّتها فوق الحالية")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Link("فتح", destination: AppInfo.releasesPage)
                .font(.subheadline.weight(.semibold))
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("إخفاء")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
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
            HintRow(number: "٥", text: "زر «شغّل» يشغّل الفيديو بدون تحميل وبدون إعلانات، ويكمّل بالخلفية.")
            HintRow(number: "٦", text: "اكتب @اسم_الحساب عشان تنزل ستوريات انستقرام أو الهايلايت.")
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

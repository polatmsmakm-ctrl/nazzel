import AVKit
import SwiftUI

/// Cut a part of a video or song into a new file, or make a ringtone from it.
struct TrimView: View {
    let item: LibraryItem

    @Environment(\.dismiss) private var dismiss
    @State private var duration: Double = 0
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var preview = AVPlayer()
    @State private var stopTask: Task<Void, Never>?
    @State private var busy = false
    @State private var message: String?
    @State private var ringtone: URL?
    @State private var showRingtoneHelp = false

    private let ringtoneLimit: Double = 30

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if item.isVideo {
                        VideoPlayer(player: preview)
                            .frame(height: 210)
                            .listRowInsets(EdgeInsets())
                    } else {
                        HStack {
                            Spacer()
                            ArtworkView(image: nil, isVideo: false, size: 110, corner: 18)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }

                Section {
                    timeRow(title: "البداية", value: start)
                    Slider(value: $start, in: 0...max(duration, 0.1)) { editing in
                        if !editing { seekPreview(start) }
                    }
                    // time runs left to right, like every player's bar
                    .environment(\.layoutDirection, .leftToRight)
                    .onChange(of: start) { value in
                        if value > end - 0.5 { end = min(duration, value + 0.5) }
                    }
                    timeRow(title: "النهاية", value: end)
                    Slider(value: $end, in: 0...max(duration, 0.1)) { editing in
                        if !editing { seekPreview(max(start, end - 3)) }
                    }
                    .environment(\.layoutDirection, .leftToRight)
                    .onChange(of: end) { value in
                        if value < start + 0.5 { start = max(0, value - 0.5) }
                    }
                    HStack {
                        Text("طول المقطع")
                        Spacer()
                        Text(Formatters.duration(max(0, end - start)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        playSelection()
                    } label: {
                        Label("اسمع المقطع المختار", systemImage: "play.circle")
                    }
                } header: {
                    Text("حدد الجزء")
                }

                Section {
                    Button {
                        saveClip()
                    } label: {
                        Label("حفظ المقطع كملف جديد", systemImage: "scissors")
                    }
                    .disabled(busy || end - start < 0.5)
                    Button {
                        makeRingtone()
                    } label: {
                        Label("نغمة رنين (أول \(Int(ringtoneLimit)) ثانية من المقطع)", systemImage: "bell.badge")
                    }
                    .disabled(busy)
                    if let ringtone {
                        ShareLink(item: ringtone) {
                            Label("مشاركة النغمة", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            showRingtoneHelp = true
                        } label: {
                            Label("كيف أخليها نغمة جوالي؟", systemImage: "questionmark.circle")
                        }
                    }
                } footer: {
                    if let message {
                        Text(message)
                    } else {
                        Text("الأصل ما يتغير: المقطع ينحفظ ملف جديد جنبه.")
                    }
                }
            }
            .navigationTitle("قص")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { dismiss() }
                }
            }
            .overlay {
                if busy {
                    ProgressView()
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert("نغمة الرنين", isPresented: $showRingtoneHelp) {
                Button("تمام", role: .cancel) {}
            } message: {
                Text("الآيفون ما يسمح للتطبيقات تغيّر النغمة مباشرة. افتح تطبيق GarageBand ← مشروع جديد ← المسجل ← زر الحلقات ← الملفات، واختر النغمة من مجلد نزّل، بعدين شارك المشروع كـ «نغمة رنين».")
            }
        }
        .task { await load() }
        .onDisappear {
            stopTask?.cancel()
            preview.pause()
        }
    }

    private func timeRow(title: String, value: Double) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(Formatters.duration(value))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        let seconds = await MediaTools.duration(of: item.url) ?? 0
        duration = seconds
        start = 0
        end = seconds
        preview.replaceCurrentItem(with: AVPlayerItem(url: item.url))
    }

    private func seekPreview(_ time: Double) {
        preview.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func playSelection() {
        stopTask?.cancel()
        PlayerController.shared.pause()
        seekPreview(start)
        preview.play()
        let length = max(0.5, end - start)
        stopTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(length * 1_000_000_000))
            guard !Task.isCancelled else { return }
            preview.pause()
        }
    }

    private func saveClip() {
        busy = true
        preview.pause()
        Task { @MainActor in
            defer { busy = false }
            let folder = item.url.deletingLastPathComponent()
            let temp = Paths.work.appendingPathComponent(UUID().uuidString + "." + item.url.pathExtension)
            do {
                let clip = try await MediaTools.trim(item.url, from: start, to: end, output: temp)
                let name = item.name + " (مقطع)." + clip.pathExtension
                let destination = Paths.uniqueDestination(for: name, in: folder)
                try FileManager.default.moveItem(at: clip, to: destination)
                LibraryCopies.copyInfo(from: item, to: destination, titleSuffix: " (مقطع)")
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                message = "انحفظ المقطع ✓ (\(Formatters.duration(end - start)))"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                message = "ما قدرت أقص الملف: \(error.localizedDescription)"
            }
        }
    }

    private func makeRingtone() {
        busy = true
        preview.pause()
        Task { @MainActor in
            defer { busy = false }
            let temp = Paths.work.appendingPathComponent(UUID().uuidString + ".m4r")
            do {
                let tone = try await MediaTools.ringtone(item.url, from: start, seconds: min(ringtoneLimit, end - start), output: temp)
                let destination = Paths.uniqueDestination(for: item.name + " (نغمة).m4r", in: item.url.deletingLastPathComponent())
                try FileManager.default.moveItem(at: tone, to: destination)
                LibraryCopies.copyInfo(from: item, to: destination, titleSuffix: " (نغمة)")
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                ringtone = destination
                message = "النغمة جاهزة ✓ وموجودة في الملفات"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                message = "ما قدرت أسوي النغمة: \(error.localizedDescription)"
            }
        }
    }
}

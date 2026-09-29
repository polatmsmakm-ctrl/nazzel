import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

struct Movie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return Movie(url: dst)
        }
    }
}

@MainActor
final class Generator: ObservableObject {
    @Published var busy = false
    @Published var status = ""
    @Published var progress: Double = 0
    @Published var error: String?

    private var task: Task<Void, Never>?

    func run(video: URL, notes: String, apiKey: String, model: String,
             done: @escaping (LessonPlan) -> Void) {
        busy = true
        error = nil
        progress = 0
        status = "أشاهد الفيديو…"
        task = Task {
            do {
                let frames = try await FrameExtractor.frames(from: video) { [weak self] p in
                    self?.progress = p * 0.5
                }
                status = "أكتب التحضير… (\(frames.count) شريحة)"
                progress = 0.55
                let client = ClaudeClient(apiKey: apiKey, model: model)
                let plan = try await client.makePlan(frames: frames, notes: notes)
                progress = 1
                busy = false
                done(plan)
            } catch is CancellationError {
                busy = false
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        busy = false
    }
}

struct ContentView: View {
    @EnvironmentObject var store: PlanStore
    @StateObject private var gen = Generator()
    @AppStorage("apiKey") private var apiKey = ""
    @AppStorage("model") private var model = ClaudeClient.models[0].id

    @State private var pickerItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var videoInfo = ""
    @State private var loadingVideo = false
    @State private var showFiles = false
    @State private var notes = ""
    @State private var showSettings = false
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                if apiKey.isEmpty {
                    Section {
                        Button {
                            showSettings = true
                        } label: {
                            Label("أول شي: حط مفتاح الـ API من الإعدادات", systemImage: "key.fill")
                                .foregroundColor(.orange)
                        }
                    }
                }

                Section("فيديو الدرس") {
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        Label("اختر فيديو من الصور", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        showFiles = true
                    } label: {
                        Label("اختر فيديو من الملفات", systemImage: "folder")
                    }
                    if loadingVideo {
                        HStack { ProgressView(); Text("جاري تحميل الفيديو…") }
                    } else if videoURL != nil {
                        Label(videoInfo, systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }

                Section {
                    TextField("مثال: الصفحة 14، ركّز على الكلمات الجديدة", text: $notes, axis: .vertical)
                        .lineLimit(1...4)
                } header: {
                    Text("ملاحظات (اختياري)")
                }

                Section {
                    if gen.busy {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(gen.status)
                            ProgressView(value: gen.progress)
                            Button("إلغاء", role: .cancel) { gen.cancel() }
                                .font(.footnote)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button {
                            start()
                        } label: {
                            HStack {
                                Spacer()
                                Label("حضّر لي", systemImage: "sparkles")
                                    .font(.headline)
                                Spacer()
                            }
                        }
                        .disabled(videoURL == nil || apiKey.isEmpty || loadingVideo)
                    }
                    if let e = gen.error {
                        Text(e).foregroundColor(.red).font(.footnote)
                    }
                }

                if !store.plans.isEmpty {
                    Section("التحضيرات السابقة") {
                        ForEach(store.plans) { plan in
                            NavigationLink(value: plan.id) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plan.title.isEmpty ? "تحضير" : plan.title)
                                        .font(.body.weight(.medium))
                                    Text(plan.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        .onDelete { store.plans.remove(atOffsets: $0) }
                    }
                }
            }
            .navigationTitle("تحضير")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let idx = store.plans.firstIndex(where: { $0.id == id }) {
                    PlanView(plan: $store.plans[idx])
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fileImporter(isPresented: $showFiles,
                          allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie]) { result in
                if case .success(let url) = result { importFile(url) }
            }
            .onChange(of: pickerItem) { item in
                guard let item else { return }
                loadingVideo = true
                Task {
                    let movie = try? await item.loadTransferable(type: Movie.self)
                    loadingVideo = false
                    if let movie { await setVideo(movie.url) } else { gen.error = "ما قدرت أفتح الفيديو من الصور." }
                }
            }
        }
    }

    private func importFile(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "mov" : url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: dst)
            Task { await setVideo(dst) }
        } catch {
            gen.error = "ما قدرت أفتح الملف."
        }
    }

    private func setVideo(_ url: URL) async {
        let d = await FrameExtractor.duration(of: url)
        videoURL = url
        gen.error = nil
        let m = Int(d) / 60, s = Int(d) % 60
        videoInfo = "تم اختيار الفيديو (\(m):" + String(format: "%02d", s) + ")"
    }

    private func start() {
        guard let url = videoURL else { return }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        gen.run(video: url, notes: notes, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
                model: model) { plan in
            store.add(plan)
            path.append(plan.id)
        }
    }
}

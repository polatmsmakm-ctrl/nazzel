import SwiftUI
import UIKit

/// How much space the app uses, and what you can clear.
struct StorageView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var downloadsSize: Int64 = 0
    @State private var tempSize: Int64 = 0
    @State private var largest: [LibraryItem] = []
    @State private var pendingDelete: LibraryItem?
    @State private var message: String?

    private var tempFolders: [URL] {
        [Paths.work, Paths.thumbnails, Paths.caches.appendingPathComponent("yt-dlp", isDirectory: true)]
    }

    var body: some View {
        List {
            Section {
                LabeledContent("التحميلات", value: Formatters.bytes(Double(downloadsSize)))
                LabeledContent("ملفات مؤقتة", value: Formatters.bytes(Double(tempSize)))
                Button {
                    clearTemporary()
                } label: {
                    Label("مسح الملفات المؤقتة", systemImage: "trash.slash")
                }
                .disabled(tempSize == 0 || DownloadManager.shared.activeCount > 0)
            } footer: {
                if let message {
                    Text(message)
                } else {
                    Text("المؤقتة: صور مصغرة وبقايا تحميلات. مسحها آمن وما يمس ملفاتك.")
                }
            }

            if !largest.isEmpty {
                Section {
                    ForEach(largest) { item in
                        HStack(spacing: 12) {
                            ThumbnailView(url: item.url)
                                .scaleEffect(0.75)
                                .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.displayTitle)
                                    .font(.subheadline)
                                    .lineLimit(2)
                                Text(Formatters.bytes(Double(item.size)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                pendingDelete = item
                            } label: {
                                Label("حذف", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("أكبر الملفات")
                } footer: {
                    Text("اسحب أي ملف لليسار عشان تحذفه.")
                }
            }
        }
        .navigationTitle("المساحة")
        .navigationBarTitleDisplayMode(.inline)
        .task { await measure() }
        .refreshable { await measure() }
        .confirmationDialog("حذف الملف؟", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("حذف", role: .destructive) {
                if let item = pendingDelete { store.delete(item) }
                pendingDelete = nil
                Task { await measure() }
            }
        }
    }

    @MainActor
    private func measure() async {
        let folders = tempFolders
        let root = store.root
        let sizes = await Task.detached(priority: .utility) { () -> (Int64, Int64) in
            (LibraryStore.size(of: root), folders.reduce(Int64(0)) { $0 + LibraryStore.size(of: $1) })
        }.value
        downloadsSize = sizes.0
        tempSize = sizes.1
        largest = store.largestFiles(limit: 15)
    }

    private func clearTemporary() {
        let before = tempSize
        for folder in tempFolders {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        Task { @MainActor in
            await measure()
            message = "انمسح \(Formatters.bytes(Double(max(0, before - tempSize)))) ✓"
        }
    }
}

/// "Send a problem or idea": a ready report the user shares however they like.
@MainActor
enum FeedbackReport {
    static func make() async -> String {
        let log = await PythonEngine.shared.callAsync("log", ["lines": 60])
        let lines = (log["log"] as? [String] ?? []).suffix(60).joined(separator: "\n")
        var text = """
        نزّل \(AppInfo.version) (بناء \(AppInfo.build)) · iOS \(UIDevice.current.systemVersion) · \(deviceModel())
        المحرك: \(EngineStatus.shared.ytDlpVersion ?? "?")

        اكتب المشكلة أو الاقتراح هنا:


        --- السجل ---
        \(lines)
        """
        if let crash = CrashReporter.lastReport {
            text += "\n\n--- آخر كراش ---\n" + String(crash.prefix(3000))
        }
        return text
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

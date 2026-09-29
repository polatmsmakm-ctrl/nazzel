import AVKit
import Combine
import SwiftUI
import UIKit

struct LibraryView: View {
    @ObservedObject private var router = AppRouter.shared

    var body: some View {
        NavigationStack {
            LibraryFolderView(folder: nil)
                .navigationDestination(for: LibraryFolder.self) { folder in
                    LibraryFolderView(folder: folder.url)
                }
        }
        .sheet(item: $router.trimItem) { item in
            TrimView(item: item)
        }
    }
}

/// One folder of the library (the top one when `folder` is nil).
struct LibraryFolderView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, video, audio, photos
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "الكل"
            case .video: return "فيديو"
            case .audio: return "صوت"
            case .photos: return "صور"
            }
        }
    }

    let folder: URL?

    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var player = PlayerController.shared
    @State private var folders: [LibraryFolder] = []
    @State private var items: [LibraryItem] = []
    @State private var filter = Filter.all
    @State private var viewing: PlayItem?
    @State private var renaming: LibraryItem?
    @State private var newName = ""
    @State private var search = ""
    @State private var toast: String?
    @State private var pendingDelete: LibraryItem?
    @State private var moving: LibraryItem?
    @State private var creatingFolder = false
    @State private var folderName = ""
    @State private var renamingFolder: LibraryFolder?
    @State private var deletingFolder: LibraryFolder?

    private var location: URL { folder ?? store.root }
    private var isRoot: Bool { folder == nil }

    private var filtered: [LibraryItem] {
        var list = items
        switch filter {
        case .all: break
        case .video: list = list.filter(\.isVideo)
        case .audio: list = list.filter(\.isAudio)
        case .photos: list = list.filter(\.isImage)
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list }
        return list.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
                || ($0.meta?.uploader ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Group {
            if items.isEmpty && folders.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle(isRoot ? "الملفات" : location.lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    folderName = ""
                    creatingFolder = true
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .accessibilityLabel("مجلد جديد")
            }
        }
        .onAppear(perform: reloadListing)
        .onReceive(NotificationCenter.default.publisher(for: .libraryChanged)) { _ in reloadListing() }
        .sheet(item: $viewing) { item in
            ImageViewer(url: item.url)
        }
        .sheet(item: $moving) { item in
            MoveToFolderSheet(item: item) { message in show(message) }
        }
        .alert("إعادة تسمية", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("الاسم", text: $newName)
            Button("حفظ") {
                if let item = renaming { store.rename(item, to: newName) }
                renaming = nil
            }
            Button("إلغاء", role: .cancel) { renaming = nil }
        }
        .alert("مجلد جديد", isPresented: $creatingFolder) {
            TextField("اسم المجلد", text: $folderName)
            Button("إنشاء") {
                if store.createFolder(named: folderName, in: location) != nil { show("انسوى المجلد ✓") }
            }
            Button("إلغاء", role: .cancel) {}
        }
        .alert("اسم المجلد", isPresented: Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )) {
            TextField("الاسم", text: $folderName)
            Button("حفظ") {
                if let folder = renamingFolder { store.renameFolder(folder, to: folderName) }
                renamingFolder = nil
            }
            Button("إلغاء", role: .cancel) { renamingFolder = nil }
        }
        .confirmationDialog("حذف الملف؟", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("حذف", role: .destructive) {
                if let item = pendingDelete { store.delete(item) }
                pendingDelete = nil
            }
        } message: {
            Text("الملف ينحذف من التطبيق. النسخة المحفوظة في الصور تبقى.")
        }
        .confirmationDialog("حذف المجلد وكل اللي فيه؟", isPresented: Binding(
            get: { deletingFolder != nil },
            set: { if !$0 { deletingFolder = nil } }
        ), titleVisibility: .visible) {
            Button("حذف المجلد", role: .destructive) {
                if let folder = deletingFolder { store.deleteFolder(folder) }
                deletingFolder = nil
            }
        } message: {
            Text("كل الملفات اللي داخل المجلد بتنحذف.")
        }
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast)
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var list: some View {
        List {
            if !items.isEmpty {
                Section {
                    Picker("النوع", selection: $filter) {
                        ForEach(Filter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            }
            if !folders.isEmpty, search.isEmpty {
                Section("المجلدات") {
                    ForEach(folders) { entry in
                        NavigationLink(value: entry) {
                            HStack {
                                Label(entry.name, systemImage: "folder.fill")
                                Spacer()
                                Text("\(entry.count)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contextMenu {
                            Button {
                                folderName = entry.name
                                renamingFolder = entry
                            } label: {
                                Label("إعادة تسمية", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                deletingFolder = entry
                            } label: {
                                Label("حذف المجلد", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            if !items.isEmpty {
                Section {
                    if filtered.contains(where: \.canPlay) {
                        Button {
                            let queue = filtered.filter(\.canPlay).map(\.url)
                            if let first = queue.first { player.play(first, queue: queue) }
                        } label: {
                            Label("تشغيل الكل", systemImage: "play.circle.fill")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    ForEach(filtered) { item in
                        row(item)
                    }
                } footer: {
                    if isRoot {
                        Text("عندك \(items.count) ملف هنا، وكل التحميلات حجمها \(Formatters.bytes(Double(store.totalSize))). تلقاها كمان في تطبيق «الملفات» ← على الـ iPhone ← نزّل")
                    } else {
                        Text("في هذا المجلد \(items.count) ملف.")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "بحث في الملفات")
        .refreshable { reloadListing() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: isRoot ? "tray" : "folder")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text(isRoot ? "ما في ملفات للحين" : "المجلد فاضي")
                .font(.title3.bold())
            Text(isRoot ? "أي فيديو أو صوت أو صورة تحملها بتطلع هنا."
                        : "انقل له ملفات: اضغط مطولاً على أي ملف ← نقل إلى مجلد.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func reloadListing() {
        let listing = store.contents(of: location)
        folders = listing.folders
        items = listing.items
    }

    private func open(_ item: LibraryItem) {
        if item.canPlay {
            let queue = filtered.filter(\.canPlay).map(\.url)
            player.play(item.url, queue: queue)
            if item.isVideo { player.showFullPlayer = true }
        } else if item.isImage {
            viewing = PlayItem(url: item.url)
        } else {
            show("هذي الصيغة تنفتح من المشاركة ← تطبيق ثاني مثل VLC")
        }
    }

    private func row(_ item: LibraryItem) -> some View {
        Button {
            open(item)
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    ThumbnailView(url: item.url)
                    if player.current == item.url {
                        Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Circle().fill(Color.accentColor))
                            .padding(4)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(player.current == item.url ? Color.accentColor : .primary)
                        .lineLimit(2)
                    if let uploader = item.meta?.uploader, !uploader.isEmpty {
                        Text(uploader)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 4) {
                        Text("\(item.kindLabel) · \(Formatters.bytes(Double(item.size))) · \(item.date.formatted(date: .abbreviated, time: .omitted))")
                        if item.hasSubtitles {
                            Image(systemName: "captions.bubble")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = item
            } label: {
                Label("حذف", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            ShareLink(item: item.url) {
                Label("مشاركة", systemImage: "square.and.arrow.up")
            }
            .tint(.accentColor)
        }
        .contextMenu {
            if item.canPlay {
                Button {
                    player.play(item.url, queue: filtered.filter(\.canPlay).map(\.url))
                } label: {
                    Label("تشغيل", systemImage: "play")
                }
            }
            ShareLink(item: item.url) {
                Label("مشاركة أو حفظ في الملفات", systemImage: "square.and.arrow.up")
            }
            if PhotoSaver.canSave(item.url) {
                Button {
                    saveToPhotos(item)
                } label: {
                    Label("حفظ في الصور", systemImage: "photo.badge.plus")
                }
            }
            if item.canPlay {
                Button {
                    AppRouter.shared.trimItem = item
                } label: {
                    Label("قص مقطع أو نغمة رنين", systemImage: "scissors")
                }
            }
            if item.isVideo {
                Button {
                    convertToAudio(item)
                } label: {
                    Label("تحويل إلى صوت (M4A)", systemImage: "waveform")
                }
            }
            Button {
                moving = item
            } label: {
                Label("نقل إلى مجلد", systemImage: "folder")
            }
            if let source = item.meta?.source, let url = URL(string: source) {
                Button {
                    UIPasteboard.general.url = url
                    show("انسخ رابط المصدر ✓")
                } label: {
                    Label("نسخ رابط المصدر", systemImage: "link")
                }
            }
            Button {
                newName = item.displayTitle
                renaming = item
            } label: {
                Label("إعادة تسمية", systemImage: "pencil")
            }
            Button(role: .destructive) {
                pendingDelete = item
            } label: {
                Label("حذف", systemImage: "trash")
            }
        }
    }

    private func saveToPhotos(_ item: LibraryItem) {
        Task { @MainActor in
            do {
                try await PhotoSaver.save(item.url)
                show("انحفظ في الصور ✓")
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func convertToAudio(_ item: LibraryItem) {
        show("جاري التحويل…")
        Task { @MainActor in
            let temp = Paths.work.appendingPathComponent(UUID().uuidString + ".m4a")
            do {
                let audio = try await MediaTools.extractAudio(item.url, output: temp)
                let destination = Paths.uniqueDestination(
                    for: item.url.deletingPathExtension().lastPathComponent + ".m4a",
                    in: item.url.deletingLastPathComponent())
                try FileManager.default.moveItem(at: audio, to: destination)
                LibraryCopies.copyInfo(from: item, to: destination)
                NotificationCenter.default.post(name: .libraryChanged, object: nil)
                show("تم ✓ صار عندك نسخة صوت")
            } catch {
                show("تعذر التحويل")
            }
        }
    }

    private func show(_ message: String) {
        withAnimation { toast = message }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation {
                if toast == message { toast = nil }
            }
        }
    }
}

/// Title, channel and cover art carry over to a new file made from an old one.
@MainActor
enum LibraryCopies {
    static func copyInfo(from item: LibraryItem, to destination: URL, titleSuffix: String? = nil) {
        var meta = item.meta ?? MediaMeta(title: item.displayTitle)
        meta.added = Date()
        if let titleSuffix { meta.title = (meta.title ?? item.displayTitle) + titleSuffix }
        MediaIndex.shared.set(meta, for: destination)
        let art = MediaIndex.artworkURL(for: item.url)
        if FileManager.default.fileExists(atPath: art.path) {
            try? FileManager.default.copyItem(at: art, to: MediaIndex.artworkURL(for: destination))
        }
    }
}

/// "Move to folder": every folder, plus making a new one.
struct MoveToFolderSheet: View {
    let item: LibraryItem
    let done: (String) -> Void
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.allFolders(), id: \.self) { folder in
                        let here = folder.standardizedFileURL == item.url.deletingLastPathComponent().standardizedFileURL
                        Button {
                            move(to: folder)
                        } label: {
                            HStack {
                                Label(title(for: folder), systemImage: folder == store.root ? "tray.full" : "folder.fill")
                                Spacer()
                                if here {
                                    Text("هنا الحين").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(here)
                    }
                } footer: {
                    Text(item.displayTitle)
                }
                Section {
                    Button {
                        name = ""
                        creating = true
                    } label: {
                        Label("مجلد جديد", systemImage: "folder.badge.plus")
                    }
                }
            }
            .navigationTitle("نقل إلى مجلد")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إلغاء") { dismiss() }
                }
            }
            .alert("مجلد جديد", isPresented: $creating) {
                TextField("اسم المجلد", text: $name)
                Button("إنشاء ونقل") {
                    if let folder = store.createFolder(named: name) { move(to: folder) }
                }
                Button("إلغاء", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func title(for folder: URL) -> String {
        if folder.standardizedFileURL == store.root.standardizedFileURL { return "الملفات (الرئيسي)" }
        let rootPath = store.root.standardizedFileURL.path
        let path = folder.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count + 1)).replacingOccurrences(of: "/", with: " ← ")
                                        : folder.lastPathComponent
    }

    private func move(to folder: URL) {
        if store.move(item, to: folder) != nil {
            done("انتقل إلى «\(store.displayName(of: folder))» ✓")
        } else {
            done("ما قدرت أنقل الملف")
        }
        dismiss()
    }
}

struct ThumbnailView: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: MediaTools.isAudio(url) ? "music.note" : MediaTools.isImage(url) ? "photo" : "film")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: url) {
            let loaded = await MediaTools.thumbnail(for: url)
            await MainActor.run { image = loaded }
        }
    }
}

/// Full-screen photo with pinch to zoom.
struct ImageViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var saved = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { scale = max(1, lastScale * $0) }
                                .onEnded { _ in lastScale = scale }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.spring()) {
                                scale = scale > 1 ? 1 : 2.5
                                lastScale = scale
                            }
                        }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if PhotoSaver.canSave(url) {
                        Button {
                            Task { @MainActor in
                                saved = (try? await PhotoSaver.save(url)) != nil
                            }
                        } label: {
                            Image(systemName: saved ? "checkmark.circle.fill" : "photo.badge.plus")
                        }
                    }
                    ShareLink(item: url)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }
}

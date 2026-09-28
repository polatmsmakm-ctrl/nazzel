import AVKit
import SwiftUI
import UIKit

struct LibraryView: View {
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

    @EnvironmentObject private var store: LibraryStore
    @ObservedObject private var player = PlayerController.shared
    @State private var filter = Filter.all
    @State private var viewing: PlayItem?
    @State private var renaming: LibraryItem?
    @State private var newName = ""
    @State private var search = ""
    @State private var toast: String?
    @State private var pendingDelete: LibraryItem?

    private var filtered: [LibraryItem] {
        var items = store.items
        switch filter {
        case .all: break
        case .video: items = items.filter(\.isVideo)
        case .audio: items = items.filter(\.isAudio)
        case .photos: items = items.filter(\.isImage)
        }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(query)
                || ($0.meta?.uploader ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
                            Picker("النوع", selection: $filter) {
                                ForEach(Filter.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        }
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
                            Text("\(store.items.count) ملف · \(Formatters.bytes(Double(store.totalSize))) · تلقاها كمان في تطبيق الملفات › على الـ iPhone › نزّل")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .searchable(text: $search, prompt: "بحث في الملفات")
                }
            }
            .navigationTitle("الملفات")
            .onAppear { store.reload() }
            .refreshable { store.reload() }
            .sheet(item: $viewing) { item in
                ImageViewer(url: item.url)
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
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text("ما في ملفات للحين")
                .font(.title3.bold())
            Text("أي فيديو أو صوت أو صورة تحملها بتطلع هنا.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func open(_ item: LibraryItem) {
        if item.canPlay {
            let queue = filtered.filter(\.canPlay).map(\.url)
            player.play(item.url, queue: queue)
            if item.isVideo { player.showFullPlayer = true }
        } else if item.isImage {
            viewing = PlayItem(url: item.url)
        } else {
            show("هذي الصيغة تنفتح من المشاركة › تطبيق ثاني مثل VLC")
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
                    Text("\(item.kindLabel) · \(Formatters.bytes(Double(item.size))) · \(item.date.formatted(date: .abbreviated, time: .omitted))")
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
            if item.isVideo {
                Button {
                    convertToAudio(item)
                } label: {
                    Label("تحويل إلى صوت (M4A)", systemImage: "waveform")
                }
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
                    for: item.url.deletingPathExtension().lastPathComponent + ".m4a", in: Paths.downloads)
                try FileManager.default.moveItem(at: audio, to: destination)
                if var meta = item.meta {
                    meta.added = Date()
                    MediaIndex.shared.set(meta, for: destination)
                }
                let art = MediaIndex.artworkURL(for: item.url)
                if FileManager.default.fileExists(atPath: art.path) {
                    try? FileManager.default.copyItem(at: art, to: MediaIndex.artworkURL(for: destination))
                }
                store.reload()
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

import AVKit
import SwiftUI
import UIKit

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var playing: PlayItem?
    @State private var renaming: LibraryItem?
    @State private var newName = ""
    @State private var search = ""
    @State private var toast: String?
    @State private var pendingDelete: LibraryItem?

    private var filtered: [LibraryItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.items }
        return store.items.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    emptyState
                } else {
                    List {
                        Section {
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
            .sheet(item: $playing) { item in
                PlayerView(url: item.url)
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
            Text("أي فيديو تحمله بيطلع هنا.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func row(_ item: LibraryItem) -> some View {
        Button {
            if item.canPlay {
                playing = PlayItem(url: item.url)
            } else {
                show("هذي الصيغة تنفتح من المشاركة › تطبيق ثاني مثل VLC")
            }
        } label: {
            HStack(spacing: 12) {
                ThumbnailView(url: item.url)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text("\(item.url.pathExtension.uppercased()) · \(Formatters.bytes(Double(item.size))) · \(item.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
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
                    playing = PlayItem(url: item.url)
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
            Button {
                newName = item.name
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
                Image(systemName: MediaTools.isAudio(url) ? "waveform" : "film")
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

struct PlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
            .navigationTitle(url.deletingPathExtension().lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("إغلاق") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: url)
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .onAppear {
            let newPlayer = AVPlayer(url: url)
            player = newPlayer
            newPlayer.play()
        }
        .onDisappear {
            player?.pause()
        }
    }
}

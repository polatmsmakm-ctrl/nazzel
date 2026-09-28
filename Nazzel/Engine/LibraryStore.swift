import Foundation
import SwiftUI

struct LibraryItem: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let date: Date
    let meta: MediaMeta?

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var isVideo: Bool { MediaTools.isVideo(url) }
    var isAudio: Bool { MediaTools.isAudio(url) }
    var isImage: Bool { MediaTools.isImage(url) }
    var canPlay: Bool { MediaTools.isPlayable(url) }

    /// The real title (from the site) instead of the file name when we know it.
    var displayTitle: String {
        if let title = meta?.title, !title.isEmpty { return title }
        return name.replacingOccurrences(of: #"\s*\[[^\]]+\]$"#, with: "", options: .regularExpression)
    }

    var kindLabel: String {
        if isImage { return "صورة" }
        if isAudio { return "صوت" }
        if isVideo { return url.pathExtension.lowercased() == "ts" ? "فيديو TS" : "فيديو" }
        return url.pathExtension.uppercased()
    }
}

/// Lists finished downloads (the Documents folder).
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var items: [LibraryItem] = []
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    func reload() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Paths.downloads, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        items = urls.compactMap { url -> LibraryItem? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return nil }
            guard !url.lastPathComponent.hasSuffix(".part") else { return nil }
            let meta = MediaIndex.shared.meta(for: url)
            return LibraryItem(url: url,
                               size: Int64(values?.fileSize ?? 0),
                               date: meta?.added ?? values?.contentModificationDate ?? .distantPast,
                               meta: meta)
        }
        .sorted { $0.date > $1.date }
    }

    func delete(_ item: LibraryItem) {
        PlayerController.shared.fileRemoved(item.url)
        try? FileManager.default.removeItem(at: item.url)
        MediaIndex.shared.remove(item.url)
        reload()
    }

    func rename(_ item: LibraryItem, to newName: String) {
        let cleaned = Paths.sanitize(newName)
        guard !cleaned.isEmpty else { return }
        let target = Paths.uniqueDestination(for: cleaned + "." + item.url.pathExtension, in: Paths.downloads)
        PlayerController.shared.fileRemoved(item.url)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            MediaIndex.shared.rename(from: item.url, to: target)
            var meta = MediaIndex.shared.meta(for: target) ?? MediaMeta()
            meta.title = newName
            MediaIndex.shared.set(meta, for: target)
        } catch {}
        reload()
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

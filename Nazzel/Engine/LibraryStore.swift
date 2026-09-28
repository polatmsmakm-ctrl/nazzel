import Foundation
import SwiftUI

struct LibraryItem: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let date: Date

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var isVideo: Bool { MediaTools.isVideo(url) }
    var isAudio: Bool { MediaTools.isAudio(url) }
    var canPlay: Bool { ["mp4", "mov", "m4v", "m4a", "mp3", "aac", "wav"].contains(url.pathExtension.lowercased()) }
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
            return LibraryItem(url: url,
                               size: Int64(values?.fileSize ?? 0),
                               date: values?.contentModificationDate ?? .distantPast)
        }
        .sorted { $0.date > $1.date }
    }

    func delete(_ item: LibraryItem) {
        try? FileManager.default.removeItem(at: item.url)
        reload()
    }

    func rename(_ item: LibraryItem, to newName: String) {
        let cleaned = Paths.sanitize(newName)
        guard !cleaned.isEmpty else { return }
        let target = Paths.uniqueDestination(for: cleaned + "." + item.url.pathExtension, in: Paths.downloads)
        try? FileManager.default.moveItem(at: item.url, to: target)
        reload()
    }

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

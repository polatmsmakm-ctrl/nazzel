import Foundation
import SwiftUI

struct LibraryItem: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let date: Date
    let meta: MediaMeta?
    /// Has "<name>.<lang>.vtt" files next to it.
    var hasSubtitles = false

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
        if url.pathExtension.lowercased() == "m4r" { return "نغمة" }
        if isAudio { return "صوت" }
        if isVideo { return url.pathExtension.lowercased() == "ts" ? "فيديو TS" : "فيديو" }
        return url.pathExtension.uppercased()
    }
}

struct LibraryFolder: Identifiable, Hashable {
    let url: URL
    let count: Int
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// Lists finished downloads (the Documents folder and the folders you make inside it).
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    /// What is in the top folder (kept for the rest of the app).
    @Published private(set) var items: [LibraryItem] = []
    @Published private(set) var folders: [LibraryFolder] = []
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    var root: URL { Paths.downloads }

    func reload() {
        let listing = contents(of: root)
        items = listing.items
        folders = listing.folders
    }

    /// Files and folders inside `folder` (subtitle files travel with their video and are not listed).
    func contents(of folder: URL) -> (folders: [LibraryFolder], items: [LibraryItem]) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var folders: [LibraryFolder] = []
        var items: [LibraryItem] = []
        // "<stem>.<lang>.vtt" → stems that have subtitles
        let subtitleStems = Set(urls.filter(Subtitles.isSubtitle).map {
            $0.deletingPathExtension().deletingPathExtension().lastPathComponent
        })
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                let inside = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
                let count = inside.filter { !$0.hasPrefix(".") && !Subtitles.isSubtitle(URL(fileURLWithPath: $0)) }.count
                folders.append(LibraryFolder(url: url, count: count))
                continue
            }
            guard values?.isRegularFile == true,
                  !url.lastPathComponent.hasSuffix(".part"),
                  !Subtitles.isSubtitle(url) else { continue }
            let meta = MediaIndex.shared.meta(for: url)
            items.append(LibraryItem(url: url,
                                     size: Int64(values?.fileSize ?? 0),
                                     date: meta?.added ?? values?.contentModificationDate ?? .distantPast,
                                     meta: meta,
                                     hasSubtitles: subtitleStems.contains(url.deletingPathExtension().lastPathComponent)))
        }
        return (folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                items.sorted { $0.date > $1.date })
    }

    func delete(_ item: LibraryItem) {
        PlayerController.shared.fileRemoved(item.url)
        Subtitles.delete(for: item.url)
        try? FileManager.default.removeItem(at: item.url)
        MediaIndex.shared.remove(item.url)
        changed()
    }

    func rename(_ item: LibraryItem, to newName: String) {
        let cleaned = Paths.sanitize(newName)
        guard !cleaned.isEmpty else { return }
        let folder = item.url.deletingLastPathComponent()
        let target = Paths.uniqueDestination(for: cleaned + "." + item.url.pathExtension, in: folder)
        PlayerController.shared.fileRemoved(item.url)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
            Subtitles.move(from: item.url, to: target)
            MediaIndex.shared.rename(from: item.url, to: target)
            var meta = MediaIndex.shared.meta(for: target) ?? MediaMeta()
            meta.title = newName
            MediaIndex.shared.set(meta, for: target)
        } catch {}
        changed()
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(named name: String, in parent: URL? = nil) -> URL? {
        let cleaned = Paths.sanitize(name)
        guard !cleaned.isEmpty else { return nil }
        let folder = Paths.uniqueDestination(for: cleaned, in: parent ?? root)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        changed()
        return folder
    }

    /// Moves a file (and its subtitles, cover art, and saved position) into another folder.
    @discardableResult
    func move(_ item: LibraryItem, to folder: URL) -> URL? {
        guard item.url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL else { return item.url }
        let target = Paths.uniqueDestination(for: item.url.lastPathComponent, in: folder)
        PlayerController.shared.fileRemoved(item.url)
        do {
            try FileManager.default.moveItem(at: item.url, to: target)
        } catch {
            return nil
        }
        Subtitles.move(from: item.url, to: target)
        if target.lastPathComponent != item.url.lastPathComponent {
            MediaIndex.shared.rename(from: item.url, to: target)
        }
        changed()
        return target
    }

    func renameFolder(_ folder: LibraryFolder, to name: String) {
        let cleaned = Paths.sanitize(name)
        guard !cleaned.isEmpty, cleaned != folder.name else { return }
        let target = Paths.uniqueDestination(for: cleaned, in: folder.url.deletingLastPathComponent())
        try? FileManager.default.moveItem(at: folder.url, to: target)
        changed()
    }

    /// Deletes a folder and everything in it.
    func deleteFolder(_ folder: LibraryFolder) {
        let files = FileManager.default.enumerator(at: folder.url, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        for file in files {
            PlayerController.shared.fileRemoved(file)
            MediaIndex.shared.remove(file)
        }
        try? FileManager.default.removeItem(at: folder.url)
        changed()
    }

    /// Every folder (for "move to…"), top folder first.
    func allFolders() -> [URL] {
        var out = [root]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                out.append(url)
            }
        }
        return out
    }

    func displayName(of folder: URL) -> String {
        folder.standardizedFileURL == root.standardizedFileURL ? "الملفات" : folder.lastPathComponent
    }

    // MARK: - Sizes

    var totalSize: Int64 { Self.size(of: root) }

    nonisolated static func size(of folder: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    /// The biggest files anywhere in the library (for cleaning up space).
    func largestFiles(limit: Int = 20) -> [LibraryItem] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles]) else { return [] }
        var found: [LibraryItem] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, !Subtitles.isSubtitle(url) else { continue }
            found.append(LibraryItem(url: url, size: Int64(values?.fileSize ?? 0),
                                     date: values?.contentModificationDate ?? .distantPast,
                                     meta: MediaIndex.shared.meta(for: url)))
        }
        return Array(found.sorted { $0.size > $1.size }.prefix(limit))
    }

    private func changed() {
        reload()
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
    }
}

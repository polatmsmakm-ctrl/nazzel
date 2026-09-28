import Foundation
import UIKit

/// What we know about each downloaded file (title, channel, source link) plus its cover art.
struct MediaMeta: Codable, Hashable {
    var title: String?
    var uploader: String?
    var source: String?
    var added: Date = Date()
}

@MainActor
final class MediaIndex {
    static let shared = MediaIndex()

    private var entries: [String: MediaMeta] = [:]
    private var indexURL: URL { Paths.support.appendingPathComponent("library.json") }

    private init() {
        Paths.ensure()
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: MediaMeta].self, from: data) {
            entries = decoded
        }
    }

    func meta(for url: URL) -> MediaMeta? { entries[url.lastPathComponent] }

    func set(_ meta: MediaMeta, for url: URL) {
        entries[url.lastPathComponent] = meta
        save()
    }

    func rename(from old: URL, to new: URL) {
        if let meta = entries.removeValue(forKey: old.lastPathComponent) {
            entries[new.lastPathComponent] = meta
            save()
        }
        let oldArt = Self.artworkURL(for: old)
        if FileManager.default.fileExists(atPath: oldArt.path) {
            try? FileManager.default.moveItem(at: oldArt, to: Self.artworkURL(for: new))
        }
        ResumeStore.move(from: old, to: new)
    }

    func remove(_ url: URL) {
        entries.removeValue(forKey: url.lastPathComponent)
        save()
        try? FileManager.default.removeItem(at: Self.artworkURL(for: url))
        ResumeStore.clear(url)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    // MARK: artwork

    nonisolated static func artworkURL(for media: URL) -> URL {
        Paths.artwork.appendingPathComponent(Paths.sanitize(media.lastPathComponent) + ".jpg")
    }

    /// Stores yt-dlp's thumbnail (webp/jpg/png) as a JPEG next to the library.
    nonisolated static func storeArtwork(from imagePath: String, for media: URL) {
        guard let image = UIImage(contentsOfFile: imagePath) else { return }
        let maxSide: CGFloat = 900
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        if let data = resized.jpegData(compressionQuality: 0.85) {
            try? data.write(to: artworkURL(for: media), options: .atomic)
        }
    }
}

/// Remembers where you stopped in long videos and audio.
enum ResumeStore {
    private static let key = "resumePositions"

    static func position(for url: URL) -> Double? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[url.lastPathComponent]
    }

    static func save(_ seconds: Double, for url: URL) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        all[url.lastPathComponent] = seconds
        if all.count > 300 { all.removeValue(forKey: all.keys.first!) }
        UserDefaults.standard.set(all, forKey: key)
    }

    static func clear(_ url: URL) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        all.removeValue(forKey: url.lastPathComponent)
        UserDefaults.standard.set(all, forKey: key)
    }

    static func move(from old: URL, to new: URL) {
        if let value = position(for: old) {
            clear(old)
            save(value, for: new)
        }
    }
}

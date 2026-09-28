import Foundation

/// Where everything lives inside the app container.
enum Paths {
    private static let fm = FileManager.default

    /// Finished downloads. Visible in the Files app under "On My iPhone › نزّل".
    static var downloads: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Private app data (engine updates, cookies). Not visible in Files.
    static var support: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nazzel", isDirectory: true)
    }

    static var caches: URL {
        fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nazzel", isDirectory: true)
    }

    static var engine: URL { support.appendingPathComponent("engine", isDirectory: true) }
    static var cookies: URL { support.appendingPathComponent("cookies.txt") }
    static var work: URL { caches.appendingPathComponent("work", isDirectory: true) }
    static var pycache: URL { caches.appendingPathComponent("pycache", isDirectory: true) }
    static var thumbnails: URL { caches.appendingPathComponent("thumbs", isDirectory: true) }
    static var artwork: URL { support.appendingPathComponent("artwork", isDirectory: true) }

    static func ensure() {
        for dir in [downloads, support, caches, engine, work, pycache, thumbnails, artwork] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        var supportURL = support
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? supportURL.setResourceValues(values)
    }

    /// A file name that does not collide with anything already in `folder`.
    static func uniqueDestination(for name: String, in folder: URL) -> URL {
        let cleaned = sanitize(name)
        let ext = (cleaned as NSString).pathExtension
        let stem = (cleaned as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent(cleaned)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let parts = name.components(separatedBy: bad)
        var out = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasPrefix(".") { out.removeFirst() }
        return out.isEmpty ? "video" : out
    }
}

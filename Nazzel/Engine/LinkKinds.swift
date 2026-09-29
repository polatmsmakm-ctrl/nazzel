import Foundation

/// Small helpers that look at a link (or what the user typed) before anything is downloaded.
enum LinkKinds {
    /// A playlist, a channel or a feed: the user picks which videos to download.
    static func isCollection(_ link: String) -> Bool {
        guard let url = URL(string: link), let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        if host.hasSuffix("youtube.com") {
            if path.hasPrefix("/playlist") { return true }
            if path.hasPrefix("/@") || path.hasPrefix("/channel/") || path.hasPrefix("/c/") || path.hasPrefix("/user/") {
                // a single video on a channel page is still a video
                return !path.contains("/shorts/") && !path.contains("/watch")
            }
            return false
        }
        if host.hasSuffix("soundcloud.com"), path.contains("/sets/") { return true }
        return path.hasSuffix(".rss") || path.hasSuffix(".xml") || path.hasSuffix("/feed")
    }

    /// A single video that also names a playlist (…watch?v=X&list=Y): ask which one they mean.
    static func playlistInsideVideo(_ link: String) -> String? {
        guard let components = URLComponents(string: link),
              let host = components.host?.lowercased(), host.hasSuffix("youtube.com") || host == "youtu.be",
              let list = components.queryItems?.first(where: { $0.name == "list" })?.value, !list.isEmpty,
              components.queryItems?.contains(where: { $0.name == "v" }) == true || host == "youtu.be",
              !list.hasPrefix("RD")   // "mixes" never end
        else { return nil }
        return "https://www.youtube.com/playlist?list=\(list)"
    }

    /// "@name" typed in the link box → an Instagram account.
    static func instagramHandle(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("@"), trimmed.count > 1, !trimmed.contains(" "), !trimmed.contains("/") else { return nil }
        let name = String(trimmed.dropFirst())
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return name
    }

    static func instagramStories(_ handle: String) -> String { "https://www.instagram.com/stories/\(handle)/" }
    static func instagramHighlights(_ handle: String) -> String { "https://www.instagram.com/\(handle)/highlights/" }

    /// "1:30", "01:02:03", "90" → seconds.
    static func parseTime(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "٫", with: ".")
            .replacingOccurrences(of: "٬", with: "")
        let digits = cleaned.map { char -> Character in
            // Arabic-Indic digits (٠١٢…) → 0-9
            if let value = char.wholeNumberValue, !char.isASCII { return Character(String(value)) }
            return char
        }
        let parts = String(digits).split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    static func formatTime(_ seconds: Double) -> String {
        Formatters.duration(seconds)
    }
}

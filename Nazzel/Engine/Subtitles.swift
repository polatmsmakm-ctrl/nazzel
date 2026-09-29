import Foundation

/// One line of a subtitle file, shown from `start` to `end` (seconds).
struct SubtitleCue: Equatable {
    let start: Double
    let end: Double
    let text: String
}

/// A subtitle language available for what is playing.
struct SubtitleTrack: Identifiable, Hashable {
    let lang: String
    /// Local sidecar file, or a web address for streams.
    let url: URL

    var id: String { lang }
    var displayName: String { Subtitles.languageName(lang) }
}

/// Subtitles live next to the video as "<video name>.<lang>.vtt" (like most players expect),
/// so they show up together in the Files app and move / rename / delete with the video.
enum Subtitles {
    static let extensions: Set<String> = ["vtt", "srt"]

    static func isSubtitle(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    /// "<stem>.<lang>.vtt" files sitting next to `media`.
    static func sidecars(for media: URL) -> [SubtitleTrack] {
        let folder = media.deletingLastPathComponent()
        let stem = media.deletingPathExtension().lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var tracks: [SubtitleTrack] = []
        for name in names.sorted() where name.hasPrefix(stem + ".") {
            let url = folder.appendingPathComponent(name)
            guard isSubtitle(url) else { continue }
            let middle = String(name.dropFirst(stem.count + 1)).components(separatedBy: ".").dropLast().joined(separator: ".")
            guard !middle.isEmpty, !tracks.contains(where: { $0.lang == middle }) else { continue }
            tracks.append(SubtitleTrack(lang: middle, url: url))
        }
        return sortedByPreference(tracks)
    }

    /// Arabic first, then English, then the rest.
    static func sortedByPreference(_ tracks: [SubtitleTrack]) -> [SubtitleTrack] {
        func rank(_ lang: String) -> Int {
            let base = lang.lowercased()
            if base == "ar" || base.hasPrefix("ar-") || base.hasPrefix("ar_") { return 0 }
            if base == "en" || base.hasPrefix("en-") || base.hasPrefix("en_") { return 1 }
            return 2
        }
        return tracks.sorted { (rank($0.lang), $0.lang) < (rank($1.lang), $1.lang) }
    }

    /// Moves the subtitle files that belong to `old` so they follow the video to `new`.
    static func move(from old: URL, to new: URL) {
        let fm = FileManager.default
        for track in sidecars(for: old) {
            let target = new.deletingLastPathComponent()
                .appendingPathComponent(new.deletingPathExtension().lastPathComponent + ".\(track.lang).\(track.url.pathExtension)")
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: track.url, to: target)
        }
    }

    static func copy(from old: URL, to new: URL) {
        let fm = FileManager.default
        for track in sidecars(for: old) {
            let target = new.deletingLastPathComponent()
                .appendingPathComponent(new.deletingPathExtension().lastPathComponent + ".\(track.lang).\(track.url.pathExtension)")
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: track.url, to: target)
        }
    }

    static func delete(for media: URL) {
        for track in sidecars(for: media) {
            try? FileManager.default.removeItem(at: track.url)
        }
    }

    /// Places a downloaded subtitle file next to the final video.
    static func attach(_ file: URL, lang: String, to media: URL) {
        let ext = file.pathExtension.isEmpty ? "vtt" : file.pathExtension
        let safeLang = Paths.sanitize(lang).replacingOccurrences(of: " ", with: "_")
        let target = media.deletingLastPathComponent()
            .appendingPathComponent(media.deletingPathExtension().lastPathComponent + ".\(safeLang).\(ext)")
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: file, to: target)
    }

    static func languageName(_ code: String) -> String {
        let base = code.components(separatedBy: CharacterSet(charactersIn: "-_")).first ?? code
        let name = Locale(identifier: "ar").localizedString(forLanguageCode: base) ?? code
        return code.lowercased().contains("orig") ? name + " (الأصلية)" : name
    }

    // MARK: - Parsing (WebVTT and SRT)

    static func parse(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = seconds(parts[0]),
                  let end = seconds(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "")
            else { continue }
            let body = lines[(timing + 1)...].map(clean).filter { !$0.isEmpty }
            guard !body.isEmpty else { continue }
            let joined = body.joined(separator: "\n")
            // YouTube's automatic captions repeat the previous line while the next one types in
            if let last = cues.last, last.text == joined, abs(last.end - start) < 0.05 {
                cues[cues.count - 1] = SubtitleCue(start: last.start, end: end, text: joined)
            } else {
                cues.append(SubtitleCue(start: start, end: end, text: joined))
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func load(_ url: URL) -> [SubtitleCue] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return parse(text)
    }

    /// The cue to show at `time` (binary search; cues are sorted by start).
    static func cue(in cues: [SubtitleCue], at time: Double) -> SubtitleCue? {
        var low = 0, high = cues.count - 1, found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let index = found else { return nil }
        // a few cues can overlap: take the latest one that still covers `time`
        var i = index
        while i >= 0, i >= index - 3 {
            if cues[i].end > time { return cues[i] }
            i -= 1
        }
        return nil
    }

    /// "00:01:02.500", "01:02.500" or "00:01:02,500" (SRT).
    static func seconds(_ raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = text.components(separatedBy: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    private static func clean(_ line: String) -> String {
        // drop tags like <c>, <00:00:01.000>, <i>, {\an8} and cue settings
        var out = line.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        return out.trimmingCharacters(in: .whitespaces)
    }
}

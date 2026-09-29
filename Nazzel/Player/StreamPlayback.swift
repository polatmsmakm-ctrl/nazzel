import AVFoundation
import Foundation
import UIKit

/// What the engine found for "play without downloading".
struct StreamInfo {
    enum Kind: String {
        case hls, file, pair, audio
    }

    let kind: Kind
    let url: URL?
    let videoURL: URL?
    let audioURL: URL?
    let headers: [String: String]
    let pageURL: URL
    let id: String
    let title: String
    let uploader: String?
    let thumbnail: URL?
    let duration: Double?
    let isLive: Bool
    let subtitles: [SubtitleTrack]

    var hasVideo: Bool { kind != .audio }

    init?(_ result: [String: Any], page: String) {
        guard let raw = result["kind"] as? String, let kind = Kind(rawValue: raw) else { return nil }
        self.kind = kind
        url = (result["url"] as? String).flatMap(URL.init(string:))
        videoURL = (result["video"] as? String).flatMap(URL.init(string:))
        audioURL = (result["audio"] as? String).flatMap(URL.init(string:))
        headers = result["headers"] as? [String: String] ?? [:]
        let pageText = result["webpage_url"] as? String ?? page
        pageURL = URL(string: pageText) ?? URL(string: page) ?? URL(fileURLWithPath: "/stream")
        id = (result["id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? pageText
        title = (result["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "فيديو"
        uploader = result["uploader"] as? String
        thumbnail = (result["thumbnail"] as? String).flatMap(URL.init(string:))
        duration = (result["duration"] as? NSNumber)?.doubleValue
        isLive = result["is_live"] as? Bool ?? false
        let subs = (result["subtitles"] as? [[String: Any]] ?? []).compactMap { entry -> SubtitleTrack? in
            guard let lang = entry["lang"] as? String, let link = entry["url"] as? String,
                  let url = URL(string: link) else { return nil }
            return SubtitleTrack(lang: lang, url: url)
        }
        subtitles = Subtitles.sortedByPreference(subs)
        switch kind {
        case .pair:
            if videoURL == nil || audioURL == nil { return nil }
        default:
            if url == nil { return nil }
        }
    }

    /// A stable key for "continue where you stopped".
    var resumeKey: URL { URL(fileURLWithPath: "/stream/" + Paths.sanitize(id)) }

    /// Builds the item the shared AVPlayer plays.
    func makeItem() async throws -> AVPlayerItem {
        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        switch kind {
        case .hls, .file, .audio:
            guard let url else { throw MediaError.exportFailed("no url") }
            return AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        case .pair:
            // Separate picture and sound (how most sites send HD): join them on the fly.
            guard let videoURL, let audioURL else { throw MediaError.exportFailed("no url") }
            let video = AVURLAsset(url: videoURL, options: options)
            let audio = AVURLAsset(url: audioURL, options: options)
            async let videoTracks = video.loadTracks(withMediaType: .video)
            async let audioTracks = audio.loadTracks(withMediaType: .audio)
            async let videoLength = video.load(.duration)
            guard let videoTrack = try await videoTracks.first else { throw MediaError.noVideoTrack }
            let length = try await videoLength
            let composition = AVMutableComposition()
            if let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: videoTrack, at: .zero)
                track.preferredTransform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
            }
            if let audioTrack = try await audioTracks.first,
               let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let audioLength = (try? await audio.load(.duration)) ?? length
                try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(length, audioLength)),
                                          of: audioTrack, at: .zero)
            }
            return AVPlayerItem(asset: composition)
        }
    }
}

/// "Play in Nazzel": asks the engine for a playable address and hands it to the player.
@MainActor
enum StreamLauncher {
    static var subtitleLanguages: [String] {
        (UserDefaults.standard.object(forKey: "downloadSubtitles") as? Bool ?? true) ? ["ar", "en"] : []
    }

    /// Returns an error message to show, or nil when it is playing.
    static func play(_ link: String, audioOnly: Bool = false, openPlayer: Bool = true) async -> String? {
        let result = await PythonEngine.shared.callAsync("stream", [
            "url": link,
            "cookies": Paths.cookies.path,
            "av1": DeviceCaps.av1,
            "audio": audioOnly,
            "subtitles": subtitleLanguages,
        ])
        guard result["ok"] as? Bool == true else {
            return result["error"] as? String ?? "ما قدرت أشغّل هذا الرابط"
        }
        guard let info = StreamInfo(result, page: link) else {
            return "ما لقيت نسخة يقدر الآيفون يشغلها مباشرة. جرب التحميل بدالها."
        }
        do {
            try await PlayerController.shared.playStream(info, audioOnly: audioOnly)
        } catch {
            return "ما قدرت أشغّل الفيديو: \(error.localizedDescription)"
        }
        if openPlayer, info.hasVideo, !audioOnly {
            PlayerController.shared.showFullPlayer = true
        }
        return nil
    }
}

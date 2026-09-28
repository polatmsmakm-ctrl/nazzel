import AVFoundation
import Photos
import UIKit

enum MediaError: LocalizedError {
    case noVideoTrack
    case exportFailed(String?)
    case photosDenied
    case notCompatible

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "ما لقيت مسار فيديو في الملف"
        case .exportFailed(let reason): return "تعذر تجهيز الملف" + (reason.map { ": \($0)" } ?? "")
        case .photosDenied: return "ما عندي إذن أحفظ في الصور. فعّله من الإعدادات › نزّل › الصور"
        case .notCompatible: return "صيغة الملف ما تنحفظ في الصور، بس تقدر تشغله وتشاركه من الملفات"
        }
    }
}

/// Native media processing, replacing what ffmpeg does on a computer.
enum MediaTools {
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "ts", "3gp"]
    static let audioExtensions: Set<String> = ["m4a", "mp3", "aac", "opus", "ogg", "wav", "flac", "weba"]

    static func isVideo(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }
    static func isAudio(_ url: URL) -> Bool { audioExtensions.contains(url.pathExtension.lowercased()) }

    static func hasTrack(_ url: URL, _ type: AVMediaType) async -> Bool {
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: type)) ?? []
        return !tracks.isEmpty
    }

    /// Combines a video-only file and an audio-only file into one MP4 without re-encoding.
    static func merge(video: URL, audio: URL, output: URL) async throws -> URL {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)

        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw MediaError.noVideoTrack
        }
        let videoDuration = try await videoAsset.load(.duration)
        guard let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaError.exportFailed("video track")
        }
        try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)
        compVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

        if let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) {
            let audioDuration = try await audioAsset.load(.duration)
            let duration = CMTimeMinimum(videoDuration, audioDuration)
            try compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
        }

        return try await export(composition, to: output, audioOnly: false)
    }

    /// Rewraps any file AVFoundation can read (e.g. MPEG-TS from HLS) into MP4.
    static func remux(_ input: URL, output: URL) async throws -> URL {
        let asset = AVURLAsset(url: input)
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
            throw MediaError.noVideoTrack
        }
        return try await export(asset, to: output, audioOnly: false)
    }

    /// Keeps only the sound as M4A.
    static func extractAudio(_ input: URL, output: URL) async throws -> URL {
        let asset = AVURLAsset(url: input)
        return try await export(asset, to: output, audioOnly: true)
    }

    private static func export(_ asset: AVAsset, to output: URL, audioOnly: Bool) async throws -> URL {
        let attempts: [(preset: String, type: AVFileType, ext: String)] = audioOnly
            ? [(AVAssetExportPresetAppleM4A, .m4a, "m4a")]
            : [(AVAssetExportPresetPassthrough, .mp4, "mp4"),
               (AVAssetExportPresetPassthrough, .mov, "mov"),
               (AVAssetExportPresetHighestQuality, .mp4, "mp4")]

        var lastReason: String?
        for attempt in attempts {
            let destination = output.deletingPathExtension().appendingPathExtension(attempt.ext)
            try? FileManager.default.removeItem(at: destination)
            guard let session = AVAssetExportSession(asset: asset, presetName: attempt.preset) else { continue }
            session.outputURL = destination
            session.outputFileType = attempt.type
            session.shouldOptimizeForNetworkUse = true
            await session.export()
            if session.status == .completed, FileManager.default.fileExists(atPath: destination.path) {
                return destination
            }
            lastReason = session.error?.localizedDescription
        }
        throw MediaError.exportFailed(lastReason)
    }

    static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let time = try? await asset.load(.duration), time.isNumeric else { return nil }
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// Thumbnail for the library, cached on disk.
    static func thumbnail(for url: URL, maxSize: CGFloat = 240) async -> UIImage? {
        let key = Paths.sanitize(url.lastPathComponent) + "-\(Int(maxSize)).jpg"
        let cacheURL = Paths.thumbnails.appendingPathComponent(key)
        if let data = try? Data(contentsOf: cacheURL), let image = UIImage(data: data) {
            return image
        }
        guard isVideo(url) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        let image = UIImage(cgImage: cgImage)
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: cacheURL)
        }
        return image
    }
}

enum PhotoSaver {
    static func canSave(_ url: URL) -> Bool {
        MediaTools.isVideo(url) && UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path)
    }

    static func save(_ url: URL) async throws {
        guard canSave(url) else { throw MediaError.notCompatible }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw MediaError.photosDenied }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            options.originalFilename = url.lastPathComponent
            request.addResource(with: .video, fileURL: url, options: options)
        }
    }
}

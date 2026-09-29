import AVFoundation
import UIKit

struct VideoFrame {
    let seconds: Double
    let jpeg: Data
}

/// Pulls the distinct "slides" out of a lesson video: samples it regularly and
/// keeps a frame only when the picture has changed from the last kept one.
enum FrameExtractor {
    static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        let d = (try? await asset.load(.duration).seconds) ?? 0
        return d.isFinite ? d : 0
    }

    static func frames(from url: URL,
                       maxFrames: Int = 60,
                       progress: @escaping @MainActor (Double) -> Void) async throws -> [VideoFrame] {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw AppError.message("ما قدرت أقرأ الفيديو. جرّب فيديو ثاني.")
        }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1000, height: 1000)
        let tol = CMTime(seconds: 0.2, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol

        // Sample every ~0.7s, but never more than 300 samples for long videos.
        let step = max(0.7, duration / 300)
        var t = min(0.3, duration / 2)
        var kept: [(Double, CGImage)] = []
        var lastSig: [UInt8]?

        while t < duration {
            try Task.checkCancellation()
            if let cg = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                let sig = signature(cg)
                if let last = lastSig, difference(last, sig) < 2.2 {
                    // Same slide as before; skip.
                } else {
                    kept.append((t, cg))
                    lastSig = sig
                }
            }
            let p = min(1, t / duration)
            await progress(p)
            t += step
        }

        if kept.isEmpty {
            throw AppError.message("ما قدرت أطلع صور من الفيديو.")
        }

        // Thin out evenly if there are too many (e.g. long animated clips).
        var chosen = kept
        if chosen.count > maxFrames {
            chosen = (0..<maxFrames).map { i in
                kept[Int(Double(i) * Double(kept.count) / Double(maxFrames))]
            }
        }

        return chosen.compactMap { (sec, cg) in
            guard let data = jpeg(cg, maxSide: 720) else { return nil }
            return VideoFrame(seconds: sec, jpeg: data)
        }
    }

    private static func jpeg(_ cg: CGImage, maxSide: CGFloat) -> Data? {
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxSide / max(w, h))
        let size = CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: size))
        }
        return img.jpegData(compressionQuality: 0.6)
    }

    /// A tiny grayscale thumbnail used to tell whether two frames show the same slide.
    private static func signature(_ cg: CGImage) -> [UInt8] {
        let w = 32, h = 32
        var px = [UInt8](repeating: 0, count: w * h)
        px.withUnsafeMutableBytes { buf in
            if let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: w,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                ctx.interpolationQuality = .medium
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return px
    }

    private static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var sum = 0
        for i in 0..<min(a.count, b.count) {
            sum += abs(Int(a[i]) - Int(b[i]))
        }
        return Double(sum) / Double(max(1, a.count))
    }
}

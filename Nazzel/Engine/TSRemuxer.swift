import AVFoundation
import CoreMedia
import Foundation

/// Rewraps an MPEG-TS file (what HLS streams download as) into MP4 without re-encoding.
///
/// AVFoundation cannot open .ts files, and iOS has no ffmpeg, so this parses the transport
/// stream itself: H.264 video + AAC audio, the codecs HLS uses almost everywhere.
enum TSRemuxer {
    enum RemuxError: LocalizedError {
        case notTransportStream, unsupportedCodec(String), noVideo, writer(String)

        var errorDescription: String? {
            switch self {
            case .notTransportStream: return "not an MPEG-TS file"
            case .unsupportedCodec(let c): return "unsupported codec \(c)"
            case .noVideo: return "no H.264 video found"
            case .writer(let m): return m
            }
        }
    }

    /// What happened during the last remux (printed by the self-test).
    nonisolated(unsafe) static var lastDiagnostics = ""

    /// AAC decoder config can be described three ways; the writer accepts different ones
    /// on different iOS versions, so try each until the audio track comes out.
    static func remux(_ input: URL, to output: URL) async throws -> URL {
        var notes: [String] = []
        for cookieMode in 0..<3 {
            do {
                let (url, hadAudio, diagnostics) = try await Task.detached(priority: .userInitiated) {
                    let remuxer = Remuxer(input: input, output: output, cookieMode: cookieMode)
                    let url = try remuxer.run()
                    return (url, remuxer.hadAudio, remuxer.diagnostics)
                }.value
                notes.append("cookie\(cookieMode): " + diagnostics.joined(separator: ", "))
                let audioWritten = hadAudio ? await MediaTools.hasTrack(url, .audio) : true
                if audioWritten {
                    lastDiagnostics = notes.joined(separator: " | ")
                    return url
                }
                try? FileManager.default.removeItem(at: url)
            } catch {
                notes.append("cookie\(cookieMode) error: \(error.localizedDescription)")
            }
        }
        lastDiagnostics = notes.joined(separator: " | ")
        throw RemuxError.writer("audio track could not be written")
    }
}

private final class Remuxer {
    private struct Pending {
        var data = Data()
        var pts: Int64?
        var dts: Int64?
    }

    private struct VideoSample {
        let avcc: Data
        let pts: Int64
        let dts: Int64
        let keyframe: Bool
    }

    private struct AudioFrame {
        let payload: Data
        let pts: CMTime
    }

    private let input: URL
    private let output: URL
    private let cookieMode: Int
    private(set) var hadAudio = false
    private(set) var diagnostics: [String] = []
    private var audioAppended = 0
    private var audioFailed = 0
    private var videoAppended = 0

    private var pmtPID: Int?
    private var videoPID: Int?
    private var audioPID: Int?
    private var videoType = 0
    private var audioType = 0
    private var pes: [Int: Pending] = [:]

    private var sps: Data?
    private var pps: Data?
    private var videoFormat: CMVideoFormatDescription?
    private var audioFormat: CMAudioFormatDescription?
    private var audioSampleRate = 44100
    private var audioCarry = Data()
    private var nextAudioPTS: CMTime?

    private var videoQueue: [VideoSample] = []
    private var audioQueue: [AudioFrame] = []

    init(input: URL, output: URL, cookieMode: Int) {
        self.input = input
        self.output = output
        self.cookieMode = cookieMode
    }

    func run() throws -> URL {
        let handle = try FileHandle(forReadingFrom: input)
        defer { try? handle.close() }
        try? FileManager.default.removeItem(at: output)

        var buffer = Data()
        var eof = false
        var writer: AVAssetWriter?
        var videoInput: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        var sessionStarted = false
        var checkedSync = false
        var idleSpins = 0

        func readMore() throws {
            guard !eof else { return }
            let chunk = handle.readData(ofLength: 188 * 2048)
            if chunk.isEmpty {
                eof = true
                flushAll()
                return
            }
            buffer.append(chunk)
            if !checkedSync {
                checkedSync = true
                guard buffer.count >= 188, buffer[buffer.startIndex] == 0x47 else { throw TSRemuxer.RemuxError.notTransportStream }
            }
            var offset = buffer.startIndex
            while buffer.endIndex - offset >= 188 {
                if buffer[offset] != 0x47 {
                    // resync
                    offset += 1
                    continue
                }
                parsePacket(buffer[offset ..< offset + 188])
                offset += 188
            }
            buffer = Data(buffer[offset...])
        }

        while true {
            // keep a few samples of each track ready so the writer can interleave
            while !eof && (videoQueue.count < 12 || (audioPID != nil && audioQueue.count < 12)) {
                try readMore()
                if videoQueue.count > 4000 || audioQueue.count > 8000 { break }
            }

            if writer == nil {
                guard let videoFormat, !videoQueue.isEmpty else {
                    if eof { throw TSRemuxer.RemuxError.noVideo }
                    continue
                }
                let w = try AVAssetWriter(outputURL: output, fileType: .mp4)
                let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
                vIn.expectsMediaDataInRealTime = false
                guard w.canAdd(vIn) else { throw TSRemuxer.RemuxError.writer("cannot add video") }
                w.add(vIn)
                if let audioFormat {
                    let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
                    aIn.expectsMediaDataInRealTime = false
                    if w.canAdd(aIn) {
                        w.add(aIn)
                        audioInput = aIn
                    } else {
                        diagnostics.append("canAdd(audio)=false")
                    }
                } else if hadAudio {
                    diagnostics.append("audio format nil")
                }
                guard w.startWriting() else {
                    throw TSRemuxer.RemuxError.writer(w.error?.localizedDescription ?? "startWriting failed")
                }
                writer = w
                videoInput = vIn
            }

            if !sessionStarted, let writer {
                var start = CMTime(value: videoQueue.map(\.pts).min() ?? 0, timescale: 90000)
                if let firstAudio = audioQueue.first?.pts, audioInput != nil { start = CMTimeMinimum(start, firstAudio) }
                writer.startSession(atSourceTime: start)
                sessionStarted = true
            }

            var progressed = false
            if let videoInput, videoInput.isReadyForMoreMediaData, !videoQueue.isEmpty {
                let sample = videoQueue.removeFirst()
                if let buffer = makeVideoSample(sample), videoInput.append(buffer) { videoAppended += 1 }
                progressed = true
            }
            if let audioInput, audioInput.isReadyForMoreMediaData, !audioQueue.isEmpty {
                let frame = audioQueue.removeFirst()
                if let buffer = makeAudioSample(frame), audioInput.append(buffer) {
                    audioAppended += 1
                } else {
                    audioFailed += 1
                }
                progressed = true
            } else if audioInput == nil {
                audioQueue.removeAll()
            }

            if eof && videoQueue.isEmpty && audioQueue.isEmpty { break }
            if let writer, writer.status == .failed {
                throw TSRemuxer.RemuxError.writer(writer.error?.localizedDescription ?? "writer failed")
            }
            if progressed {
                idleSpins = 0
            } else {
                if !eof && (videoQueue.count < 12 || audioQueue.count < 12) {
                    try readMore()
                } else {
                    idleSpins += 1
                    if idleSpins > 7500 { throw TSRemuxer.RemuxError.writer("writer stalled") }  // ~15 s
                    usleep(2000)
                }
            }
        }

        guard let writer else { throw TSRemuxer.RemuxError.noVideo }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        diagnostics.append("video=\(videoAppended) audio=\(audioAppended) audioFailed=\(audioFailed) status=\(writer.status.rawValue)")
        guard writer.status == .completed else {
            throw TSRemuxer.RemuxError.writer(writer.error?.localizedDescription ?? "finish failed")
        }
        return output
    }

    // MARK: - Transport stream

    private func parsePacket(_ p: Data) {
        let b = [UInt8](p)
        let pusi = (b[1] & 0x40) != 0
        let pid = (Int(b[1] & 0x1F) << 8) | Int(b[2])
        let afc = (b[3] >> 4) & 0x3
        var i = 4
        if afc == 2 || afc == 3 {
            i += 1 + Int(b[4])
        }
        guard afc == 1 || afc == 3, i < 188 else { return }
        let payload = b[i...]

        if pid == 0 {
            parsePAT(Array(payload), pusi: pusi)
        } else if pid == pmtPID {
            parsePMT(Array(payload), pusi: pusi)
        } else if pid == videoPID || pid == audioPID {
            if pusi {
                flushPES(pid)
                pes[pid] = Pending()
                startPES(pid, Array(payload))
            } else if pes[pid] != nil {
                pes[pid]?.data.append(contentsOf: payload)
            }
        }
    }

    private func sectionBody(_ payload: [UInt8], pusi: Bool) -> [UInt8]? {
        guard pusi, !payload.isEmpty else { return nil }
        let pointer = Int(payload[0])
        let start = 1 + pointer
        guard payload.count > start + 3 else { return nil }
        let sectionLength = (Int(payload[start + 1] & 0x0F) << 8) | Int(payload[start + 2])
        let end = min(payload.count, start + 3 + sectionLength)
        return Array(payload[start ..< end])
    }

    private func parsePAT(_ payload: [UInt8], pusi: Bool) {
        guard pmtPID == nil, let s = sectionBody(payload, pusi: pusi), s.count >= 12 else { return }
        var i = 8
        while i + 4 <= s.count - 4 {
            let program = (Int(s[i]) << 8) | Int(s[i + 1])
            let pid = (Int(s[i + 2] & 0x1F) << 8) | Int(s[i + 3])
            if program != 0 {
                pmtPID = pid
                return
            }
            i += 4
        }
    }

    private func parsePMT(_ payload: [UInt8], pusi: Bool) {
        guard videoPID == nil, let s = sectionBody(payload, pusi: pusi), s.count >= 16 else { return }
        let programInfoLength = (Int(s[10] & 0x0F) << 8) | Int(s[11])
        var i = 12 + programInfoLength
        while i + 5 <= s.count - 4 {
            let type = Int(s[i])
            let pid = (Int(s[i + 1] & 0x1F) << 8) | Int(s[i + 2])
            let infoLength = (Int(s[i + 3] & 0x0F) << 8) | Int(s[i + 4])
            switch type {
            case 0x1B where videoPID == nil:
                videoPID = pid
                videoType = type
            case 0x0F where audioPID == nil:
                audioPID = pid
                audioType = type
            default:
                break
            }
            i += 5 + infoLength
        }
    }

    private func startPES(_ pid: Int, _ payload: [UInt8]) {
        guard payload.count >= 9, payload[0] == 0, payload[1] == 0, payload[2] == 1 else { return }
        let flags = payload[7]
        let headerLength = Int(payload[8])
        var pts: Int64?
        var dts: Int64?
        if flags & 0x80 != 0, payload.count >= 14 { pts = Self.timestamp(payload, 9) }
        if flags & 0x40 != 0, payload.count >= 19 { dts = Self.timestamp(payload, 14) }
        pes[pid]?.pts = pts
        pes[pid]?.dts = dts ?? pts
        let start = 9 + headerLength
        if start < payload.count {
            pes[pid]?.data.append(contentsOf: payload[start...])
        }
    }

    private static func timestamp(_ b: [UInt8], _ i: Int) -> Int64 {
        let a = Int64(b[i] & 0x0E) << 29
        let c = Int64(b[i + 1]) << 22 | Int64(b[i + 2] & 0xFE) << 14
        let d = Int64(b[i + 3]) << 7 | Int64(b[i + 4] >> 1)
        return a | c | d
    }

    private func flushAll() {
        for pid in Array(pes.keys) { flushPES(pid) }
    }

    private func flushPES(_ pid: Int) {
        guard let packet = pes.removeValue(forKey: pid), !packet.data.isEmpty else { return }
        if pid == videoPID {
            handleVideo(packet)
        } else if pid == audioPID {
            handleAudio(packet)
        }
    }

    // MARK: - H.264

    private func handleVideo(_ packet: Pending) {
        guard let pts = packet.pts else { return }
        var avcc = Data()
        var keyframe = false
        for nal in Self.splitAnnexB(packet.data) {
            guard let first = nal.first else { continue }
            let type = first & 0x1F
            switch type {
            case 7:
                if sps == nil { sps = nal }
                continue
            case 8:
                if pps == nil { pps = nal }
                continue
            case 9:
                continue  // access unit delimiter
            case 5:
                keyframe = true
            default:
                break
            }
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        if videoFormat == nil, let sps, let pps {
            videoFormat = Self.makeVideoFormat(sps: sps, pps: pps)
        }
        guard videoFormat != nil, !avcc.isEmpty else { return }
        videoQueue.append(VideoSample(avcc: avcc, pts: pts, dts: packet.dts ?? pts, keyframe: keyframe))
    }

    private static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let s = start {
                    var end = i
                    if end > s, bytes[end - 1] == 0 { end -= 1 }  // 4-byte start code
                    if end > s { units.append(Data(bytes[s ..< end])) }
                }
                i += 3
                start = i
                continue
            }
            i += 1
        }
        if let s = start, s < bytes.count {
            units.append(Data(bytes[s...]))
        }
        return units
    }

    private static func makeVideoFormat(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)
        let status: OSStatus = spsBytes.withUnsafeBufferPointer { spsPtr in
            ppsBytes.withUnsafeBufferPointer { ppsPtr in
                let pointers: [UnsafePointer<UInt8>] = [spsPtr.baseAddress!, ppsPtr.baseAddress!]
                let sizes: [Int] = [spsBytes.count, ppsBytes.count]
                return pointers.withUnsafeBufferPointer { pointersPtr in
                    sizes.withUnsafeBufferPointer { sizesPtr in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointersPtr.baseAddress!,
                            parameterSetSizes: sizesPtr.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &format)
                    }
                }
            }
        }
        return status == noErr ? format : nil
    }

    private func makeVideoSample(_ sample: VideoSample) -> CMSampleBuffer? {
        guard let videoFormat, let block = Self.makeBlockBuffer(sample.avcc) else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: sample.pts, timescale: 90000),
            decodeTimeStamp: CMTime(value: sample.dts, timescale: 90000))
        var size = sample.avcc.count
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: videoFormat,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { return nil }
        if !sample.keyframe,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return buffer
    }

    // MARK: - AAC (ADTS)

    private static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
                                      16000, 12000, 11025, 8000, 7350]

    private func handleAudio(_ packet: Pending) {
        var data = audioCarry
        data.append(packet.data)
        audioCarry = Data()
        let bytes = [UInt8](data)
        var i = 0
        var framePTS: CMTime? = packet.pts.map { CMTime(value: $0, timescale: 90000) } ?? nextAudioPTS
        while i + 7 <= bytes.count {
            guard bytes[i] == 0xFF, bytes[i + 1] & 0xF0 == 0xF0 else {
                i += 1
                continue
            }
            let protectionAbsent = bytes[i + 1] & 0x01
            let profile = Int((bytes[i + 2] >> 6) & 0x03)
            let rateIndex = Int((bytes[i + 2] >> 2) & 0x0F)
            let channels = Int(((bytes[i + 2] & 0x01) << 2) | ((bytes[i + 3] >> 6) & 0x03))
            let frameLength = (Int(bytes[i + 3] & 0x03) << 11) | (Int(bytes[i + 4]) << 3) | Int(bytes[i + 5] >> 5)
            let header = protectionAbsent == 1 ? 7 : 9
            guard rateIndex < Self.sampleRates.count, frameLength > header else {
                i += 1
                continue
            }
            if i + frameLength > bytes.count {
                audioCarry = Data(bytes[i...])
                break
            }
            hadAudio = true
            if audioFormat == nil {
                audioSampleRate = Self.sampleRates[rateIndex]
                audioFormat = Self.makeAudioFormat(objectType: profile + 1, rateIndex: rateIndex,
                                                   sampleRate: audioSampleRate, channels: max(1, channels),
                                                   cookieMode: cookieMode)
                if audioFormat == nil { diagnostics.append("CMAudioFormatDescriptionCreate failed") }
            }
            let payload = Data(bytes[(i + header) ..< (i + frameLength)])
            if let pts = framePTS {
                audioQueue.append(AudioFrame(payload: payload, pts: pts))
                let next = CMTimeAdd(pts, CMTime(value: 1024, timescale: CMTimeScale(audioSampleRate)))
                framePTS = next
                nextAudioPTS = next
            }
            i += frameLength
        }
    }

    private static func makeAudioFormat(objectType: Int, rateIndex: Int, sampleRate: Int, channels: Int,
                                        cookieMode: Int) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: UInt32(objectType),
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        // AudioSpecificConfig: objectType(5) | frequencyIndex(4) | channelConfig(4) | 000
        let config = UInt16(objectType << 11) | UInt16(rateIndex << 7) | UInt16(channels << 3)
        let asc: [UInt8] = [UInt8(config >> 8), UInt8(config & 0xFF)]
        var cookie: [UInt8]
        switch cookieMode {
        case 0: cookie = esds(asc)
        case 1: cookie = asc
        default: cookie = []
        }
        var format: CMAudioFormatDescription?
        let status: OSStatus
        if cookie.isEmpty {
            status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        } else {
            status = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                magicCookieSize: cookie.count, magicCookie: &cookie, extensions: nil, formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    /// MPEG-4 ES_Descriptor wrapping the AudioSpecificConfig (the 'esds' box payload).
    private static func esds(_ asc: [UInt8]) -> [UInt8] {
        let decoderSpecific: [UInt8] = [0x05, UInt8(asc.count)] + asc
        let bitrate: [UInt8] = [0x00, 0x01, 0xF4, 0x00]  // 128 kb/s (informational)
        let decoderConfigBody: [UInt8] = [0x40, 0x15, 0x00, 0x00, 0x00] + bitrate + bitrate + decoderSpecific
        let decoderConfig: [UInt8] = [0x04, UInt8(decoderConfigBody.count)] + decoderConfigBody
        let slConfig: [UInt8] = [0x06, 0x01, 0x02]
        let esBody: [UInt8] = [0x00, 0x00, 0x00] + decoderConfig + slConfig
        return [0x03, UInt8(esBody.count)] + esBody
    }

    private func makeAudioSample(_ frame: AudioFrame) -> CMSampleBuffer? {
        guard let audioFormat, let block = Self.makeBlockBuffer(frame.payload) else { return nil }
        var description = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.payload.count))
        var buffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: audioFormat,
            sampleCount: 1, presentationTimeStamp: frame.pts, packetDescriptions: &description,
            sampleBufferOut: &buffer)
        return status == noErr ? buffer : nil
    }

    // MARK: - Shared

    private static func makeBlockBuffer(_ data: Data) -> CMBlockBuffer? {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: 0, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { return nil }
        status = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: data.count)
        }
        return status == kCMBlockBufferNoErr ? block : nil
    }
}

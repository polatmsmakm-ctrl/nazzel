import AVFoundation
import AVKit
import MediaPlayer
import UIKit

/// One app-wide player: keeps playing in the background, shows on the lock screen,
/// and powers the mini bar and the full player.
@MainActor
final class PlayerController: NSObject, ObservableObject {
    static let shared = PlayerController()

    enum RepeatMode: String, CaseIterable {
        case off, all, one

        var symbol: String {
            switch self {
            case .off: return "repeat"
            case .all: return "repeat"
            case .one: return "repeat.1"
            }
        }
    }

    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    static let skipSeconds: Double = 10

    @Published private(set) var current: URL?
    @Published private(set) var queue: [URL] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var hasVideo = false
    /// width / height of the picture (vertical TikTok videos are < 1)
    @Published private(set) var videoAspect: CGFloat = 16.0 / 9.0
    @Published private(set) var artwork: UIImage?
    @Published private(set) var title = ""
    @Published private(set) var subtitle = ""
    @Published private(set) var sleepAt: Date?
    @Published private(set) var sleepAtEndOfItem = false
    @Published private(set) var isPiPActive = false
    @Published private(set) var isPiPPossible = false
    @Published var showFullPlayer = false
    @Published var repeatMode: RepeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "repeatMode") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeatMode") }
    }
    @Published var rate: Float = UserDefaults.standard.object(forKey: "playbackRate") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(rate, forKey: "playbackRate")
            player.defaultRate = rate
            if isPlaying { player.rate = rate }
            updateNowPlaying()
        }
    }

    let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var sleepTask: Task<Void, Never>?
    private var lastResumeSave = Date.distantPast
    private weak var playerLayer: AVPlayerLayer?
    private var pipController: AVPictureInPictureController?
    private var pipObservation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []

    private override init() {
        super.init()
        player.allowsExternalPlayback = true
        player.defaultRate = rate
        observePlayer()
        setupRemoteCommands()
        observeSystem()
    }

    var hasNext: Bool {
        guard let current, let index = queue.firstIndex(of: current) else { return false }
        return index + 1 < queue.count || repeatMode == .all
    }

    var progress: Double { duration > 0 ? min(1, currentTime / duration) : 0 }

    // MARK: - Playback

    func play(_ url: URL, queue newQueue: [URL]? = nil) {
        BackgroundKeeper.shared.stop()
        activateSession()
        if let newQueue, newQueue.contains(url) {
            queue = newQueue
        } else if !queue.contains(url) {
            queue = [url]
        }
        load(url, autoplay: true)
    }

    func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    func resume() {
        guard current != nil else { return }
        BackgroundKeeper.shared.stop()
        activateSession()
        if duration > 0, currentTime >= duration - 0.5 { seek(to: 0) }
        player.playImmediately(atRate: rate)
        updateNowPlaying()
    }

    func pause() {
        player.pause()
        saveResumePosition(force: true)
        updateNowPlaying()
    }

    func stop() {
        saveResumePosition(force: true)
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        queue = []
        isPlaying = false
        currentTime = 0
        duration = 0
        artwork = nil
        showFullPlayer = false
        cancelSleepTimer()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, current != nil else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    func skip(by delta: Double) {
        seek(to: currentTime + delta)
    }

    func next() {
        guard let current, let index = queue.firstIndex(of: current) else { return }
        if index + 1 < queue.count {
            load(queue[index + 1], autoplay: true)
        } else if repeatMode == .all, let first = queue.first {
            load(first, autoplay: true)
        }
    }

    func previous() {
        guard let current, let index = queue.firstIndex(of: current) else { return }
        if currentTime > 3 || index == 0 {
            seek(to: 0)
        } else {
            load(queue[index - 1], autoplay: true)
        }
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    /// Called when a file is deleted or renamed from the library.
    func fileRemoved(_ url: URL) {
        queue.removeAll { $0 == url }
        if current == url { stop() }
    }

    // MARK: - Sleep timer

    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepAt = end
        sleepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.pause()
            self.sleepAt = nil
        }
    }

    func sleepAfterCurrentItem() {
        cancelSleepTimer()
        sleepAtEndOfItem = true
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepAt = nil
        sleepAtEndOfItem = false
    }

    // MARK: - Loading

    private func load(_ url: URL, autoplay: Bool) {
        saveResumePosition(force: true)
        current = url
        currentTime = 0
        duration = 0
        artwork = nil

        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.itemEnded() }
        }
        player.replaceCurrentItem(with: item)

        let meta = MediaIndex.shared.meta(for: url)
        title = meta?.title ?? url.deletingPathExtension().lastPathComponent
        subtitle = meta?.uploader ?? "نزّل"
        hasVideo = MediaTools.isVideo(url)

        if let resume = ResumeStore.position(for: url), resume > 5 {
            player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            currentTime = resume
        }
        if autoplay {
            player.playImmediately(atRate: rate)
        }
        updateNowPlaying()

        Task { @MainActor [weak self] in
            let asset = AVURLAsset(url: url)
            let seconds = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
            let video = await MediaTools.hasTrack(url, .video)
            var aspect: CGFloat = 16.0 / 9.0
            if video, let track = try? await asset.loadTracks(withMediaType: .video).first,
               let size = try? await track.load(.naturalSize),
               let transform = try? await track.load(.preferredTransform) {
                let rect = CGRect(origin: .zero, size: size).applying(transform)
                if rect.width > 1, rect.height > 1 { aspect = abs(rect.width) / abs(rect.height) }
            }
            let image = await MediaTools.thumbnail(for: url, maxSize: 600)
            guard let self, self.current == url else { return }
            if seconds.isFinite, seconds > 0 { self.duration = seconds }
            self.hasVideo = video
            self.videoAspect = aspect.isFinite ? min(3, max(0.3, aspect)) : 16.0 / 9.0
            self.artwork = image
            if let resume = ResumeStore.position(for: url), seconds > 0, resume > seconds - 10 {
                ResumeStore.clear(url)
            }
            self.updateNowPlaying()
        }
    }

    private func itemEnded() {
        if let current { ResumeStore.clear(current) }
        if sleepAtEndOfItem {
            sleepAtEndOfItem = false
            player.pause()
            seek(to: 0)
            return
        }
        switch repeatMode {
        case .one:
            seek(to: 0)
            player.playImmediately(atRate: rate)
        case .all:
            next()
        case .off:
            if let current, let index = queue.firstIndex(of: current), index + 1 < queue.count {
                load(queue[index + 1], autoplay: true)
            } else {
                player.pause()
                seek(to: 0)
            }
        }
    }

    private func saveResumePosition(force: Bool = false) {
        guard let current, duration > 180 else { return }
        guard force || Date().timeIntervalSince(lastResumeSave) > 5 else { return }
        lastResumeSave = Date()
        if currentTime > 5 && currentTime < duration - 10 {
            ResumeStore.save(currentTime, for: current)
        }
    }

    // MARK: - Observers

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            Task { @MainActor in
                guard let self, seconds.isFinite else { return }
                self.currentTime = seconds
                if self.duration <= 0, let item = self.player.currentItem {
                    let d = CMTimeGetSeconds(item.duration)
                    if d.isFinite, d > 0 { self.duration = d }
                }
                self.saveResumePosition()
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor in
                guard let self, self.isPlaying != playing else { return }
                self.isPlaying = playing
                self.updateNowPlaying()
            }
        }
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self, let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .ended, AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                    self.resume()
                }
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in
                // headphones unplugged -> pause, like every music app
                if let raw, AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable {
                    self?.pause()
                }
            }
        })
        notificationTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // A visible video layer would pause playback; detach it so the sound keeps going.
                if !self.isPiPActive { self.playerLayer?.player = nil }
                self.saveResumePosition(force: true)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.playerLayer?.player = self.player
            }
        })
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }

    // MARK: - Video layer & Picture in Picture

    func attach(_ layer: AVPlayerLayer) {
        layer.player = player
        playerLayer = layer
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline =
            UserDefaults.standard.object(forKey: "autoPiP") as? Bool ?? true
        pipController = controller
        pipObservation = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            Task { @MainActor in self?.isPiPPossible = possible }
        }
    }

    func detach(_ layer: AVPlayerLayer) {
        guard playerLayer === layer, !isPiPActive else { return }
        layer.player = nil
        playerLayer = nil
        pipObservation = nil
        pipController = nil
        // This runs while SwiftUI is tearing the view down. Publishing a change right now
        // re-enters SwiftUI mid-teardown and crashes ("Fatal access conflict"), so defer it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.playerLayer == nil, self.isPiPPossible else { return }
            self.isPiPPossible = false
        }
    }

    func startPictureInPicture() {
        pipController?.startPictureInPicture()
    }

    // MARK: - Lock screen & Control Center

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipSeconds)]
        center.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: PlayerController.skipSeconds) }
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipSeconds)]
        center.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skip(by: -PlayerController.skipSeconds) }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = Self.rates.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            let newRate = event.playbackRate
            Task { @MainActor in self?.rate = newRate }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard current != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: subtitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: hasVideo
                ? MPNowPlayingInfoMediaType.video.rawValue
                : MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = Self.makeArtwork(artwork)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Built outside the main actor: MediaPlayer calls the handler on a background queue.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}

extension PlayerController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isPiPActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.isPiPActive = false }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            self.showFullPlayer = true
            completionHandler(true)
        }
    }
}

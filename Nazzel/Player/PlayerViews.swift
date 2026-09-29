import AVKit
import MediaPlayer
import SwiftUI
import UIKit

// MARK: - Mini player bar (sits above the tab bar on every tab)

struct MiniPlayerBar: View {
    @ObservedObject private var player = PlayerController.shared

    var body: some View {
        if player.current != nil {
            VStack(spacing: 0) {
                ProgressLine(progress: player.progress)
                    .frame(height: 3)

                HStack(spacing: 12) {
                    ArtworkView(image: player.artwork, isVideo: player.hasVideo, size: 44, corner: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(player.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // playback controls keep their natural order in Arabic too
                    HStack(spacing: 16) {
                        Button { player.skip(by: -PlayerController.skipSeconds) } label: {
                            Image(systemName: "gobackward.10").font(.title3)
                        }
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .frame(width: 30, height: 30)
                        }
                        Button { player.skip(by: PlayerController.skipSeconds) } label: {
                            Image(systemName: "goforward.10").font(.title3)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .environment(\.layoutDirection, .leftToRight)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
            .onTapGesture { player.showFullPlayer = true }
            .contextMenu {
                Button(role: .destructive) {
                    player.stop()
                } label: {
                    Label("إيقاف وإغلاق المشغّل", systemImage: "xmark.circle")
                }
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Thin progress line; always fills left to right like every media app.
private struct ProgressLine: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.08))
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * CGFloat(progress.isFinite ? min(1, max(0, progress)) : 0))
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

extension View {
    /// Adds the mini player above the tab bar.
    func withMiniPlayer() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar()
        }
    }
}

// MARK: - Full player

struct NowPlayingView: View {
    @ObservedObject private var player = PlayerController.shared
    @Environment(\.dismiss) private var dismiss
    @State private var skipFlash: Int = 0   // -1 back, +1 forward (double-tap feedback)
    @State private var addedToDownloads = false

    var body: some View {
        GeometryReader { geo in
            if player.hasVideo, player.isFullscreen || geo.size.width > geo.size.height * 1.15 {
                FullscreenVideoView()
            } else {
                let contentWidth = max(200, geo.size.width - 40)
                // leave room for titles + bar + buttons on every iPhone size
                let mediaHeight = max(140, min(geo.size.height * 0.42, geo.size.height - 330))
                VStack(spacing: 14) {
                    header
                    Spacer(minLength: 0)
                    media(maxWidth: contentWidth, maxHeight: mediaHeight)
                    Spacer(minLength: 0)
                    titles
                    PlayerScrubber()
                    transport
                    extras
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(NowPlayingBackground(image: player.isFullscreen ? nil : player.artwork))
        .preferredColorScheme(.dark)
        .presentationDragIndicator(player.isFullscreen ? .hidden : .visible)
        .interactiveDismissDisabled(player.isFullscreen)
        .statusBarHidden(player.isFullscreen)
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Text("يعمل الآن")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                if let url = player.current {
                    if player.isStream {
                        Button {
                            DownloadManager.shared.enqueue(url.absoluteString, mode: player.hasVideo ? .video : .audio,
                                                           quality: DownloadManager.defaultQuality)
                            addedToDownloads = true
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        } label: {
                            Label(addedToDownloads ? "انضاف للتحميلات ✓" : "نزّله على الجوال", systemImage: "arrow.down.circle")
                        }
                        ShareLink(item: url) {
                            Label("مشاركة الرابط", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        ShareLink(item: url) {
                            Label("مشاركة الملف", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                Button(role: .destructive) {
                    player.stop()
                    dismiss()
                } label: {
                    Label("إيقاف وإغلاق", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(.white)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func media(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        if player.hasVideo {
            let aspect = player.videoAspect
            let width = min(maxWidth, maxHeight * aspect)
            VideoSurface()
                .frame(width: width, height: width / aspect)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .bottom) { SubtitleOverlay(text: player.subtitleText, fontSize: 15) }
                .overlay(doubleTapZones)
                .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                .frame(maxWidth: .infinity)
        } else {
            let side = min(maxWidth, maxHeight)
            ArtworkView(image: player.artwork, isVideo: false, size: side, corner: 20)
                .scaleEffect(player.isPlaying ? 1 : 0.9)
                .animation(.spring(response: 0.45, dampingFraction: 0.75), value: player.isPlaying)
                .shadow(color: .black.opacity(0.5), radius: 22, y: 10)
                .overlay(doubleTapZones)
                .frame(maxWidth: .infinity)
        }
    }

    /// Double-tap the left / right half to jump 10 seconds (like YouTube).
    private var doubleTapZones: some View {
        HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { flash(-1) }
                .overlay(skipBadge("gobackward.10").opacity(skipFlash == -1 ? 1 : 0))
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { flash(1) }
                .overlay(skipBadge("goforward.10").opacity(skipFlash == 1 ? 1 : 0))
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func skipBadge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.title.weight(.semibold))
            .foregroundStyle(.white)
            .padding(14)
            .background(Circle().fill(Color.black.opacity(0.45)))
            .animation(.easeOut(duration: 0.2), value: skipFlash)
    }

    private func flash(_ direction: Int) {
        player.skip(by: Double(direction) * PlayerController.skipSeconds)
        skipFlash = direction
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if skipFlash == direction { skipFlash = 0 }
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(player.title)
                .font(.title3.bold())
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(player.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
    }

    private var transport: some View {
        HStack {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title2)
            }
            Spacer()
            Button { player.skip(by: -PlayerController.skipSeconds) } label: {
                Image(systemName: "gobackward.10").font(.system(size: 30))
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .symbolRenderingMode(.hierarchical)
            }
            Spacer()
            Button { player.skip(by: PlayerController.skipSeconds) } label: {
                Image(systemName: "goforward.10").font(.system(size: 30))
            }
            Spacer()
            Button { player.next() } label: {
                Image(systemName: "forward.fill").font(.title2)
            }
            .disabled(!player.hasNext)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .environment(\.layoutDirection, .leftToRight)
    }

    private var extras: some View {
        HStack {
            Menu {
                Picker("سرعة التشغيل", selection: $player.rate) {
                    ForEach(PlayerController.rates, id: \.self) { value in
                        Text(rateLabel(value)).tag(value)
                    }
                }
            } label: {
                Text(rateLabel(player.rate))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .frame(minWidth: 48, minHeight: 32)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
            }

            Spacer()

            Button { player.cycleRepeat() } label: {
                Image(systemName: player.repeatMode.symbol)
                    .font(.title3)
                    .foregroundStyle(player.repeatMode == .off ? Color.white.opacity(0.55) : Color.accentColor)
            }

            Spacer()

            Menu {
                if player.sleepAt != nil || player.sleepAtEndOfItem {
                    Button(role: .destructive) { player.cancelSleepTimer() } label: {
                        Label("إلغاء مؤقت النوم", systemImage: "moon.zzz")
                    }
                }
                ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                    Button("بعد \(minutes) دقيقة") { player.setSleepTimer(minutes: minutes) }
                }
                Button("نهاية المقطع الحالي") { player.sleepAfterCurrentItem() }
            } label: {
                Image(systemName: player.sleepAt != nil || player.sleepAtEndOfItem ? "moon.zzz.fill" : "moon.zzz")
                    .font(.title3)
                    .foregroundStyle(player.sleepAt != nil || player.sleepAtEndOfItem ? Color.accentColor : Color.white.opacity(0.8))
            }

            Spacer()

            if !player.subtitleTracks.isEmpty {
                SubtitleMenu()
                Spacer()
            }

            if player.hasVideo {
                Button { player.startPictureInPicture() } label: {
                    Image(systemName: "pip.enter").font(.title3)
                }
                .disabled(!player.isPiPPossible)
                Spacer()
                Button { player.enterFullscreen() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.title3)
                }
                .accessibilityLabel("ملء الشاشة")
                Spacer()
            }

            RoutePicker()
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private func rateLabel(_ value: Float) -> String {
        value == Float(Int(value)) ? "\(Int(value))×" : String(format: "%g×", value)
    }
}

/// Blurred cover behind the player. Lives in `.background`, so it can never
/// change the size of the player (a big picture used to push the controls off screen).
private struct NowPlayingBackground: View {
    let image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                GeometryReader { geo in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 40)
                        .opacity(0.5)
                }
            }
            LinearGradient(colors: [Color.black.opacity(0.1), Color.black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Building blocks

struct ArtworkView: View {
    let image: UIImage?
    let isVideo: Bool
    let size: CGFloat
    let corner: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.9), Color.indigo.opacity(0.8)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Image(systemName: isVideo ? "film" : "music.note")
                    .font(.system(size: max(12, size * 0.38), weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

final class PlayerLayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Shows the shared player's video. Attaching it enables Picture in Picture.
struct VideoSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView()
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        PlayerController.shared.attach(view.playerLayer)
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerLayerUIView, coordinator: ()) {
        PlayerController.shared.detach(uiView.playerLayer)
    }
}

/// AirPlay / Bluetooth output picker.
struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(named: "AccentColor") ?? .systemTeal
        view.prioritizesVideoDevices = false
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - Scrubber (shared by the portrait and the fullscreen player)

struct PlayerScrubber: View {
    @ObservedObject private var player = PlayerController.shared
    @State private var scrub: Double?

    var body: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { min(scrub ?? player.currentTime, max(player.duration, 1)) },
                    set: { scrub = $0 }
                ),
                in: 0...max(player.duration.isFinite ? player.duration : 1, 1),
                onEditingChanged: { editing in
                    if !editing, let value = scrub {
                        player.seek(to: value)
                        scrub = nil
                    }
                }
            )
            .tint(.white)
            HStack {
                Text(Formatters.duration(scrub ?? player.currentTime))
                Spacer()
                Text("-" + Formatters.duration(max(0, player.duration - (scrub ?? player.currentTime))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

// MARK: - Subtitles

struct SubtitleOverlay: View {
    let text: String?
    var fontSize: CGFloat = 16

    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.system(size: fontSize, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.62)))
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

struct SubtitleMenu: View {
    @ObservedObject private var player = PlayerController.shared

    var body: some View {
        Menu {
            Button {
                player.selectSubtitle(nil)
            } label: {
                if player.subtitleLang == nil {
                    Label("بدون ترجمة", systemImage: "checkmark")
                } else {
                    Text("بدون ترجمة")
                }
            }
            ForEach(player.subtitleTracks) { track in
                Button {
                    player.selectSubtitle(track.lang)
                } label: {
                    if player.subtitleLang == track.lang {
                        Label(track.displayName, systemImage: "checkmark")
                    } else {
                        Text(track.displayName)
                    }
                }
            }
        } label: {
            Image(systemName: player.subtitleLang == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.title3)
                .foregroundStyle(player.subtitleLang == nil ? Color.white.opacity(0.8) : Color.accentColor)
        }
        .accessibilityLabel("الترجمة")
    }
}

// MARK: - Fullscreen (landscape) video with gestures

/// Turn the phone (or tap the fullscreen button): the video fills the screen.
/// Tap: show/hide controls · double-tap left/right: ∓10 s
/// Swipe up/down on the left: brightness · on the right: volume · sideways: seek
struct FullscreenVideoView: View {
    @ObservedObject private var player = PlayerController.shared
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var hud: GestureHUD?
    @State private var drag: DragStart?
    @State private var skipFlash = 0

    enum GestureHUD: Equatable {
        case brightness(Double)
        case volume(Double)
        case seek(target: Double, delta: Double)
    }

    struct DragStart {
        enum Kind { case brightness, volume, seek }
        let kind: Kind
        let brightness: Double
        let volume: Double
        let time: Double
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                SystemVolumeHost()
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                VideoSurface()
                SubtitleOverlay(text: player.subtitleText, fontSize: 20)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, controlsVisible ? 76 : 18)
                    .animation(.easeOut(duration: 0.2), value: controlsVisible)
                touchLayer(size: geo.size)
                if controlsVisible {
                    controls
                        .transition(.opacity)
                }
                if let hud {
                    hudView(hud)
                        .transition(.opacity)
                }
            }
            .ignoresSafeArea()
        }
        .onAppear { scheduleHide() }
        .onChange(of: player.isPlaying) { _ in scheduleHide() }
    }

    // MARK: touches

    private func touchLayer(size: CGSize) -> some View {
        HStack(spacing: 0) {
            zone(direction: -1)
            zone(direction: 1)
        }
        .environment(\.layoutDirection, .leftToRight)
        .gesture(
            DragGesture(minimumDistance: 14)
                .onChanged { value in dragChanged(value, size: size) }
                .onEnded { _ in dragEnded() }
        )
    }

    private func zone(direction: Int) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                player.skip(by: Double(direction) * PlayerController.skipSeconds)
                skipFlash = direction
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if skipFlash == direction { skipFlash = 0 }
                }
            }
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.2)) { controlsVisible.toggle() }
                scheduleHide()
            }
            .overlay(
                Image(systemName: direction < 0 ? "gobackward.10" : "goforward.10")
                    .font(.largeTitle.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(18)
                    .background(Circle().fill(Color.black.opacity(0.45)))
                    .opacity(skipFlash == direction ? 1 : 0)
                    .animation(.easeOut(duration: 0.2), value: skipFlash)
                    .allowsHitTesting(false)
            )
    }

    private func dragChanged(_ value: DragGesture.Value, size: CGSize) {
        if drag == nil {
            let dx = abs(value.translation.width), dy = abs(value.translation.height)
            let kind: DragStart.Kind = dx > dy ? .seek : (value.startLocation.x < size.width / 2 ? .brightness : .volume)
            drag = DragStart(kind: kind, brightness: ScreenBrightness.value,
                             volume: Double(AVAudioSession.sharedInstance().outputVolume),
                             time: player.currentTime)
        }
        guard let drag else { return }
        let height = max(size.height * 0.8, 1)
        switch drag.kind {
        case .brightness:
            let level = min(1, max(0, drag.brightness - Double(value.translation.height / height)))
            ScreenBrightness.value = level
            hud = .brightness(level)
        case .volume:
            let level = min(1, max(0, drag.volume - Double(value.translation.height / height)))
            SystemVolumeHost.setVolume(Float(level))
            hud = .volume(level)
        case .seek:
            let span = min(180, max(60, player.duration * 0.25))
            let delta = Double(value.translation.width / max(size.width, 1)) * span
            let target = min(max(0, drag.time + delta), max(player.duration - 1, 0))
            hud = .seek(target: target, delta: target - drag.time)
        }
    }

    private func dragEnded() {
        if case .seek(let target, _) = hud { player.seek(to: target) }
        drag = nil
        withAnimation(.easeOut(duration: 0.3)) { hud = nil }
    }

    private func hudView(_ hud: GestureHUD) -> some View {
        let symbol: String
        let text: String
        var level: Double?
        switch hud {
        case .brightness(let value):
            symbol = "sun.max.fill"
            text = Formatters.percent(value)
            level = value
        case .volume(let value):
            symbol = value < 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill"
            text = Formatters.percent(value)
            level = value
        case .seek(let target, let delta):
            symbol = delta < 0 ? "gobackward" : "goforward"
            text = Formatters.duration(target) + "  (" + (delta < 0 ? "-" : "+") + Formatters.duration(abs(delta)) + ")"
        }
        return VStack(spacing: 10) {
            Image(systemName: symbol).font(.title)
            Text(text).font(.headline.monospacedDigit())
                .environment(\.layoutDirection, .leftToRight)
            if let level {
                ProgressView(value: level).tint(.white).frame(width: 120)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.6)))
        .allowsHitTesting(false)
    }

    // MARK: controls

    private var controls: some View {
        VStack {
            HStack(spacing: 18) {
                Button { player.exitFullscreen() } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.title3.weight(.semibold))
                }
                .accessibilityLabel("خروج من ملء الشاشة")
                Text(player.title)
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !player.subtitleTracks.isEmpty { SubtitleMenu() }
                Button { player.startPictureInPicture() } label: {
                    Image(systemName: "pip.enter").font(.title3)
                }
                .disabled(!player.isPiPPossible)
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)

            Spacer()

            HStack(spacing: 56) {
                Button { player.skip(by: -PlayerController.skipSeconds) } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 34))
                }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 66))
                        .symbolRenderingMode(.hierarchical)
                }
                Button { player.skip(by: PlayerController.skipSeconds) } label: {
                    Image(systemName: "goforward.10").font(.system(size: 34))
                }
            }
            .environment(\.layoutDirection, .leftToRight)

            Spacer()

            PlayerScrubber()
                .padding(.horizontal, 28)
                .padding(.bottom, 14)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.55), .clear, .clear, Color.black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard player.isPlaying else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, player.isPlaying else { return }
            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
        }
    }
}

/// Screen brightness for the fullscreen swipe.
@MainActor
enum ScreenBrightness {
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    static var value: Double {
        get { Double(screen?.brightness ?? 0.5) }
        set { screen?.brightness = CGFloat(min(1, max(0, newValue))) }
    }
}

/// A hidden system volume control: moving its slider changes the phone's volume
/// (and keeps iOS's big volume badge from covering the video).
struct SystemVolumeHost: UIViewRepresentable {
    @MainActor private static weak var slider: UISlider?

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 40, height: 40))
        view.showsRouteButton = false
        Self.slider = view.subviews.compactMap { $0 as? UISlider }.first
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        if Self.slider == nil {
            Self.slider = uiView.subviews.compactMap { $0 as? UISlider }.first
        }
    }

    @MainActor
    static func setVolume(_ value: Float) {
        guard let slider else { return }
        slider.value = min(1, max(0, value))
        slider.sendActions(for: .valueChanged)
    }
}

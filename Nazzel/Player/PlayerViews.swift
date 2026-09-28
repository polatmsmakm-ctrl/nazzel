import AVKit
import SwiftUI
import UIKit

// MARK: - Mini player bar (sits above the tab bar on every tab)

struct MiniPlayerBar: View {
    @ObservedObject private var player = PlayerController.shared

    var body: some View {
        if player.current != nil {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * player.progress, height: 2.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 2.5)
                .environment(\.layoutDirection, .leftToRight)

                HStack(spacing: 12) {
                    ArtworkView(image: player.artwork, isVideo: player.hasVideo, size: 42, corner: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(player.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(player.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    HStack(spacing: 18) {
                        Button { player.skip(by: -15) } label: {
                            Image(systemName: "gobackward.15").font(.title3)
                        }
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .frame(width: 28)
                        }
                        Button { player.skip(by: 15) } label: {
                            Image(systemName: "goforward.15").font(.title3)
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
    @State private var scrub: Double?

    var body: some View {
        ZStack {
            background
            VStack(spacing: 18) {
                header
                Spacer(minLength: 0)
                media
                Spacer(minLength: 0)
                titles
                scrubber
                transport
                extras
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    private var background: some View {
        ZStack {
            Color.black
            if let art = player.artwork {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 60)
                    .opacity(0.55)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 40, height: 40)
            }
            Spacer()
            Text("يعمل الآن")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                if let url = player.current {
                    ShareLink(item: url) {
                        Label("مشاركة الملف", systemImage: "square.and.arrow.up")
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
                    .frame(width: 40, height: 40)
            }
        }
        .foregroundStyle(.white)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var media: some View {
        if player.hasVideo {
            VideoSurface()
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        } else {
            ArtworkView(image: player.artwork, isVideo: false, size: 290, corner: 22)
                .scaleEffect(player.isPlaying ? 1 : 0.88)
                .animation(.spring(response: 0.45, dampingFraction: 0.75), value: player.isPlaying)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(player.title)
                .font(.title3.bold())
                .lineLimit(2)
            Text(player.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrub ?? player.currentTime },
                    set: { scrub = $0 }
                ),
                in: 0...max(player.duration, 1),
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

    private var transport: some View {
        HStack {
            Button { player.previous() } label: {
                Image(systemName: "backward.fill").font(.title2)
            }
            Spacer()
            Button { player.skip(by: -15) } label: {
                Image(systemName: "gobackward.15").font(.title)
            }
            Spacer()
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 68))
                    .symbolRenderingMode(.hierarchical)
            }
            Spacer()
            Button { player.skip(by: 15) } label: {
                Image(systemName: "goforward.15").font(.title)
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
                Picker("السرعة", selection: $player.rate) {
                    ForEach(PlayerController.rates, id: \.self) { value in
                        Text(rateLabel(value)).tag(value)
                    }
                }
            } label: {
                Text(rateLabel(player.rate))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .frame(minWidth: 44, minHeight: 32)
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
                        Label("إلغاء المؤقت", systemImage: "moon.zzz")
                    }
                }
                ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                    Button("\(minutes) دقيقة") { player.setSleepTimer(minutes: minutes) }
                }
                Button("نهاية المقطع الحالي") { player.sleepAfterCurrentItem() }
            } label: {
                Image(systemName: player.sleepAt != nil || player.sleepAtEndOfItem ? "moon.zzz.fill" : "moon.zzz")
                    .font(.title3)
                    .foregroundStyle(player.sleepAt != nil || player.sleepAtEndOfItem ? Color.accentColor : Color.white.opacity(0.8))
            }

            Spacer()

            if player.hasVideo {
                Button { player.startPictureInPicture() } label: {
                    Image(systemName: "pip.enter").font(.title3)
                }
                .disabled(!player.isPiPPossible)
                Spacer()
            }

            RoutePicker()
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .environment(\.layoutDirection, .leftToRight)
    }

    private func rateLabel(_ value: Float) -> String {
        value == Float(Int(value)) ? "\(Int(value))×" : String(format: "%g×", value)
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
            } else {
                Image(systemName: isVideo ? "film" : "music.note")
                    .font(.system(size: size * 0.38, weight: .semibold))
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

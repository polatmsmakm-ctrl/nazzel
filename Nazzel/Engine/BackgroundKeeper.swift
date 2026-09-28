import AVFoundation
import UIKit
import UserNotifications

/// Keeps the app running while downloads finish in the background.
///
/// iOS suspends apps a few seconds after you leave them. While a download is running we
/// hold a silent, mixable audio session (it never interrupts your music) so the download
/// can finish while you keep scrolling in another app.
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private var silence: AVAudioPlayer?
    private(set) var isActive = false

    var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "backgroundDownloads") as? Bool ?? true
    }

    func start() {
        guard isEnabled, !isActive, !PlayerController.shared.isPlaying else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(data: Self.silentWAV())
            player.numberOfLoops = -1
            player.volume = 0
            player.prepareToPlay()
            player.play()
            silence = player
            isActive = true
        } catch {
            silence = nil
            isActive = false
        }
    }

    func stop() {
        guard isActive else { return }
        silence?.stop()
        silence = nil
        isActive = false
        if !PlayerController.shared.isPlaying {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// One second of 8 kHz mono silence as a WAV file in memory.
    private static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8000
        let samples = Data(count: Int(sampleRate) * 2)
        var data = Data()
        func append<T>(_ value: T) {
            var v = value
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples.count).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian)          // PCM
        append(UInt16(1).littleEndian)          // mono
        append(sampleRate.littleEndian)
        append((sampleRate * 2).littleEndian)   // byte rate
        append(UInt16(2).littleEndian)          // block align
        append(UInt16(16).littleEndian)         // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(samples.count).littleEndian)
        data.append(samples)
        return data
    }
}

/// Local "download finished" notifications (no server involved).
enum Notifier {
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "notifyWhenDone") as? Bool ?? true
    }

    static func requestPermissionIfNeeded() {
        guard isEnabled, !SelfTest.isRequested else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    @MainActor
    static func post(title: String, body: String) {
        guard isEnabled, !SelfTest.isRequested, UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

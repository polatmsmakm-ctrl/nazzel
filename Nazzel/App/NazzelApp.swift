import AVFoundation
import SwiftUI
import UIKit

/// Which ways the screen may turn. The app is portrait; the video player goes landscape.
enum OrientationLock {
    // read by UIKit on the main thread only
    nonisolated(unsafe) private(set) static var mask: UIInterfaceOrientationMask = .portrait

    @MainActor
    static func set(_ newMask: UIInterfaceOrientationMask, prefer: UIInterfaceOrientationMask) {
        mask = newMask
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: prefer))
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return OrientationLock.mask
    }
}

@main
struct NazzelApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var engine = EngineStatus.shared
    @StateObject private var library = LibraryStore.shared

    init() {
        Paths.ensure()
        CrashReporter.start()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        CookieStore.refreshInBackground()
        DownloadActivityController.shared.cleanUpOnLaunch()
        if SelfTest.isRequested {
            SelfTest.start()
        } else {
            PythonEngine.shared.bootInBackground()
            EngineAutoUpdater.runIfDue()
            _ = ClipboardWatcher.shared
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(downloads)
                .environmentObject(engine)
                .environmentObject(library)
                .environment(\.layoutDirection, .rightToLeft)
                .onOpenURL { url in
                    downloads.handleIncoming(url)
                }
        }
    }
}

struct RootView: View {
    enum AppTab: Hashable {
        case download, browse, library, settings
    }

    @EnvironmentObject private var downloads: DownloadManager
    @ObservedObject private var player = PlayerController.shared
    @ObservedObject private var router = AppRouter.shared

    var body: some View {
        TabView(selection: $router.tab) {
            DownloadView()
                .withMiniPlayer()
                .tabItem { Label("تحميل", systemImage: "arrow.down.circle") }
                .tag(AppTab.download)
            BrowserView()
                .withMiniPlayer()
                .tabItem { Label("تصفّح", systemImage: "safari") }
                .tag(AppTab.browse)
            LibraryView()
                .withMiniPlayer()
                .tabItem { Label("الملفات", systemImage: "square.stack") }
                .tag(AppTab.library)
            SettingsView()
                .withMiniPlayer()
                .tabItem { Label("الإعدادات", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .onChange(of: downloads.incomingToken) { _ in
            router.tab = .download
        }
        .sheet(isPresented: $player.showFullPlayer) {
            NowPlayingView()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: player.current)
    }
}

/// Wrapper so a file URL can drive `.sheet(item:)`.
struct PlayItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Which tab is showing (shared so links from outside and the self-test can switch tabs).
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    @Published var tab: RootView.AppTab = .download
    @Published var showQualityPicker = false
    /// A playlist / channel waiting for the user to pick videos.
    @Published var collection: CollectionRequest?
    /// A library file opened in the cutter.
    @Published var trimItem: LibraryItem?
}

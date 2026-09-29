import AVFoundation
import SwiftUI

@main
struct NazzelApp: App {
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var engine = EngineStatus.shared
    @StateObject private var library = LibraryStore.shared

    init() {
        Paths.ensure()
        CrashReporter.start()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        CookieStore.refreshInBackground()
        if SelfTest.isRequested {
            SelfTest.start()
        } else {
            PythonEngine.shared.bootInBackground()
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
}

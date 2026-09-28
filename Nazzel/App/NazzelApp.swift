import AVFoundation
import SwiftUI

@main
struct NazzelApp: App {
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var engine = EngineStatus.shared
    @StateObject private var library = LibraryStore.shared

    init() {
        Paths.ensure()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
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
        case download, library, settings
    }

    @EnvironmentObject private var downloads: DownloadManager
    @State private var tab = AppTab.download

    var body: some View {
        TabView(selection: $tab) {
            DownloadView()
                .tabItem { Label("تحميل", systemImage: "arrow.down.circle") }
                .tag(AppTab.download)
            LibraryView()
                .tabItem { Label("الملفات", systemImage: "square.stack") }
                .tag(AppTab.library)
            SettingsView()
                .tabItem { Label("الإعدادات", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .onChange(of: downloads.incomingToken) { _ in
            tab = .download
        }
    }
}

/// Wrapper so a file URL can drive `.sheet(item:)`.
struct PlayItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

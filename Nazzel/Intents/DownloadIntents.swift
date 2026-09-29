import AppIntents
import UIKit

/// What to download (shown in the Shortcuts app).
@available(iOS 17.0, *)
enum DownloadKindOption: String, AppEnum {
    case video, audio, photos

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "نوع التحميل"
    static var caseDisplayRepresentations: [DownloadKindOption: DisplayRepresentation] = [
        .video: "فيديو",
        .audio: "صوت",
        .photos: "صور ومنشورات",
    ]
}

/// "نزّل الرابط": downloads without opening the app (Siri, Shortcuts, Back Tap, Action button).
/// The progress shows on the Lock Screen / Dynamic Island, and a notification says when it is done.
@available(iOS 17.0, *)
struct DownloadLinkIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "نزّل الرابط"
    static var description = IntentDescription(
        "ينزّل الفيديو أو الصوت من الرابط بدون ما تفتح التطبيق. إذا ما حطيت رابط، ياخذ الرابط المنسوخ.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "الرابط", description: "رابط الفيديو. اتركه فاضي عشان ياخذ الرابط المنسوخ.")
    var link: String?

    @Parameter(title: "النوع", default: .video)
    var kind: DownloadKindOption

    static var parameterSummary: some ParameterSummary {
        Summary("نزّل \(\.$link) \(\.$kind)")
    }

    init() {}

    init(link: String?, kind: DownloadKindOption = .video) {
        self.link = link
        self.kind = kind
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let given = link?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = given.isEmpty ? (UIPasteboard.general.string ?? "") : given
        let mode = DownloadMode(rawValue: kind.rawValue) ?? .video
        guard DownloadManager.shared.enqueue(text, mode: mode, quality: DownloadManager.defaultQuality) != nil else {
            return .result(dialog: "ما لقيت رابط. انسخ رابط الفيديو وجرب مرة ثانية.")
        }
        // keep the app alive in the background until the download is finished
        if UIApplication.shared.applicationState != .active {
            BackgroundKeeper.shared.start()
        }
        DownloadActivityController.shared.refresh(jobs: DownloadManager.shared.jobs)
        switch mode {
        case .audio: return .result(dialog: "بدأ تحميل الصوت ⬇ وبيوصلك تنبيه لما يخلص.")
        case .photos: return .result(dialog: "بدأ تحميل المنشور ⬇ وبيوصلك تنبيه لما يخلص.")
        case .video: return .result(dialog: "بدأ التحميل ⬇ وبيوصلك تنبيه لما يخلص.")
        }
    }
}

/// Ready-made shortcuts: they show up in the Shortcuts app and work with Siri right away.
@available(iOS 17.0, *)
struct NazzelShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DownloadLinkIntent(),
            phrases: [
                "نزّل الرابط في \(.applicationName)",
                "نزّل بـ \(.applicationName)",
                "Download with \(.applicationName)",
            ],
            shortTitle: "نزّل الرابط المنسوخ",
            systemImageName: "arrow.down.circle.fill"
        )
    }
}

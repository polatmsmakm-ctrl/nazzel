import SwiftUI

@main
struct TahdeerApp: App {
    @StateObject private var store = PlanStore()

    init() {
        // Used by CI to check the paper drawing without calling the API.
        if ProcessInfo.processInfo.arguments.contains("-demo") {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try? PaperRenderer.image(LessonPlan.sample).pngData()?
                .write(to: dir.appendingPathComponent("demo.png"))
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environment(\.layoutDirection, .rightToLeft)
                .onAppear {
                    if ProcessInfo.processInfo.arguments.contains("-demo"), store.plans.isEmpty {
                        store.add(LessonPlan.sample)
                    }
                }
        }
    }
}

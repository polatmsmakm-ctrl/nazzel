import Foundation
import SwiftUI

struct LessonPlan: Codable, Equatable, Identifiable, Hashable {
    var id = UUID()
    var title: String = ""
    var steps: [String] = []
    var sectionTitle: String = ""
    var sectionSteps: [String] = []
    var createdAt = Date()

    enum CodingKeys: String, CodingKey {
        case id, title, steps
        case sectionTitle = "section_title"
        case sectionSteps = "section_steps"
        case createdAt = "created_at"
    }

    init(title: String = "", steps: [String] = [], sectionTitle: String = "", sectionSteps: [String] = []) {
        self.title = title
        self.steps = steps
        self.sectionTitle = sectionTitle
        self.sectionSteps = sectionSteps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        steps = (try? c.decode([String].self, forKey: .steps)) ?? []
        sectionTitle = (try? c.decode(String.self, forKey: .sectionTitle)) ?? ""
        sectionSteps = (try? c.decode([String].self, forKey: .sectionSteps)) ?? []
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    }

    /// Removes empty lines and any numbering / bullets the model may have added.
    func cleaned() -> LessonPlan {
        var p = self
        p.steps = steps.map(Self.strip).filter { !$0.isEmpty }
        p.sectionSteps = sectionSteps.map(Self.strip).filter { !$0.isEmpty }
        p.sectionTitle = sectionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        p.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return p
    }

    private static func strip(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #"^(\d+\s*[-.)]|[-•*])\s*"#, options: .regularExpression) {
            t.removeSubrange(r)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let sample = LessonPlan(
        title: "Letter Ee",
        steps: [
            "Presenting the letter Ee by showing a short video about its sound.",
            "Asking learners what they saw in the video.",
            "Encouraging learners to say words that begin with the letter e.",
            "Showing the letter e words (egg, elephant, eight, eggplant, eleven, elbow) and asking learners to repeat them.",
            "Using the Ee flashcard to show the capital and small letter.",
            "Asking learners to look for the small e in the jungle picture.",
            "Asking learners to look for the capital E in the kitchen picture.",
            "Playing a guessing game with the letter e words.",
            "Teaching learners how to write the letter Ee step by step by showing them a video."
        ],
        sectionTitle: "Let's write (Page 14)",
        sectionSteps: [
            "Asking learners to open their books at page 14 and say what they can see.",
            "Asking learners to trace the capital E and the small e.",
            "Encouraging learners to copy the letter Ee on the lines.",
            "Wrap up: asking learners to circle the pictures that start with e."
        ]
    )
}

@MainActor
final class PlanStore: ObservableObject {
    @Published var plans: [LessonPlan] = [] {
        didSet { save() }
    }

    private let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("plans.json")
    }()

    init() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([LessonPlan].self, from: data) {
            plans = list
        }
    }

    func add(_ plan: LessonPlan) {
        plans.insert(plan, at: 0)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(plans) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

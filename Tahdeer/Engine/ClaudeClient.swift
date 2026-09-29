import Foundation

struct ClaudeClient {
    let apiKey: String
    let model: String

    static let models: [ModelOption] = [
        ModelOption(id: "claude-sonnet-5", name: "Claude Sonnet 5 (سريع ومناسب)"),
        ModelOption(id: "claude-opus-5-5", name: "Claude Opus 5.5 (الأقوى)"),
        ModelOption(id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5 (الأرخص)")
    ]

    func makePlan(frames: [VideoFrame], notes: String) async throws -> LessonPlan {
        var content: [[String: Any]] = []
        for f in frames {
            content.append(["type": "text", "text": "Frame at \(Int(f.seconds))s:"])
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": f.jpeg.base64EncodedString()
                ]
            ])
        }
        let ask = PlanWriter.ask(notes)
        content.append(["type": "text", "text": ask])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 3000,
            "system": Prompt.system,
            "messages": [["role": "user", "content": content]]
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw AppError.message("ما في اتصال بالإنترنت أو الاتصال انقطع. جرّب مرة ثانية.")
        }

        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard code == 200 else {
            let apiMsg = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? ""
            throw AppError.message(Self.arabicError(code: code, message: apiMsg))
        }

        let blocks = obj?["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["text"] as? String }.joined()
        return try PlanWriter.parse(text)
    }

    static func arabicError(code: Int, message: String) -> String {
        let lower = message.lowercased()
        let base: String
        switch code {
        case 401:
            base = "مفتاح الـ API غير صحيح. تأكد منه في الإعدادات."
        case 403:
            base = "المفتاح ما عنده صلاحية."
        case 404:
            base = "اسم النموذج غير متاح لحسابك. غيّره من الإعدادات."
        case 413:
            base = "الفيديو كبير جداً. جرّب فيديو أقصر."
        case 429:
            base = "طلبات كثيرة. انتظر دقيقة وجرّب مرة ثانية."
        case 529, 503, 500:
            base = "الخدمة مشغولة الحين. جرّب بعد شوي."
        case 400 where lower.contains("credit"):
            base = "رصيد حسابك في Anthropic خلص. اشحن الرصيد من console.anthropic.com."
        default:
            base = "صار خطأ (\(code))."
        }
        return message.isEmpty ? base : base + "\n\n" + message
    }
}

enum Prompt {
    static let system = """
    You are an experienced primary-school English teacher in Kuwait. You write the teacher's \
    lesson plan ("tahdeer") for a lesson, based on a recording of the lesson's slideshow \
    (Skyline English style: title slides, vocabulary slides, games, videos, then the Student's Book page).

    You receive frames from the video in chronological order, each labelled with its time. \
    Consecutive near-identical frames were removed, so each frame is usually a new slide.

    How to read the slides:
    - Short title-only slides (e.g. "New voc", "Let's answer", "Presenting Letter", "Give words", \
    "Find letter", "Guess", "How to write", "Let's write", "Use in a sentence", "Wrap up") announce \
    the activity that follows. Describe the activity, not the title.
    - A dark, blank or plain-coloured frame right after a title slide usually means a video was \
    played there (e.g. "Asking learners to watch a short video about ... and say what they saw.").
    - "What did you see?" after a video means learners talk about the video.
    - A slide "Page : N" or the Student's Book cover starts the book part. Everything from that \
    slide on goes into section_steps, and section_title is a short heading like \
    "Setting the scene (Page N)" or "Let's write (Page N)" that fits the slides. \
    If there is no book page, leave section_title empty and section_steps empty.
    - A final "Wrap up" activity is the last step, written as "Wrap up: asking learners to ...".

    How to write:
    - Follow the exact order of the slides. One step per activity. Do not invent activities \
    that are not in the video, and do not skip any.
    - Each step is one short sentence in simple English starting with a gerund, e.g. \
    "Presenting ...", "Asking learners to ...", "Encouraging learners to ...", "Showing ...", \
    "Playing ...", "Teaching learners how to ...". Vary the verbs naturally.
    - Mention the real words from the slides where useful, e.g. "(egg, ear, elephant, elbow)".
    - No numbering, no bullets, no markdown inside the steps.
    - title is a short lesson name, e.g. "Letter Ee" or "Numbers 1-10".

    Example of the style (for a letter Ee lesson):
    {"title":"Letter Ee",
     "steps":["Presenting the letter Ee by showing a short video about its sound.",
      "Asking learners what they saw in the video.",
      "Encouraging learners to say words that begin with the letter e.",
      "Showing the letter e words (egg, elephant, eight, eggplant, eleven, elbow) and asking learners to repeat them.",
      "Asking learners to look for the small e in the jungle picture.",
      "Teaching learners how to write the letter Ee step by step by showing them a video."],
     "section_title":"Let's write (Page 14)",
     "section_steps":["Asking learners to open their books at page 14 and say what they can see.",
      "Asking learners to trace the capital E and the small e.",
      "Wrap up: asking learners to circle the pictures that start with e."]}

    Reply with ONE JSON object only, exactly with the keys title, steps, section_title, section_steps.
    """
}

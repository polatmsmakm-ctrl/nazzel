import Foundation

enum Provider: String, CaseIterable, Identifiable {
    case gemini, claude
    var id: String { rawValue }
    var name: String {
        switch self {
        case .gemini: return "Gemini (مجاني)"
        case .claude: return "Claude (مدفوع)"
        }
    }
}

struct ModelOption: Identifiable {
    let id: String
    let name: String
}

enum PlanWriter {
    static let geminiModels: [ModelOption] = [
        ModelOption(id: "gemini-flash-latest", name: "Gemini Flash – آخر نسخة (ننصح فيه)"),
        ModelOption(id: "gemini-3.8-flash", name: "Gemini 3.8 Flash"),
        ModelOption(id: "gemini-3.5-flash-lite", name: "Gemini 3.5 Flash-Lite (أسرع)")
    ]

    static func write(provider: Provider, key: String, model: String,
                      frames: [VideoFrame], notes: String) async throws -> LessonPlan {
        switch provider {
        case .claude:
            return try await ClaudeClient(apiKey: key, model: model).makePlan(frames: frames, notes: notes)
        case .gemini:
            return try await GeminiClient(apiKey: key, model: model).makePlan(frames: frames, notes: notes)
        }
    }

    static func ask(_ notes: String) -> String {
        var ask = "These are the frames of the lesson video in order. Write the lesson plan now as JSON only."
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty {
            ask += "\n\nNotes from the teacher (may be in Arabic, follow them): \(n)"
        }
        return ask
    }

    static func parse(_ text: String) throws -> LessonPlan {
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"), s < e else {
            throw AppError.message("الرد ما كان بالشكل المتوقع. جرّب مرة ثانية.")
        }
        let json = String(text[s...e])
        guard let plan = try? JSONDecoder().decode(LessonPlan.self, from: Data(json.utf8)) else {
            throw AppError.message("ما قدرت أقرأ التحضير من الرد. جرّب مرة ثانية.")
        }
        let cleaned = plan.cleaned()
        if cleaned.steps.isEmpty && cleaned.sectionSteps.isEmpty {
            throw AppError.message("ما طلع تحضير من هذا الفيديو. تأكد إن الفيديو فيه شرائح الدرس.")
        }
        return cleaned
    }
}

struct GeminiClient {
    let apiKey: String
    let model: String

    func makePlan(frames: [VideoFrame], notes: String) async throws -> LessonPlan {
        var parts: [[String: Any]] = []
        for f in frames {
            parts.append(["text": "Frame at \(Int(f.seconds))s:"])
            parts.append(["inline_data": ["mime_type": "image/jpeg", "data": f.jpeg.base64EncodedString()]])
        }
        parts.append(["text": PlanWriter.ask(notes)])

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": Prompt.system]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "maxOutputTokens": 8192,
                "temperature": 0.4
            ]
        ]

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        guard let url = URL(string: urlString) else {
            throw AppError.message("اسم النموذج غير صحيح.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
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

        let candidates = obj?["candidates"] as? [[String: Any]] ?? []
        let content = candidates.first?["content"] as? [String: Any]
        let resultParts = content?["parts"] as? [[String: Any]] ?? []
        let text = resultParts
            .filter { ($0["thought"] as? Bool) != true }
            .compactMap { $0["text"] as? String }
            .joined()
        if text.isEmpty {
            let reason = candidates.first?["finishReason"] as? String ?? ""
            throw AppError.message("ما رجع رد من Gemini. جرّب مرة ثانية. \(reason)")
        }
        return try PlanWriter.parse(text)
    }

    static func arabicError(code: Int, message: String) -> String {
        let lower = message.lowercased()
        let base: String
        switch code {
        case 400 where lower.contains("api key") || lower.contains("api_key"):
            base = "مفتاح Gemini غير صحيح. تأكد منه في الإعدادات."
        case 401, 403:
            base = "مفتاح Gemini غير صحيح أو ما عنده صلاحية."
        case 404:
            base = "اسم النموذج غير متاح. غيّره من الإعدادات."
        case 413:
            base = "الفيديو كبير جداً. جرّب فيديو أقصر."
        case 429:
            base = "وصلت حد الاستخدام المجاني المؤقت. انتظر دقيقة وجرّب مرة ثانية."
        case 500, 503, 504:
            base = "خدمة Gemini مشغولة الحين. جرّب بعد شوي."
        default:
            base = "صار خطأ (\(code))."
        }
        return message.isEmpty ? base : base + "\n\n" + message
    }
}

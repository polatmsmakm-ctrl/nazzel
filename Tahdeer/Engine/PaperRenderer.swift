import UIKit

/// Draws a lesson plan on a lined notebook page in a handwriting font.
enum PaperRenderer {
    static let width: CGFloat = 1284
    static let rule: CGFloat = 58
    static let marginX: CGFloat = 148
    static let fontSize: CGFloat = 40
    static let textX: CGFloat = marginX + 34
    static let wrapIndent: CGFloat = 32
    static let rightPad: CGFloat = 70
    static let firstRuleY: CGFloat = 52
    static let topBlankRules = 1

    static let paper = UIColor(red: 0.992, green: 0.992, blue: 0.984, alpha: 1)
    static let ruleColor = UIColor(red: 0.725, green: 0.831, blue: 0.918, alpha: 1)
    static let marginColor = UIColor(red: 0.886, green: 0.478, blue: 0.478, alpha: 1)
    static let holeColor = UIColor(red: 0.827, green: 0.827, blue: 0.816, alpha: 1)
    static let navy = UIColor(red: 0.122, green: 0.184, blue: 0.561, alpha: 1)
    static let orange = UIColor(red: 0.886, green: 0.635, blue: 0.102, alpha: 1)

    static var font: UIFont {
        UIFont(name: "PatrickHand-Regular", size: fontSize)
            ?? UIFont(name: "Noteworthy-Light", size: fontSize)
            ?? .systemFont(ofSize: fontSize)
    }

    private struct Line {
        var number: String?
        var text: String
        var x: CGFloat
        var color: UIColor
        var underline = false
    }

    private static func layout(_ plan: LessonPlan) -> [Line?] {
        var out: [Line?] = []
        let f = font
        let full = width - textX - rightPad

        func add(_ number: String, _ text: String, _ color: UIColor) {
            let parts = wrap(text, font: f, first: full, rest: full - wrapIndent)
            for (i, p) in parts.enumerated() {
                out.append(Line(number: i == 0 ? number : nil, text: p,
                                x: i == 0 ? textX : textX + wrapIndent, color: color))
            }
        }

        for (i, s) in plan.steps.enumerated() {
            add("\(i + 1)-", s, navy)
        }
        if !plan.sectionTitle.isEmpty || !plan.sectionSteps.isEmpty {
            if !out.isEmpty { out.append(nil) }
            if !plan.sectionTitle.isEmpty {
                out.append(Line(number: nil, text: plan.sectionTitle, x: textX + 40,
                                color: orange, underline: true))
            }
            for s in plan.sectionSteps {
                add("-", s, orange)
            }
        }
        return out
    }

    private static func wrap(_ text: String, font: UIFont, first: CGFloat, rest: CGFloat) -> [String] {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var lines: [String] = []
        var cur = ""
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        for w in words {
            let cand = cur.isEmpty ? w : cur + " " + w
            let limit = lines.isEmpty ? first : rest
            if cur.isEmpty || (cand as NSString).size(withAttributes: attrs).width <= limit {
                cur = cand
            } else {
                lines.append(cur)
                cur = w
            }
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines.isEmpty ? [""] : lines
    }

    static func size(for plan: LessonPlan) -> CGSize {
        let count = layout(plan).count
        let needed = firstRuleY + CGFloat(count + topBlankRules + 3) * rule
        return CGSize(width: width, height: max(width * 1.414, needed).rounded(.up))
    }

    static func draw(_ plan: LessonPlan, in ctx: CGContext, size: CGSize) {
        // Paper
        paper.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))

        // Rules
        ctx.setFillColor(ruleColor.cgColor)
        var y = firstRuleY
        while y < size.height {
            ctx.fill(CGRect(x: 0, y: y, width: size.width, height: 2))
            y += rule
        }

        // Margin line
        ctx.setFillColor(marginColor.cgColor)
        ctx.fill(CGRect(x: marginX, y: 0, width: 2, height: size.height))

        // Punched holes
        ctx.setFillColor(holeColor.cgColor)
        for frac in [0.1, 0.48, 0.86] {
            let k = ((size.height * frac - firstRuleY) / rule).rounded(.down)
            let cy = firstRuleY + (k + 0.5) * rule
            ctx.fillEllipse(in: CGRect(x: 19, y: cy - 21, width: 42, height: 42))
        }

        // Text
        let f = font
        UIGraphicsPushContext(ctx)
        for (i, line) in layout(plan).enumerated() {
            guard let line else { continue }
            let ruleY = firstRuleY + CGFloat(i + 1 + topBlankRules) * rule
            let baseline = ruleY - 9
            let top = baseline - f.ascender
            var attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: line.color]
            if line.underline {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            (line.text as NSString).draw(at: CGPoint(x: line.x, y: top), withAttributes: attrs)
            if let n = line.number {
                let nAttrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: line.color]
                let w = (n as NSString).size(withAttributes: nAttrs).width
                (n as NSString).draw(at: CGPoint(x: marginX - 18 - w, y: top), withAttributes: nAttrs)
            }
        }
        UIGraphicsPopContext()
    }

    static func image(_ plan: LessonPlan, scale: CGFloat = 1) -> UIImage {
        let sz = Self.size(for: plan)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: sz, format: format).image { c in
            draw(plan, in: c.cgContext, size: sz)
        }
    }

    static func pdf(_ plan: LessonPlan) -> Data {
        let sz = Self.size(for: plan)
        return UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: sz)).pdfData { c in
            c.beginPage()
            draw(plan, in: c.cgContext, size: sz)
        }
    }

    /// Writes PNG and PDF files to a temp folder for sharing.
    static func exportFiles(_ plan: LessonPlan) -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = plan.title.isEmpty ? "Tahdeer" : plan.title
        name = name.replacingOccurrences(of: "/", with: "-")
        let png = dir.appendingPathComponent("\(name).png")
        let pdfURL = dir.appendingPathComponent("\(name).pdf")
        try? image(plan).pngData()?.write(to: png, options: .atomic)
        try? pdf(plan).write(to: pdfURL, options: .atomic)
        return [png, pdfURL]
    }
}

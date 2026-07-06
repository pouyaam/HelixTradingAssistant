import SwiftUI

/// Shared helpers for parsing and rendering the AI post-mortem / day-review
/// Markdown replies used by the Journal feature. Both
/// `JournalAISheet` and `JournalDayAISheet` historically kept their own
/// near-identical copies of this logic; this module centralises it so:
///   • Section parsing matches sections by **title** (not array index), so a
///     model that reorders or adds an intro section no longer misaligns icons.
///   • Inline `**bold**` markers render as bold runs instead of being
///     stripped silently (which discarded the model's intended emphasis).
///   • Mid-stream UX is smoother — callers can show the spinner until the
///     first `## ` header arrives, then switch to cards, and fall back to a
///     raw-text view if the model produced a headerless reply.
enum AISectionParse {
    /// One parsed `## `-prefixed section, or a preface if the model wrote
    /// prose before any header (`title == ""`). Callers can drop the preface
    /// bucket or render it under a "Summary" card with a neutral accent.
    struct Bucket { let title: String; let body: String }

    /// Split a Markdown reply into `## `-headed sections. Robust to
    /// arbitrary section order and to a leading preface (paragraphs before
    /// the first header). Headers are trimmed of trailing whitespace and
    /// inline-after-header punctuation (colons, em-dashes) so matching
    /// against canonical titles is forgiving.
    static func sections(from raw: String) -> [Bucket] {
        let lines = raw.components(separatedBy: "\n")
        var buckets: [(String, [String])] = []
        var current: (String, [String])? = nil
        var preface: [String] = []
        for line in lines {
            if line.hasPrefix("## ") {
                if let c = current { buckets.append((c.0, c.1)) }
                current = (String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
            } else if current != nil {
                current!.1.append(line)
            } else {
                preface.append(line)
            }
        }
        if let c = current { buckets.append((c.0, c.1)) }
        var result: [Bucket] = []
        let prefaceBody = preface.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefaceBody.isEmpty { result.append(Bucket(title: "", body: prefaceBody)) }
        for b in buckets {
            result.append(Bucket(
                title: b.0.trimmingCharacters(in: CharacterSet(charactersIn: ":—-").union(.whitespaces)),
                body: b.1.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return result
    }

    /// Lowercase, alphanumerics + spaces only, collapsed whitespace. Used so
    /// "Why This Trade Won" matches "Why this trade won:" / "Why this trade
    /// (won)" / "why this trade Won".
    static func normalize(_ s: String) -> String {
        var out = ""
        for c in s.lowercased() {
            if c.isLetter || c.isNumber { out.append(c) }
            else if c.isWhitespace { if !out.isEmpty && !out.hasSuffix(" ") { out.append(" ") } }
            else if c == "(" || c == ":" || c == "—" || c == "-" || c == "." {
                if !out.isEmpty && !out.hasSuffix(" ") { out.append(" ") }
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Match a raw section title against an ordered list of canonical
    /// titles. Returns the matched index (falls back to nil) so callers
    /// can pick the right icon/color pair. Non-exact matches still score a
    /// hit if either string contains the other after normalisation — a
    /// useful fallback when the model paraphrases ("What Cost You Today"
    /// vs "What Cost You" / "What Made You Profitable …").
    static func match(_ title: String, against known: [String]) -> Int? {
        let t = normalize(title)
        if t.isEmpty { return nil }
        for (i, k) in known.enumerated()
        where normalize(k) == t { return i }
        for (i, k) in known.enumerated() {
            let kn = normalize(k)
            if kn.count >= 6 {
                if t.contains(kn) || kn.contains(t) { return i }
            }
        }
        return nil
    }

    /// Split a paragraph of text into alternating (text, isBold) runs by
    /// scanning `**` markers. Unbalanced markers pass through literally — we
    /// don't wrap trailing `**` into a bold run that never closes.
    static func inlineRuns(_ text: String) -> [(text: String, bold: Bool)] {
        var runs: [(String, Bool)] = []
        var current = ""
        var inBold = false
        var i = text.startIndex
        while i < text.endIndex {
            if text.distance(from: i, to: text.endIndex) >= 2,
               text[i] == "*", text[text.index(after: i)] == "*" {
                if !current.isEmpty { runs.append((current, inBold)); current = "" }
                inBold.toggle()
                i = text.index(i, offsetBy: 2)
            } else {
                current.append(text[i])
                i = text.index(after: i)
            }
        }
        if inBold { current = "**" + current }   // unmatched — show literally
        if !current.isEmpty { runs.append((current, false)) }
        return runs.isEmpty ? [(text, false)] : runs
    }
}

struct AIMarkdownLines: View {
    /// Renamed from `body` because `body` collides with SwiftUI `View.body`.
    let bodyText: String
    var accentColor: Color = Theme.Color.textSecondary
    var baseSize: CGFloat = 12
    var bodyColor: Color = Theme.Color.textSecondary

    var body: some View {
        let trimmed = bodyText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "---" }
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(trimmed.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("- ") || line.hasPrefix("• ") {
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(accentColor.opacity(0.85))
                            .frame(width: 4, height: 4)
                            .padding(.top, 5)
                        InlineMarkdownText(
                            text: String(line.dropFirst(2)),
                            baseSize: baseSize,
                            baseColor: bodyColor
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    InlineMarkdownText(text: line, baseSize: baseSize, baseColor: bodyColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Renders one paragraph's inline `**bold**` runs as a single `Text` built
/// by concatenation, preserving the font/color baking SwiftUI expects.
struct InlineMarkdownText: View {
    let text: String
    var baseSize: CGFloat = 12
    var baseColor: Color = Theme.Color.textSecondary

    var body: some View {
        runs.reduce(Text("")) { acc, run in
            let segment = Text(run.text)
                .font(.system(size: baseSize, weight: run.bold ? .semibold : .regular))
                .foregroundColor(baseColor)
            return acc + segment
        }
        .textSelection(.enabled)
    }

    private var runs: [(text: String, bold: Bool)] { AISectionParse.inlineRuns(text) }
}
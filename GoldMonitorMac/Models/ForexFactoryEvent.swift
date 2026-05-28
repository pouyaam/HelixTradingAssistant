import Foundation

/// One ForexFactory macro-calendar event. Mirrors the Go backend's
/// `models.ForexFactoryEvent` so the Mac app reads the same shape it
/// would get from `/api/news` — and porting parsing/sentiment logic
/// back-and-forth between the two stays mechanical.
///
/// Field semantics (matching the upstream XML feed):
///   • `currency`: 3-letter ISO code (USD, EUR, …). Some events use
///     "ALL" or are blank — we keep them as-is so the filter can show
///     "Other" buckets correctly.
///   • `impactLevel`: normalised to one of `"high" | "medium" | "low"`
///     for the UI's dot color. Distinct from `impact` (raw label).
///   • `eventAt`: optional absolute date — present when the time
///     parsed cleanly; missing for "All Day" / "Tentative".
///   • `actual/forecast/previous`: free-text (numbers usually have a
///     unit suffix like "2.3%" or "$50.5B"). We don't try to parse
///     them into Doubles — surface verbatim.
struct ForexFactoryEvent: Identifiable, Hashable {
    let id: String          // stable across refetches; derived in init
    let title: String
    let currency: String
    let impact: String
    let impactLevel: ImpactLevel
    let date: String        // "YYYY-MM-DD" in feed timezone (US/Eastern)
    let time: String        // "10:30am" / "All Day" / "Tentative"
    let eventAt: Date?
    let actual: String
    let forecast: String
    let previous: String
    let url: String

    enum ImpactLevel: String, Codable, Hashable {
        case high, medium, low, unknown
    }

    enum Sentiment: String, Codable, Hashable {
        case bullish, bearish, neutral
    }

    init(
        title: String,
        currency: String,
        impactRaw: String,
        date: String,
        time: String,
        eventAt: Date?,
        actual: String,
        forecast: String,
        previous: String,
        url: String
    ) {
        let cur = currency.uppercased().trimmingCharacters(in: .whitespaces)
        let t = title.trimmingCharacters(in: .whitespaces)
        let tm = time.trimmingCharacters(in: .whitespaces)
        let u = url.trimmingCharacters(in: .whitespaces)
        // Stable id: same shape as the web app's `buildEventKey` so
        // future cross-platform persistence can collide cleanly.
        self.id = "\(date)|\(cur)|\(tm.lowercased())|\(t.lowercased())|\(u.lowercased())"
        self.title = t
        self.currency = cur
        self.impact = impactRaw
        self.impactLevel = Self.normaliseImpact(impactRaw)
        self.date = date
        self.time = tm
        self.eventAt = eventAt
        self.actual = actual.trimmingCharacters(in: .whitespaces)
        self.forecast = forecast.trimmingCharacters(in: .whitespaces)
        self.previous = previous.trimmingCharacters(in: .whitespaces)
        self.url = u
    }

    // MARK: - Classification helpers

    /// Map the raw `<impact>` string (which varies across feeds —
    /// "High", "high-impact", "red folder", etc.) onto the three
    /// canonical buckets the UI cares about.
    static func normaliseImpact(_ raw: String) -> ImpactLevel {
        let s = raw.lowercased()
        if s.contains("high") || s.contains("red")    { return .high }
        if s.contains("med")  || s.contains("orange") { return .medium }
        if s.contains("low")  || s.contains("yellow") { return .low }
        return .unknown
    }

    /// Cheap keyword-based bullish/bearish/neutral score. Same word
    /// lists as the web app's NewsPanel so users see consistent
    /// classifications across surfaces. Not a real NLP signal —
    /// just a visual cue.
    var sentiment: Sentiment {
        let text = (title + " " + currency).lowercased()
        var score = 0
        for kw in Self.bullishKeywords where text.contains(kw) { score += 1 }
        for kw in Self.bearishKeywords where text.contains(kw) { score -= 1 }
        if score > 0 { return .bullish }
        if score < 0 { return .bearish }
        return .neutral
    }

    private static let bullishKeywords: [String] = [
        "gdp", "nonfarm", "nfp", "employment", "jobs", "rate hike", "hawkish",
        "surplus", "strong", "beat", "better", "positive", "growth", "gain",
        "increase", "rise", "surge", "acceleration", "expansion", "recovery",
        "optimism", "confidence", "upgrade",
    ]
    private static let bearishKeywords: [String] = [
        "unemployment", "jobless", "layoff", "dovish", "deficit", "cut", "weak",
        "miss", "worse", "negative", "decline", "drop", "fall", "contraction",
        "slowdown", "recession", "default", "crisis", "decrease", "loss",
        "downgrade", "inflation spike",
    ]
}

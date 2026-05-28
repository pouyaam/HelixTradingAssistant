import Foundation

/// Pulls **post-release actual values** from Investing.com's economic
/// calendar AJAX endpoint and returns them keyed by event identity so
/// the News tab can overlay them onto the ForexFactory feed.
///
/// **Why this exists**: the public `nfs.faireconomy.media` mirror (both
/// XML and JSON variants) does not publish the `<actual>` field for any
/// event — confirmed by inspecting the live feed payload. The
/// canonical workaround used by the Go backend was to scrape
/// `forexfactory.com/calendar?day=…`, but ForexFactory now fronts that
/// page with a Cloudflare JS challenge, so plain HTTP scrapes return a
/// 5KB "Just a moment…" placeholder instead of the calendar HTML.
///
/// Investing.com still exposes the same data through a no-auth POST
/// endpoint that returns an HTML fragment with class-tagged cells —
/// `<td class="…" id="eventActual_NNN">5.537M</td>` etc. We hit it on
/// a 60s cadence while the News tab is visible, cache the parsed map
/// per week, and merge it back onto our existing `ForexFactoryEvent`
/// rows by `(currency, normalised title)`. Titles are bridged via
/// `ForexFactoryEvent.normalisedTitleKey` so divergent naming
/// conventions ("Core CPI m/m" vs "Core CPI (MoM)") collapse to the
/// same key.
enum InvestingActualsSource {

    /// Default endpoint. Investing.com may rotate hosts; if they do,
    /// the wizard can be extended to let users override this. For
    /// now it's a single constant.
    static let endpoint = URL(string: "https://www.investing.com/economic-calendar/Service/getCalendarFilteredData")!

    /// Form-encoded body for "this week, all major economies, UTC".
    /// `currentTab=thisWeek` gives the rolling 7-day window matching
    /// what the FF XML feed covers. The `country[]` IDs pick the
    /// economies whose macro releases gold/forex traders care about;
    /// expand here if you need more coverage. `timeZone=110` is UTC.
    private static let requestBody: String = {
        let countries = [
            5,   // United States
            72,  // Euro Zone
            17,  // Germany
            11,  // Spain
            110, // Italy
            22,  // France
            4,   // United Kingdom
            12,  // Switzerland
            6,   // Canada
            25,  // Australia
            43,  // New Zealand
            14,  // Japan
            37,  // China
            39,  // Hong Kong
        ]
        var parts = countries.map { "country%5B%5D=\($0)" }
        parts.append("timeZone=110")
        parts.append("timeFilter=timeRemain")
        parts.append("currentTab=thisWeek")
        parts.append("limit_from=0")
        return parts.joined(separator: "&")
    }()

    /// Fetch the current week's actual values. Returns
    /// `[normalisedKey: actualString]`. Empty actuals are dropped —
    /// the caller only wants entries it can actually overlay.
    ///
    /// Errors propagate so the caller can decide to fall back silently;
    /// the News surface treats enrichment as best-effort, so a failed
    /// scrape means "show what the XML feed gave us" without an error
    /// banner.
    static func fetchActualsForWeek(session: URLSession = .shared) async throws -> [String: String] {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        // Browser-shape headers — Investing.com gates the endpoint on
        // these. Stripped UA / missing X-Requested-With gets a 403.
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("XMLHttpRequest",                forHTTPHeaderField: "X-Requested-With")
        req.setValue("application/json, text/javascript, */*; q=0.01",
                                                      forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                                                      forHTTPHeaderField: "Content-Type")
        req.setValue("en-US,en;q=0.9",                forHTTPHeaderField: "Accept-Language")
        req.setValue("https://www.investing.com/economic-calendar/",
                                                      forHTTPHeaderField: "Referer")
        req.httpBody = requestBody.data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.network("http \(http.statusCode)")
        }

        // The body is a JSON envelope `{"data": "<tr>…</tr><tr>…</tr>…", …}`.
        // We only need the HTML chunk inside `data`.
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let html = envelope["data"] as? String else {
            throw FetchError.parse("envelope missing 'data'")
        }

        return parseRows(html: html)
    }

    /// Walk the HTML chunk row-by-row. We don't want a full HTML
    /// parser dependency for what is, in practice, three regex
    /// extractions per event row. The classes Investing.com uses are
    /// stable enough that regex holds up — if they rename them, this
    /// fails closed (empty map → no enrichment, no crash).
    static func parseRows(html: String) -> [String: String] {
        var out: [String: String] = [:]
        // Each event row sits inside `<tr id="eventRowId_…" …>…</tr>`.
        // The full row may contain other table cells; the body we
        // care about is everything up to the matching `</tr>`.
        let rowPattern = #"<tr id="eventRowId_(\d+)"[^>]*>(.*?)</tr>"#
        guard let rowRE = try? NSRegularExpression(pattern: rowPattern, options: [.dotMatchesLineSeparators]) else {
            return out
        }
        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        rowRE.enumerateMatches(in: html, options: [], range: full) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 3 else { return }
            let body = ns.substring(with: m.range(at: 2))

            // Currency — typically inside the second <td> with class
            // "flagCur"; the 3-letter code follows the inline flag span.
            guard let currency = firstMatch(in: body, pattern: #"flagCur[^>]*>.*?([A-Z]{3})\s*</td>"#) else { return }

            // Title — anchor text inside the "left event" cell. Strip
            // tags + collapse whitespace via the helper.
            guard var title = firstMatch(in: body, pattern: #"<td class="left event"[^>]*>.*?<a [^>]*>(.*?)</a>"#) else { return }
            title = Self.stripTagsAndCollapse(title)
            guard !title.isEmpty else { return }

            // Actual — the cell whose id starts with eventActual_.
            // `&nbsp;` or empty content means "not yet released".
            guard let actualRaw = firstMatch(in: body, pattern: #"id="eventActual_\d+"[^>]*>([^<]*)</td>"#) else { return }
            let actual = Self.stripTagsAndCollapse(actualRaw)
            guard !actual.isEmpty else { return }

            let key = ForexFactoryEvent.normalisedTitleKey(currency: currency, title: title)
            // First-write-wins: if Investing returns dupes (same event
            // listed twice for some reason), keep the earlier value
            // since it sorts to the actual release timestamp.
            if out[key] == nil { out[key] = actual }
        }
        return out
    }

    // MARK: - Small helpers

    /// Run a regex, return the first capture group of the first match,
    /// or nil. Wrapped because we use it three times above.
    private static func firstMatch(in body: String, pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = body as NSString
        let r = NSRange(location: 0, length: ns.length)
        guard let m = re.firstMatch(in: body, options: [], range: r), m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Strip any nested HTML tags and decode the handful of named
    /// entities Investing.com actually uses (&nbsp; / &amp; / &gt; /
    /// &lt;) then collapse runs of whitespace. We don't want a full
    /// HTML entity table; the calendar payload is conservative.
    private static func stripTagsAndCollapse(_ s: String) -> String {
        var out = s
        // Remove tags
        out = out.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        // Decode entities
        out = out
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
        // Collapse whitespace + trim
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    enum FetchError: LocalizedError {
        case network(String)
        case parse(String)
        var errorDescription: String? {
            switch self {
            case .network(let m): return "Investing actuals fetch failed: \(m)"
            case .parse(let m):   return "Investing actuals body unparseable: \(m)"
            }
        }
    }
}

import Foundation

/// Direct ForexFactory XML feed reader. No backend in the loop — the
/// Mac app talks to faireconomy.media directly (the same upstream URL
/// the Go backend uses) and parses the weekly XML payload into
/// `ForexFactoryEvent` values.
///
/// The "thisweek" XML covers the rolling current week in feed
/// timezone (US/Eastern). Per-event timestamps come back without a
/// timezone offset; we resolve them in `parseDateTime` by anchoring
/// to America/New_York and converting to UTC for storage. The UI
/// then displays in the user's local zone via `DateFormatter`.
///
/// The schema is small and stable, so we use Foundation's
/// `XMLParser` directly. No third-party deps.
enum ForexFactorySource {

    /// Default upstream URL. Kept as a parameter on `fetchThisWeek`
    /// so unit tests / debug pages can override it.
    static let defaultURL = URL(string: "https://nfs.faireconomy.media/ff_calendar_thisweek.xml")!

    /// Fetch and parse the current weekly calendar. Errors:
    ///   • `.network` — URLSession failure or non-2xx HTTP.
    ///   • `.parse`   — XMLParser failure (malformed feed).
    static func fetchThisWeek(
        url: URL = defaultURL,
        session: URLSession = .shared
    ) async throws -> [ForexFactoryEvent] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        // ForexFactory's CDN is picky about UAs — a blank UA gets a
        // 403. Match the Go backend's outbound UA so source servers
        // see the same fingerprint across surfaces.
        req.setValue(
            "Mozilla/5.0 (compatible; HelixTradingApp/1.0; +https://example.local)",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("application/xml,text/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.network("http \(http.statusCode)")
        }

        let parser = XMLParser(data: data)
        let delegate = WeeklyXMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            let err = parser.parserError?.localizedDescription ?? "unknown"
            throw FetchError.parse(err)
        }
        return delegate.events
    }

    enum FetchError: LocalizedError {
        case network(String)
        case parse(String)
        var errorDescription: String? {
            switch self {
            case .network(let msg): return "ForexFactory fetch failed: \(msg)"
            case .parse(let msg):   return "ForexFactory feed unparseable: \(msg)"
            }
        }
    }
}

// MARK: - XML decoding

/// XMLParser delegate that walks the feed top-to-bottom, accumulates
/// child element text into a builder, and emits one event per
/// `</event>` close tag. The feed schema is shallow (no nesting
/// inside an event), so a single-pass state machine is the right fit.
private final class WeeklyXMLDelegate: NSObject, XMLParserDelegate {
    var events: [ForexFactoryEvent] = []

    /// Fields collected for the in-flight `<event>`. Reset on
    /// `<event>` open, snapshot on `</event>` close.
    private var current: [String: String] = [:]
    private var currentTag: String = ""
    private var charBuffer: String = ""

    /// Lazy formatter for US-Eastern → UTC conversion. Feed dates use
    /// "MM-DD-YYYY" and times use "h:mma" — both are 12-hour US
    /// conventions.
    private lazy var dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        f.dateFormat = "MM-dd-yyyy h:mma"
        return f
    }()

    private lazy var dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd-yyyy"
        return f
    }()

    /// ISO output formatter — "YYYY-MM-DD" — for the `date` field.
    /// Matches the web app + Go backend's stored `date` so the
    /// filter chips can compare strings directly.
    private lazy var isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes _: [String: String] = [:]) {
        currentTag = elementName
        charBuffer = ""
        if elementName.lowercased() == "event" {
            current.removeAll(keepingCapacity: true)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        charBuffer += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) {
            charBuffer += s
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        if elementName.lowercased() == "event" {
            events.append(buildEvent(from: current))
            current.removeAll(keepingCapacity: true)
        } else {
            current[elementName.lowercased()] = charBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        currentTag = ""
        charBuffer = ""
    }

    private func buildEvent(from f: [String: String]) -> ForexFactoryEvent {
        let title    = f["title"]    ?? ""
        let country  = f["country"]  ?? ""
        let impact   = f["impact"]   ?? ""
        let dateRaw  = f["date"]     ?? ""
        let timeRaw  = f["time"]     ?? ""
        let actual   = f["actual"]   ?? ""
        let forecast = f["forecast"] ?? ""
        let previous = f["previous"] ?? ""
        let url      = f["url"]      ?? ""

        let (isoDate, eventAt) = parseDateTime(date: dateRaw, time: timeRaw)
        return ForexFactoryEvent(
            title: title,
            currency: country,
            impactRaw: impact,
            date: isoDate,
            time: timeRaw,
            eventAt: eventAt,
            actual: actual,
            forecast: forecast,
            previous: previous,
            url: url
        )
    }

    /// Convert the feed's "MM-DD-YYYY" date + "h:mma"/"All Day"/
    /// "Tentative" time into:
    ///   • An ISO date string ("YYYY-MM-DD") — always returned when
    ///     the date parses; falls back to the raw string otherwise.
    ///   • An optional absolute `Date` — only when the time also
    ///     parses to a valid clock value.
    private func parseDateTime(date dateRaw: String, time timeRaw: String) -> (String, Date?) {
        let date = dateRaw.trimmingCharacters(in: .whitespaces)
        let time = timeRaw.trimmingCharacters(in: .whitespaces)
        let lowerTime = time.lowercased()

        // "All Day" / "Tentative" → no absolute time; we still want a
        // date.
        if lowerTime.isEmpty || lowerTime == "all day" || lowerTime == "tentative" {
            if let d = dateOnlyFormatter.date(from: date) {
                return (isoDateFormatter.string(from: d), nil)
            }
            return (date, nil)
        }

        let combined = "\(date) \(time)"
        if let d = dateTimeFormatter.date(from: combined) {
            let iso = isoDateFormatter.string(from: d)
            return (iso, d)
        }
        // Time didn't parse — return the date if we can, otherwise
        // raw passthrough so the user at least sees the original.
        if let dOnly = dateOnlyFormatter.date(from: date) {
            return (isoDateFormatter.string(from: dOnly), nil)
        }
        return (date, nil)
    }
}

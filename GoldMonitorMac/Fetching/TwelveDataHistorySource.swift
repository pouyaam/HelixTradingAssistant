import Foundation

/// Pulls *historical* intraday OHLC bars from Twelve Data's REST
/// `time_series` endpoint. This is the only free source that reaches
/// older 1m / 5m candles than Yahoo serves (Yahoo caps 1m at ~8 days
/// and 5m at ~60 days), so it backs the chart's pan-left "load older
/// history" path once the user scrolls past Yahoo's window.
///
/// The live `TwelveDataSpotStream` (WebSocket) only delivers ticks — the
/// free tier exposes no historical OHLC over WS — so the two Twelve Data
/// integrations are complementary: stream for the live tail, this for
/// the deep past. Both authenticate with the same `apikey` from
/// `DataSourceConfig`.
///
/// Free tier is ~800 requests/day and 5000 data points per request, so
/// callers page backward one 5000-bar chunk at a time (anchored on
/// `end`) rather than asking for an unbounded range.
enum TwelveDataHistorySource {
    /// Fetch up to `outputSize` bars *ending at* `end`, going backward in
    /// time, for one pair. Bars are tagged with `tfTag` (the stored
    /// `ohlc.timeframe` value, "1m" / "5m") so they upsert into the same
    /// native series Yahoo fills. Weekend bars drop for markets with a
    /// weekly close (gold); crypto keeps every bar.
    static func fetchHistory(
        pairID: String,
        symbol: String,            // Twelve Data form, e.g. "XAU/USD"
        tfTag: String,             // stored timeframe tag: "1m" or "5m"
        end: Date,
        apiKey: String,            // read at the @MainActor call site
        outputSize: Int = 5000,
        skipWeekends: Bool
    ) async throws -> [OHLCBar] {
        guard !apiKey.isEmpty else { throw TwelveDataHistoryError.noAPIKey }
        guard let interval = intervalParam(for: tfTag) else {
            throw TwelveDataHistoryError.unsupportedTimeframe(tfTag)
        }

        var comps = URLComponents(string: "https://api.twelvedata.com/time_series")!
        comps.queryItems = [
            .init(name: "symbol", value: symbol),
            .init(name: "interval", value: interval),
            // Anchor the (backward-counting) window at `end`. Twelve Data
            // returns the most recent `outputsize` bars at or before this.
            .init(name: "end_date", value: Self.requestFormatter.string(from: end)),
            .init(name: "outputsize", value: String(min(max(outputSize, 1), 5000))),
            // Ask for UTC so our single decode formatter is unambiguous —
            // otherwise datetimes come back in the symbol's exchange tz.
            .init(name: "timezone", value: "UTC"),
            .init(name: "format", value: "JSON"),
            .init(name: "apikey", value: apiKey),
        ]
        guard let url = comps.url else { throw TwelveDataHistoryError.badURL }

        var req = URLRequest(url: url)
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            await log(url: url, status: nil, durationMs: Date().timeIntervalSince(start) * 1000,
                      response: nil, error: error)
            throw error
        }
        let durationMs = Date().timeIntervalSince(start) * 1000
        let status = (response as? HTTPURLResponse)?.statusCode
        await log(url: url, status: status, durationMs: durationMs, response: data, error: nil)

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw TwelveDataHistoryError.http(status: (response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let decoded = try JSONDecoder().decode(TimeSeriesResponse.self, from: data)
        // Twelve Data signals failure with a 200 + {status:"error"} body
        // (bad symbol, rate-limit, out-of-plan range). Surface it rather
        // than returning an empty series that looks like "no more data".
        if decoded.status == "error" {
            throw TwelveDataHistoryError.api(message: decoded.message ?? "unknown Twelve Data error")
        }
        guard let values = decoded.values else { return [] }

        var bars: [OHLCBar] = []
        bars.reserveCapacity(values.count)
        for v in values {
            guard let date = Self.parseDate(v.datetime),
                  let open = Double(v.open), let high = Double(v.high),
                  let low = Double(v.low),  let close = Double(v.close)
            else { continue }
            if skipWeekends && MarketCalendar.isClosedDay(date) { continue }
            bars.append(OHLCBar(
                pairID: pairID,
                timeframe: tfTag,
                bucketStart: date,
                open: open, high: high, low: low, close: close,
                volume: v.volume.flatMap(Double.init)
            ))
        }
        // Twelve Data returns newest-first; the rest of the app expects
        // oldest-first. Sort so callers + the dedupe upsert are stable.
        bars.sort { $0.bucketStart < $1.bucketStart }
        return bars
    }

    /// Stored timeframe tag → Twelve Data interval string. Only the two
    /// native intraday series the pan-left path extends are mapped; the
    /// coarser TFs reach years back through Yahoo already.
    private static func intervalParam(for tfTag: String) -> String? {
        switch tfTag {
        case "1m": return "1min"
        case "5m": return "5min"
        default:   return nil
        }
    }

    /// Parse Twelve Data's datetime. Intraday bars come back as
    /// "yyyy-MM-dd HH:mm:ss" (UTC, because we ask for `timezone=UTC`);
    /// fall back to date-only just in case the server ever omits the time.
    private static func parseDate(_ raw: String) -> Date? {
        if let d = decodeFormatter.date(from: raw) { return d }
        return dateOnlyFormatter.date(from: raw)
    }

    private static func log(
        url: URL, status: Int?, durationMs: Double, response: Data?, error: Error?
    ) async {
        await MainActor.run {
            NetworkLog.shared.record(
                source: "twelve-data",
                method: "GET",
                url: url.absoluteString,
                status: status,
                durationMs: durationMs,
                response: response,
                error: error
            )
        }
    }

    // ── Date formatters ───────────────────────────────────────────────
    //
    // All fixed-format + UTC so they're stable regardless of the user's
    // locale / timezone. `requestFormatter` builds the `end_date` query
    // param; the decode pair parses responses.
    private static let requestFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let decodeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let dateOnlyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Wire format
//
//   { "values": [ { "datetime": "...", "open": "...", "high": "...",
//                   "low": "...", "close": "...", "volume": "..." }, ... ],
//     "status": "ok" }
// or on failure:
//   { "code": 400, "message": "...", "status": "error" }
//
// All numeric fields arrive as JSON *strings*, hence the Double(...) parse.

private struct TimeSeriesResponse: Decodable {
    let values: [Value]?
    let status: String?
    let message: String?

    struct Value: Decodable {
        let datetime: String
        let open: String
        let high: String
        let low: String
        let close: String
        let volume: String?
    }
}

enum TwelveDataHistoryError: LocalizedError {
    case noAPIKey
    case badURL
    case unsupportedTimeframe(String)
    case http(status: Int)
    case api(message: String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:                 return "Twelve Data API key not configured (Settings)."
        case .badURL:                   return "Could not construct Twelve Data URL."
        case .unsupportedTimeframe(let t): return "Twelve Data history not supported for timeframe \(t)."
        case .http(let s):              return "Twelve Data HTTP \(s)."
        case .api(let m):               return "Twelve Data: \(m)"
        }
    }
}

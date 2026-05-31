import Foundation

/// Pulls OHLC bars from Yahoo Finance's anonymous chart API for any
/// supported symbol — originally gold ounce (XAU/USD via `GC=F`) but
/// now also covers BTC, SOL, ETH spot. Each call site supplies the
/// Yahoo symbol (`GC=F` / `BTC-USD` / `SOL-USD` / `ETH-USD`) and the
/// internal `pairID` to tag the resulting `OHLCBar`s with.
///
/// We deliberately bypass ProxyTransport here: Yahoo's CDN is reachable
/// directly without a VPN. Using URLSession.shared also keeps Yahoo
/// traffic out of the proxy budget.
enum YahooGoldSource {
    /// Static map for resolving a TradingPair id → Yahoo's chart
    /// symbol. Kept here (rather than on the pair definition) because
    /// it's a Yahoo-specific concern — other live sources have their
    /// own symbol forms (Twelve Data uses `XAU/USD`, `BTC/USD`).
    static let yahooSymbol: [String: String] = [
        "ounce": "GC=F",
        "btc":   "BTC-USD",
        "sol":   "SOL-USD",
        "eth":   "ETH-USD",
    ]

    /// Fetch a (range, interval) window for a single pair and decode
    /// into OHLCBars tagged with that pair's id. Pairs whose category
    /// has a fixed weekly close (e.g. COMEX gold) drop weekend bars;
    /// crypto pairs run 24/7 and keep every bar.
    static func fetchHistory(
        pairID: String,
        symbol: String,
        skipWeekends: Bool,
        range: String,
        interval: String
    ) async throws -> [OHLCBar] {
        var comps = URLComponents(string: "https://query2.finance.yahoo.com/v8/finance/chart/\(symbol)")!
        comps.queryItems = [
            .init(name: "range", value: range),
            .init(name: "interval", value: interval),
            .init(name: "includePrePost", value: "false"),
        ]
        guard let url = comps.url else { throw YahooError.badURL }

        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        // Yahoo's edge rejects requests with an empty / scripty user-agent.
        // A plain browser-ish UA works without any auth.
        req.setValue("Mozilla/5.0 HelixTradingApp/0.1", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            await logYahoo(url: url, status: nil, durationMs: Date().timeIntervalSince(start) * 1000,
                           response: nil, error: error)
            throw error
        }
        let durationMs = Date().timeIntervalSince(start) * 1000
        let status = (response as? HTTPURLResponse)?.statusCode
        await logYahoo(url: url, status: status, durationMs: durationMs, response: data, error: nil)

        guard let http = response as? HTTPURLResponse else { throw YahooError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw YahooError.http(status: http.statusCode)
        }

        let decoded = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        guard let result = decoded.chart.result?.first else {
            // Yahoo returns 200 with an error envelope when the symbol is
            // wrong — surface it explicitly rather than silently emitting [].
            throw YahooError.emptyResult
        }
        return result.toBars(
            pairID: pairID,
            timeframe: yahooIntervalToTimeframeTag(interval),
            skipWeekends: skipWeekends
        )
    }

    /// Latest spot price from the response metadata. Cheaper than parsing
    /// the full series when all we want is a sidebar tick. Defaults to
    /// the gold-ounce symbol for back-compat with older call sites.
    static func fetchLatestPrice(symbol: String = "GC=F") async throws -> Double {
        // The 1d/1m window is the cheapest endpoint that includes a
        // populated `meta.regularMarketPrice`.
        var comps = URLComponents(string: "https://query2.finance.yahoo.com/v8/finance/chart/\(symbol)")!
        comps.queryItems = [
            .init(name: "range", value: "1d"),
            .init(name: "interval", value: "1m"),
        ]
        guard let url = comps.url else { throw YahooError.badURL }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0 HelixTradingApp/0.1", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            await logYahoo(url: url, status: nil, durationMs: Date().timeIntervalSince(start) * 1000,
                           response: nil, error: error)
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode
        await logYahoo(url: url, status: status,
                       durationMs: Date().timeIntervalSince(start) * 1000,
                       response: data, error: nil)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw YahooError.invalidResponse
        }
        let decoded = try JSONDecoder().decode(YahooChartResponse.self, from: data)
        guard let price = decoded.chart.result?.first?.meta.regularMarketPrice, price > 0 else {
            throw YahooError.emptyResult
        }
        return price
    }

    /// Push a Yahoo round-trip into the central debug log. Tagged
    /// `yahoo` so the bug-icon view can group/filter by source.
    /// Dispatches to the main actor since NetworkLog is @MainActor.
    private static func logYahoo(
        url: URL, status: Int?, durationMs: Double, response: Data?, error: Error?
    ) async {
        await MainActor.run {
            NetworkLog.shared.record(
                source: "yahoo",
                method: "GET",
                url: url.absoluteString,
                status: status,
                durationMs: durationMs,
                response: response,
                error: error
            )
        }
    }

    /// Map Yahoo's interval string ("1m", "5m") to the tag we store in
    /// `ohlc.timeframe`. Anything not in our chart routing falls back to
    /// the raw string; OHLCRepo treats it as opaque.
    private static func yahooIntervalToTimeframeTag(_ raw: String) -> String {
        // Our internal tags happen to match Yahoo's already.
        raw
    }
}

// MARK: - Wire format
//
// chart.result[0] structure:
//   meta:    { regularMarketPrice, regularMarketTime, symbol, currency, ... }
//   timestamp: [Int]   (Unix seconds, UTC)
//   indicators.quote[0]: { open: [Double?], high: [Double?], low: [Double?],
//                          close: [Double?], volume: [Int?] }
//
// All four OHLC arrays are aligned with `timestamp[]` by index. A null at
// position i means that minute had no trade (exchange closed / illiquid);
// we skip those bars entirely.

private struct YahooChartResponse: Decodable {
    let chart: Chart

    struct Chart: Decodable {
        let result: [Result]?
        let error: ErrorEnvelope?
    }

    struct ErrorEnvelope: Decodable {
        let code: String?
        let description: String?
    }

    struct Result: Decodable {
        let meta: Meta
        let timestamp: [Int]?
        let indicators: Indicators

        func toBars(pairID: String, timeframe: String, skipWeekends: Bool) -> [OHLCBar] {
            guard let ts = timestamp,
                  let q = indicators.quote.first else { return [] }
            // Defensive: all five arrays should have the same length, but
            // some quotes have been observed missing volume entirely.
            let n = min(ts.count,
                        q.close.count,
                        q.open.count,
                        q.high.count,
                        q.low.count)
            var bars: [OHLCBar] = []
            bars.reserveCapacity(n)
            for i in 0..<n {
                guard let close = q.close[i],
                      let open  = q.open[i],
                      let high  = q.high[i],
                      let low   = q.low[i] else { continue }
                let bucketStart = Date(timeIntervalSince1970: TimeInterval(ts[i]))
                // Skip weekend bars only for markets with a fixed
                // weekly close (COMEX gold). Crypto trades 24/7, so
                // every bar matters there.
                if skipWeekends && MarketCalendar.isClosedDay(bucketStart) { continue }
                let volume = i < q.volume.count ? q.volume[i].map(Double.init) : nil
                bars.append(OHLCBar(
                    pairID: pairID,
                    timeframe: timeframe,
                    bucketStart: bucketStart,
                    open: open, high: high, low: low, close: close,
                    volume: volume
                ))
            }
            return bars
        }
    }

    struct Meta: Decodable {
        let symbol: String?
        let currency: String?
        let regularMarketPrice: Double?
        let regularMarketTime: Int?
    }

    struct Indicators: Decodable {
        let quote: [Quote]
    }

    struct Quote: Decodable {
        let open:   [Double?]
        let high:   [Double?]
        let low:    [Double?]
        let close:  [Double?]
        // `volume` may be absent on some endpoints — decode as an empty
        // array when the key is missing to keep `toBars` simple.
        let volume: [Int?]

        enum CodingKeys: String, CodingKey { case open, high, low, close, volume }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.open   = try c.decodeIfPresent([Double?].self, forKey: .open)  ?? []
            self.high   = try c.decodeIfPresent([Double?].self, forKey: .high)  ?? []
            self.low    = try c.decodeIfPresent([Double?].self, forKey: .low)   ?? []
            self.close  = try c.decodeIfPresent([Double?].self, forKey: .close) ?? []
            self.volume = try c.decodeIfPresent([Int?].self,    forKey: .volume) ?? []
        }
    }
}

enum YahooError: LocalizedError {
    case badURL
    case invalidResponse
    case emptyResult
    case http(status: Int)

    var errorDescription: String? {
        switch self {
        case .badURL:           return "Could not construct Yahoo Finance URL."
        case .invalidResponse:  return "Yahoo Finance sent a malformed response."
        case .emptyResult:      return "Yahoo Finance returned no data for GC=F."
        case .http(let s):      return "Yahoo Finance HTTP \(s)."
        }
    }
}

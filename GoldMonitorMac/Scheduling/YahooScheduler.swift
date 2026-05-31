import Foundation
import Combine

/// Live-price + history coordinator for every pair that doesn't go
/// through the Iranian snapshot pipeline. Despite the legacy name
/// (kept so env-object wiring stays intact), this scheduler manages
/// FOUR pairs concurrently: `ounce`, `btc`, `sol`, `eth`. Each has
/// its own Yahoo history symbol (`GC=F` / `BTC-USD` / `SOL-USD` /
/// `ETH-USD`) and Twelve Data WebSocket symbol (`XAU/USD` / `BTC/USD`
/// / `SOL/USD` / `ETH/USD`).
///
/// Source priority per pair:
///   1. **Twelve Data WebSocket** — primary live tick stream for all
///      four symbols on a single socket (free-tier allows 8 symbols).
///   2. **gold-api.com** — fallback ONLY for `ounce` (no equivalent
///      free spot endpoint for crypto). Polled every 10s when the
///      stream's last `XAU/USD` tick is older than `streamStaleSeconds`.
///   3. **Yahoo Finance** — authoritative history sync per pair every
///      6th tick (~60s). Overwrites whatever the live sources rolled
///      and provides the long-tail backfill on launch / gap-fill.
@MainActor
final class YahooScheduler: ObservableObject {
    /// Latest spot price per pair, keyed by internal pair id
    /// (`ounce`, `btc`, `sol`, `eth`). The dashboard reads this map
    /// directly for sidebar / header / chart-tag price display.
    @Published private(set) var latestPrices: [String: Double] = [:]
    /// Back-compat accessor — many existing call sites still read
    /// `latestOuncePrice` specifically. Returns the entry in the map
    /// rather than a separate stored field.
    var latestOuncePrice: Double? { latestPrices["ounce"] }

    /// Timestamp of the last successful update (any source). Drives
    /// the dashboard's "fresh as of …" indicator and the countdown.
    @Published private(set) var lastUpdateAt: Date?
    /// Last error string, source-prefixed (`twelve-data:` /
    /// `gold-api:` / `yahoo:`) so the UI can see which feed died.
    @Published private(set) var lastError: String?
    /// True once the first Yahoo history bootstrap completed for at
    /// least one pair. Used to gate "no data" UI states.
    @Published private(set) var hasBootstrapped: Bool = false
    /// In-flight indicator for the spinner.
    @Published private(set) var isFetching: Bool = false
    /// Which source delivered the most recent price tick to ANY pair.
    /// Surfaced in the debug pane.
    @Published private(set) var activeLiveSource: String = "(none)"

    /// Source series currently being deep-backfilled, keyed
    /// `"pairID|sourceTF"` (e.g. `"ounce|1h"`). The dashboard watches
    /// this to show a loading skeleton over the chart while the
    /// historical candles for the selected timeframe are still
    /// arriving from Yahoo.
    @Published private(set) var backfilling: Set<String> = []

    /// Source series we've already pulled to full depth this session,
    /// so toggling back to a timeframe doesn't re-download years of
    /// bars. Populated by both the bootstrap and on-demand backfills.
    private var deepBackfilled: Set<String> = []

    /// Source series currently fetching an *older* page from Twelve Data
    /// (the pan-left "load more history" path), keyed `"pairID|sourceTF"`.
    /// The dashboard watches this to show a "loading older bars" hint at
    /// the left edge without blocking the rest of the chart.
    @Published private(set) var loadingOlder: Set<String> = []

    /// Series we've paged all the way back on — Twelve Data returned
    /// nothing older than what we already had. Stops the pan-left
    /// trigger from re-requesting (and burning the daily request quota)
    /// once we've hit the bottom of available history.
    private var exhaustedOlder: Set<String> = []

    private func backfillKey(_ pairID: String, _ sourceTF: String) -> String {
        "\(pairID)|\(sourceTF)"
    }

    /// Deepest `(range, interval)` Yahoo will serve for each native
    /// source series. These are the per-interval ceilings — asking for
    /// more just returns the same window.
    private func deepFetchSpec(forSourceTF tf: String) -> (range: String, interval: String)? {
        switch tf {
        case "1m": return ("8d",  "1m")
        case "5m": return ("60d", "5m")
        case "1h": return ("2y",  "1h")
        case "1d": return ("10y", "1d")
        default:   return nil
        }
    }

    /// 10s tick — for the gold-api fallback path. Twelve Data ticks
    /// arrive on their own clock independent of this.
    let tickIntervalSeconds: Int = 10

    /// Yahoo history sync runs every Nth tick (~60s).
    private let yahooEveryNTicks: Int = 6

    /// gold-api fallback kicks in when the XAU stream has been quiet
    /// for this long. 30s is well past Twelve Data's heartbeat
    /// cadence — anything longer means we've actually lost the
    /// stream.
    private let streamStaleSeconds: TimeInterval = 30

    /// Per-pair config: which symbol to ask each upstream for, plus
    /// market-calendar flags. Driven directly from
    /// `TradingPair.catalog` so adding a new metal/crypto pair is
    /// purely a catalog entry + this static map.
    private struct PairConfig {
        let pairID: String
        let yahooSymbol: String         // e.g. "GC=F", "BTC-USD", "^DJI"
        /// nil = no Twelve Data WS feed for this symbol (e.g. US
        /// indices on the free tier). The bar history still syncs
        /// via Yahoo polling — the chart just doesn't get
        /// sub-second live ticks for these pairs.
        let twelveDataSymbol: String?
        let respectsWeekend: Bool       // forex + indices = yes, crypto = no
        let goldAPIFallback: Bool       // only ounce has a free spot fallback
    }

    private let pairs: [PairConfig] = [
        .init(pairID: "ounce", yahooSymbol: "GC=F",    twelveDataSymbol: "XAU/USD",
              respectsWeekend: true,  goldAPIFallback: true),
        .init(pairID: "btc",   yahooSymbol: "BTC-USD", twelveDataSymbol: "BTC/USD",
              respectsWeekend: false, goldAPIFallback: false),
        .init(pairID: "sol",   yahooSymbol: "SOL-USD", twelveDataSymbol: "SOL/USD",
              respectsWeekend: false, goldAPIFallback: false),
        .init(pairID: "eth",   yahooSymbol: "ETH-USD", twelveDataSymbol: "ETH/USD",
              respectsWeekend: false, goldAPIFallback: false),
        .init(pairID: "dji",   yahooSymbol: "^DJI",    twelveDataSymbol: nil,
              respectsWeekend: true,  goldAPIFallback: false),
    ]

    /// Reverse-lookup helper: Twelve Data symbol → internal pair id.
    /// Built once from `pairs` and used in the WS tick callback to
    /// route a tick by symbol back to the right OHLC bucket. Pairs
    /// with no Twelve Data feed (nil `twelveDataSymbol`) drop out.
    private var pairIDByTwelveDataSymbol: [String: String] {
        Dictionary(uniqueKeysWithValues: pairs.compactMap { cfg in
            cfg.twelveDataSymbol.map { ($0, cfg.pairID) }
        })
    }

    private var task: Task<Void, Never>?
    private var stream: TwelveDataSpotStream?
    private var tickCount: Int = 0

    /// Optional higher-priority source for the XAU/USD live feed. When
    /// set and "fresh", TwelveData ticks AND the gold-api fallback are
    /// suppressed for the ounce pair — same data flows through, just
    /// from cTrader instead. Other symbols are unaffected.
    private weak var cTraderProvider: CTraderScheduler?
    /// Repo reference cached at start() so external entry points
    /// (cTrader pushes via applyExternalTick) can roll bars without
    /// re-plumbing the AppDatabase through every call. OHLCRepo is a
    /// value type so a strong reference is fine.
    private var cachedRepo: OHLCRepo?

    /// Inject the cTrader scheduler so this YahooScheduler can ask
    /// "should I suppress my XAU ticks because cTrader is hotter?".
    /// Pass `nil` to clear (e.g. for unit tests). Called once at boot.
    func attachCTraderProvider(_ provider: CTraderScheduler) {
        self.cTraderProvider = provider
    }

    /// External entry point for ticks from sources OTHER than this
    /// scheduler's owned TwelveData / gold-api / Yahoo. Used by
    /// `CTraderScheduler` to feed cTrader ticks through the exact
    /// same OHLC + published-price pipeline as everything else.
    /// No-op until `start(database:)` has populated `cachedRepo`.
    func applyExternalTick(price: Double, pairID: String, source: String) {
        guard let repo = cachedRepo else { return }
        // applyLiveTick is async (DB bar-roll runs off-main). Hop onto a
        // task so this synchronous entry point stays non-blocking for its
        // caller (the cTrader flush loop).
        Task { await self.applyLiveTick(price: price, pairID: pairID, source: source, repo: repo) }
    }

    // ── On-demand deep backfill ───────────────────────────────────────

    /// Pull + store the full Yahoo depth for one pair's source series
    /// (1m / 5m / 1h / 1d). Idempotent within a session — a series
    /// already filled (by the bootstrap or a prior call) returns
    /// immediately. Publishes `backfilling` around the network round
    /// trip so the dashboard can show a skeleton while history loads.
    /// No-op until `start(database:)` has cached the repo.
    func ensureDeepHistory(pairID: String, sourceTF: String) async {
        guard let repo = cachedRepo else { return }
        let key = backfillKey(pairID, sourceTF)
        if deepBackfilled.contains(key) || backfilling.contains(key) { return }
        guard let spec = deepFetchSpec(forSourceTF: sourceTF),
              let cfg = pairs.first(where: { $0.pairID == pairID }) else { return }

        backfilling.insert(key)
        defer { backfilling.remove(key) }
        do {
            let bars = try await YahooGoldSource.fetchHistory(
                pairID: pairID, symbol: cfg.yahooSymbol,
                skipWeekends: cfg.respectsWeekend,
                range: spec.range, interval: spec.interval
            )
            try await repo.upsertMany(bars)
            deepBackfilled.insert(key)
            self.lastUpdateAt = Date()
        } catch {
            self.lastError = "yahoo backfill \(pairID)/\(sourceTF): \(error.localizedDescription)"
        }
    }

    /// Warm every native series for one pair at once (1m/5m/1h/1d),
    /// fetched in parallel. Used to pre-fill all timeframes rather than
    /// lazily per selection.
    func backfillAll(pairID: String) async {
        await withTaskGroup(of: Void.self) { group in
            for tf in ["1m", "5m", "1h", "1d"] {
                group.addTask { [self] in
                    await ensureDeepHistory(pairID: pairID, sourceTF: tf)
                }
            }
        }
    }

    // ── Pan-left "load older history" (Twelve Data REST) ─────────────

    /// Fetch one older page of intraday bars for a source series and
    /// prepend it to the stored history. Yahoo caps 1m at ~8d and 5m at
    /// ~60d, so once the user pans past that the chart hits a wall;
    /// Twelve Data's `time_series` REST endpoint reaches years further
    /// back for the same symbols. Anchors the (backward-counting) request
    /// on the oldest bar we currently have and upserts whatever's older.
    ///
    /// Returns the number of genuinely-older bars added (0 = nothing new,
    /// either because we've hit the bottom of available data or the fetch
    /// failed). Idempotent against concurrent calls + a per-series
    /// "exhausted" latch so a user pinned at the left edge can't spin the
    /// request quota. No-op for coarse TFs (1h/1d already reach years via
    /// Yahoo) and until `start(database:)` has cached the repo.
    @discardableResult
    func loadOlderHistory(pairID: String, sourceTF: String) async -> Int {
        guard let repo = cachedRepo else { return 0 }
        // Only the intraday series are Yahoo-capped; 1h/1d go back years
        // already, so there's nothing for Twelve Data to extend there.
        guard sourceTF == "1m" || sourceTF == "5m" else { return 0 }
        let key = backfillKey(pairID, sourceTF)
        if loadingOlder.contains(key) || exhaustedOlder.contains(key) { return 0 }
        let apiKey = TwelveDataSpotStream.apiKey
        guard !apiKey.isEmpty else { return 0 }
        guard let cfg = pairs.first(where: { $0.pairID == pairID }),
              let symbol = cfg.twelveDataSymbol,
              let earliest = try? await repo.earliestBucket(pairID: pairID, timeframe: sourceTF)
        else { return 0 }

        loadingOlder.insert(key)
        defer { loadingOlder.remove(key) }
        do {
            // End the window one second before our oldest bar so the page
            // is strictly older (the boundary bar would just dedupe).
            let bars = try await TwelveDataHistorySource.fetchHistory(
                pairID: pairID, symbol: symbol, tfTag: sourceTF,
                end: earliest.addingTimeInterval(-1),
                apiKey: apiKey,
                skipWeekends: cfg.respectsWeekend
            )
            let older = bars.filter { $0.bucketStart < earliest }
            guard !older.isEmpty else {
                exhaustedOlder.insert(key)
                return 0
            }
            try await repo.upsertMany(older)
            self.lastUpdateAt = Date()
            return older.count
        } catch {
            self.lastError = "twelve-data history \(pairID)/\(sourceTF): \(error.localizedDescription)"
            return 0
        }
    }

    /// Start every loop. Idempotent — repeated calls from AppState's
    /// boot path are no-ops once running.
    func start(database: AppDatabase) {
        guard task == nil else { return }
        let repo = database.ohlcRepo
        cachedRepo = repo

        // 1) Twelve Data WebSocket — one socket, all four symbols.
        let s = TwelveDataSpotStream(symbols: pairs.compactMap { $0.twelveDataSymbol })
        s.onTick = { [weak self] symbol, price in
            guard let self = self else { return }
            let id = self.pairIDByTwelveDataSymbol[symbol] ?? symbol
            // Fallback gate: if cTrader is currently the authoritative
            // source for ounce, don't let TwelveData overwrite it.
            // Other pairs are unaffected because cTrader only streams
            // XAU/USD today.
            if id == "ounce", self.cTraderProvider?.isFreshForXAUUSD() == true {
                return
            }
            Task { await self.applyLiveTick(price: price, pairID: id, source: "twelve-data", repo: repo) }
        }
        s.start()
        stream = s

        // 2) Bootstrap + polling/sync loop.
        task = Task { [weak self] in
            await self?.bootstrapAndGapFill(repo: repo)
            while !Task.isCancelled {
                let interval = UInt64(self?.tickIntervalSeconds ?? 60) * 1_000_000_000
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                await self?.tick(repo: repo)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        stream?.stop()
        stream = nil
    }

    // ── Bootstrap / gap-fill ──────────────────────────────────────────
    //
    // Yahoo-only: gold-api has no history, Twelve Data's free tier
    // doesn't expose historical OHLC over WS. One pass over every
    // managed pair at launch; gaps detected by latest stored bar.
    private func bootstrapAndGapFill(repo: OHLCRepo) async {
        isFetching = true
        defer { isFetching = false }
        for cfg in pairs {
            // Weekend cleanup only matters for markets that have
            // weekends; crypto never has closed-day rows.
            if cfg.respectsWeekend {
                _ = try? await repo.deleteClosedDayBars(pairID: cfg.pairID)
            }
            // Pull every native series to full depth through the shared
            // `ensureDeepHistory` path — same code (and `backfilling`
            // skeleton signalling) the dashboard's on-demand backfill
            // uses, so the two can't double-fetch the same series.
            // Depth per interval (Yahoo's per-interval ceiling):
            //   5m → 60d · 1m → 8d · 1h → 2y · 1d → 10y.
            await ensureDeepHistory(pairID: cfg.pairID, sourceTF: "5m")
            await ensureDeepHistory(pairID: cfg.pairID, sourceTF: "1m")
            await ensureDeepHistory(pairID: cfg.pairID, sourceTF: "1h")
            await ensureDeepHistory(pairID: cfg.pairID, sourceTF: "1d")

            // Seed the published price from the last stored 1m bar.
            if let last1m = try? await repo.latestBucket(pairID: cfg.pairID, timeframe: "1m"),
               let recent = try? await repo.read(
                pairID: cfg.pairID, timeframe: "1m",
                since: last1m.addingTimeInterval(-60),
                until: last1m
               ).last {
                latestPrices[cfg.pairID] = recent.close
            }
            self.hasBootstrapped = true
        }
        self.lastUpdateAt = Date()
    }

    // ── Periodic tick ─────────────────────────────────────────────────
    private func tick(repo: OHLCRepo) async {
        isFetching = true
        defer { isFetching = false }
        tickCount += 1

        // Yahoo authoritative history sync every Nth tick. Fans out
        // across all managed pairs in parallel. The Twelve Data WS
        // and cTrader bridge (when running) keep the *latest tick*
        // fresher than this in between syncs; Yahoo is what gives
        // us the OHLC bars.
        if tickCount % yahooEveryNTicks == 0 {
            await withTaskGroup(of: Void.self) { group in
                for cfg in pairs {
                    group.addTask { [self] in
                        await syncYahoo(cfg: cfg, repo: repo)
                    }
                }
            }
            self.lastUpdateAt = Date()
        }
    }

    /// Sync one pair's 1m + 5m history in parallel. Errors are
    /// captured into `lastError` but don't bail — one pair failing
    /// shouldn't stop the others.
    private func syncYahoo(cfg: PairConfig, repo: OHLCRepo) async {
        do {
            // Periodic sync only needs to refresh the *trailing* bars —
            // the deep 1h/1d tails were filled at bootstrap and never
            // change once closed. So we use short ranges here (cheap
            // payloads, kinder to Yahoo's rate limits) and let
            // upsertMany merge the freshest few bars of each series.
            async let oneMinT = YahooGoldSource.fetchHistory(
                pairID: cfg.pairID, symbol: cfg.yahooSymbol,
                skipWeekends: cfg.respectsWeekend,
                range: "8d", interval: "1m"
            )
            async let fiveMinT = YahooGoldSource.fetchHistory(
                pairID: cfg.pairID, symbol: cfg.yahooSymbol,
                skipWeekends: cfg.respectsWeekend,
                range: "1mo", interval: "5m"
            )
            async let oneHourT = YahooGoldSource.fetchHistory(
                pairID: cfg.pairID, symbol: cfg.yahooSymbol,
                skipWeekends: cfg.respectsWeekend,
                range: "5d", interval: "1h"
            )
            async let oneDayT = YahooGoldSource.fetchHistory(
                pairID: cfg.pairID, symbol: cfg.yahooSymbol,
                skipWeekends: cfg.respectsWeekend,
                range: "1mo", interval: "1d"
            )
            let oneMin = try await oneMinT
            let fiveMin = try await fiveMinT
            let oneHour = try await oneHourT
            let oneDay = try await oneDayT
            try await repo.upsertMany(oneMin)
            try await repo.upsertMany(fiveMin)
            try await repo.upsertMany(oneHour)
            try await repo.upsertMany(oneDay)
        } catch {
            self.lastError = "yahoo \(cfg.pairID): \(error.localizedDescription)"
        }
    }

    // ── Live-tick handler (Twelve Data + gold-api) ───────────────────

    /// Common path for an incoming live price. Publishes it for the
    /// pair, rolls 1m + 5m buckets, updates timestamps + source tag.
    private func applyLiveTick(
        price: Double,
        pairID: String,
        source: String,
        repo: OHLCRepo
    ) async {
        // Publish the price immediately (cheap @Published mutation on the
        // main actor) so the UI updates the instant a tick arrives — the
        // bar-rolling DB work below runs off-main and never blocks it.
        latestPrices[pairID] = price
        activeLiveSource = "\(source)/\(pairID)"
        let cfg = pairs.first { $0.pairID == pairID }
        let respectsWeekend = cfg?.respectsWeekend ?? false
        try? await rollLiveBar(pairID: pairID, timeframe: "1m", bucketSize: 60,
                               respectsWeekend: respectsWeekend, price: price, repo: repo)
        try? await rollLiveBar(pairID: pairID, timeframe: "5m", bucketSize: 300,
                               respectsWeekend: respectsWeekend, price: price, repo: repo)
        // Throttle lastUpdateAt writes — it's @Published and feeds
        // several heavy observers (chart reload trigger, header
        // FetchTimerView re-render, status bar). At cTrader's 2+ Hz
        // flush rate, writing it every tick would fire
        // `objectWillChange` on the scheduler 2× per second, which
        // re-evaluates every view that reads ANY of this scheduler's
        // properties. 1 Hz here keeps the timer countdown looking
        // live without those cascade costs.
        let now = Date()
        if let prev = lastUpdateAt, now.timeIntervalSince(prev) < 1.0 {
            hasBootstrapped = true
            return
        }
        lastUpdateAt = now
        hasBootstrapped = true
    }

    /// True if Twelve Data has delivered an XAU/USD tick recently.
    /// Drives the gold-api fallback gate (which only applies to the
    /// ounce — crypto symbols have no fallback path).
    private func streamIsFreshForOunce() -> Bool {
        guard let last = stream?.lastTickAtBySymbol["XAU/USD"] else { return false }
        return Date().timeIntervalSince(last) < streamStaleSeconds
    }

    // ── Helpers ───────────────────────────────────────────────────────

    /// Upsert (or extend) the open OHLC bar for "right now" at the
    /// given pair + timeframe. Open is captured on first touch;
    /// high/low expand monotonically; close always reflects the
    /// latest tick. For markets with a weekly close (gold), skips
    /// weekend buckets to keep stale Friday quotes out of the chart.
    ///
    /// The read-modify-write is done atomically inside the repo's SQL
    /// `ON CONFLICT` merge (`upsertLiveTickBar`) and runs off the main
    /// thread, so a burst of ticks for the same bucket can't race a
    /// stale read — and the main actor never blocks on SQLite here.
    private func rollLiveBar(
        pairID: String,
        timeframe: String,
        bucketSize: TimeInterval,
        respectsWeekend: Bool,
        price: Double,
        repo: OHLCRepo
    ) async throws {
        let nowSecs = Date().timeIntervalSince1970
        let bucketSecs = floor(nowSecs / bucketSize) * bucketSize
        let bucketStart = Date(timeIntervalSince1970: bucketSecs)
        if respectsWeekend && MarketCalendar.isClosedDay(bucketStart) { return }

        try await repo.upsertLiveTickBar(
            pairID: pairID,
            timeframe: timeframe,
            bucketStart: bucketStart,
            price: price
        )
    }
}

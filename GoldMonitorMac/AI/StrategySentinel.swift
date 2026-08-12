import Foundation

/// One SMC setup surfaced by the Strategy Sentinel.
///
/// Every field traces back to the ALGOSMART ASSIST v2 indicator — there is no
/// volume ranking, EMA trend filter, or multi-engine order-block voting in this
/// model any more. See `SMCSentinelEngine` for the rules.
struct RadarAlert: Identifiable, Equatable, Codable {
    let id: UUID
    let symbol: String
    let pairID: String
    let timeframe: String
    let direction: SetupDirection
    let confluenceScore: Int // 0 - 100
    /// Trigger-candle close, or the POI edge while the setup is still waiting.
    let entryPrice: Double
    let stopLoss: Double
    /// TP1 — the 0.5 equilibrium, or a 1:2 target when equilibrium is too near.
    let takeProfit: Double
    /// TP2 — the opposing POI zone or the major swing beyond TP1.
    let takeProfit2: Double
    let riskRewardRatio: Double
    let rationale: String
    let createdAt: Date
    /// The POI (order block) the setup is anchored to.
    var zoneTop: Double = 0
    var zoneBottom: Double = 0
    /// The 0.5 level of the current structural leg.
    var equilibrium: Double = 0
    /// The higher timeframe that supplied the context, e.g. "1h".
    var htfLabel: String? = nil
    var status: SetupStatus = .waitingForPOI
    var breakdown: ConfluenceBreakdown? = nil

    enum SetupDirection: String, Codable {
        case buy = "BUY"
        case sell = "SELL"
    }

    /// The strategy's own lifecycle: waiting for price to reach the POI,
    /// mitigating inside it, or live after a SCOB / LTF CHoCH trigger.
    /// `invalidated` setups are dropped by the engine rather than published.
    enum SetupStatus: String, Codable {
        case waitingForPOI = "WAITING POI"
        case mitigating = "IN POI"
        case active = "ACTIVE"
        case invalidated = "INVALID"
    }

    /// SMC confluence scoring. The HTF context is a hard precondition, so it is
    /// reported for transparency but not scored.
    struct ConfluenceBreakdown: Codable, Equatable {
        let baseScore: Int
        let ltfAlignBonus: Int
        let idmSweepBonus: Int
        let liquiditySweepBonus: Int
        let equilibriumBonus: Int
        let triggerBonus: Int
        let freshZoneBonus: Int
        let htfLabel: String?
        /// e.g. "Bullish CHoCH".
        let contextEvent: String
        /// "IDM sweep" or "Liquidity sweep".
        let grabKind: String
        let grabLevel: Double
        /// "SCOB", "LTF CHoCH", or "Awaiting trigger".
        let triggerKind: String
        /// "Discount" or "Premium".
        let equilibriumState: String
        let isLTFAligned: Bool
        let isFreshZone: Bool
        let hasTrigger: Bool
    }

    var isFresh: Bool {
        Date().timeIntervalSince(createdAt) < 1800 // < 30 mins
    }
}

/// The EBP indicator's current read for one symbol, as the radar shows
/// it. Unlike `RadarAlert` this is not a scored setup queue — EBP has no
/// confluence rubric, so the radar simply mirrors the engine's own
/// output: the setups it is tracking and the tally they add up to.
struct EBPRadarSnapshot: Equatable {
    let pairID: String
    let symbol: String
    /// The timeframe the patterns were detected on, which is not
    /// necessarily the one on the chart — see the indicator's
    /// "Detect on timeframe" setting.
    let timeframe: String
    let setups: [EngulfingBarPlay.Setup]
    let stats: EngulfingBarPlay.Stats
    let updatedAt: Date

    /// Setups still worth watching: an order resting or a live position.
    var working: [EngulfingBarPlay.Setup] {
        setups.filter { $0.status == .pending || $0.status == .triggered }
    }
}

@MainActor
final class StrategySentinel: ObservableObject {
    static let shared = StrategySentinel()

    @Published var isSentinelActive: Bool = true
    /// Setups keyed by `"pairID|timeframe"` — see `scanKey(_:_:)`. Keyed by
    /// pair *and* timeframe so scanning several timeframes at once doesn't
    /// have each one overwrite the last.
    @Published private(set) var alertsByKey: [String: [RadarAlert]] = [:]
    /// EBP reads, keyed by pair. Fed by `DashboardView` off the same
    /// computation that drives the chart overlay, so the radar and the
    /// chart can never disagree about what a setup is doing.
    @Published private(set) var ebpSnapshots: [String: EBPRadarSnapshot] = [:]
    @Published private(set) var lastScanTimestamp: Date?
    /// Market read per `"pairID|timeframe"`, shown in the drawer header even
    /// when no setup qualifies.
    @Published private(set) var marketContext: [String: MarketContext] = [:]

    /// Which timeframes to scan *in addition to* the chart's, which is always
    /// scanned. Empty is the historical behaviour and stays the default.
    @Published var scanTimeframes: Set<Timeframe> = StrategySentinel.loadScanTimeframes() {
        didSet {
            guard scanTimeframes != oldValue else { return }
            Self.saveScanTimeframes(scanTimeframes)
        }
    }

    var notificationInbox: NotificationInbox?
    /// Set once from `DashboardView`, so auxiliary timeframes can read their
    /// own candles instead of folding the chart's.
    private(set) weak var database: AppDatabase?

    /// Every setup on the radar, flattened. Consumers filter by `pairID`.
    var activeRadarAlerts: [RadarAlert] { alertsByKey.values.flatMap { $0 } }

    /// The market read for one pair on one timeframe.
    func marketContext(pairID: String, timeframe: String) -> MarketContext? {
        marketContext[Self.scanKey(pairID, timeframe)]
    }

    /// Setups on the radar for one pair on one timeframe.
    func alerts(pairID: String, timeframe: String) -> [RadarAlert] {
        alertsByKey[Self.scanKey(pairID, timeframe)] ?? []
    }

    /// Per-key scan throttle. One shared slot would let a fast timeframe
    /// starve the rest, so each key gets its own.
    private var lastEval: [String: (key: String, at: Date)] = [:]
    /// Keys with an auxiliary candle load in flight, so a burst of new bars
    /// doesn't queue several reads for the same timeframe.
    private var auxLoadsInFlight: Set<String> = []
    /// Keys already published at least once. A key's first publish is silent
    /// — enabling a timeframe shouldn't fire notifications for setups that
    /// have been resting there for hours.
    private var notifiedKeys: Set<String> = []

    nonisolated private static let scanTimeframesKey = "sentinel.scanTimeframes.v1"

    nonisolated static func scanKey(_ pairID: String, _ timeframe: String) -> String {
        "\(pairID)|\(timeframe)"
    }

    nonisolated private static func loadScanTimeframes() -> Set<Timeframe> {
        let raw = UserDefaults.standard.stringArray(forKey: scanTimeframesKey) ?? []
        return Set(raw.compactMap(Timeframe.init(rawValue:)))
    }

    nonisolated private static func saveScanTimeframes(_ set: Set<Timeframe>) {
        UserDefaults.standard.set(set.map(\.rawValue).sorted(), forKey: scanTimeframesKey)
    }

    func attach(database: AppDatabase) {
        self.database = database
    }

    /// The narrative half of a scan: what the indicator sees right now, and
    /// which rule is currently blocking a setup.
    struct MarketContext: Equatable {
        let contextLabel: String       // "Bullish BOS" / "—"
        let htfLabel: String
        let equilibrium: Double?
        let equilibriumState: String   // "Discount" / "Premium"
        let blocker: String            // "" when setups exist
    }

    private init() {}

    /// Runs the ALGOSMART-ASSIST-driven SMC pass for a symbol off the main
    /// actor and publishes the resulting setups.
    ///
    /// - Parameters:
    ///   - htfCandles: the context series. Pass the real higher-timeframe
    ///     bars when they are available; empty falls back to folding
    ///     `candles`, which is only correct in the absence of a database.
    ///   - minInterval: throttle floor for this key. The chart timeframe
    ///     ticks constantly and wants the historical 3s; an auxiliary
    ///     timeframe is re-read far less often.
    func evaluateSymbol(
        pairID: String,
        symbol: String,
        timeframe: String,
        candles: [Candle],
        htfCandles: [Candle] = [],
        htfLabel: String? = nil,
        minInterval: TimeInterval = 3.0
    ) {
        guard isSentinelActive, candles.count > 60, let latestCandle = candles.last else { return }

        let key = Self.scanKey(pairID, timeframe)
        let now = Date()
        let evalKey = "\(candles.count)|\(latestCandle.id.timeIntervalSince1970)"
        if let prior = lastEval[key], prior.key == evalKey,
           now.timeIntervalSince(prior.at) < minInterval {
            return
        }
        lastEval[key] = (evalKey, now)

        let tf = Timeframe(rawValue: timeframe)
        // `.d1` has no higher timeframe, so the engine falls back to its own
        // read. Label it rather than leaving an empty string to render as a
        // gap in the rationale and the drawer's context line.
        let resolvedHigher = tf?.higher
        let htfName = htfLabel.flatMap { $0.isEmpty ? nil : $0 }
            ?? resolvedHigher?.rawValue
            ?? "LTF"
        let stamp = latestCandle.id

        Task.detached(priority: .utility) {
            // Real HTF bars when the caller supplied them; otherwise fold the
            // LTF series by wall clock as a last resort.
            let contextCandles: [Candle]
            if !htfCandles.isEmpty {
                contextCandles = htfCandles
            } else if let tf, let higher = tf.higher {
                contextCandles = Self.aggregateCandles(candles, into: higher)
            } else {
                contextCandles = []
            }

            let result = SMCSentinelEngine.scan(
                candles: candles,
                htfCandles: contextCandles,
                htfLabel: htfName
            )

            let price = latestCandle.close
            let eqState: String
            if let eq = result.equilibrium {
                eqState = price < eq ? "Discount" : "Premium"
            } else {
                eqState = "—"
            }

            let context = MarketContext(
                contextLabel: result.context?.label ?? "—",
                htfLabel: htfName,
                equilibrium: result.equilibrium,
                equilibriumState: eqState,
                blocker: result.blocker == .none ? "" : result.blocker.rawValue
            )

            let alerts: [RadarAlert] = result.setups.map { setup in
                // Seeded on the zone's *geometry*, never on `setup.zoneID` —
                // that embeds a bar index, which shifts on every new bar and
                // whenever the loaded window slides, so an index-seeded id
                // would be fresh every pass. That would defeat the diff below
                // and reset the drawer's hover/expanded state under the
                // user's cursor.
                let seed = "\(pairID)|\(timeframe)|\(setup.isLong ? "BUY" : "SELL")"
                    + "|\(String(format: "%.4f", setup.zoneTop))"
                    + "|\(String(format: "%.4f", setup.zoneBottom))"
                return RadarAlert(
                    id: Self.deterministicUUID(from: seed),
                    symbol: symbol,
                    pairID: pairID,
                    timeframe: timeframe,
                    direction: setup.isLong ? .buy : .sell,
                    confluenceScore: setup.score,
                    entryPrice: setup.entry,
                    stopLoss: setup.stopLoss,
                    takeProfit: setup.takeProfit1,
                    takeProfit2: setup.takeProfit2,
                    riskRewardRatio: setup.riskReward,
                    rationale: setup.rationale,
                    createdAt: Date(),
                    zoneTop: setup.zoneTop,
                    zoneBottom: setup.zoneBottom,
                    equilibrium: setup.equilibrium,
                    htfLabel: htfName,
                    status: setup.status,
                    breakdown: setup.breakdown
                )
            }

            await MainActor.run {
                Self.shared.publishResultsIfChanged(
                    pairID: pairID, timeframe: timeframe, stamp: stamp,
                    newAlerts: alerts, context: context
                )
            }
        }
    }

    /// The single entry point `DashboardView` calls. Scans the chart's own
    /// timeframe from the candles already in memory, scans every other
    /// selected timeframe from its own DB read, and prunes whatever is no
    /// longer selected.
    ///
    /// Cheap to call on every tick: each key is throttled independently.
    func scan(
        pairID: String,
        symbol: String,
        chartTimeframe: Timeframe,
        chartCandles: [Candle],
        respectsWeekend: Bool,
        until: Date = Date()
    ) {
        prune(pairID: pairID, keeping: scanTimeframes.union([chartTimeframe]))

        evaluateSymbol(
            pairID: pairID,
            symbol: symbol,
            timeframe: chartTimeframe.rawValue,
            candles: chartCandles,
            htfCandles: contextSeries(
                pairID: pairID, above: chartTimeframe,
                respectsWeekend: respectsWeekend, until: until
            ),
            htfLabel: chartTimeframe.higher?.rawValue ?? ""
        )

        scanAuxiliaryTimeframes(
            pairID: pairID, symbol: symbol,
            chartTimeframe: chartTimeframe,
            respectsWeekend: respectsWeekend, until: until
        )
    }

    /// Cached higher-timeframe bars for a scanned timeframe. Returns `[]`
    /// (which makes `evaluateSymbol` fall back to the wall-clock fold) while
    /// the first read is in flight, and refreshes in the background once the
    /// cached copy goes stale — the chart path runs far too often to take a
    /// DB read every pass.
    private func contextSeries(
        pairID: String,
        above tf: Timeframe,
        respectsWeekend: Bool,
        until: Date
    ) -> [Candle] {
        guard let db = database, let higher = tf.higher else { return [] }
        let key = Self.scanKey(pairID, higher.rawValue)
        let cached = htfCache[key]

        let isStale = cached.map { Date().timeIntervalSince($0.at) > Self.htfCacheTTL } ?? true
        if isStale, !auxLoadsInFlight.contains("htf|\(key)") {
            auxLoadsInFlight.insert("htf|\(key)")
            Task { [weak self] in
                defer { self?.auxLoadsInFlight.remove("htf|\(key)") }
                let bars = await OHLCCandleLoader.loadAsync(
                    repo: db.ohlcRepo, pairID: pairID, tf: higher,
                    since: Self.windowStart(before: until, tf: higher), until: until,
                    dropClosedDays: respectsWeekend
                )
                guard !bars.isEmpty else { return }
                self?.htfCache[key] = (Array(bars.suffix(Self.maxContextBars)), Date())
            }
        }
        return cached?.candles ?? []
    }

    /// Scan every selected timeframe other than the one on the chart. Each
    /// needs its own candles, so this reads them through
    /// `OHLCCandleLoader` — the same path `reloadHTFChoch` and
    /// `reloadExternalEBP` use for a foreign timeframe — along with the
    /// timeframe above it for context.
    ///
    /// Cheap to call: keys already loading are skipped, and `evaluateSymbol`
    /// throttles the scan itself.
    func scanAuxiliaryTimeframes(
        pairID: String,
        symbol: String,
        chartTimeframe: Timeframe,
        respectsWeekend: Bool,
        until: Date = Date()
    ) {
        guard isSentinelActive, let db = database else { return }
        let wanted = scanTimeframes.subtracting([chartTimeframe])
        guard !wanted.isEmpty else { return }

        for tf in wanted.sorted(by: { $0.seconds < $1.seconds }) {
            let key = Self.scanKey(pairID, tf.rawValue)
            guard !auxLoadsInFlight.contains(key) else { continue }
            // The scan itself is throttled downstream, but the DB read is
            // not — skip it while the last one is still fresh.
            if let prior = lastEval[key], Date().timeIntervalSince(prior.at) < Self.auxScanInterval {
                continue
            }
            auxLoadsInFlight.insert(key)

            Task { [weak self] in
                defer { self?.auxLoadsInFlight.remove(key) }
                let ltf = await OHLCCandleLoader.loadAsync(
                    repo: db.ohlcRepo, pairID: pairID, tf: tf,
                    since: Self.windowStart(before: until, tf: tf), until: until,
                    dropClosedDays: respectsWeekend
                )
                guard ltf.count > 60 else { return }

                var htf: [Candle] = []
                if let higher = tf.higher {
                    htf = await OHLCCandleLoader.loadAsync(
                        repo: db.ohlcRepo, pairID: pairID, tf: higher,
                        since: Self.windowStart(before: until, tf: higher), until: until,
                        dropClosedDays: respectsWeekend
                    )
                    htf = Array(htf.suffix(Self.maxContextBars))
                }

                self?.evaluateSymbol(
                    pairID: pairID, symbol: symbol,
                    timeframe: tf.rawValue,
                    candles: Array(ltf.suffix(Self.maxScanBars)),
                    htfCandles: htf,
                    htfLabel: tf.higher?.rawValue ?? "",
                    minInterval: Self.auxScanInterval
                )
            }
        }
    }

    /// Drop everything that isn't for `pairID` on one of `timeframes`, plus
    /// the chart's own timeframe. Without this, deselecting a timeframe (or
    /// switching pair) would leave its rows on the radar forever.
    func prune(pairID: String?, keeping timeframes: Set<Timeframe>) {
        // The context cache is keyed by *higher* timeframe, which need not be
        // one of the scanned ones, so it can't be filtered against `live` —
        // drop it by pair instead.
        if let pairID {
            htfCache = htfCache.filter { $0.key.hasPrefix("\(pairID)|") }
        } else {
            htfCache.removeAll()
        }

        let live = Self.liveKeys(pairID: pairID, timeframes: timeframes)
        let staleAlerts = alertsByKey.keys.filter { !live.contains($0) }
        let staleContext = marketContext.keys.filter { !live.contains($0) }
        guard !staleAlerts.isEmpty || !staleContext.isEmpty else { return }
        for key in staleAlerts { alertsByKey[key] = nil }
        for key in staleContext { marketContext[key] = nil }
        notifiedKeys.subtract(staleAlerts)
        lastEval = lastEval.filter { live.contains($0.key) }
        publishedStamp = publishedStamp.filter { live.contains($0.key) }
    }

    /// The keys that should survive a prune. Pure so it can be tested
    /// without the main actor.
    nonisolated static func liveKeys(pairID: String?, timeframes: Set<Timeframe>) -> Set<String> {
        guard let pairID else { return [] }
        return Set(timeframes.map { scanKey(pairID, $0.rawValue) })
    }

    private var htfCache: [String: (candles: [Candle], at: Date)] = [:]
    /// The newest bar each key has published for, so an out-of-order result
    /// can be dropped.
    private var publishedStamp: [String: Date] = [:]

    /// How far back to read for a timeframe. `maxScanBars` bars' worth, with
    /// slack for closed sessions — the engine drops zones older than 500 bars
    /// anyway, so reading the whole stored series would be waste.
    nonisolated static func windowStart(before until: Date, tf: Timeframe) -> Date {
        until.addingTimeInterval(-tf.seconds * Double(maxScanBars) * 2.5)
    }

    /// How often an auxiliary timeframe is re-read. A 15m bar cannot change
    /// its structural read faster than this, and the DB read is not free.
    private static let auxScanInterval: TimeInterval = 30
    /// The chart path reuses a cached context series for this long. Shorter
    /// than the shortest timeframe that can be a *higher* one, so the context
    /// is never more than a fraction of a bar behind.
    private static let htfCacheTTL: TimeInterval = 60
    nonisolated static let maxScanBars = 600
    private static let maxContextBars = 400

    /// Publish an EBP read for a symbol. Idempotent — an identical
    /// snapshot is dropped so the drawer doesn't re-render on every tick
    /// that changed nothing.
    func publishEBP(pairID: String, symbol: String, timeframe: String, output: EngulfingBarPlay.Output) {
        let snapshot = EBPRadarSnapshot(
            pairID: pairID,
            symbol: symbol,
            timeframe: timeframe,
            setups: output.setups,
            stats: output.stats,
            updatedAt: Date()
        )
        let existing = ebpSnapshots[pairID]
        let unchanged = existing?.timeframe == snapshot.timeframe
            && existing?.setups == snapshot.setups
            && existing?.stats == snapshot.stats
        guard !unchanged else { return }
        ebpSnapshots[pairID] = snapshot
    }

    /// Drop a symbol's EBP read — the indicator was turned off.
    func clearEBP(pairID: String) {
        guard ebpSnapshots[pairID] != nil else { return }
        ebpSnapshots[pairID] = nil
    }

    /// A stable UUID for a seed string. Two alerts sharing an id would
    /// corrupt both the `ForEach` identity in the drawer and the diff in
    /// `publishResultsIfChanged`, so this runs a real hash (FNV-1a, four
    /// independently-seeded lanes) rather than the byte-XOR fold it used to
    /// — that collided on any two same-length seeds with characters swapped
    /// 16 apart, which is exactly what near-identical zone prices look like.
    nonisolated static func deterministicUUID(from seed: String) -> UUID {
        let bytes = Array(seed.utf8)
        var hash = [UInt8](repeating: 0, count: 16)
        for lane in 0..<4 {
            var h: UInt64 = 0xcbf2_9ce4_8422_2325 &+ UInt64(lane) &* 0x9e37_79b9_7f4a_7c15
            for b in bytes {
                h ^= UInt64(b)
                h = h &* 0x0000_0100_0000_01b3
            }
            for byte in 0..<4 {
                hash[lane * 4 + byte] = UInt8(truncatingIfNeeded: h >> (UInt64(byte) * 8))
            }
        }
        hash[6] = (hash[6] & 0x0f) | 0x40
        hash[8] = (hash[8] & 0x3f) | 0x80
        return UUID(uuid: (
            hash[0], hash[1], hash[2], hash[3],
            hash[4], hash[5], hash[6], hash[7],
            hash[8], hash[9], hash[10], hash[11],
            hash[12], hash[13], hash[14], hash[15]
        ))
    }

    private func publishResultsIfChanged(
        pairID: String,
        timeframe: String,
        stamp: Date,
        newAlerts: [RadarAlert],
        context: MarketContext
    ) {
        let key = Self.scanKey(pairID, timeframe)
        // Scans are detached and differ in cost, so a slow one started
        // earlier can land after a fast one started later. Dropping the older
        // result keeps the radar from settling on stale geometry.
        if let seen = publishedStamp[key], seen > stamp { return }
        publishedStamp[key] = stamp

        if marketContext[key] != context {
            marketContext[key] = context
        }

        // Only this pair-and-timeframe's alerts are replaced; every other
        // key keeps its own.
        let mine = alertsByKey[key] ?? []

        let alertsEqual = mine.count == newAlerts.count &&
            zip(mine, newAlerts).allSatisfy { a, b in
                a.id == b.id &&
                a.confluenceScore == b.confluenceScore &&
                a.status == b.status &&
                abs(a.entryPrice - b.entryPrice) < 0.0001 &&
                abs(a.stopLoss - b.stopLoss) < 0.0001 &&
                abs(a.takeProfit - b.takeProfit) < 0.0001 &&
                abs(a.takeProfit2 - b.takeProfit2) < 0.0001
            }

        if !alertsEqual {
            alertsByKey[key] = newAlerts.isEmpty ? nil : newAlerts
            lastScanTimestamp = Date()

            // First publish for a key is a silent baseline: ticking a
            // timeframe on shouldn't fire notifications for setups that have
            // been resting there for hours.
            let isBaseline = notifiedKeys.insert(key).inserted
            guard !isBaseline else { return }

            for alert in newAlerts where alert.confluenceScore >= 70 {
                let stage = alert.status == .active ? "TRIGGERED" : alert.status.rawValue
                notificationInbox?.record(
                    dedupKey: "sentinel|\(alert.pairID)|\(alert.direction.rawValue)|\(alert.timeframe)|\(String(format: "%.1f", alert.entryPrice))|\(alert.status.rawValue)",
                    cooldown: 1800, // 30 mins dedup
                    pairID: alert.pairID,
                    pairLabel: alert.symbol,
                    category: .strategy,
                    title: "⚡ SMC Sentinel: \(alert.symbol) \(alert.direction.rawValue) · \(stage) (\(alert.confluenceScore)%)",
                    body: "\(alert.rationale) | SL: \(PriceFormat.exact(alert.stopLoss)) | TP1: \(PriceFormat.exact(alert.takeProfit)) | TP2: \(PriceFormat.exact(alert.takeProfit2)).",
                    timeframeLabel: alert.timeframe
                )
            }
        }
    }

    /// Fold a series up into `target` bars, bucketing by **wall clock**.
    ///
    /// Only used when no database is attached — the normal path reads real
    /// higher-timeframe bars. Bucketing by array index (which this used to
    /// do) is wrong the moment history is prepended by infinite scroll: every
    /// bucket boundary shifts, which can flip the structural read and with it
    /// the radar's traded direction. Anchoring on the timestamp makes the
    /// fold independent of where the array happens to start.
    nonisolated static func aggregateCandles(_ candles: [Candle], into target: Timeframe) -> [Candle] {
        let bucket = target.seconds
        guard bucket > 0, !candles.isEmpty else { return candles }

        var result: [Candle] = []
        var open = 0.0, high = 0.0, low = 0.0, close = 0.0, volume = 0.0
        var start: Date? = nil
        var currentBucket = -Double.greatestFiniteMagnitude

        func flush() {
            guard let start else { return }
            result.append(Candle(id: start, open: open, high: high, low: low,
                                 close: close, volume: volume))
        }

        for c in candles {
            let slot = (c.id.timeIntervalSince1970 / bucket).rounded(.down)
            if slot != currentBucket {
                flush()
                currentBucket = slot
                start = Date(timeIntervalSince1970: slot * bucket)
                open = c.open; high = c.high; low = c.low
                volume = 0
            } else {
                if c.high > high { high = c.high }
                if c.low < low { low = c.low }
            }
            close = c.close
            volume += (c.volume ?? 1.0)
        }
        flush()
        return result
    }
}

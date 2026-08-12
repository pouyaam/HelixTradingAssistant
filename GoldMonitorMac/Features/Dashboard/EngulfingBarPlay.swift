import Foundation

/// EBP — Engulfing Bar Play (the Omar Agag swing model).
///
/// Ported from the PineScript v6 indicator "EBP – Engulfing Bar Play".
///
/// ## The pattern
///
/// A **bullish EBP** is one candle that:
///
/// 1. sweeps *below* the previous candle's low,
/// 2. makes that sweep with its lower **shadow** — the body never trades
///    under the swept low (`wickOnlySweep`),
/// 3. closes back *above* the previous candle's body (or above its high,
///    with `requireFullEngulf`), and
/// 4. follows a *bearish* candle (`requireOppositeColour`).
///
/// A **bearish EBP** is the exact mirror. Both are read at the close.
///
/// ## The trade
///
/// The EBP candle's own range is the fib: 0 at the extreme it pushed
/// toward, 1 at the extreme it swept. Where the close sits inside that
/// range decides the model:
///
/// - **Strong close** — within `strongClosePercent` of the extreme. The
///   candle did its work, so the order rests shallow: entry at a
///   `strongEntryPercent` retrace, stop at `strongStopPercent`.
/// - **Indecisive close** — anywhere further back. Entry drops to
///   `indecisiveEntryPercent` (the midpoint by default) and the stop
///   goes all the way to the swept extreme, i.e. behind the whole
///   candle.
/// - A close that is *already beyond* the 50% level would leave a limit
///   order sitting on the wrong side of price, so
///   `marketEntryBeyondHalf` takes that one at the close instead.
///
/// The target is `riskReward × risk` off the fill.
///
/// ## One trade at a time
///
/// The Pine original holds a single state machine — a pattern that
/// prints while an order is resting or a position is open is drawn but
/// not traded. That is ported as-is: every detection becomes a `Setup`,
/// but one that arrives while another is working is marked `.skipped`
/// and carries no plan. It keeps `stats` honest and keeps the chart
/// showing every pattern the eye can see.
///
/// The Pine `htfOnly` switch (4H and above) is generalised here to
/// `minTimeframeMinutes`, since a Swift engine only ever sees candles —
/// the bar spacing is inferred from the series itself.
///
/// Pure functions, no state — `ChartView` maps the result into marks.
enum EngulfingBarPlay {

    // MARK: - Types

    enum Direction: String, Hashable, Codable {
        case long
        case short

        var isLong: Bool { self == .long }
    }

    /// Directional gate.
    enum DirectionMode: String, Hashable, Sendable {
        case both, long, short

        init(_ raw: String) {
            switch raw.lowercased() {
            case "long":  self = .long
            case "short": self = .short
            default:      self = .both
            }
        }

        var allowsLong: Bool { self != .short }
        var allowsShort: Bool { self != .long }
    }

    /// Where the EBP candle closed inside its own range — the input the
    /// whole trade model keys off.
    enum CloseQuality: String, Hashable, Codable {
        /// Within `strongClosePercent` of the extreme it pushed toward.
        case strong
        /// Further back than that — the candle hesitated.
        case indecisive

        var label: String { self == .strong ? "strong" : "indecisive" }
    }

    /// How the position is taken.
    enum EntryKind: String, Hashable, Codable {
        /// A resting order at the retrace level.
        case limit
        /// The close was already past the 50% level, so there was nothing
        /// to wait for.
        case market

        var label: String { self == .market ? "market" : "limit" }
    }

    /// Lifecycle of one setup.
    enum Status: String, Hashable, Codable {
        /// Limit order resting, not filled yet.
        case pending
        /// Filled; neither level hit yet.
        case triggered
        case hitTP
        case hitSL
        /// Stopped out *after* the breakeven rule moved the stop to
        /// entry — neither a win nor a loss, as in the original.
        case breakeven
        /// The limit expired unfilled after `expiryBars`.
        case cancelled
        /// The pattern printed while another setup was working, so it was
        /// never traded.
        case skipped

        var isResolved: Bool {
            self == .hitTP || self == .hitSL || self == .breakeven
        }
        /// Never became a position — drawn as a bare marker, not a plan.
        var isUntriggered: Bool {
            self == .pending || self == .cancelled || self == .skipped
        }
    }

    // MARK: - Configuration

    struct Configuration: Hashable, Sendable {
        // ── Pattern rules ────────────────────────────────────────────
        var directionMode = DirectionMode.both
        /// Bullish EBP must follow a down candle, bearish an up candle.
        /// The original model allows same-colour candles; turn this off
        /// to match it.
        var requireOppositeColour = true
        /// The body must stay above the swept low (below the swept high)
        /// — only the wick takes the level out.
        var wickOnlySweep = true
        /// Close must clear the previous candle's high/low rather than
        /// just its body.
        var requireFullEngulf = false
        /// Minimum EBP candle range in ATR. 0 = off.
        var minRangeATR = 0.0
        var atrLength = 14
        /// Only signal at or above this bar size, in minutes (the Pine
        /// `htfOnly` switch, which was fixed at 4H). 0 = off.
        var minTimeframeMinutes = 0.0

        // ── Trade model ──────────────────────────────────────────────
        /// How close to the extreme still counts as a decisive close.
        var strongClosePercent = 15.0
        var strongEntryPercent = 25.0
        var strongStopPercent = 75.0
        var indecisiveEntryPercent = 50.0
        /// Take the trade at the close when the close is already beyond
        /// the 50% level.
        var marketEntryBeyondHalf = true
        var riskReward = 2.0
        /// Cancel an unfilled limit after N bars. 0 = never.
        var expiryBars = 20
        /// Move the stop to entry on a new extreme beyond the EBP candle.
        var breakevenOnNewExtreme = false

        // ── Display ──────────────────────────────────────────────────
        /// Cap on setups kept, newest first.
        var maxSetups = 8
    }

    // MARK: - Results

    /// One detected pattern, with the plan it produced (if any).
    struct Setup: Identifiable, Hashable {
        let direction: Direction
        /// Bar the EBP candle printed on.
        let index: Int
        /// The EBP candle's own range — the fib the model is drawn on.
        let barHigh: Double
        let barLow: Double

        let closeQuality: CloseQuality
        let entryKind: EntryKind
        /// Where the order rests (or the close it was taken at).
        let entryLevel: Double
        /// `nil` on a `.skipped` setup — it was never planned.
        let stopLoss: Double?
        let takeProfit: Double?

        /// Bar the order filled on. Equals `index` for a market entry.
        var triggerIndex: Int?
        /// Bar the trade ended, or the limit was cancelled.
        var resolveIndex: Int?
        var status: Status
        /// The breakeven rule moved the stop before the trade ended.
        var movedToBreakeven = false

        // ── Wall-clock anchors ───────────────────────────────────────
        // Bar indices only mean something inside the series they were
        // computed on. When the indicator runs on a timeframe other than
        // the one on screen, the chart re-projects it through these.
        var barDate: Date?
        var triggerDate: Date?
        var resolveDate: Date?

        var id: String { "ebp-\(direction.rawValue)-\(index)" }

        /// Rightmost bar this setup still has something to say about.
        var lastRelevantIndex: Int {
            resolveIndex ?? triggerIndex ?? index
        }

        /// What the trade paid, in R. `nil` while it is still open.
        var rMultiple: Double? {
            switch status {
            case .hitTP:
                guard let entry = filledEntry, let stop = stopLoss, let target = takeProfit else { return nil }
                let risk = abs(entry - stop)
                return risk > 0 ? abs(target - entry) / risk : nil
            case .hitSL:     return -1
            case .breakeven: return 0
            default:         return nil
            }
        }

        /// The price the position was actually taken at, once filled.
        var filledEntry: Double? {
            triggerIndex == nil ? nil : entryLevel
        }

        /// "EBP strong · limit" — the chart badge.
        var badge: String {
            status == .skipped
                ? "EBP \(closeQuality.label)"
                : "EBP \(closeQuality.label) · \(entryKind.label)"
        }
    }

    /// The Pine info table, as data. Nothing draws it yet; the legend is
    /// the natural home if it is ever wanted.
    struct Stats: Equatable {
        var setups = 0
        var wins = 0
        var losses = 0
        var breakevens = 0
        var cancelled = 0
        var totalR = 0.0

        /// Breakevens are excluded from the denominator, as in the
        /// original — they are neither a win nor a loss.
        var winRate: Double? {
            let decided = wins + losses
            return decided > 0 ? Double(wins) / Double(decided) * 100 : nil
        }
    }

    struct Output: Equatable {
        var setups: [Setup] = []
        var stats = Stats()

        static let empty = Output()
    }

    // MARK: - Working state

    /// The Pine state machine's live slot: one order or position at a
    /// time, keyed by the index of the `setups` entry it belongs to.
    private struct Working {
        let slot: Int
        let direction: Direction
        let entry: Double
        var stop: Double
        let target: Double
        /// The EBP candle's extremes — the breakeven rule's trigger.
        let barHigh: Double
        let barLow: Double
        let armIndex: Int
        var filled: Bool
        var movedToBreakeven = false
    }

    // MARK: - Entry point

    static func compute(_ candles: [Candle], configuration raw: Configuration = Configuration()) -> Output {
        let cfg = sanitized(raw)
        let n = candles.count
        guard n > 2 else { return .empty }
        guard timeframeAllows(candles, cfg: cfg) else { return .empty }

        let atr = wilderATR(candles, period: cfg.atrLength)

        var setups: [Setup] = []
        var live: Working?
        var stats = Stats()

        for i in 1..<n {
            let bar = candles[i]

            // ── Manage the open order / position first ───────────────
            // Pine's `newSig` branch is exclusive with the management
            // branch: a bar that arms a fresh setup never also advances
            // the previous one — but a bar can only arm while flat, so
            // running management first is the same ordering.
            if var working = live {
                let done = advance(&working, bar: bar, at: i, setups: &setups, stats: &stats, cfg: cfg)
                live = done ? nil : working
            }

            // ── Detect ──────────────────────────────────────────────
            guard let direction = pattern(candles, at: i, atr: atr, cfg: cfg) else { continue }

            let plan = plan(for: bar, direction: direction, cfg: cfg)

            // A pattern printing on top of a working setup is drawn but
            // not traded — the original holds one slot.
            guard live == nil else {
                setups.append(Setup(
                    direction: direction, index: i,
                    barHigh: bar.high, barLow: bar.low,
                    closeQuality: plan.quality, entryKind: plan.kind,
                    entryLevel: plan.entry, stopLoss: nil, takeProfit: nil,
                    triggerIndex: nil, resolveIndex: nil, status: .skipped
                ))
                continue
            }

            let isMarket = plan.kind == .market
            setups.append(Setup(
                direction: direction, index: i,
                barHigh: bar.high, barLow: bar.low,
                closeQuality: plan.quality, entryKind: plan.kind,
                entryLevel: plan.entry, stopLoss: plan.stop, takeProfit: plan.target,
                triggerIndex: isMarket ? i : nil, resolveIndex: nil,
                status: isMarket ? .triggered : .pending
            ))
            stats.setups += 1

            live = Working(
                slot: setups.count - 1,
                direction: direction,
                entry: plan.entry,
                stop: plan.stop,
                target: plan.target,
                barHigh: bar.high,
                barLow: bar.low,
                armIndex: i,
                filled: isMarket
            )
        }

        // Newest first, capped for the chart, then date-stamped so a
        // result computed on one timeframe can be drawn on another.
        let ordered = setups.sorted { $0.index > $1.index }
        let capped = ordered.prefix(cfg.maxSetups).map { setup -> Setup in
            var dated = setup
            func date(_ i: Int?) -> Date? {
                guard let i, candles.indices.contains(i) else { return nil }
                return candles[i].bucketStart
            }
            dated.barDate = date(setup.index)
            dated.triggerDate = date(setup.triggerIndex)
            dated.resolveDate = date(setup.resolveIndex)
            return dated
        }
        return Output(setups: capped, stats: stats)
    }

    // MARK: - Detection

    /// The pattern test for one bar, or `nil` if it isn't an EBP.
    /// Bullish and bearish can both read true on a wide outside bar; as
    /// in the original, bullish wins.
    private static func pattern(
        _ candles: [Candle],
        at i: Int,
        atr: [Double],
        cfg: Configuration
    ) -> Direction? {
        let bar = candles[i]
        let previous = candles[i - 1]

        guard cfg.minRangeATR <= 0 || (bar.high - bar.low) >= cfg.minRangeATR * atr[i] else {
            return nil
        }

        let previousBodyHigh = max(previous.open, previous.close)
        let previousBodyLow = min(previous.open, previous.close)
        let bodyHigh = max(bar.open, bar.close)
        let bodyLow = min(bar.open, bar.close)

        // The sweep has to come from the shadow: the body never trades
        // beyond the level it took out.
        let sweptLow = bar.low < previous.low
            && (!cfg.wickOnlySweep || bodyLow >= previous.low)
        let sweptHigh = bar.high > previous.high
            && (!cfg.wickOnlySweep || bodyHigh <= previous.high)

        let closedUp = cfg.requireFullEngulf ? bar.close > previous.high : bar.close > previousBodyHigh
        let closedDown = cfg.requireFullEngulf ? bar.close < previous.low : bar.close < previousBodyLow

        let previousBearish = previous.close < previous.open
        let previousBullish = previous.close > previous.open

        if sweptLow, closedUp, cfg.directionMode.allowsLong,
           !cfg.requireOppositeColour || previousBearish {
            return .long
        }
        if sweptHigh, closedDown, cfg.directionMode.allowsShort,
           !cfg.requireOppositeColour || previousBullish {
            return .short
        }
        return nil
    }

    // MARK: - Trade model

    private struct Plan {
        let quality: CloseQuality
        let kind: EntryKind
        let entry: Double
        let stop: Double
        let target: Double
    }

    /// The fib is the EBP candle itself: 0 at the extreme it pushed
    /// toward, 1 at the one it swept.
    private static func plan(for bar: Candle, direction: Direction, cfg: Configuration) -> Plan {
        let isLong = direction.isLong
        // A doji with high == low would divide by zero; nothing about the
        // model is meaningful there, but it must not produce a NaN.
        let range = max(bar.high - bar.low, .ulpOfOne)

        // How far the close sits from the extreme it pushed toward.
        let closeRetrace = isLong ? (bar.high - bar.close) / range : (bar.close - bar.low) / range
        let quality: CloseQuality = closeRetrace <= cfg.strongClosePercent / 100 ? .strong : .indecisive

        let entryPercent = quality == .strong ? cfg.strongEntryPercent : cfg.indecisiveEntryPercent
        let limitEntry = isLong
            ? bar.high - entryPercent / 100 * range
            : bar.low + entryPercent / 100 * range

        // A strong close keeps the stop inside the candle; an indecisive
        // one puts it behind the whole thing.
        let stop = quality == .strong
            ? (isLong ? bar.high - cfg.strongStopPercent / 100 * range
                      : bar.low + cfg.strongStopPercent / 100 * range)
            : (isLong ? bar.low : bar.high)

        // A limit that is already on the wrong side of price would never
        // fill on the way the model expects.
        let beyondHalf = isLong
            ? bar.close < bar.high - 0.5 * range
            : bar.close > bar.low + 0.5 * range
        let takeAtMarket = cfg.marketEntryBeyondHalf && quality == .indecisive && beyondHalf

        let entry = takeAtMarket ? bar.close : limitEntry
        let target = entry + (isLong ? 1 : -1) * cfg.riskReward * abs(entry - stop)

        return Plan(
            quality: quality,
            kind: takeAtMarket ? .market : .limit,
            entry: entry,
            stop: stop,
            target: target
        )
    }

    // MARK: - State machine

    /// Advance the working order/position by one bar. Returns `true` when
    /// the slot is free again.
    private static func advance(
        _ working: inout Working,
        bar: Candle,
        at i: Int,
        setups: inout [Setup],
        stats: inout Stats,
        cfg: Configuration
    ) -> Bool {
        let isLong = working.direction.isLong

        // ── Resting limit ───────────────────────────────────────────
        if !working.filled {
            let filled = isLong ? bar.low <= working.entry : bar.high >= working.entry
            if filled {
                working.filled = true
                setups[working.slot].triggerIndex = i
                setups[working.slot].status = .triggered
                // Fall through: the fill bar can also reach a level, as
                // in the original.
            } else {
                if cfg.expiryBars > 0, i - working.armIndex >= cfg.expiryBars {
                    setups[working.slot].status = .cancelled
                    setups[working.slot].resolveIndex = i
                    stats.cancelled += 1
                    return true
                }
                return false
            }
        }

        // ── Open position ───────────────────────────────────────────
        if cfg.breakevenOnNewExtreme, !working.movedToBreakeven,
           isLong ? bar.high > working.barHigh : bar.low < working.barLow {
            working.stop = working.entry
            working.movedToBreakeven = true
            setups[working.slot].movedToBreakeven = true
        }

        let hitStop = isLong ? bar.low <= working.stop : bar.high >= working.stop
        let hitTarget = isLong ? bar.high >= working.target : bar.low <= working.target

        // A bar that spans both reads as a loss — intrabar order is
        // unknowable from OHLC, the same call every sibling engine makes.
        if hitTarget && !hitStop {
            setups[working.slot].status = .hitTP
            setups[working.slot].resolveIndex = i
            stats.wins += 1
            stats.totalR += cfg.riskReward
            return true
        }
        if hitStop {
            setups[working.slot].resolveIndex = i
            if working.movedToBreakeven {
                setups[working.slot].status = .breakeven
                stats.breakevens += 1
            } else {
                setups[working.slot].status = .hitSL
                stats.losses += 1
                stats.totalR -= 1
            }
            return true
        }
        return false
    }

    // MARK: - Timeframe gate

    /// Bar size inferred from the series — the smallest positive gap
    /// between consecutive bars, which weekend and holiday gaps can only
    /// widen, never shrink.
    private static func timeframeAllows(_ candles: [Candle], cfg: Configuration) -> Bool {
        guard cfg.minTimeframeMinutes > 0 else { return true }
        var spacing = Double.greatestFiniteMagnitude
        for i in 1..<candles.count {
            let gap = candles[i].id.timeIntervalSince(candles[i - 1].id)
            if gap > 0 { spacing = min(spacing, gap) }
        }
        guard spacing < .greatestFiniteMagnitude else { return true }
        return spacing >= cfg.minTimeframeMinutes * 60
    }

    // MARK: - Series helpers

    /// Wilder-smoothed ATR, seeded with the simple mean of the first
    /// `period` true ranges — matches Pine's `ta.atr`.
    private static func wilderATR(_ candles: [Candle], period: Int) -> [Double] {
        let n = candles.count
        var out = [Double](repeating: 0, count: n)
        guard n > 1 else { return out }

        var trueRanges = [Double](repeating: 0, count: n)
        trueRanges[0] = candles[0].high - candles[0].low
        for i in 1..<n {
            let previousClose = candles[i - 1].close
            trueRanges[i] = max(
                candles[i].high - candles[i].low,
                max(abs(candles[i].high - previousClose), abs(candles[i].low - previousClose))
            )
        }
        guard n >= period, period > 0 else { return trueRanges }

        var seed = 0.0
        for i in 0..<period { seed += trueRanges[i] }
        var atr = seed / Double(period)
        for i in 0..<period { out[i] = atr }
        for i in period..<n {
            atr = (atr * Double(period - 1) + trueRanges[i]) / Double(period)
            out[i] = atr
        }
        return out
    }

    // MARK: - Config hygiene

    private static func sanitized(_ cfg: Configuration) -> Configuration {
        var c = cfg
        c.atrLength = max(2, c.atrLength)
        c.minRangeATR = max(0, c.minRangeATR)
        c.minTimeframeMinutes = max(0, c.minTimeframeMinutes)
        c.strongClosePercent = min(max(1, c.strongClosePercent), 49)
        c.strongEntryPercent = min(max(1, c.strongEntryPercent), 99)
        c.strongStopPercent = min(max(2, c.strongStopPercent), 100)
        c.indecisiveEntryPercent = min(max(1, c.indecisiveEntryPercent), 99)
        c.riskReward = max(0.1, c.riskReward)
        c.expiryBars = max(0, c.expiryBars)
        c.maxSetups = max(1, c.maxSetups)
        return c
    }
}

extension EngulfingBarPlay.Configuration {
    /// Build from an `IndicatorInstance`'s param dictionary. Mirrors how
    /// `RankedSP2LBTB` / `AMDCycle` / `AlgoSmartAssist` read their
    /// settings — the newer indicators skip the `OscillatorConfig`
    /// mirror entirely.
    init(params: [String: ParamValue]) {
        self.init()
        if let v = params["directionMode"]         { directionMode = EngulfingBarPlay.DirectionMode(v.stringValue) }
        if let v = params["requireOppositeColour"] { requireOppositeColour = v.boolValue }
        if let v = params["wickOnlySweep"]         { wickOnlySweep = v.boolValue }
        if let v = params["requireFullEngulf"]     { requireFullEngulf = v.boolValue }
        if let v = params["minRangeATR"]           { minRangeATR = v.doubleValue }
        if let v = params["atrLength"]             { atrLength = Int(v.doubleValue) }
        if let v = params["minTimeframeMinutes"]   { minTimeframeMinutes = v.doubleValue }

        if let v = params["strongClosePercent"]      { strongClosePercent = v.doubleValue }
        if let v = params["strongEntryPercent"]      { strongEntryPercent = v.doubleValue }
        if let v = params["strongStopPercent"]       { strongStopPercent = v.doubleValue }
        if let v = params["indecisiveEntryPercent"]  { indecisiveEntryPercent = v.doubleValue }
        if let v = params["marketEntryBeyondHalf"]   { marketEntryBeyondHalf = v.boolValue }
        if let v = params["riskReward"]              { riskReward = v.doubleValue }
        if let v = params["expiryBars"]              { expiryBars = Int(v.doubleValue) }
        if let v = params["breakevenOnNewExtreme"]   { breakevenOnNewExtreme = v.boolValue }

        if let v = params["maxSetups"]               { maxSetups = Int(v.doubleValue) }
    }
}

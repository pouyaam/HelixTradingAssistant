import Foundation

/// AMD — Accumulation · Manipulation · Distribution.
///
/// A phase detector, not a pattern matcher. Markets rotate through
/// phases that let large participants build inventory, protect it, and
/// eventually unload it; the framework explains *intent* at a location
/// rather than predicting a turning point. This engine reads that
/// rotation off raw OHLC and marks where each phase started, so the
/// chart can say "you are trading inside a manipulation leg" instead of
/// only "a candle closed above a line".
///
/// The cycle it looks for:
///
/// 1. **Accumulation** — a contained range after a move: volatility
///    contracts, the high/low band stays inside `maxRangeATR × ATR`, and
///    the bars inside it are smaller than the bars that led in. Inventory
///    is being built; breakouts here fail because the market is still
///    absorbing, not expanding.
/// 2. **Manipulation** — a sharp excursion beyond the range edge that
///    takes the stops resting there, followed by a close back *inside*
///    the range. The lack of follow-through is the whole tell: the
///    breakout filled orders, it didn't establish direction. Sweeping the
///    lows implies the expansion is up; sweeping the highs implies down.
/// 3. **Expansion** — a close beyond the *opposite* edge by at least
///    `minExpansionATR × ATR`. This displacement leg is what the earlier
///    two phases were building toward, and it moves fast enough to leave
///    an inefficiency behind.
/// 4. **Distribution** — the leg stalls: bars stop making new extremes
///    and re-contract into a band. Positions built in phase 1 are being
///    reduced here. It is a risk-management signal, not an entry.
///
/// **The entry** is the fair value gap left inside the displacement leg
/// (`EntryGap`). A three-candle imbalance means price moved too fast for
/// the opposite side to trade — the retrace into it is where the move
/// offers a fill at a price it skipped, with the manipulation extreme as
/// a natural invalidation point. No FVG in the leg means no entry: the
/// expansion was orderly, and there is nothing to retrace into.
///
/// Pure functions, no state — `ChartView` / `ChartViewiPad` map the
/// result into marks, exactly like `MTRSetup` / `RankedOBStrategy`.
enum AMDCycle {

    // MARK: - Types

    enum Direction: String, Hashable, Codable {
        case long
        case short

        var isLong: Bool { self == .long }
    }

    /// Which side of the accumulation range the manipulation took out.
    /// Sweeping buy-side liquidity (above the highs) fuels a move *down*,
    /// and vice versa — the sweep is fuel, not direction.
    enum SweptSide: String, Hashable, Codable {
        case high
        case low
    }

    /// Where the cycle currently stands. Ordered by progression, so a
    /// cycle only ever moves forward through them (or to `.failed`).
    enum Phase: String, Hashable, Codable {
        /// Range formed, no liquidity taken yet — patience, wait.
        case accumulation
        /// Liquidity swept and reclaimed, displacement not confirmed —
        /// restraint, do not chase.
        case manipulation
        /// Displacement confirmed; the entry gap (if any) is live.
        case expansion
        /// The leg stalled — reduce exposure, manage risk.
        case distribution
        /// Swept and reclaimed, but the expansion never came (or the
        /// sweep extreme was traded back through). Hidden by default.
        case failed

        var label: String {
            switch self {
            case .accumulation: return "Accumulation"
            case .manipulation: return "Manipulation"
            case .expansion:    return "Expansion"
            case .distribution: return "Distribution"
            case .failed:       return "Failed"
            }
        }

        /// Single-letter chart badge — A / M / D, the way the framework
        /// is drawn by hand.
        var badge: String {
            switch self {
            case .accumulation: return "A"
            case .manipulation: return "M"
            case .expansion:    return "D"
            case .distribution: return "D"
            case .failed:       return "×"
            }
        }
    }

    /// Lifecycle of the FVG entry inside a confirmed expansion.
    enum TradeState: String, Hashable, Codable {
        /// Gap formed, price has not returned to it.
        case armed
        /// Price traded into the gap — position open.
        case filled
        /// First target reached.
        case tp1
        /// Final target reached.
        case tp2
        /// Invalidation (beyond the manipulation extreme) hit.
        case stopped

        var isResolved: Bool { self == .tp2 || self == .stopped }
    }

    /// The fair value gap the displacement left behind, plus the trade
    /// plan derived from it. `index` is the middle bar of the three-bar
    /// imbalance — the rectangle's left edge, same convention as
    /// `FairValueGap.Zone`.
    struct EntryGap: Hashable, Codable {
        let index: Int
        let high: Double
        let low: Double
        /// The edge price retraces into first (gap high for a short,
        /// gap low for a long — the near side of the imbalance).
        let proximal: Double
        /// The far edge; price has to cross the whole gap to reach it.
        let distal: Double

        let entry: Double
        let stopLoss: Double
        let takeProfit1: Double
        let takeProfit2: Double

        /// Bar where price first traded through `entry`.
        var fillIndex: Int?
        /// Bar where the plan finished (target or stop).
        var resolveIndex: Int?
        var state: TradeState

        var mid: Double { (high + low) / 2 }
        var risk: Double { abs(entry - stopLoss) }
        var riskReward: Double {
            let r = risk
            guard r > 0 else { return 0 }
            return abs(takeProfit2 - entry) / r
        }
    }

    /// One detected rotation. Every bar index refers to the candle array
    /// the cycle was computed from.
    struct Cycle: Identifiable, Hashable {
        // ── Accumulation ──────────────────────────────────────────────
        let rangeStart: Int
        let rangeEnd: Int
        let rangeHigh: Double
        let rangeLow: Double

        // ── Manipulation ──────────────────────────────────────────────
        /// Bar that took the liquidity. `nil` while the range is still
        /// unchallenged (`phase == .accumulation`).
        var sweepIndex: Int?
        /// The wick extreme of the sweep — the invalidation reference for
        /// the whole cycle.
        var sweepPrice: Double?
        var sweptSide: SweptSide?
        /// Bar that closed back inside the range, turning a breakout into
        /// a manipulation. May equal `sweepIndex` (a single rejection bar).
        var reclaimIndex: Int?

        // ── Expansion / distribution ──────────────────────────────────
        /// Bar whose close cleared the opposite edge by the required
        /// displacement.
        var expansionIndex: Int?
        /// Furthest point the leg reached, and where.
        var expansionExtreme: Double?
        var expansionExtremeIndex: Int?
        /// Bar from which the leg stopped making progress.
        var distributionIndex: Int?

        var gap: EntryGap?
        var phase: Phase

        /// Long once the lows are swept, short once the highs are — nil
        /// while the range is still unchallenged.
        var direction: Direction? {
            guard let side = sweptSide else { return nil }
            return side == .low ? .long : .short
        }

        var rangeMid: Double { (rangeHigh + rangeLow) / 2 }
        var rangeHeight: Double { rangeHigh - rangeLow }

        /// Rightmost bar this cycle has anything to say about — the chart
        /// extends live elements from here to the right edge.
        var lastRelevantIndex: Int {
            gap?.resolveIndex
                ?? distributionIndex
                ?? expansionExtremeIndex
                ?? expansionIndex
                ?? reclaimIndex
                ?? sweepIndex
                ?? rangeEnd
        }

        var id: String { "amd-\(rangeStart)-\(rangeEnd)-\(sweepIndex ?? -1)" }
    }

    struct Configuration: Hashable, Sendable {
        var atrPeriod = 14

        // Accumulation
        var minRangeBars = 6
        var maxRangeBars = 60
        var maxRangeATR = 2.0
        var requireContraction = true
        /// Mean bar range inside the base, as a fraction of the mean bar
        /// range immediately before it. Below 1 ⇒ volatility contracted.
        var contractionRatio = 0.85

        // Manipulation
        /// How far past the edge the wick has to poke to count as taking
        /// liquidity rather than noise. Also the point at which a bar
        /// stops belonging to the accumulation it is trading out of —
        /// see `base(from:candles:atr:cfg:)`. At 0, a base ends at the
        /// first bar to make any new extreme at all.
        var minSweepATR = 0.15
        /// How long after the range we keep watching for a sweep.
        var maxManipulationBars = 12
        /// How long the sweep has to be reclaimed. Beyond this it was a
        /// real breakout, not manipulation.
        var maxReclaimBars = 5

        // Expansion
        var minExpansionATR = 0.5
        var maxExpansionBars = 25

        // Entry
        var requireFVG = true
        /// Which gap in the leg to trade: the one nearest the
        /// manipulation (best R, may never fill), the one nearest the
        /// extreme (fills first), or the widest.
        var gapPick = GapPick.first
        var entryModel = EntryModel.mid
        var stopBufferATR = 0.25
        /// Targets are R multiples of the entry-to-sweep distance.
        ///
        /// A "measured move" alternative (the range height projected off
        /// the edge it broke) was tried and removed: the stop sits a
        /// full range height *below* the entry by construction, so the
        /// risk always exceeds the range height, and the projected
        /// target therefore always lands inside 1R. It could never fire.
        var tp1R = 1.0
        var tp2R = 2.0
        /// Drop plans below this R:R. 0 ⇒ off.
        var minRR = 0.0

        // Distribution
        /// Bars without a new extreme before the leg is called stalled.
        var distributionBars = 5

        var showFailed = false
        var maxCycles = 4
    }

    enum GapPick: String, Hashable, Sendable {
        case first, last, largest

        init(_ raw: String) {
            switch raw.lowercased() {
            case "last":    self = .last
            case "largest": self = .largest
            default:        self = .first
            }
        }
    }

    enum EntryModel: String, Hashable, Sendable {
        case proximal, mid, distal

        init(_ raw: String) {
            switch raw.lowercased() {
            case "proximal": self = .proximal
            case "distal":   self = .distal
            default:         self = .mid
            }
        }
    }

    // MARK: - Entry point

    static func compute(
        _ candles: [Candle],
        configuration raw: Configuration = Configuration()
    ) -> [Cycle] {
        let cfg = sanitized(raw)
        guard candles.count >= cfg.minRangeBars + cfg.atrPeriod + 3 else { return [] }

        let atr = atrSeries(candles, period: cfg.atrPeriod)
        var cycles: [Cycle] = []

        var scan = 0
        while scan <= candles.count - cfg.minRangeBars {
            guard let base = base(from: scan, candles: candles, atr: atr, cfg: cfg) else {
                scan += 1
                continue
            }
            var cycle = Cycle(
                rangeStart: base.start,
                rangeEnd: base.end,
                rangeHigh: base.high,
                rangeLow: base.low,
                phase: .accumulation
            )
            resolveManipulation(&cycle, candles: candles, atr: atr, cfg: cfg)
            if cycle.phase != .accumulation {
                resolveExpansion(&cycle, candles: candles, atr: atr, cfg: cfg)
            }
            cycles.append(cycle)

            // Never look for the next base inside this one's own story —
            // the expansion leg would otherwise be mined for a "range".
            scan = max(base.end, cycle.lastRelevantIndex) + 1
        }

        // A base that was never challenged is only interesting while it
        // is still the live one. Historical unchallenged ranges are just
        // places price happened to pause.
        let lastBar = candles.count - 1
        cycles.removeAll { cycle in
            cycle.phase == .accumulation
                && cycle.rangeEnd < lastBar - cfg.maxManipulationBars
        }
        // An expansion with no imbalance inside it is a real phase read
        // but not a tradeable one — price moved without skipping any,
        // so there is nothing to retrace into. With the toggle on, only
        // cycles that left an entry survive.
        if cfg.requireFVG {
            cycles.removeAll { cycle in
                (cycle.phase == .expansion || cycle.phase == .distribution) && cycle.gap == nil
            }
        }
        if !cfg.showFailed {
            cycles.removeAll { $0.phase == .failed }
        }
        return Array(cycles.suffix(cfg.maxCycles))
    }

    // MARK: - Accumulation

    private struct Base {
        let start: Int
        let end: Int
        let high: Double
        let low: Double
    }

    /// Grow the widest contained range that starts at `start`, or `nil`
    /// if the bars there don't hold together as a base.
    ///
    /// "Contained" is measured against ATR rather than a fixed
    /// percentage so the same settings work on a 1-minute gold chart and
    /// a daily one — a range that is tight for one is a trend leg for
    /// the other.
    private static func base(
        from start: Int,
        candles: [Candle],
        atr: [Double?],
        cfg: Configuration
    ) -> Base? {
        var end = start + cfg.minRangeBars - 1
        guard end < candles.count, let seedATR = atr[end], seedATR > 0 else { return nil }

        var high = -Double.greatestFiniteMagnitude
        var low = Double.greatestFiniteMagnitude
        for i in start...end {
            high = max(high, candles[i].high)
            low = min(low, candles[i].low)
        }
        guard high - low <= cfg.maxRangeATR * seedATR else { return nil }

        while end + 1 < candles.count, end - start + 1 < cfg.maxRangeBars {
            let next = candles[end + 1]
            guard let a = atr[end + 1], a > 0 else { break }
            // `minSweepATR` does double duty: it is both what counts as
            // taking liquidity *and* what ends the base. The two have to
            // be the same number — if a bar could poke further than the
            // sweep threshold and still be swallowed into the range,
            // the manipulation would be absorbed by the accumulation it
            // is supposed to end, and no cycle would ever be found. The
            // seed window is already `minRangeBars` long, so the band
            // this is measured against is established, not still forming.
            let pad = cfg.minSweepATR * a
            guard next.high <= high + pad, next.low >= low - pad else { break }
            let grownHigh = max(high, next.high)
            let grownLow = min(low, next.low)
            guard grownHigh - grownLow <= cfg.maxRangeATR * a else { break }
            high = grownHigh
            low = grownLow
            end += 1
        }

        guard !cfg.requireContraction || contracted(candles, start: start, end: end, cfg: cfg) else {
            return nil
        }
        return Base(start: start, end: end, high: high, low: low)
    }

    /// Volatility contraction: the mean bar range inside the base against
    /// the mean of the run that led into it. Accumulation is not just
    /// sideways — it is *quieter* than what came before, which is what
    /// separates a base from a slow drift.
    private static func contracted(
        _ candles: [Candle],
        start: Int,
        end: Int,
        cfg: Configuration
    ) -> Bool {
        let lookback = cfg.minRangeBars
        let priorStart = start - lookback
        guard priorStart >= 0 else { return false }

        var priorSum = 0.0
        for i in priorStart..<start { priorSum += candles[i].high - candles[i].low }
        let priorMean = priorSum / Double(lookback)
        guard priorMean > 0 else { return false }

        var baseSum = 0.0
        for i in start...end { baseSum += candles[i].high - candles[i].low }
        let baseMean = baseSum / Double(end - start + 1)

        return baseMean <= cfg.contractionRatio * priorMean
    }

    // MARK: - Manipulation

    /// Look for the liquidity grab past either edge and the close that
    /// puts price back inside. Mutates `cycle` in place: on success the
    /// phase advances to `.manipulation`; a breakout that never comes
    /// back leaves the cycle in `.accumulation` (the range simply broke)
    /// or marks it `.failed`.
    private static func resolveManipulation(
        _ cycle: inout Cycle,
        candles: [Candle],
        atr: [Double?],
        cfg: Configuration
    ) {
        let first = cycle.rangeEnd + 1
        let last = min(candles.count - 1, cycle.rangeEnd + cfg.maxManipulationBars)
        guard first <= last else { return }

        var sweepIndex: Int?
        var side: SweptSide = .high
        for i in first...last {
            guard let a = atr[i], a > 0 else { continue }
            let pad = cfg.minSweepATR * a
            let above = candles[i].high - (cycle.rangeHigh + pad)
            let below = (cycle.rangeLow - pad) - candles[i].low
            guard above > 0 || below > 0 else { continue }
            // An outside bar took both sides; the deeper excursion is the
            // one that actually ran the stops.
            side = above >= below ? .high : .low
            sweepIndex = i
            break
        }
        guard let sweep = sweepIndex else { return }

        let extreme = side == .high ? candles[sweep].high : candles[sweep].low
        cycle.sweepIndex = sweep
        cycle.sweepPrice = extreme
        cycle.sweptSide = side

        // The reclaim can happen on the sweep bar itself — a single
        // rejection candle that pokes through and closes back inside is
        // the cleanest form of this.
        let reclaimLast = min(candles.count - 1, sweep + cfg.maxReclaimBars)
        for i in sweep...reclaimLast {
            let close = candles[i].close
            let inside = close <= cycle.rangeHigh && close >= cycle.rangeLow
            if inside {
                cycle.reclaimIndex = i
                cycle.phase = .manipulation
                return
            }
            // Ran further the same way instead of coming back: this was a
            // genuine breakout, and there is no manipulation to trade.
            let ranOn = side == .high
                ? close > cycle.rangeHigh + (atr[i] ?? 0) * cfg.minExpansionATR
                : close < cycle.rangeLow - (atr[i] ?? 0) * cfg.minExpansionATR
            if ranOn {
                cycle.phase = .failed
                return
            }
        }
        // Ran out of bars rather than out of patience: the sweep is live
        // and the reclaim may still print. Leave the cycle in
        // accumulation (the sweep fields are set, so the chart can still
        // mark where liquidity was taken).
        guard reclaimLast >= sweep + cfg.maxReclaimBars else { return }
        // Window expired with price still outside and undecided.
        cycle.phase = .failed
    }

    // MARK: - Expansion, distribution, entry

    private static func resolveExpansion(
        _ cycle: inout Cycle,
        candles: [Candle],
        atr: [Double?],
        cfg: Configuration
    ) {
        guard let reclaim = cycle.reclaimIndex,
              let direction = cycle.direction,
              let sweepPrice = cycle.sweepPrice
        else { return }

        let isLong = direction.isLong
        let target = isLong ? cycle.rangeHigh : cycle.rangeLow
        let last = min(candles.count - 1, reclaim + cfg.maxExpansionBars)
        guard reclaim + 1 <= last else { return }

        var expansion: Int?
        for i in (reclaim + 1)...last {
            // The sweep extreme is the cycle's invalidation: trading back
            // through it says the manipulation read was wrong.
            let brokeBack = isLong ? candles[i].low < sweepPrice : candles[i].high > sweepPrice
            if brokeBack {
                cycle.phase = .failed
                return
            }
            guard let a = atr[i], a > 0 else { continue }
            let beyond = isLong
                ? candles[i].close - target
                : target - candles[i].close
            if beyond >= cfg.minExpansionATR * a {
                expansion = i
                break
            }
        }
        guard let expansionIndex = expansion else {
            // Still inside the window with bars left to come — the cycle
            // is genuinely mid-manipulation, not failed.
            if last >= candles.count - 1 { return }
            cycle.phase = .failed
            return
        }

        cycle.expansionIndex = expansionIndex
        cycle.phase = .expansion

        // ── Track the leg to its extreme ──────────────────────────────
        var extreme = isLong ? candles[expansionIndex].high : candles[expansionIndex].low
        var extremeIndex = expansionIndex
        var i = expansionIndex + 1
        var stalled = 0
        while i < candles.count {
            let bar = candles[i]
            let progressed = isLong ? bar.high > extreme : bar.low < extreme
            if progressed {
                extreme = isLong ? bar.high : bar.low
                extremeIndex = i
                stalled = 0
            } else {
                stalled += 1
                if stalled >= cfg.distributionBars {
                    cycle.distributionIndex = extremeIndex + 1
                    cycle.phase = .distribution
                    break
                }
            }
            i += 1
        }
        cycle.expansionExtreme = extreme
        cycle.expansionExtremeIndex = extremeIndex

        buildEntry(&cycle, candles: candles, atr: atr, cfg: cfg)
    }

    /// Find the imbalance the displacement left behind and turn it into a
    /// plan. The search spans the manipulation bar through the leg's
    /// extreme: the gap that matters can straddle the reclaim candle
    /// itself, which is often the fastest bar in the whole sequence.
    private static func buildEntry(
        _ cycle: inout Cycle,
        candles: [Candle],
        atr: [Double?],
        cfg: Configuration
    ) {
        guard let direction = cycle.direction,
              let sweep = cycle.sweepIndex,
              let sweepPrice = cycle.sweepPrice,
              let expansionIndex = cycle.expansionIndex,
              let extremeIndex = cycle.expansionExtremeIndex
        else { return }

        let isLong = direction.isLong
        let gaps = gaps(
            candles,
            from: sweep,
            through: extremeIndex,
            isLong: isLong
        )
        guard let picked = pick(gaps, using: cfg.gapPick) else { return }

        let proximal = isLong ? picked.high : picked.low
        let distal = isLong ? picked.low : picked.high
        let entry: Double
        switch cfg.entryModel {
        case .proximal: entry = proximal
        case .distal:   entry = distal
        case .mid:      entry = (picked.high + picked.low) / 2
        }

        // Invalidation sits beyond the manipulation extreme — the price
        // the market already proved it did not want to trade through.
        let buffer = (atr[min(expansionIndex, atr.count - 1)] ?? 0) * cfg.stopBufferATR
        let stop = isLong ? sweepPrice - buffer : sweepPrice + buffer
        let risk = abs(entry - stop)
        guard risk > 0 else { return }

        let tp1 = isLong ? entry + risk * cfg.tp1R : entry - risk * cfg.tp1R
        let tp2 = isLong ? entry + risk * cfg.tp2R : entry - risk * cfg.tp2R

        var gap = EntryGap(
            index: picked.index,
            high: picked.high,
            low: picked.low,
            proximal: proximal,
            distal: distal,
            entry: entry,
            stopLoss: stop,
            takeProfit1: tp1,
            takeProfit2: tp2,
            state: .armed
        )
        guard cfg.minRR <= 0 || gap.riskReward >= cfg.minRR else { return }
        track(&gap, candles: candles, isLong: isLong, from: max(picked.index + 2, expansionIndex + 1))
        cycle.gap = gap
    }

    struct RawGap: Hashable {
        let index: Int
        let high: Double
        let low: Double
        var size: Double { high - low }
    }

    /// Three-candle imbalances between `from` and `through`, in the
    /// direction of the expansion only.
    ///
    /// Deliberately not `FairValueGap.compute`: that scans the whole
    /// series and then runs an O(zones × bars) mitigation pass, which is
    /// wasted work when the window of interest is a couple of dozen bars
    /// and mitigation is tracked here against the plan instead.
    static func gaps(
        _ candles: [Candle],
        from: Int,
        through: Int,
        isLong: Bool
    ) -> [RawGap] {
        var out: [RawGap] = []
        let lower = max(1, from)
        let upper = min(candles.count - 2, through)
        guard lower <= upper else { return out }

        for m in lower...upper {
            let before = candles[m - 1]
            let after = candles[m + 1]
            if isLong {
                guard after.low > before.high, candles[m].close > before.high else { continue }
                out.append(RawGap(index: m, high: after.low, low: before.high))
            } else {
                guard after.high < before.low, candles[m].close < before.low else { continue }
                out.append(RawGap(index: m, high: before.low, low: after.high))
            }
        }
        return out
    }

    private static func pick(_ gaps: [RawGap], using mode: GapPick) -> RawGap? {
        switch mode {
        case .first:   return gaps.first
        case .last:    return gaps.last
        case .largest: return gaps.max { $0.size < $1.size }
        }
    }

    /// Walk the plan forward from `start`: fill, then targets, with the
    /// stop checked first on every bar. A bar that spans both the stop
    /// and a target is read as a loss — the pessimistic reading, since
    /// the intrabar order is unknowable from OHLC.
    private static func track(
        _ gap: inout EntryGap,
        candles: [Candle],
        isLong: Bool,
        from start: Int
    ) {
        guard start < candles.count else { return }
        for i in start..<candles.count {
            let bar = candles[i]

            if gap.state == .armed {
                // The stop always sits beyond the entry (past the
                // manipulation extreme), so price cannot reach it
                // without filling first — no separate pre-fill
                // invalidation check is needed here.
                let touched = isLong ? bar.low <= gap.entry : bar.high >= gap.entry
                guard touched else { continue }
                gap.fillIndex = i
                gap.state = .filled
                // Fall through: the fill bar itself can run to either side.
            }

            let stopped = isLong ? bar.low <= gap.stopLoss : bar.high >= gap.stopLoss
            if stopped {
                gap.state = .stopped
                gap.resolveIndex = i
                return
            }
            if gap.state == .filled {
                let hit1 = isLong ? bar.high >= gap.takeProfit1 : bar.low <= gap.takeProfit1
                if hit1 { gap.state = .tp1 }
            }
            if gap.state == .tp1 {
                let hit2 = isLong ? bar.high >= gap.takeProfit2 : bar.low <= gap.takeProfit2
                if hit2 {
                    gap.state = .tp2
                    gap.resolveIndex = i
                    return
                }
            }
        }
    }

    // MARK: - Helpers

    private static func sanitized(_ raw: Configuration) -> Configuration {
        var c = raw
        c.atrPeriod = max(2, raw.atrPeriod)
        c.minRangeBars = max(3, raw.minRangeBars)
        c.maxRangeBars = max(c.minRangeBars, raw.maxRangeBars)
        c.maxRangeATR = max(0.2, raw.maxRangeATR)
        c.contractionRatio = max(0.1, raw.contractionRatio)
        c.minSweepATR = max(0, raw.minSweepATR)
        c.maxManipulationBars = max(1, raw.maxManipulationBars)
        c.maxReclaimBars = max(0, raw.maxReclaimBars)
        c.minExpansionATR = max(0, raw.minExpansionATR)
        c.maxExpansionBars = max(1, raw.maxExpansionBars)
        c.stopBufferATR = max(0, raw.stopBufferATR)
        c.tp1R = max(0.1, raw.tp1R)
        c.tp2R = max(c.tp1R, raw.tp2R)
        c.minRR = max(0, raw.minRR)
        c.distributionBars = max(1, raw.distributionBars)
        c.maxCycles = max(1, raw.maxCycles)
        return c
    }

    /// Wilder-smoothed ATR, matching `MTRSetup` / `SP2LSetup` so the same
    /// "× ATR" setting means the same thing across every setup engine.
    private static func atrSeries(_ candles: [Candle], period: Int) -> [Double?] {
        guard !candles.isEmpty else { return [] }
        let p = max(1, period)
        var trueRanges = [Double](repeating: 0, count: candles.count)
        for index in candles.indices {
            if index == 0 {
                trueRanges[index] = candles[index].high - candles[index].low
            } else {
                trueRanges[index] = max(
                    candles[index].high - candles[index].low,
                    abs(candles[index].high - candles[index - 1].close),
                    abs(candles[index].low - candles[index - 1].close)
                )
            }
        }
        var output = [Double?](repeating: nil, count: candles.count)
        guard candles.count >= p else { return output }
        var value = trueRanges[0..<p].reduce(0, +) / Double(p)
        output[p - 1] = value
        if p < candles.count {
            for index in p..<candles.count {
                value = (value * Double(p - 1) + trueRanges[index]) / Double(p)
                output[index] = value
            }
        }
        return output
    }
}

// MARK: - Params bridge

extension AMDCycle.Configuration {
    /// Build from an `IndicatorInstance`'s param dictionary. Mirrors how
    /// `HelixOBCombo` / `AlgoSmartAssist` read their settings — the newer
    /// indicators skip the `OscillatorConfig` mirror entirely.
    init(params: [String: ParamValue]) {
        self.init()
        if let v = params["atrPeriod"]           { atrPeriod = Int(v.doubleValue) }
        if let v = params["minRangeBars"]        { minRangeBars = Int(v.doubleValue) }
        if let v = params["maxRangeBars"]        { maxRangeBars = Int(v.doubleValue) }
        if let v = params["maxRangeATR"]         { maxRangeATR = v.doubleValue }
        if let v = params["requireContraction"]  { requireContraction = v.boolValue }
        if let v = params["contractionRatio"]    { contractionRatio = v.doubleValue }
        if let v = params["minSweepATR"]         { minSweepATR = v.doubleValue }
        if let v = params["maxManipulationBars"] { maxManipulationBars = Int(v.doubleValue) }
        if let v = params["maxReclaimBars"]      { maxReclaimBars = Int(v.doubleValue) }
        if let v = params["minExpansionATR"]     { minExpansionATR = v.doubleValue }
        if let v = params["maxExpansionBars"]    { maxExpansionBars = Int(v.doubleValue) }
        if let v = params["requireFVG"]          { requireFVG = v.boolValue }
        if let v = params["gapPick"]             { gapPick = AMDCycle.GapPick(v.stringValue) }
        if let v = params["entryModel"]          { entryModel = AMDCycle.EntryModel(v.stringValue) }
        if let v = params["stopBufferATR"]       { stopBufferATR = v.doubleValue }
        if let v = params["tp1R"]                { tp1R = v.doubleValue }
        if let v = params["tp2R"]                { tp2R = v.doubleValue }
        if let v = params["minRR"]               { minRR = v.doubleValue }
        if let v = params["distributionBars"]    { distributionBars = Int(v.doubleValue) }
        if let v = params["showFailed"]          { showFailed = v.boolValue }
        if let v = params["maxCycles"]           { maxCycles = Int(v.doubleValue) }
    }
}

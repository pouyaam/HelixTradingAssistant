import Foundation

/// Turns Ranked Order Block *zones* into Ranked Order Block *trades*.
///
/// The indicator answers "where is a good place to react?" — it says
/// nothing about when to act or what to risk. This layer adds the three
/// gates that turn a graded zone into a plan:
///
///   1. **Location.** The zone must pass the grade filter. A-grade means
///      ≥70% of whatever confluence divisor is live (`4/5`, `2/3`, …).
///   2. **Arrival.** Price has to come *back* to the zone. A zone that
///      just formed is not a trade; the tap is what arms it.
///   3. **Confirmation.** Something must happen inside the zone before
///      the order goes live — a rejection candle, a micro break of
///      structure, or a displacement gap. `.touch` skips this gate for
///      people who want the raw limit-order behaviour.
///
/// Geometry is fixed the moment the zone forms, so a plan is displayable
/// (and its R:R knowable) long before it triggers:
///
/// ```
///   long:   entry  = proximal (top) | mid | distal (bottom)
///           SL     = bottom − atr × slATRBuffer
///           TP1    = entry + risk × tp1R
///           TP2    = entry + risk × tp2R,  or the nearest opposing zone
/// ```
///
/// The exception is `.confirmClose`, which can only know its entry once
/// the confirmation bar closes; until then the plan shows the zone mid as
/// a provisional level (`isProvisionalEntry`).
///
/// **Scope, deliberately.** `RankedOrderBlocks.compute` returns the
/// *render set* — the freshest `zonesPerSide` per side — and drops zones
/// entirely once price passes clean through the far side of a breaker. So
/// setups live and die with the zones on screen: a trade whose zone has
/// been fully consumed disappears rather than lingering as history. That
/// keeps the overlay honest about what's still tradeable, and it is why
/// this is a live-assist layer rather than a backtester.
///
/// Pure-function, no state. `ChartView` maps the result into rule marks;
/// `AlertStore.evaluateRankedOBStrategy` maps stage transitions into
/// notifications.
enum RankedOBStrategy {

    enum Direction: String, Hashable {
        case long
        case short
    }

    /// Minimum confluence grade a zone must carry to be traded.
    enum MinGrade: String, Codable, Hashable {
        case aOnly
        case aOrB
        case any

        /// `.unranked` always passes: with both ranking legs switched off
        /// there is nothing to grade on, so filtering on grade would
        /// silently produce zero setups.
        func admits(_ grade: RankedOrderBlocks.Grade) -> Bool {
            switch grade {
            case .unranked: return true
            case .a:        return true
            case .b:        return self != .aOnly
            case .c:        return self == .any
            }
        }
    }

    /// What has to happen inside the zone before the order goes live.
    enum Confirmation: String, Codable, Hashable {
        /// No confirmation — the tap itself arms the entry (a plain
        /// limit order at the zone).
        case touch
        /// A candle that wicks into the zone and closes back out of it,
        /// with the close in the far third of its own range.
        case rejection
        /// A close beyond the extreme of the reaction so far — the
        /// smallest honest break of structure available inside a zone.
        case microBOS
        /// A three-bar displacement gap in the trade's direction.
        case fvg
    }

    /// Where in the zone the order rests.
    enum EntryModel: String, Codable, Hashable {
        /// The edge price meets first — top for a long, bottom for a
        /// short. Best fill rate, worst R:R.
        case proximal
        case mid
        /// The far edge, right against the stop. Best R:R, often missed.
        case distal
        /// Market-in at the close of the confirmation bar. Always fills;
        /// pays for it in risk.
        case confirmClose
    }

    enum TargetMode: String, Codable, Hashable {
        /// TP2 at a fixed R multiple.
        case fixedR
        /// TP2 at the nearest opposing zone's proximal edge, falling back
        /// to `fixedR` when there isn't one in front of the trade.
        case opposingZone
    }

    /// Lifecycle of one plan. Terminal states carry `resolveIndex`.
    enum Stage: String, Hashable {
        /// Plan exists, price hasn't returned to the zone yet.
        case waiting
        /// Price tapped the zone; confirmation window is open.
        case armed
        /// Confirmation printed; waiting for the fill.
        case triggered
        /// Filled — trade is live.
        case entered
        /// TP1 banked, running to TP2 with the stop at breakeven.
        case runningToTP2
        case hitTP
        case hitSL
        /// Price broke past the stop before the trade ever filled.
        case invalidated
        /// The confirmation (or fill) window closed with nothing.
        case expired

        var isTerminal: Bool {
            switch self {
            case .hitTP, .hitSL, .invalidated, .expired: return true
            default: return false
            }
        }

        /// True while the plan is something the user could still act on —
        /// what the notification and legend layers care about.
        var isActionable: Bool {
            switch self {
            case .waiting, .armed, .triggered, .entered, .runningToTP2: return true
            default: return false
            }
        }
    }

    struct Config: Equatable {
        /// Master switch. Off ⇒ `compute` returns `[]` without scanning.
        var enabled: Bool = false
        var minGrade: MinGrade = .aOrB
        var confirmation: Confirmation = .rejection
        /// Bars allowed between the tap and the confirmation, and again
        /// between the confirmation and the fill.
        var confirmWindow: Int = 5
        var entryModel: EntryModel = .mid
        /// Stop distance beyond the far edge, in ATRs at zone formation.
        var slATRBuffer: Double = 0.3
        var tp1R: Double = 1.0
        var targetMode: TargetMode = .fixedR
        var tp2R: Double = 2.0
        /// A-grade zones get +1R on TP2 — the confluence is the edge, so
        /// let it run further.
        var gradeScaledTargets: Bool = true
        /// Trade the retest of a *broken* zone in the opposite direction.
        var tradeBreakers: Bool = false
        /// Drop plans whose TP2 R:R lands below this. 0 ⇒ keep all.
        var minRR: Double = 0
    }

    /// One trade plan derived from one zone.
    struct Setup: Identifiable, Hashable {
        /// The originating zone, for cross-referencing on the chart.
        let zoneID: String
        let zoneTop: Double
        let zoneBottom: Double
        let direction: Direction
        /// True when this is the retest of a broken zone, i.e. the trade
        /// runs *against* the zone's original polarity.
        let isBreakerPlay: Bool
        let grade: RankedOrderBlocks.Grade
        let score: Int
        let maxScore: Int
        /// Bar the plan became visible (the zone's creation bar, or the
        /// break bar for a breaker play).
        let planIndex: Int

        let entry: Double
        let stopLoss: Double
        let takeProfit1: Double
        let takeProfit2: Double
        /// `.confirmClose` plans show the zone mid until the confirmation
        /// bar prints; the levels are indicative until then.
        let isProvisionalEntry: Bool

        var armIndex: Int?
        var triggerIndex: Int?
        var entryIndex: Int?
        var tp1Index: Int?
        var resolveIndex: Int?
        var stage: Stage

        var id: String { "robs-\(zoneID)-\(direction.rawValue)" }

        /// Distance from entry to stop, in price.
        var risk: Double { abs(entry - stopLoss) }

        /// R:R measured to the final target.
        var riskReward: Double {
            risk > 0 ? abs(takeProfit2 - entry) / risk : 0
        }

        /// Right edge for the plan's lines: where it resolved, or open-ended.
        func planEnd(lastIndex: Int) -> Int { resolveIndex ?? lastIndex }

        /// Short badge for the chart — "A 4/5 LONG · 2.4R".
        var badge: String {
            let g = grade == .unranked ? "OB" : "\(grade.rawValue) \(score)/\(maxScore)"
            let side = direction == .long ? "LONG" : "SHORT"
            let brk = isBreakerPlay ? " BRK" : ""
            return String(format: "%@ %@%@ · %.1fR", g, side, brk, riskReward)
        }

        /// One-line plain-English plan, for the legend and the Inbox.
        var summary: String {
            let side = direction == .long ? "Long" : "Short"
            let where_ = "\(fmt(zoneBottom))–\(fmt(zoneTop))"
            let plan = "entry \(fmt(entry)) · SL \(fmt(stopLoss)) · TP \(fmt(takeProfit1)) / \(fmt(takeProfit2))"
            let rr = String(format: "%.1fR", riskReward)
            return "\(side) \(where_) — \(stagePhrase) · \(plan) · \(rr)"
        }

        var stagePhrase: String {
            switch stage {
            case .waiting:      return "waiting for the retest"
            case .armed:        return "tapped, waiting for confirmation"
            case .triggered:    return "confirmed, waiting for the fill"
            case .entered:      return "live"
            case .runningToTP2: return "TP1 banked, stop at breakeven"
            case .hitTP:        return "target hit"
            case .hitSL:        return "stopped out"
            case .invalidated:  return "invalidated before entry"
            case .expired:      return "no confirmation, expired"
            }
        }

        private func fmt(_ v: Double) -> String { PriceFormat.exact(v) }
    }

    // MARK: - Entry point

    /// Build a plan for every zone that passes the grade filter and
    /// replay the candles forward from its creation bar to see how far
    /// each one got.
    ///
    /// `zones` is expected to be exactly what the chart is drawing (the
    /// output of `RankedOrderBlocks.compute` with the same config), so
    /// what the overlay says is always about a zone the user can see.
    static func compute(
        _ candles: [Candle],
        zones: [RankedOrderBlocks.Zone],
        config cfg: Config
    ) -> [Setup] {
        guard cfg.enabled, candles.count > 2, !zones.isEmpty else { return [] }

        var out: [Setup] = []
        for zone in zones {
            guard cfg.minGrade.admits(zone.grade) else { continue }
            if zone.isBreaker && !cfg.tradeBreakers { continue }
            guard var setup = plan(for: zone, zones: zones, candles: candles, cfg: cfg) else { continue }
            if cfg.minRR > 0, setup.riskReward < cfg.minRR { continue }
            replay(&setup, zone: zone, candles: candles, cfg: cfg)
            out.append(setup)
        }
        // Freshest first — the plan most likely to matter is the one that
        // just formed.
        return out.sorted { $0.planIndex > $1.planIndex }
    }

    /// The single actionable plan worth surfacing in a legend or a
    /// one-line summary: the newest one that hasn't resolved.
    static func headline(_ setups: [Setup]) -> Setup? {
        // An entered trade beats an armed one beats a waiting one.
        let rank: [Stage: Int] = [
            .runningToTP2: 5, .entered: 4, .triggered: 3, .armed: 2, .waiting: 1,
        ]
        return setups
            .filter { $0.stage.isActionable }
            .max { (rank[$0.stage] ?? 0, $0.planIndex) < (rank[$1.stage] ?? 0, $1.planIndex) }
    }

    // MARK: - Plan geometry

    private static func plan(
        for zone: RankedOrderBlocks.Zone,
        zones: [RankedOrderBlocks.Zone],
        candles: [Candle],
        cfg: Config
    ) -> Setup? {
        // A breaker's polarity flips: a bullish block that failed is
        // resistance now, so its retest is a short.
        let isLong = zone.isBreaker ? !zone.isBullish : zone.isBullish
        let direction: Direction = isLong ? .long : .short
        // A breaker only becomes tradeable at the bar it broke.
        let planIndex = zone.isBreaker ? zone.endIndex : zone.confirmIndex
        guard planIndex < candles.count else { return nil }

        let proximal = isLong ? zone.top : zone.bottom
        let distal   = isLong ? zone.bottom : zone.top
        let mid      = (zone.top + zone.bottom) / 2

        let provisional = cfg.entryModel == .confirmClose
        let entry: Double
        switch cfg.entryModel {
        case .proximal:     entry = proximal
        case .mid:          entry = mid
        case .distal:       entry = distal
        case .confirmClose: entry = mid   // stand-in until the trigger prints
        }

        // The stop sits *past* the far edge by a slice of the volatility
        // the zone was born into — placing it exactly at the edge parks
        // it where the liquidity sweep lands.
        let buffer = max(0, cfg.slATRBuffer) * max(0, zone.atr)
        let stopLoss = isLong ? distal - buffer : distal + buffer
        let risk = abs(entry - stopLoss)
        guard risk > 0 else { return nil }

        let tp1 = isLong ? entry + risk * max(0.1, cfg.tp1R)
                         : entry - risk * max(0.1, cfg.tp1R)
        let tp2 = target2(
            zone: zone, zones: zones, isLong: isLong,
            entry: entry, risk: risk, tp1: tp1, cfg: cfg
        )

        return Setup(
            zoneID: zone.id,
            zoneTop: zone.top,
            zoneBottom: zone.bottom,
            direction: direction,
            isBreakerPlay: zone.isBreaker,
            grade: zone.grade,
            score: zone.score,
            maxScore: zone.maxScore,
            planIndex: planIndex,
            entry: entry,
            stopLoss: stopLoss,
            takeProfit1: tp1,
            takeProfit2: tp2,
            isProvisionalEntry: provisional,
            stage: .waiting
        )
    }

    /// Final target: a fixed R multiple, or the nearest opposing zone in
    /// front of the trade. A-grade zones get an extra R when
    /// `gradeScaledTargets` is on — the confluence *is* the edge, so it
    /// earns a longer leash.
    private static func target2(
        zone: RankedOrderBlocks.Zone,
        zones: [RankedOrderBlocks.Zone],
        isLong: Bool,
        entry: Double,
        risk: Double,
        tp1: Double,
        cfg: Config
    ) -> Double {
        var multiple = max(cfg.tp1R, cfg.tp2R)
        if cfg.gradeScaledTargets, zone.grade == .a { multiple += 1 }
        let fixed = isLong ? entry + risk * multiple : entry - risk * multiple

        guard cfg.targetMode == .opposingZone else { return fixed }

        // The first opposing-side zone the trade would run into. Its
        // proximal edge is where the opposing orders sit, so that's the
        // realistic exit — not the far side of it.
        let opposing = zones.filter { other in
            guard other.id != zone.id, !other.isBreaker else { return false }
            guard other.isBullish != isLong else { return false }
            let edge = isLong ? other.bottom : other.top
            return isLong ? edge > tp1 : edge < tp1
        }
        let edges = opposing.map { isLong ? $0.bottom : $0.top }
        guard let nearest = isLong ? edges.min() : edges.max() else { return fixed }
        return nearest
    }

    // MARK: - Replay

    /// Walk the candles forward from the plan bar and advance the stage
    /// as far as the data allows. Two conventions worth knowing:
    ///
    ///   - **Same-bar ambiguity resolves against the trade.** A bar whose
    ///     range covers both the stop and a target is counted as the stop.
    ///     Intrabar order is unknowable from OHLC; assuming the good
    ///     outcome is how backtests learn to lie.
    ///   - **The fill bar is not a resolution bar.** TP/SL checks start
    ///     on the bar *after* the fill, so a single wick can't both fill
    ///     and stop a trade.
    private static func replay(
        _ setup: inout Setup,
        zone: RankedOrderBlocks.Zone,
        candles: [Candle],
        cfg: Config
    ) {
        let n = candles.count
        let isLong = setup.direction == .long
        let proximal = isLong ? zone.top : zone.bottom
        let window = max(1, cfg.confirmWindow)

        var entry = setup.entry
        var tp1 = setup.takeProfit1
        var tp2 = setup.takeProfit2
        var breakevenArmed = false

        var i = setup.planIndex + 1
        while i < n {
            let bar = candles[i]

            // ── Waiting: has price come back to the zone? ─────────────
            if setup.stage == .waiting {
                if beyondStop(bar, setup.stopLoss, isLong: isLong) {
                    setup.stage = .invalidated
                    setup.resolveIndex = i
                    return
                }
                guard tapped(bar, proximal: proximal, isLong: isLong) else { i += 1; continue }
                setup.armIndex = i
                setup.stage = .armed
                // Fall through: the tap bar itself is very often the
                // rejection candle, so it must be eligible to confirm.
            }

            // ── Armed: waiting for the confirmation signal ────────────
            if setup.stage == .armed, let arm = setup.armIndex {
                if beyondStop(bar, setup.stopLoss, isLong: isLong) {
                    setup.stage = .invalidated
                    setup.resolveIndex = i
                    return
                }
                if i - arm > window {
                    setup.stage = .expired
                    setup.resolveIndex = i
                    return
                }
                guard confirms(
                    at: i, armIndex: arm, candles: candles,
                    zoneTop: zone.top, zoneBottom: zone.bottom,
                    isLong: isLong, mode: cfg.confirmation
                ) else { i += 1; continue }

                setup.triggerIndex = i
                setup.stage = .triggered

                // `.confirmClose` only learns its entry here. Re-derive
                // the targets off the real fill; the stop never moves.
                if cfg.entryModel == .confirmClose {
                    entry = bar.close
                    let risk = abs(entry - setup.stopLoss)
                    if risk > 0 {
                        let r1 = max(0.1, cfg.tp1R)
                        var r2 = max(cfg.tp1R, cfg.tp2R)
                        if cfg.gradeScaledTargets, zone.grade == .a { r2 += 1 }
                        tp1 = isLong ? entry + risk * r1 : entry - risk * r1
                        tp2 = isLong ? entry + risk * r2 : entry - risk * r2
                    }
                    setup = rebased(setup, entry: entry, tp1: tp1, tp2: tp2)
                    // Market entry: filled at the trigger bar's close.
                    setup.entryIndex = i
                    setup.stage = .entered
                    i += 1
                    continue
                }
            }

            // ── Triggered: resting limit waiting to be filled ─────────
            if setup.stage == .triggered, let trigger = setup.triggerIndex {
                if beyondStop(bar, setup.stopLoss, isLong: isLong) {
                    setup.stage = .invalidated
                    setup.resolveIndex = i
                    return
                }
                if i - trigger > window {
                    setup.stage = .expired
                    setup.resolveIndex = i
                    return
                }
                // Never fill on the trigger bar. The confirmation is only
                // knowable at that bar's close, so counting a fill from
                // its intrabar range would be reading the signal before
                // it existed. `.confirmClose` is the deliberate exception
                // — it fills *at* that close and never reaches here.
                guard i > trigger else { i += 1; continue }
                guard bar.low <= entry, bar.high >= entry else { i += 1; continue }
                setup.entryIndex = i
                setup.stage = .entered
                i += 1
                continue
            }

            // ── Live: manage the position ─────────────────────────────
            if setup.stage == .entered || setup.stage == .runningToTP2 {
                let stop = breakevenArmed ? entry : setup.stopLoss
                if beyondStop(bar, stop, isLong: isLong) {
                    // Breakeven stop after TP1 is a scratch, not a loss,
                    // but the trade is over either way.
                    setup.stage = breakevenArmed ? .hitTP : .hitSL
                    setup.resolveIndex = i
                    return
                }
                if setup.stage == .entered, reached(bar, tp1, isLong: isLong) {
                    setup.tp1Index = i
                    setup.stage = .runningToTP2
                    breakevenArmed = true
                }
                if reached(bar, tp2, isLong: isLong) {
                    setup.stage = .hitTP
                    setup.resolveIndex = i
                    return
                }
            }

            i += 1
        }
    }

    // MARK: - Predicates

    /// Price has traded into the zone from the side it approaches on.
    private static func tapped(_ bar: Candle, proximal: Double, isLong: Bool) -> Bool {
        isLong ? bar.low <= proximal : bar.high >= proximal
    }

    /// Price has traded past where the stop would sit.
    private static func beyondStop(_ bar: Candle, _ stop: Double, isLong: Bool) -> Bool {
        isLong ? bar.low < stop : bar.high > stop
    }

    private static func reached(_ bar: Candle, _ level: Double, isLong: Bool) -> Bool {
        isLong ? bar.high >= level : bar.low <= level
    }

    private static func confirms(
        at i: Int,
        armIndex arm: Int,
        candles: [Candle],
        zoneTop: Double,
        zoneBottom: Double,
        isLong: Bool,
        mode: Confirmation
    ) -> Bool {
        let bar = candles[i]
        switch mode {
        case .touch:
            return true

        case .rejection:
            // Wicked in, closed back out, and closed strong within its
            // own range — the three things that make a rejection candle
            // more than a doji.
            let range = bar.high - bar.low
            guard range > 0 else { return false }
            if isLong {
                guard bar.low <= zoneTop, bar.close > zoneTop, bar.close > bar.open else { return false }
                return (bar.close - bar.low) / range >= 2.0 / 3.0
            } else {
                guard bar.high >= zoneBottom, bar.close < zoneBottom, bar.close < bar.open else { return false }
                return (bar.high - bar.close) / range >= 2.0 / 3.0
            }

        case .microBOS:
            // A close beyond the extreme of the reaction so far. Needs at
            // least two bars of reaction to have an extreme to break,
            // which is what keeps this from degenerating into `.touch`.
            guard i >= arm + 2 else { return false }
            var extreme = isLong ? -Double.greatestFiniteMagnitude : Double.greatestFiniteMagnitude
            for k in arm...(i - 2) {
                extreme = isLong ? max(extreme, candles[k].high) : min(extreme, candles[k].low)
            }
            return isLong ? bar.close > extreme : bar.close < extreme

        case .fvg:
            // Three-bar displacement in the trade's direction: bar i's
            // range doesn't overlap bar i-2's. Detected inline rather
            // than through `FairValueGap.compute` — that scans the whole
            // series and caps its output, and all this needs is "is
            // there a gap at exactly this bar?".
            guard i >= arm, i >= 2 else { return false }
            let two = candles[i - 2]
            return isLong ? bar.low > two.high : bar.high < two.low
        }
    }

    /// `Setup` keeps its levels immutable so the plan can't drift; a
    /// `.confirmClose` re-base rebuilds it instead of mutating.
    private static func rebased(_ s: Setup, entry: Double, tp1: Double, tp2: Double) -> Setup {
        var copy = Setup(
            zoneID: s.zoneID,
            zoneTop: s.zoneTop,
            zoneBottom: s.zoneBottom,
            direction: s.direction,
            isBreakerPlay: s.isBreakerPlay,
            grade: s.grade,
            score: s.score,
            maxScore: s.maxScore,
            planIndex: s.planIndex,
            entry: entry,
            stopLoss: s.stopLoss,
            takeProfit1: tp1,
            takeProfit2: tp2,
            isProvisionalEntry: false,
            stage: s.stage
        )
        copy.armIndex = s.armIndex
        copy.triggerIndex = s.triggerIndex
        copy.entryIndex = s.entryIndex
        copy.tp1Index = s.tp1Index
        copy.resolveIndex = s.resolveIndex
        return copy
    }
}

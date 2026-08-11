import Foundation

/// SP2L + Pro BTB × Ranked Order Blocks.
///
/// Ported from the PineScript v6 indicator "SP2L + Pro BTB x Ranked OB".
/// Two *trigger* engines feed one *quality* engine; a setup only becomes
/// a signal if it clears a minimum grade.
///
/// ## The triggers
///
/// 1. **SP2L** — a displacement candle (`|close − close[2]| ≥ spikeATR ×
///    ATR`) that leaves a three-bar fair value gap behind it arms that
///    gap as a zone. Price then has to come back and trade into the
///    zone's near edge (or its 50% equilibrium, per `entryModel`) while
///    still closing on the right side of the gap, with an optional
///    confirmation candle. Closing *through* the far side inverts the
///    gap (the "IFVG" label in the original) and kills the setup.
///
/// 2. **Pro BTB** (break-then-back) — a close through the last confirmed
///    pivot with a body of at least `minBreakBodyATR × ATR` arms the
///    broken level, optionally requiring a fresh FVG that straddles it.
///    Price then has to return to the level (within `retestToleranceATR
///    × ATR`) and close back on the breakout side. The stop goes under
///    the retest low or the FVG floor, whichever is lower.
///
/// Both trigger *at the close*, enter at that close, place the stop a
/// `stopBufferATR × ATR` buffer beyond the structure, and take the
/// target at `riskReward × risk`.
///
/// ## The grade
///
/// Every armed zone is scored the moment a trigger fires, out of three
/// independent legs:
///
/// - **Volume Profile** (0–2) — does the zone sit on a high-volume node
///   of the last `vpLookback` bars?
/// - **Ichimoku** (0–3) — is the zone on the right side of the Kumo,
///   and do Tenkan/Kijun agree with the direction?
/// - **Order-block confluence** (0–2) — 2 for a live same-direction
///   order block overlapping the zone, 1 for one within
///   `obProximityATR × ATR` of it, else 0. OB and FVG are usually
///   *adjacent* rather than overlapping, which is why proximity counts.
///
/// The total maps to A (≥70%), B (≥40%) or C, and `minGrade` decides
/// which of those are allowed to signal. `obMode == .required` turns the
/// confluence leg into a hard gate rather than a bonus.
///
/// The order blocks themselves come from the same swing → BOS → extreme
/// candle engine as `RankedOrderBlocks`, re-implemented here because
/// confluence has to be judged against the blocks that were *live at the
/// signal bar* — `RankedOrderBlocks.compute` only returns the handful
/// still standing at the end of the series.
///
/// The Pine original also draws the volume-profile histogram, the
/// Ichimoku cloud and an info table; here those are scoring inputs only
/// (the app ships both as standalone indicators), same call
/// `RankedOrderBlocks` made. Order blocks *are* drawn, since they are
/// half the indicator's name.
///
/// Pure functions, no state — `ChartView` maps the result into marks.
enum RankedSP2LBTB {

    // MARK: - Types

    /// Which trigger engine produced a setup.
    enum Source: String, Hashable, Codable {
        case sp2l
        case btb

        var label: String { self == .sp2l ? "SP2L" : "BTB" }
    }

    enum Direction: String, Hashable, Codable {
        case long
        case short

        var isLong: Bool { self == .long }
    }

    /// Letter grade from the confluence score.
    enum Grade: String, Hashable, Codable {
        case a = "A"
        case b = "B"
        case c = "C"
        /// Every scoring leg disabled — nothing to grade on.
        case unranked = "–"

        /// Ordering for the `minGrade` gate. Unranked sits below C so a
        /// fully-disabled rubric still passes the "C (all)" setting.
        var rank: Int {
            switch self {
            case .a: return 3
            case .b: return 2
            case .c: return 1
            case .unranked: return 1
            }
        }
    }

    /// Where inside an armed zone the order rests.
    enum EntryModel: String, Hashable, Sendable {
        /// The near edge — the first price the retrace touches.
        case edge
        /// The zone's 50% equilibrium (Pine's "CE").
        case centre

        init(_ raw: String) {
            self = raw.lowercased() == "edge" ? .edge : .centre
        }
    }

    /// Directional gate applied to both engines.
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

    /// Bias filter — which way the wider picture has to lean before a
    /// setup may arm or fire.
    enum TrendFilter: String, Hashable, Sendable {
        case off, ema, kumo, both

        init(_ raw: String) {
            switch raw.lowercased() {
            case "off":  self = .off
            case "kumo": self = .kumo
            case "both": self = .both
            default:     self = .ema
            }
        }
    }

    /// How the order-block confluence leg is treated.
    enum OBMode: String, Hashable, Sendable {
        /// Adds to the score; a setup with no nearby block can still pass.
        case bonus
        /// No nearby block, no signal — regardless of the other legs.
        case required

        init(_ raw: String) {
            self = raw.lowercased() == "required" ? .required : .bonus
        }
    }

    /// How a zone's price range is measured off the order-block candle.
    enum ZoneSource: String, Hashable, Sendable {
        case wicks, body

        init(_ raw: String) {
            self = raw.lowercased() == "body" ? .body : .wicks
        }
    }

    /// What counts as trading through an order block.
    enum Invalidation: String, Hashable, Sendable {
        case wick, close

        init(_ raw: String) {
            self = raw.lowercased() == "close" ? .close : .wick
        }
    }

    /// Lifecycle of one setup.
    enum Status: String, Hashable, Codable {
        /// Zone is live, waiting for price to come back into it.
        case armed
        /// Triggered; the trade is open and neither level is hit yet.
        case triggered
        case hitTP
        case hitSL
        /// Price closed through the far side before triggering — an
        /// inverted FVG for SP2L, a failed breakout for BTB.
        case invalidated
        /// The wait window ran out, or a fresh zone replaced this one.
        case expired

        var isResolved: Bool { self == .hitTP || self == .hitSL }
        /// Never traded — drawn as a faded zone, not a plan.
        var isUntriggered: Bool {
            self == .armed || self == .invalidated || self == .expired
        }
    }

    // MARK: - Configuration

    struct Configuration: Hashable, Sendable {
        // ── General ──────────────────────────────────────────────────
        var enableSP2L = true
        var enableBTB = true
        var directionMode = DirectionMode.both
        var atrLength = 14
        var riskReward = 3.0
        /// Stop buffer beyond the structure, in ATR.
        var stopBufferATR = 0.15
        var entryModel = EntryModel.centre
        /// Require the trigger bar to close in the trade's direction.
        var requireConfirmation = true
        /// Cap on setups kept, newest first.
        var maxSetups = 6

        // ── SP2L ─────────────────────────────────────────────────────
        /// Minimum two-bar displacement that qualifies as a spike.
        var spikeATR = 1.5
        /// How long an armed FVG waits for its pullback.
        var maxWaitSP2L = 30

        // ── Pro BTB ──────────────────────────────────────────────────
        var pivotLength = 8
        /// Only break levels that a fresh FVG straddles.
        var requireFVGOverlap = true
        var minBreakBodyATR = 0.5
        /// How close to the broken level the retest has to come.
        var retestToleranceATR = 0.10
        var maxWaitBTB = 30

        // ── Grading ──────────────────────────────────────────────────
        var minGrade = Grade.b
        var useVolumeProfile = true
        var useIchimoku = true
        var useOrderBlocks = true
        var obMode = OBMode.bonus
        /// Order blocks sit *beside* fair value gaps more often than on
        /// top of them; this is how far apart still counts as confluence.
        var obProximityATR = 0.75

        // ── Trend filter ─────────────────────────────────────────────
        var trendFilter = TrendFilter.ema
        var emaLength = 60
        /// Apply the bias to arming as well as to entries.
        var filterZones = true

        // ── Volume Profile (scoring input) ───────────────────────────
        var vpLookback = 150
        var vpRows = 24

        // ── Ichimoku (scoring input) ─────────────────────────────────
        var tenkanLength = 9
        var kijunLength = 26
        var senkouBLength = 52
        var ichimokuDisplacement = 26

        // ── Order blocks (scoring input + overlay) ───────────────────
        var swingLength = 10
        var zoneSource = ZoneSource.wicks
        var maxOBATRMult = 3.5
        var obATRLength = 10
        var obInvalidation = Invalidation.wick
        var obPerSide = 3
        var obMaxStored = 20
        var showBreakerBlocks = true
        /// Only the last N bars are scanned for new blocks.
        var obWindow = 1750
    }

    // MARK: - Results

    /// One armed-or-fired setup.
    struct Setup: Identifiable, Hashable {
        let source: Source
        let direction: Direction
        /// Bar the spike / breakout printed on.
        let armIndex: Int
        /// Zone bounds: the FVG for SP2L, the graded band around the
        /// broken level for BTB.
        let zoneTop: Double
        let zoneBottom: Double
        /// The pivot that broke — BTB only.
        let brokenLevel: Double?
        /// Bar the broken pivot printed on, so the level line can start
        /// where the level was made — BTB only.
        let levelIndex: Int?
        /// Price the pullback has to reach to trigger.
        let entryLevel: Double

        let grade: Grade
        let score: Int
        let maxScore: Int
        /// 2 = a live order block overlaps the zone, 1 = one sits within
        /// `obProximityATR × ATR`, 0 = none.
        let obConfluence: Int

        var triggerIndex: Int?
        var entry: Double?
        var stopLoss: Double?
        var takeProfit: Double?
        /// Bar the trade hit its target or its stop.
        var resolveIndex: Int?
        var status: Status

        var id: String {
            "\(source.rawValue)-\(direction.rawValue)-\(armIndex)-\(triggerIndex.map(String.init) ?? "armed")"
        }

        /// Rightmost bar this setup still has something to say about.
        var lastRelevantIndex: Int {
            resolveIndex ?? triggerIndex ?? armIndex
        }

        /// "SP2L A 6/7" — the chart badge.
        var badge: String {
            grade == .unranked
                ? source.label
                : "\(source.label) \(grade.rawValue) \(score)/\(maxScore)"
        }
    }

    /// A ranked order block, kept for the overlay and for confluence.
    struct OrderBlock: Identifiable, Hashable {
        let startIndex: Int
        let endIndex: Int
        let top: Double
        let bottom: Double
        let isBullish: Bool
        let isBreaker: Bool
        let grade: Grade
        let score: Int
        let maxScore: Int

        var id: String {
            "sbob-\(startIndex)-\(isBullish ? "bull" : "bear")"
        }

        var badge: String {
            let base = grade == .unranked ? "OB" : "OB \(grade.rawValue)"
            return isBreaker ? "\(base) · Breaker" : base
        }
    }

    struct Output: Equatable {
        var setups: [Setup] = []
        var orderBlocks: [OrderBlock] = []
        /// Direction the trend filter is currently allowing, for the
        /// legend. `nil` when the filter is off or disagrees with itself.
        var bias: Direction?

        static let empty = Output()
    }

    // MARK: - Working state

    /// An armed zone before it becomes a `Setup` — mutable through the
    /// scan, mirroring the Pine `var` block for one engine/direction.
    private struct ArmedZone {
        let source: Source
        let direction: Direction
        let armIndex: Int
        let top: Double
        let bottom: Double
        let brokenLevel: Double?
        let levelIndex: Int?
        let entryLevel: Double
        /// FVG floor/ceiling captured at break time — BTB stop anchor.
        let fvgAnchor: Double?
    }

    private struct WorkingOB {
        var top: Double
        var bottom: Double
        var isBullish: Bool
        var startIndex: Int
        var isBreaker = false
        var breakIndex: Int?
        var score = 0
        var maxScore = 0
    }

    // MARK: - Entry point

    static func compute(_ candles: [Candle], configuration raw: Configuration = Configuration()) -> Output {
        let cfg = sanitized(raw)
        let n = candles.count
        guard n > max(cfg.swingLength + 2, cfg.atrLength + 2) else { return .empty }

        let atr = wilderATR(candles, period: cfg.atrLength)
        let obATR = wilderATR(candles, period: cfg.obATRLength)
        let ema = emaSeries(candles, period: cfg.emaLength)
        let ichi = ichimokuCloud(candles, cfg: cfg)

        // Zone-range source per bar for the order-block engine.
        let obMax: [Double] = candles.map { cfg.zoneSource == .body ? max($0.open, $0.close) : $0.high }
        let obMin: [Double] = candles.map { cfg.zoneSource == .body ? min($0.open, $0.close) : $0.low }

        // ── Order-block engine state (Pine's swing block) ────────────
        var swingType = 0                                   // 0 = last pivot a high, 1 = a low
        var swingTop: (price: Double, index: Int)?
        var swingBottom: (price: Double, index: Int)?
        var topCrossed = false
        var bottomCrossed = false
        var bullOBs: [WorkingOB] = []                       // newest first
        var bearOBs: [WorkingOB] = []
        let obWindowStart = max(0, n - max(1, cfg.obWindow))

        // ── FVG memory ───────────────────────────────────────────────
        var lastBullFVG: (bottom: Double, top: Double, index: Int)?
        var lastBearFVG: (bottom: Double, top: Double, index: Int)?

        // ── Armed slots — one per engine per direction, as in Pine ───
        var armedLongSP2L: ArmedZone?
        var armedShortSP2L: ArmedZone?
        var armedLongBTB: ArmedZone?
        var armedShortBTB: ArmedZone?

        // ── Pivot memory for BTB ─────────────────────────────────────
        var lastPivotHigh: (price: Double, index: Int)?
        var lastPivotLow: (price: Double, index: Int)?

        var setups: [Setup] = []

        /// Close out an armed zone that never traded.
        func retire(_ zone: ArmedZone, at index: Int, status: Status, gradeAt: Int) {
            let scored = gradeZone(
                direction: zone.direction, top: zone.top, bottom: zone.bottom,
                at: gradeAt, candles: candles, atr: atr, ichi: ichi,
                bullOBs: bullOBs, bearOBs: bearOBs, cfg: cfg
            )
            setups.append(Setup(
                source: zone.source, direction: zone.direction, armIndex: zone.armIndex,
                zoneTop: zone.top, zoneBottom: zone.bottom,
                brokenLevel: zone.brokenLevel, levelIndex: zone.levelIndex,
                entryLevel: zone.entryLevel,
                grade: scored.grade, score: scored.score, maxScore: scored.maxScore,
                obConfluence: scored.obConfluence,
                triggerIndex: nil, entry: nil, stopLoss: nil, takeProfit: nil,
                resolveIndex: status == .armed ? nil : index, status: status
            ))
        }

        for i in 2..<n {
            let bar = candles[i]
            let atrHere = atr[i]

            // ── Bias ─────────────────────────────────────────────────
            let (bullOK, bearOK) = bias(at: i, candles: candles, ema: ema, ichi: ichi, cfg: cfg)
            let armLong = !cfg.filterZones || bullOK
            let armShort = !cfg.filterZones || bearOK

            // ── Order blocks: swings, then lifecycle, then creation ──
            // Statement order matters and matches the Pine script.
            if i >= cfg.swingLength {
                let pivotIdx = i - cfg.swingLength
                var tailHigh = -Double.greatestFiniteMagnitude
                var tailLow = Double.greatestFiniteMagnitude
                for k in (pivotIdx + 1)...i {
                    tailHigh = max(tailHigh, candles[k].high)
                    tailLow = min(tailLow, candles[k].low)
                }
                let previousType = swingType
                if candles[pivotIdx].high > tailHigh {
                    swingType = 0
                } else if candles[pivotIdx].low < tailLow {
                    swingType = 1
                }
                if swingType == 0, previousType != 0 {
                    swingTop = (candles[pivotIdx].high, pivotIdx)
                    topCrossed = false
                }
                if swingType == 1, previousType != 1 {
                    swingBottom = (candles[pivotIdx].low, pivotIdx)
                    bottomCrossed = false
                }
            }

            let lowProbe  = cfg.obInvalidation == .wick ? bar.low  : min(bar.open, bar.close)
            let highProbe = cfg.obInvalidation == .wick ? bar.high : max(bar.open, bar.close)
            for zi in bullOBs.indices.reversed() {
                if !bullOBs[zi].isBreaker {
                    if lowProbe < bullOBs[zi].bottom {
                        bullOBs[zi].isBreaker = true
                        bullOBs[zi].breakIndex = i
                    }
                } else if bar.high > bullOBs[zi].top {
                    bullOBs.remove(at: zi)
                }
            }
            for zi in bearOBs.indices.reversed() {
                if !bearOBs[zi].isBreaker {
                    if highProbe > bearOBs[zi].top {
                        bearOBs[zi].isBreaker = true
                        bearOBs[zi].breakIndex = i
                    }
                } else if bar.low < bearOBs[zi].bottom {
                    bearOBs.remove(at: zi)
                }
            }

            if i >= obWindowStart {
                let maxWidth = obATR[i] * cfg.maxOBATRMult
                if let top = swingTop, !topCrossed, bar.close > top.price {
                    topCrossed = true
                    var zoneBottom = obMin[i - 1]
                    var zoneTop = obMax[i - 1]
                    var zoneIdx = i - 1
                    if i - 2 > top.index {
                        for j in stride(from: i - 2, through: top.index + 1, by: -1) where obMin[j] < zoneBottom {
                            zoneBottom = obMin[j]
                            zoneTop = obMax[j]
                            zoneIdx = j
                        }
                    }
                    if zoneTop > zoneBottom, maxWidth <= 0 || (zoneTop - zoneBottom) <= maxWidth {
                        var ob = WorkingOB(top: zoneTop, bottom: zoneBottom, isBullish: true, startIndex: zoneIdx)
                        let scored = zoneQuality(
                            direction: .long, top: zoneTop, bottom: zoneBottom,
                            at: i, candles: candles, ichi: ichi, cfg: cfg
                        )
                        ob.score = scored.score
                        ob.maxScore = scored.maxScore
                        bullOBs.insert(ob, at: 0)
                        if bullOBs.count > cfg.obMaxStored { bullOBs.removeLast() }
                    }
                }
                if let bottom = swingBottom, !bottomCrossed, bar.close < bottom.price {
                    bottomCrossed = true
                    var zoneTop = obMax[i - 1]
                    var zoneBottom = obMin[i - 1]
                    var zoneIdx = i - 1
                    if i - 2 > bottom.index {
                        for j in stride(from: i - 2, through: bottom.index + 1, by: -1) where obMax[j] > zoneTop {
                            zoneTop = obMax[j]
                            zoneBottom = obMin[j]
                            zoneIdx = j
                        }
                    }
                    if zoneTop > zoneBottom, maxWidth <= 0 || (zoneTop - zoneBottom) <= maxWidth {
                        var ob = WorkingOB(top: zoneTop, bottom: zoneBottom, isBullish: false, startIndex: zoneIdx)
                        let scored = zoneQuality(
                            direction: .short, top: zoneTop, bottom: zoneBottom,
                            at: i, candles: candles, ichi: ichi, cfg: cfg
                        )
                        ob.score = scored.score
                        ob.maxScore = scored.maxScore
                        bearOBs.insert(ob, at: 0)
                        if bearOBs.count > cfg.obMaxStored { bearOBs.removeLast() }
                    }
                }
            }

            // ── Fair value gaps ──────────────────────────────────────
            let bullFVG = bar.low > candles[i - 2].high
            let bearFVG = bar.high < candles[i - 2].low
            if bullFVG { lastBullFVG = (candles[i - 2].high, bar.low, i) }
            if bearFVG { lastBearFVG = (bar.high, candles[i - 2].low, i) }

            let displacement = abs(bar.close - candles[i - 2].close)
            let bigMove = atrHere > 0 && displacement > cfg.spikeATR * atrHere

            // ── SP2L: arm on a displacement FVG ──────────────────────
            let spikeUp = cfg.enableSP2L && cfg.directionMode.allowsLong && armLong
                && bullFVG && bar.close > candles[i - 2].close && bigMove
            let spikeDown = cfg.enableSP2L && cfg.directionMode.allowsShort && armShort
                && bearFVG && bar.close < candles[i - 2].close && bigMove

            if spikeUp {
                if let previous = armedLongSP2L { retire(previous, at: i, status: .expired, gradeAt: i) }
                let bottom = candles[i - 2].high
                let top = bar.low
                armedLongSP2L = ArmedZone(
                    source: .sp2l, direction: .long, armIndex: i, top: top, bottom: bottom,
                    brokenLevel: nil, levelIndex: nil,
                    entryLevel: cfg.entryModel == .centre ? (top + bottom) / 2 : top,
                    fvgAnchor: bottom
                )
            }
            if spikeDown {
                if let previous = armedShortSP2L { retire(previous, at: i, status: .expired, gradeAt: i) }
                let bottom = bar.high
                let top = candles[i - 2].low
                armedShortSP2L = ArmedZone(
                    source: .sp2l, direction: .short, armIndex: i, top: top, bottom: bottom,
                    brokenLevel: nil, levelIndex: nil,
                    entryLevel: cfg.entryModel == .centre ? (top + bottom) / 2 : bottom,
                    fvgAnchor: top
                )
            }

            // ── Pivots for BTB ───────────────────────────────────────
            let pivotIdx = i - cfg.pivotLength
            if pivotIdx >= cfg.pivotLength {
                if isPivotHigh(candles, at: pivotIdx, length: cfg.pivotLength) {
                    lastPivotHigh = (candles[pivotIdx].high, pivotIdx)
                }
                if isPivotLow(candles, at: pivotIdx, length: cfg.pivotLength) {
                    lastPivotLow = (candles[pivotIdx].low, pivotIdx)
                }
            }

            // ── Pro BTB: arm on a break of the last pivot ────────────
            let bodyOK = atrHere > 0 && abs(bar.close - bar.open) > cfg.minBreakBodyATR * atrHere
            let freshBullFVG = lastBullFVG.flatMap { i - $0.index <= 3 ? $0 : nil }
            let freshBearFVG = lastBearFVG.flatMap { i - $0.index <= 3 ? $0 : nil }

            if cfg.enableBTB, cfg.directionMode.allowsLong, armLong, bodyOK,
               let pivot = lastPivotHigh,
               bar.close > pivot.price, candles[i - 1].close <= pivot.price {
                let overlapping = freshBullFVG.flatMap {
                    $0.bottom <= pivot.price && pivot.price <= $0.top ? $0 : nil
                }
                if !cfg.requireFVGOverlap || overlapping != nil {
                    if let previous = armedLongBTB { retire(previous, at: i, status: .expired, gradeAt: i) }
                    let anchor = freshBullFVG?.bottom
                    armedLongBTB = ArmedZone(
                        source: .btb, direction: .long, armIndex: i,
                        top: pivot.price + 0.25 * atrHere,
                        bottom: anchor ?? (pivot.price - 0.25 * atrHere),
                        brokenLevel: pivot.price, levelIndex: pivot.index,
                        entryLevel: pivot.price + cfg.retestToleranceATR * atrHere,
                        fvgAnchor: anchor
                    )
                }
            }
            if cfg.enableBTB, cfg.directionMode.allowsShort, armShort, bodyOK,
               let pivot = lastPivotLow,
               bar.close < pivot.price, candles[i - 1].close >= pivot.price {
                let overlapping = freshBearFVG.flatMap {
                    $0.bottom <= pivot.price && pivot.price <= $0.top ? $0 : nil
                }
                if !cfg.requireFVGOverlap || overlapping != nil {
                    if let previous = armedShortBTB { retire(previous, at: i, status: .expired, gradeAt: i) }
                    let anchor = freshBearFVG?.top
                    armedShortBTB = ArmedZone(
                        source: .btb, direction: .short, armIndex: i,
                        top: anchor ?? (pivot.price + 0.25 * atrHere),
                        bottom: pivot.price - 0.25 * atrHere,
                        brokenLevel: pivot.price, levelIndex: pivot.index,
                        entryLevel: pivot.price - cfg.retestToleranceATR * atrHere,
                        fvgAnchor: anchor
                    )
                }
            }

            // ── Triggers ─────────────────────────────────────────────
            let confirmUp = !cfg.requireConfirmation || bar.close > bar.open
            let confirmDown = !cfg.requireConfirmation || bar.close < bar.open

            /// Grade, gate, and (if it passes) fire an armed zone.
            func attempt(_ zone: ArmedZone, stop: Double) -> Bool {
                let scored = gradeZone(
                    direction: zone.direction, top: zone.top, bottom: zone.bottom,
                    at: i, candles: candles, atr: atr, ichi: ichi,
                    bullOBs: bullOBs, bearOBs: bearOBs, cfg: cfg
                )
                guard scored.grade.rank >= cfg.minGrade.rank else { return false }
                if cfg.useOrderBlocks, cfg.obMode == .required, scored.obConfluence == 0 { return false }

                let entry = bar.close
                let risk = abs(entry - stop)
                guard risk > 0 else { return false }
                let target = zone.direction.isLong
                    ? entry + risk * cfg.riskReward
                    : entry - risk * cfg.riskReward

                var setup = Setup(
                    source: zone.source, direction: zone.direction, armIndex: zone.armIndex,
                    zoneTop: zone.top, zoneBottom: zone.bottom,
                    brokenLevel: zone.brokenLevel, levelIndex: zone.levelIndex,
                    entryLevel: zone.entryLevel,
                    grade: scored.grade, score: scored.score, maxScore: scored.maxScore,
                    obConfluence: scored.obConfluence,
                    triggerIndex: i, entry: entry, stopLoss: stop, takeProfit: target,
                    resolveIndex: nil, status: .triggered
                )
                resolve(&setup, candles: candles)
                setups.append(setup)
                return true
            }

            if let zone = armedLongSP2L, !spikeUp, bullOK,
               bar.low <= zone.entryLevel, bar.close > zone.bottom, confirmUp,
               i - zone.armIndex <= cfg.maxWaitSP2L {
                if attempt(zone, stop: zone.bottom - cfg.stopBufferATR * atrHere) {
                    armedLongSP2L = nil
                }
            }
            if let zone = armedShortSP2L, !spikeDown, bearOK,
               bar.high >= zone.entryLevel, bar.close < zone.top, confirmDown,
               i - zone.armIndex <= cfg.maxWaitSP2L {
                if attempt(zone, stop: zone.top + cfg.stopBufferATR * atrHere) {
                    armedShortSP2L = nil
                }
            }

            if let zone = armedLongBTB, let level = zone.brokenLevel,
               i > zone.armIndex + 1, bullOK,
               bar.low <= zone.entryLevel, bar.close > level, confirmUp,
               i - zone.armIndex <= cfg.maxWaitBTB {
                let base = min(zone.fvgAnchor ?? min(bar.low, level), bar.low)
                if attempt(zone, stop: base - cfg.stopBufferATR * atrHere) {
                    armedLongBTB = nil
                }
            }
            if let zone = armedShortBTB, let level = zone.brokenLevel,
               i > zone.armIndex + 1, bearOK,
               bar.high >= zone.entryLevel, bar.close < level, confirmDown,
               i - zone.armIndex <= cfg.maxWaitBTB {
                let base = max(zone.fvgAnchor ?? max(bar.high, level), bar.high)
                if attempt(zone, stop: base + cfg.stopBufferATR * atrHere) {
                    armedShortBTB = nil
                }
            }

            // ── Invalidation / timeout ───────────────────────────────
            if let zone = armedLongSP2L, !spikeUp {
                if bar.close < zone.bottom {
                    retire(zone, at: i, status: .invalidated, gradeAt: i)
                    armedLongSP2L = nil
                } else if i - zone.armIndex > cfg.maxWaitSP2L {
                    retire(zone, at: i, status: .expired, gradeAt: i)
                    armedLongSP2L = nil
                }
            }
            if let zone = armedShortSP2L, !spikeDown {
                if bar.close > zone.top {
                    retire(zone, at: i, status: .invalidated, gradeAt: i)
                    armedShortSP2L = nil
                } else if i - zone.armIndex > cfg.maxWaitSP2L {
                    retire(zone, at: i, status: .expired, gradeAt: i)
                    armedShortSP2L = nil
                }
            }
            if let zone = armedLongBTB, let level = zone.brokenLevel {
                if bar.close < level - cfg.stopBufferATR * atrHere {
                    retire(zone, at: i, status: .invalidated, gradeAt: i)
                    armedLongBTB = nil
                } else if i - zone.armIndex > cfg.maxWaitBTB {
                    retire(zone, at: i, status: .expired, gradeAt: i)
                    armedLongBTB = nil
                }
            }
            if let zone = armedShortBTB, let level = zone.brokenLevel {
                if bar.close > level + cfg.stopBufferATR * atrHere {
                    retire(zone, at: i, status: .invalidated, gradeAt: i)
                    armedShortBTB = nil
                } else if i - zone.armIndex > cfg.maxWaitBTB {
                    retire(zone, at: i, status: .expired, gradeAt: i)
                    armedShortBTB = nil
                }
            }
        }

        // Zones still waiting at the right edge — graded as of the last
        // bar, which is what the Pine box text shows.
        for zone in [armedLongSP2L, armedShortSP2L, armedLongBTB, armedShortBTB].compactMap({ $0 }) {
            retire(zone, at: n - 1, status: .armed, gradeAt: n - 1)
        }

        setups.sort { $0.lastRelevantIndex < $1.lastRelevantIndex }
        var output = Output(
            setups: Array(setups.suffix(cfg.maxSetups)),
            orderBlocks: renderableOBs(bullOBs: bullOBs, bearOBs: bearOBs, lastIndex: n - 1, cfg: cfg),
            bias: nil
        )
        let (finalBull, finalBear) = bias(at: n - 1, candles: candles, ema: ema, ichi: ichi, cfg: cfg)
        if cfg.trendFilter != .off {
            output.bias = finalBull ? .long : finalBear ? .short : nil
        }
        return output
    }

    // MARK: - Trade resolution

    /// Walk a fired setup forward to its target or its stop. A bar that
    /// spans both reads as a loss — intrabar order is unknowable from
    /// OHLC, and this matches `RankedOBStrategy` / `AMDCycle`.
    private static func resolve(_ setup: inout Setup, candles: [Candle]) {
        guard let start = setup.triggerIndex,
              let stop = setup.stopLoss,
              let target = setup.takeProfit,
              start + 1 < candles.count
        else { return }

        for i in (start + 1)..<candles.count {
            let bar = candles[i]
            let hitStop = setup.direction.isLong ? bar.low <= stop : bar.high >= stop
            let hitTarget = setup.direction.isLong ? bar.high >= target : bar.low <= target
            if hitStop || hitTarget {
                setup.resolveIndex = i
                setup.status = hitStop ? .hitSL : .hitTP
                return
            }
        }
    }

    // MARK: - Order-block render set

    private static func renderableOBs(
        bullOBs: [WorkingOB],
        bearOBs: [WorkingOB],
        lastIndex: Int,
        cfg: Configuration
    ) -> [OrderBlock] {
        func map(_ list: [WorkingOB]) -> [OrderBlock] {
            list.prefix(cfg.obPerSide)
                .filter { cfg.showBreakerBlocks || !$0.isBreaker }
                .map {
                    OrderBlock(
                        startIndex: $0.startIndex,
                        endIndex: $0.isBreaker ? ($0.breakIndex ?? lastIndex) : lastIndex,
                        top: $0.top,
                        bottom: $0.bottom,
                        isBullish: $0.isBullish,
                        isBreaker: $0.isBreaker,
                        grade: grade(score: $0.score, maxScore: $0.maxScore),
                        score: $0.score,
                        maxScore: $0.maxScore
                    )
                }
        }
        return map(bullOBs) + map(bearOBs)
    }

    // MARK: - Bias

    private static func bias(
        at bar: Int,
        candles: [Candle],
        ema: [Double?],
        ichi: IchimokuCloud,
        cfg: Configuration
    ) -> (bull: Bool, bear: Bool) {
        guard cfg.trendFilter != .off else { return (true, true) }
        let close = candles[bar].close
        let emaValue = ema[bar]
        let emaUp = emaValue.map { close > $0 } ?? false
        let emaDown = emaValue.map { close < $0 } ?? false
        let kumoUp = ichi.top[bar].map { close > $0 } ?? false
        let kumoDown = ichi.bottom[bar].map { close < $0 } ?? false

        switch cfg.trendFilter {
        case .off:  return (true, true)
        case .ema:  return (emaUp, emaDown)
        case .kumo: return (kumoUp, kumoDown)
        case .both: return (emaUp && kumoUp, emaDown && kumoDown)
        }
    }

    // MARK: - Scoring

    private struct Scored {
        let score: Int
        let maxScore: Int
        let grade: Grade
        let obConfluence: Int
    }

    /// The two context legs (Volume Profile + Ichimoku) — what an order
    /// block is graded on, since a block cannot be in confluence with
    /// itself.
    private static func zoneQuality(
        direction: Direction,
        top: Double,
        bottom: Double,
        at bar: Int,
        candles: [Candle],
        ichi: IchimokuCloud,
        cfg: Configuration
    ) -> (score: Int, maxScore: Int) {
        var score = 0
        var maxScore = 0
        if cfg.useVolumeProfile {
            maxScore += 2
            score += volumeScore(top: top, bottom: bottom, at: bar, candles: candles, cfg: cfg)
        }
        if cfg.useIchimoku {
            maxScore += 3
            score += ichimokuScore(
                top: top, bottom: bottom, isBullish: direction.isLong, at: bar, ichi: ichi
            )
        }
        return (score, maxScore)
    }

    /// All three legs — what a *setup* is graded on.
    private static func gradeZone(
        direction: Direction,
        top: Double,
        bottom: Double,
        at bar: Int,
        candles: [Candle],
        atr: [Double],
        ichi: IchimokuCloud,
        bullOBs: [WorkingOB],
        bearOBs: [WorkingOB],
        cfg: Configuration
    ) -> Scored {
        let context = zoneQuality(
            direction: direction, top: top, bottom: bottom,
            at: bar, candles: candles, ichi: ichi, cfg: cfg
        )
        var score = context.score
        var maxScore = context.maxScore
        var confluence = 0
        if cfg.useOrderBlocks {
            maxScore += 2
            confluence = obConfluence(
                direction: direction, top: top, bottom: bottom,
                atr: atr[bar], blocks: direction.isLong ? bullOBs : bearOBs, cfg: cfg
            )
            score += confluence
        }
        return Scored(
            score: score,
            maxScore: maxScore,
            grade: grade(score: score, maxScore: maxScore),
            obConfluence: confluence
        )
    }

    /// 2 for a live same-direction block overlapping the zone, 1 for one
    /// within `obProximityATR × ATR`, 0 for none.
    private static func obConfluence(
        direction: Direction,
        top: Double,
        bottom: Double,
        atr: Double,
        blocks: [WorkingOB],
        cfg: Configuration
    ) -> Int {
        var best = 0
        let reach = cfg.obProximityATR * atr
        for block in blocks where !block.isBreaker {
            let gap = max(block.bottom - top, bottom - block.top)
            if gap <= 0 {
                return 2
            } else if gap <= reach {
                best = max(best, 1)
            }
        }
        return best
    }

    /// 0–2 by how close the zone's busiest price row sits to the profile
    /// peak over the last `vpLookback` bars: ≥70% → 2, ≥40% → 1, else 0.
    private static func volumeScore(
        top: Double,
        bottom: Double,
        at bar: Int,
        candles: [Candle],
        cfg: Configuration
    ) -> Int {
        let rows = max(1, cfg.vpRows)
        let lookback = max(1, min(cfg.vpLookback, bar + 1))
        let start = bar - lookback + 1
        var hi = -Double.greatestFiniteMagnitude
        var lo = Double.greatestFiniteMagnitude
        for k in start...bar {
            hi = max(hi, candles[k].high)
            lo = min(lo, candles[k].low)
        }
        let step = (hi - lo) / Double(rows)
        guard step > 0 else { return 0 }

        var bins = [Double](repeating: 0, count: rows)
        for k in start...bar {
            let typical = (candles[k].high + candles[k].low + candles[k].close) / 3
            let b = max(0, min(rows - 1, Int((typical - lo) / step)))
            bins[b] += candles[k].volume ?? 0
        }
        guard let peak = bins.max(), peak > 0 else { return 0 }

        let b0 = max(0, min(rows - 1, Int((bottom - lo) / step)))
        let b1 = max(0, min(rows - 1, Int((top - lo) / step)))
        var localMax = 0.0
        for b in min(b0, b1)...max(b0, b1) { localMax = max(localMax, bins[b]) }

        let ratio = localMax / peak
        return ratio >= 0.7 ? 2 : ratio >= 0.4 ? 1 : 0
    }

    /// 0–3: position relative to the Kumo (0–2) plus Tenkan/Kijun
    /// agreement (0–1).
    private static func ichimokuScore(
        top: Double,
        bottom: Double,
        isBullish: Bool,
        at bar: Int,
        ichi: IchimokuCloud
    ) -> Int {
        guard let cloudTop = ichi.top[bar], let cloudBottom = ichi.bottom[bar] else { return 0 }
        let tenkan = ichi.tenkan[bar]
        let kijun = ichi.kijun[bar]
        var score: Int
        if isBullish {
            score = bottom > cloudTop ? 2 : top < cloudBottom ? 0 : 1
            if let tenkan, let kijun, tenkan > kijun { score += 1 }
        } else {
            score = top < cloudBottom ? 2 : bottom > cloudTop ? 0 : 1
            if let tenkan, let kijun, tenkan < kijun { score += 1 }
        }
        return score
    }

    private static func grade(score: Int, maxScore: Int) -> Grade {
        guard maxScore > 0 else { return .unranked }
        let ratio = Double(score) / Double(maxScore)
        return ratio >= 0.7 ? .a : ratio >= 0.4 ? .b : .c
    }

    // MARK: - Pivots

    /// Strict pivot: higher than every bar within `length` on both
    /// sides, the way `ta.pivothigh(length, length)` reads.
    private static func isPivotHigh(_ candles: [Candle], at index: Int, length: Int) -> Bool {
        guard index - length >= 0, index + length < candles.count else { return false }
        let value = candles[index].high
        for k in (index - length)...(index + length) where k != index {
            if candles[k].high >= value { return false }
        }
        return true
    }

    private static func isPivotLow(_ candles: [Candle], at index: Int, length: Int) -> Bool {
        guard index - length >= 0, index + length < candles.count else { return false }
        let value = candles[index].low
        for k in (index - length)...(index + length) where k != index {
            if candles[k].low <= value { return false }
        }
        return true
    }

    // MARK: - Ichimoku

    /// Per-bar Ichimoku values. `top`/`bottom` are the Kumo boundaries
    /// *as seen at that bar* — Senkou A/B computed `displacement` bars
    /// earlier, which is where the cloud gets its forward shift.
    private struct IchimokuCloud {
        let tenkan: [Double?]
        let kijun: [Double?]
        let top: [Double?]
        let bottom: [Double?]
    }

    private static func ichimokuCloud(_ candles: [Candle], cfg: Configuration) -> IchimokuCloud {
        let n = candles.count
        let tenkan = donchianMid(candles, period: cfg.tenkanLength)
        let kijun = donchianMid(candles, period: cfg.kijunLength)
        let senkouB = donchianMid(candles, period: cfg.senkouBLength)
        var senkouA = [Double?](repeating: nil, count: n)
        for i in 0..<n {
            if let t = tenkan[i], let k = kijun[i] { senkouA[i] = (t + k) / 2 }
        }

        let displacement = cfg.ichimokuDisplacement
        var top = [Double?](repeating: nil, count: n)
        var bottom = [Double?](repeating: nil, count: n)
        if displacement < n {
            for i in displacement..<n {
                guard let a = senkouA[i - displacement], let b = senkouB[i - displacement] else { continue }
                top[i] = max(a, b)
                bottom[i] = min(a, b)
            }
        }
        return IchimokuCloud(tenkan: tenkan, kijun: kijun, top: top, bottom: bottom)
    }

    /// Midpoint of the rolling high/low channel — the shape every
    /// Ichimoku line takes.
    private static func donchianMid(_ candles: [Candle], period: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: candles.count)
        guard period > 0, candles.count >= period else { return out }
        for i in (period - 1)..<candles.count {
            var hi = -Double.greatestFiniteMagnitude
            var lo = Double.greatestFiniteMagnitude
            for k in (i - period + 1)...i {
                hi = max(hi, candles[k].high)
                lo = min(lo, candles[k].low)
            }
            out[i] = (hi + lo) / 2
        }
        return out
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

    private static func emaSeries(_ candles: [Candle], period: Int) -> [Double?] {
        var out = [Double?](repeating: nil, count: candles.count)
        guard period > 1, candles.count >= period else { return out }
        var previous = candles.prefix(period).map(\.close).reduce(0, +) / Double(period)
        out[period - 1] = previous
        let multiplier = 2.0 / Double(period + 1)
        guard period < candles.count else { return out }
        for i in period..<candles.count {
            previous = (candles[i].close - previous) * multiplier + previous
            out[i] = previous
        }
        return out
    }

    // MARK: - Config hygiene

    private static func sanitized(_ cfg: Configuration) -> Configuration {
        var c = cfg
        c.atrLength = max(2, c.atrLength)
        c.obATRLength = max(1, c.obATRLength)
        c.emaLength = max(2, c.emaLength)
        c.riskReward = max(0.1, c.riskReward)
        c.stopBufferATR = max(0, c.stopBufferATR)
        c.maxSetups = max(1, c.maxSetups)
        c.spikeATR = max(0.01, c.spikeATR)
        c.maxWaitSP2L = max(1, c.maxWaitSP2L)
        c.pivotLength = max(2, c.pivotLength)
        c.minBreakBodyATR = max(0, c.minBreakBodyATR)
        c.retestToleranceATR = max(0, c.retestToleranceATR)
        c.maxWaitBTB = max(1, c.maxWaitBTB)
        c.obProximityATR = max(0, c.obProximityATR)
        c.vpLookback = max(5, c.vpLookback)
        c.vpRows = max(2, c.vpRows)
        c.tenkanLength = max(1, c.tenkanLength)
        c.kijunLength = max(1, c.kijunLength)
        c.senkouBLength = max(2, c.senkouBLength)
        c.ichimokuDisplacement = max(1, c.ichimokuDisplacement)
        c.swingLength = max(3, c.swingLength)
        c.maxOBATRMult = max(0, c.maxOBATRMult)
        c.obPerSide = max(1, c.obPerSide)
        c.obMaxStored = max(c.obPerSide, c.obMaxStored)
        c.obWindow = max(50, c.obWindow)
        return c
    }
}

extension RankedSP2LBTB.Configuration {
    /// Build from an `IndicatorInstance`'s param dictionary. Mirrors how
    /// `AMDCycle` / `HelixOBCombo` / `AlgoSmartAssist` read their
    /// settings — the newer indicators skip the `OscillatorConfig`
    /// mirror entirely.
    init(params: [String: ParamValue]) {
        self.init()
        if let v = params["enableSP2L"]        { enableSP2L = v.boolValue }
        if let v = params["enableBTB"]         { enableBTB = v.boolValue }
        if let v = params["directionMode"]     { directionMode = RankedSP2LBTB.DirectionMode(v.stringValue) }
        if let v = params["atrLength"]         { atrLength = Int(v.doubleValue) }
        if let v = params["riskReward"]        { riskReward = v.doubleValue }
        if let v = params["stopBufferATR"]     { stopBufferATR = v.doubleValue }
        if let v = params["entryModel"]        { entryModel = RankedSP2LBTB.EntryModel(v.stringValue) }
        if let v = params["requireConfirmation"] { requireConfirmation = v.boolValue }
        if let v = params["maxSetups"]         { maxSetups = Int(v.doubleValue) }

        if let v = params["spikeATR"]          { spikeATR = v.doubleValue }
        if let v = params["maxWaitSP2L"]       { maxWaitSP2L = Int(v.doubleValue) }

        if let v = params["pivotLength"]       { pivotLength = Int(v.doubleValue) }
        if let v = params["requireFVGOverlap"] { requireFVGOverlap = v.boolValue }
        if let v = params["minBreakBodyATR"]   { minBreakBodyATR = v.doubleValue }
        if let v = params["retestToleranceATR"] { retestToleranceATR = v.doubleValue }
        if let v = params["maxWaitBTB"]        { maxWaitBTB = Int(v.doubleValue) }

        if let v = params["minGrade"] {
            minGrade = RankedSP2LBTB.Grade(rawValue: v.stringValue.uppercased()) ?? .b
        }
        if let v = params["useVolumeProfile"]  { useVolumeProfile = v.boolValue }
        if let v = params["useIchimoku"]       { useIchimoku = v.boolValue }
        if let v = params["useOrderBlocks"]    { useOrderBlocks = v.boolValue }
        if let v = params["obMode"]            { obMode = RankedSP2LBTB.OBMode(v.stringValue) }
        if let v = params["obProximityATR"]    { obProximityATR = v.doubleValue }

        if let v = params["trendFilter"]       { trendFilter = RankedSP2LBTB.TrendFilter(v.stringValue) }
        if let v = params["emaLength"]         { emaLength = Int(v.doubleValue) }
        if let v = params["filterZones"]       { filterZones = v.boolValue }

        if let v = params["vpLookback"]        { vpLookback = Int(v.doubleValue) }
        if let v = params["vpRows"]            { vpRows = Int(v.doubleValue) }

        if let v = params["tenkanLength"]      { tenkanLength = Int(v.doubleValue) }
        if let v = params["kijunLength"]       { kijunLength = Int(v.doubleValue) }
        if let v = params["senkouBLength"]     { senkouBLength = Int(v.doubleValue) }
        if let v = params["ichimokuDisplacement"] { ichimokuDisplacement = Int(v.doubleValue) }

        if let v = params["swingLength"]       { swingLength = Int(v.doubleValue) }
        if let v = params["zoneSource"]        { zoneSource = RankedSP2LBTB.ZoneSource(v.stringValue) }
        if let v = params["maxOBATRMult"]      { maxOBATRMult = v.doubleValue }
        if let v = params["obATRLength"]       { obATRLength = Int(v.doubleValue) }
        if let v = params["obInvalidation"]    { obInvalidation = RankedSP2LBTB.Invalidation(v.stringValue) }
        if let v = params["obPerSide"]         { obPerSide = Int(v.doubleValue) }
        if let v = params["obMaxStored"]       { obMaxStored = Int(v.doubleValue) }
        if let v = params["showBreakerBlocks"] { showBreakerBlocks = v.boolValue }
        if let v = params["obWindow"]          { obWindow = Int(v.doubleValue) }
    }
}

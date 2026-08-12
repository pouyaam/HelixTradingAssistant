import Foundation

/// Smart Money Concepts setup finder driven **solely** by the
/// `AlgoSmartAssist` (ALGOSMART ASSIST v2) indicator.
///
/// The strategy, in the order the rules are evaluated:
///
/// 1. **Context** — the higher timeframe's most recent confirmed BOS or CHoCH
///    sets the only direction the radar will trade. There are no counter-trend
///    setups: a LTF CHoCH is a *trigger* in this strategy, not a context.
/// 2. **Liquidity grab** — price must have swept the inducement (IDM) or taken
///    a prior swing high/low (the indicator's "X" sweep) since that context
///    event. An IDM line is only ever drawn by the indicator at the moment the
///    inducement is swept, so its presence *is* the confirmation.
/// 3. **POI mitigation** — the setup anchors on a demand zone (long) or supply
///    zone (short) sitting on the correct side of the 0.5 equilibrium:
///    discount for longs, premium for shorts.
/// 4. **Trigger** — a bullish/bearish SCOB candle closing inside the POI, or a
///    LTF CHoCH printed after the liquidity grab.
/// 5. **Execution** — entry at the trigger close (or the POI edge while still
///    waiting), stop a few ticks beyond the zone, TP1 at equilibrium or 1:2,
///    TP2 at the opposing zone or the major swing.
///
/// Everything here is pure and synchronous so it can be unit-tested and run
/// off the main actor.
enum SMCSentinelEngine {

    // MARK: - Tunables

    /// How far back a liquidity grab may sit and still count as "the current
    /// leg's" sweep.
    static let grabLookbackBars = 120
    /// A setup further than this many ATRs from spot is not actionable.
    static let maxDistanceATR = 12.0
    /// Discard setups that already travelled most of the way to TP1.
    static let maxProgressToTP1 = 0.70
    static let maxSetupsPerSymbol = 6

    // MARK: - Indicator configuration

    /// The parameter set the sentinel drives the indicator with.
    ///
    /// `markX` is on so sweep lines carry the "X" caption — that is the only
    /// thing distinguishing them from BOS/CHoCH/IDM lines once the indicator
    /// flattens everything into `Output.lines`. `showHL` is on because the
    /// HH/LH/HL/LL labels are the major-swing source for TP2.
    static var indicatorParams: [String: ParamValue] {
        [
            "showPOI": .bool(true),
            "poiType": .string("---"),
            "mergeRatio": .double(0.0),
            "maxBarHistory": .double(500),
            "structureType": .string("Choch without IDM"),
            "showHL": .bool(true),
            "showCircleHL": .bool(false),
            "showMn": .bool(false),
            "showBOS": .bool(true),
            "showChoCh": .bool(true),
            "showIDM": .bool(true),
            "showPdhl": .bool(false),
            "showMid": .bool(true),
            "showSw": .bool(true),
            "markX": .bool(true),
            "showTP": .bool(false),
            "showliveBOS": .bool(true),
            "showliveChoch": .bool(true),
            "showliveIDM": .bool(true),
            "showSCOB": .bool(true),
            "showISB": .bool(false),
            "showOSB": .bool(false),
        ]
    }

    // MARK: - Result types

    /// Why a scan produced nothing — surfaced in the drawer so an empty radar
    /// explains itself instead of just showing "no setups".
    enum Blocker: String {
        case notEnoughBars = "Not enough history"
        case noHTFContext = "No HTF BOS/CHoCH yet"
        case noEquilibrium = "No structural range yet"
        case noLiquidityGrab = "Waiting for IDM / liquidity sweep"
        case noValidPOI = "No POI in discount/premium"
        case none = ""
    }

    struct Context: Equatable {
        let isBullish: Bool
        /// "BOS" or "CHoCH".
        let event: String
        let bar: Int
        let price: Double

        var label: String { "\(isBullish ? "Bullish" : "Bearish") \(event)" }
    }

    struct LiquidityGrab: Equatable {
        enum Kind: String { case idm = "IDM sweep", sweep = "Liquidity sweep" }
        let kind: Kind
        let bar: Int
        let level: Double
    }

    struct Trigger: Equatable {
        enum Kind: String { case scob = "SCOB", choch = "LTF CHoCH" }
        let kind: Kind
        let bar: Int
        let close: Double
        let low: Double
        let high: Double
    }

    struct Setup: Equatable {
        let zoneID: String
        let isLong: Bool
        let status: RadarAlert.SetupStatus
        let entry: Double
        let stopLoss: Double
        let takeProfit1: Double
        let takeProfit2: Double
        let zoneTop: Double
        let zoneBottom: Double
        let equilibrium: Double
        let riskReward: Double
        let score: Int
        let breakdown: RadarAlert.ConfluenceBreakdown
        let rationale: String
    }

    struct ScanResult: Equatable {
        let setups: [Setup]
        let context: Context?
        let equilibrium: Double?
        let blocker: Blocker

        static let empty = ScanResult(setups: [], context: nil, equilibrium: nil, blocker: .notEnoughBars)
    }

    // MARK: - Entry point

    /// Runs the full strategy over a candle series and its higher-timeframe
    /// series. The two series are matched by **date**, not by bar count — the
    /// HTF candles are loaded independently and need not start where the LTF
    /// ones do.
    static func scan(
        candles: [Candle],
        htfCandles: [Candle],
        htfLabel: String
    ) -> ScanResult {
        guard candles.count >= 60, let last = candles.last else {
            return ScanResult(setups: [], context: nil, equilibrium: nil, blocker: .notEnoughBars)
        }

        let ltf = AlgoSmartAssist.calculate(candles: candles, params: indicatorParams)

        // 1. Context — HTF BOS/CHoCH. Falls back to the LTF read only when the
        //    HTF series is too short for the indicator to map structure.
        let htf = htfCandles.count >= 60
            ? AlgoSmartAssist.calculate(candles: htfCandles, params: indicatorParams)
            : nil
        let htfEvents = structureEvents(htf ?? ltf)
        guard let context = htfEvents.last.map({
            Context(isBullish: $0.isBullish,
                    event: $0.labelText == AlgoSmartAssist.Caption.bos ? "BOS" : "CHoCH",
                    bar: $0.endBar,
                    price: $0.price)
        }) else {
            return ScanResult(setups: [], context: nil, equilibrium: nil, blocker: .noHTFContext)
        }

        let isLong = context.isBullish

        // 2. Equilibrium — the indicator's live 0.5 line over the current
        //    structural leg. Premium above, discount below.
        guard let equilibrium = ltf.liveLines.first(where: { $0.id == "live-mid" })?.price else {
            return ScanResult(setups: [], context: context, equilibrium: nil, blocker: .noEquilibrium)
        }

        let price = last.close
        let atr = atr14(candles)
        let lastBar = candles.count - 1

        // 3. Liquidity grab since the context event. The indicator only draws
        //    an IDM line at the bar the inducement is swept, so any recent IDM
        //    in our direction is itself a completed grab.
        //
        //    The gate is the HTF context bar mapped into LTF space — *not* the
        //    latest LTF structure event. Within one leg the indicator prints
        //    BOS → IDM sweep → BOS, so gating on the newest LTF BOS would throw
        //    away the very sweep that qualifies the setup.
        let ltfEvents = structureEvents(ltf)
        let contextLTFBar: Int
        if htf == nil {
            contextLTFBar = context.bar          // already an LTF index
        } else if context.bar < htfCandles.count {
            contextLTFBar = firstBar(in: candles, atOrAfter: htfCandles[context.bar].id)
        } else {
            contextLTFBar = lastBar
        }
        let earliest = max(0, min(contextLTFBar, lastBar), lastBar - grabLookbackBars)

        let idmGrab = ltf.lines
            .filter { $0.labelText == AlgoSmartAssist.Caption.idm && $0.isBullish == isLong && $0.endBar >= earliest }
            .max(by: { $0.endBar < $1.endBar })
            .map { LiquidityGrab(kind: .idm, bar: $0.endBar, level: $0.price) }

        // A long wants a *low* taken out; `drawSweep(trend:)` tags a low sweep
        // as bearish and a high sweep as bullish.
        let xGrab = ltf.lines
            .filter { $0.labelText == AlgoSmartAssist.Caption.sweep && $0.isBullish != isLong && $0.endBar >= earliest }
            .max(by: { $0.endBar < $1.endBar })
            .map { LiquidityGrab(kind: .sweep, bar: $0.endBar, level: $0.price) }

        let grab = [idmGrab, xGrab].compactMap { $0 }.max(by: { $0.bar < $1.bar })
        guard let grab else {
            return ScanResult(setups: [], context: context, equilibrium: equilibrium, blocker: .noLiquidityGrab)
        }

        // 4. POI zones on the traded side, on the correct half of equilibrium.
        let poiZones = ltf.zones.filter { zone in
            guard zone.isSupply != isLong else { return false }
            let mid = (zone.top + zone.bottom) / 2
            return isLong ? (mid <= equilibrium) : (mid >= equilibrium)
        }
        guard !poiZones.isEmpty else {
            return ScanResult(setups: [], context: context, equilibrium: equilibrium, blocker: .noValidPOI)
        }

        let ltfAligned = ltfEvents.last?.isBullish == isLong
        let swingTargets = majorSwings(ltf, isLong: isLong)
        let opposing = ltf.zones.filter { $0.isSupply == isLong }

        var setups: [Setup] = []
        for zone in poiZones {
            guard let setup = buildSetup(
                zone: zone,
                isLong: isLong,
                context: context,
                htfLabel: htfLabel,
                grab: grab,
                equilibrium: equilibrium,
                price: price,
                atr: atr,
                candles: candles,
                ltf: ltf,
                ltfAligned: ltfAligned,
                opposingZones: opposing,
                swingTargets: swingTargets
            ) else { continue }
            setups.append(setup)
        }

        // Strongest first; ties broken by how close the entry is to spot.
        setups.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return abs(a.entry - price) < abs(b.entry - price)
        }

        return ScanResult(
            setups: Array(setups.prefix(maxSetupsPerSymbol)),
            context: context,
            equilibrium: equilibrium,
            blocker: setups.isEmpty ? .noValidPOI : .none
        )
    }

    // MARK: - Setup construction

    private static func buildSetup(
        zone: AlgoSmartAssist.POIZone,
        isLong: Bool,
        context: Context,
        htfLabel: String,
        grab: LiquidityGrab,
        equilibrium: Double,
        price: Double,
        atr: Double,
        candles: [Candle],
        ltf: AlgoSmartAssist.Output,
        ltfAligned: Bool,
        opposingZones: [AlgoSmartAssist.POIZone],
        swingTargets: [Double]
    ) -> Setup? {
        let poiEdge = isLong ? zone.top : zone.bottom

        // Out of reach → not actionable.
        guard abs(price - poiEdge) <= max(maxDistanceATR * atr, price * 0.05) else { return nil }

        // 5. Trigger — SCOB closing inside the POI, or a LTF CHoCH after the grab.
        let trigger = findTrigger(
            zone: zone, isLong: isLong, grabBar: grab.bar, candles: candles, ltf: ltf
        )

        let entry = trigger?.close ?? poiEdge
        let buffer = stopBuffer(price: price, atr: atr)
        let stopLoss: Double
        if isLong {
            stopLoss = min(zone.bottom, trigger?.low ?? zone.bottom) - buffer
        } else {
            stopLoss = max(zone.top, trigger?.high ?? zone.top) + buffer
        }

        let risk = abs(entry - stopLoss)
        guard risk > 0 else { return nil }

        // TP1: equilibrium when it pays at least 1R, otherwise a 1:2 target.
        let eqReward = isLong ? (equilibrium - entry) : (entry - equilibrium)
        let takeProfit1 = eqReward / risk >= 1.0
            ? equilibrium
            : (isLong ? entry + 2 * risk : entry - 2 * risk)

        // TP2: nearest opposing zone beyond TP1, else the major swing, else 3R.
        let opposingEdge = opposingZones
            .map { isLong ? $0.bottom : $0.top }
            .filter { isLong ? $0 > takeProfit1 : $0 < takeProfit1 }
            .min(by: { isLong ? $0 < $1 : $0 > $1 })
        let swingEdge = swingTargets
            .filter { isLong ? $0 > takeProfit1 : $0 < takeProfit1 }
            .min(by: { isLong ? $0 < $1 : $0 > $1 })
        let fallback2 = isLong ? entry + 3 * risk : entry - 3 * risk
        let takeProfit2 = opposingEdge ?? swingEdge ?? fallback2

        let rr = abs(takeProfit1 - entry) / risk
        guard rr >= 1.0 else { return nil }

        // 6. Status & invalidation.
        let inZone = price >= zone.bottom && price <= zone.top
        let beyond = isLong ? price > zone.top : price < zone.bottom

        // Stop already taken out → dead setup, not a radar entry.
        if isLong ? (price <= stopLoss) : (price >= stopLoss) { return nil }

        // Already ran most of the way to TP1 → the trade is gone.
        if beyond {
            let span = abs(takeProfit1 - entry)
            if span > 0, abs(price - entry) / span > maxProgressToTP1 { return nil }
        }

        let status: RadarAlert.SetupStatus
        if trigger != nil && (inZone || beyond) {
            status = .active
        } else if inZone {
            status = .mitigating
        } else {
            status = .waitingForPOI
        }

        // 7. Score — the context is a precondition, so only the discriminating
        //    confluences are scored.
        let ltfAlignBonus = ltfAligned ? 10 : 0
        let idmSweepBonus = grab.kind == .idm ? 15 : 0
        let liquiditySweepBonus = grab.kind == .sweep ? 10 : 0
        let equilibriumBonus = 10 // enforced by the POI filter above
        let triggerBonus = trigger != nil ? 15 : 0
        let freshZoneBonus = zone.isMitigated ? 0 : 10
        let base = 40
        let score = min(100, base + ltfAlignBonus + idmSweepBonus + liquiditySweepBonus
                        + equilibriumBonus + triggerBonus + freshZoneBonus)

        let side = isLong ? "Discount" : "Premium"
        let poiName = isLong ? "Demand" : "Supply"
        let triggerText = trigger.map { $0.kind.rawValue } ?? "Awaiting trigger"
        let rationale = "\(context.label) on \(htfLabel) · \(grab.kind.rawValue) @ \(PriceFormat.exact(grab.level)) · "
            + "\(zone.isMitigated ? "Tested" : "Fresh") \(poiName) POI in \(side) · \(triggerText) -> "
            + "\(isLong ? "LONG" : "SHORT") at \(PriceFormat.exact(entry))"

        let breakdown = RadarAlert.ConfluenceBreakdown(
            baseScore: base,
            ltfAlignBonus: ltfAlignBonus,
            idmSweepBonus: idmSweepBonus,
            liquiditySweepBonus: liquiditySweepBonus,
            equilibriumBonus: equilibriumBonus,
            triggerBonus: triggerBonus,
            freshZoneBonus: freshZoneBonus,
            htfLabel: htfLabel,
            contextEvent: context.label,
            grabKind: grab.kind.rawValue,
            grabLevel: grab.level,
            triggerKind: triggerText,
            equilibriumState: side,
            isLTFAligned: ltfAligned,
            isFreshZone: !zone.isMitigated,
            hasTrigger: trigger != nil
        )

        return Setup(
            zoneID: zone.id,
            isLong: isLong,
            status: status,
            entry: entry,
            stopLoss: stopLoss,
            takeProfit1: takeProfit1,
            takeProfit2: takeProfit2,
            zoneTop: zone.top,
            zoneBottom: zone.bottom,
            equilibrium: equilibrium,
            riskReward: rr,
            score: score,
            breakdown: breakdown,
            rationale: rationale
        )
    }

    // MARK: - Strategy primitives

    /// Index of the first candle opening at or after `date`, or the last index
    /// when the whole series predates it. Binary search — both series are
    /// stored oldest-first.
    ///
    /// This is how an HTF bar is located in LTF bar space. Multiplying the HTF
    /// index by a bar-count factor only works when both series start on the
    /// same bar, which is false for any independently loaded HTF series.
    static func firstBar(in candles: [Candle], atOrAfter date: Date) -> Int {
        guard !candles.isEmpty else { return 0 }
        var low = 0
        var high = candles.count - 1
        var found = candles.count
        while low <= high {
            let mid = (low + high) / 2
            if candles[mid].id >= date {
                found = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return min(found, candles.count - 1)
    }

    /// Confirmed BOS / CHoCH lines, oldest first.
    static func structureEvents(_ out: AlgoSmartAssist.Output) -> [AlgoSmartAssist.StructureLine] {
        out.lines
            .filter { $0.labelText == AlgoSmartAssist.Caption.bos || $0.labelText == AlgoSmartAssist.Caption.choch }
            .sorted { $0.endBar < $1.endBar }
    }

    /// A bullish SCOB closing inside a demand zone (or bearish inside supply),
    /// or a LTF CHoCH in our direction — whichever printed last after the grab.
    static func findTrigger(
        zone: AlgoSmartAssist.POIZone,
        isLong: Bool,
        grabBar: Int,
        candles: [Candle],
        ltf: AlgoSmartAssist.Output
    ) -> Trigger? {
        let wanted: AlgoSmartAssist.BarColorType = isLong ? .scobUp : .scobDn
        let scob = ltf.coloredBars
            .filter { bar in
                guard bar.colorType == wanted, bar.barIndex >= grabBar, bar.barIndex >= zone.startBar,
                      bar.barIndex < candles.count else { return false }
                let c = candles[bar.barIndex]
                return c.close >= zone.bottom && c.close <= zone.top
            }
            .max(by: { $0.barIndex < $1.barIndex })
            .map { bar -> Trigger in
                let c = candles[bar.barIndex]
                return Trigger(kind: .scob, bar: bar.barIndex, close: c.close, low: c.low, high: c.high)
            }

        let choch = structureEvents(ltf)
            .filter { $0.labelText == AlgoSmartAssist.Caption.choch && $0.isBullish == isLong
                      && $0.endBar >= grabBar && $0.endBar < candles.count }
            .max(by: { $0.endBar < $1.endBar })
            .map { line -> Trigger in
                let c = candles[line.endBar]
                return Trigger(kind: .choch, bar: line.endBar, close: c.close, low: c.low, high: c.high)
            }

        return [scob, choch].compactMap { $0 }.max(by: { $0.bar < $1.bar })
    }

    /// Major swing levels for TP2, taken from the indicator's H/L labels.
    static func majorSwings(_ out: AlgoSmartAssist.Output, isLong: Bool) -> [Double] {
        let wanted: Set<String> = isLong ? ["HH", "LH"] : ["LL", "HL"]
        return out.labels.filter { wanted.contains($0.text) }.map { $0.price }
    }

    /// The strategy's "2-5 pips/ticks beyond the zone". Ticks alone are
    /// meaningless across instruments with very different volatility, so the
    /// buffer is floored at a small fraction of ATR.
    static func stopBuffer(price: Double, atr: Double) -> Double {
        max(3 * tickSize(for: price), 0.08 * atr)
    }

    static func tickSize(for price: Double) -> Double {
        let p = abs(price)
        if p >= 100 { return 0.01 }
        if p >= 10 { return 0.001 }
        if p >= 1 { return 0.0001 }
        return 0.00001
    }

    static func atr14(_ candles: [Candle]) -> Double {
        guard candles.count > 1 else { return 1.0 }
        var trs: [Double] = []
        trs.reserveCapacity(candles.count - 1)
        for i in 1..<candles.count {
            let h = candles[i].high, l = candles[i].low, pc = candles[i - 1].close
            trs.append(max(h - l, abs(h - pc), abs(l - pc)))
        }
        let tail = trs.suffix(14)
        guard !tail.isEmpty else { return 1.0 }
        return tail.reduce(0, +) / Double(tail.count)
    }
}

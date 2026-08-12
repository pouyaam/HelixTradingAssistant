import Foundation

/// The Smart-Money evidence pack: one deterministic snapshot of what the
/// Ranked-OB, ALGOSMART ASSIST and Previous-Day engines currently see on a
/// symbol, plus the derived facts an SMC read actually turns on (premium vs
/// discount, distance-to-zone in ATR, which zones agree with each other, where
/// the unswept liquidity sits).
///
/// It exists because two very different consumers need the *same* numbers:
///
///   • `AnalysisKind.smcDesk` renders it as markdown into the AI prompt, so the
///     model ranks and narrates pre-computed structure instead of trying to
///     re-derive order blocks from an OHLC table (which it does badly).
///   • The local MCP server hands it to other AI tools as JSON.
///
/// If those two ever disagreed the app and the MCP clients would be analysing
/// different charts, so the assembly lives here once and neither consumer is
/// allowed its own copy.
///
/// Everything is `Codable` and pure — no main-actor hop, no chart state, no
/// `ChartDerivedCache`. Callers hand in candles and get a value back.
struct SMCEvidence: Codable, Equatable {

    // MARK: - Payload

    struct Meta: Codable, Equatable {
        let pairID: String
        let symbol: String
        let timeframe: String
        let barCount: Int
        let firstBarAt: Date?
        let lastBarAt: Date?
        let lastClose: Double
        /// Wilder ATR(14) on this series — the unit every distance below is
        /// quoted in, so "1.8 ATR away" means the same thing on gold and BTC.
        let atr14: Double?
    }

    /// A graded swing order block from `RankedOrderBlocks`.
    struct RankedZone: Codable, Equatable {
        let grade: String        // "A" | "B" | "C" | "–"
        let score: Int
        let maxScore: Int
        let direction: String    // "bullish" | "bearish"
        let top: Double
        let bottom: Double
        let mid: Double
        /// Bars between the order-block candle and the latest bar.
        let barsAgo: Int
        let isBreaker: Bool
        let isCombined: Bool
        /// Where spot sits relative to the zone: "inside" | "above" | "below".
        let priceLocation: String
        /// Distance from spot to the nearest zone edge, in ATR units. 0 when
        /// price is inside the zone.
        let distanceATR: Double?
        /// The price range of an ALGOSMART POI of the same direction that
        /// overlaps this zone, or nil for none — two independent engines
        /// marking the same price is the single strongest confluence in
        /// this pack.
        ///
        /// The bounds are carried rather than a bare flag because the POI
        /// list is truncated for the prompt while this check runs against
        /// every POI: a reader that can't see the zone being cited has no
        /// way to verify the claim, and inventing numbers to fill the gap
        /// is exactly the failure this pack exists to prevent.
        let poiOverlap: PriceRange?

        /// Convenience for callers that only care whether there is one.
        var agreesWithPOI: Bool { poiOverlap != nil }
    }

    /// A price band, used where a range needs to travel with a zone.
    struct PriceRange: Codable, Equatable {
        let bottom: Double
        let top: Double
    }

    /// A confirmed market-structure event from ALGOSMART ASSIST.
    struct StructureEvent: Codable, Equatable {
        /// "BOS" | "CHoCH" | "IDM" | "Sweep"
        let kind: String
        let direction: String    // "bullish" | "bearish"
        let price: Double
        let barsAgo: Int
    }

    /// An ALGOSMART point-of-interest zone.
    struct POIZone: Codable, Equatable {
        let direction: String    // "supply" | "demand"
        let top: Double
        let bottom: Double
        let mid: Double
        let barsAgo: Int
        let isMitigated: Bool
        /// "premium" | "discount" | "unknown" — which side of the current
        /// structural leg's 0.5 the zone sits on.
        let side: String
    }

    /// A live (right-edge-anchored) level: the working BOS / CHoCH / IDM
    /// levels and the 0.5 equilibrium of the current leg.
    struct LiveLevel: Codable, Equatable {
        let label: String
        let price: Double
        let direction: String
        /// Distance from spot in ATR units.
        let distanceATR: Double?
    }

    /// Previous-day high/low plus that session's volume profile.
    struct PreviousDay: Codable, Equatable {
        let high: Double
        let low: Double
        let mid: Double
        let open: Double
        let close: Double
        let poc: Double
        let vah: Double
        let val: Double
        let range: Double
        /// False when the session had no volume data — the profile is
        /// time-at-price (TPO), so POC/VA are weaker evidence.
        let hasRealVolume: Bool
        /// Where spot sits: "above PDH" | "inside value" | "inside range,
        /// above value" | "inside range, below value" | "below PDL".
        let priceLocation: String
        /// PDH/PDL still untouched by the session in progress — the obvious
        /// draw-on-liquidity targets. Empty when both have been taken.
        let unsweptLevels: [String]
        let bucketCount: Int
    }

    /// The `SMCSentinelEngine` read — the codebase's own rules engine over the
    /// same indicator, included so the model can agree or disagree with a
    /// stated mechanical opinion rather than inventing one unanchored.
    struct SentinelRead: Codable, Equatable {
        let context: String          // "Bullish CHoCH" / "—"
        let htfLabel: String
        let equilibrium: Double?
        let equilibriumState: String // "premium" | "discount" | "unknown"
        /// Why no setup qualified, when none did.
        let blocker: String
        let setups: [Setup]

        struct Setup: Codable, Equatable {
            let direction: String    // "long" | "short"
            let status: String
            let entry: Double
            let stopLoss: Double
            let takeProfit1: Double
            let takeProfit2: Double
            let zoneTop: Double
            let zoneBottom: Double
            let riskReward: Double
            let score: Int
            let rationale: String
        }
    }

    let meta: Meta
    let rankedZones: [RankedZone]
    let structureEvents: [StructureEvent]
    let poiZones: [POIZone]
    let liveLevels: [LiveLevel]
    let previousDay: PreviousDay?
    let sentinel: SentinelRead?
    /// Engines that produced nothing and why — an empty section in the prompt
    /// is ambiguous ("no zones" vs "not enough bars"), and a model that can't
    /// tell the difference will confidently analyse a blank chart.
    let gaps: [String]

    // MARK: - Options

    struct Options: Equatable {
        /// Ranked-OB zones surfaced per side, newest first.
        var zonesPerSide: Int = 3
        /// Confirmed structure events surfaced, newest last.
        var structureEvents: Int = 6
        /// POI zones surfaced per side.
        var poiPerSide: Int = 3
        var previousDayBuckets: Int = 24
        var previousDayValueAreaPct: Double = 70.0
        /// Run the sentinel pass. Off for the lighter MCP calls.
        var includeSentinel: Bool = true
        var rankedOB: RankedOrderBlocks.Config = .init()
        /// ALGOSMART parameters. Defaults to the sentinel's set, which turns
        /// on the captions this pack reads (`markX` for sweeps, `showHL` for
        /// the major swings).
        var algoSmartParams: [String: ParamValue] = SMCSentinelEngine.indicatorParams

        static let `default` = Options()
    }

    // MARK: - Assembly

    /// Build the pack from a candle series.
    ///
    /// - Parameters:
    ///   - htfCandles: higher-timeframe series for the sentinel's context
    ///     rule. Pass empty to let it fall back to the LTF read. Matched to
    ///     `candles` by date, so it need not start on the same bar.
    static func build(
        pairID: String,
        symbol: String,
        timeframe: Timeframe,
        candles: [Candle],
        htfCandles: [Candle] = [],
        htfLabel: String = "",
        options: Options = .default
    ) -> SMCEvidence {
        var gaps: [String] = []
        let lastIndex = candles.count - 1
        let spot = candles.last?.close ?? 0
        let atr = wilderATR(candles, period: 14)

        let meta = Meta(
            pairID: pairID,
            symbol: symbol,
            timeframe: timeframe.rawValue,
            barCount: candles.count,
            firstBarAt: candles.first?.bucketStart,
            lastBarAt: candles.last?.bucketStart,
            lastClose: spot,
            atr14: atr
        )

        guard candles.count >= 20 else {
            return SMCEvidence(
                meta: meta, rankedZones: [], structureEvents: [], poiZones: [],
                liveLevels: [], previousDay: nil, sentinel: nil,
                gaps: ["Only \(candles.count) bars loaded — every SMC engine needs at least 20."]
            )
        }

        // ── ALGOSMART ASSIST ───────────────────────────────────────────
        let algo = candles.count >= 5
            ? AlgoSmartAssist.calculate(candles: candles, params: options.algoSmartParams)
            : .empty

        // The 0.5 line of the current structural leg. Everything premium /
        // discount downstream keys off it, so it's resolved before the zones.
        let equilibrium = algo.liveLines.first(where: { $0.id == "live-mid" })?.price

        let poiZones = buildPOIZones(
            algo.zones,
            equilibrium: equilibrium,
            lastIndex: lastIndex,
            perSide: options.poiPerSide
        )
        if poiZones.isEmpty { gaps.append("ALGOSMART found no POI zones on this window.") }

        let structureEvents = buildStructureEvents(
            algo.lines,
            lastIndex: lastIndex,
            limit: options.structureEvents
        )
        if structureEvents.isEmpty { gaps.append("No confirmed BOS / CHoCH / IDM / sweep on this window.") }

        let liveLevels = algo.liveLines.map { line in
            LiveLevel(
                label: line.text,
                price: line.price,
                direction: line.isBullish ? "bullish" : "bearish",
                distanceATR: atrDistance(from: spot, to: line.price, atr: atr)
            )
        }

        // ── Ranked Order Blocks ────────────────────────────────────────
        var obConfig = options.rankedOB
        obConfig.zonesPerSide = options.zonesPerSide
        let zones = RankedOrderBlocks.compute(candles, config: obConfig)
        let rankedZones = buildRankedZones(
            zones,
            poi: algo.zones,
            spot: spot,
            atr: atr,
            lastIndex: lastIndex
        )
        if rankedZones.isEmpty { gaps.append("Ranked OB detected no live zones on this window.") }

        // ── Previous day ───────────────────────────────────────────────
        let pdVP = VolumeProfile.computePreviousDay(
            candles,
            bucketCount: options.previousDayBuckets,
            valueAreaPct: options.previousDayValueAreaPct
        )
        let previousDay = pdVP.map { vp in
            buildPreviousDay(vp, candles: candles, spot: spot, bucketCount: options.previousDayBuckets)
        }
        if previousDay == nil {
            gaps.append("No previous-day profile — the series doesn't span two complete 18:00-ET sessions.")
        }

        // ── Sentinel ───────────────────────────────────────────────────
        var sentinel: SentinelRead? = nil
        if options.includeSentinel {
            let scan = SMCSentinelEngine.scan(
                candles: candles,
                htfCandles: htfCandles,
                htfLabel: htfLabel
            )
            sentinel = buildSentinelRead(scan, htfLabel: htfLabel, spot: spot)
        }

        return SMCEvidence(
            meta: meta,
            rankedZones: rankedZones,
            structureEvents: structureEvents,
            poiZones: poiZones,
            liveLevels: liveLevels,
            previousDay: previousDay,
            sentinel: sentinel,
            gaps: gaps
        )
    }

    // MARK: - Section builders

    private static func buildRankedZones(
        _ zones: [RankedOrderBlocks.Zone],
        poi: [AlgoSmartAssist.POIZone],
        spot: Double,
        atr: Double?,
        lastIndex: Int
    ) -> [RankedZone] {
        zones.map { z in
            let location: String
            if spot >= z.bottom && spot <= z.top { location = "inside" }
            else if spot > z.top                 { location = "above" }
            else                                 { location = "below" }

            let edge = spot > z.top ? z.top : (spot < z.bottom ? z.bottom : spot)

            // A ranked OB and an ALGOSMART POI marking the same prices is the
            // strongest single confluence available here — two engines with
            // unrelated detection rules landing on one zone.
            // Where several POIs overlap, cite the one sharing the most
            // price with the zone — the closest thing to "the same zone".
            let overlap = poi
                .filter { p in
                    let sameSide = (p.isSupply == false) == z.isBullish
                    return sameSide && p.bottom <= z.top && p.top >= z.bottom
                }
                .max { a, b in
                    let shared = { (p: AlgoSmartAssist.POIZone) in
                        min(p.top, z.top) - max(p.bottom, z.bottom)
                    }
                    return shared(a) < shared(b)
                }
                .map { PriceRange(bottom: $0.bottom, top: $0.top) }

            return RankedZone(
                grade: z.grade.rawValue,
                score: z.score,
                maxScore: z.maxScore,
                direction: z.isBullish ? "bullish" : "bearish",
                top: z.top,
                bottom: z.bottom,
                mid: (z.top + z.bottom) / 2,
                barsAgo: max(0, lastIndex - z.startIndex),
                isBreaker: z.isBreaker,
                isCombined: z.isCombined,
                priceLocation: location,
                distanceATR: location == "inside" ? 0 : atrDistance(from: spot, to: edge, atr: atr),
                poiOverlap: overlap
            )
        }
        .sorted { lhs, rhs in
            // Nearest-first: the zone price has to travel least to reach is
            // the one an entry gets planned against.
            (lhs.distanceATR ?? .greatestFiniteMagnitude) < (rhs.distanceATR ?? .greatestFiniteMagnitude)
        }
    }

    private static func buildStructureEvents(
        _ lines: [AlgoSmartAssist.StructureLine],
        lastIndex: Int,
        limit: Int
    ) -> [StructureEvent] {
        let mapped: [StructureEvent] = lines.compactMap { line in
            let kind: String
            switch line.labelText {
            case AlgoSmartAssist.Caption.bos:   kind = "BOS"
            case AlgoSmartAssist.Caption.choch: kind = "CHoCH"
            case AlgoSmartAssist.Caption.idm:   kind = "IDM"
            case AlgoSmartAssist.Caption.sweep: kind = "Sweep"
            default: return nil
            }
            return StructureEvent(
                kind: kind,
                direction: line.isBullish ? "bullish" : "bearish",
                price: line.price,
                barsAgo: max(0, lastIndex - line.endBar)
            )
        }
        // Newest last so the section reads as a chronological narrative.
        return Array(mapped.sorted { $0.barsAgo > $1.barsAgo }.suffix(limit))
    }

    private static func buildPOIZones(
        _ zones: [AlgoSmartAssist.POIZone],
        equilibrium: Double?,
        lastIndex: Int,
        perSide: Int
    ) -> [POIZone] {
        func map(_ z: AlgoSmartAssist.POIZone) -> POIZone {
            let mid = (z.top + z.bottom) / 2
            let side: String
            if let eq = equilibrium { side = mid >= eq ? "premium" : "discount" }
            else                    { side = "unknown" }
            return POIZone(
                direction: z.isSupply ? "supply" : "demand",
                top: z.top,
                bottom: z.bottom,
                mid: mid,
                barsAgo: max(0, lastIndex - z.startBar),
                isMitigated: z.isMitigated,
                side: side
            )
        }
        let supply = zones.filter { $0.isSupply }.sorted { $0.startBar > $1.startBar }.prefix(perSide)
        let demand = zones.filter { !$0.isSupply }.sorted { $0.startBar > $1.startBar }.prefix(perSide)
        return (supply.map(map) + demand.map(map)).sorted { $0.barsAgo < $1.barsAgo }
    }

    private static func buildPreviousDay(
        _ vp: VolumeProfile.PreviousDayVP,
        candles: [Candle],
        spot: Double,
        bucketCount: Int
    ) -> PreviousDay {
        let location: String
        if spot > vp.high                         { location = "above PDH" }
        else if spot < vp.low                     { location = "below PDL" }
        else if spot >= vp.val && spot <= vp.vah  { location = "inside value" }
        else if spot > vp.vah                     { location = "inside range, above value" }
        else                                      { location = "inside range, below value" }

        // Which of PDH / PDL the session in progress hasn't reached yet.
        // Untouched previous-day extremes are the liquidity price is most
        // likely drawn to, so they are worth stating explicitly rather than
        // leaving the model to compare highs itself.
        var unswept: [String] = []
        let todayBars = candles[(vp.endBar + 1)...]
        if !todayBars.isEmpty {
            if !todayBars.contains(where: { $0.high >= vp.high }) { unswept.append("PDH") }
            if !todayBars.contains(where: { $0.low  <= vp.low  }) { unswept.append("PDL") }
        }

        return PreviousDay(
            high: vp.high,
            low: vp.low,
            mid: vp.mid,
            open: vp.open,
            close: vp.close,
            poc: vp.poc,
            vah: vp.vah,
            val: vp.val,
            range: vp.high - vp.low,
            hasRealVolume: vp.hasRealVolume,
            priceLocation: location,
            unsweptLevels: unswept,
            bucketCount: bucketCount
        )
    }

    private static func buildSentinelRead(
        _ scan: SMCSentinelEngine.ScanResult,
        htfLabel: String,
        spot: Double
    ) -> SentinelRead {
        let eqState: String
        if let eq = scan.equilibrium { eqState = spot >= eq ? "premium" : "discount" }
        else                         { eqState = "unknown" }

        return SentinelRead(
            context: scan.context?.label ?? "—",
            htfLabel: htfLabel.isEmpty ? "—" : htfLabel,
            equilibrium: scan.equilibrium,
            equilibriumState: eqState,
            blocker: scan.blocker.rawValue,
            setups: scan.setups.map { s in
                SentinelRead.Setup(
                    direction: s.isLong ? "long" : "short",
                    status: s.status.rawValue,
                    entry: s.entry,
                    stopLoss: s.stopLoss,
                    takeProfit1: s.takeProfit1,
                    takeProfit2: s.takeProfit2,
                    zoneTop: s.zoneTop,
                    zoneBottom: s.zoneBottom,
                    riskReward: s.riskReward,
                    score: s.score,
                    rationale: s.rationale
                )
            }
        )
    }

    // MARK: - Helpers

    private static func atrDistance(from spot: Double, to level: Double, atr: Double?) -> Double? {
        guard let atr, atr > 0 else { return nil }
        return abs(spot - level) / atr
    }

    /// Wilder's ATR — same formula `MarketSnapshot` uses. Duplicated rather
    /// than exposed from there because that one is `private` and this file is
    /// deliberately free of dependencies on prompt-layer types.
    static func wilderATR(_ candles: [Candle], period: Int) -> Double? {
        guard period > 0, candles.count >= period else { return nil }
        let n = candles.count
        var trs = [Double](repeating: 0, count: n)
        trs[0] = candles[0].high - candles[0].low
        for i in 1..<n {
            let c = candles[i]
            let prevClose = candles[i - 1].close
            trs[i] = max(c.high - c.low, abs(c.high - prevClose), abs(c.low - prevClose))
        }
        var value = trs[0..<period].reduce(0, +) / Double(period)
        let p = Double(period)
        for i in period..<n {
            value = (value * (p - 1) + trs[i]) / p
        }
        return value
    }
}

// MARK: - Markdown rendering

extension SMCEvidence {

    /// Render the pack as the evidence section of an AI prompt.
    ///
    /// Deliberately dense: every line is a fact the model would otherwise have
    /// to derive from the OHLC table, and each carries its own units so no
    /// cross-referencing is needed to read one.
    func markdown() -> String {
        var out: [String] = []

        out.append("### Market structure — ALGOSMART ASSIST v2 (\(meta.timeframe))")
        if let sentinel {
            out.append("")
            out.append("- **HTF context:** \(sentinel.context)\(sentinel.htfLabel == "—" ? "" : " on \(sentinel.htfLabel)")")
            if let eq = sentinel.equilibrium {
                out.append("- **Equilibrium (0.5 of current leg):** \(fmt(eq)) — price is in **\(sentinel.equilibriumState)**")
            }
            if !sentinel.blocker.isEmpty {
                out.append("- **Mechanical rules currently blocked by:** \(sentinel.blocker)")
            }
        }

        if !structureEvents.isEmpty {
            out.append("")
            out.append("Confirmed events (oldest → newest):")
            out.append("")
            for e in structureEvents {
                out.append("- **\(e.kind)** \(e.direction) @ \(fmt(e.price)) — \(barsAgoLabel(e.barsAgo))")
            }
        }

        if !liveLevels.isEmpty {
            out.append("")
            out.append("Live levels (working structure, anchored to the right edge):")
            out.append("")
            for l in liveLevels {
                out.append("- **\(l.label)** \(fmt(l.price))\(atrSuffix(l.distanceATR))")
            }
        }

        if !poiZones.isEmpty {
            out.append("")
            out.append("POI zones:")
            out.append("")
            for z in poiZones {
                let state = z.isMitigated ? "mitigated" : "fresh"
                out.append("- **\(z.direction)** \(fmt(z.bottom))–\(fmt(z.top)) (mid \(fmt(z.mid))) — \(state), \(z.side), \(barsAgoLabel(z.barsAgo))")
            }
        }

        // ── Ranked OB ──────────────────────────────────────────────────
        out.append("")
        out.append("### Ranked Order Blocks — graded on Volume Profile + Ichimoku confluence")
        if rankedZones.isEmpty {
            out.append("")
            out.append("_No live zones._")
        } else {
            out.append("")
            out.append("Nearest first. Grade A ≥70% of the confluence score, B ≥40%, C below.")
            out.append("")
            for z in rankedZones {
                var parts = ["**\(z.grade) \(z.score)/\(z.maxScore)** \(z.direction)"]
                parts.append("\(fmt(z.bottom))–\(fmt(z.top)) (mid \(fmt(z.mid)))")
                parts.append(z.priceLocation == "inside"
                             ? "price is **inside this zone**"
                             : "price \(z.priceLocation)\(atrSuffix(z.distanceATR, prefix: ", "))")
                if z.isBreaker  { parts.append("**breaker** (already traded through — flipped role)") }
                if z.isCombined { parts.append("merged zone") }
                if let poi = z.poiOverlap {
                    parts.append("**overlaps ALGOSMART POI \(fmt(poi.bottom))–\(fmt(poi.top))**")
                }
                parts.append(barsAgoLabel(z.barsAgo))
                out.append("- " + parts.joined(separator: " · "))
            }
        }

        // ── Previous day ───────────────────────────────────────────────
        out.append("")
        out.append("### Previous day — PDH / PDL + settled-session volume profile")
        if let pd = previousDay {
            out.append("")
            out.append("- **PDH:** \(fmt(pd.high))   **PDL:** \(fmt(pd.low))   **mid (50%):** \(fmt(pd.mid))")
            out.append("- **Open:** \(fmt(pd.open))   **Close:** \(fmt(pd.close))   **range:** \(fmt(pd.range))")
            out.append("- **POC:** \(fmt(pd.poc))   **VAH:** \(fmt(pd.vah))   **VAL:** \(fmt(pd.val))\(pd.hasRealVolume ? "" : " _(time-at-price — this session reported no volume, so treat POC/VA as weaker evidence)_")")
            out.append("- **Spot vs previous day:** \(pd.priceLocation)")
            if pd.unsweptLevels.isEmpty {
                out.append("- **Liquidity:** both PDH and PDL have been taken this session.")
            } else {
                out.append("- **Unswept liquidity:** \(pd.unsweptLevels.joined(separator: " and ")) still untouched this session.")
            }
        } else {
            out.append("")
            out.append("_Not available — the loaded series doesn't span two complete sessions._")
        }

        // ── Sentinel setups ────────────────────────────────────────────
        if let sentinel, !sentinel.setups.isEmpty {
            out.append("")
            out.append("### Mechanical setups already qualified by the app's SMC rules engine")
            out.append("")
            out.append("These passed context → liquidity grab → POI in discount/premium → trigger. Treat them as a baseline to agree with, sharpen, or reject with a reason — not as a conclusion.")
            out.append("")
            for s in sentinel.setups {
                out.append("- **\(s.direction.uppercased()) \(s.status)** (score \(s.score)) — entry \(fmt(s.entry)), SL \(fmt(s.stopLoss)), TP1 \(fmt(s.takeProfit1)), TP2 \(fmt(s.takeProfit2)), R:R \(String(format: "%.2f", s.riskReward)). Zone \(fmt(s.zoneBottom))–\(fmt(s.zoneTop)). \(s.rationale)")
            }
        }

        if !gaps.isEmpty {
            out.append("")
            out.append("### Data gaps — do not analyse around these silently")
            out.append("")
            for g in gaps { out.append("- \(g)") }
        }

        return out.joined(separator: "\n")
    }

    /// One-line summary for the higher-timeframe context block.
    func oneLineSummary() -> String {
        var parts: [String] = []
        if let s = sentinel { parts.append("**\(s.context)**, price in \(s.equilibriumState)") }
        if let pd = previousDay {
            parts.append("PDH \(fmt(pd.high)) / PDL \(fmt(pd.low)) / POC \(fmt(pd.poc)) — \(pd.priceLocation)")
        }
        if let nearest = rankedZones.first {
            parts.append("nearest OB \(nearest.grade) \(nearest.direction) \(fmt(nearest.bottom))–\(fmt(nearest.top))")
        }
        return parts.isEmpty ? "no structure resolved" : parts.joined(separator: " · ")
    }

    // MARK: - Formatting

    private func barsAgoLabel(_ n: Int) -> String {
        n == 0 ? "current bar" : "\(n) bar\(n == 1 ? "" : "s") ago"
    }

    private func atrSuffix(_ atr: Double?, prefix: String = " — ") -> String {
        guard let atr else { return "" }
        return "\(prefix)\(String(format: "%.1f", atr)) ATR away"
    }

    /// Match the price rounding the rest of the prompt layer uses.
    private func fmt(_ v: Double) -> String {
        if v >= 10_000 { return String(format: "%.0f", v) }
        if v >= 100    { return String(format: "%.2f", v) }
        if v >= 1      { return String(format: "%.4f", v) }
        return String(format: "%.5f", v)
    }
}

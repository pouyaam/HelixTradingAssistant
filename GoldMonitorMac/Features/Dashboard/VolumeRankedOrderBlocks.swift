import Foundation

/// Volume-Ranked Order Blocks — swing-structure order blocks graded strictly by
/// Volume Profile + Volumetric Impulse / RVOL confluence (no Ichimoku).
///
/// Ported & enhanced for Helix Trading Assistant:
///   1. **Detection (swing engine).** Identifies order blocks created when price breaks
///      a protected swing pivot.
///   2. **Volumetric Validation.** Measures candle volume relative to its 20-period SMA,
///      scoring impulse strength and buying/selling pressure.
///   3. **Volume Profile Confluence.** Builds a local Volume Profile over the lookback window,
///      scoring whether the zone sits on a High Volume Node (HVN) or Value Area level.
///   4. **Lifecycle & Breakers.** Tracks retests, invalidation, and zone merging.
///
/// Pure-function, state-free calculation.
enum VolumeRankedOrderBlocks {

    enum ZoneSource: String, Codable, Hashable {
        case wicks
        case body
    }

    enum Invalidation: String, Codable, Hashable {
        case wick
        case close
    }

    enum Grade: String, Codable, Hashable {
        case a = "A"
        case b = "B"
        case c = "C"
        case unranked = "–"
    }

    struct Config: Equatable {
        var swingLength: Int = 10
        var zoneSource: ZoneSource = .wicks
        var maxATRMult: Double = 3.5
        var atrLength: Int = 10
        var invalidation: Invalidation = .wick
        var zonesPerSide: Int = 3
        var maxStored: Int = 30
        var showBreakers: Bool = true
        var combineOverlapping: Bool = true
        var mergeThreshold: Double = 0.0

        var minVolumeMultiplier: Double = 1.2
        var useVolumeProfile: Bool = true
        var vpLookback: Int = 200
        var vpRows: Int = 24

        var processingWindow: Int = 1750
    }

    /// One Volume-Ranked Order Block zone.
    struct Zone: Identifiable, Hashable {
        let startIndex: Int
        let endIndex: Int
        let confirmIndex: Int
        let top: Double
        let bottom: Double
        let isBullish: Bool
        let isBreaker: Bool
        let isCombined: Bool
        let grade: Grade
        let score: Int
        let maxScore: Int
        let rvol: Double
        let atr: Double

        var id: String {
            "vrob-\(startIndex)-\(endIndex)-\(isBullish ? "bull" : "bear")-\(isCombined ? "m" : "s")"
        }

        var badge: String {
            grade == .unranked ? "VOL OB" : "VOL \(grade.rawValue) \(score)/\(maxScore)"
        }
    }

    private struct WorkingZone {
        var top: Double
        var bottom: Double
        var isBullish: Bool
        var startIndex: Int
        var confirmIndex: Int
        var atr: Double
        var rvol: Double
        var isBreaker: Bool = false
        var breakIndex: Int? = nil
        var isCombined: Bool = false
        var score: Int = 0
        var maxScore: Int = 0
    }

    static func compute(_ candles: [Candle], config cfg: Config) -> [Zone] {
        let n = candles.count
        guard n >= (cfg.swingLength * 2 + 1), cfg.swingLength >= 2 else { return [] }

        let atr = wilderATR(candles, period: max(1, cfg.atrLength))
        let volSMA = volumeSMA(candles, period: 20)

        let maxP: [Double] = candles.map { cfg.zoneSource == .body ? max($0.open, $0.close) : $0.high }
        let minP: [Double] = candles.map { cfg.zoneSource == .body ? min($0.open, $0.close) : $0.low }

        let startBar = max(cfg.swingLength * 2, n - cfg.processingWindow)

        var bullZones: [WorkingZone] = []
        var bearZones: [WorkingZone] = []

        var phBar: Int? = nil
        var phVal: Double? = nil
        var plBar: Int? = nil
        var plVal: Double? = nil

        for i in startBar..<n {
            let curClose = candles[i].close
            let curHigh  = candles[i].high
            let curLow   = candles[i].low

            // Check if protected high was broken (BOS Bullish)
            if let hBar = phBar, let hVal = phVal, curClose > hVal, hBar >= 0 && hBar < n {
                var obIndex = i
                var obLow = minP[i]
                let validHBar = max(0, min(n - 1, hBar))
                let startJ = max(0, min(n - 1, i))
                if startJ >= validHBar {
                    for j in stride(from: startJ, through: validHBar, by: -1) {
                        if minP[j] <= obLow {
                            obLow = minP[j]
                            obIndex = j
                        }
                    }
                }
                let zTop = maxP[obIndex]
                let zBot = minP[obIndex]
                let zATR = atr[confirmIdx(obIndex, count: n)]
                if (zTop - zBot) <= cfg.maxATRMult * zATR {
                    let cVol = candles[obIndex].volume ?? 0
                    let avgV = volSMA[obIndex]
                    let rvolVal = avgV > 0 ? cVol / avgV : 1.0

                    let wz = WorkingZone(
                        top: zTop, bottom: zBot, isBullish: true,
                        startIndex: obIndex, confirmIndex: i, atr: zATR, rvol: rvolVal
                    )
                    bullZones.append(wz)
                    if bullZones.count > cfg.maxStored { bullZones.removeFirst() }
                }
                phBar = nil
                phVal = nil
            }

            // Check if protected low was broken (BOS Bearish)
            if let lBar = plBar, let lVal = plVal, curClose < lVal, lBar >= 0 && lBar < n {
                var obIndex = i
                var obHigh = maxP[i]
                let validLBar = max(0, min(n - 1, lBar))
                let startJ = max(0, min(n - 1, i))
                if startJ >= validLBar {
                    for j in stride(from: startJ, through: validLBar, by: -1) {
                        if maxP[j] >= obHigh {
                            obHigh = maxP[j]
                            obIndex = j
                        }
                    }
                }
                let zTop = maxP[obIndex]
                let zBot = minP[obIndex]
                let zATR = atr[confirmIdx(obIndex, count: n)]
                if (zTop - zBot) <= cfg.maxATRMult * zATR {
                    let cVol = candles[obIndex].volume ?? 0
                    let avgV = volSMA[obIndex]
                    let rvolVal = avgV > 0 ? cVol / avgV : 1.0

                    let wz = WorkingZone(
                        top: zTop, bottom: zBot, isBullish: false,
                        startIndex: obIndex, confirmIndex: i, atr: zATR, rvol: rvolVal
                    )
                    bearZones.append(wz)
                    if bearZones.count > cfg.maxStored { bearZones.removeFirst() }
                }
                plBar = nil
                plVal = nil
            }

            // Detect new pivots confirmed at `i`
            let pIdx = i - cfg.swingLength
            if pIdx >= cfg.swingLength && pIdx < n {
                let candidateHigh = candles[pIdx].high
                let candidateLow  = candles[pIdx].low
                var isHigh = true
                var isLow  = true

                let checkStart = max(0, pIdx - cfg.swingLength)
                let checkEnd = min(n - 1, i)
                if checkStart <= checkEnd {
                    for k in checkStart...checkEnd {
                        if k == pIdx { continue }
                        if candles[k].high >= candidateHigh { isHigh = false }
                        if candles[k].low  <= candidateLow  { isLow  = false }
                    }
                    if isHigh { phBar = pIdx; phVal = candidateHigh }
                    if isLow  { plBar = pIdx; plVal = candidateLow }
                }
            }

            // Invalidation & Breakers tracking
            updateLifecycle(&bullZones, curHigh: curHigh, curLow: curLow, curClose: curClose, index: i, cfg: cfg)
            updateLifecycle(&bearZones, curHigh: curHigh, curLow: curLow, curClose: curClose, index: i, cfg: cfg)
        }

        // Merge overlapping zones if enabled
        if cfg.combineOverlapping {
            bullZones = combineOverlapping(bullZones, cfg: cfg)
            bearZones = combineOverlapping(bearZones, cfg: cfg)
        }

        // Build Volume Profile for ranking
        let vpProfile = cfg.useVolumeProfile ? buildVolumeProfile(candles, cfg: cfg) : nil

        // Rank zones based on Volume & Volume Profile
        rankZones(&bullZones, candles: candles, vp: vpProfile, cfg: cfg)
        rankZones(&bearZones, candles: candles, vp: vpProfile, cfg: cfg)

        // Select fresh zones
        let renderBull = selectRenderSet(bullZones, limit: cfg.zonesPerSide, showBreakers: cfg.showBreakers)
        let renderBear = selectRenderSet(bearZones, limit: cfg.zonesPerSide, showBreakers: cfg.showBreakers)

        let finalZones = (renderBull + renderBear).map { wz in
            Zone(
                startIndex: wz.startIndex,
                endIndex: wz.breakIndex ?? (n - 1),
                confirmIndex: wz.confirmIndex,
                top: wz.top,
                bottom: wz.bottom,
                isBullish: wz.isBullish,
                isBreaker: wz.isBreaker,
                isCombined: wz.isCombined,
                grade: gradeFor(score: wz.score, maxScore: wz.maxScore),
                score: wz.score,
                maxScore: wz.maxScore,
                rvol: wz.rvol,
                atr: wz.atr
            )
        }

        return finalZones
    }

    // MARK: - Ranking & Scoring

    private static func rankZones(
        _ zones: inout [WorkingZone],
        candles: [Candle],
        vp: [Double: Double]?,
        cfg: Config
    ) {
        for i in 0..<zones.count {
            var score = 0
            var maxScore = 0

            // 1. Volumetric Score (0 – 2)
            maxScore += 2
            if zones[i].rvol >= 2.0 {
                score += 2
            } else if zones[i].rvol >= 1.2 {
                score += 1
            }

            // 2. Volume Profile Overlap Score (0 – 2)
            if cfg.useVolumeProfile, let profile = vp, !profile.isEmpty {
                maxScore += 2
                let top = zones[i].top
                let bot = zones[i].bottom
                let maxV = profile.values.max() ?? 1.0

                var maxLocalVol = 0.0
                for (price, vol) in profile {
                    if price >= bot && price <= top {
                        if vol > maxLocalVol { maxLocalVol = vol }
                    }
                }

                let ratio = maxLocalVol / maxV
                if ratio >= 0.6 {
                    score += 2 // High Volume Node
                } else if ratio >= 0.3 {
                    score += 1 // Moderate Volume
                }
            }

            zones[i].score = score
            zones[i].maxScore = maxScore
        }
    }

    private static func gradeFor(score: Int, maxScore: Int) -> Grade {
        guard maxScore > 0 else { return .unranked }
        let pct = Double(score) / Double(maxScore)
        if pct >= 0.70 { return .a }
        if pct >= 0.40 { return .b }
        return .c
    }

    // MARK: - Helpers

    private static func confirmIdx(_ idx: Int, count: Int) -> Int {
        min(max(0, idx), count - 1)
    }

    private static func updateLifecycle(
        _ zones: inout [WorkingZone],
        curHigh: Double, curLow: Double, curClose: Double,
        index: Int, cfg: Config
    ) {
        var keep: [WorkingZone] = []
        for var z in zones {
            if index < z.confirmIndex {
                keep.append(z)
                continue
            }
            if !z.isBreaker {
                let invalid = z.isBullish
                    ? (cfg.invalidation == .close ? curClose < z.bottom : curLow < z.bottom)
                    : (cfg.invalidation == .close ? curClose > z.top : curHigh > z.top)
                if invalid {
                    z.isBreaker = true
                    z.breakIndex = index
                }
                keep.append(z)
            } else {
                let dead = z.isBullish
                    ? (cfg.invalidation == .close ? curClose < z.bottom - z.atr : curLow < z.bottom - z.atr)
                    : (cfg.invalidation == .close ? curClose > z.top + z.atr : curHigh > z.top + z.atr)
                if !dead {
                    keep.append(z)
                }
            }
        }
        zones = keep
    }

    private static func combineOverlapping(_ zones: [WorkingZone], cfg: Config) -> [WorkingZone] {
        guard zones.count > 1 else { return zones }
        var result: [WorkingZone] = []

        for z in zones {
            if let idx = result.firstIndex(where: { $0.isBullish == z.isBullish && $0.isBreaker == z.isBreaker && rangesOverlap($0, z) }) {
                result[idx].top = max(result[idx].top, z.top)
                result[idx].bottom = min(result[idx].bottom, z.bottom)
                result[idx].isCombined = true
                result[idx].rvol = max(result[idx].rvol, z.rvol)
            } else {
                result.append(z)
            }
        }
        return result
    }

    private static func rangesOverlap(_ a: WorkingZone, _ b: WorkingZone) -> Bool {
        a.bottom <= b.top && b.bottom <= a.top
    }

    private static func selectRenderSet(_ zones: [WorkingZone], limit: Int, showBreakers: Bool) -> [WorkingZone] {
        let active = zones.filter { !$0.isBreaker }.suffix(limit)
        if showBreakers {
            let breakers = zones.filter { $0.isBreaker }.suffix(limit)
            return Array(active + breakers)
        }
        return Array(active)
    }

    private static func buildVolumeProfile(_ candles: [Candle], cfg: Config) -> [Double: Double] {
        let n = candles.count
        guard n > 10 else { return [:] }
        let window = candles.suffix(cfg.vpLookback)
        var minP = Double.greatestFiniteMagnitude
        var maxP = -Double.greatestFiniteMagnitude

        for c in window {
            if c.low < minP { minP = c.low }
            if c.high > maxP { maxP = c.high }
        }

        guard maxP > minP else { return [:] }
        let step = (maxP - minP) / Double(cfg.vpRows)
        var profile: [Double: Double] = [:]

        for c in window {
            let vol = c.volume ?? 1.0
            let row = floor((c.close - minP) / step)
            let midPrice = minP + (row * step) + (step / 2.0)
            profile[midPrice, default: 0.0] += vol
        }

        return profile
    }

    private static func wilderATR(_ candles: [Candle], period: Int) -> [Double] {
        let n = candles.count
        guard n > 0 else { return [] }
        var tr = [Double](repeating: 0, count: n)
        tr[0] = candles[0].high - candles[0].low
        for i in 1..<n {
            let h = candles[i].high
            let l = candles[i].low
            let pc = candles[i - 1].close
            tr[i] = max(h - l, abs(h - pc), abs(l - pc))
        }

        var atr = [Double](repeating: 0, count: n)
        guard n >= period else { return tr }

        var sum = 0.0
        for i in 0..<period { sum += tr[i] }
        atr[period - 1] = sum / Double(period)

        for i in period..<n {
            atr[i] = (atr[i - 1] * Double(period - 1) + tr[i]) / Double(period)
        }
        return atr
    }

    private static func volumeSMA(_ candles: [Candle], period: Int) -> [Double] {
        let n = candles.count
        var result = [Double](repeating: 0, count: n)
        var sum = 0.0

        for i in 0..<n {
            let v = candles[i].volume ?? 0.0
            sum += v
            if i >= period {
                sum -= candles[i - period].volume ?? 0.0
                result[i] = sum / Double(period)
            } else {
                result[i] = sum / Double(i + 1)
            }
        }
        return result
    }
}

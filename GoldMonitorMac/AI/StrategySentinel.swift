import Foundation

struct RadarAlert: Identifiable, Equatable, Codable {
    let id: UUID
    let symbol: String
    let pairID: String
    let timeframe: String
    let direction: SetupDirection
    let confluenceScore: Int // 0 - 100
    let entryPrice: Double
    let stopLoss: Double
    let takeProfit: Double
    let riskRewardRatio: Double
    let rationale: String
    let createdAt: Date
    var volumeRank: Int? = nil
    var tradedVolume: Double? = nil
    var htfLabel: String? = nil
    var isHTFNested: Bool = false
    var status: SetupStatus = .pending
    var breakdown: ConfluenceBreakdown? = nil

    enum SetupDirection: String, Codable {
        case buy = "BUY"
        case sell = "SELL"
    }

    enum SetupStatus: String, Codable {
        case pending = "PENDING"
        case inZone = "IN ZONE"
        case reaction = "REACTION"
    }

    struct ConfluenceBreakdown: Codable, Equatable {
        let baseScore: Int
        let rankBonus: Int
        let htfBonus: Int
        let trendBonus: Int
        let targetBonus: Int
        let htfLabel: String?
        let volumeRank: Int?
        let volumeFormatted: String
        let isTrendAligned: Bool
        let hasOpposingTarget: Bool
    }

    var isFresh: Bool {
        Date().timeIntervalSince(createdAt) < 1800 // < 30 mins
    }
}

@MainActor
final class StrategySentinel: ObservableObject {
    static let shared = StrategySentinel()

    @Published var isSentinelActive: Bool = true
    @Published private(set) var activeRadarAlerts: [RadarAlert] = []
    @Published private(set) var lastScanTimestamp: Date?

    var notificationInbox: NotificationInbox?

    private var lastEvalKey: String = ""
    private var lastEvalTime: Date = .distantPast
    private var lastCandleCount: Int = 0

    private struct UnifiedCandidateZone {
        let id: String
        let engineName: String
        let top: Double
        let bottom: Double
        let isBullish: Bool
        let gradeLabel: String
        let atr: Double
        let tradedVolume: Double
        let isHTFNested: Bool
        let htfLabel: String?
    }

    private struct HTFAuxZone {
        let top: Double
        let bottom: Double
        let isBullish: Bool
    }

    private init() {}

    /// Runs real-time top-down MTF sentinel pass off-main over candle series for a symbol using a unified Traded Volume Ranking engine
    /// across Order Blocks, Sonarlab OB, Ranked OB, and Volume-Ranked OB.
    func evaluateSymbol(
        pairID: String,
        symbol: String,
        timeframe: String,
        candles: [Candle]
    ) {
        guard isSentinelActive, candles.count > 25, let latestCandle = candles.last else { return }

        let now = Date()
        let evalKey = "\(pairID)|\(timeframe)|\(candles.count)|\(latestCandle.id.timeIntervalSince1970)"
        if evalKey == lastEvalKey && now.timeIntervalSince(lastEvalTime) < 3.0 && candles.count == lastCandleCount {
            return
        }
        lastEvalKey = evalKey
        lastEvalTime = now
        lastCandleCount = candles.count

        // Run heavy calculations in background to avoid blocking the main UI/chart rendering thread
        Task.detached(priority: .utility) {
            let currentPrice = latestCandle.close
            let atrVal = Self.calculateATR(candles: candles, period: 14)
            let window = Array(candles.suffix(200))

            // 0. Compute Higher Timeframe (HTF) candle series & active HTF candidate zones
            let (htfFactor, htfName) = Self.getHTFInfo(timeframe: timeframe)
            let htfCandles = Self.aggregateCandles(candles, factor: htfFactor)

            var htfZones: [HTFAuxZone] = []

            if htfCandles.count >= 6 {
                var htfVrobConfig = VolumeRankedOrderBlocks.Config()
                htfVrobConfig.swingLength = 3
                htfVrobConfig.zonesPerSide = 8
                htfVrobConfig.showBreakers = false
                let htfVROBs = VolumeRankedOrderBlocks.compute(htfCandles, config: htfVrobConfig)
                for z in htfVROBs where !z.isBreaker {
                    htfZones.append(HTFAuxZone(top: z.top, bottom: z.bottom, isBullish: z.isBullish))
                }

                var htfRobConfig = RankedOrderBlocks.Config()
                htfRobConfig.swingLength = 3
                htfRobConfig.zonesPerSide = 8
                htfRobConfig.showBreakers = false
                let htfROBs = RankedOrderBlocks.compute(htfCandles, config: htfRobConfig)
                for z in htfROBs where !z.isBreaker {
                    htfZones.append(HTFAuxZone(top: z.top, bottom: z.bottom, isBullish: z.isBullish))
                }

                let htfStdZones = OrderBlocks.compute(htfCandles, periods: 3, threshold: 0.0, useWicks: false)
                for z in htfStdZones where z.status != .exhausted {
                    htfZones.append(HTFAuxZone(top: z.high, bottom: z.low, isBullish: z.isBullish))
                }
            }

            // 1. Collect LTF candidate zones from all 4 Order Block engines
            var candidateZones: [UnifiedCandidateZone] = []

            // Helper to check HTF zone nesting
            let checkHTFNesting = { (top: Double, bottom: Double, isBullish: Bool) -> (Bool, String?) in
                let matches = htfZones.contains { htf in
                    htf.isBullish == isBullish && bottom <= (htf.top + (0.25 * atrVal)) && top >= (htf.bottom - (0.25 * atrVal))
                }
                return (matches, matches ? htfName : nil)
            }

            let isLTF = timeframe.contains("1m") || timeframe.contains("3m") || timeframe.contains("5m")
            let swingLen = isLTF ? 5 : 10

            // A. Volume-Ranked OB
            var vrobConfig = VolumeRankedOrderBlocks.Config()
            vrobConfig.swingLength = swingLen
            vrobConfig.zonesPerSide = 8
            vrobConfig.showBreakers = false
            let vrobZones = VolumeRankedOrderBlocks.compute(candles, config: vrobConfig)
            for z in vrobZones where !z.isBreaker {
                let vol = Self.computeTradedVolume(bottom: z.bottom, top: z.top, window: window)
                let (nested, label) = checkHTFNesting(z.top, z.bottom, z.isBullish)
                candidateZones.append(UnifiedCandidateZone(
                    id: z.id, engineName: "Volume-Ranked OB", top: z.top, bottom: z.bottom,
                    isBullish: z.isBullish, gradeLabel: z.grade.rawValue, atr: z.atr, tradedVolume: vol,
                    isHTFNested: nested, htfLabel: label
                ))
            }

            // B. Ranked OB (Pine Port)
            var robConfig = RankedOrderBlocks.Config()
            robConfig.swingLength = swingLen
            robConfig.zonesPerSide = 8
            robConfig.showBreakers = false
            let robZones = RankedOrderBlocks.compute(candles, config: robConfig)
            for z in robZones where !z.isBreaker {
                let vol = Self.computeTradedVolume(bottom: z.bottom, top: z.top, window: window)
                let (nested, label) = checkHTFNesting(z.top, z.bottom, z.isBullish)
                candidateZones.append(UnifiedCandidateZone(
                    id: z.id, engineName: "Ranked OB", top: z.top, bottom: z.bottom,
                    isBullish: z.isBullish, gradeLabel: z.grade.rawValue, atr: z.atr, tradedVolume: vol,
                    isHTFNested: nested, htfLabel: label
                ))
            }

            // C. Sonarlab OB
            let sonarZones = SonarlabOrderBlocks.compute(candles, sensitivity: isLTF ? 15 : 26, mitigationType: .close)
            for z in sonarZones {
                let vol = Self.computeTradedVolume(bottom: z.low, top: z.high, window: window)
                let (nested, label) = checkHTFNesting(z.high, z.low, z.isBullish)
                candidateZones.append(UnifiedCandidateZone(
                    id: z.id, engineName: "Sonarlab OB", top: z.high, bottom: z.low,
                    isBullish: z.isBullish, gradeLabel: "ROC", atr: atrVal, tradedVolume: vol,
                    isHTFNested: nested, htfLabel: label
                ))
            }

            // D. Standard Order Blocks
            let stdOBZones = OrderBlocks.compute(candles, periods: isLTF ? 3 : 5, threshold: 0.0, useWicks: false)
            for z in stdOBZones where z.status != .exhausted {
                let vol = Self.computeTradedVolume(bottom: z.low, top: z.high, window: window)
                let (nested, label) = checkHTFNesting(z.high, z.low, z.isBullish)
                candidateZones.append(UnifiedCandidateZone(
                    id: z.id, engineName: "Order Block", top: z.high, bottom: z.low,
                    isBullish: z.isBullish, gradeLabel: z.status == OrderBlocks.ExhaustionStatus.fresh ? "Fresh" : "Tested", atr: atrVal, tradedVolume: vol,
                    isHTFNested: nested, htfLabel: label
                ))
            }

            let emaVal = Self.calculateEMA(candles: candles, period: min(200, max(20, candles.count / 2)))

            // Filter candidates within market structure (≤ 15.0x ATR or 5% price) and not heavily retested (>3 touches)
            candidateZones = candidateZones.filter { z in
                let entry = z.isBullish ? z.top : z.bottom
                let dist = abs(currentPrice - entry)
                guard dist <= max(15.0 * z.atr, currentPrice * 0.05) else { return false }

                let retestTouches = window.filter { c in
                    c.low <= z.top && c.high >= z.bottom
                }.count
                return retestTouches <= 3
            }

            // 2. Rank ALL Candidate Zones strictly by Traded Volume (Rank #1 = highest volume)
            candidateZones.sort { $0.tradedVolume > $1.tradedVolume }

            var newAlerts: [RadarAlert] = []
            let activeBullish = candidateZones.filter { $0.isBullish }
            let activeBearish = candidateZones.filter { !$0.isBullish }

            // 3. Generate trade setups for each candidate zone in ranked order
            for (index, zone) in candidateZones.enumerated() {
                let rank = index + 1
                let isBuy = zone.isBullish
                let entry = isBuy ? zone.top : zone.bottom
                let stopLoss = isBuy ? zone.bottom - (0.35 * zone.atr) : zone.top + (0.35 * zone.atr)
                let riskAmount = abs(entry - stopLoss)
                guard riskAmount > 0 else { continue }

                // Find nearest opposing zone for Take Profit target
                let opposingZone = isBuy
                    ? activeBearish.filter { $0.bottom > entry }.min(by: { $0.bottom < $1.bottom })
                    : activeBullish.filter { $0.top < entry }.max(by: { $0.top < $1.top })

                let takeProfit: Double
                if let target = opposingZone {
                    let targetPrice = isBuy ? target.bottom : target.top
                    let targetReward = abs(targetPrice - entry)
                    if targetReward / riskAmount >= 1.5 {
                        takeProfit = targetPrice
                    } else {
                        takeProfit = isBuy ? entry + (riskAmount * 2.0) : entry - (riskAmount * 2.0)
                    }
                } else {
                    takeProfit = isBuy ? entry + (riskAmount * 2.2) : entry - (riskAmount * 2.2)
                }

                let rewardAmount = abs(takeProfit - entry)
                let rr = rewardAmount / riskAmount
                guard rr >= 1.0 else { continue }

                // 3a. Signal Invalidation Checks: Discard setups where TP or SL has already been touched/breached
                let recentWindow = Array(candles.suffix(40))
                if isBuy {
                    // BUY Setup Invalidation:
                    // 1) Target already hit (current price or recent high >= takeProfit)
                    if currentPrice >= takeProfit || latestCandle.high >= takeProfit || recentWindow.contains(where: { $0.high >= takeProfit }) {
                        continue
                    }
                    // 2) Stop loss breached (current price or recent low <= stopLoss)
                    if currentPrice <= stopLoss || latestCandle.low <= stopLoss || recentWindow.contains(where: { $0.low <= stopLoss }) {
                        continue
                    }
                } else {
                    // SELL Setup Invalidation:
                    // 1) Target already hit (current price or recent low <= takeProfit)
                    if currentPrice <= takeProfit || latestCandle.low <= takeProfit || recentWindow.contains(where: { $0.low <= takeProfit }) {
                        continue
                    }
                    // 2) Stop loss breached (current price or recent high >= stopLoss)
                    if currentPrice >= stopLoss || latestCandle.high >= stopLoss || recentWindow.contains(where: { $0.high >= stopLoss }) {
                        continue
                    }
                }

                // 3b. Setup Lifecycle Status & Remaining R:R Filter
                let isInZone = currentPrice >= zone.bottom && currentPrice <= zone.top
                let isMovingToTP = isBuy ? (currentPrice > zone.top) : (currentPrice < zone.bottom)

                let setupStatus: RadarAlert.SetupStatus
                if isInZone {
                    setupStatus = .inZone
                } else if isMovingToTP {
                    setupStatus = .reaction
                } else {
                    setupStatus = .pending
                }

                if isMovingToTP {
                    let totalSpan = abs(takeProfit - entry)
                    if totalSpan > 0 {
                        let distanceMoved = abs(currentPrice - entry)
                        let progress = distanceMoved / totalSpan

                        let remainingReward = abs(takeProfit - currentPrice)
                        let remainingRisk = abs(currentPrice - stopLoss)
                        let effectiveRR = remainingRisk > 0 ? (remainingReward / remainingRisk) : 0.0

                        // Discard if price already moved > 70% toward TP, or effective remaining R:R < 0.8
                        if progress > 0.70 || effectiveRR < 0.8 {
                            continue
                        }
                    }
                }

                // Score boost based on Traded Volume Rank + HTF Nesting + Trend EMA Alignment
                let isTrendAligned = isBuy ? (currentPrice >= emaVal) : (currentPrice <= emaVal)
                let trendBonus = isTrendAligned ? 15 : 0
                let rankBonus = max(5, 25 - ((rank - 1) * 5))
                let htfBonus = zone.isHTFNested ? 20 : 0
                let score = min(100, 45 + rankBonus + htfBonus + trendBonus + (opposingZone != nil ? 10 : 0))

                let formattedVol = Self.formatVolume(zone.tradedVolume)
                let htfTag = zone.isHTFNested ? "⚡ HTF \(zone.htfLabel ?? "Zone") · " : ""
                let rationale = "\(htfTag)Rank #\(rank) (\(formattedVol) Vol) · \(zone.engineName) [\(zone.gradeLabel)] -> \(isBuy ? "BUY" : "SELL") at \(PriceFormat.exact(entry)). TP at opposing zone."

                let alertSeed = "\(pairID)|\(timeframe)|\(isBuy ? "BUY" : "SELL")|\(zone.engineName)|\(PriceFormat.exact(entry))"
                let alertID = Self.deterministicUUID(from: alertSeed)

                let confluenceBreakdown = RadarAlert.ConfluenceBreakdown(
                    baseScore: 45,
                    rankBonus: rankBonus,
                    htfBonus: htfBonus,
                    trendBonus: trendBonus,
                    targetBonus: opposingZone != nil ? 10 : 0,
                    htfLabel: zone.htfLabel,
                    volumeRank: rank,
                    volumeFormatted: formattedVol,
                    isTrendAligned: isTrendAligned,
                    hasOpposingTarget: opposingZone != nil
                )

                let alert = RadarAlert(
                    id: alertID,
                    symbol: symbol,
                    pairID: pairID,
                    timeframe: timeframe,
                    direction: isBuy ? .buy : .sell,
                    confluenceScore: score,
                    entryPrice: entry,
                    stopLoss: stopLoss,
                    takeProfit: takeProfit,
                    riskRewardRatio: rr,
                    rationale: rationale,
                    createdAt: Date(),
                    volumeRank: rank,
                    tradedVolume: zone.tradedVolume,
                    htfLabel: zone.htfLabel,
                    isHTFNested: zone.isHTFNested,
                    status: setupStatus,
                    breakdown: confluenceBreakdown
                )
                newAlerts.append(alert)
            }

            // 4. Sort alerts by HTF nesting first, then by Volume Rank (#1 rank first)
            newAlerts.sort { a, b in
                if a.isHTFNested != b.isHTFNested {
                    return a.isHTFNested && !b.isHTFNested
                }
                return (a.volumeRank ?? 99) < (b.volumeRank ?? 99)
            }

            let finalAlerts = newAlerts
            // Hop back to main actor ONLY to publish if alerts have actually changed
            await MainActor.run {
                Self.shared.publishResultsIfChanged(newAlerts: finalAlerts)
            }
        }
    }

    nonisolated private static func deterministicUUID(from seed: String) -> UUID {
        var hash = [UInt8](repeating: 0, count: 16)
        let bytes = Array(seed.utf8)
        for (i, b) in bytes.enumerated() {
            hash[i % 16] ^= b
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

    private func publishResultsIfChanged(newAlerts: [RadarAlert]) {
        // Compare newAlerts with activeRadarAlerts to prevent unnecessary UI invalidation
        let alertsEqual = activeRadarAlerts.count == newAlerts.count &&
            zip(activeRadarAlerts, newAlerts).allSatisfy { a, b in
                a.id == b.id &&
                a.confluenceScore == b.confluenceScore &&
                abs(a.entryPrice - b.entryPrice) < 0.0001 &&
                abs(a.stopLoss - b.stopLoss) < 0.0001 &&
                abs(a.takeProfit - b.takeProfit) < 0.0001 &&
                a.isHTFNested == b.isHTFNested
            }

        if !alertsEqual {
            activeRadarAlerts = newAlerts
            lastScanTimestamp = Date()

            // Dispatch system notifications for fresh high-confluence alerts
            for alert in newAlerts where alert.confluenceScore >= 70 {
                let htfPrefix = alert.isHTFNested ? "⚡ HTF \(alert.htfLabel ?? "Zone") Nesting · " : ""
                notificationInbox?.record(
                    dedupKey: "sentinel|\(alert.pairID)|\(alert.direction.rawValue)|\(alert.timeframe)|\(String(format: "%.1f", alert.entryPrice))",
                    cooldown: 1800, // 30 mins dedup
                    pairID: alert.pairID,
                    pairLabel: alert.symbol,
                    category: .strategy,
                    title: "⚡ Strategy Sentinel: \(alert.symbol) \(alert.direction.rawValue) (\(htfPrefix)Rank #\(alert.volumeRank ?? 1))",
                    body: "\(alert.rationale) Entry: \(PriceFormat.exact(alert.entryPrice)) | TP: \(PriceFormat.exact(alert.takeProfit)) | SL: \(PriceFormat.exact(alert.stopLoss)).",
                    timeframeLabel: alert.timeframe
                )
            }
        }
    }

    nonisolated private static func getHTFInfo(timeframe: String) -> (Int, String) {
        switch timeframe.lowercased() {
        case "1m", "3m":   return (15, "15m")
        case "5m":        return (12, "1h")
        case "15m":       return (4, "1h")
        case "30m", "1h": return (4, "4h")
        case "4h":        return (6, "1D")
        default:          return (4, "1h")
        }
    }

    nonisolated private static func aggregateCandles(_ candles: [Candle], factor: Int) -> [Candle] {
        guard factor > 1, candles.count >= factor else { return candles }
        var result: [Candle] = []
        let total = candles.count
        var index = 0

        while index < total {
            let end = min(index + factor, total)
            let slice = candles[index..<end]
            guard let first = slice.first, let last = slice.last else { break }

            var maxHigh = first.high
            var minLow = first.low
            var volSum = 0.0

            for c in slice {
                if c.high > maxHigh { maxHigh = c.high }
                if c.low < minLow { minLow = c.low }
                volSum += (c.volume ?? 1.0)
            }

            result.append(Candle(
                id: first.id,
                open: first.open,
                high: maxHigh,
                low: minLow,
                close: last.close,
                volume: volSum
            ))
            index = end
        }
        return result
    }

    nonisolated private static func computeTradedVolume(bottom: Double, top: Double, window: [Candle]) -> Double {
        var total: Double = 0.0
        for c in window {
            if c.low <= top && c.high >= bottom {
                total += (c.volume ?? 1.0)
            }
        }
        return total
    }

    nonisolated private static func calculateATR(candles: [Candle], period: Int) -> Double {
        guard candles.count >= period else { return 1.0 }
        var trs: [Double] = []
        for i in 1..<candles.count {
            let h = candles[i].high
            let l = candles[i].low
            let pc = candles[i - 1].close
            trs.append(max(h - l, abs(h - pc), abs(l - pc)))
        }
        let tail = trs.suffix(period)
        return tail.reduce(0.0, +) / Double(tail.count)
    }

    nonisolated private static func calculateEMA(candles: [Candle], period: Int) -> Double {
        guard !candles.isEmpty else { return 0.0 }
        let k = 2.0 / Double(period + 1)
        var ema = candles[0].close
        for i in 1..<candles.count {
            ema = (candles[i].close * k) + (ema * (1.0 - k))
        }
        return ema
    }

    nonisolated private static func formatVolume(_ vol: Double) -> String {
        if vol >= 1_000_000 {
            return String(format: "%.1fM", vol / 1_000_000)
        } else if vol >= 1_000 {
            return String(format: "%.1fk", vol / 1_000)
        } else {
            return String(format: "%.0f", vol)
        }
    }
}

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

@MainActor
final class StrategySentinel: ObservableObject {
    static let shared = StrategySentinel()

    @Published var isSentinelActive: Bool = true
    @Published private(set) var activeRadarAlerts: [RadarAlert] = []
    @Published private(set) var lastScanTimestamp: Date?
    /// Market read for the selected symbol, shown in the drawer header even
    /// when no setup qualifies.
    @Published private(set) var marketContext: [String: MarketContext] = [:]

    var notificationInbox: NotificationInbox?

    private var lastEvalKey: String = ""
    private var lastEvalTime: Date = .distantPast
    private var lastCandleCount: Int = 0

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
    func evaluateSymbol(
        pairID: String,
        symbol: String,
        timeframe: String,
        candles: [Candle]
    ) {
        guard isSentinelActive, candles.count > 60, let latestCandle = candles.last else { return }

        let now = Date()
        let evalKey = "\(pairID)|\(timeframe)|\(candles.count)|\(latestCandle.id.timeIntervalSince1970)"
        if evalKey == lastEvalKey && now.timeIntervalSince(lastEvalTime) < 3.0 && candles.count == lastCandleCount {
            return
        }
        lastEvalKey = evalKey
        lastEvalTime = now
        lastCandleCount = candles.count

        Task.detached(priority: .utility) {
            let (htfFactor, htfName) = Self.getHTFInfo(timeframe: timeframe)
            let htfCandles = Self.aggregateCandles(candles, factor: htfFactor)

            let result = SMCSentinelEngine.scan(
                candles: candles,
                htfCandles: htfCandles,
                htfLabel: htfName,
                htfFactor: htfFactor
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
                let seed = "\(pairID)|\(timeframe)|\(setup.isLong ? "BUY" : "SELL")|\(setup.zoneID)"
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
                Self.shared.publishResultsIfChanged(pairID: pairID, newAlerts: alerts, context: context)
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

    private func publishResultsIfChanged(pairID: String, newAlerts: [RadarAlert], context: MarketContext) {
        if marketContext[pairID] != context {
            marketContext[pairID] = context
        }

        // Only this symbol's alerts are replaced; other symbols keep theirs.
        let others = activeRadarAlerts.filter { $0.pairID != pairID }
        let mine = activeRadarAlerts.filter { $0.pairID == pairID }

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
            activeRadarAlerts = others + newAlerts
            lastScanTimestamp = Date()

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
}

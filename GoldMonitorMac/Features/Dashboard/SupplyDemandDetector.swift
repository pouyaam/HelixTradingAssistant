import Foundation

/// A high-performance, 100% deterministic Swift Supply & Demand zone detector.
/// Eliminates LLM hallucinations for zone prices, boundaries, and trade geometry.
struct SupplyDemandZone: Identifiable, Equatable, Codable {
    let id: UUID
    let symbol: String
    let timeframe: String
    let type: ZoneType
    let topPrice: Double
    let bottomPrice: Double
    let startIndex: Int
    let impulseIndex: Int
    let atrAtFormation: Double
    var retestCount: Int
    var isInvalidated: Bool
    var grade: ZoneGrade

    enum ZoneType: String, Codable {
        case supply // Resistance / Sell zone
        case demand // Support / Buy zone
    }

    enum ZoneGrade: String, Codable {
        case aPlus = "A+"
        case a = "A"
        case b = "B"
        case c = "C"
    }

    var height: Double {
        abs(topPrice - bottomPrice)
    }

    var midPrice: Double {
        (topPrice + bottomPrice) / 2.0
    }
}

enum SupplyDemandDetector {
    /// Detects Supply and Demand zones from a series of OHLC candles using ATR impulse expansion.
    /// - Parameters:
    ///   - candles: The historical candle series.
    ///   - symbol: Symbol ticker string.
    ///   - timeframe: Current timeframe string.
    ///   - atrPeriod: Lookback period for ATR (default: 14).
    ///   - impulseMultiplier: Multiplier for ATR to identify an explosive move (default: 1.5).
    ///   - maxBaseCandles: Maximum consolidation candles prior to impulse (default: 3).
    /// - Returns: Array of detected `SupplyDemandZone` instances.
    static func detectZones(
        in candles: [Candle],
        symbol: String = "XAU",
        timeframe: String = "15m",
        atrPeriod: Int = 14,
        impulseMultiplier: Double = 1.5,
        maxBaseCandles: Int = 3
    ) -> [SupplyDemandZone] {
        guard candles.count > atrPeriod + maxBaseCandles else { return [] }

        // 1. Calculate ATR for candle array
        let atrs = calculateATR(candles: candles, period: atrPeriod)

        var zones: [SupplyDemandZone] = []

        // 2. Scan for impulse candles
        for i in (atrPeriod + maxBaseCandles)..<candles.count {
            let candle = candles[i]
            let atr = atrs[i]
            let candleRange = candle.high - candle.low
            let bodySize = abs(candle.close - candle.open)

            // Impulse condition: range >= multiplier * ATR and body >= 50% of range
            guard candleRange >= impulseMultiplier * atr, bodySize >= 0.5 * candleRange else {
                continue
            }

            let isBullishImpulse = candle.close > candle.open
            let baseStart = max(0, i - maxBaseCandles)
            let baseCandles = Array(candles[baseStart..<i])
            guard !baseCandles.isEmpty else { continue }

            if isBullishImpulse {
                // Demand Zone formed by base candles prior to bullish explosive move
                let bottom = baseCandles.map { $0.low }.min() ?? candle.low
                let top = baseCandles.map { min($0.open, $0.close) }.max() ?? candle.open

                let zone = SupplyDemandZone(
                    id: UUID(),
                    symbol: symbol,
                    timeframe: timeframe,
                    type: .demand,
                    topPrice: top,
                    bottomPrice: bottom,
                    startIndex: baseStart,
                    impulseIndex: i,
                    atrAtFormation: atr,
                    retestCount: 0,
                    isInvalidated: false,
                    grade: gradeZone(height: top - bottom, atr: atr, retestCount: 0)
                )
                zones.append(zone)
            } else {
                // Supply Zone formed by base candles prior to bearish explosive move
                let top = baseCandles.map { $0.high }.max() ?? candle.high
                let bottom = baseCandles.map { max($0.open, $0.close) }.min() ?? candle.open

                let zone = SupplyDemandZone(
                    id: UUID(),
                    symbol: symbol,
                    timeframe: timeframe,
                    type: .supply,
                    topPrice: top,
                    bottomPrice: bottom,
                    startIndex: baseStart,
                    impulseIndex: i,
                    atrAtFormation: atr,
                    retestCount: 0,
                    isInvalidated: false,
                    grade: gradeZone(height: top - bottom, atr: atr, retestCount: 0)
                )
                zones.append(zone)
            }
        }

        // 3. Track zone retests and invalidations forward in time
        var activeZones: [SupplyDemandZone] = []
        for var zone in zones {
            for j in (zone.impulseIndex + 1)..<candles.count {
                let currentBar = candles[j]

                if zone.type == .demand {
                    // Invalidated if price breaks below bottom price
                    if currentBar.close < zone.bottomPrice {
                        zone.isInvalidated = true
                        break
                    }
                    // Retested if price touches inside the zone
                    if currentBar.low <= zone.topPrice && currentBar.high >= zone.bottomPrice {
                        zone.retestCount += 1
                    }
                } else {
                    // Invalidated if price breaks above top price
                    if currentBar.close > zone.topPrice {
                        zone.isInvalidated = true
                        break
                    }
                    // Retested if price touches inside the zone
                    if currentBar.high >= zone.bottomPrice && currentBar.low <= zone.topPrice {
                        zone.retestCount += 1
                    }
                }
            }

            // Update grade based on retests
            zone.grade = gradeZone(height: zone.height, atr: zone.atrAtFormation, retestCount: zone.retestCount)

            // Keep fresh and lightly retested active zones
            if !zone.isInvalidated && zone.retestCount <= 3 {
                activeZones.append(zone)
            }
        }

        return activeZones
    }

    /// Evaluates zone grade (A+, A, B, C) based on ATR proportion and freshness.
    private static func gradeZone(height: Double, atr: Double, retestCount: Int) -> SupplyDemandZone.ZoneGrade {
        if retestCount == 0 && height <= 1.2 * atr {
            return .aPlus
        } else if retestCount <= 1 {
            return .a
        } else if retestCount == 2 {
            return .b
        } else {
            return .c
        }
    }

    /// Calculate Average True Range (ATR) array for candle series.
    private static func calculateATR(candles: [Candle], period: Int) -> [Double] {
        guard !candles.isEmpty else { return [] }
        var trs: [Double] = [candles[0].high - candles[0].low]

        for i in 1..<candles.count {
            let prevClose = candles[i - 1].close
            let curr = candles[i]
            let tr = max(curr.high - curr.low, max(abs(curr.high - prevClose), abs(curr.low - prevClose)))
            trs.append(tr)
        }

        var atrs: [Double] = Array(repeating: trs[0], count: candles.count)
        var sum = trs.prefix(period).reduce(0, +)
        let initialATR = sum / Double(min(period, trs.count))

        for i in 0..<candles.count {
            if i < period {
                atrs[i] = initialATR
            } else {
                let prevATR = atrs[i - 1]
                atrs[i] = (prevATR * Double(period - 1) + trs[i]) / Double(period)
            }
        }
        return atrs
    }

    /// Validates trade geometry before sending to execution or AI scoring.
    /// Ensures R:R meets minimum threshold and stop loss is safely positioned.
    static func validateTradeGeometry(
        type: SupplyDemandZone.ZoneType,
        entry: Double,
        stopLoss: Double,
        takeProfit: Double,
        minRR: Double = 1.5
    ) -> (isValid: Bool, riskRewardRatio: Double, reason: String?) {
        let risk = abs(entry - stopLoss)
        let reward = abs(takeProfit - entry)

        guard risk > 0 else {
            return (false, 0, "Stop Loss cannot equal Entry price.")
        }

        let rr = reward / risk

        if type == .demand {
            // Buy Order
            guard stopLoss < entry else {
                return (false, rr, "Buy Order Stop Loss must be below Entry.")
            }
            guard takeProfit > entry else {
                return (false, rr, "Buy Order Take Profit must be above Entry.")
            }
        } else {
            // Sell Order
            guard stopLoss > entry else {
                return (false, rr, "Sell Order Stop Loss must be above Entry.")
            }
            guard takeProfit < entry else {
                return (false, rr, "Sell Order Take Profit must be below Entry.")
            }
        }

        if rr < minRR {
            return (false, rr, String(format: "Risk:Reward ratio (%.2f) is below minimum threshold (%.2f).", rr, minRR))
        }

        return (true, rr, nil)
    }
}

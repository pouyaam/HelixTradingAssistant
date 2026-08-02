import Foundation

/// Enhanced Sonarlab Order Blocks — momentum-based institutional order block
/// detection augmented with institutional volume spikes, ATR displacement,
/// Fair Value Gap (FVG) imbalance checks, trend alignment, and zone grading.
///
/// Builds upon ClayeWeight's PineScript v5 "Sonarlab - Order Blocks" ROC engine:
///     pc = (open - open[4]) / open[4] * 100
///
/// When ROC crosses above/below the sensitivity threshold, candidate zones
/// are evaluated against multi-factor quality criteria and assigned a Grade:
///   • Grade A: Meets ROC + Volume Spike + ATR Displacement + FVG / Trend
///   • Grade B: Meets ROC + Volume Spike or ATR Displacement
///   • Grade C: Low volume or minimal displacement
enum EnhancedSonarlabOrderBlocks {

    enum MitigationType: String, Codable, Hashable {
        case wick
        case close
        case unmitigatedOnly
    }

    enum Grade: String, Codable, Hashable, Comparable {
        case C = "C"
        case B = "B"
        case A = "A"

        private var rank: Int {
            switch self {
            case .C: return 1
            case .B: return 2
            case .A: return 3
            }
        }

        static func < (lhs: Grade, rhs: Grade) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    struct Zone: Identifiable, Hashable {
        let index: Int
        let high: Double
        let low: Double
        let isBullish: Bool
        let grade: Grade
        let score: Int // 0...100
        let hasVolumeSpike: Bool
        let hasDisplacement: Bool
        let hasFVG: Bool
        let isMitigated: Bool

        var id: String { "enh-sonar-\(index)-\(isBullish ? "bull" : "bear")" }
    }

    /// Computes filtered and graded Sonarlab Order Blocks.
    static func compute(
        _ candles: [Candle],
        sensitivity: Double = 35.0,
        mitigationType: MitigationType = .wick,
        requireVolumeSpike: Bool = true,
        minVolumeMult: Double = 1.3,
        minDisplacementATR: Double = 1.0,
        requireFVG: Bool = false,
        trendFilter: String = "Off",
        minGradeFilter: String = "Grade B+",
        maxZones: Int = 15
    ) -> [Zone] {
        guard candles.count >= 20, sensitivity > 0 else { return [] }

        let sens = sensitivity / 100.0

        // 1. Precalculate 14-period ATR for displacement measurements
        let atrValues = calculateATR(candles, period: 14)

        // 2. Precalculate 20-period Volume SMA
        let volSMA = calculateVolumeSMA(candles, period: 20)

        // 3. Precalculate 50/200 EMA if trend filtering is enabled
        let ema50 = trendFilter == "EMA 50" ? calculateEMA(candles, period: 50) : []
        let ema200 = trendFilter == "EMA 200" ? calculateEMA(candles, period: 200) : []

        var candidateZones: [Zone] = []
        var lastTriggerIndex: Int = -10

        for i in 5..<candles.count {
            let openNow = candles[i].open
            let openPrev = candles[i - 4].open
            guard openPrev != 0 else { continue }
            let pc = (openNow - openPrev) / openPrev * 100.0

            let openN = candles[i - 1].open
            let openP = candles[i - 5].open
            guard openP != 0 else { continue }
            let pcPrev = (openN - openP) / openP * 100.0

            var triggered = false
            var isBullish = false

            if pcPrev <= sens && pc > sens {
                triggered = true
                isBullish = true
            } else if pcPrev >= -sens && pc < -sens {
                triggered = true
                isBullish = false
            }

            guard triggered, (i - lastTriggerIndex) > 5 else { continue }
            lastTriggerIndex = i

            // Locate origin counter-trend candle in lookback window 4..15
            var obIdx: Int? = nil
            for j in 4...min(15, i) {
                let c = candles[i - j]
                if isBullish {
                    if c.close < c.open { obIdx = i - j; break }
                } else {
                    if c.close > c.open { obIdx = i - j; break }
                }
            }
            guard let idx = obIdx else { continue }
            let obCandle = candles[idx]

            // Check Volume Spike on impulse bar (i)
            let impulseVol = candles[i].volume ?? 0.0
            let avgVol = (i < volSMA.count) ? volSMA[i] : 0.0
            let volRatio = avgVol > 0 ? impulseVol / avgVol : 1.0
            let hasVolSpike = volRatio >= minVolumeMult

            if requireVolumeSpike && !hasVolSpike {
                continue
            }

            // Check Displacement over next 3 bars following OB candle
            let atr = (idx < atrValues.count) ? atrValues[idx] : (obCandle.high - obCandle.low)
            var priceDisplacement = 0.0
            let endEval = min(i + 2, candles.count - 1)
            if isBullish {
                let maxHigh = candles[idx...endEval].map { $0.high }.max() ?? obCandle.high
                priceDisplacement = maxHigh - obCandle.high
            } else {
                let minLow = candles[idx...endEval].map { $0.low }.min() ?? obCandle.low
                priceDisplacement = obCandle.low - minLow
            }

            let displacementMult = atr > 0 ? priceDisplacement / atr : 0.0
            let hasDisplace = displacementMult >= minDisplacementATR

            if minDisplacementATR > 0 && !hasDisplace {
                continue
            }

            // Check FVG Imbalance in window [idx .. idx + 3]
            var hasFVG = false
            let fvgEnd = min(idx + 4, candles.count - 1)
            if idx + 2 <= fvgEnd {
                for k in idx..<(fvgEnd - 1) {
                    let c1 = candles[k]
                    let c3 = candles[k + 2]
                    if isBullish {
                        if c3.low > c1.high { hasFVG = true; break }
                    } else {
                        if c3.high < c1.low { hasFVG = true; break }
                    }
                }
            }

            if requireFVG && !hasFVG {
                continue
            }

            // Check Trend Alignment
            if trendFilter == "EMA 50" && i < ema50.count {
                let ema = ema50[i]
                if isBullish && candles[i].close < ema { continue }
                if !isBullish && candles[i].close > ema { continue }
            } else if trendFilter == "EMA 200" && i < ema200.count {
                let ema = ema200[i]
                if isBullish && candles[i].close < ema { continue }
                if !isBullish && candles[i].close > ema { continue }
            }

            // Score and Grade zone
            var score = 50
            if hasVolSpike { score += 20 }
            if hasDisplace { score += 20 }
            if hasFVG { score += 10 }

            let zoneGrade: Grade
            if score >= 80 {
                zoneGrade = .A
            } else if score >= 60 {
                zoneGrade = .B
            } else {
                zoneGrade = .C
            }

            // Filter by min grade
            if minGradeFilter == "Grade A Only" && zoneGrade != .A { continue }
            if minGradeFilter == "Grade B+" && zoneGrade == .C { continue }

            // Check Mitigation
            var isMitigated = false
            for ci in (idx + 1)..<candles.count {
                let c = candles[ci]
                if mitigationType == .close {
                    if ci >= 1 {
                        let prevClose = candles[ci - 1].close
                        if isBullish {
                            if prevClose < obCandle.low { isMitigated = true; break }
                        } else {
                            if prevClose > obCandle.high { isMitigated = true; break }
                        }
                    }
                } else {
                    // Wick mode
                    if isBullish {
                        if c.low < obCandle.low { isMitigated = true; break }
                    } else {
                        if c.high > obCandle.high { isMitigated = true; break }
                    }
                }
            }

            if mitigationType == .unmitigatedOnly && isMitigated {
                continue
            }

            candidateZones.append(Zone(
                index: idx,
                high: obCandle.high,
                low: obCandle.low,
                isBullish: isBullish,
                grade: zoneGrade,
                score: score,
                hasVolumeSpike: hasVolSpike,
                hasDisplacement: hasDisplace,
                hasFVG: hasFVG,
                isMitigated: isMitigated
            ))
        }

        return Array(candidateZones.suffix(maxZones))
    }

    // MARK: - Internal Math Helpers

    private static func calculateATR(_ candles: [Candle], period: Int) -> [Double] {
        guard !candles.isEmpty else { return [] }
        var trs = [Double](repeating: 0.0, count: candles.count)
        trs[0] = candles[0].high - candles[0].low
        for i in 1..<candles.count {
            let h = candles[i].high
            let l = candles[i].low
            let pc = candles[i - 1].close
            trs[i] = max(h - l, max(abs(h - pc), abs(l - pc)))
        }
        var atr = [Double](repeating: 0.0, count: candles.count)
        var sum = 0.0
        for i in 0..<candles.count {
            sum += trs[i]
            if i >= period { sum -= trs[i - period] }
            if i >= period - 1 {
                atr[i] = sum / Double(period)
            } else {
                atr[i] = sum / Double(i + 1)
            }
        }
        return atr
    }

    private static func calculateVolumeSMA(_ candles: [Candle], period: Int) -> [Double] {
        guard !candles.isEmpty else { return [] }
        var result = [Double](repeating: 0.0, count: candles.count)
        var sum = 0.0
        for i in 0..<candles.count {
            sum += candles[i].volume ?? 0.0
            if i >= period { sum -= candles[i - period].volume ?? 0.0 }
            if i >= period - 1 {
                result[i] = sum / Double(period)
            } else {
                result[i] = sum / Double(i + 1)
            }
        }
        return result
    }

    private static func calculateEMA(_ candles: [Candle], period: Int) -> [Double] {
        guard !candles.isEmpty else { return [] }
        var result = [Double](repeating: 0.0, count: candles.count)
        let k = 2.0 / Double(period + 1)
        result[0] = candles[0].close
        for i in 1..<candles.count {
            result[i] = (candles[i].close * k) + (result[i - 1] * (1.0 - k))
        }
        return result
    }
}

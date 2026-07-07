import Foundation

/// FVG-First → OB Back — detects Fair Value Gaps first, then looks
/// backward to find the originating Order Block candle. This reverses
/// the usual OB-first flow: the FVG is the primary signal (simpler
/// 3-bar pattern, more reliable detection) and the OB is the
/// confirmation that institutional activity created the imbalance.
///
/// Detection:
///   1. Compute Fair Value Gaps (configurable threshold).
///   2. For each FVG, scan backward `searchMin`..`searchMax` bars for
///      the most recent counter-trend candle.
///   3. If found, the zone is the OB candle's range, tagged with the
///      FVG that confirmed it. The FVG acts as a "validation stamp".
///   4. Optional volume filter: the OB candle's volume must be
///      ≥ `volumeMultiplier` × 20-period volume SMA (like Steroid OB).
///   5. Exhaustion lifecycle: zones track fresh → tested → exhausted
///      as price interacts with them (same logic as OrderBlocks).
///
/// Pure-function, no state.
enum FVGFirstOB {

    enum ExhaustionStatus: String, Codable, Hashable {
        case fresh
        case tested
        case exhausted
    }

    struct Zone: Identifiable, Hashable {
        /// Bar index of the originating OB candle.
        let index: Int
        let high: Double
        let low: Double
        let isBullish: Bool
        /// Bar index of the FVG that triggered the backward search.
        let fvgIndex: Int
        /// Exhaustion lifecycle status.
        let status: ExhaustionStatus
        /// How many times price has revisited this zone.
        let testCount: Int
        /// Equilibrium midline.
        var avg: Double { (high + low) / 2 }
        var id: String { "fvob-\(index)-\(fvgIndex)-\(isBullish ? "bull" : "bear")" }
    }

    /// Scan for FVG-first → OB-back zones.
    ///
    /// - searchMin:  minimum bars to look back from the FVG (default 4).
    /// - searchMax:  maximum bars to look back (default 15).
    /// - detectVolume: when true, only keep OBs whose candle volume
    ///               is ≥ `volumeMultiplier` × 20-period SMA.
    /// - volumeMultiplier: the SMA multiplier threshold (default 1.2).
    static func compute(
        _ candles: [Candle],
        fvgThreshold: Double = 0,
        searchMin: Int = 4,
        searchMax: Int = 15,
        detectVolume: Bool = false,
        volumeMultiplier: Double = 1.2,
        maxZones: Int = 20
    ) -> [Zone] {
        let fvgZones = FairValueGap.compute(candles, threshold: fvgThreshold)
        let minBars = max(1, searchMin)
        let maxBars = max(minBars, searchMax)
        guard !fvgZones.isEmpty, candles.count >= maxBars + 1 else { return [] }

        // Precompute volume SMA if volume filter is on.
        var volSMAs: [Double] = []
        if detectVolume {
            let volPeriod = 20
            volSMAs = [Double](repeating: 0, count: candles.count)
            var volSum: Double = 0
            for i in 0..<candles.count {
                let vol = candles[i].volume ?? 0
                volSum += vol
                if i >= volPeriod {
                    volSum -= candles[i - volPeriod].volume ?? 0
                }
                let activePeriod = min(i + 1, volPeriod)
                volSMAs[i] = volSum / Double(activePeriod)
            }
        }

        // Stage 1: detect zones.
        struct DetectedZone {
            let index: Int
            let high: Double
            let low: Double
            let isBullish: Bool
            let fvgIndex: Int
        }
        var detected: [DetectedZone] = []

        for fvg in fvgZones {
            var obIdx: Int? = nil
            let searchEnd = min(maxBars, fvg.index)
            for j in minBars...searchEnd {
                let ci = fvg.index - j
                guard ci >= 0 else { break }
                let c = candles[ci]
                if fvg.isBullish {
                    if c.close < c.open { obIdx = ci; break }
                } else {
                    if c.close > c.open { obIdx = ci; break }
                }
            }
            guard let idx = obIdx else { continue }

            // Volume filter.
            if detectVolume {
                let obVol = candles[idx].volume ?? 0
                let avgVol = volSMAs[idx]
                guard obVol >= avgVol * volumeMultiplier else { continue }
            }

            let ob = candles[idx]
            detected.append(DetectedZone(
                index: idx, high: ob.high, low: ob.low,
                isBullish: fvg.isBullish, fvgIndex: fvg.index
            ))
        }

        guard !detected.isEmpty else { return [] }

        // Stage 2: single forward pass for exhaustion.
        var testCounts = [Int](repeating: 0, count: detected.count)
        var statuses = [ExhaustionStatus](repeating: .fresh, count: detected.count)

        for ci in 0..<candles.count {
            let c = candles[ci]
            for zi in 0..<detected.count {
                guard statuses[zi] != .exhausted else { continue }
                let z = detected[zi]
                // Only start tracking after the FVG formed.
                guard ci > z.fvgIndex else { continue }

                if z.isBullish {
                    if c.low <= z.high && c.high >= z.low {
                        testCounts[zi] += 1
                        statuses[zi] = .tested
                    }
                    if c.close < z.low {
                        statuses[zi] = .exhausted
                    }
                } else {
                    if c.high >= z.low && c.low <= z.high {
                        testCounts[zi] += 1
                        statuses[zi] = .tested
                    }
                    if c.close > z.high {
                        statuses[zi] = .exhausted
                    }
                }
            }
        }

        // Stage 3: assemble results.
        return (0..<detected.count).map { i in
            let z = detected[i]
            return Zone(
                index: z.index,
                high: z.high,
                low: z.low,
                isBullish: z.isBullish,
                fvgIndex: z.fvgIndex,
                status: statuses[i],
                testCount: testCounts[i]
            )
        }
    }
}

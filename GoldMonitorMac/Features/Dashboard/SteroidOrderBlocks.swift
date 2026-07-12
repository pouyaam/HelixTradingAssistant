import Foundation

/// Steroid Order Blocks — institutional order-block detection enhanced with Volume Profile.
///
/// An Order Block is "on steroids" (highly validated) if it satisfies both the structural
/// trend-reversal conditions of a standard Order Block AND shows high volume validation:
///   1. Structural: Identifies standard Order Blocks (down-candle before an up-run, or up-candle
///      before a down-run).
///   2. Volume Profile Validation: The price range of the order block overlaps with a High Volume
///      Node (HVN) or the Point of Control (POC) of the Volume Profile computed over the lookback period.
///   3. Originating Volume: The originating candle has a volume that is significantly higher than
///      its local average volume (e.g. 1.2x of the 20-period volume SMA).
enum SteroidOrderBlocks {
    
    enum ExhaustionStatus: String, Codable, Hashable {
        case fresh
        case tested
        case exhausted
    }
    
    struct Zone: Identifiable, Hashable {
        /// Bar index of the OB candle within the input series.
        let index: Int
        let high: Double
        let low: Double
        let isBullish: Bool
        let volume: Double
        let volumeAvg: Double
        let hasHighRelativeVolume: Bool
        let hasHVN: Bool
        let quality: Int
        let status: ExhaustionStatus
        let testCount: Int
        
        /// Equilibrium midline.
        var avg: Double { (high + low) / 2 }
        
        var id: String { "\(index)-\(isBullish ? "bull" : "bear")-steroid" }
    }
    
    /// Scan the series for steroid order blocks.
    ///
    /// Uses the shared `OrderBlocks.computeVolumeProfile` helper for
    /// volume-SMA and HVN computation — no duplicate work.
    /// Exhaustion is tracked in a single forward pass (O(n × zones)).
    static func compute(
        _ candles: [Candle],
        periods: Int,
        threshold: Double,
        useWicks: Bool,
        detectSteroids: Bool = true,
        volumeMultiplier: Double = 1.2,
        bucketCount: Int = 30,
        hvnThreshold: Double = 0.70
    ) -> [Zone] {
        // Step 1: Compute standard order blocks (without steroid filtering).
        let standardZones = OrderBlocks.compute(
            candles, periods: periods, threshold: threshold, useWicks: useWicks,
            maxCandidates: 24
        )
        guard !standardZones.isEmpty, !candles.isEmpty else { return [] }

        // Step 2: Validate each block only with information known at its
        // confirmation bar. A global, present-day profile would make past
        // blocks change qualification as new candles arrive.
        struct Candidate {
            let zone: OrderBlocks.Zone
            let obVol: Double
            let avgVol: Double
            let hasHighRelativeVolume: Bool
            let hasHVN: Bool
        }
        var candidates: [Candidate] = []
        for zone in standardZones {
            let obIdx = zone.index
            guard obIdx < candles.count else { continue }
            let vp = OrderBlocks.computeVolumeProfile(
                candles: candles, endIndex: zone.breakIndex, candidateIndex: obIdx,
                bucketCount: bucketCount, hvnThreshold: hvnThreshold
            )
            let obVol = candles[obIdx].volume ?? 0
            let avgVol = vp.priorVolumeSMA ?? 0
            let isHighVolume = obVol > 0 && avgVol > 0 && obVol >= avgVol * volumeMultiplier
            let zoneRange = zone.low...zone.high
            let overlapsHVN = vp.hvnRanges.contains { zoneRange.overlaps($0) }
            // Strict mode requires both independent validators. If the feed
            // has no usable volume, no "Steroid" badge is fabricated.
            if !detectSteroids || (vp.hasReliableVolume && isHighVolume && overlapsHVN) {
                candidates.append(Candidate(zone: zone, obVol: obVol, avgVol: avgVol,
                                            hasHighRelativeVolume: isHighVolume, hasHVN: overlapsHVN))
            }
        }
        guard !candidates.isEmpty else { return [] }

        // Step 4: Single forward pass for exhaustion (same pattern as OrderBlocks).
        var testCounts = [Int](repeating: 0, count: candidates.count)
        var statuses = [ExhaustionStatus](repeating: .fresh, count: candidates.count)

        for ci in 0..<candles.count {
            let c = candles[ci]
            for zi in 0..<candidates.count {
                guard statuses[zi] != .exhausted else { continue }
                let z = candidates[zi].zone
                let startIdx = z.index + periods + 1
                guard ci >= startIdx else { continue }

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

        // Step 5: Assemble results.
        return (0..<candidates.count).map { i in
            let c = candidates[i]
            return Zone(
                index: c.zone.index,
                high: c.zone.high,
                low: c.zone.low,
                isBullish: c.zone.isBullish,
                volume: c.obVol,
                volumeAvg: c.avgVol,
                hasHighRelativeVolume: c.hasHighRelativeVolume,
                hasHVN: c.hasHVN,
                quality: min(100, c.zone.quality + (c.hasHighRelativeVolume ? 12 : 0) + (c.hasHVN ? 13 : 0)),
                status: statuses[i],
                testCount: testCounts[i]
            )
        }
    }
}

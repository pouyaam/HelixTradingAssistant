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
        let status: ExhaustionStatus
        let testCount: Int
        
        /// Equilibrium midline.
        var avg: Double { (high + low) / 2 }
        
        var id: String { "\(index)-\(isBullish ? "bull" : "bear")-steroid" }
    }
    
    /// Scan the series for steroid order blocks.
    ///
    /// - periods:          required run of same-direction candles after the OB (Pine's `periods`, default 5).
    /// - threshold:        minimum % move from the OB close to the last run close (default 0).
    /// - useWicks:         mark the whole high/low range instead of open-low (bull) or open-high (bear).
    /// - volumeMultiplier: factor of local average volume that the originating candle volume must exceed.
    /// - bucketCount:      number of vertical divisions for the Volume Profile (default 30).
    /// - hvnThreshold:     fraction of POC volume that defines a High Volume Node (default 0.70).
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
        // Step 1: Compute standard order blocks
        let standardZones = OrderBlocks.compute(candles, periods: periods, threshold: threshold, useWicks: useWicks)
        guard !standardZones.isEmpty, !candles.isEmpty else { return [] }
        
        // Step 2: Compute a rolling Volume SMA to evaluate the originating candle volume.
        var volSMAs = [Double](repeating: 0, count: candles.count)
        let volPeriod = 20
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
        
        // Step 3: Compute the overall Volume Profile of the series to find High Volume Nodes (HVNs).
        let prices = candles.flatMap { [$0.low, $0.high] }
        guard let priceMin = prices.min(), let priceMax = prices.max(), priceMax > priceMin else { return [] }
        
        let bucketSize = (priceMax - priceMin) / Double(bucketCount)
        var bucketVolumes = [Double](repeating: 0, count: bucketCount)
        
        for c in candles {
            let typical = (c.high + c.low + c.close) / 3
            let idx = min(bucketCount - 1, max(0, Int((typical - priceMin) / bucketSize)))
            let vol = c.volume ?? 0
            bucketVolumes[idx] += vol > 0 ? vol : 1
        }
        
        let maxVol = bucketVolumes.max() ?? 1
        let hvnLimit = maxVol * hvnThreshold
        
        // Build price ranges of High Volume Nodes (HVNs)
        var hvnRanges: [ClosedRange<Double>] = []
        for i in 0..<bucketCount {
            if bucketVolumes[i] >= hvnLimit {
                let rangeMin = priceMin + Double(i) * bucketSize
                let rangeMax = rangeMin + bucketSize
                hvnRanges.append(rangeMin...rangeMax)
            }
        }
        
        // Step 4: Filter standard order blocks down to the ones "on steroids" and calculate their exhaustion status
        var out: [Zone] = []
        for zone in standardZones {
            let obIdx = zone.index
            guard obIdx < candles.count else { continue }
            
            let obCandle = candles[obIdx]
            let obVol = obCandle.volume ?? 0
            let avgVol = volSMAs[obIdx]
            
            // Check if originating candle volume is high (at least above average)
            let isHighVolume = obVol >= avgVol * volumeMultiplier
            
            // Check if price range overlaps with any HVN
            let zoneRange = zone.low...zone.high
            let overlapsHVN = hvnRanges.contains { hvnRange in
                zoneRange.overlaps(hvnRange)
            }
            
            // Validate: sit inside a high volume zone or have high originating volume (or bypass validation if detectSteroids is false)
            if !detectSteroids || isHighVolume || overlapsHVN {
                // Calculate exhaustion status by scanning subsequent candles
                var testCount = 0
                var status = ExhaustionStatus.fresh
                let startIdx = obIdx + periods + 1
                
                if startIdx < candles.count {
                    for k in startIdx..<candles.count {
                        let c = candles[k]
                        let touches = zone.isBullish
                            ? (c.low <= zone.high && c.high >= zone.low)
                            : (c.high >= zone.low && c.low <= zone.high)
                        
                        if touches {
                            testCount += 1
                            status = .tested
                        }
                        
                        // Check for complete exhaustion (price closes through the zone)
                        let closedThrough = zone.isBullish
                            ? (c.close < zone.low)
                            : (c.close > zone.high)
                        
                        if closedThrough {
                            status = .exhausted
                            break
                        }
                    }
                }
                
                out.append(Zone(
                    index: obIdx,
                    high: zone.high,
                    low: zone.low,
                    isBullish: zone.isBullish,
                    volume: obVol,
                    volumeAvg: avgVol,
                    status: status,
                    testCount: testCount
                ))
            }
        }
        
        return out
    }
}

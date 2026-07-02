import Foundation

/// Order Block Finder — institutional order-block detection.
///
/// Ported from wugamlo's PineScript v4 "Order Block Finder". An order
/// block is the last counter-trend candle before a sequential run in the
/// opposite direction:
///   • Bullish OB — the last DOWN candle before `periods` consecutive UP
///     candles. The marked range runs from the candle's low up to its
///     open (or its high when `useWicks`).
///   • Bearish OB — the last UP candle before `periods` consecutive DOWN
///     candles. The marked range runs from the candle's high down to its
///     open (or its low when `useWicks`).
///
/// These levels often mark the origin of a strong move and tend to get
/// revisited, so traders watch them as limit-order zones. Matching the
/// Pine source, detection fires one bar *after* the run completes and the
/// block is anchored back onto the originating candle.
///
/// Pure-function, no state — `ChartView` maps the result into
/// `RectangleMark`s, mirroring how UT Bot / FVG overlays are rendered.
enum OrderBlocks {
    /// One detected order block, anchored at the originating candle's bar
    /// index. `high`/`low` bound the marked range; `avg` is the
    /// equilibrium midline the Pine plots as a solid channel.
    enum ExhaustionStatus: String, Codable, Hashable {
        case fresh
        case tested
        case exhausted
    }

    /// One detected order block, anchored at the originating candle's bar
    /// index. `high`/`low` bound the marked range; `avg` is the
    /// equilibrium midline the Pine plots as a solid channel.
    struct Zone: Identifiable, Hashable {
        /// Bar index of the OB candle within the input series.
        let index: Int
        let high: Double
        let low: Double
        let isBullish: Bool
        let status: ExhaustionStatus
        let testCount: Int

        /// Equilibrium — the average of the block's two edges. An
        /// interesting interaction level in its own right (Pine draws it
        /// as the solid channel line).
        var avg: Double { (high + low) / 2 }

        var id: String { "\(index)-\(isBullish ? "bull" : "bear")" }
    }

    /// Scan the series for order blocks.
    ///
    /// - periods:   required run of same-direction candles after the OB
    ///              candle (Pine's `periods`, default 5).
    /// - threshold: minimum % move from the OB close to the last run
    ///              candle's close for the block to validate (Pine's
    ///              `threshold`, default 0 ⇒ no filter).
    /// - useWicks:  mark the whole high/low range instead of open→low
    ///              (bull) / open→high (bear). Pine's `usewicks`.
    static func compute(
        _ candles: [Candle],
        periods: Int,
        threshold: Double,
        useWicks: Bool,
        detectSteroids: Bool = false,
        volumeMultiplier: Double = 1.2,
        bucketCount: Int = 30,
        hvnThreshold: Double = 0.70
    ) -> [Zone] {
        // Need the OB candle + its run + one evaluation bar.
        guard periods >= 1, candles.count >= periods + 2 else { return [] }
        var out: [Zone] = []
        let n = candles.count

        // Precompute Volume SMA & HVNs if detectSteroids is true
        var volSMAs = [Double](repeating: 0, count: candles.count)
        var hvnRanges: [ClosedRange<Double>] = []
        
        if detectSteroids {
            // Step 2: Compute a rolling Volume SMA
            var volSum: Double = 0
            let volPeriod = 20
            for i in 0..<candles.count {
                let vol = candles[i].volume ?? 0
                volSum += vol
                if i >= volPeriod {
                    volSum -= candles[i - volPeriod].volume ?? 0
                }
                let activePeriod = min(i + 1, volPeriod)
                volSMAs[i] = volSum / Double(activePeriod)
            }
            
            // Step 3: Compute Volume Profile
            let prices = candles.flatMap { [$0.low, $0.high] }
            if let priceMin = prices.min(), let priceMax = prices.max(), priceMax > priceMin {
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
                
                for i in 0..<bucketCount {
                    if bucketVolumes[i] >= hvnLimit {
                        let rangeMin = priceMin + Double(i) * bucketSize
                        let rangeMax = rangeMin + bucketSize
                        hvnRanges.append(rangeMin...rangeMax)
                    }
                }
            }
        }

        // `e` is the evaluation bar (Pine's "current" bar, offset 0). The
        // OB candle sits `periods + 1` bars back; the run occupies the
        // `periods` bars between them (indices obIdx+1 ... e-1).
        for e in (periods + 1)..<n {
            let obIdx = e - (periods + 1)
            let ob = candles[obIdx]
            guard ob.close != 0 else { continue }

            // % move from the OB close to the last run candle (Pine's
            // `close[1]`, i.e. the bar just before the evaluation bar).
            let absMove = abs(ob.close - candles[e - 1].close) / ob.close * 100
            guard absMove >= threshold else { continue }

            // Count the direction of the `periods` run candles. A doji
            // (close == open) counts as neither, so it breaks the run —
            // same as the Pine `close[i] > open[i] ? 1 : 0` accumulation.
            var up = 0, down = 0
            for k in (obIdx + 1)...(e - 1) {
                if candles[k].close > candles[k].open { up += 1 }
                else if candles[k].close < candles[k].open { down += 1 }
            }

            // Bullish OB: a down candle followed by an all-up run.
            if ob.close < ob.open, up == periods {
                let zHigh = useWicks ? ob.high : ob.open
                let zLow = ob.low
                
                if detectSteroids {
                    let obVol = ob.volume ?? 0
                    let avgVol = volSMAs[obIdx]
                    let isHighVolume = obVol >= avgVol * volumeMultiplier
                    let zoneRange = zLow...zHigh
                    let overlapsHVN = hvnRanges.contains { zoneRange.overlaps($0) }
                    guard isHighVolume || overlapsHVN else { continue }
                }
                
                var testCount = 0
                var status = ExhaustionStatus.fresh
                let startIdx = obIdx + periods + 1
                if startIdx < candles.count {
                    for k in startIdx..<candles.count {
                        let c = candles[k]
                        if c.low <= zHigh && c.high >= zLow {
                            testCount += 1
                            status = .tested
                        }
                        if c.close < zLow {
                            status = .exhausted
                            break
                        }
                    }
                }
                
                out.append(Zone(
                    index: obIdx,
                    high: zHigh,
                    low: zLow,
                    isBullish: true,
                    status: status,
                    testCount: testCount
                ))
            }
            // Bearish OB: an up candle followed by an all-down run.
            else if ob.close > ob.open, down == periods {
                let zHigh = ob.high
                let zLow = useWicks ? ob.low : ob.open
                
                if detectSteroids {
                    let obVol = ob.volume ?? 0
                    let avgVol = volSMAs[obIdx]
                    let isHighVolume = obVol >= avgVol * volumeMultiplier
                    let zoneRange = zLow...zHigh
                    let overlapsHVN = hvnRanges.contains { zoneRange.overlaps($0) }
                    guard isHighVolume || overlapsHVN else { continue }
                }
                
                var testCount = 0
                var status = ExhaustionStatus.fresh
                let startIdx = obIdx + periods + 1
                if startIdx < candles.count {
                    for k in startIdx..<candles.count {
                        let c = candles[k]
                        if c.high >= zLow && c.low <= zHigh {
                            testCount += 1
                            status = .tested
                        }
                        if c.close > zHigh {
                            status = .exhausted
                            break
                        }
                    }
                }
                
                out.append(Zone(
                    index: obIdx,
                    high: zHigh,
                    low: zLow,
                    isBullish: false,
                    status: status,
                    testCount: testCount
                ))
            }
        }
        return out
    }
}

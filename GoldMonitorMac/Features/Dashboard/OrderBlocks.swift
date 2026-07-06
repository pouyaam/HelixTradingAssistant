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

    // MARK: - Shared Volume Profile Helpers

    /// Pre-computed volume profile data shared between `OrderBlocks` and
    /// `SteroidOrderBlocks` so the HVN / volume-SMA work is done once.
    struct VolumeProfileData {
        let volumeSMAs: [Double]
        let hvnRanges: [ClosedRange<Double>]
    }

    /// Compute a rolling 20-period volume SMA and identify High Volume
    /// Nodes (price ranges whose accumulated volume ≥ `hvnThreshold`
    /// of the peak bucket). Used by both OrderBlocks (when
    /// `detectSteroids` is true) and SteroidOrderBlocks.
    static func computeVolumeProfile(
        candles: [Candle],
        bucketCount: Int = 30,
        hvnThreshold: Double = 0.70
    ) -> VolumeProfileData {
        // Rolling volume SMA (period 20).
        let volPeriod = 20
        var volSMAs = [Double](repeating: 0, count: candles.count)
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

        // Volume Profile — bucket typical price into equal bands.
        let prices = candles.flatMap { [$0.low, $0.high] }
        var hvnRanges: [ClosedRange<Double>] = []
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
                    hvnRanges.append(rangeMin...rangeMin + bucketSize)
                }
            }
        }
        return VolumeProfileData(volumeSMAs: volSMAs, hvnRanges: hvnRanges)
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
        let n = candles.count

        // ── Precompute Volume SMA & HVNs (if detectSteroids) ────────
        let vpData: VolumeProfileData? = detectSteroids
            ? computeVolumeProfile(candles: candles, bucketCount: bucketCount, hvnThreshold: hvnThreshold)
            : nil
        let volSMAs = vpData?.volumeSMAs ?? []
        let hvnRanges = vpData?.hvnRanges ?? []

        // ── Stage 1: detect zones ──────────────────────────────────
        // Each zone starts as `.fresh`; stage 2 updates status.
        struct DetectedZone {
            let index: Int
            let high: Double
            let low: Double
            let isBullish: Bool
        }
        var detected: [DetectedZone] = []

        for e in (periods + 1)..<n {
            let obIdx = e - (periods + 1)
            let ob = candles[obIdx]
            guard ob.close != 0 else { continue }

            let absMove = abs(ob.close - candles[e - 1].close) / ob.close * 100
            guard absMove >= threshold else { continue }

            var up = 0, down = 0
            for k in (obIdx + 1)...(e - 1) {
                if candles[k].close > candles[k].open { up += 1 }
                else if candles[k].close < candles[k].open { down += 1 }
            }

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
                detected.append(DetectedZone(index: obIdx, high: zHigh, low: zLow, isBullish: true))
            }
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
                detected.append(DetectedZone(index: obIdx, high: zHigh, low: zLow, isBullish: false))
            }
        }

        guard !detected.isEmpty else { return [] }

        // ── Stage 2: single forward pass for exhaustion ────────────
        // Walk each candle once, updating test counts and exhaustion
        // status for every zone simultaneously. O(n × zones) total but
        // each candle is visited once — eliminates the prior O(n²) that
        // re-scanned the tail for every zone independently.
        var testCounts = [Int](repeating: 0, count: detected.count)
        var statuses = [ExhaustionStatus](repeating: .fresh, count: detected.count)

        for ci in 0..<candles.count {
            let c = candles[ci]
            for zi in 0..<detected.count {
                guard statuses[zi] != .exhausted else { continue }
                let z = detected[zi]
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

        // ── Assemble results ───────────────────────────────────────
        return (0..<detected.count).map { i in
            let z = detected[i]
            return Zone(
                index: z.index,
                high: z.high,
                low: z.low,
                isBullish: z.isBullish,
                status: statuses[i],
                testCount: testCounts[i]
            )
        }
    }
}

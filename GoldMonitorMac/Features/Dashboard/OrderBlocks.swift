import Foundation

/// Non-repainting order-block detector. A block is the final opposing candle
/// before a directional displacement which also breaks the recent structure.
/// The old colour-run rule is intentionally retained only as a minimum
/// impulse-shape filter; colour alone is never sufficient to create a zone.
enum OrderBlocks {
    enum ExhaustionStatus: String, Codable, Hashable { case fresh, tested, exhausted }

    struct Zone: Identifiable, Hashable {
        let index: Int
        let breakIndex: Int
        let high: Double
        let low: Double
        let isBullish: Bool
        let impulseATR: Double
        /// 0…100, based on structural break + displacement strength.
        let quality: Int
        let status: ExhaustionStatus
        let testCount: Int
        var avg: Double { (high + low) / 2 }
        var id: String { "\(index)-\(isBullish ? "bull" : "bear")" }
    }

    struct VolumeProfileData {
        let priorVolumeSMA: Double?
        let hvnRanges: [ClosedRange<Double>]
        let hasReliableVolume: Bool
    }

    /// A profile computed from `lookback` candles ending at `endIndex`.
    /// No data after `endIndex` is read, so historic qualification cannot
    /// repaint as future candles arrive.
    static func computeVolumeProfile(
        candles: [Candle], endIndex: Int? = nil, candidateIndex: Int? = nil, lookback: Int = 120,
        bucketCount: Int = 30, hvnThreshold: Double = 0.70
    ) -> VolumeProfileData {
        guard !candles.isEmpty else { return .init(priorVolumeSMA: nil, hvnRanges: [], hasReliableVolume: false) }
        let end = min(max(endIndex ?? candles.count - 1, 0), candles.count - 1)
        let start = max(0, end - max(lookback, 20) + 1)
        let sample = Array(candles[start...end])

        // Baseline deliberately excludes the candidate candle itself.
        var rolling: [Double] = []
        var candidateAverage: Double?
        for i in max(0, start - 20)...end {
            let prior = rolling.suffix(20)
            if i == candidateIndex, prior.count >= 10 {
                candidateAverage = prior.reduce(0, +) / Double(prior.count)
            }
            if let volume = candles[i].volume, volume > 0 { rolling.append(volume) }
        }

        let volumeCandles = sample.filter { ($0.volume ?? 0) > 0 }
        guard volumeCandles.count >= max(10, sample.count / 3) else {
            return .init(priorVolumeSMA: candidateAverage, hvnRanges: [], hasReliableVolume: false)
        }
        let minPrice = sample.map(\.low).min()!, maxPrice = sample.map(\.high).max()!
        guard maxPrice > minPrice else { return .init(priorVolumeSMA: candidateAverage, hvnRanges: [], hasReliableVolume: true) }
        let size = (maxPrice - minPrice) / Double(max(1, bucketCount))
        var buckets = [Double](repeating: 0, count: max(1, bucketCount))
        // Spread a candle's volume across every crossed price bucket instead
        // of putting all of it at one typical price.
        for candle in volumeCandles {
            let lower = max(0, min(buckets.count - 1, Int((candle.low - minPrice) / size)))
            let upper = max(0, min(buckets.count - 1, Int((candle.high - minPrice) / size)))
            let share = (candle.volume ?? 0) / Double(upper - lower + 1)
            for bucket in lower...upper { buckets[bucket] += share }
        }
        let floor = (buckets.max() ?? 0) * hvnThreshold
        let ranges = buckets.indices.compactMap { i -> ClosedRange<Double>? in
            guard buckets[i] >= floor, floor > 0 else { return nil }
            let low = minPrice + Double(i) * size
            return low...min(maxPrice, low + size)
        }
        return .init(priorVolumeSMA: candidateAverage, hvnRanges: ranges, hasReliableVolume: true)
    }

    static func compute(
        _ candles: [Candle], periods: Int, threshold: Double, useWicks: Bool,
        detectSteroids: Bool = false, volumeMultiplier: Double = 1.2,
        bucketCount: Int = 30, hvnThreshold: Double = 0.70,
        atrMultiplier: Double = 0.8, maxCandidates: Int = 64
    ) -> [Zone] {
        guard periods >= 1, candles.count >= periods + 3 else { return [] }
        let atr = atrSeries(candles, period: 14)
        var detected: [(index: Int, breakIndex: Int, high: Double, low: Double, bullish: Bool, impulseATR: Double, quality: Int)] = []

        for index in 0..<(candles.count - periods - 1) {
            let origin = candles[index]
            let breakIndex = index + periods
            guard let atrValue = atr[breakIndex], atrValue > 0 else { continue }
            let close = candles[breakIndex].close
            let bullish = origin.close < origin.open
            let bearish = origin.close > origin.open
            guard bullish || bearish else { continue }

            let directionalCandles = candles[(index + 1)...breakIndex].filter {
                bullish ? $0.close > $0.open : $0.close < $0.open
            }.count
            // Strong moves may contain a small pause; demand a decisive
            // majority rather than an unrealistically perfect colour run.
            guard directionalCandles >= max(1, Int(ceil(Double(periods) * 0.7))) else { continue }
            let move = bullish ? close - origin.close : origin.close - close
            guard move > 0, move >= atrValue * atrMultiplier else { continue }
            let movePct = move / max(abs(origin.close), .leastNonzeroMagnitude) * 100
            guard movePct >= threshold else { continue }

            let structureStart = max(0, index - periods)
            let prior = candles[structureStart...index]
            let brokeStructure = bullish
                ? close > prior.map(\.high).max()!
                : close < prior.map(\.low).min()!
            guard brokeStructure else { continue }

            let high = bullish ? (useWicks ? origin.high : origin.open) : origin.high
            let low = bullish ? origin.low : (useWicks ? origin.low : origin.open)
            let strength = min(25, Int((move / atrValue - atrMultiplier) * 10))
            let quality = min(100, 75 + max(0, strength)) // structure + ATR are mandatory
            detected.append((index, breakIndex, high, low, bullish, move / atrValue, quality))
        }

        // Lifecycle scanning is proportional to candidates × bars. The chart
        // only renders recent actionable blocks, so bound historical work.
        detected = Array(detected.suffix(max(1, maxCandidates)))
        if detectSteroids {
            detected = detected.filter { candidate in
                let vp = computeVolumeProfile(candles: candles, endIndex: candidate.breakIndex, candidateIndex: candidate.index, bucketCount: bucketCount, hvnThreshold: hvnThreshold)
                guard vp.hasReliableVolume,
                      let average = vp.priorVolumeSMA, average > 0,
                      let volume = candles[candidate.index].volume, volume > 0 else { return false }
                let highVolume = volume >= average * volumeMultiplier
                let inHVN = vp.hvnRanges.contains { (candidate.low...candidate.high).overlaps($0) }
                return highVolume && inHVN
            }
        }
        return applyLifecycle(candles: candles, detected: detected)
    }

    private static func applyLifecycle(
        candles: [Candle],
        detected: [(index: Int, breakIndex: Int, high: Double, low: Double, bullish: Bool, impulseATR: Double, quality: Int)]
    ) -> [Zone] {
        detected.map { item in
            var status: ExhaustionStatus = .fresh, tests = 0
            if item.breakIndex + 1 < candles.count {
                for candle in candles[(item.breakIndex + 1)...] {
                    if candle.low <= item.high && candle.high >= item.low { tests += 1; status = .tested }
                    if item.bullish ? candle.close < item.low : candle.close > item.high { status = .exhausted; break }
                }
            }
            return Zone(index: item.index, breakIndex: item.breakIndex, high: item.high, low: item.low,
                        isBullish: item.bullish, impulseATR: item.impulseATR, quality: item.quality,
                        status: status, testCount: tests)
        }
    }

    private static func atrSeries(_ candles: [Candle], period: Int) -> [Double?] {
        var output = [Double?](repeating: nil, count: candles.count), ranges: [Double] = []
        for i in candles.indices {
            let previous = i > 0 ? candles[i - 1].close : candles[i].close
            ranges.append(max(candles[i].high - candles[i].low, abs(candles[i].high - previous), abs(candles[i].low - previous)))
            guard i >= period - 1 else { continue }
            output[i] = ranges[(i - period + 1)...i].reduce(0, +) / Double(period)
        }
        return output
    }
}

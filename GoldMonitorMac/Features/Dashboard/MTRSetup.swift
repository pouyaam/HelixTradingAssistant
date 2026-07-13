import Foundation

/// Al Brooks-style Major Trend Reversal detector.
///
/// The detector deliberately uses confirmed price pivots rather than an
/// oscillator or moving average: established channel -> close-confirmed
/// channel break -> test of the old extreme -> neckline break. Results are
/// deterministic over raw OHLC candles and safe to reuse for chart overlays,
/// replay, notifications and unit tests.
enum MTRSetup {
    enum Direction: String, Hashable, Codable {
        case long
        case short
    }

    enum Variant: String, Hashable, Codable {
        case higherLow
        case doubleBottom
        case lowerLow
        case lowerHigh
        case doubleTop
        case higherHigh

        var label: String {
            switch self {
            case .higherLow:    return "Higher Low"
            case .doubleBottom: return "Double Bottom"
            case .lowerLow:     return "Lower Low"
            case .lowerHigh:    return "Lower High"
            case .doubleTop:    return "Double Top"
            case .higherHigh:   return "Higher High"
            }
        }
    }

    enum Stage: String, Hashable, Codable {
        case forming
        case confirmed
        case hitTP
        case hitSL
        case expired
    }

    struct Configuration: Hashable, Sendable {
        var pivotDepth = 3
        var atrPeriod = 14
        var minTrendLegATR = 1.0
        var breakBufferATR = 0.10
        var retestToleranceATR = 0.25
        var maxFailedBreakATR = 0.75
        var maxRetestBars = 20
        var maxConfirmationBars = 20
        var stopBufferATR = 0.10
        var riskReward = 2.0
        var maxTradeBars = 50
        var maxResults = 12
    }

    struct Result: Identifiable, Hashable {
        let direction: Direction
        let variant: Variant

        let channelStartIndex: Int
        let channelEndIndex: Int
        let channelStartPrice: Double
        let channelEndPrice: Double
        let parallelStartPrice: Double
        let parallelEndPrice: Double

        let trendExtremeIndex: Int
        let trendExtremePrice: Double
        let breakoutIndex: Int
        let retestIndex: Int
        let retestPrice: Double
        let neckline: Double

        var confirmationIndex: Int?
        var entry: Double?
        var stopLoss: Double?
        var takeProfit: Double?
        var resolveIndex: Int?
        var stage: Stage

        var id: String {
            "\(direction.rawValue)-\(channelStartIndex)-\(channelEndIndex)-\(breakoutIndex)-\(retestIndex)"
        }

        var isConfirmed: Bool { confirmationIndex != nil }
        var hasPlan: Bool { entry != nil && stopLoss != nil && takeProfit != nil }
        var lastRelevantIndex: Int {
            resolveIndex ?? confirmationIndex ?? retestIndex
        }
    }

    private struct Pivot: Hashable {
        let index: Int
        let price: Double
        let isHigh: Bool
    }

    static func compute(
        _ candles: [Candle],
        configuration raw: Configuration = Configuration()
    ) -> [Result] {
        let config = sanitized(raw)
        let minimumBars = max(config.atrPeriod + 2, config.pivotDepth * 2 + 6)
        guard candles.count >= minimumBars else { return [] }

        let atr = atrSeries(candles, period: config.atrPeriod)
        let pivots = confirmedPivots(
            candles,
            atr: atr,
            depth: config.pivotDepth,
            minLegATR: config.minTrendLegATR
        )
        guard pivots.count >= 4 else { return [] }

        var output: [Result] = []
        var seen = Set<String>()

        for start in 0...(pivots.count - 4) {
            let sequence = Array(pivots[start..<(start + 4)])
            guard let trend = trendCandidate(sequence) else { continue }
            guard let candidate = makeResult(
                candles: candles,
                atr: atr,
                pivots: pivots,
                trend: trend,
                config: config
            ) else { continue }
            guard seen.insert(candidate.id).inserted else { continue }
            output.append(candidate)
        }

        output.sort {
            if $0.retestIndex == $1.retestIndex {
                return $0.breakoutIndex < $1.breakoutIndex
            }
            return $0.retestIndex < $1.retestIndex
        }
        return Array(output.suffix(config.maxResults))
    }

    private struct TrendCandidate {
        let direction: Direction
        let lineStart: Pivot
        let lineEnd: Pivot
        let oppositePivots: [Pivot]
        let extreme: Pivot
    }

    private static func trendCandidate(_ p: [Pivot]) -> TrendCandidate? {
        guard p.count == 4 else { return nil }

        // Bear channel: lower high, lower low -> hunt a bullish MTR.
        if p[0].isHigh, !p[1].isHigh, p[2].isHigh, !p[3].isHigh,
           p[2].price < p[0].price,
           p[3].price < p[1].price {
            return TrendCandidate(
                direction: .long,
                lineStart: p[0],
                lineEnd: p[2],
                oppositePivots: [p[1], p[3]],
                extreme: p[3]
            )
        }

        // Bull channel: higher low, higher high -> hunt a bearish MTR.
        if !p[0].isHigh, p[1].isHigh, !p[2].isHigh, p[3].isHigh,
           p[2].price > p[0].price,
           p[3].price > p[1].price {
            return TrendCandidate(
                direction: .short,
                lineStart: p[0],
                lineEnd: p[2],
                oppositePivots: [p[1], p[3]],
                extreme: p[3]
            )
        }
        return nil
    }

    private static func makeResult(
        candles: [Candle],
        atr: [Double?],
        pivots: [Pivot],
        trend: TrendCandidate,
        config: Configuration
    ) -> Result? {
        let slope = (trend.lineEnd.price - trend.lineStart.price)
            / Double(trend.lineEnd.index - trend.lineStart.index)
        func linePrice(at index: Int) -> Double {
            trend.lineStart.price + slope * Double(index - trend.lineStart.index)
        }

        let offsets = trend.oppositePivots.map { $0.price - linePrice(at: $0.index) }
        let parallelOffset = trend.direction == .long
            ? (offsets.min() ?? 0)
            : (offsets.max() ?? 0)

        let lastConfirmedPivotIndex = max(0, candles.count - config.pivotDepth - 1)
        let breakoutUpper = min(
            candles.count - 1,
            trend.extreme.index + config.maxRetestBars
        )
        guard trend.extreme.index + 1 <= breakoutUpper else { return nil }

        var breakoutIndex: Int?
        for index in (trend.extreme.index + 1)...breakoutUpper {
            guard let currentATR = atr[index], currentATR > 0 else { continue }
            let buffer = currentATR * config.breakBufferATR
            let boundary = linePrice(at: index)
            let broke = trend.direction == .long
                ? candles[index].close > boundary + buffer
                : candles[index].close < boundary - buffer
            if broke { breakoutIndex = index; break }
        }
        guard let breakoutIndex else { return nil }

        let retestDeadline = min(lastConfirmedPivotIndex, breakoutIndex + config.maxRetestBars)
        guard retestDeadline > breakoutIndex else { return nil }
        let matchingPivots = pivots.filter {
            $0.index > breakoutIndex &&
            $0.index <= retestDeadline &&
            $0.isHigh == (trend.direction == .short)
        }
        let classifiedRetest = matchingPivots.lazy.compactMap { pivot -> (Pivot, Variant)? in
            let referenceIndex = max(0, pivot.index - 1)
            guard let retestATR = atr[referenceIndex] ?? atr[pivot.index], retestATR > 0,
                  let variant = classifyRetest(
                    candles: candles,
                    direction: trend.direction,
                    oldExtreme: trend.extreme.price,
                    retest: pivot,
                    atr: retestATR,
                    config: config
                  )
            else { return nil }
            return (pivot, variant)
        }.first
        guard let (retest, variant) = classifiedRetest else { return nil }

        let between = candles[trend.extreme.index...retest.index]
        let neckline = trend.direction == .long
            ? (between.map(\.high).max() ?? candles[breakoutIndex].high)
            : (between.map(\.low).min() ?? candles[breakoutIndex].low)

        var result = Result(
            direction: trend.direction,
            variant: variant,
            channelStartIndex: trend.lineStart.index,
            channelEndIndex: trend.lineEnd.index,
            channelStartPrice: trend.lineStart.price,
            channelEndPrice: trend.lineEnd.price,
            parallelStartPrice: trend.lineStart.price + parallelOffset,
            parallelEndPrice: trend.lineEnd.price + parallelOffset,
            trendExtremeIndex: trend.extreme.index,
            trendExtremePrice: trend.extreme.price,
            breakoutIndex: breakoutIndex,
            retestIndex: retest.index,
            retestPrice: retest.price,
            neckline: neckline,
            stage: .forming
        )

        let confirmationUpper = min(candles.count - 1, retest.index + config.maxConfirmationBars)
        if retest.index + 1 <= confirmationUpper {
            for index in (retest.index + 1)...confirmationUpper {
                guard let currentATR = atr[index], currentATR > 0 else { continue }
                let buffer = currentATR * config.breakBufferATR
                let confirmed = trend.direction == .long
                    ? candles[index].close > neckline + buffer
                    : candles[index].close < neckline - buffer
                guard confirmed else { continue }
                applyTradePlan(
                    &result,
                    candles: candles,
                    atr: atr,
                    confirmationIndex: index,
                    config: config
                )
                break
            }
        }

        if result.confirmationIndex == nil,
           candles.count - 1 >= retest.index + config.maxConfirmationBars {
            result.stage = .expired
            result.resolveIndex = retest.index + config.maxConfirmationBars
        }
        return result
    }

    private static func classifyRetest(
        candles: [Candle],
        direction: Direction,
        oldExtreme: Double,
        retest: Pivot,
        atr: Double,
        config: Configuration
    ) -> Variant? {
        let tolerance = atr * config.retestToleranceATR
        let maximumDistance = atr * config.maxFailedBreakATR
        let delta = retest.price - oldExtreme

        switch direction {
        case .long:
            if delta > tolerance, delta <= maximumDistance { return .higherLow }
            if abs(delta) <= tolerance { return .doubleBottom }
            if delta < -tolerance,
               delta >= -maximumDistance,
               candles[retest.index].close > oldExtreme {
                return .lowerLow
            }
        case .short:
            if delta < -tolerance, delta >= -maximumDistance { return .lowerHigh }
            if abs(delta) <= tolerance { return .doubleTop }
            if delta > tolerance,
               delta <= maximumDistance,
               candles[retest.index].close < oldExtreme {
                return .higherHigh
            }
        }
        return nil
    }

    private static func applyTradePlan(
        _ result: inout Result,
        candles: [Candle],
        atr: [Double?],
        confirmationIndex: Int,
        config: Configuration
    ) {
        guard let currentATR = atr[confirmationIndex], currentATR > 0 else { return }
        let entry = candles[confirmationIndex].close
        let stop = result.direction == .long
            ? result.retestPrice - currentATR * config.stopBufferATR
            : result.retestPrice + currentATR * config.stopBufferATR
        let risk = abs(entry - stop)
        guard risk > 0 else { return }
        let target = result.direction == .long
            ? entry + risk * config.riskReward
            : entry - risk * config.riskReward

        result.confirmationIndex = confirmationIndex
        result.entry = entry
        result.stopLoss = stop
        result.takeProfit = target
        result.stage = .confirmed

        let upper = min(candles.count - 1, confirmationIndex + config.maxTradeBars)
        guard confirmationIndex + 1 <= upper else { return }
        for index in (confirmationIndex + 1)...upper {
            let hitStop = result.direction == .long
                ? candles[index].low <= stop
                : candles[index].high >= stop
            let hitTarget = result.direction == .long
                ? candles[index].high >= target
                : candles[index].low <= target
            // Conservative for a candle that touches both levels.
            if hitStop {
                result.stage = .hitSL
                result.resolveIndex = index
                return
            }
            if hitTarget {
                result.stage = .hitTP
                result.resolveIndex = index
                return
            }
        }
        if candles.count - 1 >= confirmationIndex + config.maxTradeBars {
            result.stage = .expired
            result.resolveIndex = confirmationIndex + config.maxTradeBars
        }
    }

    private static func confirmedPivots(
        _ candles: [Candle],
        atr: [Double?],
        depth: Int,
        minLegATR: Double
    ) -> [Pivot] {
        guard candles.count >= depth * 2 + 1 else { return [] }
        var raw: [Pivot] = []
        for index in depth..<(candles.count - depth) {
            let range = (index - depth)...(index + depth)
            let high = candles[index].high
            let low = candles[index].low
            let isHigh = range.allSatisfy { $0 == index || candles[$0].high < high }
            let isLow = range.allSatisfy { $0 == index || candles[$0].low > low }
            if isHigh { raw.append(Pivot(index: index, price: high, isHigh: true)) }
            if isLow { raw.append(Pivot(index: index, price: low, isHigh: false)) }
        }
        raw.sort { $0.index < $1.index }

        var alternating: [Pivot] = []
        for pivot in raw {
            guard let last = alternating.last else {
                alternating.append(pivot)
                continue
            }
            if pivot.isHigh == last.isHigh {
                let moreExtreme = pivot.isHigh
                    ? pivot.price > last.price
                    : pivot.price < last.price
                if moreExtreme { alternating[alternating.count - 1] = pivot }
                continue
            }
            let referenceATR = atr[pivot.index] ?? atr[last.index] ?? 0
            guard abs(pivot.price - last.price) >= referenceATR * minLegATR else { continue }
            alternating.append(pivot)
        }
        return alternating
    }

    private static func sanitized(_ raw: Configuration) -> Configuration {
        var config = raw
        config.pivotDepth = max(1, raw.pivotDepth)
        config.atrPeriod = max(1, raw.atrPeriod)
        config.minTrendLegATR = max(0, raw.minTrendLegATR)
        config.breakBufferATR = max(0, raw.breakBufferATR)
        config.retestToleranceATR = max(0, raw.retestToleranceATR)
        config.maxFailedBreakATR = max(config.retestToleranceATR, raw.maxFailedBreakATR)
        config.maxRetestBars = max(1, raw.maxRetestBars)
        config.maxConfirmationBars = max(1, raw.maxConfirmationBars)
        config.stopBufferATR = max(0, raw.stopBufferATR)
        config.riskReward = max(0.1, raw.riskReward)
        config.maxTradeBars = max(1, raw.maxTradeBars)
        config.maxResults = max(1, raw.maxResults)
        return config
    }

    private static func atrSeries(_ candles: [Candle], period: Int) -> [Double?] {
        guard !candles.isEmpty else { return [] }
        let p = max(1, period)
        var trueRanges = [Double](repeating: 0, count: candles.count)
        for index in candles.indices {
            if index == 0 {
                trueRanges[index] = candles[index].high - candles[index].low
            } else {
                trueRanges[index] = max(
                    candles[index].high - candles[index].low,
                    abs(candles[index].high - candles[index - 1].close),
                    abs(candles[index].low - candles[index - 1].close)
                )
            }
        }
        var output = [Double?](repeating: nil, count: candles.count)
        guard candles.count >= p else { return output }
        var value = trueRanges[0..<p].reduce(0, +) / Double(p)
        output[p - 1] = value
        if p < candles.count {
            for index in p..<candles.count {
                value = (value * Double(p - 1) + trueRanges[index]) / Double(p)
                output[index] = value
            }
        }
        return output
    }
}

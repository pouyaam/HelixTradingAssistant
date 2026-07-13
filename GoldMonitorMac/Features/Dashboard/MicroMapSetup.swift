import Foundation

/// Deterministic MicroMap continuation detector.
///
/// A directional spike is followed by a weak counter-trend micro-channel.
/// The first close outside that channel starts attempt one. After a stopped
/// attempt, one complete anchor candle must close before the next breakout can
/// trigger. Three stopped attempts invalidate the setup.
enum MicroMapSetup {
    enum Direction: String, Hashable, Codable {
        case long
        case short
    }

    enum Stage: String, Hashable, Codable {
        case awaitingFirstEntry
        case awaitingReentry
        case active
        case succeeded
        case expired
        case invalidated
    }

    enum AttemptStatus: String, Hashable, Codable {
        case waiting
        case active
        case stopped
        case succeeded
    }

    enum EndReason: String, Hashable, Codable {
        case targetHit
        case reentryExpired
        case threeStops
    }

    enum Quality: String, Hashable, Codable {
        case standard
        case confirmed
        case strong
    }

    struct PressureGap: Hashable {
        let startIndex: Int
        let endIndex: Int
        let low: Double
        let high: Double
    }

    struct Confluence: Hashable {
        let pressureGap: PressureGap?
        let brokeKeyLevel: Bool
        let trendAligned: Bool
        let liquidSession: Bool
        let score: Int

        var quality: Quality {
            if score >= 5 { return .strong }
            if score >= 3 { return .confirmed }
            return .standard
        }
    }

    struct Configuration: Equatable, Sendable {
        var atrPeriod = 14
        var minSpikeBars = 2
        var maxSpikeBars = 6
        var minSpikeATR = 1.5
        var minDirectionalRatio = 0.65
        var minBodyRatio = 0.60
        var maxCloseFromExtreme = 0.25
        var minMicroBars = 2
        var maxMicroBars = 8
        var maxMicroRangeRatio = 0.70
        var maxRetracement = 0.60
        var structureToleranceATR = 0.10
        var maxReentryBars = 8
        var riskReward = 2.0
        var confluenceBalanceBars = 4
        var confluenceEMAPeriod = 60
        var minPressureGapPct = 0.0
        var maxPressureGapBar = 3
        var requirePressureGap = false
        var requireKeyLevelBreak = false
        var minConfluenceScore = 0
    }

    struct Attempt: Identifiable, Hashable {
        let number: Int
        let anchorIndex: Int?
        let triggerLevel: Double
        var triggerIndex: Int? = nil
        var entry: Double? = nil
        var stopLoss: Double? = nil
        var takeProfit: Double? = nil
        var stopIndex: Int? = nil
        var targetIndex: Int? = nil
        var status: AttemptStatus

        var id: Int { number }
    }

    struct Result: Identifiable, Hashable {
        let id: String
        let direction: Direction
        let spikeStartIndex: Int
        let spikeEndIndex: Int
        let spikeLow: Double
        let spikeHigh: Double
        let microStartIndex: Int
        let microEndIndex: Int
        let score: Double
        let confluence: Confluence
        var attempts: [Attempt]
        var stage: Stage
        var endIndex: Int? = nil
        var endReason: EndReason? = nil

        var hasTriggeredEntry: Bool {
            attempts.contains { $0.triggerIndex != nil }
        }

        var lastRelevantIndex: Int {
            endIndex
                ?? attempts.compactMap(\.targetIndex).max()
                ?? attempts.compactMap(\.stopIndex).max()
                ?? attempts.compactMap(\.triggerIndex).max()
                ?? microEndIndex
        }
    }

    static func compute(
        _ candles: [Candle],
        configuration raw: Configuration = Configuration(),
        maxResults: Int = 24
    ) -> [Result] {
        let config = normalized(raw)
        guard candles.count >= config.atrPeriod + config.minSpikeBars + config.minMicroBars + 1 else {
            return []
        }

        let atr = atrSeries(candles, period: config.atrPeriod)
        let confluenceEMA = emaSeries(candles, period: config.confluenceEMAPeriod)
        var candidates: [Result] = []

        for start in candles.indices {
            for count in config.minSpikeBars...config.maxSpikeBars {
                let end = start + count - 1
                guard end < candles.count,
                      let candidate = detectCandidate(
                        candles,
                        atr: atr,
                        confluenceEMA: confluenceEMA,
                        start: start,
                        end: end,
                        config: config
                      )
                else { continue }
                candidates.append(candidate)
            }
        }

        let ordered = candidates.sorted {
            if $0.spikeStartIndex != $1.spikeStartIndex {
                return $0.spikeStartIndex < $1.spikeStartIndex
            }
            return $0.score > $1.score
        }
        var selected: [Result] = []

        for candidate in ordered {
            guard let priorIndex = selected.lastIndex(where: {
                $0.direction == candidate.direction &&
                candidate.spikeStartIndex <= $0.lastRelevantIndex
            }) else {
                selected.append(candidate)
                continue
            }

            let prior = selected[priorIndex]
            let priorEnteredBeforeCandidate = prior.attempts.contains {
                guard let trigger = $0.triggerIndex else { return false }
                return trigger <= candidate.microEndIndex
            }
            if !priorEnteredBeforeCandidate && candidate.score > prior.score {
                selected[priorIndex] = candidate
            }
        }

        return Array(selected.sorted { $0.spikeStartIndex < $1.spikeStartIndex }.suffix(max(1, maxResults)))
    }

    private static func detectCandidate(
        _ candles: [Candle],
        atr: [Double?],
        confluenceEMA: [Double?],
        start: Int,
        end: Int,
        config: Configuration
    ) -> Result? {
        guard let atrValue = atr[end], atrValue > 0 else { return nil }
        let slice = candles[start...end]
        let firstOpen = candles[start].open
        let lastClose = candles[end].close
        let direction: Direction = lastClose >= firstOpen ? .long : .short
        let displacement = abs(lastClose - firstOpen)
        guard displacement >= config.minSpikeATR * atrValue else { return nil }

        let directionalCount = slice.reduce(into: 0) { count, candle in
            if direction == .long ? candle.close > candle.open : candle.close < candle.open {
                count += 1
            }
        }
        let directionalRatio = Double(directionalCount) / Double(slice.count)
        guard directionalRatio >= config.minDirectionalRatio else { return nil }

        let bodyRatio = slice.reduce(0.0) { sum, candle in
            let range = max(candle.high - candle.low, .leastNonzeroMagnitude)
            return sum + abs(candle.close - candle.open) / range
        } / Double(slice.count)
        guard bodyRatio >= config.minBodyRatio else { return nil }

        let spikeHigh = slice.map(\.high).max() ?? candles[end].high
        let spikeLow = slice.map(\.low).min() ?? candles[end].low
        let spikeRange = max(spikeHigh - spikeLow, .leastNonzeroMagnitude)
        let closeFromExtreme = direction == .long
            ? (spikeHigh - lastClose) / spikeRange
            : (lastClose - spikeLow) / spikeRange
        guard closeFromExtreme <= config.maxCloseFromExtreme else { return nil }

        let confluence = evaluateConfluence(
            candles,
            ema: confluenceEMA,
            start: start,
            end: end,
            direction: direction,
            config: config
        )
        guard !config.requirePressureGap || confluence.pressureGap != nil,
              !config.requireKeyLevelBreak || confluence.brokeKeyLevel,
              confluence.score >= config.minConfluenceScore
        else { return nil }

        let microStart = end + 1
        guard microStart < candles.count else { return nil }
        let spikeAverageRange = slice.reduce(0.0) { $0 + ($1.high - $1.low) } / Double(slice.count)
        var microIndices: [Int] = []
        var triggerIndex: Int?
        var rangeSum = 0.0
        let tolerance = config.structureToleranceATR * atrValue

        let scanEnd = min(candles.count - 1, end + config.maxMicroBars + 1)
        for index in microStart...scanEnd {
            if microIndices.count >= config.minMicroBars,
               let prior = microIndices.last,
               closesBeyond(candles[index], level: direction == .long ? candles[prior].high : candles[prior].low, direction: direction) {
                triggerIndex = index
                break
            }
            guard microIndices.count < config.maxMicroBars else { break }

            if let prior = microIndices.last {
                let structureIsValid = direction == .long
                    ? candles[index].high <= candles[prior].high + tolerance
                    : candles[index].low >= candles[prior].low - tolerance
                guard structureIsValid else { return nil }
            }

            rangeSum += candles[index].high - candles[index].low
            microIndices.append(index)
            let averageMicroRange = rangeSum / Double(microIndices.count)
            guard averageMicroRange <= spikeAverageRange * config.maxMicroRangeRatio else { return nil }

            let pullbackExtreme: Double
            if direction == .long {
                pullbackExtreme = microIndices.map { candles[$0].low }.min() ?? candles[index].low
            } else {
                pullbackExtreme = microIndices.map { candles[$0].high }.max() ?? candles[index].high
            }
            let retracement = direction == .long
                ? (spikeHigh - pullbackExtreme) / displacement
                : (pullbackExtreme - spikeLow) / displacement
            guard retracement <= config.maxRetracement else { return nil }
        }

        guard microIndices.count >= config.minMicroBars else { return nil }
        let microEnd = microIndices.last!
        let triggerLevel = direction == .long ? candles[microEnd].high : candles[microEnd].low
        let score = displacement / atrValue
            + directionalRatio
            + bodyRatio
            - closeFromExtreme
            + Double(confluence.score) * 0.35
        let id = "\(Int(candles[start].id.timeIntervalSince1970))-\(direction.rawValue)"
        var result = Result(
            id: id,
            direction: direction,
            spikeStartIndex: start,
            spikeEndIndex: end,
            spikeLow: spikeLow,
            spikeHigh: spikeHigh,
            microStartIndex: microStart,
            microEndIndex: microEnd,
            score: score,
            confluence: confluence,
            attempts: [],
            stage: .awaitingFirstEntry
        )

        guard let triggerIndex else {
            if candles.count - 1 > microEnd {
                result.stage = .expired
                result.endIndex = microEnd
                result.endReason = .reentryExpired
            }
            result.attempts = [Attempt(
                number: 1,
                anchorIndex: nil,
                triggerLevel: triggerLevel,
                status: .waiting
            )]
            return result
        }

        let firstStop = direction == .long
            ? microIndices.map { candles[$0].low }.min()!
            : microIndices.map { candles[$0].high }.max()!
        runAttempt(
            number: 1,
            anchorIndex: nil,
            triggerLevel: triggerLevel,
            triggerIndex: triggerIndex,
            stopLoss: firstStop,
            candles: candles,
            config: config,
            result: &result
        )
        return result
    }

    private static func runAttempt(
        number: Int,
        anchorIndex: Int?,
        triggerLevel: Double,
        triggerIndex: Int,
        stopLoss: Double,
        candles: [Candle],
        config: Configuration,
        result: inout Result
    ) {
        let entry = candles[triggerIndex].close
        let risk = abs(entry - stopLoss)
        guard risk > .leastNonzeroMagnitude else {
            result.stage = .expired
            result.endIndex = triggerIndex
            result.endReason = .reentryExpired
            return
        }
        let target = result.direction == .long
            ? entry + risk * config.riskReward
            : entry - risk * config.riskReward
        var attempt = Attempt(
            number: number,
            anchorIndex: anchorIndex,
            triggerLevel: triggerLevel,
            triggerIndex: triggerIndex,
            entry: entry,
            stopLoss: stopLoss,
            takeProfit: target,
            status: .active
        )
        result.stage = .active

        let resolutionStart = triggerIndex + 1
        if resolutionStart < candles.count {
            for index in resolutionStart..<candles.count {
                let stopHit = result.direction == .long
                    ? candles[index].close <= stopLoss
                    : candles[index].close >= stopLoss
                let targetHit = result.direction == .long
                    ? candles[index].high >= target
                    : candles[index].low <= target

                // Stop wins an ambiguous candle to avoid optimistic history.
                if stopHit {
                    attempt.status = .stopped
                    attempt.stopIndex = index
                    result.attempts.append(attempt)
                    if number == 3 {
                        result.stage = .invalidated
                        result.endIndex = index
                        result.endReason = .threeStops
                    } else {
                        prepareReentry(
                            afterStop: index,
                            number: number + 1,
                            candles: candles,
                            config: config,
                            result: &result
                        )
                    }
                    return
                }
                if targetHit {
                    attempt.status = .succeeded
                    attempt.targetIndex = index
                    result.attempts.append(attempt)
                    result.stage = .succeeded
                    result.endIndex = index
                    result.endReason = .targetHit
                    return
                }
            }
        }
        result.attempts.append(attempt)
    }

    private static func prepareReentry(
        afterStop stopIndex: Int,
        number: Int,
        candles: [Candle],
        config: Configuration,
        result: inout Result
    ) {
        let anchorIndex = stopIndex + 1
        guard anchorIndex < candles.count else {
            result.stage = .awaitingReentry
            return
        }
        let triggerLevel = result.direction == .long
            ? candles[anchorIndex].high
            : candles[anchorIndex].low
        let scanStart = anchorIndex + 1
        let scanEnd = min(candles.count - 1, anchorIndex + config.maxReentryBars)

        guard scanStart <= scanEnd else {
            result.attempts.append(Attempt(
                number: number,
                anchorIndex: anchorIndex,
                triggerLevel: triggerLevel,
                status: .waiting
            ))
            result.stage = .awaitingReentry
            return
        }

        var triggerIndex: Int?
        for index in scanStart...scanEnd where closesBeyond(candles[index], level: triggerLevel, direction: result.direction) {
            triggerIndex = index
            break
        }
        guard let triggerIndex else {
            result.attempts.append(Attempt(
                number: number,
                anchorIndex: anchorIndex,
                triggerLevel: triggerLevel,
                status: .waiting
            ))
            if candles.count - 1 >= anchorIndex + config.maxReentryBars {
                result.stage = .expired
                result.endIndex = anchorIndex + config.maxReentryBars
                result.endReason = .reentryExpired
            } else {
                result.stage = .awaitingReentry
            }
            return
        }

        let stopLoss: Double
        if number == 2 {
            let range = stopIndex...triggerIndex
            stopLoss = result.direction == .long
                ? range.map { candles[$0].low }.min()!
                : range.map { candles[$0].high }.max()!
        } else {
            stopLoss = result.direction == .long
                ? candles[anchorIndex].low
                : candles[anchorIndex].high
        }
        runAttempt(
            number: number,
            anchorIndex: anchorIndex,
            triggerLevel: triggerLevel,
            triggerIndex: triggerIndex,
            stopLoss: stopLoss,
            candles: candles,
            config: config,
            result: &result
        )
    }

    private static func closesBeyond(_ candle: Candle, level: Double, direction: Direction) -> Bool {
        direction == .long ? candle.close > level : candle.close < level
    }

    private static func normalized(_ raw: Configuration) -> Configuration {
        var config = raw
        config.atrPeriod = max(1, raw.atrPeriod)
        config.minSpikeBars = max(2, raw.minSpikeBars)
        config.maxSpikeBars = max(config.minSpikeBars, raw.maxSpikeBars)
        config.minSpikeATR = max(0.1, raw.minSpikeATR)
        config.minDirectionalRatio = min(max(raw.minDirectionalRatio, 0), 1)
        config.minBodyRatio = min(max(raw.minBodyRatio, 0), 1)
        config.maxCloseFromExtreme = min(max(raw.maxCloseFromExtreme, 0), 1)
        config.minMicroBars = max(2, raw.minMicroBars)
        config.maxMicroBars = max(config.minMicroBars, raw.maxMicroBars)
        config.maxMicroRangeRatio = max(0.1, raw.maxMicroRangeRatio)
        config.maxRetracement = max(0.1, raw.maxRetracement)
        config.structureToleranceATR = max(0, raw.structureToleranceATR)
        config.maxReentryBars = max(1, raw.maxReentryBars)
        config.riskReward = max(0.1, raw.riskReward)
        config.confluenceBalanceBars = max(2, raw.confluenceBalanceBars)
        config.confluenceEMAPeriod = max(2, raw.confluenceEMAPeriod)
        config.minPressureGapPct = max(0, raw.minPressureGapPct)
        config.maxPressureGapBar = max(2, raw.maxPressureGapBar)
        config.minConfluenceScore = min(max(0, raw.minConfluenceScore), 6)
        return config
    }

    private static func evaluateConfluence(
        _ candles: [Candle],
        ema: [Double?],
        start: Int,
        end: Int,
        direction: Direction,
        config: Configuration
    ) -> Confluence {
        let gap = pressureGap(
            candles,
            start: start,
            end: end,
            direction: direction,
            minGapPct: config.minPressureGapPct,
            maxPressureGapBar: config.maxPressureGapBar
        )
        let brokeKeyLevel = breaksPriorRange(
            candles,
            start: start,
            end: end,
            lookback: config.confluenceBalanceBars,
            direction: direction
        )
        let trendAligned = isTrendAligned(
            candles,
            ema: ema,
            start: start,
            end: end,
            direction: direction
        )
        let liquidSession = isLiquidSession(candles[end].id)
        let score = (gap == nil ? 0 : 2)
            + (brokeKeyLevel ? 2 : 0)
            + (trendAligned ? 1 : 0)
            + (liquidSession ? 1 : 0)
        return Confluence(
            pressureGap: gap,
            brokeKeyLevel: brokeKeyLevel,
            trendAligned: trendAligned,
            liquidSession: liquidSession,
            score: score
        )
    }

    private static func pressureGap(
        _ candles: [Candle],
        start: Int,
        end: Int,
        direction: Direction,
        minGapPct: Double,
        maxPressureGapBar: Int
    ) -> PressureGap? {
        let firstEnd = max(2, start + 1)
        let latestEnd = min(end, start - 1 + maxPressureGapBar)
        guard firstEnd <= latestEnd else { return nil }

        for index in firstEnd...latestEnd {
            let first = candles[index - 2]
            let middle = candles[index - 1]
            let current = candles[index]
            switch direction {
            case .long where current.low > first.high && middle.close > first.high:
                let pct = first.high > 0 ? (current.low - first.high) / first.high * 100 : 0
                if pct >= minGapPct {
                    return PressureGap(
                        startIndex: index - 2,
                        endIndex: index,
                        low: first.high,
                        high: current.low
                    )
                }
            case .short where current.high < first.low && middle.close < first.low:
                let pct = current.high > 0 ? (first.low - current.high) / current.high * 100 : 0
                if pct >= minGapPct {
                    return PressureGap(
                        startIndex: index - 2,
                        endIndex: index,
                        low: current.high,
                        high: first.low
                    )
                }
            default:
                break
            }
        }
        return nil
    }

    private static func breaksPriorRange(
        _ candles: [Candle],
        start: Int,
        end: Int,
        lookback: Int,
        direction: Direction
    ) -> Bool {
        guard start >= lookback, end > start else { return false }
        let prior = candles[(start - lookback)..<start]
        let priorHigh = prior.map(\.high).max() ?? candles[start - 1].high
        let priorLow = prior.map(\.low).min() ?? candles[start - 1].low

        for index in start..<end {
            let next = index + 1
            if direction == .long,
               candles[index].close > priorHigh,
               candles[next].close > priorHigh,
               candles[next].close > candles[index].close {
                return true
            }
            if direction == .short,
               candles[index].close < priorLow,
               candles[next].close < priorLow,
               candles[next].close < candles[index].close {
                return true
            }
        }
        return false
    }

    private static func isTrendAligned(
        _ candles: [Candle],
        ema: [Double?],
        start: Int,
        end: Int,
        direction: Direction
    ) -> Bool {
        let priorIndex = max(0, start - 1)
        guard end < ema.count,
              let current = ema[end],
              let prior = ema[priorIndex]
        else { return false }
        switch direction {
        case .long:
            return candles[end].close > current && current >= prior
        case .short:
            return candles[end].close < current && current <= prior
        }
    }

    private static func isLiquidSession(_ date: Date) -> Bool {
        isInside(date, timezone: "Europe/London", startMinute: 8 * 60 + 30, endMinute: 16 * 60 + 30)
            || isInside(date, timezone: "America/New_York", startMinute: 9 * 60 + 30, endMinute: 16 * 60)
    }

    private static func isInside(
        _ date: Date,
        timezone: String,
        startMinute: Int,
        endMinute: Int
    ) -> Bool {
        guard let timezone = TimeZone(identifier: timezone) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday,
              weekday != 1,
              weekday != 7,
              let hour = parts.hour,
              let minute = parts.minute
        else { return false }
        let minuteOfDay = hour * 60 + minute
        return minuteOfDay >= startMinute && minuteOfDay < endMinute
    }

    private static func atrSeries(_ candles: [Candle], period: Int) -> [Double?] {
        guard !candles.isEmpty else { return [] }
        var trueRanges = [Double](repeating: 0, count: candles.count)
        trueRanges[0] = candles[0].high - candles[0].low
        for index in 1..<candles.count {
            let previousClose = candles[index - 1].close
            trueRanges[index] = max(
                candles[index].high - candles[index].low,
                abs(candles[index].high - previousClose),
                abs(candles[index].low - previousClose)
            )
        }
        var output = [Double?](repeating: nil, count: candles.count)
        guard candles.count >= period else { return output }
        var value = trueRanges.prefix(period).reduce(0, +) / Double(period)
        output[period - 1] = value
        let p = Double(period)
        if period < candles.count {
            for index in period..<candles.count {
                value = (value * (p - 1) + trueRanges[index]) / p
                output[index] = value
            }
        }
        return output
    }

    private static func emaSeries(_ candles: [Candle], period: Int) -> [Double?] {
        guard candles.count >= period else {
            return [Double?](repeating: nil, count: candles.count)
        }
        var output = [Double?](repeating: nil, count: candles.count)
        var value = candles.prefix(period).map(\.close).reduce(0, +) / Double(period)
        output[period - 1] = value
        let multiplier = 2.0 / Double(period + 1)
        if period < candles.count {
            for index in period..<candles.count {
                value = (candles[index].close - value) * multiplier + value
                output[index] = value
            }
        }
        return output
    }
}

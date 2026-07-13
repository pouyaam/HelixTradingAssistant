import Foundation

/// Pin-bar confirmation overlay for the two continuation structures taught
/// together in the source lesson:
///
/// - SP2L: reuse a detected spike/pullback level, but require rejection
///   instead of treating the first touch as a fill.
/// - BTB: break a recent balance extreme, return to the broken level, then
///   require a rejection pin bar before entering with the breakout.
enum PinBarComboSetup {
    enum Kind: String, Hashable {
        case sp2l
        case btb
    }

    enum Direction: String, Hashable {
        case long
        case short
    }

    enum Status: String, Hashable {
        case active
        case hitTP
        case hitSL
        case expired
    }

    struct Configuration: Hashable {
        var enableSP2L = true
        var enableBTB = true
        var atrPeriod = 14
        var minWickBodyRatio = 2.0
        var minWickRangeRatio = 0.55
        var maxBodyRangeRatio = 0.35
        var minCloseLocation = 0.65
        var oppositeWickDominance = 1.5
        var touchToleranceATR = 0.10
        var stopBufferATR = 0.05
        var maxConfirmationBars = 8
        var btbLookbackBars = 12
        var minBreakoutBodyATR = 0.50
        var riskReward = 2.0
        var maxContinuationBars = 20
    }

    struct Result: Identifiable, Hashable {
        let kind: Kind
        let direction: Direction
        let structureStartIndex: Int
        let breakoutIndex: Int
        let confirmationIndex: Int
        let level: Double
        let pinBarHigh: Double
        let pinBarLow: Double
        let entry: Double
        let stopLoss: Double
        let takeProfit: Double
        var resolveIndex: Int?
        var status: Status

        var id: String {
            "\(kind.rawValue)-\(direction.rawValue)-\(breakoutIndex)-\(confirmationIndex)"
        }

        var lastRelevantIndex: Int {
            resolveIndex ?? confirmationIndex
        }
    }

    static func compute(
        _ candles: [Candle],
        sp2lResults: [SP2LSetup.Result],
        configuration rawConfiguration: Configuration = Configuration(),
        maxResults: Int = 16
    ) -> [Result] {
        guard candles.count >= 3 else { return [] }
        let configuration = sanitized(rawConfiguration)
        let atr = atrSeries(candles, period: configuration.atrPeriod)
        var output: [Result] = []

        if configuration.enableSP2L {
            output += confirmedSP2L(
                candles,
                bases: sp2lResults,
                atr: atr,
                configuration: configuration
            )
        }
        if configuration.enableBTB {
            output += confirmedBTB(
                candles,
                atr: atr,
                configuration: configuration
            )
        }

        output.sort {
            if $0.confirmationIndex == $1.confirmationIndex {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.confirmationIndex < $1.confirmationIndex
        }
        return Array(output.suffix(max(1, maxResults)))
    }

    static func isPinBar(
        _ candle: Candle,
        direction: Direction,
        level: Double,
        atr: Double,
        configuration rawConfiguration: Configuration = Configuration()
    ) -> Bool {
        let configuration = sanitized(rawConfiguration)
        let range = candle.high - candle.low
        guard range > 0 else { return false }

        let body = abs(candle.close - candle.open)
        let ratioBody = max(body, range * 0.02)
        let upperWick = candle.high - max(candle.open, candle.close)
        let lowerWick = min(candle.open, candle.close) - candle.low
        let tolerance = max(0, atr) * configuration.touchToleranceATR

        guard body / range <= configuration.maxBodyRangeRatio else { return false }

        switch direction {
        case .long:
            let closeLocation = (candle.close - candle.low) / range
            return candle.low <= level + tolerance
                && candle.close >= level
                && lowerWick / ratioBody >= configuration.minWickBodyRatio
                && lowerWick / range >= configuration.minWickRangeRatio
                && lowerWick >= upperWick * configuration.oppositeWickDominance
                && closeLocation >= configuration.minCloseLocation
        case .short:
            let closeLocation = (candle.high - candle.close) / range
            return candle.high >= level - tolerance
                && candle.close <= level
                && upperWick / ratioBody >= configuration.minWickBodyRatio
                && upperWick / range >= configuration.minWickRangeRatio
                && upperWick >= lowerWick * configuration.oppositeWickDominance
                && closeLocation >= configuration.minCloseLocation
        }
    }

    private static func confirmedSP2L(
        _ candles: [Candle],
        bases: [SP2LSetup.Result],
        atr: [Double?],
        configuration: Configuration
    ) -> [Result] {
        var output: [Result] = []
        var usedConfirmations = Set<String>()

        for base in bases {
            let direction: Direction = base.direction == .long ? .long : .short
            let lower = base.spikeEndIndex + 1
            let upper = min(candles.count - 1, base.spikeEndIndex + configuration.maxConfirmationBars)
            guard lower <= upper else { continue }

            for index in lower...upper {
                guard let currentATR = atr[index], currentATR > 0,
                      isPinBar(
                        candles[index],
                        direction: direction,
                        level: base.entry,
                        atr: currentATR,
                        configuration: configuration
                      )
                else { continue }

                let key = "\(direction.rawValue)-\(index)"
                guard usedConfirmations.insert(key).inserted else { break }
                if let result = makeResult(
                    candles,
                    kind: .sp2l,
                    direction: direction,
                    structureStartIndex: base.spikeStartIndex,
                    breakoutIndex: base.breakoutIndex,
                    confirmationIndex: index,
                    level: base.entry,
                    atr: currentATR,
                    configuration: configuration
                ) {
                    output.append(result)
                }
                break
            }
        }
        return output
    }

    private static func confirmedBTB(
        _ candles: [Candle],
        atr: [Double?],
        configuration: Configuration
    ) -> [Result] {
        let lookback = configuration.btbLookbackBars
        guard candles.count > lookback + 1 else { return [] }
        var output: [Result] = []
        var breakoutIndex = lookback

        while breakoutIndex < candles.count - 1 {
            guard let currentATR = atr[breakoutIndex], currentATR > 0 else {
                breakoutIndex += 1
                continue
            }
            let history = candles[(breakoutIndex - lookback)..<breakoutIndex]
            let resistance = history.map(\.high).max() ?? candles[breakoutIndex - 1].high
            let support = history.map(\.low).min() ?? candles[breakoutIndex - 1].low
            let breakout = candles[breakoutIndex]
            let body = abs(breakout.close - breakout.open)
            let tolerance = currentATR * configuration.touchToleranceATR

            let candidate: (Direction, Double)?
            if breakout.close > resistance,
               breakout.open <= resistance + tolerance,
               body >= currentATR * configuration.minBreakoutBodyATR {
                candidate = (.long, resistance)
            } else if breakout.close < support,
                      breakout.open >= support - tolerance,
                      body >= currentATR * configuration.minBreakoutBodyATR {
                candidate = (.short, support)
            } else {
                candidate = nil
            }

            guard let (direction, level) = candidate else {
                breakoutIndex += 1
                continue
            }

            let upper = min(candles.count - 1, breakoutIndex + configuration.maxConfirmationBars)
            var confirmationIndex: Int?
            if breakoutIndex + 1 <= upper {
                for index in (breakoutIndex + 1)...upper {
                    guard let pinATR = atr[index], pinATR > 0 else { continue }
                    if isPinBar(
                        candles[index],
                        direction: direction,
                        level: level,
                        atr: pinATR,
                        configuration: configuration
                    ) {
                        confirmationIndex = index
                        break
                    }
                }
            }

            if let confirmationIndex,
               let pinATR = atr[confirmationIndex],
               let result = makeResult(
                    candles,
                    kind: .btb,
                    direction: direction,
                    structureStartIndex: breakoutIndex - lookback,
                    breakoutIndex: breakoutIndex,
                    confirmationIndex: confirmationIndex,
                    level: level,
                    atr: pinATR,
                    configuration: configuration
               ) {
                output.append(result)
                breakoutIndex = confirmationIndex + 1
            } else {
                breakoutIndex += 1
            }
        }
        return output
    }

    private static func makeResult(
        _ candles: [Candle],
        kind: Kind,
        direction: Direction,
        structureStartIndex: Int,
        breakoutIndex: Int,
        confirmationIndex: Int,
        level: Double,
        atr: Double,
        configuration: Configuration
    ) -> Result? {
        let pin = candles[confirmationIndex]
        let buffer = atr * configuration.stopBufferATR
        let entry = pin.close
        let stopLoss = direction == .long ? pin.low - buffer : pin.high + buffer
        let risk = abs(entry - stopLoss)
        guard risk > 0 else { return nil }
        let takeProfit = direction == .long
            ? entry + risk * configuration.riskReward
            : entry - risk * configuration.riskReward

        var result = Result(
            kind: kind,
            direction: direction,
            structureStartIndex: structureStartIndex,
            breakoutIndex: breakoutIndex,
            confirmationIndex: confirmationIndex,
            level: level,
            pinBarHigh: pin.high,
            pinBarLow: pin.low,
            entry: entry,
            stopLoss: stopLoss,
            takeProfit: takeProfit,
            status: .active
        )
        resolve(&result, candles: candles, configuration: configuration)
        return result
    }

    private static func resolve(
        _ result: inout Result,
        candles: [Candle],
        configuration: Configuration
    ) {
        let first = result.confirmationIndex + 1
        let last = min(candles.count - 1, result.confirmationIndex + configuration.maxContinuationBars)
        guard first <= last else { return }

        for index in first...last {
            let candle = candles[index]
            let hitStop: Bool
            let hitTarget: Bool
            switch result.direction {
            case .long:
                hitStop = candle.low <= result.stopLoss
                hitTarget = candle.high >= result.takeProfit
            case .short:
                hitStop = candle.high >= result.stopLoss
                hitTarget = candle.low <= result.takeProfit
            }
            if hitStop || hitTarget {
                result.resolveIndex = index
                result.status = hitStop ? .hitSL : .hitTP
                return
            }
        }

        if candles.count - 1 >= result.confirmationIndex + configuration.maxContinuationBars {
            result.resolveIndex = last
            result.status = .expired
        }
    }

    private static func sanitized(_ configuration: Configuration) -> Configuration {
        var value = configuration
        value.atrPeriod = max(1, value.atrPeriod)
        value.minWickBodyRatio = max(0, value.minWickBodyRatio)
        value.minWickRangeRatio = min(1, max(0, value.minWickRangeRatio))
        value.maxBodyRangeRatio = min(1, max(0.01, value.maxBodyRangeRatio))
        value.minCloseLocation = min(1, max(0, value.minCloseLocation))
        value.oppositeWickDominance = max(0, value.oppositeWickDominance)
        value.touchToleranceATR = max(0, value.touchToleranceATR)
        value.stopBufferATR = max(0, value.stopBufferATR)
        value.maxConfirmationBars = max(1, value.maxConfirmationBars)
        value.btbLookbackBars = max(2, value.btbLookbackBars)
        value.minBreakoutBodyATR = max(0, value.minBreakoutBodyATR)
        value.riskReward = max(0.1, value.riskReward)
        value.maxContinuationBars = max(1, value.maxContinuationBars)
        return value
    }

    private static func atrSeries(_ candles: [Candle], period: Int) -> [Double?] {
        guard !candles.isEmpty else { return [] }
        var ranges = [Double](repeating: 0, count: candles.count)
        for index in candles.indices {
            if index == 0 {
                ranges[index] = candles[index].high - candles[index].low
            } else {
                let previousClose = candles[index - 1].close
                ranges[index] = max(
                    candles[index].high - candles[index].low,
                    abs(candles[index].high - previousClose),
                    abs(candles[index].low - previousClose)
                )
            }
        }

        var output = [Double?](repeating: nil, count: candles.count)
        var sum = 0.0
        for index in ranges.indices {
            sum += ranges[index]
            if index >= period { sum -= ranges[index - period] }
            if index >= period - 1 { output[index] = sum / Double(period) }
        }
        return output
    }
}

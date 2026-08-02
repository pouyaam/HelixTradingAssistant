import Foundation
import SwiftUI

/// Helix + Price Action Volumetric Order Blocks [Combo] indicator.
///
/// Ported from PineScript v6 "Helix + Price Action Volumetric Order Blocks [Combo]".
/// Combines an ATR trailing-stop trend detector with EMA filter, session volume filter,
/// MACD crossover signals, and UAlgo Volumetric Order Blocks with pivot-driven MSB/BOS structure lines.
enum HelixOBCombo {
    /// ATR stop and direction point per bar.
    struct Point: Identifiable, Hashable {
        let index: Int
        let longStop: Double?
        let shortStop: Double?
        let dir: Int // +1 for long, -1 for short
        let emaFilter: Double?

        var id: Int { index }
    }

    /// Buy / Sell signal marker at a specific bar.
    struct Signal: Identifiable, Hashable {
        let id: String
        let index: Int
        let isBuy: Bool
        let isMACD: Bool
        let price: Double
    }

    /// Active Volumetric Order Block zone.
    struct OrderBlock: Identifiable, Hashable {
        let id: UUID
        let top: Double
        let btm: Double
        let barStart: Int
        let bullishStr: Double
        let bearishStr: Double
        let vol: Double
        let isBullish: Bool

        init(
            id: UUID = UUID(),
            top: Double,
            btm: Double,
            barStart: Int,
            bullishStr: Double,
            bearishStr: Double,
            vol: Double,
            isBullish: Bool
        ) {
            self.id = id
            self.top = top
            self.btm = btm
            self.barStart = barStart
            self.bullishStr = bullishStr
            self.bearishStr = bearishStr
            self.vol = vol
            self.isBullish = isBullish
        }

        var mid: Double { btm + (top - btm) / 2.0 }
    }

    /// Market structure line (MSB / BOS).
    struct StructureLine: Identifiable, Hashable {
        let id: UUID
        let x1: Int
        let y1: Double
        let x2: Int
        let y2: Double
        let label: String // "MSB" or "BOS"
        let isBullish: Bool

        init(
            id: UUID = UUID(),
            x1: Int,
            y1: Double,
            x2: Int,
            y2: Double,
            label: String,
            isBullish: Bool
        ) {
            self.id = id
            self.x1 = x1
            self.y1 = y1
            self.x2 = x2
            self.y2 = y2
            self.label = label
            self.isBullish = isBullish
        }
    }

    /// Full calculation output.
    struct Output: Hashable {
        let points: [Point]
        let emaPoints: [IndicatorPoint]
        let signals: [Signal]
        let bullishOBs: [OrderBlock]
        let bearishOBs: [OrderBlock]
        let structures: [StructureLine]

        static let empty = Output(
            points: [],
            emaPoints: [],
            signals: [],
            bullishOBs: [],
            bearishOBs: [],
            structures: []
        )
    }

    /// Compute full Helix + Volumetric OB Combo series and zones.
    static func compute(_ candles: [Candle], params: [String: ParamValue]) -> Output {
        guard !candles.isEmpty else { return .empty }

        // Parameter extraction with PineScript defaults
        let atrLength = max(1, Int(params["atrLength"]?.doubleValue ?? 1))
        let atrMult = params["atrMult"]?.doubleValue ?? 1.85
        let emaLength = max(1, Int(params["emaLength"]?.doubleValue ?? 50))
        let useEMAFilter = params["useEMAFilter"]?.boolValue ?? true
        let useVolumeFilter = params["useVolumeFilter"]?.boolValue ?? true
        let useExtraVolumeFilter = params["useExtraVolumeFilter"]?.boolValue ?? true
        let lookBackPeriod = max(1, Int(params["lookBackPeriod"]?.doubleValue ?? 20))
        let useMACDSignal = params["useMACDSignal"]?.boolValue ?? true
        let heikenAshi = params["heikenAshi"]?.boolValue ?? false

        let fastLength = max(1, Int(params["fastLength"]?.doubleValue ?? 12))
        let slowLength = max(1, Int(params["slowLength"]?.doubleValue ?? 26))
        let signalLength = max(1, Int(params["signalLength"]?.doubleValue ?? 9))

        let swingLength = max(1, Int(params["swingLength"]?.doubleValue ?? 8))
        let showLastXOb = max(1, Int(params["showLastXOb"]?.doubleValue ?? 4))
        let violationType = params["violationType"]?.stringValue ?? "Wick"
        let hideOverlapStr = params["hideOverlap"]?.stringValue ?? "True"
        let hideOverlap = hideOverlapStr == "True" || hideOverlapStr == "true"

        let tokyoStart = Int(params["tokyoStart"]?.doubleValue ?? 0)
        let tokyoEnd = Int(params["tokyoEnd"]?.doubleValue ?? 9)
        let londonStart = Int(params["londonStart"]?.doubleValue ?? 8)
        let londonEnd = Int(params["londonEnd"]?.doubleValue ?? 17)
        let nyStart = Int(params["nyStart"]?.doubleValue ?? 13)
        let nyEnd = Int(params["nyEnd"]?.doubleValue ?? 22)

        // 1. Prepare candles for Helix (Heikin Ashi or Normal)
        let nCandles = heikenAshi ? HeikinAshi.transform(candles) : candles
        let n = candles.count

        // 2. EMA Filter calculation
        let emaPoints = Indicators.ema(nCandles, period: emaLength)
        var emaDict: [Int: Double] = [:]
        for pt in emaPoints { emaDict[pt.index] = pt.value }

        // 3. ATR calculation on nCandles
        let atrValues = calcATR(nCandles, length: atrLength)

        // 4. Trailing stop and direction calculation
        var longStops: [Double] = Array(repeating: 0, count: n)
        var shortStops: [Double] = Array(repeating: 0, count: n)
        var dirs: [Int] = Array(repeating: 1, count: n)
        var points: [Point] = []
        points.reserveCapacity(n)

        for i in 0..<n {
            let atr = atrMult * atrValues[i]
            // Highest high over atrLength
            var hi = nCandles[i].high
            var lo = nCandles[i].low
            let startIdx = max(0, i - atrLength + 1)
            for j in startIdx...i {
                if nCandles[j].high > hi { hi = nCandles[j].high }
                if nCandles[j].low < lo { lo = nCandles[j].low }
            }

            let rawLongStop = hi - atr
            let rawShortStop = lo + atr

            let longStopPrev = i > 0 ? longStops[i - 1] : rawLongStop
            let shortStopPrev = i > 0 ? shortStops[i - 1] : rawShortStop

            let prevClose = i > 0 ? nCandles[i - 1].close : nCandles[0].close
            let curLongStop = prevClose > longStopPrev ? max(rawLongStop, longStopPrev) : rawLongStop
            let curShortStop = prevClose < shortStopPrev ? min(rawShortStop, shortStopPrev) : rawShortStop

            longStops[i] = curLongStop
            shortStops[i] = curShortStop

            let curClose = nCandles[i].close
            let curDir: Int
            if curClose > shortStopPrev {
                curDir = 1
            } else if curClose < longStopPrev {
                curDir = -1
            } else {
                curDir = i > 0 ? dirs[i - 1] : 1
            }
            dirs[i] = curDir

            points.append(Point(
                index: i,
                longStop: curDir == 1 ? curLongStop : nil,
                shortStop: curDir == -1 ? curShortStop : nil,
                dir: curDir,
                emaFilter: emaDict[i]
            ))
        }

        // 5. Session Volume & Extra Volume Filters
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var lastDay: Int? = nil
        var tokyoCount = 0, londonCount = 0, nyCount = 0
        var volTokyoSum: Double = 0, volLondonSum: Double = 0, volNYSum: Double = 0

        var volumeConditionBuy: [Bool] = Array(repeating: true, count: n)
        var extraVolumeCondition: [Bool] = Array(repeating: true, count: n)

        // Precompute Volume SMA
        var volSum: Double = 0
        for i in 0..<n {
            let v = candles[i].volume ?? 0
            volSum += v
            if i >= lookBackPeriod { volSum -= candles[i - lookBackPeriod].volume ?? 0 }
            let count = min(i + 1, lookBackPeriod)
            let avgVol = volSum / Double(count)
            extraVolumeCondition[i] = !useExtraVolumeFilter || (v > avgVol)

            let ts = Int(candles[i].bucketStart.timeIntervalSince1970)
            let hour = (ts / 3600) % 24
            let day = ts / 86400

            if lastDay != day {
                lastDay = day
                tokyoCount = 0; londonCount = 0; nyCount = 0
                volTokyoSum = 0; volLondonSum = 0; volNYSum = 0
            }

            let isTokyo = hour >= tokyoStart && hour < tokyoEnd
            let isLondon = hour >= londonStart && hour < londonEnd
            let isNY = hour >= nyStart && hour < nyEnd

            if isTokyo { volTokyoSum += v; tokyoCount += 1 }
            if isLondon { volLondonSum += v; londonCount += 1 }
            if isNY { volNYSum += v; nyCount += 1 }

            let avgVolTokyo = tokyoCount > 0 ? volTokyoSum / Double(tokyoCount) : 0
            let avgVolLondon = londonCount > 0 ? volLondonSum / Double(londonCount) : 0
            let avgVolNY = nyCount > 0 ? volNYSum / Double(nyCount) : 0

            if useVolumeFilter {
                let cond = (isTokyo && v > avgVolTokyo) ||
                           (isLondon && v > avgVolLondon) ||
                           (isNY && v > avgVolNY)
                volumeConditionBuy[i] = cond
            } else {
                volumeConditionBuy[i] = true
            }
        }

        // 6. MACD Crossover calculation on nCandles
        let macdResult = calcMACD(nCandles.map(\.close), fast: fastLength, slow: slowLength, signal: signalLength)

        // 7. Signals compilation
        var signals: [Signal] = []
        for i in 1..<n {
            let buySignalRaw = dirs[i] == 1 && dirs[i - 1] == -1
            let sellSignalRaw = dirs[i] == -1 && dirs[i - 1] == 1

            let emaVal = emaDict[i]
            let emaConditionBuy = !useEMAFilter || (emaVal != nil && nCandles[i].close > emaVal!)
            let emaConditionSell = !useEMAFilter || (emaVal != nil && nCandles[i].close < emaVal!)

            let volCond = volumeConditionBuy[i]
            let extraVolCond = extraVolumeCondition[i]

            let macdBuySignal = macdResult.macd[i] > macdResult.signal[i] && macdResult.macd[i - 1] <= macdResult.signal[i - 1]
            let macdSellSignal = macdResult.macd[i] < macdResult.signal[i] && macdResult.macd[i - 1] >= macdResult.signal[i - 1]

            let buySignal = buySignalRaw && emaConditionBuy && volCond && extraVolCond
            let sellSignal = sellSignalRaw && emaConditionSell && volCond && extraVolCond

            let buyWithMACD = useMACDSignal && buySignalRaw && emaConditionBuy && volCond && extraVolCond && macdBuySignal
            let sellWithMACD = useMACDSignal && sellSignalRaw && emaConditionSell && volCond && extraVolCond && macdSellSignal

            if buyWithMACD {
                signals.append(Signal(id: "\(i)-buyMACD", index: i, isBuy: true, isMACD: true, price: longStops[i]))
            } else if buySignal {
                signals.append(Signal(id: "\(i)-buy", index: i, isBuy: true, isMACD: false, price: longStops[i]))
            }

            if sellWithMACD {
                signals.append(Signal(id: "\(i)-sellMACD", index: i, isBuy: false, isMACD: true, price: shortStops[i]))
            } else if sellSignal {
                signals.append(Signal(id: "\(i)-sell", index: i, isBuy: false, isMACD: false, price: shortStops[i]))
            }
        }

        // 8. Order Blocks & Market Structure (UAlgo - calculated on raw candles)
        var bullishOBs: [OrderBlock] = []
        var bearishOBs: [OrderBlock] = []
        var structures: [StructureLine] = []

        var toppX: Int? = nil, toppY: Double? = nil, toppCrossed = false
        var btmmX: Int? = nil, btmmY: Double? = nil, btmmCrossed = false
        var lastDirection: Int? = nil
        var msbOrBos: String? = nil

        for i in 0..<n {
            // Check pivot high / low at i - swingLength
            let pivotIdx = i - swingLength
            if pivotIdx >= swingLength {
                let targetH = candles[pivotIdx].high
                let targetL = candles[pivotIdx].low

                var isPivotH = true
                var isPivotL = true

                for k in 1...swingLength {
                    if candles[pivotIdx - k].high >= targetH || candles[pivotIdx + k].high >= targetH {
                        isPivotH = false
                    }
                    if candles[pivotIdx - k].low <= targetL || candles[pivotIdx + k].low <= targetL {
                        isPivotL = false
                    }
                }

                if isPivotH {
                    toppX = pivotIdx
                    toppY = targetH
                    toppCrossed = false
                }
                if isPivotL {
                    btmmX = pivotIdx
                    btmmY = targetL
                    btmmCrossed = false
                }
            }

            let curClose = candles[i].close

            // Check breakdown below btmmY
            if let bY = btmmY, let bX = btmmX, curClose < bY, !btmmCrossed {
                btmmCrossed = true
                let kind = msbOrBos == nil ? "MSB" : (lastDirection == -1 ? "BOS" : "MSB")
                msbOrBos = kind
                lastDirection = -1

                structures.append(StructureLine(x1: bX, y1: bY, x2: i, y2: bY, label: kind, isBullish: false))

                // Find Bearish OB: last green candle with highest high in past swingLength bars
                var highAndGreenTop: Double = 0
                var highAndGreenBtm: Double = 0
                var selectedOffset: Int? = nil
                var vol: Double = 0

                for k in 1...swingLength {
                    let idx = i - k
                    if idx >= 0 {
                        let c = candles[idx]
                        if c.close > c.open && c.high > highAndGreenTop {
                            highAndGreenTop = c.high
                            highAndGreenBtm = c.low
                            selectedOffset = k
                            vol = c.volume ?? 0
                        }
                    }
                }

                if let selOffset = selectedOffset {
                    let selIdx = i - selOffset
                    let (bullStr, bearStr) = calcStrengths(candles, barIndex: selIdx, swingLength: swingLength)
                    let newOb = OrderBlock(
                        top: highAndGreenTop,
                        btm: highAndGreenBtm,
                        barStart: selIdx,
                        bullishStr: bullStr,
                        bearishStr: bearStr,
                        vol: vol,
                        isBullish: false
                    )

                    let overlaps = isOverlapping(newOb, array: bearishOBs)
                    if !overlaps || !hideOverlap {
                        bearishOBs.append(newOb)
                    }
                    if bearishOBs.count > showLastXOb {
                        bearishOBs.removeFirst()
                    }
                }
            }
            // Check breakout above toppY
            else if let tY = toppY, let tX = toppX, curClose > tY, !toppCrossed {
                toppCrossed = true
                let kind = msbOrBos == nil ? "MSB" : (lastDirection == 1 ? "BOS" : "MSB")
                msbOrBos = kind
                lastDirection = 1

                structures.append(StructureLine(x1: tX, y1: tY, x2: i, y2: tY, label: kind, isBullish: true))

                // Find Bullish OB: red candle with lowest low in past swingLength bars
                var lowAndRedBtm: Double = Double.greatestFiniteMagnitude
                var lowAndRedTop: Double = 0
                var selectedOffset: Int? = nil
                var vol: Double = 0

                for k in 1...swingLength {
                    let idx = i - k
                    if idx >= 0 {
                        let c = candles[idx]
                        if c.close < c.open && c.low < lowAndRedBtm {
                            lowAndRedBtm = c.low
                            lowAndRedTop = c.high
                            selectedOffset = k
                            vol = c.volume ?? 0
                        }
                    }
                }

                if let selOffset = selectedOffset {
                    let selIdx = i - selOffset
                    let (bullStr, bearStr) = calcStrengths(candles, barIndex: selIdx, swingLength: swingLength)
                    let newOb = OrderBlock(
                        top: lowAndRedTop,
                        btm: lowAndRedBtm,
                        barStart: selIdx,
                        bullishStr: bullStr,
                        bearishStr: bearStr,
                        vol: vol,
                        isBullish: true
                    )

                    let overlaps = isOverlapping(newOb, array: bullishOBs)
                    if !overlaps || !hideOverlap {
                        bullishOBs.append(newOb)
                    }
                    if bullishOBs.count > showLastXOb {
                        bullishOBs.removeFirst()
                    }
                }
            }

            // Invalidation check for active OBs at current bar
            let curLow = candles[i].low
            let curHigh = candles[i].high

            bullishOBs.removeAll { ob in
                if violationType == "Wick" {
                    return curLow < ob.btm
                } else {
                    return curClose < ob.btm
                }
            }

            bearishOBs.removeAll { ob in
                if violationType == "Wick" {
                    return curHigh > ob.top
                } else {
                    return curClose > ob.top
                }
            }
        }

        return Output(
            points: points,
            emaPoints: emaPoints,
            signals: signals,
            bullishOBs: bullishOBs,
            bearishOBs: bearishOBs,
            structures: structures
        )
    }

    // MARK: - Private Helpers

    private static func calcATR(_ candles: [Candle], length: Int) -> [Double] {
        let n = candles.count
        guard n > 0 else { return [] }
        var trs: [Double] = Array(repeating: 0, count: n)
        for i in 0..<n {
            let high = candles[i].high
            let low = candles[i].low
            let prevClose = i > 0 ? candles[i - 1].close : candles[0].close
            trs[i] = max(high - low, max(abs(high - prevClose), abs(low - prevClose)))
        }

        if length <= 1 { return trs }

        var atrs: [Double] = Array(repeating: 0, count: n)
        var sum: Double = 0
        for i in 0..<n {
            sum += trs[i]
            if i >= length { sum -= trs[i - length] }
            if i >= length - 1 {
                atrs[i] = sum / Double(length)
            } else {
                atrs[i] = trs[i]
            }
        }
        return atrs
    }

    private static func calcMACD(_ closes: [Double], fast: Int, slow: Int, signal: Int) -> (macd: [Double], signal: [Double]) {
        let n = closes.count
        guard n > 0 else { return ([], []) }

        let fastEMA = emaSeries(closes, period: fast)
        let slowEMA = emaSeries(closes, period: slow)

        var macdLine: [Double] = Array(repeating: 0, count: n)
        for i in 0..<n {
            macdLine[i] = fastEMA[i] - slowEMA[i]
        }

        let signalLine = emaSeries(macdLine, period: signal)
        return (macdLine, signalLine)
    }

    private static func emaSeries(_ values: [Double], period: Int) -> [Double] {
        let n = values.count
        guard n > 0 else { return [] }
        var out: [Double] = Array(repeating: 0, count: n)
        let alpha = 2.0 / (Double(period) + 1.0)
        var prev = values[0]
        out[0] = prev

        for i in 1..<n {
            prev = alpha * values[i] + (1.0 - alpha) * prev
            out[i] = prev
        }
        return out
    }

    private static func calcStrengths(_ candles: [Candle], barIndex: Int, swingLength: Int) -> (bullish: Double, bearish: Double) {
        var bullStr: Double = 0
        var bearStr: Double = 0
        for i in 0..<swingLength {
            let idx = barIndex - i
            if idx >= 0 && idx < candles.count {
                let c = candles[idx]
                let v = c.volume ?? 0
                if c.open > c.close {
                    bearStr += v
                } else {
                    bullStr += v
                }
            }
        }
        return (bullStr, bearStr)
    }

    private static func isOverlapping(_ newOb: OrderBlock, array: [OrderBlock]) -> Bool {
        for ob in array {
            if (newOb.top >= ob.btm && newOb.top <= ob.top) || (newOb.btm >= ob.btm && newOb.btm <= ob.top) {
                return true
            }
        }
        return false
    }
}

import Foundation
import SwiftUI

/// AlgoSmart Assist v2 Smart Money Concepts (SMC) Indicator.
/// Ported from PineScript v6 "ALGOSMART ASSIST v2" by Crypto Smart / AlbaTherium & Ma Bang Chu.
enum AlgoSmartAssist {

    /// The Pine `const string` captions. Consumers (the renderer, the SMC
    /// sentinel) match on these rather than on inline literals.
    enum Caption {
        static let idm = "I D M"
        static let choch = "CHoCH"
        static let bos = "B O S"
        static let sweep = "X"
        static let mid = "0.5"
        static let pdh = "PDH"
        static let pdl = "PDL"
    }

    enum BarColorType: String, Codable, Hashable {
        case scobUp
        case scobDn
        case isb
        case osbUp
        case osbDn
    }

    struct POIZone: Identifiable, Hashable {
        let id: String
        let startBar: Int
        var endBar: Int? // nil if extending to right edge
        let top: Double
        let bottom: Double
        let isSupply: Bool
        var isMitigated: Bool
    }

    struct StructureLine: Identifiable, Hashable {
        let id: String
        let startBar: Int
        let endBar: Int
        let price: Double
        let labelText: String // "B O S", "CHoCH", "I D M", "Sweep"
        let isBullish: Bool
        let isDashed: Bool
    }

    struct StructureLabel: Identifiable, Hashable {
        let id: String
        let bar: Int
        let price: Double
        let text: String // "HH", "LL", "HL", "LH", "I D M", "B O S", "CHoCH", "X"
        let isBullish: Bool
        let isCircle: Bool
        let isPullback: Bool
        /// Pine `colorText` in `drawIDM`: the IDM caption turns red when the
        /// leg that produced it was already swept
        /// (`trend and H_lastH > L_lastHH or not trend and H_lastLL > L_lastL`).
        var isWarning: Bool = false
    }

    struct TargetProfitLine: Identifiable, Hashable {
        let id: String
        let startBar: Int
        let fromPrice: Double
        let targetPrice: Double
        let isBullish: Bool
    }

    struct LiveLine: Identifiable, Hashable {
        let id: String
        let startBar: Int
        let price: Double
        let text: String
        let isBullish: Bool
        /// Pine `drawLiveStrc` extends each live line `length` bars past the
        /// last bar (the `leng*` inputs).
        let extendBars: Int
    }

    struct ColoredBar: Identifiable, Hashable {
        let id: String
        let barIndex: Int
        let colorType: BarColorType
    }

    struct Output: Hashable {
        let zones: [POIZone]
        let lines: [StructureLine]
        let labels: [StructureLabel]
        let tpLines: [TargetProfitLine]
        let liveLines: [LiveLine]
        let coloredBars: [ColoredBar]

        static var empty: Output {
            Output(zones: [], lines: [], labels: [], tpLines: [], liveLines: [], coloredBars: [])
        }

        /// Marks that overlap the visible bar window `loBar...hiBar`.
        ///
        /// This indicator emits marks for the *whole* series — a few thousand
        /// bars is ~1k marks, a couple of hundred of which the renderer hosts a
        /// real SwiftUI view for via `.annotation` — and Swift Charts lays every
        /// mark handed to it out on every pan/zoom frame. With the default
        /// 180-bar window that is ~95% wasted work, which is what made the chart
        /// lag whenever this indicator was switched on.
        ///
        /// `liveLines` are never culled: there are at most five and they are
        /// anchored to the right edge, which is what makes them "live".
        func culled(loBar: Int, hiBar: Int, barCount: Int, lastIndex: Int, labelBudget: Int = 80) -> Output {
            func overlaps(_ from: Int, _ to: Int) -> Bool { to >= loBar && from <= hiBar }

            // Labels are the priciest mark, so on top of culling they get a
            // density cap. Past it keep an evenly-strided sample rather than
            // truncating, so survivors stay spread across the window instead of
            // bunching at the left edge.
            let visibleLabels = labels.filter { $0.bar >= 0 && $0.bar < barCount && overlaps($0.bar, $0.bar) }
            let cappedLabels: [StructureLabel]
            if visibleLabels.count <= labelBudget || labelBudget <= 0 {
                cappedLabels = visibleLabels
            } else {
                let step = max(2, Int((Double(visibleLabels.count) / Double(labelBudget)).rounded(.up)))
                cappedLabels = visibleLabels.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
            }

            return Output(
                zones: zones.filter { overlaps($0.startBar, $0.endBar ?? lastIndex) },
                lines: lines.filter { overlaps($0.startBar, $0.endBar) },
                labels: cappedLabels,
                tpLines: tpLines.filter { overlaps($0.startBar, $0.startBar + 8) },
                liveLines: liveLines,
                coloredBars: coloredBars.filter {
                    $0.barIndex >= 0 && $0.barIndex < barCount && overlaps($0.barIndex, $0.barIndex)
                }
            )
        }
    }

    static func calculate(candles: [Candle], params: [String: ParamValue]) -> Output {
        guard candles.count >= 5 else { return .empty }

        // Parameters
        let showPOI = params["showPOI"]?.boolValue ?? true
        let poiType = params["poiType"]?.stringValue ?? "---"
        let mergeRatio = params["mergeRatio"]?.doubleValue ?? 0.0
        let maxBarHistory = Int(params["maxBarHistory"]?.doubleValue ?? 2000.0)

        let structureType = params["structureType"]?.stringValue ?? "Choch without IDM"
        let showHL = params["showHL"]?.boolValue ?? false
        let showCircleHL = params["showCircleHL"]?.boolValue ?? true
        let showMn = params["showMn"]?.boolValue ?? false
        let showBOS = params["showBOS"]?.boolValue ?? true
        let showChoCh = params["showChoCh"]?.boolValue ?? true
        let showIDM = params["showIDM"]?.boolValue ?? true
        let showPdhl = params["showPdhl"]?.boolValue ?? false
        let lengPdhl = Int(params["lengPdhl"]?.doubleValue ?? 40)
        let showMid = params["showMid"]?.boolValue ?? true
        let lengMid = Int(params["lengMid"]?.doubleValue ?? 40)
        let showSw = params["showSw"]?.boolValue ?? true
        let markX = params["markX"]?.boolValue ?? false
        let showTP = params["showTP"]?.boolValue ?? false
        let showliveBOS = params["showliveBOS"]?.boolValue ?? true
        let lengBos = Int(params["lengBos"]?.doubleValue ?? 40)
        let showliveChoch = params["showliveChoch"]?.boolValue ?? true
        let lengChoch = Int(params["lengChoch"]?.doubleValue ?? 40)
        let showliveIDM = params["showliveIDM"]?.boolValue ?? true
        let lengIDM = Int(params["lengIDM"]?.doubleValue ?? 15)
        let showSCOB = params["showSCOB"]?.boolValue ?? true
        let showISB = params["showISB"]?.boolValue ?? false
        let showOSB = params["showOSB"]?.boolValue ?? false

        // Previous Day High / Low
        let (pdh, pdl) = calculatePDHL(candles: candles)

        // Running state
        var L = candles[0].low
        var H = candles[0].high
        var idmLow = candles[0].low
        var idmHigh = candles[0].high
        var lastH = candles[0].high
        var lastL = candles[0].low
        var H_lastH = candles[0].high
        var L_lastHH = candles[0].low
        var H_lastLL = candles[0].high
        var L_lastL = candles[0].low
        var motherHigh = candles[0].high
        var motherLow = candles[0].low
        var motherBar = 0

        var idmLBar = 0
        var idmHBar = 0
        var HBar = 0
        var LBar = 0
        var lastHBar = 0
        var lastLBar = 0

        var mnStrc: Bool? = nil
        var prevMnStrc: Bool? = nil
        var top = candles[0].high
        var bot = candles[0].low
        var top_ = candles[0].high
        var bot_ = candles[0].low
        var bar = 0
        var bar_ = 0

        var isPrevBos: Bool? = nil
        var findIDM = false
        var isBosUp = false
        var isBosDn = false
        var isCocUp = true
        var isCocDn = true

        var isSweepOBS = false
        var current_OBS = 0
        var high_MOBS: Double = 0
        var low_MOBS: Double = 0

        var isSweepOBD = false
        var current_OBD = 0
        var low_MOBD: Double = 0
        var high_MOBD: Double = 0

        // Collections
        var puHigh: [Double] = []
        var puHBar: [Int] = []
        var puLow: [Double] = []
        var puLBar: [Int] = []

        var demandZone: [POIZone] = []
        var supplyZone: [POIZone] = []

        var arrLastH: [Double] = []
        var arrLastHBar: [Int] = []
        var arrLastL: [Double] = []
        var arrLastLBar: [Int] = []

        var arrIdmLine: [StructureLine] = []
        var arrIdmLabel: [StructureLabel] = []
        var arrBCLine: [StructureLine] = []
        var arrBCLabel: [StructureLabel] = []
        var arrHLLabel: [StructureLabel] = []
        var arrHLCircle: [StructureLabel] = []
        var pullbackLabels: [StructureLabel] = []
        var sweepLines: [StructureLine] = []
        var sweepLabels: [StructureLabel] = []
        var tpLines: [TargetProfitLine] = []
        var coloredBars: [ColoredBar] = []
        var isbHistory: [Bool] = Array(repeating: false, count: candles.count)
        var motherHighHistory: [Double] = Array(repeating: 0, count: candles.count)
        var motherLowHistory: [Double] = Array(repeating: 0, count: candles.count)
        var motherBarHistory: [Int] = Array(repeating: 0, count: candles.count)

        // Helper functions
        func getNLast<T>(_ arr: [T], _ n: Int) -> T? {
            guard arr.count >= n else { return nil }
            return arr[arr.count - n]
        }

        func removeLast<T>(_ arr: inout [T], _ n: Int) {
            let count = min(n, arr.count)
            if count > 0 {
                arr.removeLast(count)
            }
        }

        func removeNLast<T>(_ arr: inout [T], _ n: Int) {
            let index = arr.count - n
            if index >= 0 && index < arr.count {
                arr.remove(at: index)
            }
        }

        func removeIdm() {
            removeLast(&arrIdmLabel, 1)
            removeLast(&arrIdmLine, 1)
        }

        func fixStrcAfterBos() {
            removeLast(&arrBCLabel, 1)
            removeLast(&arrBCLine, 1)
            removeIdm()
            removeLast(&arrHLLabel, 2)
            removeLast(&arrHLCircle, 2)
        }

        func fixStrcAfterChoch() {
            removeLast(&arrBCLabel, 2)
            removeLast(&arrBCLine, 2)
            removeNLast(&arrHLLabel, 2)
            removeNLast(&arrHLLabel, 3)
            removeNLast(&arrHLCircle, 2)
            removeNLast(&arrHLCircle, 3)
            removeNLast(&arrIdmLabel, 2)
            removeNLast(&arrIdmLine, 2)
        }

        func updateLastH(barIdx: Int) {
            arrLastH.append(lastH)
            arrLastHBar.append(lastHBar)
        }

        func updateLastL(barIdx: Int) {
            arrLastL.append(lastL)
            arrLastLBar.append(lastLBar)
        }

        var seq = 0
        func nextSeq() -> Int { seq += 1; return seq }

        func drawIDM(trend: Bool, currentBar: Int) {
            let x = trend ? idmLBar : idmHBar
            let y = trend ? idmLow : idmHigh
            let s = nextSeq()
            // Pine: label style is `getStyleLabel(not trend)` — the IDM caption
            // sits below the level on an up leg and above it on a down leg.
            let isWarning = (trend && H_lastH > L_lastHH) || (!trend && H_lastLL > L_lastL)
            if showIDM {
                let lineId = "idm-line-\(currentBar)-\(s)"
                let ln = StructureLine(id: lineId, startBar: x, endBar: currentBar, price: y, labelText: Caption.idm, isBullish: trend, isDashed: false)
                let lblId = "idm-lbl-\(currentBar)-\(s)"
                let lbl = StructureLabel(id: lblId, bar: (x + currentBar) / 2, price: y, text: Caption.idm, isBullish: !trend, isCircle: false, isPullback: false, isWarning: isWarning)
                arrIdmLine.append(ln)
                arrIdmLabel.append(lbl)
            }
            if trend {
                puLow.removeAll()
                puLBar.removeAll()
            } else {
                puHigh.removeAll()
                puHBar.removeAll()
            }
        }

        func drawStructure(txt: String, trend: Bool, currentBar: Int) {
            let x = trend ? lastHBar : lastLBar
            let y = trend ? lastH : lastL
            let s = nextSeq()
            let lineId = "bc-line-\(currentBar)-\(s)"
            let ln = StructureLine(id: lineId, startBar: x, endBar: currentBar, price: y, labelText: txt, isBullish: trend, isDashed: true)
            let lblId = "bc-lbl-\(currentBar)-\(s)"
            let lbl = StructureLabel(id: lblId, bar: (x + currentBar) / 2, price: y, text: txt, isBullish: trend, isCircle: false, isPullback: false)

            if txt == Caption.bos && showBOS {
                arrBCLine.append(ln)
                arrBCLabel.append(lbl)
            } else if txt == Caption.choch && showChoCh {
                arrBCLine.append(ln)
                arrBCLabel.append(lbl)
            }
        }

        func drawPullback(x: Int, y: Double, trend: Bool) {
            if showMn {
                let s = nextSeq()
                let lbl = StructureLabel(id: "pb-\(x)-\(trend)-\(s)", bar: x, price: y, text: trend ? "▼" : "▲", isBullish: !trend, isCircle: false, isPullback: true)
                pullbackLabels.append(lbl)
            }
        }

        func drawHL(trend: Bool, txt: String, currentBar: Int) {
            let x = trend ? HBar : LBar
            let y = trend ? H : L
            let s = nextSeq()
            if showHL {
                let lbl = StructureLabel(id: "hl-\(currentBar)-\(txt)-\(s)", bar: x, price: y, text: txt, isBullish: trend, isCircle: false, isPullback: false)
                arrHLLabel.append(lbl)
            }
            if showCircleHL {
                let lbl2 = StructureLabel(id: "hlc-\(currentBar)-\(txt)-\(s)", bar: x, price: y, text: "", isBullish: trend, isCircle: true, isPullback: false)
                arrHLCircle.append(lbl2)
            }
        }

        func drawSweep(trend: Bool, currentBar: Int) {
            let x = trend ? lastHBar : lastLBar
            let y = trend ? lastH : lastL
            let s = nextSeq()
            if showSw {
                let ln = StructureLine(id: "sw-line-\(currentBar)-\(s)", startBar: x, endBar: currentBar, price: y, labelText: markX ? Caption.sweep : "", isBullish: trend, isDashed: false)
                sweepLines.append(ln)
                if markX {
                    let lbl = StructureLabel(id: "sw-lbl-\(currentBar)-\(s)", bar: (x + currentBar) / 2, price: y, text: Caption.sweep, isBullish: trend, isCircle: false, isPullback: false)
                    sweepLabels.append(lbl)
                }
            }
        }

        func drawTP(H: Double, L: Double, currentBar: Int) {
            guard showTP else { return }
            let s = nextSeq()
            var target = isCocUp ? candles[currentBar].high + abs(H - L) : candles[currentBar].low - abs(H - L)
            if target < 0 { target = 0 }
            let tp = TargetProfitLine(id: "tp-\(currentBar)-\(s)", startBar: currentBar, fromPrice: isCocUp ? candles[currentBar].high : candles[currentBar].low, targetPrice: target, isBullish: isCocUp)
            tpLines.append(tp)
        }

        func handleZone(zones: inout [POIZone], left: Int, top _topParam: Double, bot _botParam: Double, isSupply: Bool, currentBar: Int) {
            var _top = _topParam
            var _bot = _botParam
            var _left = left
            let s = nextSeq()

            // Pine reads `topZone`/`botZone` from the previous last zone once, up
            // front, and keeps using those values for the containment check below
            // even after the zone has been merged away — so they are captured here
            // rather than re-read from `zones.last`.
            if let lastZone = zones.last {
                let topZone = lastZone.top
                let botZone = lastZone.bottom
                let leftZone = lastZone.startBar
                let height = max(1e-6, topZone - botZone)

                let rangeTop = abs(_top - topZone) / height < mergeRatio
                let rangeBot = abs(_bot - botZone) / height < mergeRatio

                if (_top >= topZone && _bot <= botZone) || rangeTop || rangeBot {
                    _top = max(_top, topZone)
                    _bot = min(_bot, botZone)
                    _left = leftZone
                    zones.removeLast()
                }

                // Fully contained by the zone we compared against → nothing to add.
                if _top <= topZone && _bot >= botZone { return }
            }

            let newZone = POIZone(id: "zone-\(isSupply ? "sup" : "dem")-\(currentBar)-\(s)", startBar: _left, endBar: nil, top: _top, bottom: _bot, isSupply: isSupply, isMitigated: false)
            zones.append(newZone)
        }

        func processZones(zones: inout [POIZone], isSupply: Bool, currentBar: Int) -> [POIZone] {
            guard !zones.isEmpty else { return [] }
            var indicesToRemove = IndexSet()
            var breakers: [POIZone] = []
            let c = candles[currentBar]

            for i in (0..<zones.count).reversed() {
                var zone = zones[i]
                let topZone = zone.top
                let botZone = zone.bottom
                let leftZone = zone.startBar
                let s = nextSeq()

                // Breaker block check
                if isSupply && c.low < botZone && c.close > topZone {
                    let breakerZone = POIZone(id: "breaker-dem-\(currentBar)-\(i)-\(s)", startBar: leftZone, endBar: nil, top: topZone, bottom: botZone, isSupply: false, isMitigated: false)
                    breakers.append(breakerZone)
                    indicesToRemove.insert(i)
                    continue
                } else if !isSupply && c.high > topZone && c.close < botZone {
                    let breakerZone = POIZone(id: "breaker-sup-\(currentBar)-\(i)-\(s)", startBar: leftZone, endBar: nil, top: topZone, bottom: botZone, isSupply: true, isMitigated: false)
                    breakers.append(breakerZone)
                    indicesToRemove.insert(i)
                    continue
                } else if (isSupply && c.high >= botZone && c.high < topZone) || (!isSupply && c.low <= topZone && c.low > botZone) {
                    // Mitigated check
                    zone.endBar = currentBar
                    zone.isMitigated = true
                    zones[i] = zone
                }

                // Delete condition (exceeded history or completely passed through)
                if (currentBar - leftZone > maxBarHistory) || (isSupply && c.high >= topZone) || (!isSupply && c.low <= botZone) {
                    indicesToRemove.insert(i)
                }
            }

            for idx in indicesToRemove.reversed() {
                if idx < zones.count {
                    zones.remove(at: idx)
                }
            }
            return breakers
        }

        func checkSCOB(zones: [POIZone], isSupply: Bool, currentBar: Int) -> BarColorType? {
            guard currentBar >= 2, let lastZone = zones.last else { return nil }
            let topZone = lastZone.top
            let botZone = lastZone.bottom

            let isbPrev = isbHistory[currentBar - 1]
            if !isbPrev {
                let low1 = candles[currentBar - 1].low
                let low2 = candles[currentBar - 2].low
                let low0 = candles[currentBar].low
                let close0 = candles[currentBar].close
                let high1 = candles[currentBar - 1].high
                let high2 = candles[currentBar - 2].high
                let high0 = candles[currentBar].high

                if !isSupply && low1 < low2 && low1 < low0 && close0 > high1 && low1 < topZone && low1 > botZone {
                    return .scobUp
                } else if isSupply && high1 > high2 && high1 > high0 && close0 < low1 && high1 < topZone && high1 > botZone {
                    return .scobDn
                }
            }
            return nil
        }

        // Loop bar by bar
        for i in 0..<candles.count {
            let c = candles[i]

            // 1. Inside Bar (ISB)
            let isb = motherHigh > c.high && motherLow < c.low
            isbHistory[i] = isb
            if isb {
                // motherHigh, motherLow, motherBar unchanged
            } else {
                motherHigh = c.high
                motherLow = c.low
                motherBar = i
            }
            motherHighHistory[i] = motherHigh
            motherLowHistory[i] = motherLow
            motherBarHistory[i] = motherBar

            // 2. Outside Bar (OSB)
            let osb = c.high > top && c.low < bot
            let isGreen = c.close > c.open

            // 3. Pullbacks
            if c.high >= top && c.low <= bot {
                if mnStrc != nil { prevMnStrc = mnStrc }
                if prevMnStrc == true {
                    top_ = top; bar_ = bar
                } else {
                    bot_ = bot; bar_ = bar
                }
                top = c.high; bot = c.low; bar = i; mnStrc = nil
            }

            if c.high >= top && c.low > bot {
                if prevMnStrc == true && mnStrc == nil {
                    puHBar.append(bar_)
                    puHigh.append(top_)
                    puLBar.append(bar)
                    puLow.append(bot)
                    drawPullback(x: bar_, y: top_, trend: true)
                    drawPullback(x: bar, y: bot, trend: false)
                } else if (prevMnStrc == false && mnStrc == nil) || mnStrc == false {
                    puLBar.append(bar)
                    puLow.append(bot)
                    drawPullback(x: bar, y: bot, trend: false)
                }
                top = c.high; bot = c.low; bar = i; prevMnStrc = nil; mnStrc = true
            }

            if c.high < top && c.low <= bot {
                if prevMnStrc == false && mnStrc == nil {
                    puHBar.append(bar)
                    puHigh.append(top)
                    puLBar.append(bar_)
                    puLow.append(bot_)
                    drawPullback(x: bar, y: top, trend: true)
                    drawPullback(x: bar_, y: bot_, trend: false)
                } else if (prevMnStrc == true && mnStrc == nil) || mnStrc == true {
                    puHBar.append(bar)
                    puHigh.append(top)
                    drawPullback(x: bar, y: top, trend: true)
                }
                top = c.high; bot = c.low; bar = i; prevMnStrc = nil; mnStrc = false
            }

            // 4. Update IDM Anchors
            if c.high >= H {
                H = c.high; HBar = i; L_lastHH = c.low
                if let lastLow = puLow.last, let lastLBarVal = puLBar.last {
                    idmLow = lastLow; idmLBar = lastLBarVal
                }
            }

            if c.low <= L {
                L = c.low; LBar = i; H_lastLL = c.high
                if let lastHigh = puHigh.last, let lastHBarVal = puHBar.last {
                    idmHigh = lastHigh; idmHBar = lastHBarVal
                }
            }

            // 5. Structure mapping
            // Check for IDM
            if findIDM && isCocUp {
                if c.low < idmLow {
                    findIDM = false
                    isBosUp = false
                    L = c.low
                    LBar = i
                    if structureType == "Choch with IDM" && idmLow == lastL {
                        if isPrevBos == true {
                            fixStrcAfterBos()
                            if let valL = getNLast(arrLastL, 1), let valLBar = getNLast(arrLastLBar, 1) {
                                lastL = valL; lastLBar = valLBar
                            }
                            lastH = H; lastHBar = HBar
                            drawIDM(trend: true, currentBar: i)
                            drawHL(trend: true, txt: "HH", currentBar: i)
                            updateLastH(barIdx: i); updateLastL(barIdx: i)
                            if let valH = getNLast(arrLastH, 1) { H_lastH = valH }
                        } else {
                            fixStrcAfterChoch()
                            isCocUp = false; isCocDn = true
                        }
                    } else {
                        lastH = H; lastHBar = HBar
                        drawIDM(trend: true, currentBar: i)
                        drawHL(trend: true, txt: "HH", currentBar: i)
                        updateLastH(barIdx: i); updateLastL(barIdx: i)
                        if let valH = getNLast(arrLastH, 1) { H_lastH = valH }
                    }
                }
            }

            if findIDM && isCocDn && isBosDn {
                if c.high > idmHigh {
                    findIDM = false
                    isBosDn = false
                    H = c.high
                    HBar = i
                    if structureType == "Choch with IDM" && idmHigh == lastH {
                        if isPrevBos == true {
                            fixStrcAfterBos()
                            if let valH = getNLast(arrLastH, 1), let valHBar = getNLast(arrLastHBar, 1) {
                                lastH = valH; lastHBar = valHBar
                            }
                            lastL = L; lastLBar = LBar
                            drawIDM(trend: false, currentBar: i)
                            drawHL(trend: false, txt: "LL", currentBar: i)
                            updateLastH(barIdx: i); updateLastL(barIdx: i)
                            if let valL = getNLast(arrLastL, 1) { L_lastL = valL }
                        } else {
                            fixStrcAfterChoch()
                            isCocUp = true; isCocDn = false
                        }
                    } else {
                        lastL = L; lastLBar = LBar
                        drawIDM(trend: false, currentBar: i)
                        drawHL(trend: false, txt: "LL", currentBar: i)
                        updateLastH(barIdx: i); updateLastL(barIdx: i)
                        if let valL = getNLast(arrLastL, 1) { L_lastL = valL }
                    }
                }
            }

            // Check for CHoCH
            if isCocDn && c.high > lastH {
                if structureType == "Choch without IDM" && idmHigh == lastH && c.close > idmHigh {
                    removeIdm()
                }
                if c.close > lastH {
                    drawStructure(txt: Caption.choch, trend: true, currentBar: i)
                    findIDM = true; isBosUp = true; isCocUp = true
                    isBosDn = false; isCocDn = false; isPrevBos = false
                    if let valL = getNLast(arrLastL, 1) { L_lastL = valL }
                    drawTP(H: lastH, L: lastL, currentBar: i)
                } else {
                    drawSweep(trend: true, currentBar: i)
                }
            }

            if isCocUp && c.low < lastL {
                if structureType == "Choch without IDM" && idmLow == lastL && c.close < idmLow {
                    removeIdm()
                }
                if c.close < lastL {
                    drawStructure(txt: Caption.choch, trend: false, currentBar: i)
                    findIDM = true; isBosUp = false; isCocUp = false
                    isBosDn = true; isCocDn = true; isPrevBos = false
                    if let valH = getNLast(arrLastH, 1) { H_lastH = valH }
                    drawTP(H: lastH, L: lastL, currentBar: i)
                } else {
                    drawSweep(trend: false, currentBar: i)
                }
            }

            // Check for BoS
            if !findIDM && !isBosUp && isCocUp {
                if c.high > lastH {
                    if c.close > lastH {
                        drawStructure(txt: Caption.bos, trend: true, currentBar: i)
                        findIDM = true; isBosUp = true; isCocUp = true
                        isBosDn = false; isCocDn = false; isPrevBos = true
                        drawHL(trend: false, txt: "HL", currentBar: i)
                        lastL = L; lastLBar = LBar; L_lastL = L
                        drawTP(H: lastH, L: lastL, currentBar: i)
                    } else {
                        drawSweep(trend: true, currentBar: i)
                    }
                }
            }

            if !findIDM && !isBosDn && isCocDn {
                if c.low < lastL {
                    if c.close < lastL {
                        drawStructure(txt: Caption.bos, trend: false, currentBar: i)
                        findIDM = true; isBosUp = false; isCocUp = false
                        isBosDn = true; isCocDn = true; isPrevBos = true
                        drawHL(trend: true, txt: "LH", currentBar: i)
                        lastH = H; lastHBar = HBar; H_lastH = H
                        drawTP(H: lastH, L: lastL, currentBar: i)
                    } else {
                        drawSweep(trend: false, currentBar: i)
                    }
                }
            }

            // Update High & Low
            if c.high > lastH {
                lastH = c.high; lastHBar = i
            }
            if c.low < lastL {
                lastL = c.low; lastLBar = i
            }

            // 6. POI (Demand & Supply) Detection
            if showPOI {
                // Supply POI detection (3 bars back)
                if !isSweepOBS {
                    if i >= 4 {
                        high_MOBS = candles[i - 3].high
                        low_MOBS = candles[i - 3].low
                        current_OBS = i - 3
                        if high_MOBS > candles[i - 4].high && high_MOBS > candles[i - 2].high {
                            isSweepOBS = true
                        }
                    }
                } else {
                    if i >= 1 && low_MOBS > candles[i - 1].high {
                        handleZone(zones: &supplyZone, left: current_OBS, top: high_MOBS, bot: low_MOBS, isSupply: true, currentBar: i)
                        isSweepOBS = false
                    } else if i >= 2 {
                        if poiType == "Mother Bar" && isbHistory[i - 2] {
                            high_MOBS = max(high_MOBS, motherHighHistory[i - 2])
                            low_MOBS = min(low_MOBS, motherLowHistory[i - 2])
                            current_OBS = min(current_OBS, motherBarHistory[i - 2])
                        } else {
                            high_MOBS = candles[i - 2].high
                            low_MOBS = candles[i - 2].low
                            current_OBS = i - 2
                        }
                    }
                }

                // Demand POI detection (3 bars back)
                if !isSweepOBD {
                    if i >= 4 {
                        low_MOBD = candles[i - 3].low
                        high_MOBD = candles[i - 3].high
                        current_OBD = i - 3
                        if low_MOBD < candles[i - 4].low && low_MOBD < candles[i - 2].low {
                            isSweepOBD = true
                        }
                    }
                } else {
                    if i >= 1 && high_MOBD < candles[i - 1].low {
                        handleZone(zones: &demandZone, left: current_OBD, top: high_MOBD, bot: low_MOBD, isSupply: false, currentBar: i)
                        isSweepOBD = false
                    } else if i >= 2 {
                        if poiType == "Mother Bar" && isbHistory[i - 2] {
                            high_MOBD = max(high_MOBD, motherHighHistory[i - 2])
                            low_MOBD = min(low_MOBD, motherLowHistory[i - 2])
                            current_OBD = min(current_OBD, motherBarHistory[i - 2])
                        } else {
                            high_MOBD = candles[i - 2].high
                            low_MOBD = candles[i - 2].low
                            current_OBD = i - 2
                        }
                    }
                }
            }

            // 7. Bar Colors & Zone Lifecycle
            if showSCOB {
                if let scobType = checkSCOB(zones: supplyZone, isSupply: true, currentBar: i) {
                    coloredBars.append(ColoredBar(id: "scob-\(i)", barIndex: i, colorType: scobType))
                }
                if let scobType = checkSCOB(zones: demandZone, isSupply: false, currentBar: i) {
                    coloredBars.append(ColoredBar(id: "scob-\(i)", barIndex: i, colorType: scobType))
                }
            }
            if showISB && isb {
                coloredBars.append(ColoredBar(id: "isb-\(i)", barIndex: i, colorType: .isb))
            }
            if showOSB && osb {
                coloredBars.append(ColoredBar(id: "osb-\(i)", barIndex: i, colorType: isGreen ? .osbUp : .osbDn))
            }

            let demBreakers = processZones(zones: &supplyZone, isSupply: true, currentBar: i)
            let supBreakers = processZones(zones: &demandZone, isSupply: false, currentBar: i)
            demandZone.append(contentsOf: demBreakers)
            supplyZone.append(contentsOf: supBreakers)
        }

        // Live structure lines on final bar
        var liveLines: [LiveLine] = []
        let lastIdx = candles.count - 1

        if showliveIDM && findIDM {
            let x = isCocUp ? idmLBar : idmHBar
            let y = isCocUp ? idmLow : idmHigh
            liveLines.append(LiveLine(id: "live-idm", startBar: x, price: y, text: String(format: "I D M - %.2f", y), isBullish: isCocUp, extendBars: lengIDM))
        }
        if showliveChoch {
            // Pine passes `not isCocUp` as the trend: in a down leg the live CHoCH
            // sits on the last high, in an up leg on the last low.
            let trend = !isCocUp
            let x = trend ? lastHBar : lastLBar
            let y = trend ? lastH : lastL
            liveLines.append(LiveLine(id: "live-choch", startBar: x, price: y, text: String(format: "CHoCH - %.2f", y), isBullish: trend, extendBars: lengChoch))
        }
        if showliveBOS && !findIDM {
            let x = isCocUp ? lastHBar : lastLBar
            let y = isCocUp ? lastH : lastL
            liveLines.append(LiveLine(id: "live-bos", startBar: x, price: y, text: String(format: "B O S - %.2f", y), isBullish: isCocUp, extendBars: lengBos))
        }
        if showPdhl, let pdhVal = pdh, let pdlVal = pdl {
            let pdhBar = pdhlBar(candles: candles, value: pdhVal, isHigh: true) ?? max(0, lastIdx - lengPdhl)
            let pdlBar = pdhlBar(candles: candles, value: pdlVal, isHigh: false) ?? max(0, lastIdx - lengPdhl)
            liveLines.append(LiveLine(id: "live-pdh", startBar: pdhBar, price: pdhVal, text: String(format: "PDH - %.2f", pdhVal), isBullish: true, extendBars: lengPdhl))
            liveLines.append(LiveLine(id: "live-pdl", startBar: pdlBar, price: pdlVal, text: String(format: "PDL - %.2f", pdlVal), isBullish: false, extendBars: lengPdhl))
        }
        if showMid {
            let x = min(lastHBar, lastLBar)
            let midPrice = (lastH + lastL) / 2.0
            liveLines.append(LiveLine(id: "live-mid", startBar: x, price: midPrice, text: String(format: "0.5 - %.2f", midPrice), isBullish: true, extendBars: lengMid))
        }

        let allZones = showPOI ? (demandZone + supplyZone) : []
        let allLines = arrBCLine + arrIdmLine + sweepLines
        let allLabels = arrBCLabel + arrIdmLabel + arrHLLabel + arrHLCircle + pullbackLabels + sweepLabels

        return Output(
            zones: allZones,
            lines: allLines,
            labels: allLabels,
            tpLines: tpLines,
            liveLines: liveLines,
            coloredBars: coloredBars
        )
    }

    /// Pine `getPdhlBar` — walks back over the last two days of bars to find the
    /// bar that actually printed the previous-day high/low, so the live PDH/PDL
    /// line starts there rather than at a fixed offset.
    private static func pdhlBar(candles: [Candle], value: Double, isHigh: Bool) -> Int? {
        let cal = Calendar.current
        guard let lastDate = candles.last?.id,
              let cutoff = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: lastDate))
        else { return nil }

        for i in stride(from: candles.count - 1, through: 0, by: -1) {
            let c = candles[i]
            if c.id < cutoff { break }
            if isHigh ? (c.high == value) : (c.low == value) { return i }
        }
        return nil
    }

    private static func calculatePDHL(candles: [Candle]) -> (pdh: Double?, pdl: Double?) {
        guard let lastCandle = candles.last else { return (nil, nil) }
        let cal = Calendar.current
        let lastDay = cal.startOfDay(for: lastCandle.id)

        guard let prevDay = cal.date(byAdding: .day, value: -1, to: lastDay) else { return (nil, nil) }
        let prevDayCandles = candles.filter { cal.isDate($0.id, inSameDayAs: prevDay) }

        if prevDayCandles.isEmpty {
            let earlierCandles = candles.filter { cal.startOfDay(for: $0.id) < lastDay }
            guard let latestEarlierDay = earlierCandles.last.map({ cal.startOfDay(for: $0.id) }) else { return (nil, nil) }
            let dayCandles = earlierCandles.filter { cal.isDate($0.id, inSameDayAs: latestEarlierDay) }
            let high = dayCandles.map { $0.high }.max()
            let low = dayCandles.map { $0.low }.min()
            return (high, low)
        } else {
            let high = prevDayCandles.map { $0.high }.max()
            let low = prevDayCandles.map { $0.low }.min()
            return (high, low)
        }
    }
}

import Foundation
import XCTest
@testable import HelixTradingApp

/// Unit tests for the ALGOSMART-ASSIST-driven SMC sentinel strategy.
///
/// The indicator is path-dependent — structure is built bar by bar from index
/// 0 — so hand-authoring a series that lands on one specific setup is brittle.
/// These tests therefore split into two kinds: exact assertions on the pure
/// helpers, and strategy-rule invariants asserted over generated markets
/// (whatever setups come out, every one of them must obey the rules).
final class SMCSentinelEngineTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func candle(_ i: Int, o: Double, h: Double, l: Double, c: Double, v: Double = 100) -> Candle {
        Candle(id: start.addingTimeInterval(TimeInterval(i * 60)), open: o, high: h, low: l, close: c, volume: v)
    }

    /// Deterministic pseudo-random zig-zag market: a trend with regular
    /// pullbacks, which is what the indicator needs to print BOS/CHoCH/IDM
    /// and lay down order blocks.
    private func syntheticMarket(bars: Int, drift: Double, seed: UInt64 = 42) -> [Candle] {
        var rng = seed
        func next() -> Double {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Double((rng >> 33) % 1000) / 1000.0
        }

        var candles: [Candle] = []
        var price = 2000.0
        let dir = drift >= 0 ? 1.0 : -1.0
        let mag = abs(drift)

        // A 14-bar SMC cycle: a wicky pullback that builds inducement
        // liquidity, then a sharp 3-bar impulse. The impulse leaves the
        // imbalance the indicator needs to lay down an order block — a smooth
        // random walk never prints one.
        for i in 0..<bars {
            let phase = i % 14
            let open = price
            var close: Double
            var wick: Double

            switch phase {
            case 0..<6:                                  // deep pullback back into the POIs
                close = price - dir * mag * (0.7 + next() * 0.5)
                wick = mag * (0.5 + next())
            case 6..<9:                                  // impulse: big body, tiny wick
                close = price + dir * mag * (1.9 + next() * 0.6)
                wick = mag * 0.04
            default:                                     // drift on with the trend
                close = price + dir * mag * (0.1 + next() * 0.3)
                wick = mag * (0.4 + next() * 0.8)
            }

            let high = max(open, close) + wick
            let low = min(open, close) - wick
            candles.append(candle(i, o: open, h: high, l: low, c: close, v: 100 + next() * 900))
            price = close
        }
        return candles
    }

    private func aggregate(_ candles: [Candle], factor: Int) -> [Candle] {
        var out: [Candle] = []
        var i = 0
        while i < candles.count {
            let end = min(i + factor, candles.count)
            let slice = Array(candles[i..<end])
            guard let f = slice.first, let l = slice.last else { break }
            out.append(Candle(
                id: f.id, open: f.open,
                high: slice.map(\.high).max() ?? f.high,
                low: slice.map(\.low).min() ?? f.low,
                close: l.close,
                volume: slice.compactMap(\.volume).reduce(0, +)
            ))
            i = end
        }
        return out
    }

    // MARK: - Pure helpers

    func testTickSizeScalesWithPriceMagnitude() {
        XCTAssertEqual(SMCSentinelEngine.tickSize(for: 2400), 0.01)
        XCTAssertEqual(SMCSentinelEngine.tickSize(for: 150), 0.01)
        XCTAssertEqual(SMCSentinelEngine.tickSize(for: 42), 0.001)
        XCTAssertEqual(SMCSentinelEngine.tickSize(for: 1.2345), 0.0001)
        XCTAssertEqual(SMCSentinelEngine.tickSize(for: 0.5), 0.00001)
    }

    /// The strategy asks for "2-5 ticks" beyond the zone, but a raw tick count
    /// is meaningless on a volatile instrument, so the buffer is floored at a
    /// fraction of ATR.
    func testStopBufferIsFlooredByATR() {
        let tickOnly = 3 * SMCSentinelEngine.tickSize(for: 2400)
        XCTAssertEqual(SMCSentinelEngine.stopBuffer(price: 2400, atr: 0.0), tickOnly, accuracy: 1e-9)

        let volatile = SMCSentinelEngine.stopBuffer(price: 2400, atr: 5.0)
        XCTAssertEqual(volatile, 0.4, accuracy: 1e-9)
        XCTAssertGreaterThan(volatile, tickOnly)
    }

    func testATRIsPositiveOnRealSeriesAndSafeOnEmpty() {
        XCTAssertEqual(SMCSentinelEngine.atr14([]), 1.0)
        XCTAssertGreaterThan(SMCSentinelEngine.atr14(syntheticMarket(bars: 60, drift: 4)), 0)
    }

    /// Sweeps, IDM and BOS/CHoCH all land in the same flattened `lines` array;
    /// the strategy tells them apart purely by caption.
    func testStructureEventsSelectOnlyBOSAndCHoCH() {
        func line(_ caption: String, _ bar: Int) -> AlgoSmartAssist.StructureLine {
            AlgoSmartAssist.StructureLine(id: caption + "\(bar)", startBar: 0, endBar: bar,
                                          price: 1, labelText: caption, isBullish: true, isDashed: true)
        }
        let out = AlgoSmartAssist.Output(
            zones: [],
            lines: [line(AlgoSmartAssist.Caption.idm, 1),
                    line(AlgoSmartAssist.Caption.bos, 5),
                    line(AlgoSmartAssist.Caption.sweep, 3),
                    line(AlgoSmartAssist.Caption.choch, 2)],
            labels: [], tpLines: [], liveLines: [], coloredBars: []
        )

        let events = SMCSentinelEngine.structureEvents(out)
        XCTAssertEqual(events.map(\.labelText), [AlgoSmartAssist.Caption.choch, AlgoSmartAssist.Caption.bos])
        XCTAssertEqual(events.map(\.endBar), [2, 5], "events must be oldest-first")
    }

    func testMajorSwingsPickHighsForLongsAndLowsForShorts() {
        func label(_ text: String, _ price: Double) -> AlgoSmartAssist.StructureLabel {
            AlgoSmartAssist.StructureLabel(id: text + "\(price)", bar: 0, price: price, text: text,
                                           isBullish: true, isCircle: false, isPullback: false)
        }
        let out = AlgoSmartAssist.Output(
            zones: [], lines: [],
            labels: [label("HH", 10), label("LH", 9), label("LL", 1), label("HL", 2), label("I D M", 5)],
            tpLines: [], liveLines: [], coloredBars: []
        )

        XCTAssertEqual(SMCSentinelEngine.majorSwings(out, isLong: true).sorted(), [9, 10])
        XCTAssertEqual(SMCSentinelEngine.majorSwings(out, isLong: false).sorted(), [1, 2])
    }

    /// A SCOB only triggers when its *close* is inside the POI — a bar that
    /// merely wicks through the zone is not an entry.
    func testSCOBTriggerRequiresCloseInsideZone() {
        let zone = AlgoSmartAssist.POIZone(id: "z", startBar: 0, endBar: nil,
                                           top: 105, bottom: 100, isSupply: false, isMitigated: false)
        let candles = [
            candle(0, o: 102, h: 106, l: 99, c: 103),   // closes inside
            candle(1, o: 110, h: 112, l: 104, c: 111),  // wicks in, closes outside
        ]
        let inside = AlgoSmartAssist.Output(
            zones: [], lines: [], labels: [], tpLines: [], liveLines: [],
            coloredBars: [AlgoSmartAssist.ColoredBar(id: "a", barIndex: 0, colorType: .scobUp)]
        )
        let outside = AlgoSmartAssist.Output(
            zones: [], lines: [], labels: [], tpLines: [], liveLines: [],
            coloredBars: [AlgoSmartAssist.ColoredBar(id: "b", barIndex: 1, colorType: .scobUp)]
        )

        XCTAssertEqual(
            SMCSentinelEngine.findTrigger(zone: zone, isLong: true, grabBar: 0, candles: candles, ltf: inside)?.kind,
            .scob
        )
        XCTAssertNil(
            SMCSentinelEngine.findTrigger(zone: zone, isLong: true, grabBar: 0, candles: candles, ltf: outside)
        )
    }

    /// A bearish SCOB must not trigger a long.
    func testSCOBTriggerIgnoresOppositeDirection() {
        let zone = AlgoSmartAssist.POIZone(id: "z", startBar: 0, endBar: nil,
                                           top: 105, bottom: 100, isSupply: false, isMitigated: false)
        let candles = [candle(0, o: 102, h: 106, l: 99, c: 103)]
        let out = AlgoSmartAssist.Output(
            zones: [], lines: [], labels: [], tpLines: [], liveLines: [],
            coloredBars: [AlgoSmartAssist.ColoredBar(id: "a", barIndex: 0, colorType: .scobDn)]
        )
        XCTAssertNil(SMCSentinelEngine.findTrigger(zone: zone, isLong: true, grabBar: 0, candles: candles, ltf: out))
    }

    /// Triggers before the liquidity grab belong to the previous leg.
    func testTriggerBeforeLiquidityGrabIsIgnored() {
        let zone = AlgoSmartAssist.POIZone(id: "z", startBar: 0, endBar: nil,
                                           top: 105, bottom: 100, isSupply: false, isMitigated: false)
        let candles = (0..<6).map { candle($0, o: 102, h: 106, l: 99, c: 103) }
        let out = AlgoSmartAssist.Output(
            zones: [], lines: [], labels: [], tpLines: [], liveLines: [],
            coloredBars: [AlgoSmartAssist.ColoredBar(id: "a", barIndex: 2, colorType: .scobUp)]
        )
        XCTAssertNotNil(SMCSentinelEngine.findTrigger(zone: zone, isLong: true, grabBar: 2, candles: candles, ltf: out))
        XCTAssertNil(SMCSentinelEngine.findTrigger(zone: zone, isLong: true, grabBar: 4, candles: candles, ltf: out))
    }

    // MARK: - Scan guards

    func testShortSeriesIsRejectedBeforeAnyWork() {
        let result = SMCSentinelEngine.scan(candles: syntheticMarket(bars: 30, drift: 4), htfCandles: [], htfLabel: "1h")
        XCTAssertTrue(result.setups.isEmpty)
        XCTAssertEqual(result.blocker, .notEnoughBars)
    }

    func testEmptyInputIsSafe() {
        let result = SMCSentinelEngine.scan(candles: [], htfCandles: [], htfLabel: "1h")
        XCTAssertTrue(result.setups.isEmpty)
        XCTAssertEqual(result.blocker, .notEnoughBars)
    }

    /// A scan that yields nothing must still say which rule blocked it, so the
    /// drawer can explain an empty radar.
    func testBlockerIsReportedWhenNoSetupQualifies() {
        let flat = (0..<200).map { candle($0, o: 2000, h: 2000.5, l: 1999.5, c: 2000) }
        let result = SMCSentinelEngine.scan(candles: flat, htfCandles: aggregate(flat, factor: 4), htfLabel: "1h")
        XCTAssertTrue(result.setups.isEmpty)
        XCTAssertNotEqual(result.blocker, .none, "an empty scan must name the blocking rule")
    }

    // MARK: - Strategy invariants

    /// Every published setup must obey the written strategy: direction follows
    /// the HTF context, the POI sits on the right side of equilibrium, the stop
    /// is beyond the zone, and TP1/TP2 run the right way with at least 1R.
    func testGeneratedSetupsObeyStrategyRules() {
        var checked = 0

        // Sweep seeds, trend direction and where the series ends: a setup only
        // exists while price is retracing into the POI, so the end phase of the
        // generated cycle decides whether one is live.
        for seed in UInt64(1)...10 {
            for drift in [4.0, -4.0] {
              for bars in [409, 412, 421, 424, 427] {
                let candles = syntheticMarket(bars: bars, drift: drift, seed: seed)
                let result = SMCSentinelEngine.scan(
                    candles: candles,
                    htfCandles: aggregate(candles, factor: 4),
                    htfLabel: "1h"
                )

                guard let context = result.context, let eq = result.equilibrium else {
                    XCTAssertTrue(result.setups.isEmpty, "setups cannot exist without context + equilibrium")
                    continue
                }

                for s in result.setups {
                    checked += 1

                    XCTAssertEqual(s.isLong, context.isBullish,
                                   "direction must come from the HTF context — no counter-trend setups")

                    let mid = (s.zoneTop + s.zoneBottom) / 2
                    if s.isLong {
                        XCTAssertLessThanOrEqual(mid, eq, "a long must mitigate a POI in discount")
                        XCTAssertLessThan(s.stopLoss, s.zoneBottom, "long stop sits below the demand zone")
                        XCTAssertGreaterThan(s.takeProfit1, s.entry)
                        XCTAssertGreaterThan(s.takeProfit2, s.takeProfit1, "TP2 must be beyond TP1")
                    } else {
                        XCTAssertGreaterThanOrEqual(mid, eq, "a short must mitigate a POI in premium")
                        XCTAssertGreaterThan(s.stopLoss, s.zoneTop, "short stop sits above the supply zone")
                        XCTAssertLessThan(s.takeProfit1, s.entry)
                        XCTAssertLessThan(s.takeProfit2, s.takeProfit1, "TP2 must be beyond TP1")
                    }

                    XCTAssertGreaterThanOrEqual(s.riskReward, 1.0, "sub-1R setups must be discarded")
                    XCTAssertGreaterThan(s.zoneTop, s.zoneBottom)
                    XCTAssertTrue((0...100).contains(s.score))
                    XCTAssertEqual(s.equilibrium, eq)

                    // A setup is only ACTIVE once a trigger actually printed.
                    if s.status == .active {
                        XCTAssertTrue(s.breakdown.hasTrigger, "ACTIVE requires a SCOB or LTF CHoCH trigger")
                    }
                    XCTAssertNotEqual(s.status, .invalidated, "invalidated setups are never published")

                    // The score must be the sum of its published parts.
                    let b = s.breakdown
                    let summed = b.baseScore + b.ltfAlignBonus + b.idmSweepBonus + b.liquiditySweepBonus
                        + b.equilibriumBonus + b.triggerBonus + b.freshZoneBonus
                    XCTAssertEqual(s.score, min(100, summed), "score must equal its breakdown")
                }

                XCTAssertLessThanOrEqual(result.setups.count, SMCSentinelEngine.maxSetupsPerSymbol)

                // Ranked strongest-first.
                let scores = result.setups.map(\.score)
                XCTAssertEqual(scores, scores.sorted(by: >), "setups must be ranked by score")
              }
            }
        }

        XCTAssertGreaterThan(checked, 0, "the generated markets produced no setups at all — test is vacuous")
    }

    /// The grab is what separates this strategy from "buy any order block":
    /// a setup may only exist once IDM or a swing sweep has been taken.
    func testEverySetupIsBackedByALiquidityGrab() {
        for seed in UInt64(1)...10 {
          for bars in [409, 412, 421, 424, 427] {
            let candles = syntheticMarket(bars: bars, drift: 4, seed: seed)
            let result = SMCSentinelEngine.scan(
                candles: candles,
                htfCandles: aggregate(candles, factor: 4),
                htfLabel: "1h"
            )
            for s in result.setups {
                XCTAssertTrue(
                    s.breakdown.idmSweepBonus > 0 || s.breakdown.liquiditySweepBonus > 0,
                    "setup published without an IDM or liquidity sweep"
                )
            }
          }
        }
    }

    func testScanIsDeterministic() {
        let candles = syntheticMarket(bars: 423, drift: 4, seed: 1)
        let htf = aggregate(candles, factor: 4)
        let a = SMCSentinelEngine.scan(candles: candles, htfCandles: htf, htfLabel: "1h")
        let b = SMCSentinelEngine.scan(candles: candles, htfCandles: htf, htfLabel: "1h")
        XCTAssertEqual(a, b)
    }
}

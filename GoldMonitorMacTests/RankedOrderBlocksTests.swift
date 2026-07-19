import Foundation
import XCTest
@testable import HelixTradingApp

/// Locks in the port of the "Ranked Order Blocks [VP + Ichimoku]" Pine
/// indicator: detection geometry, grading bounds, and the mitigation
/// lifecycle.
final class RankedOrderBlocksTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func candle(_ i: Int, o: Double, h: Double, l: Double, c: Double, v: Double? = 1) -> Candle {
        Candle(id: start.addingTimeInterval(TimeInterval(i * 60)), open: o, high: h, low: l, close: c, volume: v)
    }

    /// 14 flat seed bars (small range → small ATR), then a small bearish
    /// OB candle, then a strong bullish displacement, then `tailBars`
    /// trailing bars produced by `tail` (defaults to non-mitigating flats
    /// just above the block).
    private func bullishScenario(
        tailBars: Int = 2,
        tail: (Int) -> Candle
    ) -> [Candle] {
        var cs: [Candle] = []
        for i in 0..<14 { cs.append(candle(i, o: 100, h: 100.1, l: 99.9, c: 100)) }
        // Bearish OB candle: body 100→99.8, wicks 100.05 / 99.75.
        cs.append(candle(14, o: 100, h: 100.05, l: 99.75, c: 99.8))
        // Bullish impulse: body 1.7 ≫ 1.5 × ATR(~0.2).
        cs.append(candle(15, o: 99.8, h: 101.6, l: 99.8, c: 101.5))
        for j in 0..<tailBars { cs.append(tail(16 + j)) }
        return cs
    }

    private func compute(
        _ candles: [Candle],
        zoneSrc: String = "Wicks",
        mitBy: String = "Close",
        removeMit: Bool = true,
        useVP: Bool = false,
        useIchi: Bool = false
    ) -> RankedOrderBlocks.Output {
        RankedOrderBlocks.compute(
            candles,
            dispMult: 1.5, atrLen: 14, zoneSrc: zoneSrc, mitBy: mitBy,
            useBOS: false, bosLen: 10, maxOBs: 10, removeMit: removeMit,
            useVP: useVP, vpLookback: 200, vpRows: 24,
            useIchi: useIchi, tenkan: 9, kijun: 26, senkouB: 52, ichiDisp: 26
        )
    }

    // MARK: - Detection & geometry

    func testBullishBlockDetectedFromWicks() {
        let cs = bullishScenario { candle($0, o: 101.5, h: 101.6, l: 101.4, c: 101.5) }
        let out = compute(cs)
        XCTAssertEqual(out.zones.count, 1)
        let z = out.zones[0]
        XCTAssertTrue(z.isBullish)
        XCTAssertEqual(z.startIndex, 14)           // the OB candle, one before the impulse
        XCTAssertEqual(z.high, 100.05, accuracy: 1e-6)  // wick range
        XCTAssertEqual(z.low, 99.75, accuracy: 1e-6)
    }

    func testBodyModeUsesCandleBody() {
        let cs = bullishScenario { candle($0, o: 101.5, h: 101.6, l: 101.4, c: 101.5) }
        let out = compute(cs, zoneSrc: "Body")
        XCTAssertEqual(out.zones.count, 1)
        XCTAssertEqual(out.zones[0].high, 100.0, accuracy: 1e-6)   // max(open, close)
        XCTAssertEqual(out.zones[0].low, 99.8, accuracy: 1e-6)     // min(open, close)
    }

    // MARK: - Grading bounds

    func testGradeDashWhenNoRankingEnabled() {
        let cs = bullishScenario { candle($0, o: 101.5, h: 101.6, l: 101.4, c: 101.5) }
        let z = compute(cs).zones[0]
        XCTAssertEqual(z.grade, "–")
        XCTAssertEqual(z.score, 0)
        XCTAssertEqual(z.maxScore, 0)
    }

    func testMaxScoreReflectsEnabledRankings() {
        let cs = bullishScenario { candle($0, o: 101.5, h: 101.6, l: 101.4, c: 101.5) }
        XCTAssertEqual(compute(cs, useVP: true).zones.first?.maxScore, 2)
        XCTAssertEqual(compute(cs, useIchi: true).zones.first?.maxScore, 3)
        let both = compute(cs, useVP: true, useIchi: true).zones.first
        XCTAssertEqual(both?.maxScore, 5)
        XCTAssertTrue(["A", "B", "C"].contains(both?.grade ?? ""))
    }

    // MARK: - Mitigation lifecycle

    func testMitigatedBlockRemovedByDefault() {
        // A trailing bar closes below the block low (99.75) → mitigated.
        let cs = bullishScenario(tailBars: 1) { candle($0, o: 99.7, h: 99.8, l: 99.5, c: 99.6) }
        let out = compute(cs, removeMit: true)
        XCTAssertTrue(out.zones.isEmpty)
    }

    func testMitigatedBlockKeptGreyedWhenRemoveOff() {
        let cs = bullishScenario(tailBars: 1) { candle($0, o: 99.7, h: 99.8, l: 99.5, c: 99.6) }
        let out = compute(cs, removeMit: false)
        XCTAssertEqual(out.zones.count, 1)
        XCTAssertTrue(out.zones[0].mitigated)
    }

    func testWickMitigationTriggersOnLowNotClose() {
        // Trailing bar dips its wick below the low but closes back above it.
        let cs = bullishScenario(tailBars: 1) { candle($0, o: 100.2, h: 100.3, l: 99.5, c: 100.2) }
        // Close-based mitigation: close stays above → block survives.
        XCTAssertEqual(compute(cs, mitBy: "Close").zones.count, 1)
        // Wick-based mitigation: the low pierced the block → removed.
        XCTAssertTrue(compute(cs, mitBy: "Wick").zones.isEmpty)
    }

    // MARK: - Degenerate input

    func testEmptyInput() {
        XCTAssertTrue(compute([]).zones.isEmpty)
    }
}

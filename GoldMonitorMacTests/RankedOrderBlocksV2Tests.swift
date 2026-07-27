import Foundation
import XCTest
@testable import HelixTradingApp

final class RankedOrderBlocksV2Tests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func c(_ i: Int, _ o: Double, _ h: Double, _ l: Double, _ close: Double, _ v: Double = 100) -> Candle {
        Candle(id: start.addingTimeInterval(TimeInterval(i * 60)), open: o, high: h, low: l, close: close, volume: v)
    }

    private func bullishBase() -> [Candle] {
        [
            c(0, 105, 106, 105, 105), c(1, 104, 105, 104, 104),
            c(2, 103, 104, 103, 103), c(3, 102, 103, 102, 102),
            c(4, 100, 101, 100, 100), c(5, 99, 100, 99, 99),      // low pivot (pivotIdx = 5 - 3 = 2)
            c(6, 101, 102, 101, 101), c(7, 103, 104, 103, 103),
            c(8, 105, 106, 105, 105),                              // high pivot (106)
            c(9, 104, 105, 104, 104), c(10, 102, 103, 102, 102),
            c(11, 100, 101, 100, 100, 400),                        // OB candle
            c(12, 102, 108, 102, 108, 500),                        // Displacement expansion (>1.2 ATR)
            c(13, 108, 110, 108, 110, 300),                        // break > 106
        ]
    }

    func testDetectsBullishBlockV2() {
        var cfg = RankedOrderBlocksV2.Config()
        cfg.swingLength = 3
        cfg.requireDisplacement = true

        let zones = RankedOrderBlocksV2.compute(bullishBase(), config: cfg)
        let bull = zones.filter(\.isBullish)
        XCTAssertFalse(bull.isEmpty, "expected at least one bullish V2 order block")

        let z = bull[0]
        XCTAssertFalse(z.isBreaker)
        XCTAssertLessThan(z.bottom, z.top)
        XCTAssertTrue(z.hasDisplacement)
        XCTAssertGreaterThanOrEqual(z.volumeDelta, 0.0)
        XCTAssertLessThanOrEqual(z.volumeDelta, 1.0)
        XCTAssertEqual(z.touchCount, 0)
    }

    func testFreshnessTouchTracking() {
        var cfg = RankedOrderBlocksV2.Config()
        cfg.swingLength = 3

        var cs = bullishBase()
        // Append a candle that taps back into the zone ([100, 101])
        cs.append(c(14, 105, 105, 100.5, 104, 200))

        let zones = RankedOrderBlocksV2.compute(cs, config: cfg)
        let bull = zones.filter(\.isBullish)
        XCTAssertFalse(bull.isEmpty)
        if let z = bull.first {
            XCTAssertGreaterThanOrEqual(z.touchCount, 1, "expected at least 1 touch to be tracked")
        }
    }

    func testDisplacementFiltering() {
        var cfgStrict = RankedOrderBlocksV2.Config()
        cfgStrict.swingLength = 3
        cfgStrict.requireDisplacement = true

        // Base with small sluggish candles (no expansion body > 1.2 ATR, no FVG)
        let sluggish = [
            c(0, 105, 106, 105, 105), c(1, 104, 105, 104, 104),
            c(2, 103, 104, 103, 103), c(3, 102, 103, 102, 102),
            c(4, 100, 101, 100, 100), c(5, 99, 100, 99, 99),
            c(6, 101, 102, 101, 101), c(7, 103, 104, 103, 103),
            c(8, 105, 105.5, 105, 105.5),
            c(9, 104, 104.5, 104, 104.5), c(10, 102, 102.5, 102, 102.5),
            c(11, 100, 100.2, 100, 100.1, 100),                    // OB candle (body 0.1)
            c(12, 100.1, 100.3, 100.1, 100.2, 100),                // tiny body 0.1
            c(13, 100.2, 105.6, 100.2, 105.6, 100),                // break
        ]

        var cfgRelaxed = cfgStrict
        cfgRelaxed.requireDisplacement = false

        let strictZones = RankedOrderBlocksV2.compute(sluggish, config: cfgStrict)
        let relaxedZones = RankedOrderBlocksV2.compute(sluggish, config: cfgRelaxed)

        XCTAssertGreaterThanOrEqual(relaxedZones.count, strictZones.count)
    }

    func testEmptyInput() {
        XCTAssertTrue(RankedOrderBlocksV2.compute([], config: RankedOrderBlocksV2.Config()).isEmpty)
    }
}

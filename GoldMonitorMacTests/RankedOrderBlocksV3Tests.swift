import Foundation
import XCTest
@testable import HelixTradingApp

final class RankedOrderBlocksV3Tests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func c(_ i: Int, _ o: Double, _ h: Double, _ l: Double, _ close: Double, _ v: Double = 100) -> Candle {
        Candle(id: start.addingTimeInterval(TimeInterval(i * 60)), open: o, high: h, low: l, close: close, volume: v)
    }

    private func bullishBase() -> [Candle] {
        [
            c(0, 105, 106, 105, 105), c(1, 104, 105, 104, 104),
            c(2, 103, 104, 103, 103), c(3, 102, 103, 102, 102),
            c(4, 100, 101, 100, 100), c(5, 99, 100, 99, 99),      // low pivot
            c(6, 101, 102, 101, 101), c(7, 103, 104, 103, 103),
            c(8, 105, 106, 105, 105),                              // high pivot (106)
            c(9, 104, 105, 104, 104), c(10, 102, 103, 102, 102),
            c(11, 101, 102, 99.5, 100, 400),                       // OB candle (Red bearish: open 101, low 99.5)
            c(12, 100, 112, 100, 112, 500),                        // Large expansion > 106
            c(13, 112, 114, 112, 114, 300),
        ]
    }

    func testDetectsBullishBlockV3() {
        var cfg = RankedOrderBlocksV3.Config()
        cfg.swingLength = 3
        cfg.zoneSource = .institutional

        let zones = RankedOrderBlocksV3.compute(bullishBase(), config: cfg)
        let bull = zones.filter(\.isBullish)
        XCTAssertFalse(bull.isEmpty, "expected at least one bullish V3 order block")

        let z = bull[0]
        XCTAssertFalse(z.isBreaker)
        // Institutional Bullish OB: Low (99.5) to Open (101)
        XCTAssertEqual(z.bottom, 99.5, accuracy: 1e-6)
        XCTAssertEqual(z.top, 101.0, accuracy: 1e-6)
        XCTAssertEqual(z.equilibrium, (99.5 + 101.0) / 2.0, accuracy: 1e-6)
    }

    func testROCTriggerEngine() {
        var cfg = RankedOrderBlocksV3.Config()
        cfg.triggerEngine = .momentumROC
        cfg.rocSensitivity = 2.0
        cfg.requireDisplacement = false

        let series = [
            c(0, 100, 101, 100, 100), c(1, 100, 101, 100, 100),
            c(2, 100, 101, 100, 100), c(3, 100, 101, 100, 100),
            c(4, 100, 100.5, 98.5, 99, 400),                       // Counter-trend red candle
            c(5, 103, 112, 103, 112, 500),                        // ROC surge
            c(6, 112, 114, 112, 114, 300),
            c(7, 114, 116, 114, 116, 300),
            c(8, 116, 118, 116, 118, 300),
            c(9, 118, 120, 118, 120, 300),
        ]

        let zones = RankedOrderBlocksV3.compute(series, config: cfg)
        XCTAssertFalse(zones.isEmpty, "expected momentum ROC trigger to detect an order block")
    }

    func testEquilibriumMitigation() {
        var cfg = RankedOrderBlocksV3.Config()
        cfg.swingLength = 3
        cfg.zoneSource = .institutional

        var cs = bullishBase()
        // Zone top = 101, bottom = 99.5, eq = 100.25
        // Append candle 14 that taps down to 100.0 (breaching 50% eq)
        cs.append(c(14, 105, 105, 100.0, 104, 200))

        let zones = RankedOrderBlocksV3.compute(cs, config: cfg)
        let bull = zones.filter(\.isBullish)
        XCTAssertFalse(bull.isEmpty)
        if let z = bull.first {
            XCTAssertTrue(z.isEqBreached, "expected 50% equilibrium breach to be flagged")
        }
    }

    func testEmptyInput() {
        XCTAssertTrue(RankedOrderBlocksV3.compute([], config: RankedOrderBlocksV3.Config()).isEmpty)
    }
}

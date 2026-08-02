import Foundation
import XCTest
@testable import HelixTradingApp

/// Unit tests for Helix + Price Action Volumetric Order Blocks [Combo].
final class HelixOBComboTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func c(_ i: Int, _ o: Double, _ h: Double, _ l: Double, _ close: Double, _ v: Double = 100) -> Candle {
        Candle(id: start.addingTimeInterval(TimeInterval(i * 60)), open: o, high: h, low: l, close: close, volume: v)
    }

    func testHelixOBComboReturnsPointsForCandles() {
        var candles: [Candle] = []
        for i in 0..<50 {
            let p = 100.0 + Double(i) * 0.5
            candles.append(c(i, p, p + 1.0, p - 0.5, p + 0.2, 500))
        }

        let output = HelixOBCombo.compute(candles, params: [:])

        XCTAssertEqual(output.points.count, 50)
        XCTAssertFalse(output.emaPoints.isEmpty)
    }

    func testHelixOBComboDetectsDirectionFlip() {
        var candles: [Candle] = []
        // Strong uptrend
        for i in 0..<30 {
            let p = 100.0 + Double(i) * 2.0
            candles.append(c(i, p, p + 1.0, p - 0.2, p + 0.8, 500))
        }
        // Sudden crash
        for i in 30..<50 {
            let p = 160.0 - Double(i - 30) * 3.0
            candles.append(c(i, p, p + 0.2, p - 1.0, p - 0.8, 500))
        }

        let output = HelixOBCombo.compute(candles, params: ["atrLength": .double(2), "atrMult": .double(1.0)])

        let dirs = output.points.map(\.dir)
        XCTAssertTrue(dirs.contains(1), "Expected long direction in uptrend")
        XCTAssertTrue(dirs.contains(-1), "Expected short direction flip after crash")
    }

    func testHelixOBComboCreatesOrderBlocksOnStructureBreak() {
        let swingLength = 3
        var candles: [Candle] = []

        // Form pivot low at bar 5, pivot high at bar 8, OB red candle at bar 11, break up at bar 14
        let basePrices: [(Double, Double, Double, Double)] = [
            (105, 106, 105, 105), (104, 105, 104, 104),
            (103, 104, 103, 103), (102, 103, 102, 102),
            (100, 101, 100, 100), (99, 100, 99, 99),      // pivot low (bar 5)
            (101, 102, 101, 101), (103, 104, 103, 103),
            (105, 106, 105, 105),                        // pivot high 106 (bar 8)
            (104, 105, 104, 104), (102, 103, 102, 102),
            (101, 102, 99.5, 100),                       // red OB candle (bar 11)
            (102, 103, 102, 102), (104, 105, 104, 104),
            (106, 108, 106, 107.5)                       // close break > 106 (bar 14)
        ]

        for (i, p) in basePrices.enumerated() {
            candles.append(c(i, p.0, p.1, p.2, p.3, 500))
        }

        let output = HelixOBCombo.compute(candles, params: [
            "swingLength": .double(Double(swingLength)),
            "showLastXOb": .double(4),
            "violationType": .string("Wick"),
            "hideOverlap": .string("False")
        ])

        XCTAssertFalse(output.structures.isEmpty, "Expected MSB or BOS structure line")
        XCTAssertFalse(output.bullishOBs.isEmpty, "Expected bullish order block created on structure break")
    }
}

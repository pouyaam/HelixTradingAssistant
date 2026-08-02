import XCTest
@testable import HelixTradingApp

final class RenkoTests: XCTestCase {

    private func makeCandles(prices: [Double], intervalSeconds: TimeInterval = 60) -> [Candle] {
        let baseDate = Date(timeIntervalSince1970: 1700000000)
        return prices.enumerated().map { i, p in
            Candle(
                id: baseDate.addingTimeInterval(Double(i) * intervalSeconds),
                open: p,
                high: p + 0.5,
                low: p - 0.5,
                close: p,
                volume: 100
            )
        }
    }

    func testRenkoFixedUpBricks() {
        // Given prices rising from 100 to 105 with fixed box size = 1.0
        let prices = [100.0, 101.0, 102.0, 103.0, 104.0, 105.0]
        let candles = makeCandles(prices: prices)
        let config = RenkoConfig(mode: .fixed, fixedBoxSize: 1.0)

        let bricks = Renko.transform(candles, config: config)

        XCTAssertFalse(bricks.isEmpty)
        XCTAssertEqual(bricks.count, 5)
        XCTAssertEqual(bricks[0].open, 100.0)
        XCTAssertEqual(bricks[0].close, 101.0)
        XCTAssertEqual(bricks[4].open, 104.0)
        XCTAssertEqual(bricks[4].close, 105.0)
    }

    func testRenkoFixedDownBricks() {
        // Given prices falling from 100 to 95 with fixed box size = 1.0
        let prices = [100.0, 99.0, 98.0, 97.0, 96.0, 95.0]
        let candles = makeCandles(prices: prices)
        let config = RenkoConfig(mode: .fixed, fixedBoxSize: 1.0)

        let bricks = Renko.transform(candles, config: config)

        XCTAssertFalse(bricks.isEmpty)
        XCTAssertEqual(bricks.count, 5)
        XCTAssertEqual(bricks[0].open, 100.0)
        XCTAssertEqual(bricks[0].close, 99.0)
        XCTAssertEqual(bricks[4].open, 96.0)
        XCTAssertEqual(bricks[4].close, 95.0)
    }

    func testRenkoReversalTwoBricks() {
        // Prices rise 100 -> 103, then reverse down to 100
        let prices = [100.0, 101.0, 102.0, 103.0, 100.0]
        let candles = makeCandles(prices: prices)
        let config = RenkoConfig(mode: .fixed, fixedBoxSize: 1.0)

        let bricks = Renko.transform(candles, config: config)

        // Initial UP bricks: 100->101, 101->102, 102->103 (3 UP bricks)
        // Reversal DOWN from 103 requires dropping to <= 101 (2 box sizes below close 103)
        // From 103 down to 100 creates DOWN bricks: 102->101, 101->100
        XCTAssertGreaterThanOrEqual(bricks.count, 4)
        XCTAssertEqual(bricks[0].close, 101.0)
        XCTAssertEqual(bricks[1].close, 102.0)
        XCTAssertEqual(bricks[2].close, 103.0)
        XCTAssertTrue(bricks.last!.close < bricks.last!.open)
    }

    func testRenkoATRMode() {
        let prices = [100.0, 102.0, 101.0, 105.0, 103.0, 108.0]
        let candles = makeCandles(prices: prices)
        let atr = Renko.computeATR(candles, period: 5)
        XCTAssertGreaterThan(atr, 0.0)

        let config = RenkoConfig(mode: .atr, atrPeriod: 5)
        let bricks = Renko.transform(candles, config: config)
        XCTAssertFalse(bricks.isEmpty)
    }

    // MARK: - Rendering window

    /// Realistic gold-ish intraday series: 360 one-minute bars drifting
    /// inside a few dollars, which an ATR box turns into far fewer bricks
    /// than candles — the case that rendered a blank chart.
    private func makeRealisticCandles(count: Int = 360) -> [Candle] {
        let base = Date(timeIntervalSince1970: 1700000000)
        var price = 2400.0
        var out: [Candle] = []
        for i in 0..<count {
            // Deterministic wobble — no RNG, so the test can't flake.
            price += sin(Double(i) / 7.0) * 0.35 + cos(Double(i) / 23.0) * 0.15
            out.append(Candle(
                id: base.addingTimeInterval(Double(i) * 60),
                open: price, high: price + 0.4, low: price - 0.4,
                close: price, volume: 10
            ))
        }
        return out
    }

    /// The Renko brick array is a different length than the candle array,
    /// and the chart plots at bar *index*. If the visible window is sized
    /// to `candles.count` while the bricks are drawn, every rendered index
    /// lands past the end of the brick array and nothing is drawn.
    /// Regression test for the blank Renko chart.
    func testRenkoBricksProduceNonEmptyRenderWindow() {
        let candles = makeRealisticCandles()
        let bricks = Renko.transform(candles, config: RenkoConfig(mode: .atr, atrPeriod: 14))

        XCTAssertFalse(bricks.isEmpty)
        // The interesting case: meaningfully fewer bricks than candles.
        XCTAssertLessThan(bricks.count, candles.count)

        // Window sized to the DRAWN series (the fix) → bricks actually render.
        let good = ChartWindow.renderIndices(
            domain: ChartWindow.defaultDomain(count: bricks.count),
            count: bricks.count
        )
        XCTAssertFalse(good.isEmpty, "Renko bricks must produce a non-empty render window")
        XCTAssertTrue(good.allSatisfy { $0 >= 0 && $0 < bricks.count },
                      "every rendered index must be a valid brick index")

        // Window sized to the RAW candle count (the bug) → every index is
        // out of range for the brick array, i.e. a blank chart.
        let bad = ChartWindow.renderIndices(
            domain: ChartWindow.defaultDomain(count: candles.count),
            count: candles.count
        )
        XCTAssertTrue(bad.allSatisfy { $0 >= bricks.count },
                      "candle-space window should fall entirely outside the brick array")
    }

    /// A pinned zoom window from candle space must not survive into Renko:
    /// `visibleBounds` returning nil is the signal `effectiveXDomain` uses
    /// to fall back to a default window instead of framing nothing.
    func testStaleCandleSpaceDomainIsDetectedAsNonIntersecting() {
        let candles = makeRealisticCandles()
        let bricks = Renko.transform(candles, config: RenkoConfig(mode: .atr, atrPeriod: 14))
        let stalePin = ChartWindow.defaultDomain(count: candles.count)

        XCTAssertNil(
            ChartWindow.visibleBounds(domain: stalePin, count: bricks.count),
            "a candle-space window must read as non-intersecting for the brick series"
        )
        // …and the fallback window it triggers does frame the bricks.
        let fallback = ChartWindow.defaultDomain(count: bricks.count)
        XCTAssertNotNil(ChartWindow.visibleBounds(domain: fallback, count: bricks.count))
    }

    func testRenkoConfigRawValueEncodingAndEquality() {
        let config = RenkoConfig(mode: .fixed, atrPeriod: 14, fixedBoxSize: 2.5)
        let raw = config.rawValue
        XCTAssertFalse(raw.isEmpty)
        XCTAssertNotEqual(raw, "{}")

        let decoded = RenkoConfig(rawValue: raw)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(decoded?.mode, .fixed)
        XCTAssertEqual(decoded?.fixedBoxSize, 2.5)
    }

    /// A payload persisted before shadows were removed still carries a
    /// `showWicks` key. It must keep decoding — `JSONDecoder` ignores
    /// unknown keys — so an existing user's settings don't reset.
    func testLegacyRawValueWithShowWicksStillDecodes() {
        let legacy = #"{"fixedBoxSize":2.5,"showWicks":false,"atrPeriod":14,"mode":"Fixed"}"#
        let decoded = RenkoConfig(rawValue: legacy)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.mode, .fixed)
        XCTAssertEqual(decoded?.atrPeriod, 14)
        XCTAssertEqual(decoded?.fixedBoxSize, 2.5)
    }

    // MARK: - No shadows

    /// A Renko brick is a pure box: it represents a fixed price move, not
    /// a time period, so it has no intrabar excursion to draw a shadow
    /// for. High/low must equal the body bounds on every brick, even
    /// though the source candles have highs and lows well outside them.
    func testRenkoBricksHaveNoShadows() {
        // Source candles deliberately carry wide highs/lows (±0.5).
        let candles = makeCandles(prices: [100, 101, 102, 103, 100, 98, 101, 105])
        for config in [RenkoConfig(mode: .fixed, fixedBoxSize: 1.0),
                       RenkoConfig(mode: .atr, atrPeriod: 5)] {
            let bricks = Renko.transform(candles, config: config)
            XCTAssertFalse(bricks.isEmpty)
            for b in bricks {
                XCTAssertEqual(b.high, max(b.open, b.close), accuracy: 1e-9,
                               "brick high must be the body top — no upper shadow")
                XCTAssertEqual(b.low, min(b.open, b.close), accuracy: 1e-9,
                               "brick low must be the body bottom — no lower shadow")
            }
        }
    }

    /// Every brick is exactly one box tall, and consecutive bricks are
    /// contiguous (each opens where the previous closed) except across a
    /// reversal, where the traditional one-box gap applies.
    func testRenkoBricksAreUniformHeightAndContiguous() {
        let box = 1.0
        let candles = makeRealisticCandles()
        let bricks = Renko.transform(candles, config: RenkoConfig(mode: .fixed, fixedBoxSize: box))
        XCTAssertGreaterThan(bricks.count, 2)

        for b in bricks {
            XCTAssertEqual(abs(b.close - b.open), box, accuracy: 1e-9,
                           "every brick body must be exactly one box tall")
        }
        for (prev, cur) in zip(bricks, bricks.dropFirst()) {
            let prevUp = prev.close > prev.open
            let curUp = cur.close > cur.open
            if prevUp == curUp {
                XCTAssertEqual(cur.open, prev.close, accuracy: 1e-9,
                               "a continuation brick opens where the previous closed")
            } else {
                // Reversal: starts one box away from the previous close.
                let expected = prev.close + (curUp ? box : -box)
                XCTAssertEqual(cur.open, expected, accuracy: 1e-9,
                               "a reversal brick starts one box off the previous close")
            }
        }
    }
}

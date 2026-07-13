import Foundation
import XCTest
@testable import HelixTradingApp

final class SP2LSetupTests: XCTestCase {
    func testLongTakeProfitsUseMultiplesOfFirstTargetDistance() {
        let result = makeResult(direction: .long, entry: 100, stopLoss: 99, takeProfit: 101)

        XCTAssertEqual(result.takeProfits(count: 3), [101, 102, 103])
    }

    func testShortTakeProfitsUseMultiplesOfFirstTargetDistance() {
        let result = makeResult(direction: .short, entry: 100, stopLoss: 101, takeProfit: 99)

        XCTAssertEqual(result.takeProfits(count: 3), [99, 98, 97])
    }

    func testTakeProfitCountIsClampedToSupportedRange() {
        let result = makeResult(direction: .long, entry: 100, stopLoss: 99, takeProfit: 101)

        XCTAssertEqual(result.takeProfits(count: 0), [101])
        XCTAssertEqual(result.takeProfits(count: 4), [101, 102, 103])
    }

    func testDetectsBullishSpikeBreakingRecentStructuralHigh() {
        var candles = balancedWarmup()
        candles += bullishSpike()

        let result = detect(candles).last

        XCTAssertEqual(result?.direction, .long)
        XCTAssertEqual(result?.brokenLevel ?? 0, 100.25, accuracy: 0.0001)
        XCTAssertEqual(result?.breakoutIndex, 16)
        XCTAssertEqual(result?.followThroughIndex, 17)
    }

    func testRejectsLargeMoveThatDoesNotBreakRecentStructuralHigh() {
        var candles = balancedWarmup()
        candles[7] = candle(100.0, 103.0, 99.75, 100.0)
        candles += bullishSpike()

        XCTAssertTrue(detect(candles).isEmpty)
    }

    func testRejectsWickOnlyBreakWithoutStrongClose() {
        var candles = balancedWarmup()
        candles += [
            candle(100.0, 101.4, 99.9, 100.2),
            candle(100.2, 102.4, 100.1, 102.2),
        ]

        XCTAssertTrue(detect(candles).isEmpty)
    }

    func testRejectsPressureGapThatIsOnlyMarketNoise() {
        var candles = balancedWarmup()
        candles += [
            candle(100.0, 101.4, 99.9, 101.2),
            candle(101.2, 102.4, 100.26, 102.2),
        ]

        XCTAssertTrue(detect(candles).isEmpty)
    }

    func testDetectsMirroredBearishStructuralBreak() {
        var candles = balancedWarmup()
        candles += [
            candle(100.0, 100.1, 98.6, 98.8),
            candle(98.8, 99.1, 97.6, 97.8),
        ]

        let result = detect(candles).last

        XCTAssertEqual(result?.direction, .short)
        XCTAssertEqual(result?.brokenLevel ?? 0, 99.75, accuracy: 0.0001)
    }

    private func makeResult(
        direction: SP2LSetup.Direction,
        entry: Double,
        stopLoss: Double,
        takeProfit: Double
    ) -> SP2LSetup.Result {
        SP2LSetup.Result(
            spikeStartIndex: 1,
            spikeEndIndex: 2,
            breakoutIndex: 1,
            followThroughIndex: 2,
            spikeHigh: 101,
            spikeLow: 99,
            brokenLevel: 100,
            levelStartIndex: 0,
            gapStartIndex: 0,
            gapEndIndex: 2,
            gapLow: 99.5,
            gapHigh: 100.5,
            direction: direction,
            stage: .limitPending,
            entry: entry,
            stopLoss: stopLoss,
            takeProfit: takeProfit,
            emaValue: nil
        )
    }

    private func detect(_ candles: [Candle]) -> [SP2LSetup.Result] {
        SP2LSetup.compute(
            candles,
            minSpikeBars: 2,
            maxSpikeBars: 2,
            rangeBars: 4,
            atrPeriod: 4,
            minSpikeATR: 1.0,
            maxSpikeATR: 6.0,
            maxRangeATR: 1.5,
            useEMAContext: false,
            maxPullbackBars: 3,
            maxContinuationBars: 5
        )
    }

    private func balancedWarmup() -> [Candle] {
        (0..<16).map { index in
            candle(100.0, 100.25, 99.75, index.isMultiple(of: 2) ? 100.05 : 99.95)
        }
    }

    private func bullishSpike() -> [Candle] {
        [
            candle(100.0, 101.4, 99.9, 101.2),
            candle(101.2, 102.4, 100.9, 102.2),
        ]
    }

    private func candle(_ open: Double, _ high: Double, _ low: Double, _ close: Double) -> Candle {
        defer { nextTimestamp += 60 }
        return Candle(
            id: Date(timeIntervalSince1970: TimeInterval(nextTimestamp)),
            open: open,
            high: high,
            low: low,
            close: close
        )
    }

    private var nextTimestamp = 1_700_000_000

    override func setUp() {
        super.setUp()
        nextTimestamp = 1_700_000_000
    }
}

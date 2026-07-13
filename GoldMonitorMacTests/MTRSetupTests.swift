import Foundation
import XCTest
@testable import HelixTradingApp

final class MTRSetupTests: XCTestCase {
    func testDetectsBullishHigherLowAndConfirmsAtNecklineBreak() {
        let result = detect(bullishMTR(retestLow: 99.2, retestClose: 100)).first {
            $0.direction == .long && $0.variant == .higherLow
        }

        XCTAssertEqual(result?.stage, .confirmed)
        XCTAssertEqual(result?.breakoutIndex, 9)
        XCTAssertEqual(result?.retestIndex, 11)
        XCTAssertEqual(result?.confirmationIndex, 13)
        XCTAssertEqual(result?.entry ?? 0, 109.5, accuracy: 0.0001)
        XCTAssertEqual(result?.stopLoss ?? 0, 99.2, accuracy: 0.0001)
        XCTAssertEqual(result?.takeProfit ?? 0, 130.1, accuracy: 0.0001)
    }

    func testClassifiesDoubleBottom() {
        let result = detect(bullishMTR(retestLow: 98.1, retestClose: 99)).first {
            $0.direction == .long && $0.variant == .doubleBottom
        }
        XCTAssertNotNil(result)
    }

    func testClassifiesFailedLowerLowOnlyWhenCandleReclaimsOldExtreme() {
        let valid = detect(bullishMTR(retestLow: 97.2, retestClose: 99)).first {
            $0.direction == .long && $0.variant == .lowerLow
        }
        let rejected = detect(bullishMTR(retestLow: 97.2, retestClose: 97.8)).first {
            $0.direction == .long && $0.variant == .lowerLow
        }

        XCTAssertNotNil(valid)
        XCTAssertNil(rejected)
    }

    func testDetectsMirroredBearishVariants() {
        let lowerHigh = detect(mirror(bullishMTR(retestLow: 99.2, retestClose: 100))).first {
            $0.direction == .short && $0.variant == .lowerHigh
        }
        let doubleTop = detect(mirror(bullishMTR(retestLow: 98.1, retestClose: 99))).first {
            $0.direction == .short && $0.variant == .doubleTop
        }
        let higherHigh = detect(mirror(bullishMTR(retestLow: 97.2, retestClose: 99))).first {
            $0.direction == .short && $0.variant == .higherHigh
        }

        XCTAssertNotNil(lowerHigh)
        XCTAssertNotNil(doubleTop)
        XCTAssertNotNil(higherHigh)
    }

    func testWickOnlyChannelBreakIsRejected() {
        var candles = bullishMTR(retestLow: 99.2, retestClose: 100)
        candles[9] = candle(100, 110, 99, 105)

        XCTAssertTrue(detect(candles).filter { $0.direction == .long }.isEmpty)
    }

    func testFailedBreakBeyondConfiguredOvershootIsRejected() {
        let candles = bullishMTR(retestLow: 90, retestClose: 99)
        var config = testConfiguration()
        config.maxFailedBreakATR = 0.5

        let result = MTRSetup.compute(candles, configuration: config).first {
            $0.direction == .long && $0.variant == .lowerLow
        }
        XCTAssertNil(result)
    }

    func testPatternRemainsFormingWithoutNecklineClose() {
        var candles = bullishMTR(retestLow: 99.2, retestClose: 100)
        candles[13] = candle(104, 107.8, 103, 107)
        candles[14] = candle(107, 107.5, 105, 106)

        let result = detect(candles).first { $0.direction == .long }
        XCTAssertEqual(result?.stage, .forming)
        XCTAssertNil(result?.confirmationIndex)
    }

    func testUnconfirmedPatternExpiresAfterDeadline() {
        var candles = bullishMTR(retestLow: 99.2, retestClose: 100)
        candles[13] = candle(104, 107.8, 103, 107)
        candles[14] = candle(107, 107.5, 105, 106)
        candles += [
            candle(106, 107, 104, 105),
            candle(105, 106, 103, 104),
        ]
        var config = testConfiguration()
        config.maxConfirmationBars = 3

        let result = MTRSetup.compute(candles, configuration: config).first { $0.direction == .long }
        XCTAssertEqual(result?.stage, .expired)
    }

    func testStopWinsWhenStopAndTargetTouchSameCandle() {
        var candles = bullishMTR(retestLow: 99.2, retestClose: 100)
        candles.append(candle(110, 131, 98, 120))

        let result = detect(candles).first { $0.direction == .long && $0.isConfirmed }
        XCTAssertEqual(result?.stage, .hitSL)
        XCTAssertEqual(result?.resolveIndex, 15)
    }

    func testRequiresEstablishedFourPivotTrend() {
        let candles = Array(bullishMTR(retestLow: 99.2, retestClose: 100).dropFirst(5))
        XCTAssertTrue(detect(candles).isEmpty)
    }

    func testOlderIndicatorConfigDecodesWithMTRDefaults() throws {
        let legacy = Data("{\"rsiPeriod\":7}".utf8)
        let config = try JSONDecoder().decode(OscillatorConfig.self, from: legacy)

        XCTAssertEqual(config.rsiPeriod, 7)
        XCTAssertEqual(config.mtrPivotDepth, 3)
        XCTAssertEqual(config.mtrATRPeriod, 14)
        XCTAssertEqual(config.mtrRiskReward, 2.0)
        XCTAssertEqual(config.mtrMaxResults, 12)
    }

    private func detect(_ candles: [Candle]) -> [MTRSetup.Result] {
        MTRSetup.compute(candles, configuration: testConfiguration())
    }

    private func testConfiguration() -> MTRSetup.Configuration {
        var config = MTRSetup.Configuration()
        config.pivotDepth = 1
        config.atrPeriod = 2
        config.minTrendLegATR = 0
        config.breakBufferATR = 0
        config.retestToleranceATR = 0.10
        config.maxFailedBreakATR = 3.0
        config.maxRetestBars = 8
        config.maxConfirmationBars = 8
        config.stopBufferATR = 0
        config.riskReward = 2
        config.maxTradeBars = 10
        config.maxResults = 12
        return config
    }

    private func bullishMTR(retestLow: Double, retestClose: Double) -> [Candle] {
        [
            candle(106, 108, 105, 107),
            candle(107, 109, 106, 108),
            candle(108, 110, 107.5, 109),       // first lower-high anchor
            candle(108, 108.5, 102, 103),
            candle(103, 104, 100, 101),         // first low
            candle(101, 106, 101, 105),
            candle(105, 108, 104, 106),         // second lower high
            candle(105, 105.5, 99, 100),
            candle(100, 101, 98, 99),           // old trend extreme
            candle(100, 108, 99, 107),          // close-confirmed channel break
            candle(107, 107.5, 101, 102),
            candle(102, 103, retestLow, retestClose), // second test
            candle(retestClose, 105, 100, 104),
            candle(104, 110, 103, 109.5),        // neckline confirmation
            candle(109.5, 111, 108, 110),
        ]
    }

    private func mirror(_ candles: [Candle]) -> [Candle] {
        candles.map { source in
            candle(
                200 - source.open,
                200 - source.low,
                200 - source.high,
                200 - source.close
            )
        }
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

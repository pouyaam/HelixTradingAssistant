import XCTest
@testable import HelixTradingApp

final class MicroMapSetupTests: XCTestCase {
    func testLongSetupTriggersOnCloseAndHitsTwoRTarget() {
        var candles = warmup()
        candles += bullishSpikeAndChannel()
        candles.append(candle(106.1, 108.4, 105.8, 107.4))

        let result = lastTriggeredResult(candles)

        guard let result, let attempt = result.attempts.first,
              let entry = attempt.entry,
              let stopLoss = attempt.stopLoss,
              let takeProfit = attempt.takeProfit else {
            return XCTFail("Expected a complete first attempt")
        }
        XCTAssertEqual(result.direction, .long)
        XCTAssertEqual(result.stage, .succeeded)
        XCTAssertEqual(attempt.status, .succeeded)
        XCTAssertEqual(entry, 106.1, accuracy: 0.0001)
        XCTAssertEqual(stopLoss, 105.0, accuracy: 0.0001)
        XCTAssertEqual(takeProfit, 108.3, accuracy: 0.0001)
    }

    func testWickBeyondChannelDoesNotTriggerEntry() {
        var candles = warmup()
        candles += bullishSpikeAndChannel(includeTrigger: false)
        candles.append(candle(105.3, 106.2, 105.1, 105.6))

        let results = MicroMapSetup.compute(candles, configuration: testConfiguration())

        XCTAssertFalse(results.flatMap(\.attempts).contains { $0.triggerIndex != nil })
    }

    func testStopRequiresCloseBeyondLevel() {
        var candles = warmup()
        candles += bullishSpikeAndChannel()
        candles.append(candle(106.0, 106.5, 104.7, 105.4))

        let result = lastTriggeredResult(candles)

        XCTAssertEqual(result?.stage, .active)
        XCTAssertEqual(result?.attempts.first?.status, .active)
        XCTAssertNil(result?.attempts.first?.stopIndex)
    }

    func testThreeStoppedAttemptsInvalidateSetup() {
        var candles = warmup()
        candles += bullishSpikeAndChannel()
        candles += [
            candle(105.8, 106.0, 104.7, 104.9), // stop attempt 1
            candle(104.9, 105.2, 104.7, 105.0), // wait candle
            candle(105.0, 105.4, 104.6, 105.3), // entry attempt 2
            candle(105.2, 105.3, 104.3, 104.5), // stop attempt 2
            candle(104.5, 104.8, 104.3, 104.6), // wait candle
            candle(104.6, 105.0, 104.4, 104.9), // entry attempt 3
            candle(104.8, 104.9, 104.0, 104.2), // stop attempt 3
        ]

        let result = lastTriggeredResult(candles)

        XCTAssertEqual(result?.stage, .invalidated)
        XCTAssertEqual(result?.endReason, .threeStops)
        XCTAssertEqual(result?.attempts.count, 3)
        XCTAssertTrue(result?.attempts.allSatisfy { $0.status == .stopped } == true)
    }

    func testStopWinsAmbiguousTargetCandle() {
        var candles = warmup()
        candles += bullishSpikeAndChannel()
        candles.append(candle(106.0, 108.5, 104.8, 104.9))

        let result = lastTriggeredResult(candles)

        XCTAssertEqual(result?.attempts.first?.status, .stopped)
        XCTAssertNotEqual(result?.stage, .succeeded)
    }

    func testWeakSpikeIsRejected() {
        var candles = warmup()
        candles += [
            candle(100.0, 100.4, 99.9, 100.2),
            candle(100.2, 100.5, 100.1, 100.3),
            candle(100.3, 100.4, 100.0, 100.1),
            candle(100.1, 100.3, 100.0, 100.2),
        ]

        XCTAssertTrue(MicroMapSetup.compute(candles, configuration: testConfiguration()).isEmpty)
    }

    func testReentryExpiresWithoutThirdStopInvalidation() {
        var config = testConfiguration()
        config.maxReentryBars = 3
        var candles = warmup()
        candles += bullishSpikeAndChannel()
        candles += [
            candle(105.8, 106.0, 104.7, 104.9),
            candle(104.9, 105.2, 104.7, 105.0),
            candle(105.0, 105.1, 104.6, 104.8),
            candle(104.8, 105.0, 104.5, 104.7),
            candle(104.7, 104.9, 104.4, 104.6),
        ]

        let result = MicroMapSetup.compute(candles, configuration: config)
            .last { $0.hasTriggeredEntry }

        XCTAssertEqual(result?.stage, .expired)
        XCTAssertEqual(result?.endReason, .reentryExpired)
        XCTAssertNotEqual(result?.endReason, .threeStops)
    }

    func testInsufficientDataReturnsNoSetup() {
        let candles = [candle(100, 101, 99, 100.5)]
        XCTAssertTrue(MicroMapSetup.compute(candles).isEmpty)
    }

    func testDeepPullbackRejectsSetupBeforeEntry() {
        var candles = warmup()
        candles += [
            candle(100.0, 102.1, 99.9, 102.0),
            candle(102.0, 104.1, 101.9, 104.0),
            candle(104.0, 106.1, 103.9, 106.0),
            candle(105.9, 106.0, 103.0, 103.4),
            candle(103.4, 104.0, 102.0, 102.4),
        ]
        XCTAssertTrue(MicroMapSetup.compute(candles, configuration: testConfiguration()).isEmpty)
    }

    func testMirroredShortSetupIsDetected() {
        var candles = warmup()
        candles += [
            candle(100.0, 100.1, 97.9, 98.0),
            candle(98.0, 98.1, 95.9, 96.0),
            candle(96.0, 96.1, 93.9, 94.0),
            candle(94.1, 94.8, 94.0, 94.6),
            candle(94.5, 95.0, 94.3, 94.8),
            candle(94.8, 94.9, 93.7, 93.9),
        ]

        let result = lastTriggeredResult(candles)

        XCTAssertEqual(result?.direction, .short)
        XCTAssertEqual(result?.attempts.first?.status, .active)
    }

    func testSP2LConfluenceFindsPressureGapAndKeyLevelBreak() {
        var candles = warmup()
        candles += bullishSpikeAndChannel()

        let result = lastTriggeredResult(candles)

        XCTAssertNotNil(result?.confluence.pressureGap)
        XCTAssertEqual(result?.confluence.brokeKeyLevel, true)
        XCTAssertGreaterThanOrEqual(result?.confluence.score ?? 0, 4)
        XCTAssertNotEqual(result?.confluence.quality, .standard)
    }

    func testRequiredPressureGapRejectsOtherwiseValidSetup() {
        var candles = warmup()
        candles += bullishSpikeWithoutPressureGapAndChannel()
        var config = testConfiguration()
        config.requirePressureGap = true

        let results = MicroMapSetup.compute(candles, configuration: config)

        XCTAssertTrue(results.isEmpty)
    }

    func testMinimumConfluenceScoreFiltersWeakContext() {
        var candles = warmup()
        candles += bullishSpikeWithoutPressureGapAndChannel()
        var config = testConfiguration()
        config.minConfluenceScore = 3

        let results = MicroMapSetup.compute(candles, configuration: config)

        XCTAssertTrue(results.isEmpty)
    }

    private func lastTriggeredResult(_ candles: [Candle]) -> MicroMapSetup.Result? {
        MicroMapSetup.compute(candles, configuration: testConfiguration())
            .last { $0.hasTriggeredEntry }
    }

    private func testConfiguration() -> MicroMapSetup.Configuration {
        var config = MicroMapSetup.Configuration()
        config.atrPeriod = 5
        config.minSpikeBars = 3
        config.maxSpikeBars = 3
        config.minSpikeATR = 1.5
        config.structureToleranceATR = 0.25
        return config
    }

    private func warmup() -> [Candle] {
        (0..<8).map { index in
            let offset = Double(index % 2) * 0.05
            return candle(100 + offset, 100.25, 99.75, 100.05 - offset)
        }
    }

    private func bullishSpikeAndChannel(includeTrigger: Bool = true) -> [Candle] {
        var values = [
            candle(100.0, 102.1, 99.9, 102.0),
            candle(102.0, 104.1, 101.9, 104.0),
            candle(104.0, 106.1, 103.9, 106.0),
            candle(105.9, 106.0, 105.3, 105.5),
            candle(105.5, 105.7, 105.0, 105.3),
        ]
        if includeTrigger {
            values.append(candle(105.3, 106.2, 105.2, 106.1))
        }
        return values
    }

    private func bullishSpikeWithoutPressureGapAndChannel() -> [Candle] {
        [
            candle(100.0, 102.1, 99.9, 102.0),
            candle(102.0, 104.1, 100.1, 104.0),
            candle(104.0, 106.1, 102.0, 106.0),
            candle(105.9, 106.0, 105.3, 105.5),
            candle(105.5, 105.7, 105.0, 105.3),
            candle(105.3, 106.2, 105.2, 106.1),
        ]
    }

    private func candle(_ open: Double, _ high: Double, _ low: Double, _ close: Double) -> Candle {
        let date = Date(timeIntervalSince1970: TimeInterval(nextTimestamp))
        nextTimestamp += 60
        return Candle(id: date, open: open, high: high, low: low, close: close)
    }

    private var nextTimestamp = 1_700_000_000

    override func setUp() {
        super.setUp()
        nextTimestamp = 1_700_000_000
    }
}

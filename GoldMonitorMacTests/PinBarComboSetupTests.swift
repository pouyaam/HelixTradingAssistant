import XCTest
@testable import HelixTradingApp

final class PinBarComboSetupTests: XCTestCase {
    func testBullishBTBRetestRequiresPinBarAndHitsTarget() {
        var candles = balance()
        candles += [
            candle(100.0, 101.3, 99.95, 101.2),
            candle(100.75, 100.90, 100.10, 100.65),
            candle(100.65, 101.90, 100.55, 101.80),
        ]
        var config = testConfiguration()
        config.enableSP2L = false

        let result = PinBarComboSetup.compute(
            candles,
            sp2lResults: [],
            configuration: config
        ).last

        XCTAssertEqual(result?.kind, .btb)
        XCTAssertEqual(result?.direction, .long)
        XCTAssertEqual(result?.confirmationIndex, 6)
        XCTAssertEqual(result?.entry ?? 0, 100.65, accuracy: 0.0001)
        XCTAssertEqual(result?.stopLoss ?? 0, 100.10, accuracy: 0.0001)
        XCTAssertEqual(result?.takeProfit ?? 0, 101.75, accuracy: 0.0001)
        XCTAssertEqual(result?.status, .hitTP)
    }

    func testTouchWithoutPinBarDoesNotConfirmBTB() {
        var candles = balance()
        candles += [
            candle(100.0, 101.3, 99.95, 101.2),
            candle(100.75, 100.90, 100.10, 100.25),
            candle(100.25, 101.20, 100.20, 101.0),
        ]
        var config = testConfiguration()
        config.enableSP2L = false

        let results = PinBarComboSetup.compute(
            candles,
            sp2lResults: [],
            configuration: config
        )

        XCTAssertTrue(results.isEmpty)
    }

    func testBearishPinBarIsMirrored() {
        let pin = candle(100.20, 100.80, 99.95, 100.05)
        let valid = PinBarComboSetup.isPinBar(
            pin,
            direction: .short,
            level: 100.50,
            atr: 1,
            configuration: testConfiguration()
        )
        XCTAssertTrue(valid)
    }

    func testWideBodyCandleIsNotPinBar() {
        let candle = candle(100.10, 101.0, 99.90, 100.85)
        XCTAssertFalse(PinBarComboSetup.isPinBar(
            candle,
            direction: .long,
            level: 100.0,
            atr: 1,
            configuration: testConfiguration()
        ))
    }

    func testSP2LPathWaitsForPinBarConfirmation() {
        let candles = [
            candle(99.9, 100.2, 99.7, 100.0),
            candle(100.0, 101.2, 99.9, 101.0),
            candle(101.0, 102.2, 100.8, 102.0),
            candle(100.85, 101.0, 100.1, 100.82),
            candle(100.82, 102.5, 100.7, 102.4),
        ]
        let base = SP2LSetup.Result(
            spikeStartIndex: 1,
            spikeEndIndex: 2,
            breakoutIndex: 1,
            followThroughIndex: 2,
            spikeHigh: 102.2,
            spikeLow: 99.9,
            brokenLevel: 100.2,
            levelStartIndex: 0,
            gapStartIndex: 0,
            gapEndIndex: 2,
            gapLow: 100.2,
            gapHigh: 100.8,
            direction: .long,
            stage: .limitPending,
            entry: 100.8,
            stopLoss: 99.9,
            takeProfit: 101.7,
            emaValue: nil
        )
        var config = testConfiguration()
        config.enableBTB = false
        config.atrPeriod = 2

        let result = PinBarComboSetup.compute(
            candles,
            sp2lResults: [base],
            configuration: config
        ).last

        XCTAssertEqual(result?.kind, .sp2l)
        XCTAssertEqual(result?.confirmationIndex, 3)
        XCTAssertEqual(result?.status, .hitTP)
    }

    private func testConfiguration() -> PinBarComboSetup.Configuration {
        var config = PinBarComboSetup.Configuration()
        config.atrPeriod = 3
        config.btbLookbackBars = 5
        config.minBreakoutBodyATR = 0.2
        config.maxConfirmationBars = 3
        config.stopBufferATR = 0
        config.riskReward = 2
        config.maxContinuationBars = 5
        return config
    }

    private func balance() -> [Candle] {
        [
            candle(100.0, 100.20, 99.80, 100.05),
            candle(100.05, 100.18, 99.82, 99.98),
            candle(99.98, 100.15, 99.80, 100.02),
            candle(100.02, 100.19, 99.85, 100.00),
            candle(100.00, 100.20, 99.84, 100.04),
        ]
    }

    private func candle(_ open: Double, _ high: Double, _ low: Double, _ close: Double) -> Candle {
        defer { timestamp += 60 }
        return Candle(
            id: Date(timeIntervalSince1970: TimeInterval(timestamp)),
            open: open,
            high: high,
            low: low,
            close: close
        )
    }

    private var timestamp = 1_700_000_000

    override func setUp() {
        super.setUp()
        timestamp = 1_700_000_000
    }
}

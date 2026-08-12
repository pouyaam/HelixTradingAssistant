import Foundation
import XCTest
@testable import HelixTradingApp

/// Pattern + trade-model tests for the EBP (Engulfing Bar Play) engine.
///
/// Every series is hand-built so the pattern sits at a known index: 20
/// flat bars establish the ATR, bar 20 is the candle that gets swept,
/// and bar 21 is the EBP itself. The plan levels are pure fractions of
/// the EBP candle's own range, so unlike the ATR-derived engines they
/// can be asserted as exact numbers.
///
/// The reference EBP (bar 21 of `strongLongSeries`) is:
///
///     high 100.7, low 99.4  → range 1.30, close 100.6 → 7.7% retrace
///     strong close → entry 100.375 (25%), stop 99.725 (75%)
///     risk 0.65 → target 101.675 at 2R
final class EngulfingBarPlayTests: XCTestCase {

    // MARK: - Detection

    func testBullishEBPIsDetectedOnTheSweepAndReclaim() throws {
        let setups = EngulfingBarPlay.compute(strongLongSeries(), configuration: config()).setups
        let setup = try XCTUnwrap(setups.first)

        XCTAssertEqual(setup.direction, .long)
        XCTAssertEqual(setup.index, 21)
        XCTAssertEqual(setup.closeQuality, .strong)
        XCTAssertEqual(setup.entryKind, .limit)
        XCTAssertEqual(setup.status, .pending)
        XCTAssertNil(setup.triggerIndex)
    }

    /// The body may not trade beyond the level the wick took out.
    func testBodySweepIsRejectedUnlessWickOnlyIsOff() throws {
        var permissive = config()
        permissive.wickOnlySweep = false

        let strict = EngulfingBarPlay.compute(bodySweepSeries(), configuration: config()).setups
        let loose = EngulfingBarPlay.compute(bodySweepSeries(), configuration: permissive).setups

        XCTAssertTrue(strict.isEmpty)
        XCTAssertEqual(loose.count, 1)
        XCTAssertEqual(loose.first?.index, 21)
    }

    /// The original model allows same-colour candles; the default here
    /// does not.
    func testPreviousCandleMustBeTheOppositeColourUnlessTurnedOff() throws {
        var permissive = config()
        permissive.requireOppositeColour = false

        let strict = EngulfingBarPlay.compute(sameColourSeries(), configuration: config()).setups
        let loose = EngulfingBarPlay.compute(sameColourSeries(), configuration: permissive).setups

        XCTAssertTrue(strict.isEmpty)
        XCTAssertEqual(loose.first?.direction, .long)
    }

    /// Bar 21 closes above bar 20's body but below its high, so the
    /// full-engulf setting is the difference between a signal and none.
    func testFullEngulfRequirementRejectsABodyOnlyReclaim() throws {
        var full = config()
        full.requireFullEngulf = true

        let bodyOnly = EngulfingBarPlay.compute(tallPreviousSeries(), configuration: config()).setups
        let strict = EngulfingBarPlay.compute(tallPreviousSeries(), configuration: full).setups

        XCTAssertEqual(bodyOnly.count, 1)
        XCTAssertTrue(strict.isEmpty)
    }

    /// The EBP candle spans ~2.7 ATR, so it clears a 2× filter and fails
    /// a 5× one.
    func testMinimumRangeFilterGatesSmallPatterns() {
        var passes = config()
        passes.minRangeATR = 2.0
        var blocks = config()
        blocks.minRangeATR = 5.0

        XCTAssertEqual(EngulfingBarPlay.compute(strongLongSeries(), configuration: passes).setups.count, 1)
        XCTAssertTrue(EngulfingBarPlay.compute(strongLongSeries(), configuration: blocks).setups.isEmpty)
    }

    func testDirectionModeFiltersOutTheUnwantedSide() {
        var shortOnly = config()
        shortOnly.directionMode = .short

        XCTAssertTrue(EngulfingBarPlay.compute(strongLongSeries(), configuration: shortOnly).setups.isEmpty)
    }

    /// The series is built from 1-minute bars, so a 1H floor silences it.
    func testTimeframeFloorSilencesTooSmallABar() {
        var hourly = config()
        hourly.minTimeframeMinutes = 60
        var oneMinute = config()
        oneMinute.minTimeframeMinutes = 1

        XCTAssertTrue(EngulfingBarPlay.compute(strongLongSeries(), configuration: hourly).setups.isEmpty)
        XCTAssertEqual(EngulfingBarPlay.compute(strongLongSeries(), configuration: oneMinute).setups.count, 1)
    }

    /// A mirrored series must produce the mirrored setup — the two
    /// directions are meant to be the same code path reflected.
    func testShortSideMirrorsTheLongSide() throws {
        let long = try XCTUnwrap(
            EngulfingBarPlay.compute(strongLongSeries(), configuration: config()).setups.first
        )
        let short = try XCTUnwrap(
            EngulfingBarPlay.compute(mirrored(strongLongSeries()), configuration: config()).setups.first
        )

        XCTAssertEqual(short.direction, .short)
        XCTAssertEqual(short.index, long.index)
        XCTAssertEqual(short.closeQuality, .strong)
        XCTAssertEqual(short.entryLevel, 200 - long.entryLevel, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(short.stopLoss), 200 - (try XCTUnwrap(long.stopLoss)), accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(short.takeProfit), 200 - (try XCTUnwrap(long.takeProfit)), accuracy: 0.0001)
    }

    // MARK: - Trade model

    func testStrongCloseRestsAShallowLimitWithTheStopInsideTheCandle() throws {
        let setup = try XCTUnwrap(
            EngulfingBarPlay.compute(strongLongSeries(), configuration: config()).setups.first
        )

        XCTAssertEqual(setup.entryLevel, 100.375, accuracy: 0.0001)   // 25% retrace
        XCTAssertEqual(try XCTUnwrap(setup.stopLoss), 99.725, accuracy: 0.0001)  // 75% retrace
        XCTAssertEqual(try XCTUnwrap(setup.takeProfit), 101.675, accuracy: 0.0001)
        // The stop sits inside the candle, not behind it.
        XCTAssertGreaterThan(try XCTUnwrap(setup.stopLoss), setup.barLow)
    }

    /// An indecisive close that has *not* passed the midpoint still
    /// rests a limit — at 50%, with the stop behind the whole candle.
    func testIndecisiveCloseRetracesToTheMidpointWithTheStopBehindTheCandle() throws {
        let setup = try XCTUnwrap(
            EngulfingBarPlay.compute(indecisiveLimitSeries(), configuration: config()).setups.first
        )

        XCTAssertEqual(setup.closeQuality, .indecisive)
        XCTAssertEqual(setup.entryKind, .limit)
        XCTAssertEqual(setup.entryLevel, 100.15, accuracy: 0.0001)     // 50% of 1.5
        XCTAssertEqual(try XCTUnwrap(setup.stopLoss), setup.barLow, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(setup.takeProfit), 101.65, accuracy: 0.0001)
    }

    /// A close already beyond the 50% level would leave the limit on the
    /// wrong side of price, so the trade is taken at that close.
    func testCloseBeyondTheMidpointIsTakenAtMarket() throws {
        let setup = try XCTUnwrap(
            EngulfingBarPlay.compute(marketEntrySeries(), configuration: config()).setups.first
        )

        XCTAssertEqual(setup.closeQuality, .indecisive)
        XCTAssertEqual(setup.entryKind, .market)
        XCTAssertEqual(setup.entryLevel, 100.05, accuracy: 0.0001)     // the close itself
        XCTAssertEqual(setup.triggerIndex, 21)                          // live immediately
        XCTAssertEqual(setup.status, .triggered)
        XCTAssertEqual(try XCTUnwrap(setup.takeProfit), 101.35, accuracy: 0.0001)
    }

    func testMarketEntryFallsBackToALimitWhenTheSettingIsOff() throws {
        var limitOnly = config()
        limitOnly.marketEntryBeyondHalf = false

        let setup = try XCTUnwrap(
            EngulfingBarPlay.compute(marketEntrySeries(), configuration: limitOnly).setups.first
        )

        XCTAssertEqual(setup.entryKind, .limit)
        XCTAssertEqual(setup.entryLevel, 100.15, accuracy: 0.0001)     // 50% of 1.5
        XCTAssertNil(setup.triggerIndex)
    }

    func testTargetTracksTheRiskRewardSetting() throws {
        var threeR = config()
        threeR.riskReward = 3.0

        let setup = try XCTUnwrap(
            EngulfingBarPlay.compute(strongLongSeries(), configuration: threeR).setups.first
        )
        let entry = setup.entryLevel
        let stop = try XCTUnwrap(setup.stopLoss)

        XCTAssertEqual(try XCTUnwrap(setup.takeProfit), entry + (entry - stop) * 3, accuracy: 0.0001)
    }

    // MARK: - State machine

    func testLimitFillsOnTheRetraceAndRunsToTarget() throws {
        let output = EngulfingBarPlay.compute(strongLongSeries(outcome: .runsToTarget), configuration: config())
        let setup = try XCTUnwrap(output.setups.first { $0.index == 21 })

        XCTAssertEqual(setup.triggerIndex, 22)
        XCTAssertEqual(setup.status, .hitTP)
        XCTAssertEqual(setup.resolveIndex, 24)
        XCTAssertEqual(setup.rMultiple, 2.0)
        XCTAssertEqual(output.stats.wins, 1)
        XCTAssertEqual(output.stats.totalR, 2.0, accuracy: 0.0001)
        XCTAssertEqual(output.stats.winRate, 100)
    }

    func testStoppedOutTradeIsRecordedAsMinusOneR() throws {
        let output = EngulfingBarPlay.compute(strongLongSeries(outcome: .stopsOut), configuration: config())
        let setup = try XCTUnwrap(output.setups.first { $0.index == 21 })

        XCTAssertEqual(setup.status, .hitSL)
        XCTAssertEqual(setup.resolveIndex, 23)
        XCTAssertEqual(setup.rMultiple, -1)
        XCTAssertEqual(output.stats.losses, 1)
        XCTAssertEqual(output.stats.totalR, -1.0, accuracy: 0.0001)
    }

    /// A bar can fill the limit and reach a level on the way — the
    /// original checks both on the same bar, and so does this.
    func testAFillBarThatAlsoReachesTheStopResolvesImmediately() throws {
        let output = EngulfingBarPlay.compute(strongLongSeries(outcome: .fillAndStopSameBar), configuration: config())
        let setup = try XCTUnwrap(output.setups.first { $0.index == 21 })

        XCTAssertEqual(setup.triggerIndex, 22)
        XCTAssertEqual(setup.resolveIndex, 22)
        XCTAssertEqual(setup.status, .hitSL)
    }

    func testUnfilledLimitIsCancelledAfterTheExpiryWindow() throws {
        var cfg = config()
        cfg.expiryBars = 3
        let output = EngulfingBarPlay.compute(strongLongSeries(outcome: .driftAway), configuration: cfg)
        let setup = try XCTUnwrap(output.setups.first { $0.index == 21 })

        XCTAssertEqual(setup.status, .cancelled)
        XCTAssertNil(setup.triggerIndex)
        XCTAssertEqual(setup.resolveIndex, 24)   // armed at 21
        XCTAssertEqual(output.stats.cancelled, 1)
    }

    func testExpiryOfZeroLeavesTheLimitResting() throws {
        var cfg = config()
        cfg.expiryBars = 0
        let setup = try XCTUnwrap(
            EngulfingBarPlay.compute(strongLongSeries(outcome: .driftAway), configuration: cfg)
                .setups.first { $0.index == 21 }
        )

        XCTAssertEqual(setup.status, .pending)
    }

    /// With the rule on, a new high beyond the EBP candle moves the stop
    /// to entry, so the pullback that follows ends the trade flat rather
    /// than at −1R.
    func testBreakevenRuleTurnsALossIntoAFlatTrade() throws {
        var withRule = config()
        withRule.breakevenOnNewExtreme = true

        let plain = EngulfingBarPlay.compute(strongLongSeries(outcome: .breakevenPullback), configuration: config())
        let managed = EngulfingBarPlay.compute(strongLongSeries(outcome: .breakevenPullback), configuration: withRule)

        let untouched = try XCTUnwrap(plain.setups.first { $0.index == 21 })
        let moved = try XCTUnwrap(managed.setups.first { $0.index == 21 })

        // Without the rule the stop never moves, so the pullback is just
        // noise and the trade is still open at the right edge.
        XCTAssertEqual(untouched.status, .triggered)
        XCTAssertFalse(untouched.movedToBreakeven)

        XCTAssertTrue(moved.movedToBreakeven)
        XCTAssertEqual(moved.status, .breakeven)
        XCTAssertEqual(moved.resolveIndex, 24)
        XCTAssertEqual(moved.rMultiple, 0)
        XCTAssertEqual(managed.stats.breakevens, 1)
        XCTAssertEqual(managed.stats.losses, 0)
        XCTAssertEqual(managed.stats.totalR, 0, accuracy: 0.0001)
    }

    /// The fill bar runs the management block too, so a bar that fills
    /// the limit, prints a new extreme *and* comes back through the
    /// raised stop resolves the trade at breakeven where it started —
    /// the same sequence the original's state machine produces.
    func testBreakevenCanArmOnTheFillBarItself() throws {
        var withRule = config()
        withRule.breakevenOnNewExtreme = true

        let output = EngulfingBarPlay.compute(
            strongLongSeries(outcome: .newHighOnTheFillBar), configuration: withRule
        )
        let setup = try XCTUnwrap(output.setups.first { $0.index == 21 })

        XCTAssertEqual(setup.triggerIndex, 22)
        XCTAssertEqual(setup.resolveIndex, 22)
        XCTAssertEqual(setup.status, .breakeven)
        XCTAssertTrue(setup.movedToBreakeven)
    }

    /// One trade at a time, as in the original: a pattern that prints
    /// while an order is working is drawn but never planned.
    func testPatternPrintingWhileASetupIsWorkingIsMarkedSkipped() throws {
        let output = EngulfingBarPlay.compute(secondPatternSeries(), configuration: config())

        XCTAssertEqual(output.setups.count, 2)
        // Newest first.
        XCTAssertEqual(output.setups.map(\.index), [24, 21])

        let skipped = try XCTUnwrap(output.setups.first { $0.index == 24 })
        XCTAssertEqual(skipped.status, .skipped)
        XCTAssertNil(skipped.stopLoss)
        XCTAssertNil(skipped.takeProfit)
        XCTAssertNil(skipped.triggerIndex)

        XCTAssertEqual(output.setups.first { $0.index == 21 }?.status, .pending)
        // A pattern that was never traded is not a setup for the tally.
        XCTAssertEqual(output.stats.setups, 1)
    }

    func testMaxSetupsCapsTheNewestSetupsOnly() {
        var cfg = config()
        cfg.maxSetups = 1

        let output = EngulfingBarPlay.compute(secondPatternSeries(), configuration: cfg)

        XCTAssertEqual(output.setups.map(\.index), [24])
        // The cap is a display limit — the tally still counts everything.
        XCTAssertEqual(output.stats.setups, 1)
    }

    func testWinRateIsNilBeforeAnythingResolves() {
        let output = EngulfingBarPlay.compute(strongLongSeries(), configuration: config())

        XCTAssertNil(output.stats.winRate)
        XCTAssertEqual(output.stats.setups, 1)
    }

    // MARK: - Wall-clock anchors

    /// The chart re-projects setups from another timeframe through these,
    /// so every index the engine reports has to carry its date.
    func testSetupsCarryTheDatesOfTheirBars() throws {
        let series = strongLongSeries(outcome: .runsToTarget)
        let setup = try XCTUnwrap(
            EngulfingBarPlay.compute(series, configuration: config()).setups.first { $0.index == 21 }
        )

        XCTAssertEqual(setup.barDate, series[21].bucketStart)
        XCTAssertEqual(setup.triggerDate, series[try XCTUnwrap(setup.triggerIndex)].bucketStart)
        XCTAssertEqual(setup.resolveDate, series[try XCTUnwrap(setup.resolveIndex)].bucketStart)
    }

    func testAnUnresolvedSetupHasNoTriggerOrResolveDate() throws {
        let setup = try XCTUnwrap(
            EngulfingBarPlay.compute(strongLongSeries(), configuration: config()).setups.first
        )

        XCTAssertNotNil(setup.barDate)
        XCTAssertNil(setup.triggerDate)
        XCTAssertNil(setup.resolveDate)
    }

    // MARK: - Series construction

    private enum Outcome {
        case none
        case runsToTarget
        case stopsOut
        case fillAndStopSameBar
        case driftAway
        case breakevenPullback
        case newHighOnTheFillBar
    }

    /// Bars 0–19: flat 99.8–100.2, putting the ATR at ~0.4.
    /// Bar 20: a bearish candle — open 100.0, close 99.75, low 99.7.
    /// Bar 21: the EBP — wick to 99.4 (below 99.7), body from 99.8,
    ///         close 100.6 (above bar 20's body top of 100.0), high 100.7.
    private func strongLongSeries(outcome: Outcome = .none) -> [Candle] {
        var out = flatBase()
        out.append(candle(100.0, 100.3, 99.7, 99.75))       // 20 — bearish
        out.append(candle(99.8, 100.7, 99.4, 100.6))        // 21 — the EBP

        switch outcome {
        case .runsToTarget:
            out.append(candle(100.6, 100.8, 100.3, 100.5))  // 22 — fills at 100.375
            out.append(candle(100.5, 101.0, 100.4, 100.9))  // 23
            out.append(candle(100.9, 101.8, 100.8, 101.7))  // 24 — through 101.675
        case .stopsOut:
            out.append(candle(100.6, 100.8, 100.3, 100.5))  // 22 — fills
            out.append(candle(100.5, 100.6, 99.5, 99.6))    // 23 — through 99.725
        case .fillAndStopSameBar:
            out.append(candle(100.6, 100.8, 99.5, 99.6))    // 22 — fills and stops
        case .driftAway:
            // Never trades back down to the 100.375 limit.
            out += (0..<6).map { _ in candle(100.6, 100.9, 100.5, 100.8) }
        case .breakevenPullback:
            // Bar 22 must stay *under* the EBP high, or it would arm the
            // breakeven on the very bar it fills on — see
            // `testBreakevenCanArmOnTheFillBarItself`.
            out.append(candle(100.5, 100.65, 100.3, 100.5)) // 22 — fills
            out.append(candle(100.5, 100.9, 100.45, 100.8)) // 23 — new high past 100.7
            out.append(candle(100.8, 100.9, 100.2, 100.3))  // 24 — back to entry
            out += (0..<3).map { _ in candle(100.3, 100.4, 100.2, 100.35) }
        case .newHighOnTheFillBar:
            // Fills at 100.375, prints a new high past 100.7, and dips
            // back under the raised stop — all on bar 22.
            out.append(candle(100.6, 100.8, 100.3, 100.5))  // 22
        case .none:
            break
        }
        return out
    }

    /// Bar 21's *body* trades below the swept low, so only the permissive
    /// setting accepts it.
    private func bodySweepSeries() -> [Candle] {
        var out = flatBase()
        out.append(candle(100.0, 100.3, 99.7, 99.75))       // 20 — bearish
        out.append(candle(99.5, 100.7, 99.4, 100.6))        // 21 — opens under 99.7
        return out
    }

    /// Bar 20 closes *up*, so the pattern is same-colour.
    private func sameColourSeries() -> [Candle] {
        var out = flatBase()
        out.append(candle(99.7, 100.3, 99.65, 100.2))       // 20 — bullish
        out.append(candle(99.8, 100.7, 99.4, 100.6))        // 21
        return out
    }

    /// Bar 20 has a long upper wick to 100.9; bar 21 clears its body but
    /// not its high.
    private func tallPreviousSeries() -> [Candle] {
        var out = flatBase()
        out.append(candle(100.0, 100.9, 99.7, 99.75))       // 20
        out.append(candle(99.8, 100.7, 99.4, 100.6))        // 21 — close 100.6 < 100.9
        return out
    }

    /// Bar 21 closes at 100.45 — a 30% retrace, past the strong-close
    /// threshold but short of the midpoint.
    private func indecisiveLimitSeries() -> [Candle] {
        var out = flatBase()
        out.append(candle(100.0, 100.3, 99.7, 99.75))       // 20
        out.append(candle(99.8, 100.9, 99.4, 100.45))       // 21 — range 1.5
        return out
    }

    /// Bar 21 closes at 100.05 — a 57% retrace, past the midpoint.
    private func marketEntrySeries() -> [Candle] {
        var out = flatBase()
        out.append(candle(100.0, 100.3, 99.7, 99.75))       // 20
        out.append(candle(99.8, 100.9, 99.4, 100.05))       // 21 — range 1.5
        return out
    }

    /// A second EBP at bar 24 while bar 21's limit is still resting. Every
    /// bar stays above 100.375 so the first order never fills.
    private func secondPatternSeries() -> [Candle] {
        var out = flatBase()
        out.append(candle(100.0, 100.3, 99.7, 99.75))       // 20
        out.append(candle(99.8, 100.7, 99.4, 100.6))        // 21 — the EBP
        out.append(candle(100.6, 100.9, 100.5, 100.8))      // 22
        out.append(candle(100.8, 100.9, 100.5, 100.55))     // 23 — bearish
        out.append(candle(100.6, 101.0, 100.42, 100.95))    // 24 — a second EBP
        return out
    }

    private func flatBase() -> [Candle] {
        (0..<20).map { i in
            candle(100.0, 100.2, 99.8, i.isMultiple(of: 2) ? 100.05 : 99.95)
        }
    }

    /// Flip a series through the horizontal so a bullish setup becomes
    /// the identical bearish one.
    private func mirrored(_ candles: [Candle]) -> [Candle] {
        candles.map {
            Candle(
                id: $0.id,
                open: 200 - $0.open,
                high: 200 - $0.low,
                low: 200 - $0.high,
                close: 200 - $0.close,
                volume: $0.volume
            )
        }
    }

    /// Short ATR window — the series is only ~26 bars.
    private func config() -> EngulfingBarPlay.Configuration {
        var cfg = EngulfingBarPlay.Configuration()
        cfg.atrLength = 14
        cfg.expiryBars = 0          // off unless a test asks for it
        return cfg
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
}

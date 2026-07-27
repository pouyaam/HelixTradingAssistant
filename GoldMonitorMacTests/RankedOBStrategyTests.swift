import Foundation
import XCTest
@testable import HelixTradingApp

/// Locks in the Ranked-OB strategy layer: plan geometry, the
/// waiting → armed → triggered → entered → resolved walk, and the
/// conventions that keep the replay honest (no same-bar fills off the
/// confirmation bar, same-bar TP+SL counted as the stop).
final class RankedOBStrategyTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func c(_ i: Int, _ o: Double, _ h: Double, _ l: Double, _ close: Double) -> Candle {
        Candle(id: start.addingTimeInterval(TimeInterval(i * 60)), open: o, high: h, low: l, close: close, volume: 100)
    }

    /// A bullish zone at 98–100 created at bar 5, born into 1.0 of ATR.
    private func bullZone(
        grade: RankedOrderBlocks.Grade = .a,
        isBreaker: Bool = false,
        endIndex: Int = 19,
        top: Double = 100,
        bottom: Double = 98
    ) -> RankedOrderBlocks.Zone {
        RankedOrderBlocks.Zone(
            startIndex: 3, endIndex: endIndex, confirmIndex: 5,
            top: top, bottom: bottom, isBullish: true,
            isBreaker: isBreaker, isCombined: false,
            grade: grade, score: 4, maxScore: 5, atr: 1.0
        )
    }

    /// Defaults chosen so the arithmetic is checkable by hand:
    /// entry 99 (mid), SL 97.5 (0.5 ATR under 98), risk 1.5,
    /// TP1 100.5 (1R), TP2 102 (2R).
    private func config(
        confirmation: RankedOBStrategy.Confirmation = .touch,
        entryModel: RankedOBStrategy.EntryModel = .mid,
        minGrade: RankedOBStrategy.MinGrade = .any,
        targetMode: RankedOBStrategy.TargetMode = .fixedR,
        tradeBreakers: Bool = false,
        confirmWindow: Int = 5,
        minRR: Double = 0
    ) -> RankedOBStrategy.Config {
        var cfg = RankedOBStrategy.Config()
        cfg.enabled = true
        cfg.minGrade = minGrade
        cfg.confirmation = confirmation
        cfg.entryModel = entryModel
        cfg.confirmWindow = confirmWindow
        cfg.slATRBuffer = 0.5
        cfg.tp1R = 1
        cfg.tp2R = 2
        cfg.gradeScaledTargets = false
        cfg.targetMode = targetMode
        cfg.tradeBreakers = tradeBreakers
        cfg.minRR = minRR
        return cfg
    }

    /// Bars 0–5 sit well above the zone, so nothing can arm before the
    /// zone's creation bar.
    private func aboveZonePrefix() -> [Candle] {
        (0...5).map { c($0, 105, 106, 104, 105) }
    }

    private func pad(_ candles: [Candle], to count: Int, at level: Double = 105) -> [Candle] {
        var out = candles
        while out.count < count {
            out.append(c(out.count, level, level + 1, level - 1, level))
        }
        return out
    }

    // MARK: - Plan geometry

    func testPlanGeometryForALongMidEntry() {
        let candles = pad(aboveZonePrefix(), to: 20)
        let setup = RankedOBStrategy.compute(candles, zones: [bullZone()], config: config()).first

        XCTAssertEqual(setup?.direction, .long)
        XCTAssertEqual(setup?.entry ?? 0, 99, accuracy: 0.0001)
        XCTAssertEqual(setup?.stopLoss ?? 0, 97.5, accuracy: 0.0001)
        XCTAssertEqual(setup?.takeProfit1 ?? 0, 100.5, accuracy: 0.0001)
        XCTAssertEqual(setup?.takeProfit2 ?? 0, 102, accuracy: 0.0001)
        XCTAssertEqual(setup?.riskReward ?? 0, 2, accuracy: 0.0001)
        // Price never came back, so the plan is still a watch item.
        XCTAssertEqual(setup?.stage, .waiting)
    }

    func testAGradeTargetsGetAnExtraRWhenGradeScalingIsOn() {
        let candles = pad(aboveZonePrefix(), to: 20)
        var cfg = config()
        cfg.gradeScaledTargets = true

        let a = RankedOBStrategy.compute(candles, zones: [bullZone(grade: .a)], config: cfg).first
        let b = RankedOBStrategy.compute(candles, zones: [bullZone(grade: .b)], config: cfg).first

        XCTAssertEqual(a?.takeProfit2 ?? 0, 103.5, accuracy: 0.0001)   // 3R
        XCTAssertEqual(b?.takeProfit2 ?? 0, 102, accuracy: 0.0001)     // 2R
    }

    func testGradeFilterRejectsLowerGrades() {
        let candles = pad(aboveZonePrefix(), to: 20)

        XCTAssertTrue(RankedOBStrategy.compute(candles, zones: [bullZone(grade: .b)], config: config(minGrade: .aOnly)).isEmpty)
        XCTAssertFalse(RankedOBStrategy.compute(candles, zones: [bullZone(grade: .b)], config: config(minGrade: .aOrB)).isEmpty)
        XCTAssertTrue(RankedOBStrategy.compute(candles, zones: [bullZone(grade: .c)], config: config(minGrade: .aOrB)).isEmpty)
    }

    /// With both ranking legs switched off there is nothing to grade on,
    /// so an unranked zone must not be filtered into oblivion.
    func testUnrankedZonesAlwaysPassTheGradeFilter() {
        let candles = pad(aboveZonePrefix(), to: 20)
        let zone = bullZone(grade: .unranked)

        XCTAssertFalse(RankedOBStrategy.compute(candles, zones: [zone], config: config(minGrade: .aOnly)).isEmpty)
    }

    func testMinimumRiskRewardDropsThePlan() {
        let candles = pad(aboveZonePrefix(), to: 20)

        XCTAssertTrue(RankedOBStrategy.compute(candles, zones: [bullZone()], config: config(minRR: 3)).isEmpty)
        XCTAssertFalse(RankedOBStrategy.compute(candles, zones: [bullZone()], config: config(minRR: 2)).isEmpty)
    }

    func testOpposingZoneTargetUsesTheNearestOpposingEdge() {
        let candles = pad(aboveZonePrefix(), to: 20)
        // A C-grade bear zone: excluded from trading by the grade filter,
        // but still a wall the long has to run into.
        let bear = RankedOrderBlocks.Zone(
            startIndex: 1, endIndex: 19, confirmIndex: 2,
            top: 103, bottom: 101, isBullish: false,
            isBreaker: false, isCombined: false,
            grade: .c, score: 1, maxScore: 5, atr: 1.0
        )
        let setups = RankedOBStrategy.compute(
            candles, zones: [bullZone(), bear],
            config: config(minGrade: .aOrB, targetMode: .opposingZone)
        )

        XCTAssertEqual(setups.count, 1)
        XCTAssertEqual(setups.first?.takeProfit2 ?? 0, 101, accuracy: 0.0001)
    }

    // MARK: - Lifecycle walk

    func testFullWalkFromTapToTarget() {
        var candles = aboveZonePrefix()
        candles.append(c(6, 100.8, 101, 99.5, 100.5))   // taps the top → arms + confirms (.touch)
        candles.append(c(7, 100.0, 100, 98.8, 99.2))    // trades through 99 → fill
        candles.append(c(8, 99.2, 100.6, 100.0, 100.5)) // TP1
        candles.append(c(9, 100.5, 102.5, 100.4, 102.4))// TP2
        candles = pad(candles, to: 20)

        let setup = RankedOBStrategy.compute(candles, zones: [bullZone()], config: config()).first

        XCTAssertEqual(setup?.stage, .hitTP)
        XCTAssertEqual(setup?.armIndex, 6)
        XCTAssertEqual(setup?.triggerIndex, 6)
        XCTAssertEqual(setup?.entryIndex, 7)
        XCTAssertEqual(setup?.tp1Index, 8)
        XCTAssertEqual(setup?.resolveIndex, 9)
    }

    /// The confirmation is only knowable at the bar's close, so a fill
    /// must never be counted from that same bar's intrabar range.
    func testFillNeverHappensOnTheConfirmationBar() {
        var candles = aboveZonePrefix()
        // This bar taps, confirms, *and* covers the 99 entry — the fill
        // still has to wait for the next bar.
        candles.append(c(6, 99.6, 100.4, 98.5, 100.3))
        candles.append(c(7, 100.3, 100.4, 98.9, 99.5))
        candles = pad(candles, to: 20)

        let setup = RankedOBStrategy.compute(candles, zones: [bullZone()], config: config(confirmation: .rejection)).first

        XCTAssertEqual(setup?.triggerIndex, 6)
        XCTAssertEqual(setup?.entryIndex, 7)
    }

    func testRejectionConfirmationRequiresACloseBackOutOfTheZone() {
        var candles = aboveZonePrefix()
        // Taps and closes strong, but still inside the zone → no signal.
        candles.append(c(6, 98.6, 99.9, 98.5, 99.8))
        candles = pad(candles, to: 20, at: 99)

        let setup = RankedOBStrategy.compute(candles, zones: [bullZone()], config: config(confirmation: .rejection)).first

        XCTAssertEqual(setup?.armIndex, 6)
        XCTAssertNil(setup?.triggerIndex)
    }

    func testMicroBOSNeedsAReactionExtremeToBreak() {
        var candles = aboveZonePrefix()
        candles.append(c(6, 99.8, 100.0, 99.0, 99.4))   // tap → armed, reaction high 100.0
        candles.append(c(7, 99.4, 99.6, 99.0, 99.5))
        candles.append(c(8, 99.5, 100.4, 99.4, 100.3))  // closes above the reaction high
        candles = pad(candles, to: 20, at: 101)

        let setup = RankedOBStrategy.compute(candles, zones: [bullZone()], config: config(confirmation: .microBOS)).first

        XCTAssertEqual(setup?.armIndex, 6)
        XCTAssertEqual(setup?.triggerIndex, 8)
    }

    func testConfirmCloseEntersAtTheTriggerBarsCloseAndRebasesTargets() {
        var candles = aboveZonePrefix()
        candles.append(c(6, 99.6, 100.4, 98.5, 100.3))  // rejection closes at 100.3
        candles = pad(candles, to: 20, at: 101)

        let setup = RankedOBStrategy.compute(
            candles, zones: [bullZone()],
            config: config(confirmation: .rejection, entryModel: .confirmClose)
        ).first

        // Entry moves to the close; the stop stays pinned under the zone,
        // so risk widens from 1.5 to 2.8 and the targets follow.
        XCTAssertEqual(setup?.entry ?? 0, 100.3, accuracy: 0.0001)
        XCTAssertEqual(setup?.stopLoss ?? 0, 97.5, accuracy: 0.0001)
        XCTAssertEqual(setup?.takeProfit1 ?? 0, 103.1, accuracy: 0.0001)
        XCTAssertEqual(setup?.entryIndex, 6)
        XCTAssertFalse(setup?.isProvisionalEntry ?? true)
    }

    // MARK: - Failure paths

    func testPriceBreakingThePlannedStopBeforeEntryInvalidatesThePlan() {
        var candles = aboveZonePrefix()
        candles.append(c(6, 99.0, 99.5, 97.0, 97.2))    // straight through the stop
        candles = pad(candles, to: 20, at: 97)

        let setup = RankedOBStrategy.compute(candles, zones: [bullZone()], config: config()).first

        XCTAssertEqual(setup?.stage, .invalidated)
        XCTAssertEqual(setup?.resolveIndex, 6)
        XCTAssertNil(setup?.entryIndex)
    }

    func testConfirmationWindowExpires() {
        var candles = aboveZonePrefix()
        // Taps at bar 6, then loiters inside the zone without ever
        // closing back out of it.
        for i in 6...13 { candles.append(c(i, 99.0, 99.5, 98.5, 99.0)) }
        candles = pad(candles, to: 20, at: 99)

        let setup = RankedOBStrategy.compute(candles, zones: [bullZone()], config: config(confirmation: .rejection)).first

        XCTAssertEqual(setup?.stage, .expired)
        XCTAssertEqual(setup?.resolveIndex, 12)   // arm 6 + window 5, first bar past it
    }

    /// Intrabar order is unknowable from OHLC. A bar that covers both the
    /// stop and the target has to count as the stop, or every backtest
    /// built on this learns to lie.
    func testABarCoveringBothStopAndTargetCountsAsTheStop() {
        var candles = aboveZonePrefix()
        candles.append(c(6, 100.8, 101, 99.5, 100.5))
        candles.append(c(7, 100.0, 100, 98.8, 99.2))    // fill at 99
        candles.append(c(8, 99.2, 102.5, 97.0, 98.0))   // covers TP2 and the stop
        candles = pad(candles, to: 20, at: 98)

        let setup = RankedOBStrategy.compute(candles, zones: [bullZone()], config: config()).first

        XCTAssertEqual(setup?.stage, .hitSL)
        XCTAssertEqual(setup?.resolveIndex, 8)
    }

    func testStopMovesToBreakevenAfterTP1() {
        var candles = aboveZonePrefix()
        candles.append(c(6, 100.8, 101, 99.5, 100.5))
        candles.append(c(7, 100.0, 100, 98.8, 99.2))    // fill at 99
        candles.append(c(8, 99.2, 100.6, 100.0, 100.5)) // TP1 → breakeven
        candles.append(c(9, 100.5, 100.5, 98.0, 98.2))  // back through 99
        candles = pad(candles, to: 20, at: 98)

        let setup = RankedOBStrategy.compute(candles, zones: [bullZone()], config: config()).first

        // Scratched at breakeven with TP1 already banked — a win, not a loss.
        XCTAssertEqual(setup?.stage, .hitTP)
        XCTAssertEqual(setup?.tp1Index, 8)
        XCTAssertEqual(setup?.resolveIndex, 9)
    }

    // MARK: - Breakers

    func testBreakerZonesAreSkippedUnlessEnabled() {
        let candles = pad(aboveZonePrefix(), to: 20)
        let broken = bullZone(isBreaker: true, endIndex: 8)

        XCTAssertTrue(RankedOBStrategy.compute(candles, zones: [broken], config: config()).isEmpty)
        XCTAssertFalse(RankedOBStrategy.compute(candles, zones: [broken], config: config(tradeBreakers: true)).isEmpty)
    }

    /// A bullish block that failed is resistance now, so its retest is a
    /// short — entry and stop flip to the other side of the zone.
    func testBreakerPlayInvertsDirection() {
        var candles = (0...8).map { c($0, 96, 97, 95, 96) }
        candles.append(c(9, 96.5, 98.2, 96.4, 98.0))    // retests the underside
        candles.append(c(10, 98.0, 99.2, 98.6, 99.0))   // fills the 99 short
        candles = pad(candles, to: 20, at: 96)

        let setup = RankedOBStrategy.compute(
            candles, zones: [bullZone(isBreaker: true, endIndex: 8)],
            config: config(tradeBreakers: true)
        ).first

        XCTAssertEqual(setup?.direction, .short)
        XCTAssertTrue(setup?.isBreakerPlay ?? false)
        XCTAssertEqual(setup?.entry ?? 0, 99, accuracy: 0.0001)
        XCTAssertEqual(setup?.stopLoss ?? 0, 100.5, accuracy: 0.0001)
        XCTAssertEqual(setup?.takeProfit1 ?? 0, 97.5, accuracy: 0.0001)
        XCTAssertEqual(setup?.armIndex, 9)
    }

    // MARK: - Plumbing

    func testDisabledConfigProducesNothing() {
        let candles = pad(aboveZonePrefix(), to: 20)
        var cfg = config()
        cfg.enabled = false

        XCTAssertTrue(RankedOBStrategy.compute(candles, zones: [bullZone()], config: cfg).isEmpty)
    }

    func testHeadlinePrefersTheLivestPlan() {
        var candles = aboveZonePrefix()
        candles.append(c(6, 100.8, 101, 99.5, 100.5))
        candles.append(c(7, 100.0, 100, 98.8, 99.2))
        // Drifts sideways after the fill — never reaches TP1 (100.5) or
        // the stop (97.5), so the trade stays open at the last bar.
        candles = pad(candles, to: 20, at: 99.2)
        // A second, untouched zone further away — newer, but only waiting.
        let far = RankedOrderBlocks.Zone(
            startIndex: 10, endIndex: 19, confirmIndex: 12,
            top: 94, bottom: 92, isBullish: true,
            isBreaker: false, isCombined: false,
            grade: .a, score: 4, maxScore: 5, atr: 1.0
        )

        let setups = RankedOBStrategy.compute(candles, zones: [bullZone(), far], config: config())
        let headline = RankedOBStrategy.headline(setups)

        XCTAssertEqual(setups.count, 2)
        XCTAssertEqual(headline?.stage, .entered)
    }

    // MARK: - Integration with the real indicator

    /// Everything above hand-builds zones. This one drives
    /// `RankedOrderBlocks.compute` for real, so the two fields the
    /// strategy depends on — `confirmIndex` (the BOS bar, not the order
    /// block) and `atr` — are checked against the engine that produces
    /// them rather than against my assumptions about it.
    func testRealZonesCarryABOSBarAndATRTheStrategyCanUse() {
        // Decline → low pivot → rally that closes through the prior high,
        // leaving a bullish order block at the impulse's lowest candle.
        var candles: [Candle] = [
            c(0, 105, 106, 105, 105), c(1, 104, 105, 104, 104),
            c(2, 103, 104, 103, 103), c(3, 102, 103, 102, 102),
            c(4, 100, 101, 100, 100), c(5, 99, 100, 99, 99),
            c(6, 101, 102, 101, 101), c(7, 103, 104, 103, 103),
            c(8, 105, 106, 105, 105),
            c(9, 104, 105, 104, 104), c(10, 102, 103, 102, 102),
            c(11, 100, 101, 100, 100),
            c(12, 102, 103, 102, 102), c(13, 104, 105, 104, 104),
            c(14, 106, 107, 106, 107),
        ]
        // Pull back into the block, then run.
        candles.append(c(15, 106, 106.5, 100.5, 101))
        candles.append(c(16, 101, 104, 100.2, 103.5))   // dips through the 100.5 entry
        candles.append(c(17, 103.5, 110, 103, 109))

        var zoneCfg = RankedOrderBlocks.Config()
        zoneCfg.swingLength = 3
        zoneCfg.useVolumeProfile = false
        zoneCfg.useIchimoku = false
        zoneCfg.combineOverlapping = false
        let zones = RankedOrderBlocks.compute(candles, config: zoneCfg)

        guard let bull = zones.first(where: { $0.isBullish && !$0.isBreaker }) else {
            return XCTFail("expected a bullish zone")
        }
        // The block is the impulse's lowest candle (bar 11); the zone is
        // only *created* when bar 14 closes through the pivot at 106.
        XCTAssertEqual(bull.startIndex, 11)
        XCTAssertEqual(bull.confirmIndex, 14)
        XCTAssertGreaterThan(bull.atr, 0)

        var cfg = config(confirmation: .touch, minGrade: .any)
        cfg.slATRBuffer = 0.5
        let setup = RankedOBStrategy.compute(candles, zones: zones, config: cfg)
            .first { $0.direction == .long }

        // Bar 15 dips to 100.5, inside the 100–101 block → arms there,
        // which is only reachable because the scan starts at bar 14 and
        // not at the block candle itself.
        XCTAssertEqual(setup?.armIndex, 15)
        XCTAssertNotNil(setup?.entryIndex)
        XCTAssertLessThan(setup?.stopLoss ?? 0, bull.bottom)
    }

    func testSummaryReadsAsAPlan() {
        let candles = pad(aboveZonePrefix(), to: 20)
        let setup = RankedOBStrategy.compute(candles, zones: [bullZone()], config: config()).first

        XCTAssertEqual(
            setup?.summary,
            "Long 98.0000–100.00 — waiting for the retest · entry 99.0000 · SL 97.5000 · TP 100.50 / 102.00 · 2.0R"
        )
    }
}

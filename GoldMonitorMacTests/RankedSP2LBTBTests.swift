import Foundation
import XCTest
@testable import HelixTradingApp

/// Trigger + grading tests for the SP2L + Pro BTB × Ranked OB engine.
///
/// Both series are hand-built so every structural bar sits at a known
/// index: 20 flat bars establish the ATR, then the setup prints where
/// the comment says it does. The grading rubric is switched *off* in the
/// mechanics tests (`mechanicsConfig`) so a trigger failure can only
/// mean the trigger logic changed — the rubric gets its own tests.
///
/// Price levels that depend on a Wilder ATR (stops, targets) are
/// asserted relationally rather than as frozen numbers; the ATR value at
/// a given bar is an implementation detail, the geometry is not.
final class RankedSP2LBTBTests: XCTestCase {

    // MARK: - SP2L

    /// Bars 20–21 displace and leave a gap; bar 23 trades back into it
    /// and closes green above the gap floor.
    func testSP2LArmsOnDisplacementGapAndFiresOnThePullback() throws {
        let setups = RankedSP2LBTB.compute(sp2lLongSeries(), configuration: mechanicsConfig()).setups
        XCTAssertEqual(setups.count, 1)
        let setup = try XCTUnwrap(setups.first)

        XCTAssertEqual(setup.source, .sp2l)
        XCTAssertEqual(setup.direction, .long)
        XCTAssertEqual(setup.armIndex, 21)
        XCTAssertEqual(setup.triggerIndex, 23)
        XCTAssertEqual(setup.status, .triggered)

        // The gap is the imbalance between bar 19's high and bar 21's low.
        XCTAssertEqual(setup.zoneBottom, 100.2, accuracy: 0.0001)
        XCTAssertEqual(setup.zoneTop, 101.4, accuracy: 0.0001)
        // CE is the default entry model — the zone's 50%.
        XCTAssertEqual(setup.entryLevel, 100.8, accuracy: 0.0001)
    }

    func testSP2LPlanEntersAtTheTriggerCloseWithTheStopBelowTheGap() throws {
        let setup = try XCTUnwrap(
            RankedSP2LBTB.compute(sp2lLongSeries(), configuration: mechanicsConfig()).setups.first
        )
        let entry = try XCTUnwrap(setup.entry)
        let stop = try XCTUnwrap(setup.stopLoss)
        let target = try XCTUnwrap(setup.takeProfit)

        XCTAssertEqual(entry, 101.2, accuracy: 0.0001)
        XCTAssertLessThan(stop, setup.zoneBottom)
        XCTAssertEqual(target, entry + (entry - stop) * 3.0, accuracy: 0.0001)
    }

    /// "Edge" rests the order at the near side of the gap instead of its
    /// middle, so it fills earlier — on the bar that only dipped to the
    /// gap's upper half.
    func testEdgeEntryModelFillsEarlierThanCE() throws {
        var edge = mechanicsConfig()
        edge.entryModel = .edge

        let ce = try XCTUnwrap(
            RankedSP2LBTB.compute(sp2lLongSeries(), configuration: mechanicsConfig()).setups.first
        )
        let aggressive = try XCTUnwrap(
            RankedSP2LBTB.compute(sp2lLongSeries(), configuration: edge).setups.first
        )

        XCTAssertEqual(ce.entryLevel, 100.8, accuracy: 0.0001)
        XCTAssertEqual(aggressive.entryLevel, 101.4, accuracy: 0.0001)
        XCTAssertEqual(aggressive.triggerIndex, 22)
        XCTAssertEqual(ce.triggerIndex, 23)
    }

    /// Bar 22 reaches the edge level but closes red. With confirmation
    /// required that bar cannot be the entry; without it, it is.
    func testConfirmationCandleGatesTheEntryBar() throws {
        var edge = mechanicsConfig()
        edge.entryModel = .edge
        var noConfirmation = edge
        noConfirmation.requireConfirmation = false

        let confirmed = try XCTUnwrap(
            RankedSP2LBTB.compute(sp2lLongSeries(redPullback: true), configuration: edge).setups.first
        )
        let unconfirmed = try XCTUnwrap(
            RankedSP2LBTB.compute(sp2lLongSeries(redPullback: true), configuration: noConfirmation).setups.first
        )

        XCTAssertEqual(unconfirmed.triggerIndex, 22)
        XCTAssertEqual(confirmed.triggerIndex, 23)
    }

    /// Closing back through the gap floor inverts it — the setup dies
    /// rather than waiting for a deeper retrace.
    func testCloseThroughTheGapFloorInvalidatesTheSetup() throws {
        let setup = try XCTUnwrap(longSP2L(RankedSP2LBTB.compute(
            sp2lLongSeries(outcome: .invalidate), configuration: mechanicsConfig()
        )))

        XCTAssertEqual(setup.status, .invalidated)
        XCTAssertNil(setup.triggerIndex)
        XCTAssertEqual(setup.resolveIndex, 22)
    }

    func testUntouchedZoneExpiresAfterTheWaitWindow() throws {
        var cfg = mechanicsConfig()
        cfg.maxWaitSP2L = 4
        let setup = try XCTUnwrap(
            RankedSP2LBTB.compute(sp2lLongSeries(outcome: .driftAway), configuration: cfg).setups.first
        )

        XCTAssertEqual(setup.status, .expired)
        XCTAssertNil(setup.triggerIndex)
        // Armed at 21, so bar 26 is the first past the window.
        XCTAssertEqual(setup.resolveIndex, 26)
    }

    /// Still waiting at the right edge — drawn as a live zone, not a
    /// plan, and carrying no entry.
    func testZoneStillWaitingIsReportedAsArmed() throws {
        var cfg = mechanicsConfig()
        cfg.maxWaitSP2L = 60
        let setup = try XCTUnwrap(
            RankedSP2LBTB.compute(sp2lLongSeries(outcome: .driftAway), configuration: cfg).setups.first
        )

        XCTAssertEqual(setup.status, .armed)
        XCTAssertNil(setup.entry)
        XCTAssertNil(setup.resolveIndex)
        XCTAssertTrue(setup.status.isUntriggered)
    }

    // MARK: - Outcomes

    func testRunningToTheTargetResolvesAsTP() throws {
        let setup = try XCTUnwrap(longSP2L(
            RankedSP2LBTB.compute(sp2lLongSeries(outcome: .runsToTarget), configuration: mechanicsConfig())
        ))
        XCTAssertEqual(setup.status, .hitTP)
        XCTAssertNotNil(setup.resolveIndex)
    }

    func testTradingBackThroughTheStopResolvesAsSL() throws {
        let setup = try XCTUnwrap(longSP2L(
            RankedSP2LBTB.compute(sp2lLongSeries(outcome: .stopsOut), configuration: mechanicsConfig())
        ))
        XCTAssertEqual(setup.status, .hitSL)
        XCTAssertNotNil(setup.resolveIndex)
    }

    // MARK: - Direction

    /// Mirroring the series through the horizontal turns the identical
    /// long setup into the identical short one.
    func testMirroredSeriesProducesTheSameSetupShort() throws {
        let setup = try XCTUnwrap(
            RankedSP2LBTB.compute(mirrored(sp2lLongSeries()), configuration: mechanicsConfig()).setups.first
        )

        XCTAssertEqual(setup.direction, .short)
        XCTAssertEqual(setup.source, .sp2l)
        XCTAssertEqual(setup.armIndex, 21)
        XCTAssertEqual(setup.triggerIndex, 23)
        XCTAssertEqual(setup.zoneTop, 200 - 100.2, accuracy: 0.0001)
        XCTAssertEqual(setup.zoneBottom, 200 - 101.4, accuracy: 0.0001)
        XCTAssertGreaterThan(try XCTUnwrap(setup.stopLoss), setup.zoneTop)
    }

    func testShortOnlyRejectsALongSetup() {
        var cfg = mechanicsConfig()
        cfg.directionMode = .short
        XCTAssertTrue(RankedSP2LBTB.compute(sp2lLongSeries(), configuration: cfg).setups.isEmpty)
    }

    func testDisablingSP2LSilencesTheEngine() {
        var cfg = mechanicsConfig()
        cfg.enableSP2L = false
        XCTAssertTrue(RankedSP2LBTB.compute(sp2lLongSeries(), configuration: cfg).setups.isEmpty)
    }

    // MARK: - Pro BTB

    /// Bar 10 makes the pivot high, bar 20 closes through it with a real
    /// body, and bar 22 comes back to it and holds.
    func testBTBArmsOnThePivotBreakAndFiresOnTheRetest() throws {
        var cfg = mechanicsConfig()
        cfg.enableSP2L = false
        let setups = RankedSP2LBTB.compute(btbLongSeries(), configuration: cfg).setups
        XCTAssertEqual(setups.count, 1)
        let setup = try XCTUnwrap(setups.first)

        XCTAssertEqual(setup.source, .btb)
        XCTAssertEqual(setup.direction, .long)
        XCTAssertEqual(setup.armIndex, 20)
        XCTAssertEqual(setup.levelIndex, 10)
        XCTAssertEqual(setup.brokenLevel ?? 0, 100.6, accuracy: 0.0001)
        XCTAssertEqual(setup.triggerIndex, 22)
        XCTAssertEqual(setup.entry ?? 0, 100.9, accuracy: 0.0001)
        // The stop sits under the retest low, not under the level.
        XCTAssertLessThan(try XCTUnwrap(setup.stopLoss), 100.5)
    }

    /// A break that never gets tested is still an armed level, but the
    /// retest may not happen on the bar right after the break — that
    /// bar is the breakout's own follow-through.
    func testRetestCannotFireOnTheBarAfterTheBreak() throws {
        var cfg = mechanicsConfig()
        cfg.enableSP2L = false
        let setup = try XCTUnwrap(
            RankedSP2LBTB.compute(btbLongSeries(immediateRetest: true), configuration: cfg).setups.first
        )
        XCTAssertEqual(setup.armIndex, 20)
        XCTAssertEqual(setup.triggerIndex, 22)
    }

    /// A breakout candle with no body behind it is a drift through the
    /// level, not a break of it.
    func testWeakBreakoutBodyDoesNotArmTheLevel() {
        var cfg = mechanicsConfig()
        cfg.enableSP2L = false
        cfg.minBreakBodyATR = 5.0
        XCTAssertTrue(RankedSP2LBTB.compute(btbLongSeries(), configuration: cfg).setups.isEmpty)
    }

    /// With the overlap gate on, a break needs a fresh imbalance
    /// straddling the level — this series breaks cleanly but leaves none.
    func testFVGOverlapGateRejectsABreakWithNoImbalance() {
        var cfg = mechanicsConfig()
        cfg.enableSP2L = false
        cfg.requireFVGOverlap = true
        XCTAssertTrue(RankedSP2LBTB.compute(btbLongSeries(), configuration: cfg).setups.isEmpty)
    }

    func testClosingBackUnderTheBrokenLevelInvalidatesTheBreak() throws {
        var cfg = mechanicsConfig()
        cfg.enableSP2L = false
        let setup = try XCTUnwrap(
            RankedSP2LBTB.compute(btbLongSeries(failsBack: true), configuration: cfg).setups.first
        )
        XCTAssertEqual(setup.status, .invalidated)
        XCTAssertNil(setup.triggerIndex)
    }

    func testDisablingBTBSilencesTheEngine() {
        var cfg = mechanicsConfig()
        cfg.enableSP2L = false
        cfg.enableBTB = false
        XCTAssertTrue(RankedSP2LBTB.compute(btbLongSeries(), configuration: cfg).setups.isEmpty)
    }

    // MARK: - Grading

    /// With every scoring leg off there is nothing to grade on, so the
    /// setup is unranked. Note this *deviates* from the Pine original,
    /// where disabling all three legs silently blocks every signal at
    /// any minimum-grade setting; here an unranked setup passes the
    /// "C — all setups" gate, which is what turning the rubric off is
    /// asking for.
    func testUnrankedSetupsPassTheCGate() throws {
        let setup = try XCTUnwrap(
            RankedSP2LBTB.compute(sp2lLongSeries(), configuration: mechanicsConfig()).setups.first
        )
        XCTAssertEqual(setup.grade, .unranked)
        XCTAssertEqual(setup.maxScore, 0)
        XCTAssertEqual(setup.badge, "SP2L")
    }

    /// The same setup, scored: it is a weak one on this synthetic series,
    /// so raising the bar to A silences it while C lets it through.
    func testMinimumGradeGatesTheSignal() throws {
        var scored = mechanicsConfig()
        scored.useIchimoku = true
        scored.tenkanLength = 3
        scored.kijunLength = 5
        scored.senkouBLength = 7
        scored.ichimokuDisplacement = 3

        var strict = scored
        strict.minGrade = .a

        let passed = try XCTUnwrap(
            RankedSP2LBTB.compute(sp2lLongSeries(), configuration: scored).setups.first
        )
        XCTAssertEqual(passed.maxScore, 3)
        XCTAssertNotEqual(passed.grade, .a)
        XCTAssertNotNil(passed.triggerIndex)

        // Same zone, higher bar — it stays armed instead of firing.
        let blocked = try XCTUnwrap(
            RankedSP2LBTB.compute(sp2lLongSeries(), configuration: strict).setups.first
        )
        XCTAssertNil(blocked.triggerIndex)
    }

    /// `.required` turns the confluence leg into a gate. There is no
    /// swing order block anywhere near this gap, so nothing may fire.
    func testRequiredOBConfluenceBlocksSetupsWithNoNearbyBlock() throws {
        var cfg = mechanicsConfig()
        cfg.useOrderBlocks = true
        cfg.obMode = .required
        cfg.obProximityATR = 0.0

        let setups = RankedSP2LBTB.compute(sp2lLongSeries(), configuration: cfg).setups
        XCTAssertTrue(setups.allSatisfy { $0.triggerIndex == nil })

        // Same rubric as a bonus rather than a gate: the setup fires,
        // just without the confluence points.
        var bonus = cfg
        bonus.obMode = .bonus
        bonus.minGrade = .c
        let scored = try XCTUnwrap(
            RankedSP2LBTB.compute(sp2lLongSeries(), configuration: bonus).setups.first
        )
        XCTAssertEqual(scored.obConfluence, 0)
        XCTAssertEqual(scored.maxScore, 2)
    }

    // MARK: - Trend filter

    /// The pullback closes below a fast EMA that the displacement
    /// dragged up, so the bias filter refuses the entry.
    func testEMABiasFilterBlocksAnEntryAgainstTheTrend() throws {
        var cfg = mechanicsConfig()
        cfg.trendFilter = .ema
        cfg.emaLength = 3
        cfg.filterZones = false

        let setup = try XCTUnwrap(
            RankedSP2LBTB.compute(sp2lLongSeries(), configuration: cfg).setups.first
        )
        XCTAssertNil(setup.triggerIndex)
    }

    /// `filterZones` extends the same bias to arming, so the zone never
    /// even forms.
    func testBiasFilterCanRejectTheZoneItself() {
        var cfg = mechanicsConfig()
        cfg.trendFilter = .ema
        cfg.emaLength = 3
        cfg.filterZones = true
        cfg.directionMode = .short

        XCTAssertTrue(RankedSP2LBTB.compute(sp2lLongSeries(), configuration: cfg).setups.isEmpty)
    }

    // MARK: - Degenerate input

    func testShortSeriesProducesNothing() {
        XCTAssertEqual(RankedSP2LBTB.compute([]), .empty)
        XCTAssertEqual(
            RankedSP2LBTB.compute(Array(sp2lLongSeries().prefix(6)), configuration: mechanicsConfig()),
            .empty
        )
    }

    func testFlatSeriesProducesNoSetups() {
        let flat = (0..<200).map { i in
            candle(100.0, 100.2, 99.8, i.isMultiple(of: 2) ? 100.05 : 99.95)
        }
        let output = RankedSP2LBTB.compute(flat, configuration: mechanicsConfig())
        XCTAssertTrue(output.setups.isEmpty)
        XCTAssertTrue(output.orderBlocks.isEmpty)
    }

    /// The default configuration has to survive a real-shaped series
    /// without tripping a range assertion anywhere in the scoring path.
    func testDefaultConfigurationRunsCleanOnTheSetupSeries() {
        _ = RankedSP2LBTB.compute(sp2lLongSeries(outcome: .runsToTarget))
        _ = RankedSP2LBTB.compute(mirrored(btbLongSeries()))
    }

    // MARK: - Series construction

    private enum Outcome {
        case none
        case runsToTarget
        case stopsOut
        case invalidate
        case driftAway
    }

    /// Bars 0–19: flat 99.8–100.2, which puts the ATR at ~0.4.
    /// Bars 20–21: the displacement, leaving a gap from 100.2 to 101.4.
    /// Bar 22: dips to 101.0 — into the gap's top half, above CE.
    /// Bar 23: dips to 100.5 — through CE. Both close green.
    ///
    /// Every bar after the displacement is built to *overlap* its
    /// two-bars-back neighbour, so the retrace itself leaves no second
    /// imbalance behind and the series arms exactly one zone.
    private func sp2lLongSeries(
        redPullback: Bool = false,
        outcome: Outcome = .none
    ) -> [Candle] {
        var out = flatBase()

        out.append(candle(100.0, 101.5, 99.9, 101.4))     // 20
        out.append(candle(101.5, 103.5, 101.4, 103.4))    // 21 — gap 100.2…101.4

        switch outcome {
        case .driftAway:
            // Hangs above the gap and never comes back to it. Bar 22's
            // low has to stay under bar 20's high or it prints a fresh
            // gap and re-arms.
            out.append(candle(103.4, 103.6, 101.5, 103.3))
            out += (0..<11).map { i in
                candle(103.4, 103.6, 102.8, i.isMultiple(of: 2) ? 103.5 : 103.3)
            }
            return out
        case .invalidate:
            // Straight through the floor — an inverted gap.
            out.append(candle(103.4, 103.5, 99.5, 99.7))  // 22
            out += (0..<6).map { _ in candle(99.7, 99.9, 99.4, 99.6) }
            return out
        default:
            break
        }

        // 22 — reaches the gap's top half. `redPullback` flips it red so
        // the confirmation gate can be tested against the same touch.
        out.append(redPullback
            ? candle(103.4, 103.5, 101.0, 101.2)
            : candle(101.1, 103.5, 101.0, 101.6))
        // 23 — trades through CE and closes green.
        out.append(candle(101.0, 101.7, 100.5, 101.2))

        switch outcome {
        case .runsToTarget:
            // Steps of 0.6 inside 1.5-wide bars, so consecutive bars
            // always overlap and no imbalance forms on the way up.
            for i in 0..<12 {
                let base = 101.2 + Double(i) * 0.6
                out.append(candle(base, base + 1.0, base - 0.5, base + 0.6))
            }
        case .stopsOut:
            out.append(candle(101.2, 101.3, 99.0, 99.2))
            out += (0..<4).map { _ in candle(99.2, 99.4, 98.9, 99.1) }
        default:
            break
        }
        return out
    }

    /// Bars 0–19: flat, except bar 10 which pokes up to 100.6 and so is
    /// the only pivot high in the series.
    /// Bar 20: closes through it with a full body.
    /// Bar 22: comes back to 100.5 and closes green above the level.
    private func btbLongSeries(
        immediateRetest: Bool = false,
        failsBack: Bool = false
    ) -> [Candle] {
        var out = flatBase(peakAt: 10)

        out.append(candle(100.0, 101.2, 99.9, 101.1))     // 20 — the break

        if failsBack {
            out.append(candle(101.1, 101.2, 100.0, 100.2))
            out += (0..<6).map { _ in candle(100.2, 100.4, 99.9, 100.1) }
            return out
        }

        // 21 — the breakout's own follow-through. With `immediateRetest`
        // it already trades back to the level, which must not fire.
        out.append(immediateRetest
            ? candle(100.7, 101.0, 100.5, 100.9)
            : candle(101.1, 101.3, 100.9, 101.0))
        // 22 — the retest proper.
        out.append(candle(100.7, 101.0, 100.5, 100.9))
        out += (0..<6).map { i in
            candle(100.9, 101.2, 100.7, i.isMultiple(of: 2) ? 101.1 : 100.95)
        }
        return out
    }

    /// Twenty quiet bars, optionally with one distinct high so the pivot
    /// engine has exactly one candidate to find.
    private func flatBase(peakAt peak: Int? = nil) -> [Candle] {
        (0..<20).map { i in
            let close = i.isMultiple(of: 2) ? 100.05 : 99.95
            return candle(100.0, i == peak ? 100.6 : 100.2, 99.8, close)
        }
    }

    /// The long SP2L setup, ignoring anything the tail bars of an
    /// outcome variant happened to arm on the way past.
    private func longSP2L(_ output: RankedSP2LBTB.Output) -> RankedSP2LBTB.Setup? {
        output.setups.first { $0.source == .sp2l && $0.direction == .long }
    }

    /// Flip a series through the horizontal so a long setup becomes the
    /// identical short one — guards against the two directions drifting
    /// apart.
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

    /// Short lookbacks (the series is ~30 bars) and no rubric, so a
    /// failure can only mean the trigger logic moved.
    private func mechanicsConfig() -> RankedSP2LBTB.Configuration {
        var cfg = RankedSP2LBTB.Configuration()
        cfg.atrLength = 5
        cfg.obATRLength = 5
        cfg.emaLength = 5
        cfg.pivotLength = 3
        cfg.swingLength = 5
        cfg.trendFilter = .off
        cfg.requireFVGOverlap = false
        cfg.useVolumeProfile = false
        cfg.useIchimoku = false
        cfg.useOrderBlocks = false
        cfg.minGrade = .c
        cfg.vpLookback = 20
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

    override func setUp() {
        super.setUp()
        nextTimestamp = 1_700_000_000
    }
}

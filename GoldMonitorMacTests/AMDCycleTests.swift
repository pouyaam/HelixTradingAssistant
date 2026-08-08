import Foundation
import XCTest
@testable import HelixTradingApp

/// Phase-rotation tests for the AMD detector.
///
/// The series are built by hand rather than generated so each phase
/// boundary sits at a known bar index: a wide decline (bars 0–10), a
/// contracted base (11–18), a liquidity sweep that closes back inside
/// (19), a displacement leg that leaves a fair value gap (20–21), and
/// whatever the individual test needs after that.
///
/// Price levels are asserted relationally (entry is the gap mid, the
/// stop sits past the sweep, TP1 is one R away) rather than as hard
/// numbers, because the exact stop depends on a Wilder ATR whose value
/// at a given bar is an implementation detail, not behaviour worth
/// freezing.
final class AMDCycleTests: XCTestCase {

    // MARK: - Happy path

    func testDetectsFullCycleFromBaseThroughSweepToExpansion() throws {
        let cycles = detect(bullishCycle())
        XCTAssertEqual(cycles.count, 1)
        let cycle = try XCTUnwrap(cycles.first)

        XCTAssertEqual(cycle.rangeStart, 11)
        XCTAssertEqual(cycle.rangeEnd, 18)
        XCTAssertEqual(cycle.rangeHigh, 100.4, accuracy: 0.0001)
        XCTAssertEqual(cycle.rangeLow, 99.6, accuracy: 0.0001)

        XCTAssertEqual(cycle.sweepIndex, 19)
        XCTAssertEqual(cycle.sweptSide, .low)
        XCTAssertEqual(cycle.sweepPrice ?? 0, 98.8, accuracy: 0.0001)
        // The sweep bar closed back inside the range, so it is its own
        // reclaim — the single-candle liquidity grab.
        XCTAssertEqual(cycle.reclaimIndex, 19)

        XCTAssertEqual(cycle.direction, .long)
        XCTAssertEqual(cycle.expansionIndex, 20)
        XCTAssertEqual(cycle.phase, .expansion)
    }

    /// Sweeping the lows is fuel for a move *up* — the direction is the
    /// opposite of the side that got taken.
    func testSweepOfHighsProducesShortCycle() throws {
        let cycles = detect(mirrored(bullishCycle()))
        let cycle = try XCTUnwrap(cycles.first)

        XCTAssertEqual(cycle.sweptSide, .high)
        XCTAssertEqual(cycle.direction, .short)
        XCTAssertEqual(cycle.phase, .expansion)
    }

    // MARK: - The entry gap

    func testEntryGapIsTheImbalanceInsideTheDisplacementLeg() throws {
        let cycle = try XCTUnwrap(detect(bullishCycle()).first)
        let gap = try XCTUnwrap(cycle.gap)

        // Bars 19/20/21: bar 21's low never traded down to bar 19's
        // high, so the band between them was skipped.
        XCTAssertEqual(gap.index, 20)
        XCTAssertEqual(gap.low, 100.3, accuracy: 0.0001)
        XCTAssertEqual(gap.high, 101.5, accuracy: 0.0001)
        XCTAssertEqual(gap.proximal, 101.5, accuracy: 0.0001)
        XCTAssertEqual(gap.distal, 100.3, accuracy: 0.0001)
    }

    func testPlanRestsInTheGapWithInvalidationPastTheSweep() throws {
        let cycle = try XCTUnwrap(detect(bullishCycle()).first)
        let gap = try XCTUnwrap(cycle.gap)
        let sweep = try XCTUnwrap(cycle.sweepPrice)

        XCTAssertEqual(gap.entry, gap.mid, accuracy: 0.0001)
        XCTAssertLessThan(gap.stopLoss, sweep)
        XCTAssertEqual(gap.takeProfit1, gap.entry + gap.risk, accuracy: 0.0001)
        XCTAssertEqual(gap.takeProfit2, gap.entry + gap.risk * 2, accuracy: 0.0001)
        XCTAssertEqual(gap.riskReward, 2.0, accuracy: 0.0001)
    }

    func testEntryModelPicksTheRequestedEdgeOfTheGap() throws {
        var proximal = config()
        proximal.entryModel = .proximal
        var distal = config()
        distal.entryModel = .distal

        let near = try XCTUnwrap(AMDCycle.compute(bullishCycle(), configuration: proximal).first?.gap)
        let far = try XCTUnwrap(AMDCycle.compute(bullishCycle(), configuration: distal).first?.gap)

        XCTAssertEqual(near.entry, 101.5, accuracy: 0.0001)
        XCTAssertEqual(far.entry, 100.3, accuracy: 0.0001)
        // The far edge is a deeper retrace against the same stop, so it
        // has to be the better R:R of the two.
        XCTAssertGreaterThan(far.riskReward, 0)
        XCTAssertEqual(far.riskReward, 2.0, accuracy: 0.0001)
        XCTAssertLessThan(far.risk, near.risk)
    }

    /// A displacement with no imbalance in it is a real phase read but
    /// not a tradeable one: nothing was skipped, so there is nothing to
    /// retrace into.
    func testExpansionWithoutAGapIsDroppedWhenTheGapIsRequired() {
        let candles = bullishCycle(overlappingExpansion: true)

        var required = config()
        required.requireFVG = true
        XCTAssertTrue(AMDCycle.compute(candles, configuration: required).isEmpty)

        var optional = config()
        optional.requireFVG = false
        let cycle = AMDCycle.compute(candles, configuration: optional).first
        XCTAssertEqual(cycle?.phase, .expansion)
        XCTAssertNil(cycle?.gap)
    }

    /// The R:R floor filters the *trade*. The phase read is still true —
    /// it just isn't worth taking — so it survives unless the user has
    /// also asked to be shown only tradeable cycles.
    func testMinimumRiskRewardDropsThePlanButNotThePhaseRead() throws {
        var cfg = config()
        cfg.minRR = 3.0
        cfg.requireFVG = false
        let cycle = try XCTUnwrap(AMDCycle.compute(bullishCycle(), configuration: cfg).first)

        XCTAssertEqual(cycle.phase, .expansion)
        XCTAssertNil(cycle.gap)

        cfg.requireFVG = true
        XCTAssertTrue(AMDCycle.compute(bullishCycle(), configuration: cfg).isEmpty)
    }

    // MARK: - Plan lifecycle

    func testPlanFillsOnTheRetraceAndRunsToTheFinalTarget() throws {
        let cycle = try XCTUnwrap(detect(bullishCycle(outcome: .runsToTarget)).first)
        let gap = try XCTUnwrap(cycle.gap)

        XCTAssertEqual(gap.state, .tp2)
        XCTAssertEqual(gap.fillIndex, 22)
        XCTAssertNotNil(gap.resolveIndex)
    }

    func testPlanStopsOutWhenPriceTradesBackThroughTheSweep() throws {
        let cycle = try XCTUnwrap(detect(bullishCycle(outcome: .stopsOut)).first)
        let gap = try XCTUnwrap(cycle.gap)

        XCTAssertEqual(gap.state, .stopped)
        XCTAssertEqual(gap.fillIndex, 22)
        XCTAssertEqual(gap.resolveIndex, 23)
    }

    func testUnvisitedGapStaysArmed() throws {
        let cycle = try XCTUnwrap(detect(bullishCycle()).first)
        let gap = try XCTUnwrap(cycle.gap)

        XCTAssertEqual(gap.state, .armed)
        XCTAssertNil(gap.fillIndex)
    }

    // MARK: - Phases that don't complete

    /// A breakout that keeps going was never manipulation — it was just
    /// a breakout, and there is nothing here to fade.
    func testBreakoutWithoutReclaimIsNotAManipulation() {
        let cycles = detect(bullishCycle(reclaims: false), showFailed: true)
        XCTAssertEqual(cycles.first?.phase, .failed)
        XCTAssertNil(cycles.first?.gap)
    }

    func testFailedCyclesAreHiddenByDefault() {
        XCTAssertTrue(detect(bullishCycle(reclaims: false)).isEmpty)
    }

    /// A sweep + reclaim that never expands leaves the cycle sitting in
    /// manipulation for as long as the window allows — this is exactly
    /// the "do not chase" state, and it must not silently become a
    /// trade.
    func testSweepAndReclaimWithoutExpansionStaysInManipulation() throws {
        var cfg = config()
        cfg.maxExpansionBars = 40
        let cycle = try XCTUnwrap(
            AMDCycle.compute(bullishCycle(expands: false), configuration: cfg).first
        )

        XCTAssertEqual(cycle.phase, .manipulation)
        XCTAssertNil(cycle.expansionIndex)
        XCTAssertNil(cycle.gap)
    }

    /// The leg stops making new extremes: positions built in the base
    /// are being unloaded, and the cycle stops being an entry.
    func testStalledLegIsMarkedAsDistribution() throws {
        let cycle = try XCTUnwrap(detect(bullishCycle(outcome: .stalls)).first)

        XCTAssertEqual(cycle.phase, .distribution)
        XCTAssertNotNil(cycle.distributionIndex)
        XCTAssertEqual(cycle.expansionExtremeIndex, 21)
    }

    // MARK: - Accumulation gating

    /// A base is not merely sideways — it is quieter than what led into
    /// it. A drift with the same bar sizes as the move before it is not
    /// inventory building.
    func testUncontractedDriftIsNotAccumulation() {
        let candles = bullishCycle(contracts: false)

        var strict = config()
        strict.requireContraction = true
        XCTAssertTrue(AMDCycle.compute(candles, configuration: strict).isEmpty)

        // Same bars, gate off: they now register as a base. (What
        // follows reads as a genuine breakout rather than a sweep at
        // this bar size, so the cycle that forms is a failed one — the
        // point here is only that the contraction gate is what rejected
        // these bars, not the bars themselves.)
        var loose = config()
        loose.requireContraction = false
        loose.showFailed = true
        XCTAssertFalse(AMDCycle.compute(candles, configuration: loose).isEmpty)
    }

    /// An untouched range only matters while it is the live one; old
    /// pauses in price are not setups.
    func testHistoricUnchallengedRangesAreDropped() {
        // The base ends at 18 and nothing follows it for a long time.
        var candles = Array(bullishCycle().prefix(19))
        candles += (0..<40).map { i in
            candle(100.0, 100.4, 99.6, i.isMultiple(of: 2) ? 100.1 : 99.9)
        }
        XCTAssertTrue(detect(candles).isEmpty)
    }

    func testShortSeriesProducesNothing() {
        XCTAssertTrue(AMDCycle.compute([]).isEmpty)
        XCTAssertTrue(AMDCycle.compute(Array(bullishCycle().prefix(8))).isEmpty)
    }

    func testDefaultConfigurationRunsCleanOnAFlatSeries() {
        let flat = (0..<200).map { i in
            candle(100.0, 100.2, 99.8, i.isMultiple(of: 2) ? 100.05 : 99.95)
        }
        // No contraction anywhere and no sweep — nothing to say.
        XCTAssertTrue(AMDCycle.compute(flat).isEmpty)
    }

    // MARK: - Series construction

    private enum Outcome {
        case none
        case runsToTarget
        case stopsOut
        case stalls
    }

    /// Bars 0–10: a wide decline into the base (gives the ATR something
    /// to work with and makes the contraction real).
    /// Bars 11–18: the accumulation range, 99.6–100.4.
    /// Bar 19: the sweep — down to 98.8, closing back inside.
    /// Bars 20–21: displacement up, leaving a gap between 100.3 and 101.5.
    private func bullishCycle(
        reclaims: Bool = true,
        expands: Bool = true,
        contracts: Bool = true,
        overlappingExpansion: Bool = false,
        outcome: Outcome = .none
    ) -> [Candle] {
        var out: [Candle] = []

        // Decline: ten 2.0-wide bars stepping down 1.1 each.
        for i in 0..<10 {
            let center = 115.0 - Double(i) * 1.1
            out.append(candle(center + 0.8, center + 1.0, center - 1.0, center - 0.8))
        }
        // Transition bar that drops into the base.
        out.append(candle(104.5, 104.6, 100.0, 100.2))

        // Base — eight quiet bars. `contracts: false` keeps the same bar
        // size as the decline so the contraction gate rejects it.
        for i in 0..<8 {
            let close = i.isMultiple(of: 2) ? 100.1 : 99.9
            if contracts {
                out.append(candle(100.0, 100.4, 99.6, close))
            } else {
                out.append(candle(100.0, 101.0, 99.0, close))
            }
        }

        // Manipulation: take the sell-side liquidity under the base.
        // Without the reclaim the same excursion is just a breakdown.
        out.append(reclaims
            ? candle(100.0, 100.3, 98.8, 100.1)
            : candle(100.0, 100.3, 98.4, 98.6))

        guard expands else {
            // Drift sideways below the range instead of expanding.
            out += (0..<10).map { i in
                candle(100.0, 100.35, 99.7, i.isMultiple(of: 2) ? 100.05 : 99.95)
            }
            return out
        }

        if overlappingExpansion {
            // Same destination, but bar 21 trades back down through bar
            // 19's high — fast enough to break the range, orderly
            // enough to leave no imbalance behind.
            out.append(candle(100.1, 101.2, 100.0, 101.1))
            out.append(candle(101.1, 102.6, 100.2, 102.5))
        } else {
            out.append(candle(100.1, 101.2, 100.0, 101.1))
            out.append(candle(101.6, 102.6, 101.5, 102.5))
        }

        switch outcome {
        case .none:
            break
        case .runsToTarget:
            // Retrace into the gap, then run.
            out.append(candle(102.5, 102.6, 100.7, 101.5))
            for i in 0..<8 {
                let base = 101.5 + Double(i) * 1.2
                out.append(candle(base, base + 1.4, base - 0.2, base + 1.2))
            }
        case .stopsOut:
            out.append(candle(102.5, 102.6, 100.7, 101.0))
            out.append(candle(101.0, 101.1, 98.0, 98.2))
        case .stalls:
            // Never comes back to the gap; just stops going anywhere.
            for i in 0..<8 {
                out.append(candle(102.5, 102.55, 102.0, i.isMultiple(of: 2) ? 102.4 : 102.2))
            }
        }
        return out
    }

    /// Flip a series through the horizontal so a long setup becomes the
    /// identical short one. Guards against direction-specific logic
    /// drifting apart.
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

    private func config() -> AMDCycle.Configuration {
        var cfg = AMDCycle.Configuration()
        cfg.atrPeriod = 5
        cfg.minRangeBars = 5
        cfg.maxRangeBars = 30
        cfg.distributionBars = 5
        return cfg
    }

    private func detect(
        _ candles: [Candle],
        showFailed: Bool = false
    ) -> [AMDCycle.Cycle] {
        var cfg = config()
        cfg.showFailed = showFailed
        return AMDCycle.compute(candles, configuration: cfg)
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

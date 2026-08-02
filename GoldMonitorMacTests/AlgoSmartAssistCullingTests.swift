import Foundation
import XCTest
@testable import HelixTradingApp

/// Guards the viewport culling that keeps the chart responsive when
/// ALGOSMART ASSIST v2 is switched on. Without it the renderer hands Swift
/// Charts every mark for the whole series on every pan/zoom frame.
final class AlgoSmartAssistCullingTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func market(bars: Int, seed: UInt64 = 3) -> [Candle] {
        var rng = seed
        func next() -> Double {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Double((rng >> 33) % 1000) / 1000.0
        }
        var out: [Candle] = []
        var price = 2000.0
        for i in 0..<bars {
            let phase = i % 14
            let open = price
            var close: Double
            var wick: Double
            switch phase {
            case 0..<6:  close = price - 4 * (0.7 + next() * 0.5); wick = 4 * (0.5 + next())
            case 6..<9:  close = price + 4 * (1.9 + next() * 0.6); wick = 4 * 0.04
            default:     close = price + 4 * (0.1 + next() * 0.3); wick = 4 * (0.4 + next() * 0.8)
            }
            out.append(Candle(id: start.addingTimeInterval(TimeInterval(i * 60)),
                              open: open, high: max(open, close) + wick,
                              low: min(open, close) - wick, close: close, volume: 100))
            price = close
        }
        return out
    }

    private func defaultParams() -> [String: ParamValue] {
        var params: [String: ParamValue] = [:]
        for spec in IndicatorKind.algoSmartAssist.paramSpecs {
            params[spec.key] = spec.defaultValue
        }
        return params
    }

    private func totalMarks(_ o: AlgoSmartAssist.Output) -> Int {
        o.zones.count * 3 + o.lines.count + o.labels.count
            + o.tpLines.count + o.liveLines.count + o.coloredBars.count
    }

    /// The whole point: a default-sized window over a long series must hand
    /// over a small fraction of the marks.
    func testCullingDropsTheVastMajorityOfMarksOnADefaultWindow() {
        let bars = 3000
        let candles = market(bars: bars)
        let out = AlgoSmartAssist.calculate(candles: candles, params: defaultParams())
        XCTAssertGreaterThan(totalMarks(out), 500, "fixture should be big enough to matter")

        // The chart's default window is the trailing 180 bars.
        let lastIndex = bars - 1
        let culled = out.culled(loBar: lastIndex - 180, hiBar: lastIndex + 1,
                                barCount: bars, lastIndex: lastIndex)

        XCTAssertLessThan(
            Double(totalMarks(culled)) / Double(totalMarks(out)), 0.35,
            "a 180-bar window over \(bars) bars must cull most marks"
        )
        XCTAssertGreaterThan(totalMarks(culled), 0, "the visible window still has to draw something")
    }

    /// Every surviving mark must genuinely overlap the window.
    func testCulledMarksAllOverlapTheWindow() {
        let bars = 2000
        let candles = market(bars: bars)
        let out = AlgoSmartAssist.calculate(candles: candles, params: defaultParams())

        let lo = 900, hi = 1100
        let culled = out.culled(loBar: lo, hiBar: hi, barCount: bars, lastIndex: bars - 1)

        for z in culled.zones {
            XCTAssertTrue((z.endBar ?? bars - 1) >= lo && z.startBar <= hi, "zone outside window")
        }
        for l in culled.lines {
            XCTAssertTrue(l.endBar >= lo && l.startBar <= hi, "line outside window")
        }
        for l in culled.labels {
            XCTAssertTrue(l.bar >= lo && l.bar <= hi, "label outside window")
        }
        for b in culled.coloredBars {
            XCTAssertTrue(b.barIndex >= lo && b.barIndex <= hi, "bar highlight outside window")
        }
    }

    /// Live lines are anchored to the right edge — culling them would delete
    /// the live IDM / BOS / equilibrium readouts.
    func testLiveLinesSurviveCulling() {
        let bars = 1200
        let candles = market(bars: bars)
        let out = AlgoSmartAssist.calculate(candles: candles, params: defaultParams())
        XCTAssertFalse(out.liveLines.isEmpty, "fixture should produce live lines")

        let culled = out.culled(loBar: 0, hiBar: 10, barCount: bars, lastIndex: bars - 1)
        XCTAssertEqual(culled.liveLines.count, out.liveLines.count)
    }

    /// Labels are the priciest mark (each hosts a SwiftUI view), so they are
    /// capped even when a huge window is visible.
    func testLabelBudgetIsEnforcedAndSpreadAcrossTheWindow() {
        let bars = 3000
        let candles = market(bars: bars)
        let out = AlgoSmartAssist.calculate(candles: candles, params: defaultParams())

        // Whole series visible — worst case for label density.
        let culled = out.culled(loBar: 0, hiBar: bars, barCount: bars, lastIndex: bars - 1, labelBudget: 40)
        XCTAssertLessThanOrEqual(culled.labels.count, 40)

        // Strided, not truncated: survivors must still reach the far end.
        if let lastKept = culled.labels.map(\.bar).max(),
           let lastAvailable = out.labels.filter({ $0.bar < bars }).map(\.bar).max() {
            XCTAssertGreaterThan(
                Double(lastKept), Double(lastAvailable) * 0.5,
                "labels were truncated rather than strided"
            )
        }
    }

    func testCullingIsANoOpWhenEverythingFits() {
        let bars = 400
        let candles = market(bars: bars)
        let out = AlgoSmartAssist.calculate(candles: candles, params: defaultParams())

        let culled = out.culled(loBar: -5, hiBar: bars + 5, barCount: bars,
                                lastIndex: bars - 1, labelBudget: 100_000)
        XCTAssertEqual(totalMarks(culled), totalMarks(out))
    }

    func testCullingEmptyOutputIsSafe() {
        let culled = AlgoSmartAssist.Output.empty.culled(loBar: 0, hiBar: 100, barCount: 0, lastIndex: 0)
        XCTAssertEqual(totalMarks(culled), 0)
    }
}

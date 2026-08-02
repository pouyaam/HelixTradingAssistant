import Foundation
import XCTest
@testable import HelixTradingApp

/// Guards `RenkoConfig`'s explicit structural `==`.
///
/// `RenkoConfig` is `RawRepresentable` so it can live in `@AppStorage`, and the
/// standard library supplies `==` for any `RawRepresentable` with an
/// `Equatable` `RawValue`. If the explicit memberwise `==` is ever removed,
/// that overload silently takes over and equality starts comparing *encoded
/// JSON strings* — which is both incorrect (`JSONEncoder` guarantees no key
/// order, so identical configs can compare unequal) and slow enough to make
/// the chart lag, because `ChartDerivedCache.BaseDisplaySig` embeds a
/// `RenkoConfig` and is compared on every `displayCandles` call, per pane.
final class RenkoConfigEqualityTests: XCTestCase {

    func testEqualityIsStructural() {
        let a = RenkoConfig(mode: .fixed, atrPeriod: 14, fixedBoxSize: 2.5)
        let b = RenkoConfig(mode: .fixed, atrPeriod: 14, fixedBoxSize: 2.5)
        XCTAssertEqual(a, b)

        XCTAssertNotEqual(a, RenkoConfig(mode: .atr, atrPeriod: 14, fixedBoxSize: 2.5))
        XCTAssertNotEqual(a, RenkoConfig(mode: .fixed, atrPeriod: 21, fixedBoxSize: 2.5))
        XCTAssertNotEqual(a, RenkoConfig(mode: .fixed, atrPeriod: 14, fixedBoxSize: 3.0))
    }

    /// A round-trip through the persisted representation must still compare
    /// equal to the original — this is the assertion that was intermittently
    /// failing while equality went through `rawValue`.
    func testRoundTripComparesEqualRepeatedly() {
        for _ in 0..<200 {
            let original = RenkoConfig(mode: .fixed, atrPeriod: 14, fixedBoxSize: 2.5)
            let decoded = RenkoConfig(rawValue: original.rawValue)
            XCTAssertEqual(decoded, original)
        }
    }

    /// The performance half of the contract. Structural comparison is ~95 ns;
    /// the `RawRepresentable` string comparison this replaced was ~3700 ns
    /// (two full `JSONEncoder` passes). The bound is deliberately loose — an
    /// order of magnitude above structural, but still far under what the
    /// encode-based implementation could achieve — so it flags a regression
    /// without being timing-flaky.
    func testEqualityDoesNotEncodeJSON() {
        let a = RenkoConfig(mode: .atr, atrPeriod: 14, fixedBoxSize: 1.0)
        let b = RenkoConfig(mode: .atr, atrPeriod: 14, fixedBoxSize: 1.0)
        let iterations = 100_000

        var matches = 0
        let started = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations where a == b { matches += 1 }
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(matches, iterations)
        XCTAssertLessThan(
            elapsed, 0.100,
            """
            \(iterations) comparisons took \(Int(elapsed * 1000)) ms. \
            RenkoConfig.== is almost certainly going through rawValue (JSON \
            encoding) again — check that the explicit static func == still \
            exists on the struct.
            """
        )
    }
}

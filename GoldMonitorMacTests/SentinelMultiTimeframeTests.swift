import XCTest
@testable import HelixTradingApp

/// Covers the multi-timeframe radar scan: the timeframe ladder, the
/// wall-clock candle fold that feeds HTF context, the scan-key/prune logic
/// that keeps several timeframes from overwriting each other, and the
/// geometry-seeded alert ids the drawer's `ForEach` identity depends on.
final class SentinelMultiTimeframeTests: XCTestCase {

    // MARK: - The ladder

    func testHigherTimeframeIsStrictlyCoarser() {
        for tf in Timeframe.allCases {
            guard let higher = tf.higher else {
                XCTAssertEqual(tf, .d1, "only the daily may lack a higher timeframe")
                continue
            }
            XCTAssertGreaterThan(higher.seconds, tf.seconds,
                                 "\(tf.rawValue)'s context must be coarser than itself")
        }
    }

    func testLadderTerminatesFromEveryRung() {
        // Walking up must always reach `.d1` — a cycle would spin the
        // context loader forever.
        for tf in Timeframe.allCases {
            var cursor: Timeframe? = tf
            var steps = 0
            while let current = cursor {
                cursor = current.higher
                steps += 1
                XCTAssertLessThanOrEqual(steps, Timeframe.allCases.count + 1,
                                         "ladder from \(tf.rawValue) does not terminate")
            }
        }
    }

    // MARK: - Wall-clock fold

    /// The bug this replaces: the old fold sliced `candles[i..<i+factor]`
    /// from index 0, so infinite-scroll paging — which *prepends* bars —
    /// shifted every HTF bar and could flip the radar's traded direction.
    func testFoldIsInvariantUnderPrependedHistory() {
        let base = Self.series(count: 240, startingAt: 1_700_000_000, step: 900)
        let prefix = Self.series(count: 7, startingAt: 1_700_000_000 - 7 * 900, step: 900)

        let folded = StrategySentinel.aggregateCandles(base, into: .h1)
        let refolded = StrategySentinel.aggregateCandles(prefix + base, into: .h1)

        XCTAssertGreaterThan(folded.count, 10, "fixture too small to be meaningful")
        // The shared tail has to match bar for bar. Only the boundary bar the
        // prepended bars land in may differ.
        let tail = folded.dropFirst(1)
        let refoldedTail = refolded.suffix(tail.count)
        XCTAssertEqual(Array(tail), Array(refoldedTail),
                       "prepending history shifted the folded HTF series")
    }

    func testFoldAlignsBucketsToWallClock() {
        // Start deliberately mid-hour: buckets must snap to the hour anyway.
        let start = 1_700_000_000 - (1_700_000_000 % 3600) + 1800
        let candles = Self.series(count: 48, startingAt: Double(start), step: 900)
        let folded = StrategySentinel.aggregateCandles(candles, into: .h1)

        for bar in folded {
            let remainder = bar.id.timeIntervalSince1970.truncatingRemainder(dividingBy: 3600)
            XCTAssertEqual(remainder, 0, accuracy: 0.0001,
                           "folded bar \(bar.id) is not on an hour boundary")
        }
    }

    func testFoldPreservesOHLCVWithinABucket() {
        let candles = Self.series(count: 4, startingAt: 1_700_000_000, step: 900)
        let folded = StrategySentinel.aggregateCandles(candles, into: .h1)

        XCTAssertEqual(folded.count, 1)
        guard let bar = folded.first else { return }
        XCTAssertEqual(bar.open, candles[0].open)
        XCTAssertEqual(bar.close, candles[3].close)
        XCTAssertEqual(bar.high, candles.map(\.high).max())
        XCTAssertEqual(bar.low, candles.map(\.low).min())
        XCTAssertEqual(bar.volume, candles.compactMap(\.volume).reduce(0, +))
    }

    // MARK: - Scan keys and pruning

    func testScanKeySeparatesTimeframesOnTheSamePair() {
        let a = StrategySentinel.scanKey("xauusd", "15m")
        let b = StrategySentinel.scanKey("xauusd", "4h")
        XCTAssertNotEqual(a, b, "two timeframes on one pair would overwrite each other")
    }

    func testLiveKeysCoverExactlyTheSelectedTimeframes() {
        let live = StrategySentinel.liveKeys(pairID: "xauusd", timeframes: [.m15, .h1, .h4])
        XCTAssertEqual(live, [
            StrategySentinel.scanKey("xauusd", "15m"),
            StrategySentinel.scanKey("xauusd", "1h"),
            StrategySentinel.scanKey("xauusd", "4h")
        ])
    }

    func testLiveKeysAreEmptyWithoutAPair() {
        // No selected pair means nothing survives a prune — which is what
        // clears the radar when the user switches symbol.
        XCTAssertTrue(StrategySentinel.liveKeys(pairID: nil, timeframes: [.h1]).isEmpty)
    }

    func testLiveKeysDropADeselectedTimeframe() {
        let before = StrategySentinel.liveKeys(pairID: "btc", timeframes: [.m15, .h4])
        let after = StrategySentinel.liveKeys(pairID: "btc", timeframes: [.m15])
        XCTAssertTrue(after.isSubset(of: before))
        XCTAssertFalse(after.contains(StrategySentinel.scanKey("btc", "4h")))
    }

    // MARK: - Read window

    func testWindowStartScalesWithTheTimeframe() {
        let until = Date(timeIntervalSince1970: 1_700_000_000)
        let m15 = StrategySentinel.windowStart(before: until, tf: .m15)
        let h4 = StrategySentinel.windowStart(before: until, tf: .h4)

        XCTAssertLessThan(h4, m15, "a 4h read needs more history than a 15m read")
        for tf in Timeframe.allCases {
            let start = StrategySentinel.windowStart(before: until, tf: tf)
            let bars = until.timeIntervalSince(start) / tf.seconds
            XCTAssertGreaterThanOrEqual(bars, Double(StrategySentinel.maxScanBars),
                                        "\(tf.rawValue) window is short of maxScanBars")
        }
    }

    // MARK: - Alert identity

    /// Ids seed off zone *geometry*, not bar index. A bar-index seed churns
    /// every time the sliding window moves, which resets the drawer's hover
    /// and expanded-accordion state under the user's cursor.
    func testAlertIDIsStableAndTimeframeScoped() {
        let seed15m = "xauusd|15m|BUY|2410.5000|2405.2500"
        let seed4h = "xauusd|4h|BUY|2410.5000|2405.2500"

        XCTAssertEqual(StrategySentinel.deterministicUUID(from: seed15m),
                       StrategySentinel.deterministicUUID(from: seed15m),
                       "same setup must keep its id across scans")
        XCTAssertNotEqual(StrategySentinel.deterministicUUID(from: seed15m),
                          StrategySentinel.deterministicUUID(from: seed4h),
                          "the same zone found on two timeframes needs distinct rows")
    }

    /// The old byte-XOR fold collided on same-length seeds with characters
    /// swapped 16 apart — exactly what near-identical zone prices look like.
    func testAlertIDsDoNotCollideAcrossNearbyZonePrices() {
        var seen = Set<UUID>()
        for step in 0..<600 {
            let top = 2400.0 + Double(step) * 0.01
            let seed = "xauusd|15m|SELL|"
                + String(format: "%.4f", top) + "|"
                + String(format: "%.4f", top - 5)
            XCTAssertTrue(seen.insert(StrategySentinel.deterministicUUID(from: seed)).inserted,
                          "id collision at zone top \(top)")
        }
    }

    func testAlertIDIsAValidV4UUID() {
        let uuid = StrategySentinel.deterministicUUID(from: "xauusd|1h|BUY|1.0000|0.5000")
        let parts = uuid.uuidString.split(separator: "-")
        XCTAssertEqual(parts.count, 5)
        XCTAssertEqual(parts[2].first, "4", "version nibble not set")
        XCTAssertTrue(["8", "9", "a", "b", "A", "B"].contains(String(parts[3].prefix(1))),
                      "variant bits not set")
    }

    // MARK: - HTF context mapping

    /// The engine used to map its HTF context bar into LTF space as
    /// `context.bar * htfFactor`, which silently assumes HTF bar 0 aligns
    /// with LTF bar 0. That is false for any independently loaded HTF series
    /// — the MCP and Smart-Money-Desk paths both pass one — so the gate
    /// landed on the wrong bar. It is a date lookup now.
    func testContextBarMapsByDateOnAMisalignedHTFSeries() {
        let ltf = Self.series(count: 200, startingAt: 1_700_000_000, step: 900)
        // An HTF series that starts 30 hours *before* the LTF series does,
        // which is exactly what a real DB read gives you.
        let htf = Self.series(count: 60, startingAt: 1_700_000_000 - 30 * 3600, step: 3600)

        let contextBar = 40
        let mapped = SMCSentinelEngine.firstBar(in: ltf, atOrAfter: htf[contextBar].id)

        XCTAssertGreaterThanOrEqual(ltf[mapped].id, htf[contextBar].id)
        if mapped > 0 {
            XCTAssertLessThan(ltf[mapped - 1].id, htf[contextBar].id,
                              "mapped to a later bar than necessary")
        }
        // What the old arithmetic would have produced, for contrast.
        XCTAssertNotEqual(mapped, contextBar * 4,
                          "fixture no longer exercises the misalignment")
    }

    func testContextBarClampsWhenTheHTFBarIsNewerThanEveryLTFBar() {
        let ltf = Self.series(count: 50, startingAt: 1_700_000_000, step: 900)
        let future = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SMCSentinelEngine.firstBar(in: ltf, atOrAfter: future),
                       ltf.count - 1)
    }

    func testContextBarMapsToZeroWhenTheHTFBarPredatesTheLTFSeries() {
        let ltf = Self.series(count: 50, startingAt: 1_700_000_000, step: 900)
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        XCTAssertEqual(SMCSentinelEngine.firstBar(in: ltf, atOrAfter: past), 0)
    }

    // MARK: - Fixture

    /// A deterministic candle series. Prices wander enough that a shifted
    /// fold produces visibly different bars, which is what the
    /// prepend-invariance test leans on.
    private static func series(count: Int, startingAt epoch: Double, step: Double) -> [Candle] {
        var out: [Candle] = []
        var price = 2400.0
        for i in 0..<count {
            let wave = sin(Double(i) * 0.7) * 3.0 + cos(Double(i) * 0.23) * 1.5
            let open = price
            let close = price + wave
            out.append(Candle(
                id: Date(timeIntervalSince1970: epoch + Double(i) * step),
                open: open,
                high: max(open, close) + 1.25,
                low: min(open, close) - 1.25,
                close: close,
                volume: 100 + Double(i)
            ))
            price = close
        }
        return out
    }
}

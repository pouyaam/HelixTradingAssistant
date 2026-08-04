import Foundation
import XCTest
@testable import HelixTradingApp

/// Covers `VolumeProfile.computePreviousDay`, the engine behind the
/// "Previous Day (PDH/PDL + VP)" indicator.
final class PreviousDayVPTests: XCTestCase {

    private let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// July dates land in EDT (UTC-4), so 12:00 UTC is 08:00 ET.
    private func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int, _ min: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: y, month: m, day: day, hour: h, minute: min))!
    }

    /// `count` 1-minute candles from `start`, flat 99…101 unless overridden.
    private func candles(
        _ count: Int,
        from start: Date,
        overrides: [Int: (h: Double, l: Double, c: Double, v: Double?)] = [:]
    ) -> [Candle] {
        (0..<count).map { i in
            let date = start.addingTimeInterval(TimeInterval(i * 60))
            if let o = overrides[i] {
                return Candle(id: date, open: o.c, high: o.h, low: o.l, close: o.c, volume: o.v)
            }
            return Candle(id: date, open: 100, high: 101, low: 99, close: 100, volume: 1)
        }
    }

    /// Two full sessions: "yesterday" from 08:00 ET Mon, "today" from
    /// 08:00 ET Tue (the 18:00 ET boundary falls between them).
    private func twoSessions(
        yesterday: [Int: (h: Double, l: Double, c: Double, v: Double?)] = [:],
        today: [Int: (h: Double, l: Double, c: Double, v: Double?)] = [:]
    ) -> [Candle] {
        candles(30, from: d(2026, 7, 13, 12), overrides: yesterday)
            + candles(30, from: d(2026, 7, 14, 12), overrides: today)
    }

    // MARK: - Guard conditions

    func testReturnsNilWithASingleSession() {
        let only = candles(30, from: d(2026, 7, 14, 12))
        XCTAssertNil(VolumeProfile.computePreviousDay(only),
                     "one session means there is no previous day to profile")
    }

    func testReturnsNilOnEmptyAndTinyInput() {
        XCTAssertNil(VolumeProfile.computePreviousDay([]))
        XCTAssertNil(VolumeProfile.computePreviousDay(candles(1, from: d(2026, 7, 14, 12))))
    }

    // MARK: - PDH / PDL

    func testUsesPreviousSessionNotTheOneInProgress() {
        // Yesterday spikes to 130 / dips to 70. Today spikes far wider —
        // and must be ignored entirely.
        let series = twoSessions(
            yesterday: [10: (h: 130, l: 99, c: 100, v: 1), 20: (h: 101, l: 70, c: 100, v: 1)],
            today:     [5:  (h: 500, l: 99, c: 100, v: 1), 6:  (h: 101, l: 10, c: 100, v: 1)]
        )

        let pd = VolumeProfile.computePreviousDay(series)
        XCTAssertNotNil(pd)
        XCTAssertEqual(pd?.high, 130, "PDH must come from the settled session")
        XCTAssertEqual(pd?.low, 70, "PDL must come from the settled session")
    }

    func testHighAndLowBarsPointAtTheBarsThatPrintedThem() {
        let series = twoSessions(
            yesterday: [10: (h: 130, l: 99, c: 100, v: 1), 20: (h: 101, l: 70, c: 100, v: 1)]
        )
        let pd = VolumeProfile.computePreviousDay(series)

        XCTAssertEqual(pd?.highBar, 10)
        XCTAssertEqual(pd?.lowBar, 20)
        XCTAssertEqual(series[pd!.highBar].high, pd!.high)
        XCTAssertEqual(series[pd!.lowBar].low, pd!.low)
    }

    func testSessionBoundsCoverOnlyThePreviousSession() {
        let series = twoSessions()
        let pd = VolumeProfile.computePreviousDay(series)

        XCTAssertEqual(pd?.startBar, 0)
        XCTAssertEqual(pd?.endBar, 29, "previous session is bars 0..<30 of 60")
    }

    func testOpenCloseAndMid() {
        let series = twoSessions(
            yesterday: [0: (h: 101, l: 99, c: 100.5, v: 1),
                        10: (h: 130, l: 99, c: 100, v: 1),
                        20: (h: 101, l: 70, c: 100, v: 1),
                        29: (h: 101, l: 99, c: 100.25, v: 1)]
        )
        let pd = VolumeProfile.computePreviousDay(series)

        XCTAssertEqual(pd?.open, 100.5, "open is the first bar's open")
        XCTAssertEqual(pd?.close, 100.25, "close is the last bar's close")
        XCTAssertEqual(pd?.mid, 100, "mid is the midpoint of 130/70")
    }

    // MARK: - Volume profile

    func testPOCLandsOnTheHeaviestPriceAndSitsInsideTheRange() {
        // Bars 5-9 trade a tight band at 120 carrying most of the volume.
        var yesterday: [Int: (h: Double, l: Double, c: Double, v: Double?)] = [:]
        for i in 5...9 { yesterday[i] = (h: 120.5, l: 119.5, c: 120, v: 500) }
        let series = twoSessions(yesterday: yesterday)

        let pd = VolumeProfile.computePreviousDay(series, bucketCount: 24)
        XCTAssertNotNil(pd)
        XCTAssertEqual(pd!.poc, 120, accuracy: pd!.bucketSize,
                       "POC should land on the heavy 120 band")
        XCTAssertGreaterThanOrEqual(pd!.poc, pd!.low)
        XCTAssertLessThanOrEqual(pd!.poc, pd!.high)
    }

    func testValueAreaBracketsThePOCAndStaysInRange() {
        var yesterday: [Int: (h: Double, l: Double, c: Double, v: Double?)] = [:]
        for i in 5...9 { yesterday[i] = (h: 120.5, l: 119.5, c: 120, v: 500) }
        let series = twoSessions(yesterday: yesterday)

        let pd = VolumeProfile.computePreviousDay(series)!
        XCTAssertLessThanOrEqual(pd.val, pd.poc)
        XCTAssertGreaterThanOrEqual(pd.vah, pd.poc)
        XCTAssertGreaterThanOrEqual(pd.val, pd.low)
        XCTAssertLessThanOrEqual(pd.vah, pd.high)
    }

    func testBucketVolumeSumsToTheSessionVolumeOnly() {
        let series = twoSessions(today: [0: (h: 101, l: 99, c: 100, v: 9_999)])
        let pd = VolumeProfile.computePreviousDay(series)!

        let profiled = pd.buckets.reduce(0.0) { $0 + $1.volume }
        let sessionVolume = series[pd.startBar...pd.endBar].reduce(0.0) { $0 + ($1.volume ?? 0) }
        XCTAssertEqual(profiled, sessionVolume, accuracy: 0.001)
        XCTAssertLessThan(profiled, 9_999, "today's volume must not leak into the profile")
    }

    func testUpDownSplitSumsToTotalPerBucket() {
        let pd = VolumeProfile.computePreviousDay(twoSessions())!
        for bucket in pd.buckets {
            XCTAssertEqual(bucket.upVolume + bucket.downVolume, bucket.volume, accuracy: 0.001)
        }
    }

    func testFlagsTPOWhenNoRealVolume() {
        let series = candles(30, from: d(2026, 7, 13, 12),
                             overrides: Dictionary(uniqueKeysWithValues: (0..<30).map {
                                 ($0, (h: 101.0, l: 99.0, c: 100.0, v: nil as Double?))
                             }))
            + candles(30, from: d(2026, 7, 14, 12))

        let pd = VolumeProfile.computePreviousDay(series)
        XCTAssertEqual(pd?.hasRealVolume, false,
                       "a volumeless session profiles as TPO, and the chart says so")
    }

    func testBucketCountIsHonoured() {
        let series = twoSessions(yesterday: [10: (h: 130, l: 70, c: 100, v: 1)])
        for count in [10, 24, 50] {
            let pd = VolumeProfile.computePreviousDay(series, bucketCount: count)
            XCTAssertEqual(pd?.buckets.count, count)
        }
    }

    // MARK: - Session splitting

    func testSessionRangesTileTheSeriesWithoutGapsOrOverlap() {
        let series = twoSessions()
        let ranges = VolumeProfile.sessionRanges(series)

        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, series.count)
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(a.upperBound, b.lowerBound, "ranges must tile exactly")
        }
    }

    /// `compute` was refactored onto the shared `sessionRanges`; its
    /// session bounds must still agree with the previous-day path.
    func testAgreesWithSessionProfileBounds() {
        let series = twoSessions()
        let sessions = VolumeProfile.compute(series, maxSessions: 5)
        let pd = VolumeProfile.computePreviousDay(series)!

        XCTAssertEqual(sessions.count, 2)
        let previous = sessions[sessions.count - 2]
        XCTAssertEqual(previous.startBar, pd.startBar)
        XCTAssertEqual(previous.endBar, pd.endBar)
        XCTAssertEqual(previous.poc, pd.poc, accuracy: 0.0001)
    }
}

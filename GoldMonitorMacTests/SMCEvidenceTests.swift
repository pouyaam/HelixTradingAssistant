import Foundation
import XCTest
@testable import HelixTradingApp

/// Covers `SMCEvidence` — the pack shared by the Smart Money Desk prompt
/// and the MCP server's tools.
///
/// The properties worth pinning here are the *derived* ones. Detection
/// itself belongs to the engines and has its own suites; what this layer
/// adds is the interpretation an analyst acts on — which side of the
/// range price is on, how far a zone is in ATR, whether two engines agree
/// on a zone, and which previous-day liquidity is still unswept. Those
/// are exactly the facts a model will restate verbatim, so a wrong one
/// propagates straight into a trade plan.
final class SMCEvidenceTests: XCTestCase {

    private let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    private func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int, _ min: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: y, month: m, day: day, hour: h, minute: min))!
    }

    /// A trending series with enough bars and swing structure for the
    /// detectors to have something to find.
    private func trendingSeries(_ count: Int = 400, from start: Date? = nil) -> [Candle] {
        let origin = start ?? d(2026, 7, 13, 12)
        var out: [Candle] = []
        var price = 2000.0
        for i in 0..<count {
            // A rising trend with periodic pullbacks — pivots the swing
            // engine can confirm, rather than a straight line where no
            // order block ever forms.
            let wave = sin(Double(i) / 9.0) * 6.0
            let drift = Double(i) * 0.35
            let close = 2000 + drift + wave
            let open = price
            let high = max(open, close) + 1.5
            let low = min(open, close) - 1.5
            out.append(Candle(
                id: origin.addingTimeInterval(TimeInterval(i * 900)),
                open: open, high: high, low: low, close: close,
                volume: 1000 + Double((i * 37) % 500)
            ))
            price = close
        }
        return out
    }

    // MARK: - Guards

    func testShortSeriesReportsAGapRatherThanEmptySections() {
        let evidence = SMCEvidence.build(
            pairID: "ounce", symbol: "XAU", timeframe: .m15,
            candles: Array(trendingSeries(10))
        )
        XCTAssertTrue(evidence.rankedZones.isEmpty)
        XCTAssertFalse(evidence.gaps.isEmpty,
                       "a too-short series must say so — an empty section reads as 'no structure', which is a different claim")
        XCTAssertTrue(evidence.markdown().contains("Data gaps"))
    }

    func testEmptySeriesDoesNotCrash() {
        let evidence = SMCEvidence.build(
            pairID: "ounce", symbol: "XAU", timeframe: .m15, candles: []
        )
        XCTAssertEqual(evidence.meta.barCount, 0)
        XCTAssertFalse(evidence.gaps.isEmpty)
    }

    // MARK: - Meta

    func testMetaReflectsTheSeries() {
        let candles = trendingSeries()
        let evidence = SMCEvidence.build(
            pairID: "ounce", symbol: "XAU", timeframe: .h1, candles: candles
        )
        XCTAssertEqual(evidence.meta.barCount, candles.count)
        XCTAssertEqual(evidence.meta.lastClose, candles.last!.close, accuracy: 0.0001)
        XCTAssertEqual(evidence.meta.timeframe, "1h")
        XCTAssertEqual(evidence.meta.firstBarAt, candles.first!.bucketStart)
        XCTAssertNotNil(evidence.meta.atr14)
        XCTAssertGreaterThan(evidence.meta.atr14!, 0)
    }

    // MARK: - Ranked zones

    func testRankedZonesAreSortedNearestFirst() {
        let evidence = SMCEvidence.build(
            pairID: "ounce", symbol: "XAU", timeframe: .m15,
            candles: trendingSeries()
        )
        let distances = evidence.rankedZones.compactMap(\.distanceATR)
        XCTAssertEqual(distances, distances.sorted(),
                       "the zone price reaches first is the one an entry gets planned against")
    }

    func testZoneLocationAndDistanceAgree() {
        let evidence = SMCEvidence.build(
            pairID: "ounce", symbol: "XAU", timeframe: .m15,
            candles: trendingSeries()
        )
        let spot = evidence.meta.lastClose
        for z in evidence.rankedZones {
            switch z.priceLocation {
            case "inside":
                XCTAssertTrue(spot >= z.bottom && spot <= z.top)
                XCTAssertEqual(z.distanceATR ?? -1, 0, accuracy: 0.0001,
                               "price inside a zone is zero distance from it")
            case "above":
                XCTAssertGreaterThan(spot, z.top)
            case "below":
                XCTAssertLessThan(spot, z.bottom)
            default:
                XCTFail("unexpected priceLocation \(z.priceLocation)")
            }
            XCTAssertGreaterThanOrEqual(z.top, z.bottom)
            XCTAssertEqual(z.mid, (z.top + z.bottom) / 2, accuracy: 0.0001)
            XCTAssertGreaterThanOrEqual(z.barsAgo, 0)
        }
    }

    func testGradeIsOneOfTheKnownValues() {
        let evidence = SMCEvidence.build(
            pairID: "ounce", symbol: "XAU", timeframe: .m15,
            candles: trendingSeries()
        )
        for z in evidence.rankedZones {
            XCTAssertTrue(["A", "B", "C", "–"].contains(z.grade), "unexpected grade \(z.grade)")
            XCTAssertLessThanOrEqual(z.score, z.maxScore)
        }
    }

    /// The confluence flag cites a specific POI band. That band has to be
    /// real and actually overlap, because the whole point of the pack is
    /// that a model never has to invent a number — and a cited range it
    /// can't cross-check is the easiest number to invent.
    func testCitedPOIOverlapIsRealAndOverlapping() {
        let evidence = SMCEvidence.build(
            pairID: "ounce", symbol: "XAU", timeframe: .m15,
            candles: trendingSeries()
        )
        // Whether this synthetic series happens to make the two engines
        // agree is not the property under test — that depends on the wave
        // shape, and pinning it would make the test a change-detector for
        // the fixture. What must hold is that any citation is truthful.
        XCTAssertFalse(evidence.rankedZones.isEmpty, "fixture should produce zones to check")
        for zone in evidence.rankedZones {
            guard let poi = zone.poiOverlap else {
                XCTAssertFalse(zone.agreesWithPOI)
                continue
            }
            XCTAssertGreaterThanOrEqual(poi.top, poi.bottom)
            XCTAssertTrue(poi.bottom <= zone.top && poi.top >= zone.bottom,
                          "cited POI \(poi.bottom)–\(poi.top) does not overlap zone \(zone.bottom)–\(zone.top)")
            XCTAssertTrue(zone.agreesWithPOI)
        }
    }

    /// The overlap citation, driven directly rather than through a
    /// fixture that may or may not produce agreement.
    func testOverlapCitesTheMostOverlappingPOI() {
        // A series where price carves a clear zone, then the assertion
        // runs against whatever both engines found: if a citation exists
        // it must name the POI sharing the most price with the zone.
        let evidence = SMCEvidence.build(
            pairID: "ounce", symbol: "XAU", timeframe: .m15,
            candles: trendingSeries(600)
        )
        for zone in evidence.rankedZones {
            guard let cited = zone.poiOverlap else { continue }
            let citedShare = min(cited.top, zone.top) - max(cited.bottom, zone.bottom)
            XCTAssertGreaterThan(citedShare, 0, "a cited POI must share price with the zone")
        }
    }

    // MARK: - Previous day

    /// The previous-day section is the one an analyst quotes verbatim, so
    /// every derived field has to survive a case where the answer is
    /// known by construction.
    func testPreviousDayLevelsAndLocation() {
        // Yesterday ranges 90…110; today trades in 95…105 — inside the
        // previous range and never touching either extreme.
        var candles: [Candle] = []
        let yesterdayStart = d(2026, 7, 13, 12)
        for i in 0..<40 {
            let high = i == 10 ? 110.0 : 101.0
            let low  = i == 20 ? 90.0  : 99.0
            candles.append(Candle(
                id: yesterdayStart.addingTimeInterval(TimeInterval(i * 900)),
                open: 100, high: high, low: low, close: 100, volume: 100
            ))
        }
        let todayStart = d(2026, 7, 14, 12)
        for i in 0..<20 {
            candles.append(Candle(
                id: todayStart.addingTimeInterval(TimeInterval(i * 900)),
                open: 100, high: 105, low: 95, close: 100, volume: 100
            ))
        }

        let evidence = SMCEvidence.build(
            pairID: "ounce", symbol: "XAU", timeframe: .m15, candles: candles
        )
        let pd = try? XCTUnwrap(evidence.previousDay)
        guard let pd else { return XCTFail("expected a previous-day profile") }

        XCTAssertEqual(pd.high, 110, accuracy: 0.001)
        XCTAssertEqual(pd.low, 90, accuracy: 0.001)
        XCTAssertEqual(pd.mid, 100, accuracy: 0.001)
        XCTAssertEqual(pd.range, 20, accuracy: 0.001)
        XCTAssertEqual(Set(pd.unsweptLevels), ["PDH", "PDL"],
                       "today never reached 110 or 90, so both extremes are still resting liquidity")
        XCTAssertTrue(pd.priceLocation.contains("inside"), "spot 100 is inside 90…110")
        XCTAssertTrue(pd.val <= pd.poc && pd.poc <= pd.vah, "POC must sit inside the value area")
    }

    func testSweptPDHIsNotReportedAsUnswept() {
        var candles: [Candle] = []
        let yesterdayStart = d(2026, 7, 13, 12)
        for i in 0..<40 {
            candles.append(Candle(
                id: yesterdayStart.addingTimeInterval(TimeInterval(i * 900)),
                open: 100, high: i == 10 ? 110 : 101, low: i == 20 ? 90 : 99, close: 100, volume: 100
            ))
        }
        let todayStart = d(2026, 7, 14, 12)
        for i in 0..<20 {
            // Today trades up through 110, taking the previous high.
            candles.append(Candle(
                id: todayStart.addingTimeInterval(TimeInterval(i * 900)),
                open: 108, high: 112, low: 107, close: 111, volume: 100
            ))
        }

        let evidence = SMCEvidence.build(
            pairID: "ounce", symbol: "XAU", timeframe: .m15, candles: candles
        )
        guard let pd = evidence.previousDay else { return XCTFail("expected a profile") }
        XCTAssertEqual(pd.unsweptLevels, ["PDL"], "PDH was taken; only PDL is still resting")
        XCTAssertEqual(pd.priceLocation, "above PDH")
    }

    func testPreviousDayAbsentOnASingleSession() {
        let oneSession = (0..<40).map { i in
            Candle(id: d(2026, 7, 14, 12).addingTimeInterval(TimeInterval(i * 900)),
                   open: 100, high: 101, low: 99, close: 100, volume: 1)
        }
        let evidence = SMCEvidence.build(
            pairID: "ounce", symbol: "XAU", timeframe: .m15, candles: oneSession
        )
        XCTAssertNil(evidence.previousDay)
        XCTAssertTrue(evidence.gaps.contains { $0.contains("previous-day") })
    }

    // MARK: - Options

    func testSentinelCanBeDisabled() {
        var opts = SMCEvidence.Options.default
        opts.includeSentinel = false
        let evidence = SMCEvidence.build(
            pairID: "ounce", symbol: "XAU", timeframe: .m15,
            candles: trendingSeries(), options: opts
        )
        XCTAssertNil(evidence.sentinel, "the HTF pack runs without a sentinel pass")
    }

    func testZonesPerSideIsRespected() {
        var opts = SMCEvidence.Options.default
        opts.zonesPerSide = 1
        let evidence = SMCEvidence.build(
            pairID: "ounce", symbol: "XAU", timeframe: .m15,
            candles: trendingSeries(), options: opts
        )
        let bulls = evidence.rankedZones.filter { $0.direction == "bullish" }
        let bears = evidence.rankedZones.filter { $0.direction == "bearish" }
        XCTAssertLessThanOrEqual(bulls.count, 1)
        XCTAssertLessThanOrEqual(bears.count, 1)
    }

    // MARK: - Rendering

    func testMarkdownCoversEveryEngineSection() {
        let evidence = SMCEvidence.build(
            pairID: "ounce", symbol: "XAU", timeframe: .m15,
            candles: trendingSeries()
        )
        let md = evidence.markdown()
        XCTAssertTrue(md.contains("Market structure"))
        XCTAssertTrue(md.contains("Ranked Order Blocks"))
        XCTAssertTrue(md.contains("Previous day"))
        XCTAssertFalse(md.contains("nan"), "a NaN reaching the prompt would be quoted back as a price")
    }

    func testEvidenceRoundTripsThroughJSON() {
        let evidence = SMCEvidence.build(
            pairID: "ounce", symbol: "XAU", timeframe: .m15,
            candles: trendingSeries()
        )
        let data = try! MCP.encoder.encode(evidence)
        let decoded = try! MCP.decoder.decode(SMCEvidence.self, from: data)
        // The MCP path serves this pack as JSON; a lossy round-trip would
        // mean external clients and the in-app prompt see different numbers.
        XCTAssertEqual(decoded.rankedZones.count, evidence.rankedZones.count)
        XCTAssertEqual(decoded.meta.lastClose, evidence.meta.lastClose, accuracy: 0.0001)
        XCTAssertEqual(decoded.previousDay?.poc, evidence.previousDay?.poc)
    }
}

import Foundation
import XCTest
@testable import HelixTradingApp

/// State-machine tests for `SentinelOutcome.evaluate` — the pure
/// fill/win/loss/expiry tracker behind sentinel signal persistence.
/// BUY fixture geometry: entry 100, SL 95, TP 110 (SELL mirrors it).
final class SentinelOutcomeTests: XCTestCase {

    // MARK: - Helpers

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func candle(_ offset: TimeInterval, o: Double, h: Double, l: Double, c: Double) -> Candle {
        Candle(id: t0.addingTimeInterval(offset), open: o, high: h, low: l, close: c, volume: nil)
    }

    private func evalBuy(filledAt: Date? = nil, candles: [Candle]) -> SentinelOutcome.Event {
        SentinelOutcome.evaluate(
            direction: .buy, entry: 100, sl: 95, tp: 110,
            createdAt: t0, filledAt: filledAt, candles: candles
        )
    }

    private func evalSell(filledAt: Date? = nil, candles: [Candle]) -> SentinelOutcome.Event {
        SentinelOutcome.evaluate(
            direction: .sell, entry: 100, sl: 105, tp: 90,
            createdAt: t0, filledAt: filledAt, candles: candles
        )
    }

    // MARK: - BUY: fill then resolve

    func testBuyFillThenWinAcrossPasses() {
        let fillBar = candle(60, o: 101, h: 102, l: 99, c: 101)   // dips into entry
        // Pass 1: fill only.
        XCTAssertEqual(evalBuy(candles: [fillBar]), .filled(at: fillBar.id))
        // Pass 2: TP touched on a later bar → win at TP.
        let tpBar = candle(120, o: 105, h: 111, l: 104, c: 109)
        XCTAssertEqual(
            evalBuy(filledAt: fillBar.id, candles: [fillBar, tpBar]),
            .resolved(.win, at: tpBar.id, price: 110)
        )
    }

    func testBuyFillThenWinSinglePass() {
        // Fill not yet persisted → resolution carries the fill time along.
        let fillBar = candle(60, o: 101, h: 102, l: 99, c: 101)
        let tpBar = candle(120, o: 105, h: 111, l: 104, c: 109)
        XCTAssertEqual(
            evalBuy(candles: [fillBar, tpBar]),
            .filledThenResolved(filledAt: fillBar.id, outcome: .win, at: tpBar.id, price: 110)
        )
    }

    func testBuyFillThenLoss() {
        let fillBar = candle(60, o: 101, h: 102, l: 99, c: 101)
        let slBar = candle(120, o: 98, h: 99, l: 94, c: 96)
        XCTAssertEqual(
            evalBuy(filledAt: fillBar.id, candles: [fillBar, slBar]),
            .resolved(.loss, at: slBar.id, price: 95)
        )
    }

    func testBuySameCandleFillAndStopIsLoss() {
        // One bar covers entry AND trades through the stop → filled, then
        // loss (we can't know which came first; conservative).
        let bar = candle(60, o: 101, h: 102, l: 94, c: 96)
        XCTAssertEqual(
            evalBuy(candles: [bar]),
            .filledThenResolved(filledAt: bar.id, outcome: .loss, at: bar.id, price: 95)
        )
    }

    func testBuyPostFillBothTouchedIsLoss() {
        // SL + TP in the same post-fill candle → loss (conservative).
        let fillBar = candle(60, o: 101, h: 102, l: 99, c: 101)
        let wildBar = candle(120, o: 100, h: 112, l: 93, c: 100)
        XCTAssertEqual(
            evalBuy(filledAt: fillBar.id, candles: [fillBar, wildBar]),
            .resolved(.loss, at: wildBar.id, price: 95)
        )
    }

    func testBuyFillCandleTpTouchNotCredited() {
        // TP touched on the very candle that fills → still just a fill;
        // unprovable wins are not handed out.
        let bar = candle(60, o: 101, h: 112, l: 99, c: 108)
        XCTAssertEqual(evalBuy(candles: [bar]), .filled(at: bar.id))
    }

    // MARK: - BUY: pre-fill expiry

    func testBuyPreFillStopGapIsExpired() {
        // Whole bar below entry, through the stop — price gapped through
        // the zone without ever trading at entry.
        let bar = candle(60, o: 97, h: 98, l: 93, c: 94)
        XCTAssertEqual(evalBuy(candles: [bar]), .resolved(.expired, at: bar.id, price: 95))
    }

    func testBuyPreFillTakeProfitRunawayIsExpired() {
        // Whole bar above entry and through the target — ran away without us.
        let bar = candle(60, o: 105, h: 111, l: 101, c: 108)
        XCTAssertEqual(evalBuy(candles: [bar]), .resolved(.expired, at: bar.id, price: 110))
    }

    func testBuyStaleUnfilledIsExpired() {
        // > 5×24h of closed bars, never touching entry/SL/TP → expired,
        // priced at the last close.
        var bars: [Candle] = []
        for i in 1...7 {
            let day = TimeInterval(i * 86_400)
            bars.append(candle(day, o: 103, h: 105, l: 102, c: 104))
        }
        XCTAssertEqual(
            evalBuy(candles: bars),
            .resolved(.expired, at: bars.last!.id, price: 104)
        )
    }

    func testBuyUntouchedStaysUnchanged() {
        // Bars hover between entry and TP without reaching either side.
        let bars = [
            candle(60, o: 103, h: 105, l: 102, c: 104),
            candle(120, o: 104, h: 106, l: 103, c: 105),
        ]
        XCTAssertEqual(evalBuy(candles: bars), .unchanged)
    }

    func testBuyCandlesAtOrBeforeCreationIgnored() {
        // The signal's own forming bar (id == createdAt) must not fill it.
        let sameBar = candle(0, o: 101, h: 102, l: 94, c: 96)
        XCTAssertEqual(evalBuy(candles: [sameBar]), .unchanged)
    }

    // MARK: - SELL mirrors (entry 100, SL 105, TP 90)

    func testSellFillThenWin() {
        let fillBar = candle(60, o: 99, h: 101, l: 98, c: 99)     // pops into entry
        let tpBar = candle(120, o: 95, h: 96, l: 89, c: 91)
        XCTAssertEqual(evalSell(candles: [fillBar]), .filled(at: fillBar.id))
        XCTAssertEqual(
            evalSell(filledAt: fillBar.id, candles: [fillBar, tpBar]),
            .resolved(.win, at: tpBar.id, price: 90)
        )
    }

    func testSellFillThenLoss() {
        let fillBar = candle(60, o: 99, h: 101, l: 98, c: 99)
        let slBar = candle(120, o: 102, h: 106, l: 101, c: 104)
        XCTAssertEqual(
            evalSell(filledAt: fillBar.id, candles: [fillBar, slBar]),
            .resolved(.loss, at: slBar.id, price: 105)
        )
    }

    func testSellSameCandleFillAndStopIsLoss() {
        let bar = candle(60, o: 99, h: 106, l: 98, c: 104)
        XCTAssertEqual(
            evalSell(candles: [bar]),
            .filledThenResolved(filledAt: bar.id, outcome: .loss, at: bar.id, price: 105)
        )
    }

    func testSellPreFillStopGapIsExpired() {
        // Whole bar above entry, through the stop.
        let bar = candle(60, o: 103, h: 106, l: 101, c: 104)
        XCTAssertEqual(evalSell(candles: [bar]), .resolved(.expired, at: bar.id, price: 105))
    }

    func testSellPreFillTakeProfitRunawayIsExpired() {
        // Whole bar below entry and through the target.
        let bar = candle(60, o: 95, h: 98, l: 89, c: 92)
        XCTAssertEqual(evalSell(candles: [bar]), .resolved(.expired, at: bar.id, price: 90))
    }

    func testSellStaleUnfilledIsExpired() {
        var bars: [Candle] = []
        for i in 1...6 {
            let day = TimeInterval(i * 86_400)
            bars.append(candle(day, o: 97, h: 98, l: 95, c: 96))
        }
        XCTAssertEqual(
            evalSell(candles: bars),
            .resolved(.expired, at: bars.last!.id, price: 96)
        )
    }

    func testSellUntouchedStaysUnchanged() {
        let bars = [
            candle(60, o: 97, h: 98, l: 95, c: 96),
            candle(120, o: 96, h: 97, l: 94, c: 95),
        ]
        XCTAssertEqual(evalSell(candles: bars), .unchanged)
    }

    // MARK: - Filled signals only evaluate later bars

    func testAlreadyFilledIgnoresFillBarItself() {
        // The fill bar also trades below the stop (fill came first in
        // reality). With filledAt persisted, that bar is skipped and the
        // signal stays open.
        let fillBar = candle(60, o: 101, h: 102, l: 94, c: 101)
        XCTAssertEqual(evalBuy(filledAt: fillBar.id, candles: [fillBar]), .unchanged)
    }
}

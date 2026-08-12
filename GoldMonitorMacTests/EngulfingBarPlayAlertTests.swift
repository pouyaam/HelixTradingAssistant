import Foundation
import XCTest
@testable import HelixTradingApp

/// Notification-path tests for the EBP engine. Mirrors
/// `RankedSP2LBTBAlertTests`: the first evaluation only seeds the
/// baseline, and every later *change* of status fires exactly once.
@MainActor
final class EngulfingBarPlayAlertTests: XCTestCase {

    private var alertStore: AlertStore!
    private var inbox: NotificationInbox!

    override func setUp() {
        super.setUp()
        inbox = NotificationInbox()
        inbox.clearAll()
        alertStore = AlertStore()
        alertStore.attach(inbox: inbox)
    }

    override func tearDown() {
        inbox.clearAll()
        inbox = nil
        alertStore = nil
        super.tearDown()
    }

    private let pairID = "XAUUSD"
    private let pairLabel = "XAU/USD"

    private func setup(
        direction: EngulfingBarPlay.Direction = .long,
        index: Int = 21,
        status: EngulfingBarPlay.Status = .pending
    ) -> EngulfingBarPlay.Setup {
        EngulfingBarPlay.Setup(
            direction: direction,
            index: index,
            barHigh: 2050.0,
            barLow: 2040.0,
            closeQuality: .strong,
            entryKind: .limit,
            entryLevel: 2047.5,
            stopLoss: 2042.5,
            takeProfit: 2057.5,
            triggerIndex: nil,
            resolveIndex: nil,
            status: status
        )
    }

    func testSetupLifecycleFiresOneNotificationPerTransition() throws {
        let pending = setup()

        // Seeding call — baseline established, nothing fired.
        alertStore.evaluateEngulfingBarPlaySetups([pending], pairID: pairID, pairLabel: pairLabel)
        XCTAssertEqual(inbox.records.count, 0)

        // A second pattern appears.
        let second = setup(direction: .short, index: 30)
        alertStore.evaluateEngulfingBarPlaySetups([pending, second], pairID: pairID, pairLabel: pairLabel)
        XCTAssertEqual(inbox.records.count, 1)
        let armed = try XCTUnwrap(inbox.records.last)
        XCTAssertTrue(armed.title.contains("EBP Bearish armed"))
        XCTAssertEqual(armed.category, NotificationRecord.Category.strategy)

        // pending → triggered
        var filled = pending
        filled.status = .triggered
        filled.triggerIndex = 22
        alertStore.evaluateEngulfingBarPlaySetups([filled, second], pairID: pairID, pairLabel: pairLabel)
        XCTAssertEqual(inbox.records.count, 2)
        XCTAssertTrue(try XCTUnwrap(inbox.records.last).title.contains("EBP Bullish entered"))

        // Re-evaluating an unchanged set is silent.
        alertStore.evaluateEngulfingBarPlaySetups([filled, second], pairID: pairID, pairLabel: pairLabel)
        XCTAssertEqual(inbox.records.count, 2)

        // triggered → hitTP
        var won = filled
        won.status = .hitTP
        won.resolveIndex = 26
        alertStore.evaluateEngulfingBarPlaySetups([won, second], pairID: pairID, pairLabel: pairLabel)
        XCTAssertEqual(inbox.records.count, 3)
        XCTAssertTrue(try XCTUnwrap(inbox.records.last).title.contains("EBP Bullish hit target"))

        // pending → cancelled
        var expired = second
        expired.status = .cancelled
        expired.resolveIndex = 50
        alertStore.evaluateEngulfingBarPlaySetups([won, expired], pairID: pairID, pairLabel: pairLabel)
        XCTAssertEqual(inbox.records.count, 4)
        XCTAssertTrue(try XCTUnwrap(inbox.records.last).title.contains("EBP Bearish expired"))
    }

    /// A pattern that printed while another setup was working is drawn
    /// on the chart but is not a trade, so it must never notify.
    func testSkippedSetupsNeverNotify() {
        let pending = setup()
        alertStore.evaluateEngulfingBarPlaySetups([pending], pairID: pairID, pairLabel: pairLabel)

        let skipped = setup(direction: .short, index: 33, status: .skipped)
        alertStore.evaluateEngulfingBarPlaySetups([pending, skipped], pairID: pairID, pairLabel: pairLabel)

        XCTAssertEqual(inbox.records.count, 0)
    }

    /// When the indicator is pinned to another timeframe, the record has
    /// to name the timeframe the pattern actually printed on — not
    /// whatever the chart happens to be showing.
    func testTimeframeOverrideLandsOnTheRecord() throws {
        let pending = setup()
        alertStore.evaluateEngulfingBarPlaySetups(
            [pending], pairID: pairID, pairLabel: pairLabel, timeframeLabel: "4h"
        )

        var filled = pending
        filled.status = .triggered
        filled.triggerIndex = 22
        alertStore.evaluateEngulfingBarPlaySetups(
            [filled], pairID: pairID, pairLabel: pairLabel, timeframeLabel: "4h"
        )

        XCTAssertEqual(inbox.records.count, 1)
        XCTAssertEqual(try XCTUnwrap(inbox.records.last).timeframeLabel, "4h")
    }

    /// Each timeframe keeps its own baseline, so switching the setting
    /// re-seeds instead of firing a burst of "new" setups.
    func testEachTimeframeSeedsItsOwnBaseline() {
        let pending = setup()
        alertStore.evaluateEngulfingBarPlaySetups(
            [pending], pairID: pairID, pairLabel: pairLabel, timeframeLabel: "1h"
        )
        XCTAssertEqual(inbox.records.count, 0)

        // Same setup, different timeframe — a first observation again.
        alertStore.evaluateEngulfingBarPlaySetups(
            [pending], pairID: pairID, pairLabel: pairLabel, timeframeLabel: "4h"
        )
        XCTAssertEqual(inbox.records.count, 0)
    }

    func testBreakevenExitIsReportedAsNeitherWinNorLoss() throws {
        var live = setup(status: .triggered)
        live.triggerIndex = 22
        alertStore.evaluateEngulfingBarPlaySetups([live], pairID: pairID, pairLabel: pairLabel)

        var flat = live
        flat.status = .breakeven
        flat.movedToBreakeven = true
        flat.resolveIndex = 28
        alertStore.evaluateEngulfingBarPlaySetups([flat], pairID: pairID, pairLabel: pairLabel)

        XCTAssertEqual(inbox.records.count, 1)
        XCTAssertTrue(try XCTUnwrap(inbox.records.last).title.contains("closed at breakeven"))
    }
}

import Foundation
import XCTest
@testable import HelixTradingApp

@MainActor
final class RankedSP2LBTBAlertTests: XCTestCase {

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

    func testOrderBlockLifecycleNotifications() {
        let pairID = "XAUUSD"
        let pairLabel = "XAU/USD"

        let block1 = RankedSP2LBTB.OrderBlock(
            startIndex: 10,
            endIndex: 20,
            top: 2050.0,
            bottom: 2040.0,
            isBullish: true,
            isBreaker: false,
            grade: .a,
            score: 6,
            maxScore: 7
        )

        // Initial evaluation — baseline seeding, no notifications.
        alertStore.evaluateRankedSP2LBTBOrderBlocks([block1], pairID: pairID, pairLabel: pairLabel)
        XCTAssertEqual(inbox.records.count, 0)

        // Second block appears
        let block2 = RankedSP2LBTB.OrderBlock(
            startIndex: 25,
            endIndex: 30,
            top: 2060.0,
            bottom: 2055.0,
            isBullish: false,
            isBreaker: false,
            grade: .b,
            score: 4,
            maxScore: 7
        )

        alertStore.evaluateRankedSP2LBTBOrderBlocks([block1, block2], pairID: pairID, pairLabel: pairLabel)
        XCTAssertEqual(inbox.records.count, 1)
        let item1 = try! XCTUnwrap(inbox.records.last)
        XCTAssertTrue(item1.title.contains("Bearish SP2L/BTB Order Block formed"))
        XCTAssertEqual(item1.category, NotificationRecord.Category.orderBlock)

        // Block1 flips to breaker
        let block1Breaker = RankedSP2LBTB.OrderBlock(
            startIndex: 10,
            endIndex: 20,
            top: 2050.0,
            bottom: 2040.0,
            isBullish: true,
            isBreaker: true,
            grade: .a,
            score: 6,
            maxScore: 7
        )

        alertStore.evaluateRankedSP2LBTBOrderBlocks([block1Breaker, block2], pairID: pairID, pairLabel: pairLabel)
        XCTAssertEqual(inbox.records.count, 2)
        let item2 = try! XCTUnwrap(inbox.records.last)
        XCTAssertTrue(item2.title.contains("Bullish SP2L/BTB Order Block exhausted"))
    }

    func testSetupStatusNotificationsLifecycle() {
        let pairID = "XAUUSD"
        let pairLabel = "XAU/USD"

        let setupArmed = RankedSP2LBTB.Setup(
            source: .sp2l,
            direction: .long,
            armIndex: 15,
            zoneTop: 2010.0,
            zoneBottom: 2000.0,
            brokenLevel: nil,
            levelIndex: nil,
            entryLevel: 2005.0,
            grade: .a,
            score: 6,
            maxScore: 7,
            obConfluence: 2,
            triggerIndex: nil,
            entry: nil,
            stopLoss: nil,
            takeProfit: nil,
            resolveIndex: nil,
            status: .armed
        )

        // Seeding call — baseline established, 0 notifications.
        alertStore.evaluateRankedSP2LBTBSetups([setupArmed], pairID: pairID, pairLabel: pairLabel)
        XCTAssertEqual(inbox.records.count, 0)

        // New setup appears on subsequent evaluation -> Armed notification
        let setup2Armed = RankedSP2LBTB.Setup(
            source: .btb,
            direction: .short,
            armIndex: 20,
            zoneTop: 2050.0,
            zoneBottom: 2045.0,
            brokenLevel: 2048.0,
            levelIndex: 18,
            entryLevel: 2047.0,
            grade: .b,
            score: 4,
            maxScore: 7,
            obConfluence: 1,
            triggerIndex: nil,
            entry: nil,
            stopLoss: nil,
            takeProfit: nil,
            resolveIndex: nil,
            status: .armed
        )

        alertStore.evaluateRankedSP2LBTBSetups([setupArmed, setup2Armed], pairID: pairID, pairLabel: pairLabel)
        XCTAssertEqual(inbox.records.count, 1)
        let rec1 = try! XCTUnwrap(inbox.records.last)
        XCTAssertTrue(rec1.title.contains("BTB Short armed"))
        XCTAssertEqual(rec1.category, NotificationRecord.Category.strategy)

        // Setup 1 status changes: armed -> triggered
        var setup1Triggered = setupArmed
        setup1Triggered.status = .triggered
        setup1Triggered.triggerIndex = 22
        setup1Triggered.entry = 2005.0
        setup1Triggered.stopLoss = 1995.0
        setup1Triggered.takeProfit = 2035.0

        alertStore.evaluateRankedSP2LBTBSetups([setup1Triggered, setup2Armed], pairID: pairID, pairLabel: pairLabel)
        XCTAssertEqual(inbox.records.count, 2)
        let rec2 = try! XCTUnwrap(inbox.records.last)
        XCTAssertTrue(rec2.title.contains("SP2L Long triggered"))

        // Setup 1 status changes: triggered -> hitTP
        var setup1HitTP = setup1Triggered
        setup1HitTP.status = .hitTP
        setup1HitTP.resolveIndex = 30

        alertStore.evaluateRankedSP2LBTBSetups([setup1HitTP, setup2Armed], pairID: pairID, pairLabel: pairLabel)
        XCTAssertEqual(inbox.records.count, 3)
        let rec3 = try! XCTUnwrap(inbox.records.last)
        XCTAssertTrue(rec3.title.contains("SP2L Long hit target"))

        // Setup 2 status changes: armed -> invalidated
        var setup2Invalidated = setup2Armed
        setup2Invalidated.status = .invalidated

        alertStore.evaluateRankedSP2LBTBSetups([setup1HitTP, setup2Invalidated], pairID: pairID, pairLabel: pairLabel)
        XCTAssertEqual(inbox.records.count, 4)
        let rec4 = try! XCTUnwrap(inbox.records.last)
        XCTAssertTrue(rec4.title.contains("BTB Short invalidated"))
    }
}

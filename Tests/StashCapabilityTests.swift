import XCTest
@testable import BabyBuddy

@MainActor
final class StashCapabilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StashCapability.reset()
    }

    override func tearDown() {
        StashCapability.reset()
        super.tearDown()
    }

    private let summaryJSON = Data("""
    {"balance": 200.5, "status": "warn", "warn_age_hours": 48, "max_age_hours": 72,
     "expired_amount": 0.0,
     "lots": [{"time": "2026-10-10T08:00:00.123456+02:00", "amount": 80.5,
               "warn_at": "2026-10-12T08:00:00.123456+02:00", "expires_at": "2026-10-13T08:00:00.123456+02:00",
               "status": "warn"},
              {"time": "2026-10-12T06:00:00+02:00", "amount": 120.0,
               "warn_at": "2026-10-14T06:00:00+02:00", "expires_at": "2026-10-15T06:00:00+02:00",
               "status": "ok"}]}
    """.utf8)

    func testDecodesTheServersSummary() throws {
        let summary = try APICoders.decoder.decode(StashSummaryDTO.self, from: summaryJSON)
        XCTAssertEqual(summary.balance, 200.5)
        XCTAssertEqual(summary.status, .warn)
        XCTAssertEqual(summary.max_age_hours, 72)
        XCTAssertEqual(summary.lots.map(\.amount), [80.5, 120])
        XCTAssertEqual(summary.lots.first?.status, .warn)
    }

    func testDetectsTheStashFromTheAPIRoot() {
        XCTAssertTrue(StashCapability.listsStash(rootJSON: Data(
            #"{"feedings": "x", "stash-adjustments": "x", "stash": "x"}"#.utf8)))
        XCTAssertFalse(StashCapability.listsStash(rootJSON: Data(#"{"feedings": "x", "pumping": "x"}"#.utf8)))
        XCTAssertFalse(StashCapability.listsStash(rootJSON: Data("not json".utf8)))
    }

    func testStoringASummaryTurnsTheStashOnAndNilTurnsItOff() throws {
        let summary = try APICoders.decoder.decode(StashSummaryDTO.self, from: summaryJSON)
        StashCapability.store(summary: summary)
        XCTAssertTrue(StashCapability.isSupported)
        XCTAssertEqual(StashCapability.summary?.balance, 200.5)
        XCTAssertTrue(EntityKind.syncedKinds.contains(.stashAdjustment))

        StashCapability.store(summary: nil)
        XCTAssertFalse(StashCapability.isSupported)
        XCTAssertNil(StashCapability.summary)
        XCTAssertFalse(EntityKind.syncedKinds.contains(.stashAdjustment))
    }

    func testStatusFollowsTheClockBetweenSyncs() throws {
        let summary = try APICoders.decoder.decode(StashSummaryDTO.self, from: summaryJSON)
        let lot = try XCTUnwrap(summary.lots.first)
        XCTAssertEqual(lot.status(at: lot.warn_at.addingTimeInterval(-1)), .ok)
        XCTAssertEqual(lot.status(at: lot.warn_at), .warn)
        XCTAssertEqual(lot.status(at: lot.expires_at), .expired)

        XCTAssertEqual(summary.status(at: lot.expires_at), .expired)
        XCTAssertEqual(summary.expiredAmount(at: lot.expires_at), 80.5)
        XCTAssertEqual(summary.expiredAmount(at: lot.warn_at), 0)
        XCTAssertEqual(StashSummaryDTO(balance: -20, status: .ok, warn_age_hours: 48, max_age_hours: 72,
                                       expired_amount: 0, lots: []).status(at: .now), .ok)
    }

    func testDemoStashHasExpiredExpiringAndFreshMilk() {
        let now = Date()
        let summary = DemoData.demoStashSummary(now: now)
        XCTAssertEqual(summary.lots.map { $0.status(at: now) }, [.expired, .warn, .ok])
        XCTAssertEqual(summary.balance, summary.lots.reduce(0) { $0 + $1.amount })
        XCTAssertEqual(summary.expired_amount, summary.expiredAmount(at: now))
        XCTAssertEqual(summary.status, summary.status(at: now))
    }

    func testStashEntryNeedsAnAmountAboveZero() {
        var draft = ActivityDraft(kind: .stashAdjustment)
        XCTAssertEqual(draft.problem, .stashAmountRequired)
        draft.amount = "0"
        XCTAssertEqual(draft.problem, .stashAmountRequired)
        draft.amount = "lots"
        XCTAssertEqual(draft.problem, .notANumber)
        draft.amount = "90"
        XCTAssertNil(draft.problem)
        draft.time = draft.now.addingTimeInterval(3600)
        XCTAssertEqual(draft.problem, .futureTimestamp)
    }

    /// As the server checks it: breast milk or fortified breast milk, not at the breast, with an amount.
    func testWhichFeedsCanComeFromTheStash() {
        XCTAssertTrue(StashCapability.canComeFromStash(type: .breastMilk, method: .bottle, amount: 60))
        XCTAssertTrue(StashCapability.canComeFromStash(type: .fortifiedBreastMilk, method: .parentFed, amount: 60))
        XCTAssertTrue(StashCapability.canComeFromStash(type: .breastMilk, method: .selfFed, amount: 0.5))
        XCTAssertFalse(StashCapability.canComeFromStash(type: .formula, method: .bottle, amount: 60))
        XCTAssertFalse(StashCapability.canComeFromStash(type: .solidFood, method: .selfFed, amount: 60))
        XCTAssertFalse(StashCapability.canComeFromStash(type: .breastMilk, method: .leftBreast, amount: 60))
        XCTAssertFalse(StashCapability.canComeFromStash(type: .breastMilk, method: .bothBreasts, amount: 60))
        XCTAssertFalse(StashCapability.canComeFromStash(type: .breastMilk, method: .bottle, amount: nil))
        XCTAssertFalse(StashCapability.canComeFromStash(type: .breastMilk, method: .bottle, amount: 0))
    }

    func testStashEntriesStayOutOfTheTimeline() {
        XCTAssertFalse(EntityKind.timelineKinds.contains(.stashAdjustment))
    }
}

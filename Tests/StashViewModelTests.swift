import XCTest
import SwiftData
@testable import BabyBuddy

/// The stash screen shows the server's summary as the last sync cached it, and each child's milk
/// from the stash from the feedings synced to this phone.
@MainActor
final class StashViewModelTests: XCTestCase {
    override func setUp() async throws { StashCapability.reset() }
    override func tearDown() async throws { StashCapability.reset() }

    private func summary(balance: Double) -> StashSummaryDTO {
        StashSummaryDTO(balance: balance, status: .ok, warn_age_hours: 48, max_age_hours: 72,
                        oldest: nil, oldest_age_hours: nil, lots: [],
                        defaults: .init(pumping_to_stash: true, bottle_from_stash: true))
    }

    /// A bottle logged offline changes the stash only once the server says so: the model re-reads
    /// the cached summary after a sync, never before.
    func testSummaryRefreshedAfterSync() {
        StashCapability.update(rootJSON: Data(#"{"parents":"x","stash-adjustments":"x","stash":"x"}"#.utf8))
        StashCapability.store(summary: summary(balance: 315))
        let center = NotificationCenter()
        let model = StashViewModel(center: center)
        XCTAssertEqual(model.summary?.balance, 315)
        XCTAssertTrue(model.isSupported)

        StashCapability.store(summary: summary(balance: 295))
        XCTAssertEqual(model.summary?.balance, 315, "Not re-read until the sync finishes")

        center.post(name: .syncDidFinish, object: nil)
        XCTAssertEqual(model.summary?.balance, 295)
    }

    /// Moving to a server without the stash hides it after the next sync.
    func testCapabilityFollowsSync() {
        StashCapability.update(rootJSON: Data(#"{"parents":"x","stash-adjustments":"x","stash":"x"}"#.utf8))
        let center = NotificationCenter()
        let model = StashViewModel(center: center)
        XCTAssertTrue(model.isSupported)

        StashCapability.update(rootJSON: Data(#"{"children":"x"}"#.utf8))
        center.post(name: .syncDidFinish, object: nil)
        XCTAssertFalse(model.isSupported)
        XCTAssertNil(model.summary)
    }

    /// Each child's milk from the stash: today, and today plus the 6 days before. Formula, other
    /// children and deleted bottles don't count.
    func testPerChildStashUse() throws {
        let container = LocalStore.makeContainer(inMemory: true)
        let context = container.mainContext
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z")!
        var nextID = 1
        func bottle(_ start: String, stash: Double?, child: Int = 1, deleted: Bool = false) throws {
            let payload: [String: Any] = [
                "id": nextID, "child": child, "start": start, "end": start, "type": "breast milk",
                "method": "bottle", "amount": 90.0, "stash_amount": stash.map { $0 as Any } ?? NSNull(),
            ]
            nextID += 1
            let data = try JSONSerialization.data(withJSONObject: payload)
            let entity = LocalStore.upsertFromServer(data, kind: .feeding, in: context)!
            if deleted { entity.syncState = .pendingDelete }
        }
        try bottle("2026-06-15T08:00:00Z", stash: 60)
        try bottle("2026-06-15T10:00:00Z", stash: 40)
        try bottle("2026-06-15T11:00:00Z", stash: nil) // formula, or not from the stash
        try bottle("2026-06-12T08:00:00Z", stash: 50)
        try bottle("2026-06-09T08:00:00Z", stash: 30) // 6 days before today: in the week
        try bottle("2026-06-08T08:00:00Z", stash: 70) // 7 days before: out
        try bottle("2026-06-15T09:00:00Z", stash: 25, child: 2)
        try bottle("2026-06-15T09:30:00Z", stash: 15, deleted: true)

        let all = try context.fetch(FetchDescriptor<LocalEntity>())
        let totals = StashUse.totals(all, childID: 1, now: now, calendar: calendar)
        XCTAssertEqual(totals.today, 100, accuracy: 0.001)
        XCTAssertEqual(totals.week, 180, accuracy: 0.001)
        XCTAssertEqual(StashUse.totals(all, childID: 2, now: now, calendar: calendar),
                       StashUse.Totals(today: 25, week: 25))
    }
}

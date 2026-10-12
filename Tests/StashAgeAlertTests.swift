import XCTest
@testable import BabyBuddy

@MainActor
final class StashAgeAlertTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        SharedDefaults.suite.removeObject(forKey: StashAgePolicy.enabledKey)
        super.tearDown()
    }

    private func lot(hoursAgo: Double, amount: Double = 100) -> StashLotDTO {
        let time = now.addingTimeInterval(-hoursAgo * 3600)
        return StashLotDTO(time: time, amount: amount, warn_at: time.addingTimeInterval(48 * 3600),
                           expires_at: time.addingTimeInterval(72 * 3600), status: .ok)
    }

    private func summary(_ lots: [StashLotDTO]) -> StashSummaryDTO {
        StashSummaryDTO(balance: lots.reduce(0) { $0 + $1.amount }, status: .ok, warn_age_hours: 48,
                        max_age_hours: 72, expired_amount: 0, lots: lots)
    }

    func testEachLotWantsAnExpiringSoonAndAnExpiredAlert() throws {
        let fresh = lot(hoursAgo: 6)
        let requests = StashAgePolicy.requests(from: summary([fresh]))
        XCTAssertEqual(requests.map(\.id), ["stash-warn-\(Int(fresh.warn_at.timeIntervalSince1970))",
                                            "stash-expire-\(Int(fresh.expires_at.timeIntervalSince1970))"])
        XCTAssertEqual(requests.map(\.fireDate), [fresh.warn_at, fresh.expires_at])
        XCTAssertEqual(Set(requests.map(\.url)), ["babybuddy://stash"])
        XCTAssertFalse(requests.contains { $0.body.contains("ml") }, "No amount to go stale as milk is used")
    }

    func testMilkStoredAtTheSameMomentGetsOneAlert() {
        let requests = StashAgePolicy.requests(from: summary([lot(hoursAgo: 6, amount: 60), lot(hoursAgo: 6, amount: 40)]))
        XCTAssertEqual(requests.count, 2)
    }

    /// The regression this fixes: switched off, or signed out (no summary), the stash wants nothing,
    /// so its pending alerts are removed like any other kind's.
    func testOffOrSignedOutRemovesPendingStashAlerts() {
        SharedDefaults.suite.set(false, forKey: StashAgePolicy.enabledKey)
        XCTAssertFalse(StashAgePolicy.isEnabled)
        XCTAssertTrue(StashAgePolicy.requests(from: nil).isEmpty)

        let pending = ["stash-warn-1": now.addingTimeInterval(3600), "stash-expire-2": now.addingTimeInterval(7200),
                       "timer-x": now.addingTimeInterval(60)]
        let plan = ForgottenTimerPolicy.plan(wanted: [], pending: pending, delivered: [], now: now,
                                             prefix: "stash-", firesOverdue: false)
        XCTAssertEqual(plan.remove, ["stash-expire-2", "stash-warn-1"])
        XCTAssertTrue(plan.add.isEmpty)
    }

    /// Milk already past a time gets no alert for it, and a delivered one stays while the milk lasts.
    func testOverdueAlertsAreNotScheduledAndDeliveredOnesStay() {
        let expiring = lot(hoursAgo: 50)
        let requests = StashAgePolicy.requests(from: summary([expiring]))
        let plan = ForgottenTimerPolicy.plan(wanted: requests, pending: [:], delivered: [requests[0].id], now: now,
                                             prefix: "stash-", firesOverdue: false)
        XCTAssertEqual(plan.add.map(\.id), [requests[1].id], "Only the expiry, still ahead")
        XCTAssertTrue(plan.remove.isEmpty)
    }

    func testOnByDefaultOutsideUITests() {
        SharedDefaults.suite.removeObject(forKey: StashAgePolicy.enabledKey)
        XCTAssertEqual(StashAgePolicy.isEnabled, StashAgePolicy.defaultOn)
    }
}

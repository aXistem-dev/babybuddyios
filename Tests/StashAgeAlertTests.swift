import XCTest
@testable import BabyBuddy

/// The milk age alerts: one "use it first" and one "throw it away" per stash lot, planned through
/// the same diff as the other local alerts, so a used-up lot drops its alerts and a delivered one
/// isn't fired again.
final class StashAgeAlertTests: XCTestCase {
    let t0 = ISO8601DateFormatter().date(from: "2026-09-25T08:00:00Z")!
    var epoch: Int { Int(t0.timeIntervalSince1970) }

    override func setUp() {
        SharedDefaults.suite.removeObject(forKey: StashAgePolicy.enabledKey)
    }

    override func tearDown() {
        SharedDefaults.suite.removeObject(forKey: StashAgePolicy.enabledKey)
    }

    func summary(lots: [StashLotDTO]) -> StashSummaryDTO {
        .init(balance: lots.reduce(0) { $0 + $1.amount }, status: .ok, warn_age_hours: 48, max_age_hours: 72,
              oldest: lots.first?.time, oldest_age_hours: nil, lots: lots,
              defaults: .init(pumping_to_stash: true, bottle_from_stash: true))
    }

    func lot(_ time: Date, _ amount: Double) -> StashLotDTO {
        .init(time: time, amount: amount, age_hours: 0, warn_at: time.addingTimeInterval(48 * 3600),
              expires_at: time.addingTimeInterval(72 * 3600), status: .ok)
    }

    func testTwoRequestsPerLot() {
        let r = StashAgePolicy.requests(from: summary(lots: [lot(t0, 90)]), now: t0)
        XCTAssertEqual(r.map(\.id).sorted(), ["stash-expire-\(epoch)", "stash-warn-\(epoch)"])
        XCTAssertEqual(r.first { $0.id.hasPrefix("stash-warn") }?.fireDate, t0.addingTimeInterval(48 * 3600))
        XCTAssertEqual(r.first { $0.id.hasPrefix("stash-expire") }?.fireDate, t0.addingTimeInterval(72 * 3600))
    }

    func testTextAndDeepLink() {
        let r = StashAgePolicy.requests(from: summary(lots: [lot(t0, 90)]), now: t0)
        let warn = r.first { $0.id.hasPrefix("stash-warn") }
        let expire = r.first { $0.id.hasPrefix("stash-expire") }
        XCTAssertEqual(warn?.title, "Milk is getting old")
        XCTAssertEqual(expire?.title, "Throw this milk away")
        XCTAssertTrue(warn?.body.hasPrefix("90 ml pumped ") == true, warn?.body ?? "")
        XCTAssertTrue(warn?.body.hasSuffix(" is 48 h old: use it first.") == true, warn?.body ?? "")
        XCTAssertTrue(expire?.body.hasPrefix("90 ml pumped ") == true, expire?.body ?? "")
        XCTAssertTrue(expire?.body.hasSuffix(" is past 72 h.") == true, expire?.body ?? "")
        XCTAssertEqual(Set(r.map(\.url)), ["babybuddy://stash"])
    }

    /// A lot past its warn age but not expired still gets its "use it first", at its (past) time:
    /// the overdue lane fires it once.
    func testWarnPastButNotExpiredStillWanted() {
        let now = t0.addingTimeInterval(50 * 3600)
        let r = StashAgePolicy.requests(from: summary(lots: [lot(t0, 90)]), now: now)
        XCTAssertEqual(r.count, 2)
        let plan = ForgottenTimerPolicy.plan(wanted: r, pending: [:], delivered: [], now: now,
                                             prefix: "stash-", firesOverdue: true)
        XCTAssertEqual(plan.add.map(\.id).sorted(), ["stash-expire-\(epoch)", "stash-warn-\(epoch)"])
    }

    /// An expired lot only needs throwing away: no "use it first" next to it.
    func testExpiredLotOnlyGetsThrowAway() {
        let now = t0.addingTimeInterval(80 * 3600)
        let r = StashAgePolicy.requests(from: summary(lots: [lot(t0, 90)]), now: now)
        XCTAssertEqual(r.map(\.id), ["stash-expire-\(epoch)"])
    }

    func testLotUsedUpRemovesPending() {
        let id = "stash-warn-\(epoch)"
        let plan = ForgottenTimerPolicy.plan(wanted: StashAgePolicy.requests(from: summary(lots: []), now: t0),
                                             pending: [id: t0], delivered: [], now: t0,
                                             prefix: "stash-", firesOverdue: true)
        XCTAssertEqual(plan.remove, [id])
        XCTAssertTrue(plan.add.isEmpty)
    }

    func testDeliveredNotReAdded() {
        let wanted = StashAgePolicy.requests(from: summary(lots: [lot(t0, 90)]), now: t0)
        let plan = ForgottenTimerPolicy.plan(wanted: wanted, pending: [:], delivered: Set(wanted.map(\.id)),
                                             now: t0, prefix: "stash-", firesOverdue: true)
        XCTAssertTrue(plan.add.isEmpty)
    }

    /// Cleared from Notification Center, a delivered alert is neither pending nor delivered any
    /// more; an overdue one that was scheduled before isn't fired again on the next foreground.
    func testClearedOverdueAlertNotRefired() {
        let now = t0.addingTimeInterval(80 * 3600)
        let wanted = StashAgePolicy.requests(from: summary(lots: [lot(t0, 90)]), now: now)
        let plan = ForgottenTimerPolicy.plan(wanted: wanted, pending: [:], delivered: [], now: now,
                                             prefix: "stash-", firesOverdue: true)
        XCTAssertEqual(plan.add.count, 1, "Overdue, never scheduled: fires once")
        XCTAssertEqual(StashAgePolicy.firstTimeOnly(plan.add, scheduled: [], now: now).count, 1)
        XCTAssertTrue(StashAgePolicy.firstTimeOnly(plan.add, scheduled: ["stash-expire-\(epoch)"], now: now).isEmpty)
    }

    /// A future alert whose schedule was lost is scheduled again, even if it was once before.
    func testFutureAlertRescheduledEvenIfSeenBefore() {
        let wanted = StashAgePolicy.requests(from: summary(lots: [lot(t0, 90)]), now: t0)
        let again = StashAgePolicy.firstTimeOnly(wanted, scheduled: Set(wanted.map(\.id)), now: t0)
        XCTAssertEqual(again.count, 2)
    }

    func testDisabledOrNoSummaryIsEmpty() {
        XCTAssertTrue(StashAgePolicy.requests(from: nil, now: t0).isEmpty)
    }

    /// On unless switched off.
    func testEnabledByDefault() {
        XCTAssertTrue(StashAgePolicy.isEnabled)
        SharedDefaults.suite.set(false, forKey: StashAgePolicy.enabledKey)
        XCTAssertFalse(StashAgePolicy.isEnabled)
    }

    @MainActor
    func testSettingsSubtitleFollowsTheServer() {
        XCTAssertEqual(SettingsView.stashAlertsSubtitle(summary(lots: [])),
                       "Use first after 48 h, throw away after 72 h (set on the server)")
        XCTAssertNil(SettingsView.stashAlertsSubtitle(nil))
    }
}

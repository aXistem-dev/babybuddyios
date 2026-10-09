import XCTest
@testable import BabyBuddy

/// The stash screen's below-zero warning: shown while the balance is below zero, hidden for the
/// dip it was dismissed for, and back for the next dip once the balance has recovered.
final class StashNegativeWarningTests: XCTestCase {
    override func setUp() { SharedDefaults.suite.removeObject(forKey: StashNegativeWarning.dismissedKey) }
    override func tearDown() { SharedDefaults.suite.removeObject(forKey: StashNegativeWarning.dismissedKey) }

    private func summary(balance: Double, negativeSince: Date? = nil) -> StashSummaryDTO {
        StashSummaryDTO(balance: balance, status: .ok, warn_age_hours: 48, max_age_hours: 72,
                        oldest: nil, oldest_age_hours: nil, lots: [],
                        defaults: .init(pumping_to_stash: true, bottle_from_stash: true),
                        negative_since: negativeSince)
    }

    func testShowsOnlyBelowZero() {
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(StashNegativeWarning.shows(summary: summary(balance: -20, negativeSince: since), dismissedToken: nil))
        XCTAssertFalse(StashNegativeWarning.shows(summary: summary(balance: 0), dismissedToken: nil))
        XCTAssertFalse(StashNegativeWarning.shows(summary: summary(balance: 120), dismissedToken: nil))
        XCTAssertFalse(StashNegativeWarning.shows(summary: nil, dismissedToken: nil), "No summary yet")
    }

    func testDismissedForThisDipOnly() {
        let first = summary(balance: -20, negativeSince: Date(timeIntervalSince1970: 1_800_000_000))
        let token = StashNegativeWarning.token(for: first)
        XCTAssertFalse(StashNegativeWarning.shows(summary: first, dismissedToken: token))

        let deeper = summary(balance: -50, negativeSince: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(StashNegativeWarning.shows(summary: deeper, dismissedToken: token), "Same dip")

        let next = summary(balance: -10, negativeSince: Date(timeIntervalSince1970: 1_800_090_000))
        XCTAssertTrue(StashNegativeWarning.shows(summary: next, dismissedToken: token), "A new dip")
    }

    func testServerWithoutNegativeSinceStillDismisses() {
        let old = summary(balance: -20)
        XCTAssertEqual(StashNegativeWarning.token(for: old), "negative")
        XCTAssertFalse(StashNegativeWarning.shows(summary: old, dismissedToken: "negative"))
    }

    /// A summary at or above zero forgets the dismissal, so the next dip shows the warning again.
    func testRecoveryForgetsTheDismissal() {
        SharedDefaults.suite.set("1800000000", forKey: StashNegativeWarning.dismissedKey)
        StashCapability.store(summary: summary(balance: -5, negativeSince: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertEqual(SharedDefaults.suite.string(forKey: StashNegativeWarning.dismissedKey), "1800000000")

        StashCapability.store(summary: summary(balance: 0))
        XCTAssertNil(SharedDefaults.suite.string(forKey: StashNegativeWarning.dismissedKey))
        StashCapability.store(summary: nil)
    }

    func testSummaryDecodesNegativeSince() throws {
        let json = #"{"balance": -30.0, "negative_since": "2026-09-30T06:33:56Z", "status": "ok", "warn_age_hours": 48, "max_age_hours": 72, "oldest": null, "oldest_age_hours": null, "lots": [], "defaults": {"pumping_to_stash": true, "bottle_from_stash": true}}"#
        let s = try APICoders.decoder.decode(StashSummaryDTO.self, from: Data(json.utf8))
        XCTAssertNotNil(s.negative_since)
        let older = #"{"balance": 10.0, "status": "ok", "warn_age_hours": 48, "max_age_hours": 72, "oldest": null, "oldest_age_hours": null, "lots": [], "defaults": {"pumping_to_stash": true, "bottle_from_stash": true}}"#
        XCTAssertNil(try APICoders.decoder.decode(StashSummaryDTO.self, from: Data(older.utf8)).negative_since)
    }
}

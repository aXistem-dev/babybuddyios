import XCTest
@testable import BabyBuddy

/// The stash screen's below-zero warning: shown while the balance is below zero until dismissed,
/// and back when Settings turns it on again. The dismissal lives in the App Group's defaults.
final class StashNegativeWarningTests: XCTestCase {
    override func setUp() { StashNegativeWarning.isDismissed = false }
    override func tearDown() { StashNegativeWarning.isDismissed = false }

    func testShowsBelowZeroUntilDismissed() {
        XCTAssertTrue(StashNegativeWarning.shows(balance: -20))
        XCTAssertFalse(StashNegativeWarning.shows(balance: 0))
        XCTAssertFalse(StashNegativeWarning.shows(balance: 120))
        XCTAssertFalse(StashNegativeWarning.shows(balance: nil), "No summary yet")

        StashNegativeWarning.isDismissed = true // "Dismiss"
        XCTAssertFalse(StashNegativeWarning.shows(balance: -20))
        XCTAssertTrue(SharedDefaults.suite.bool(forKey: StashNegativeWarning.dismissedKey))

        StashNegativeWarning.isDismissed = false // Settings ▸ Below-zero stash warning
        XCTAssertTrue(StashNegativeWarning.shows(balance: -20))
    }

    func testPureRule() {
        XCTAssertTrue(StashNegativeWarning.shows(balance: -0.5, dismissed: false))
        XCTAssertFalse(StashNegativeWarning.shows(balance: -0.5, dismissed: true))
    }
}

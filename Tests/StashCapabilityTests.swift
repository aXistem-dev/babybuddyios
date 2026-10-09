import XCTest
@testable import BabyBuddy

/// Whether the server has the milk stash comes from its API root, and the stash summary it
/// returns is cached across launches (and for the widgets) in the App Group's defaults.
final class StashCapabilityTests: XCTestCase {
    override func setUp() { StashCapability.reset() }
    override func tearDown() { StashCapability.reset() }

    func testCapabilityOnWithRootKeys() {
        StashCapability.update(rootJSON: #"{"children":"x","parents":"x","stash-adjustments":"x","stash":"x"}"#.data(using: .utf8)!)
        XCTAssertTrue(StashCapability.isSupported)
    }

    func testCapabilityOffWithoutRootKeys() {
        StashCapability.update(rootJSON: #"{"children":"x","pumping":"x"}"#.data(using: .utf8)!)
        XCTAssertFalse(StashCapability.isSupported)
        XCTAssertNil(StashCapability.summary)
    }

    /// Moving to a server without the stash drops the summary cached from one that had it.
    func testCapabilityOffClearsCachedSummary() {
        StashCapability.update(rootJSON: #"{"parents":"x","stash-adjustments":"x","stash":"x"}"#.data(using: .utf8)!)
        StashCapability.store(summary: StashSummaryDTO(
            balance: 50, status: .ok, warn_age_hours: 48, max_age_hours: 72,
            oldest: nil, oldest_age_hours: nil, lots: [],
            defaults: .init(pumping_to_stash: true, bottle_from_stash: true)))
        XCTAssertNotNil(StashCapability.summary)

        StashCapability.update(rootJSON: #"{"children":"x"}"#.data(using: .utf8)!)
        XCTAssertFalse(StashCapability.isSupported)
        XCTAssertNil(StashCapability.summary)
    }

    /// Only a server listing all three stash routes counts.
    func testPartialRootKeysAreNotSupported() {
        StashCapability.update(rootJSON: #"{"parents":"x","stash":"x"}"#.data(using: .utf8)!)
        XCTAssertFalse(StashCapability.isSupported)
    }

    func testSummaryRoundTrips() throws {
        let s = StashSummaryDTO(balance: 50, status: .ok, warn_age_hours: 48, max_age_hours: 72,
                                oldest: nil, oldest_age_hours: nil, lots: [],
                                defaults: .init(pumping_to_stash: true, bottle_from_stash: true))
        StashCapability.store(summary: s)
        XCTAssertEqual(StashCapability.summary, s)

        StashCapability.store(summary: nil)
        XCTAssertNil(StashCapability.summary)
    }

    /// Lots survive the cache with their throw-away fields. Whole-second dates, since the API
    /// encoder writes no fractional seconds.
    func testSummaryWithLotsRoundTrips() throws {
        let time = Date(timeIntervalSince1970: 1_790_000_000)
        let lot = StashLotDTO(time: time, amount: 60, throw_away_amount: 59.996, age_hours: 80,
                              warn_at: time.addingTimeInterval(48 * 3600),
                              expires_at: time.addingTimeInterval(72 * 3600),
                              status: .expired, is_oldest_expired: true)
        let s = StashSummaryDTO(balance: 60, status: .expired, warn_age_hours: 48, max_age_hours: 72,
                                oldest: time, oldest_age_hours: 80, lots: [lot],
                                defaults: .init(pumping_to_stash: true, bottle_from_stash: false))
        StashCapability.store(summary: s)
        XCTAssertEqual(StashCapability.summary, s)
    }

    /// A sync compares the cached summary, whose dates the cache keeps in whole seconds, with the
    /// server's, which can carry microseconds and fresh age readings. The same stash is no change;
    /// a different amount is.
    func testSameSummaryWithFractionalSecondsIsNotAChange() {
        func summary(time: Date, amount: Double, age: Double) -> StashSummaryDTO {
            let lot = StashLotDTO(time: time, amount: amount, throw_away_amount: amount, age_hours: age,
                                  warn_at: time.addingTimeInterval(48 * 3600),
                                  expires_at: time.addingTimeInterval(72 * 3600),
                                  status: .warn, is_oldest_expired: false)
            return StashSummaryDTO(balance: amount, status: .warn, warn_age_hours: 48, max_age_hours: 72,
                                   oldest: time, oldest_age_hours: age, lots: [lot],
                                   defaults: .init(pumping_to_stash: true, bottle_from_stash: true))
        }
        let time = Date(timeIntervalSince1970: 1_790_000_000.654321)
        let fresh = summary(time: time, amount: 60, age: 50.25)
        StashCapability.store(summary: fresh)
        let cached = StashCapability.summary
        XCTAssertNotNil(cached)

        XCTAssertFalse(SyncActor.stashSummaryChanged(from: cached, to: fresh))
        XCTAssertFalse(SyncActor.stashSummaryChanged(from: cached, to: summary(time: time, amount: 60, age: 50.5)),
                       "Only the age moved")
        XCTAssertTrue(SyncActor.stashSummaryChanged(from: cached, to: summary(time: time, amount: 45, age: 50.25)))
        XCTAssertTrue(SyncActor.stashSummaryChanged(from: nil, to: fresh))
        XCTAssertFalse(SyncActor.stashSummaryChanged(from: nil, to: nil))
    }
}

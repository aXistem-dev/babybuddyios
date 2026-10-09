import XCTest
@testable import BabyBuddy

/// Throwing expired milk away never takes more than is left, only the oldest expired lot can go on
/// its own, and "Throw away all expired milk" takes every expired lot.
final class StashThrowAwayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func lot(_ amount: Double, _ status: StashStatus, hoursAgo: Double, throwAway: Double? = nil,
                     oldestExpired: Bool? = nil, parent: Int? = nil) -> StashLotDTO {
        let time = now.addingTimeInterval(-hoursAgo * 3600)
        return StashLotDTO(time: time, amount: amount, throw_away_amount: throwAway, age_hours: hoursAgo,
                           warn_at: time.addingTimeInterval(48 * 3600),
                           expires_at: time.addingTimeInterval(72 * 3600),
                           status: status, is_oldest_expired: oldestExpired, parent: parent)
    }

    /// "Throw away" on a lot discards its unrounded amount, rounded down, from the lot's parent, and
    /// pins it; "Throw away all expired milk" pins no parent at all.
    func testThrowAwayPresets() {
        let one = StashEntryPreset.throwAway(lot: lot(20, .expired, hoursAgo: 90, throwAway: 19.996, parent: 3),
                                             maxAgeHours: 72)
        XCTAssertEqual(one.kind, .discarded)
        XCTAssertEqual(one.amount ?? 0, 19.99, accuracy: 1e-9)
        XCTAssertEqual(one.reason, "Older than 72 h")
        XCTAssertEqual(one.parent, 3)
        XCTAssertTrue(one.pinsParent)

        let nobodys = StashEntryPreset.throwAway(lot: lot(20, .expired, hoursAgo: 90), maxAgeHours: 72)
        XCTAssertNil(nobodys.parent)
        XCTAssertEqual(nobodys.amount ?? 0, 20, accuracy: 1e-9)

        let all = StashEntryPreset.throwAway(30.5, maxAgeHours: 72)
        XCTAssertNil(all.parent)
        XCTAssertTrue(all.pinsParent)
        XCTAssertFalse(StashEntryPreset(kind: .discarded).pinsParent, "Discard milk picks as usual")
    }

    private func summary(_ lots: [StashLotDTO]) -> StashSummaryDTO {
        StashSummaryDTO(balance: lots.reduce(0) { $0 + $1.amount }, status: .expired,
                        warn_age_hours: 48, max_age_hours: 72, oldest: lots.first?.time,
                        oldest_age_hours: lots.first?.age_hours, lots: lots,
                        defaults: .init(pumping_to_stash: true, bottle_from_stash: true))
    }

    func testThrowAwayAmountRoundsDown() {
        XCTAssertEqual(StashThrowAway.amount(59.999), 59.99, accuracy: 1e-9)
        XCTAssertEqual(StashThrowAway.amount(60.0000001), 60.0, accuracy: 1e-9)
        XCTAssertEqual(StashThrowAway.amount(12.345), 12.34, accuracy: 1e-9)
        // Already on 2 decimals: unchanged, not a cent less.
        XCTAssertEqual(StashThrowAway.amount(59.99), 59.99, accuracy: 1e-9)
    }

    func testOnlyOldestExpiredOffersThrowAway() {
        let first = lot(60, .expired, hoursAgo: 90, oldestExpired: true)
        let second = lot(30.5, .expired, hoursAgo: 80, oldestExpired: false)
        let fresh = lot(40, .warn, hoursAgo: 50, oldestExpired: false)
        XCTAssertEqual(StashThrowAway.lotOffers(summary([first, second, fresh])), first)

        // A summary cached before the server flagged lots: the first expired lot.
        let unflagged = [lot(60, .expired, hoursAgo: 90), lot(30.5, .expired, hoursAgo: 80),
                         lot(40, .warn, hoursAgo: 50)]
        XCTAssertEqual(StashThrowAway.lotOffers(summary(unflagged)), unflagged[0])

        // Nothing expired: nothing to throw away.
        XCTAssertNil(StashThrowAway.lotOffers(summary([lot(40, .warn, hoursAgo: 50, oldestExpired: false)])))
        XCTAssertNil(StashThrowAway.lotOffers(summary([lot(40, .ok, hoursAgo: 5)])))
    }

    func testThrowAwayAllSumsExpired() {
        let lots = [lot(60, .expired, hoursAgo: 90, oldestExpired: true),
                    lot(30.5, .expired, hoursAgo: 80, oldestExpired: false),
                    lot(40, .warn, hoursAgo: 50, oldestExpired: false)]
        XCTAssertEqual(StashThrowAway.allExpiredAmount(summary(lots)), 90.5, accuracy: 1e-9)

        // The unrounded amounts are summed, then rounded down once.
        let exact = [lot(20, .expired, hoursAgo: 90, throwAway: 19.996, oldestExpired: true),
                     lot(10, .expired, hoursAgo: 80, throwAway: 10.003, oldestExpired: false)]
        XCTAssertEqual(StashThrowAway.allExpiredAmount(summary(exact)), 29.99, accuracy: 1e-9)
    }

    func testReasonText() {
        XCTAssertEqual(StashThrowAway.reason(maxAgeHours: 72), "Older than 72 h")
    }

    /// The throw-away buttons open a discard pre-filled with the rounded-down amount and the reason.
    func testThrowAwayPreset() {
        let preset = StashEntryPreset.throwAway(59.999, maxAgeHours: 72)
        XCTAssertEqual(preset.kind, .discarded)
        XCTAssertEqual(preset.amount ?? -1, 59.99, accuracy: 1e-9)
        XCTAssertEqual(preset.reason, "Older than 72 h")
    }
}

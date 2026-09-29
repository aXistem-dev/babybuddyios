import XCTest
@testable import BabyBuddy

/// The parent and stash-adjustment kinds, and the milk stash DTOs decoding the server's JSON.
final class EntityKindStashTests: XCTestCase {
    func testPathsAndWindowing() {
        XCTAssertEqual(EntityKind.parent.path, "parents")
        XCTAssertEqual(EntityKind.stashAdjustment.path, "stash-adjustments")
        XCTAssertFalse(EntityKind.parent.isWindowed)
        XCTAssertFalse(EntityKind.stashAdjustment.isWindowed)
        XCTAssertEqual(EntityKind.stashAdjustment.timeField, "time")
        XCTAssertFalse(EntityKind.timelineKinds.contains(.parent))
        XCTAssertTrue(EntityKind.timelineKinds.contains(.stashAdjustment))
    }

    /// A parent has no time field of its own: its timestamp falls back to `.distantPast`, and it
    /// belongs to no child.
    func testParentHasNoTimestampOrChild() {
        let payload: [String: Any] = ["id": 1, "first_name": "Robin", "last_name": "", "children": [1, 2]]
        XCTAssertEqual(EntityKind.parent.timestamp(from: payload), .distantPast)
        XCTAssertNil(EntityKind.parent.childID(from: payload))
        XCTAssertEqual(EntityKind.parent.imageField, "picture")
    }

    func testKindSigns() {
        XCTAssertEqual(StashKind.added.sign, 1)
        XCTAssertEqual(StashKind.discarded.sign, -1)
    }

    func testSummaryDecodes() throws {
        let json = """
        {"balance": 120.0, "status": "warn", "warn_age_hours": 48, "max_age_hours": 72,
         "oldest": "2026-09-25T08:00:00+02:00", "oldest_age_hours": 50.0,
         "lots": [{"time": "2026-09-25T08:00:00+02:00", "amount": 120.0,
                   "throw_away_amount": 119.996, "age_hours": 50.0,
                   "warn_at": "2026-09-27T08:00:00+02:00", "expires_at": "2026-09-28T08:00:00+02:00",
                   "status": "warn", "is_oldest_expired": false}],
         "defaults": {"pumping_to_stash": true, "bottle_from_stash": false}}
        """.data(using: .utf8)!
        let s = try APICoders.decoder.decode(StashSummaryDTO.self, from: json)
        XCTAssertEqual(s.lots.first?.status, .warn)
        XCTAssertEqual(s.lots.first?.throw_away_amount, 119.996)
        XCTAssertEqual(s.lots.first?.is_oldest_expired, false)
        XCTAssertEqual(s.warn_age_hours, 48)
        XCTAssertEqual(s.oldest, APIDate.parse("2026-09-25T08:00:00+02:00"))
        XCTAssertTrue(s.defaults.pumping_to_stash)
        XCTAssertFalse(s.defaults.bottle_from_stash)
    }

    /// A summary cached before the server sent `throw_away_amount` / `is_oldest_expired` still
    /// decodes, and an empty stash has no `oldest`.
    func testSummaryDecodesWithoutNewerLotFields() throws {
        let json = """
        {"balance": 0, "status": "ok", "warn_age_hours": 48, "max_age_hours": 72,
         "oldest": null, "oldest_age_hours": null, "lots": [],
         "defaults": {"pumping_to_stash": false, "bottle_from_stash": true}}
        """.data(using: .utf8)!
        let s = try APICoders.decoder.decode(StashSummaryDTO.self, from: json)
        XCTAssertNil(s.oldest)
        XCTAssertTrue(s.lots.isEmpty)

        let lot = """
        {"time": "2026-09-25T08:00:00+02:00", "amount": 60.0, "age_hours": 80.0,
         "warn_at": "2026-09-27T08:00:00+02:00", "expires_at": "2026-09-28T08:00:00+02:00",
         "status": "expired"}
        """.data(using: .utf8)!
        let decoded = try APICoders.decoder.decode(StashLotDTO.self, from: lot)
        XCTAssertEqual(decoded.status, .expired)
        XCTAssertNil(decoded.throw_away_amount)
        XCTAssertNil(decoded.is_oldest_expired)
    }

    func testAdjustmentDecodesFreeTextReason() throws {
        let spilled = """
        {"id": 3, "time": "2026-09-25T08:00:00+02:00", "amount": 20.0, "kind": "discarded",
         "reason": "Spilled", "signed_amount": -20.0, "parent": 1, "feeding": 12,
         "notes": "", "tags": []}
        """.data(using: .utf8)!
        let a = try APICoders.decoder.decode(StashAdjustmentDTO.self, from: spilled)
        XCTAssertEqual(a.kind, .discarded)
        XCTAssertEqual(a.reason, "Spilled")
        XCTAssertEqual(a.signed_amount, -20)
        XCTAssertEqual(a.feeding, 12)

        let noReason = """
        {"id": 4, "time": "2026-09-25T09:00:00+02:00", "amount": 15.5, "kind": "discarded",
         "reason": "", "signed_amount": -15.5, "parent": null, "feeding": null,
         "notes": "", "tags": []}
        """.data(using: .utf8)!
        let b = try APICoders.decoder.decode(StashAdjustmentDTO.self, from: noReason)
        XCTAssertEqual(b.kind, .discarded)
        XCTAssertEqual(b.reason, "")
        XCTAssertNil(b.parent)
        XCTAssertNil(b.feeding)
    }

    /// Pumping logged on a parent has `child: null`; a bottle carries its stash fields.
    func testPumpingAndFeedingStashFieldsDecode() throws {
        let pumping = """
        {"id": 5, "child": null, "parent": 1, "amount": 120.0, "stash_amount": 100.0,
         "start": "2026-09-25T07:40:00+02:00", "end": "2026-09-25T08:00:00+02:00",
         "duration": "00:20:00", "notes": "", "tags": [], "timer": null}
        """.data(using: .utf8)!
        let p = try APICoders.decoder.decode(PumpingDTO.self, from: pumping)
        XCTAssertNil(p.child)
        XCTAssertEqual(p.parent, 1)
        XCTAssertEqual(p.stash_amount, 100)

        let feeding = """
        {"id": 6, "child": 1, "parent": null, "start": "2026-09-25T10:00:00+02:00",
         "end": "2026-09-25T10:15:00+02:00", "timer": null, "duration": "00:15:00",
         "type": "breast milk", "method": "bottle", "amount": 90.0, "stash_amount": 90.0,
         "stash_discarded": 10.0, "stash_discard_reason": "Left over", "notes": "", "tags": []}
        """.data(using: .utf8)!
        let f = try APICoders.decoder.decode(FeedingDTO.self, from: feeding)
        XCTAssertEqual(f.stash_amount, 90)
        XCTAssertEqual(f.stash_discarded, 10)
        XCTAssertEqual(f.stash_discard_reason, "Left over")
        XCTAssertNil(f.parent)
    }

    func testParentDecodes() throws {
        let json = """
        {"id": 1, "first_name": "Robin", "last_name": "", "slug": "robin",
         "picture": null, "children": [1, 2]}
        """.data(using: .utf8)!
        let parent = try APICoders.decoder.decode(ParentDTO.self, from: json)
        XCTAssertEqual(parent.first_name, "Robin")
        XCTAssertEqual(parent.children, [1, 2])
        XCTAssertNil(parent.picture)
    }
}

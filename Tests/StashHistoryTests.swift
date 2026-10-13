import XCTest
@testable import BabyBuddy

/// The stash screen's view of this phone's records: which record a lot came from.
@MainActor
final class StashHistoryTests: XCTestCase {
    private func entity(_ kind: EntityKind, id: Int?, _ payload: [String: Any] = [:],
                        state: SyncState = .synced) -> LocalEntity {
        LocalEntity(kind: kind, serverID: id, childID: payload["child"] as? Int,
                    timestamp: kind.timestamp(from: payload),
                    payload: try! JSONSerialization.data(withJSONObject: payload), syncState: state)
    }

    // MARK: Lot sources

    /// A lot names its source when the server has lot sources, and decodes without one when it doesn't.
    func testLotSourceIsOptional() throws {
        let lots = try APICoders.decoder.decode(StashSummaryDTO.self, from: Data("""
        {"balance": 230.0, "status": "warn", "warn_age_hours": 48, "max_age_hours": 72, "expired_amount": 0.0,
         "lots": [{"time": "2024-01-06T08:30:00-05:00", "amount": 110.0, "warn_at": "2024-01-08T08:30:00-05:00",
                   "expires_at": "2024-01-09T08:30:00-05:00", "status": "warn", "source": {"type": "pumping", "id": 42}},
                  {"time": "2024-01-07T19:00:00-05:00", "amount": 120.0, "warn_at": "2024-01-09T19:00:00-05:00",
                   "expires_at": "2024-01-10T19:00:00-05:00", "status": "ok"}]}
        """.utf8)).lots
        XCTAssertEqual(lots[0].source, StashLotSourceDTO(type: "pumping", id: 42))
        XCTAssertNil(lots[1].source)
    }

    /// A lot opens the cached pumping or manual add it came from, by the server's id; nothing for a
    /// record this phone doesn't have, one being deleted, a source of another type, or no source.
    func testRecordForSource() {
        let pumping = entity(.pumping, id: 42, ["child": 1])
        let added = entity(.stashAdjustment, id: 7, ["kind": "added"])
        let feeding = entity(.feeding, id: 9, ["child": 1])
        let gone = entity(.pumping, id: 43, ["child": 1], state: .pendingDelete)
        let all = [pumping, added, feeding, gone]
        XCTAssertIdentical(StashHistory.record(for: .init(type: "pumping", id: 42), in: all), pumping)
        XCTAssertIdentical(StashHistory.record(for: .init(type: "stash_adjustment", id: 7), in: all), added)
        XCTAssertNil(StashHistory.record(for: .init(type: "pumping", id: 7), in: all), "Ids are per kind")
        XCTAssertNil(StashHistory.record(for: .init(type: "pumping", id: 43), in: all))
        XCTAssertNil(StashHistory.record(for: .init(type: "feeding", id: 9), in: all))
        XCTAssertNil(StashHistory.record(for: .init(type: "pumping", id: 99), in: all), "Outside the window")
        XCTAssertNil(StashHistory.record(for: nil, in: all))
    }
}

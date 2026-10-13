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

    // MARK: History

    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func iso(_ minutesAgo: Double) -> String {
        APIDate.isoDateTime.string(from: now.addingTimeInterval(-minutesAgo * 60))
    }

    private func adjustment(_ kind: String, at minutesAgo: Double, amount: Double = 50,
                            state: SyncState = .synced) -> LocalEntity {
        entity(.stashAdjustment, id: nil, ["time": iso(minutesAgo), "amount": amount, "kind": kind], state: state)
    }

    /// Every kind of movement, signed in or out, at the time the server counts it: a pumping at its
    /// end, a bottle at its start. Feedings not from the stash or without an amount, pumpings not into
    /// it, and records being deleted aren't movements.
    func testMovements() {
        let pumping = entity(.pumping, id: 1, ["child": 1, "start": iso(130), "end": iso(120),
                                               "amount": 160.0, "to_stash": true])
        let bottle = entity(.feeding, id: 2, ["child": 1, "start": iso(60), "end": iso(50),
                                              "amount": 40.0, "from_stash": true])
        let records = [
            pumping, bottle, adjustment("added", at: 90, amount: 80), adjustment("discarded", at: 30, amount: 20),
            entity(.pumping, id: 3, ["child": 1, "start": iso(15), "end": iso(10), "amount": 90.0]),
            entity(.feeding, id: 4, ["child": 1, "start": iso(5), "end": iso(1), "from_stash": true]),
            entity(.feeding, id: 5, ["child": 1, "start": iso(5), "end": iso(1), "amount": 30.0]),
            adjustment("added", at: 3, state: .pendingDelete),
        ]
        let movements = StashHistory.movements(in: records)
        XCTAssertEqual(movements.map(\.kind), [.discarded, .bottle, .added, .pumping], "Newest first")
        XCTAssertEqual(movements.map(\.signedAmount), ["\u{2212}20 ml", "\u{2212}40 ml", "+80 ml", "+160 ml"])
        XCTAssertEqual(movements.last?.time, now.addingTimeInterval(-120 * 60), "A pumping counts at its end")
        XCTAssertEqual(movements[1].time, now.addingTimeInterval(-60 * 60), "A bottle counts at its start")
        XCTAssertIdentical(movements[1].record, bottle)
        XCTAssertEqual(movements.map(\.isDeletableHere), [true, false, true, false],
                       "Only milk added or discarded by hand")
    }

    /// At the same time, milk in counts before milk out, so newest first the out comes first; and
    /// only the newest ten are listed.
    func testTieOrderAndLimit() {
        let tie = [adjustment("added", at: 10), adjustment("discarded", at: 10)]
        XCTAssertEqual(StashHistory.movements(in: tie).map(\.kind), [.discarded, .added])
        XCTAssertEqual(StashHistory.movements(in: tie.reversed()).map(\.kind), [.discarded, .added])

        let many = (1...12).map { adjustment("added", at: Double($0)) }
        let listed = StashHistory.movements(in: many)
        XCTAssertEqual(listed.count, 10)
        XCTAssertEqual(listed.first?.time, now.addingTimeInterval(-60))
        XCTAssertEqual(StashHistory.movements(in: many, limit: 3).count, 3)
    }
}

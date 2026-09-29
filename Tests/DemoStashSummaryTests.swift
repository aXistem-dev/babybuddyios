import XCTest
import SwiftData
@testable import BabyBuddy

#if DEBUG
/// Demo mode has no server, so it computes the stash summary itself. It has to agree with the
/// server's FIFO, or the stash screens and milk age alerts would be exercised against numbers no
/// real server returns.
@MainActor
final class DemoStashSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func tearDown() async throws {
        StashCapability.reset()
    }

    private func iso(_ hoursAgo: Double) -> String {
        APIDate.isoDateTime.string(from: now.addingTimeInterval(-hoursAgo * 3600))
    }

    private func entity(_ kind: EntityKind, _ payload: [String: Any]) -> LocalEntity {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return LocalEntity(kind: kind, serverID: payload["id"] as? Int, childID: payload["child"] as? Int,
                           timestamp: kind.timestamp(from: payload), payload: data, syncState: .synced)
    }

    private func pumping(_ hoursAgo: Double, stash: Double) -> LocalEntity {
        entity(.pumping, ["child": NSNull(), "parent": 1, "start": iso(hoursAgo + 0.3), "end": iso(hoursAgo),
                          "amount": stash, "stash_amount": stash])
    }

    private func bottle(_ hoursAgo: Double, stash: Double) -> LocalEntity {
        entity(.feeding, ["child": 1, "start": iso(hoursAgo), "end": iso(hoursAgo - 0.25),
                          "type": "breast milk", "method": "bottle", "amount": stash, "stash_amount": stash])
    }

    private func adjustment(_ hoursAgo: Double, _ kind: StashKind, _ amount: Double) -> LocalEntity {
        entity(.stashAdjustment, ["time": iso(hoursAgo), "amount": amount, "kind": kind.rawValue,
                                  "reason": "", "signed_amount": kind.sign * amount])
    }

    /// Outflows use the oldest milk first, a linked discard included, and each lot gets its
    /// status from its age: 80 h expired, 50 h warn, younger ok.
    func testFIFOLotsAndStatuses() {
        let s = DemoData.demoStashSummary(entities: [
            pumping(80, stash: 240), bottle(70, stash: 90), adjustment(70, .discarded, 10),
            pumping(50, stash: 120), adjustment(30, .added, 60), pumping(20, stash: 100),
            bottle(10, stash: 60), adjustment(8, .discarded, 5), bottle(6, stash: 40),
        ], now: now)

        XCTAssertEqual(s.balance, 315)
        XCTAssertEqual(s.lots.map(\.amount), [35, 120, 60, 100])
        XCTAssertEqual(s.lots.map(\.status), [.expired, .warn, .ok, .ok])
        XCTAssertEqual(s.lots.map(\.age_hours), [80, 50, 30, 20])
        XCTAssertEqual(s.status, .expired)
        XCTAssertEqual(s.oldest, now.addingTimeInterval(-80 * 3600))
        XCTAssertEqual(s.oldest_age_hours, 80)
        XCTAssertEqual(s.lots.first?.expires_at, now.addingTimeInterval(-8 * 3600))
        XCTAssertEqual(s.lots.first?.warn_at, now.addingTimeInterval(-32 * 3600))
    }

    /// Milk can only be thrown away from the oldest expired lot on its own, so only that one is
    /// flagged.
    func testOnlyFirstExpiredLotIsOldestExpired() {
        let s = DemoData.demoStashSummary(entities: [pumping(90, stash: 50), pumping(80, stash: 40),
                                                     pumping(10, stash: 30)], now: now)
        XCTAssertEqual(s.lots.map(\.status), [.expired, .expired, .ok])
        XCTAssertEqual(s.lots.map(\.is_oldest_expired), [true, false, false])
    }

    /// `amount` is rounded to 2 decimals, `throw_away_amount` is the exact lot, and a sliver
    /// under 0.01 ml is no lot at all.
    func testRoundingAndSlivers() {
        let s = DemoData.demoStashSummary(entities: [pumping(30, stash: 100.004), bottle(20, stash: 100),
                                                     pumping(10, stash: 33.3333)], now: now)
        XCTAssertEqual(s.lots.count, 1)
        XCTAssertEqual(s.lots.first?.amount, 33.33)
        XCTAssertEqual(s.lots.first?.throw_away_amount, 33.3333)
    }

    /// Milk taken from an empty stash is a shortfall: the balance goes negative and the next
    /// inflow repays it before it forms a lot.
    func testShortfallIsRepaidFirst() {
        let short = DemoData.demoStashSummary(entities: [bottle(20, stash: 50)], now: now)
        XCTAssertEqual(short.balance, -50)
        XCTAssertTrue(short.lots.isEmpty)
        XCTAssertEqual(short.status, .ok)
        XCTAssertNil(short.oldest)

        let repaid = DemoData.demoStashSummary(entities: [bottle(20, stash: 50), pumping(10, stash: 80)], now: now)
        XCTAssertEqual(repaid.balance, 30)
        XCTAssertEqual(repaid.lots.map(\.amount), [30])
    }

    /// Not stash entries: a bottle or pumping without `stash_amount`.
    func testEntriesOutsideTheStashAreIgnored() {
        let s = DemoData.demoStashSummary(entities: [
            entity(.pumping, ["child": 1, "start": iso(3), "end": iso(2.7), "amount": 90]),
            entity(.feeding, ["child": 1, "start": iso(2), "end": iso(1.8), "type": "formula",
                              "method": "bottle", "amount": 90, "stash_amount": NSNull()]),
        ], now: now)
        XCTAssertEqual(s.balance, 0)
        XCTAssertTrue(s.lots.isEmpty)
    }

    /// The demo seed turns the stash on and leaves one lot to warn about and one expired, so both
    /// lot states and both milk age alerts can be seen in demo mode.
    func testDemoSeedShowsWarnAndExpiredLots() throws {
        let container = LocalStore.makeContainer(inMemory: true)
        DemoData.seedIfNeeded(into: container.mainContext)

        XCTAssertTrue(StashCapability.isSupported)
        let summary = try XCTUnwrap(StashCapability.summary)
        XCTAssertTrue(summary.lots.contains { $0.status == .warn })
        XCTAssertTrue(summary.lots.contains { $0.status == .expired })
        XCTAssertEqual(summary.lots.filter { $0.is_oldest_expired == true }.count, 1)
        XCTAssertGreaterThan(summary.balance, 0)
        XCTAssertNotNil(LocalStore.fetch(kind: .parent, serverID: 1, in: container.mainContext))
    }
}
#endif

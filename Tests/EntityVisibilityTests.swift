import XCTest
import SwiftData
@testable import BabyBuddy

/// Which records a child's views show: a parent's pumping (`child: null`) and stash adjustments
/// reach every child linked to that parent.
@MainActor
final class EntityVisibilityTests: XCTestCase {
    private func entity(_ kind: EntityKind, _ payload: [String: Any], serverID: Int? = nil) -> LocalEntity {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return LocalEntity(kind: kind, serverID: serverID, childID: kind.childID(from: payload),
                           timestamp: kind.timestamp(from: payload), payload: data, syncState: .synced)
    }

    func testParentPumpingVisibleForLinkedChildren() throws {
        let container = LocalStore.makeContainer(inMemory: true)
        let context = container.mainContext
        let repo = LocalRepository(context: context)
        _ = repo.create(kind: .parent, payload: ["id": 7, "first_name": "Robin", "children": [1, 2]])
        let pump = repo.create(kind: .pumping, payload: ["parent": 7, "child": NSNull(), "amount": 100,
                                                         "start": "2026-09-27T08:00:00Z", "end": "2026-09-27T08:20:00Z"])!
        let all = try context.fetch(FetchDescriptor<LocalEntity>())
        XCTAssertTrue(EntityVisibility.isVisible(pump, forChild: 1, parentIDs: EntityVisibility.parentIDs(forChild: 1, in: all)))
        XCTAssertFalse(EntityVisibility.isVisible(pump, forChild: 3, parentIDs: EntityVisibility.parentIDs(forChild: 3, in: all)))
    }

    /// A synced parent is found by its `serverID` when the payload carries no `id`.
    func testParentIDsFallBackToServerID() {
        let parent = entity(.parent, ["first_name": "Robin", "children": [1]], serverID: 4)
        let unlinked = entity(.parent, ["id": 5, "first_name": "Casey", "children": [2]], serverID: 5)
        XCTAssertEqual(EntityVisibility.parentIDs(forChild: 1, in: [parent, unlinked]), [4])
        XCTAssertEqual(EntityVisibility.parentIDs(forChild: 2, in: [parent, unlinked]), [5])
        XCTAssertEqual(EntityVisibility.parentIDs(forChild: 3, in: [parent, unlinked]), [])
    }

    /// Pumping logged on a child (as on a server without the milk stash) stays that child's own.
    func testChildPumpingOnlyForItsChild() {
        let pump = entity(.pumping, ["id": 1, "child": 1, "amount": 80, "start": "2026-09-27T08:00:00Z"])
        XCTAssertTrue(EntityVisibility.isVisible(pump, forChild: 1, parentIDs: []))
        XCTAssertFalse(EntityVisibility.isVisible(pump, forChild: 2, parentIDs: [7]))
    }

    func testParentPumpingHiddenWithoutLinkedParent() {
        let pump = entity(.pumping, ["id": 2, "child": NSNull(), "parent": 7, "start": "2026-09-27T08:00:00Z"])
        let orphan = entity(.pumping, ["id": 3, "child": NSNull(), "parent": NSNull(), "start": "2026-09-27T09:00:00Z"])
        XCTAssertFalse(EntityVisibility.isVisible(pump, forChild: 1, parentIDs: [8]))
        XCTAssertFalse(EntityVisibility.isVisible(orphan, forChild: 1, parentIDs: [7]))
    }

    /// The stash is shared: an adjustment with no parent shows for every child, one with a parent
    /// only for that parent's children.
    func testStashAdjustmentVisibility() {
        let shared = entity(.stashAdjustment, ["id": 10, "time": "2026-09-27T08:00:00Z", "amount": 60,
                                               "kind": "added", "reason": "Donor milk", "parent": NSNull()])
        let robins = entity(.stashAdjustment, ["id": 11, "time": "2026-09-27T09:00:00Z", "amount": 5,
                                               "kind": "discarded", "reason": "", "parent": 7])
        XCTAssertTrue(EntityVisibility.isVisible(shared, forChild: 1, parentIDs: []))
        XCTAssertTrue(EntityVisibility.isVisible(shared, forChild: 2, parentIDs: [7]))
        XCTAssertTrue(EntityVisibility.isVisible(robins, forChild: 1, parentIDs: [7]))
        XCTAssertFalse(EntityVisibility.isVisible(robins, forChild: 2, parentIDs: [8]))
    }

    func testParentNeverVisible() {
        let parent = entity(.parent, ["id": 7, "first_name": "Robin", "children": [1]], serverID: 7)
        XCTAssertFalse(EntityVisibility.isVisible(parent, forChild: 1, parentIDs: [7]))
    }

    /// Everything else keeps the plain child rule: another child's records and unassigned timers
    /// stay out.
    func testOtherKindsFollowTheirChild() {
        let feeding = entity(.feeding, ["id": 20, "child": 1, "start": "2026-09-27T08:00:00Z"])
        let timer = entity(.timer, ["id": 21, "child": NSNull(), "start": "2026-09-27T08:00:00Z"])
        XCTAssertTrue(EntityVisibility.isVisible(feeding, forChild: 1, parentIDs: [7]))
        XCTAssertFalse(EntityVisibility.isVisible(feeding, forChild: 2, parentIDs: [7]))
        XCTAssertFalse(EntityVisibility.isVisible(timer, forChild: 1, parentIDs: [7]))
    }
}

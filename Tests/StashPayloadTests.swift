import XCTest
@testable import BabyBuddy

/// What the pumping and feeding editors send. On a server with the milk stash, pumping is logged on
/// a parent with no `child` key, and a feeding carries its stash fields and who breastfed; without
/// it, upstream's payloads on the child with no stash keys.
@MainActor
final class StashPayloadTests: XCTestCase {
    func testPumpingPayloadCapableUsesParentAndStash() {
        let p = EntityEditorView.pumpingPayload(base: ["child": 1, "amount": 120.0], parentID: 7,
                                                toStash: true, storedAmount: nil, amount: 120, capable: true)
        XCTAssertNil(p["child"])
        XCTAssertEqual(p["parent"] as? Int, 7)
        XCTAssertEqual(p["stash_amount"] as? Double, 120)
    }

    func testPumpingPayloadSwitchOffSendsNull() {
        let p = EntityEditorView.pumpingPayload(base: ["amount": 80.0], parentID: 7, toStash: false,
                                                storedAmount: 40, amount: 80, capable: true)
        XCTAssertTrue(p["stash_amount"] is NSNull)
    }

    func testPumpingPayloadWithoutCapabilityKeepsChild() {
        let p = EntityEditorView.pumpingPayload(base: ["child": 1, "amount": 80.0], parentID: nil,
                                                toStash: true, storedAmount: nil, amount: 80, capable: false)
        XCTAssertEqual(p["child"] as? Int, 1)
        XCTAssertNil(p["stash_amount"])
        XCTAssertNil(p["parent"])
    }

    /// Only part of a session went into the stash: the stored amount is sent, not the whole.
    func testPumpingPayloadSendsStoredAmount() {
        let p = EntityEditorView.pumpingPayload(base: ["child": 1, "amount": 130.0], parentID: 7,
                                                toStash: true, storedAmount: 120, amount: 130, capable: true)
        XCTAssertEqual(p["stash_amount"] as? Double, 120)
        XCTAssertEqual(p["amount"] as? Double, 130)
    }

    /// Editing a parent's pumping from a child's timeline: the editor's base carries that child
    /// and the record's id; the id stays and the child doesn't come back.
    func testPumpingPayloadEditKeepsIdWithoutChild() {
        let p = EntityEditorView.pumpingPayload(base: ["child": 1, "id": 4000, "amount": 240.0], parentID: 1,
                                                toStash: true, storedAmount: 240, amount: 240, capable: true)
        XCTAssertNil(p["child"])
        XCTAssertEqual(p["id"] as? Int, 4000)
        XCTAssertEqual(p["parent"] as? Int, 1)
    }

    /// The picker starts on the child's only parent, and empty when the child has none or several.
    func testDefaultParentIsTheOnlyLinkedOne() {
        let robin = parent(1, "Robin", children: [1])
        let casey = parent(2, "Casey", children: [2])
        let sam = parent(3, "Sam", children: [2])
        XCTAssertEqual(EntityEditorView.defaultParentID(forChild: 1, in: [robin, casey, sam]), 1)
        XCTAssertNil(EntityEditorView.defaultParentID(forChild: 2, in: [robin, casey, sam]))
        XCTAssertNil(EntityEditorView.defaultParentID(forChild: 3, in: [robin, casey, sam]))
    }

    // MARK: Feeding

    func testBottleFromStashWithDiscard() {
        let f = EntityEditorView.feedingStashFields(type: .breastMilk, method: .bottle, fromStash: true,
                                                    amount: 60, stashAmount: nil, discarded: 10,
                                                    discardReason: "  Spilled  ", capable: true)
        XCTAssertEqual(f["stash_amount"] as? Double, 60)
        XCTAssertEqual(f["stash_discarded"] as? Double, 10)
        XCTAssertEqual(f["stash_discard_reason"] as? String, "Spilled")
    }

    func testDiscardOffSendsNull() {
        let f = EntityEditorView.feedingStashFields(type: .breastMilk, method: .bottle, fromStash: true,
                                                    amount: 60, stashAmount: 60, discarded: nil,
                                                    discardReason: "Spilled", capable: true)
        XCTAssertTrue(f["stash_discarded"] is NSNull)
        XCTAssertEqual(f["stash_discard_reason"] as? String, "")
    }

    func testFormulaClearsStashFields() {
        let f = EntityEditorView.feedingStashFields(type: .formula, method: .bottle, fromStash: true,
                                                    amount: 60, stashAmount: 60, discarded: 10,
                                                    discardReason: "x", capable: true)
        XCTAssertTrue(f["stash_amount"] is NSNull)
        XCTAssertTrue(f["stash_discarded"] is NSNull)
        XCTAssertEqual(f["stash_discard_reason"] as? String, "")
    }

    func testNotCapableSendsNothing() {
        XCTAssertTrue(EntityEditorView.feedingStashFields(type: .breastMilk, method: .bottle, fromStash: true,
                                                          amount: 60, stashAmount: nil, discarded: 5,
                                                          discardReason: nil, capable: false).isEmpty)
    }

    func testDiscardReasonCappedAt255() {
        let f = EntityEditorView.feedingStashFields(type: .breastMilk, method: .bottle, fromStash: true,
                                                    amount: 60, stashAmount: nil, discarded: 5,
                                                    discardReason: String(repeating: "a", count: 300), capable: true)
        XCTAssertEqual((f["stash_discard_reason"] as? String)?.count, 255)
    }

    /// Only part of the bottle came from the stash: that part is sent, not the whole.
    func testBottleSendsAmountFromStash() {
        let f = EntityEditorView.feedingStashFields(type: .fortifiedBreastMilk, method: .bottle, fromStash: true,
                                                    amount: 90, stashAmount: 50, discarded: nil,
                                                    discardReason: nil, capable: true)
        XCTAssertEqual(f["stash_amount"] as? Double, 50)
    }

    /// A bottle not taken from the stash clears it, and never sends a discard without a stash amount,
    /// which the server refuses.
    func testNotFromStashClearsDiscard() {
        let f = EntityEditorView.feedingStashFields(type: .breastMilk, method: .bottle, fromStash: false,
                                                    amount: 60, stashAmount: 60, discarded: 10,
                                                    discardReason: "Spilled", capable: true)
        XCTAssertTrue(f["stash_amount"] is NSNull)
        XCTAssertTrue(f["stash_discarded"] is NSNull)
        XCTAssertEqual(f["stash_discard_reason"] as? String, "")
    }

    /// A breastfeed is never taken from the stash.
    func testBreastfeedClearsStashFields() {
        let f = EntityEditorView.feedingStashFields(type: .breastMilk, method: .leftBreast, fromStash: true,
                                                    amount: nil, stashAmount: nil, discarded: nil,
                                                    discardReason: nil, capable: true)
        XCTAssertTrue(f["stash_amount"] is NSNull)
        XCTAssertTrue(f["stash_discarded"] is NSNull)
        XCTAssertEqual(f["stash_discard_reason"] as? String, "")
    }

    func testBreastfeedParentRules() {
        XCTAssertEqual(EntityEditorView.feedingParentField(method: .leftBreast, parentID: 7, linkedParentCount: 1,
                                                           isNew: true, capable: true)["parent"] as? Int, 7)
        XCTAssertTrue(EntityEditorView.feedingParentField(method: .leftBreast, parentID: nil, linkedParentCount: 2,
                                                          isNew: true, capable: true).isEmpty)
        XCTAssertTrue(EntityEditorView.feedingParentField(method: .bothBreasts, parentID: nil, linkedParentCount: 2,
                                                          isNew: false, capable: true)["parent"] is NSNull)
        XCTAssertTrue(EntityEditorView.feedingParentField(method: .bottle, parentID: 7, linkedParentCount: 1,
                                                          isNew: true, capable: true).isEmpty)
        XCTAssertTrue(EntityEditorView.feedingParentField(method: .leftBreast, parentID: 7, linkedParentCount: 1,
                                                          isNew: true, capable: false).isEmpty)
    }

    /// Editing a breastfeed of a child with one parent, and no parent chosen: nothing is sent.
    func testBreastfeedEditWithOneParentSendsNothing() {
        XCTAssertTrue(EntityEditorView.feedingParentField(method: .rightBreast, parentID: nil, linkedParentCount: 1,
                                                          isNew: false, capable: true).isEmpty)
    }

    private func parent(_ id: Int, _ name: String, children: [Int]) -> LocalEntity {
        let payload: [String: Any] = ["id": id, "first_name": name, "children": children]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return LocalEntity(kind: .parent, serverID: id, childID: EntityKind.parent.childID(from: payload),
                           timestamp: EntityKind.parent.timestamp(from: payload), payload: data, syncState: .synced)
    }
}

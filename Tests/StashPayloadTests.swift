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

    /// Nothing pumped (or no amount) with "Store in stash" on stores nothing: null, not a stash
    /// amount of 0, which the server refuses.
    func testPumpingPayloadWithoutAmountStoresNothing() {
        let zero = EntityEditorView.pumpingPayload(base: ["amount": 0.0], parentID: 7, toStash: true,
                                                   storedAmount: 0, amount: 0, capable: true)
        XCTAssertTrue(zero["stash_amount"] is NSNull)
        let none = EntityEditorView.pumpingPayload(base: [:], parentID: 7, toStash: true,
                                                   storedAmount: 40, amount: nil, capable: true)
        XCTAssertTrue(none["stash_amount"] is NSNull)
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

    /// A new stash entry starts on no parent, as on the web: with several parents one is picked,
    /// and nothing is sent until then. Other kinds start on the child's only parent.
    func testNewStashEntryStartsOnNoParent() {
        let robin = parent(1, "Robin", children: [1])
        let casey = parent(2, "Casey", children: [2])
        let parents = [robin, casey]
        let start = EntityEditorView.initialParentID(kind: .stashAdjustment, forChild: 1, in: parents)
        XCTAssertNil(start)
        XCTAssertEqual(EntityEditorView.initialParentID(kind: .pumping, forChild: 1, in: parents), 1)
        XCTAssertNil(entry(parentID: start, parentCount: parents.count, isNew: true)["parent"])
    }

    // MARK: Feeding

    /// "Taken from stash" starts on only as the server would apply its default: when it's on and the
    /// stash has been used (milk in the cached summary, a stash entry or a stored pumping).
    func testBottleFromStashDefaultNeedsStashActivity() {
        let empty = summary(balance: 0, lots: 0)
        XCTAssertFalse(EntityEditorView.bottleFromStashDefault(defaultOn: false, summary: summary(balance: 60, lots: 1),
                                                               hasStashActivity: true), "Default off")
        XCTAssertFalse(EntityEditorView.bottleFromStashDefault(defaultOn: true, summary: empty,
                                                               hasStashActivity: false), "No activity")
        XCTAssertFalse(EntityEditorView.bottleFromStashDefault(defaultOn: true, summary: nil,
                                                               hasStashActivity: false), "No summary, no activity")
        XCTAssertTrue(EntityEditorView.bottleFromStashDefault(defaultOn: true, summary: summary(balance: 60, lots: 1),
                                                              hasStashActivity: false), "Milk in the stash")
        XCTAssertTrue(EntityEditorView.bottleFromStashDefault(defaultOn: true, summary: summary(balance: -20, lots: 0),
                                                              hasStashActivity: false), "Below zero: it was used")
        XCTAssertTrue(EntityEditorView.bottleFromStashDefault(defaultOn: true, summary: empty,
                                                              hasStashActivity: true), "Only a stash entry cached")
    }

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

    // MARK: Stash entries

    private func entry(kind: StashKind = .discarded, amount: Double? = 20, reason: String = " Spilled ",
                       parentID: Int? = nil, parentCount: Int = 1, isNew: Bool = true) -> [String: Any] {
        EntityEditorView.stashEntryPayload(kind: kind, amount: amount, time: "2026-06-15T08:00:00Z",
                                           reason: reason, parentID: parentID, parentCount: parentCount,
                                           isNew: isNew, notes: "", tags: ["night"])
    }

    /// A stash entry belongs to the stash, not a child: never a `child` key, and never the server's
    /// computed `signed_amount` or a bottle link. With one parent the key is left out, so the server
    /// fills it in on a new entry and keeps its own on an edit.
    func testStashEntryPayloadHasNoChild() {
        for isNew in [true, false] {
            let p = entry(parentID: 1, isNew: isNew)
            XCTAssertNil(p["child"])
            XCTAssertNil(p["signed_amount"])
            XCTAssertNil(p["feeding"])
            XCTAssertNil(p["parent"], "One parent: the server's to fill in")
            XCTAssertEqual(p["kind"] as? String, "discarded")
            XCTAssertEqual(p["amount"] as? Double, 20)
            XCTAssertEqual(p["reason"] as? String, "Spilled")
            XCTAssertEqual(p["time"] as? String, "2026-06-15T08:00:00Z")
            XCTAssertEqual(p["tags"] as? [String], ["night"])
            XCTAssertEqual(p["notes"] as? String, "")
        }
        XCTAssertEqual(entry(kind: .added, reason: "")["kind"] as? String, "added")
        XCTAssertEqual(entry(reason: "")["reason"] as? String, "")
    }

    /// With several parents: the pick, else nothing on a new entry and a cleared parent on an edit.
    func testStashEntryParentWithSeveralParents() {
        XCTAssertEqual(entry(parentID: 2, parentCount: 2)["parent"] as? Int, 2)
        XCTAssertEqual(entry(parentID: 2, parentCount: 2, isNew: false)["parent"] as? Int, 2)
        XCTAssertNil(entry(parentID: nil, parentCount: 2, isNew: true)["parent"])
        XCTAssertTrue(entry(parentID: nil, parentCount: 3, isNew: false)["parent"] is NSNull)
        XCTAssertNil(entry(parentID: nil, parentCount: 0, isNew: false)["parent"])
    }

    func testStashEntryReasonCappedAt255() {
        let p = entry(reason: String(repeating: "b", count: 300))
        XCTAssertEqual((p["reason"] as? String)?.unicodeScalars.count, 255)
    }

    private func summary(balance: Double, lots: Int) -> StashSummaryDTO {
        let time = Date(timeIntervalSince1970: 1_790_000_000)
        let lot = StashLotDTO(time: time, amount: 60, throw_away_amount: 60, age_hours: 2,
                              warn_at: time.addingTimeInterval(48 * 3600),
                              expires_at: time.addingTimeInterval(72 * 3600),
                              status: .ok, is_oldest_expired: false)
        return StashSummaryDTO(balance: balance, status: .ok, warn_age_hours: 48, max_age_hours: 72,
                               oldest: lots > 0 ? time : nil, oldest_age_hours: lots > 0 ? 2 : nil,
                               lots: Array(repeating: lot, count: lots),
                               defaults: .init(pumping_to_stash: true, bottle_from_stash: true))
    }

    private func parent(_ id: Int, _ name: String, children: [Int]) -> LocalEntity {
        let payload: [String: Any] = ["id": id, "first_name": name, "children": children]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return LocalEntity(kind: .parent, serverID: id, childID: EntityKind.parent.childID(from: payload),
                           timestamp: EntityKind.parent.timestamp(from: payload), payload: data, syncState: .synced)
    }
}

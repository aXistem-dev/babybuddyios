import XCTest

/// The milk stash, on a demo server that has it: one parent, Robin, linked to the demo child.
/// `BB_NO_STASH=1` runs the demo as a server without it.
final class StashTests: UITestCase {
    /// A new pumping is logged on the child's only parent and goes into the stash by default. It
    /// has no child, and still shows on the child's timeline. (Demo history pumps 60–140 ml.)
    func testPumpingLogsOnParentIntoStash() {
        launch()
        openEditor("Pumping")
        let bar = expect(app.navigationBars["New Pumping"])
        XCTAssertTrue(expect(app.buttons["Robin"]).isSelected, "The child's only parent starts selected")
        expectValue(app.switches["Store in stash"], "1")

        let amount = app.textFields["0"]
        tap(amount)
        amount.typeText("185")
        tap(bar.buttons["Save"])
        expectGone(bar)

        tap(app.tabBars.buttons["Timeline"])
        let search = app.searchFields.firstMatch
        tap(search)
        search.typeText("185")
        expect(elements("label BEGINSWITH 'Pumping, ' AND label CONTAINS '185 ml'").firstMatch)
    }

    /// Robin's seeded 240 ml session opens from the child's timeline on Robin, stored; saving it
    /// keeps it a parent's pumping there.
    func testParentPumpingEditsOnParent() {
        launch(["BB_START_TAB": "timeline"])
        let search = app.searchFields.firstMatch
        tap(search)
        search.typeText("240")
        tap(elements("label BEGINSWITH 'Pumping, ' AND label CONTAINS '240 ml'").firstMatch)
        let bar = expect(app.navigationBars["Edit Pumping"])
        XCTAssertTrue(expect(app.buttons["Robin"]).isSelected)
        expectValue(app.switches["Store in stash"], "1")

        tap(bar.buttons["Save"])
        expectGone(bar)
        expect(elements("label BEGINSWITH 'Pumping, ' AND label CONTAINS '240 ml'").firstMatch)
    }

    /// A breast-milk bottle is taken from the stash by default. Some of it discarded, with a reason,
    /// reopens as it was saved. A breastfeed shows no stash switch, and no "Breastfed by" picker
    /// while Robin is the child's only parent.
    func testBottleFromStashWithDiscard() {
        launch()
        openEditor("Feeding")
        let bar = expect(app.navigationBars["New Feeding"])
        XCTAssertTrue(app.buttons["Breast"].isSelected)
        XCTAssertFalse(app.switches["Taken from stash"].exists, "A breastfeed isn't taken from the stash")
        XCTAssertFalse(app.staticTexts["Breastfed by"].exists, "The only parent needs no picker")

        tap(app.buttons.labeled("Left Breast"))
        tap(app.buttons["Bottle"])
        expectValue(app.switches["Taken from stash"], "1")
        toggle(app.switches["Some was discarded"], to: "1")

        // The discard's amount sits below the bottle's own; both are still empty, so both read "0".
        let discarded = app.textFields.matching(identifier: "0").element(boundBy: 1)
        tap(discarded)
        discarded.typeText("10")
        let reason = app.textFields["Spilled, left over…"]
        tap(reason)
        reason.typeText("Spilled")
        let amount = app.textFields["0"]
        tap(amount)
        amount.typeText("75")
        tap(bar.buttons["Save"])
        expectGone(bar)

        tap(app.tabBars.buttons["Timeline"])
        let search = app.searchFields.firstMatch
        tap(search)
        search.typeText("75")
        tap(elements("label BEGINSWITH 'Feeding, ' AND label CONTAINS '75 ml'").firstMatch)
        expect(app.navigationBars["Edit Feeding"])
        expectValue(app.switches["Taken from stash"], "1")
        expectValue(app.switches["Some was discarded"], "1")
        expect(app.textFields.matching(NSPredicate(format: "value == %@", "10")).firstMatch)
        expect(app.textFields.matching(NSPredicate(format: "value == %@", "Spilled")).firstMatch)
    }

    /// Without the milk stash a breast-milk bottle is upstream's: no stash switch.
    func testFeedingEditorWithoutStash() {
        launch(["BB_NO_STASH": "1"])
        openEditor("Feeding")
        expect(app.navigationBars["New Feeding"])
        tap(app.buttons.labeled("Left Breast"))
        tap(app.buttons["Bottle"])
        expectGone(app.buttons["Parent Fed"]) // the method menu has closed
        expect(app.buttons.labeled("Bottle"))
        XCTAssertFalse(app.switches["Taken from stash"].exists)
        XCTAssertFalse(app.switches["Some was discarded"].exists)
    }

    /// Without the milk stash the pumping editor is upstream's: no parent, no stash switch.
    func testPumpingEditorWithoutStash() {
        launch(["BB_NO_STASH": "1"])
        openEditor("Pumping")
        expect(app.navigationBars["New Pumping"])
        XCTAssertFalse(app.switches["Store in stash"].exists)
        XCTAssertFalse(app.staticTexts["Who pumped"].exists)
        XCTAssertFalse(app.buttons["Robin"].exists)
    }
}

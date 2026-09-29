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

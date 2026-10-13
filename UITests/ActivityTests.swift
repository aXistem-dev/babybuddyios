import XCTest

/// Activities, on a demo server that has them: Bath, Pajama change and Bodysuit change (one moment
/// each) and Walk (with a start and an end), and activities of all four for the demo child.
/// `BB_NO_ACTIVITIES=1` runs the demo as a server without activities.
final class ActivityTests: UITestCase {
    /// Home ▸ "+" ▸ More… ▸ Activity. Activities sit below the measurements, in a lazy grid that only
    /// holds its tiles once they're scrolled into view.
    private func openActivityEditor() {
        tap(app.buttons["Add"])
        tap(app.buttons.labeled("More…"))
        expect(app.navigationBars["Add Activity"])
        app.scrollViews.firstMatch.swipeUp()
        expect(app.staticTexts["ACTIVITIES"]) // section headers are drawn in capitals
        tap(app.buttons["Activity"])
    }

    /// A type without duration is logged at one time: the editor asks for a type first, then shows
    /// a Time row and no End, and the activity lands on the timeline under its type's name.
    func testLogActivityAtOneTime() {
        launch()
        openActivityEditor()
        let bar = expect(app.navigationBars["New Activity"])
        expect(element(labeled: "Can\u{2019}t save yet. Choose an activity type."))
        XCTAssertFalse(bar.buttons["Save"].isEnabled)

        tap(app.buttons["Bath"])
        XCTAssertTrue(app.buttons["Bath"].isSelected)
        expect(app.staticTexts["Time"])
        XCTAssertFalse(app.staticTexts["End"].exists)
        // A vertical text field: found by its prompt, as a field or a text view, whichever the OS exposes.
        let notes = elements("placeholderValue == 'Add a note\u{2026}'").firstMatch
        tap(notes)
        notes.typeText("Before bed")
        tap(bar.buttons["Save"])
        expectGone(bar)
        expect(element(labeled: "Logged bath"))

        tap(app.tabBars.buttons["Timeline"])
        let search = app.searchFields.firstMatch
        tap(search)
        search.typeText("Before bed")
        expect(element(labeled: "Bath, Before bed, "))
    }

    /// A type that tracks duration gets a start and an end instead of one time, and its row shows
    /// how long it took.
    func testTypeWithDurationHasStartAndEnd() {
        launch()
        openActivityEditor()
        expect(app.navigationBars["New Activity"])
        tap(app.buttons["Walk"])
        expect(app.staticTexts["Start"])
        expect(app.staticTexts["End"])
        XCTAssertFalse(app.staticTexts["Time"].exists)
        tap(app.buttons["Bath"])
        expect(app.staticTexts["Time"])
        XCTAssertFalse(app.staticTexts["End"].exists)
        tap(app.navigationBars["New Activity"].buttons["Cancel"])

        tap(app.tabBars.buttons["Timeline"])
        expect(element(labeled: "Walk, 40m"))
    }

    /// An activity opens in the editor on its own type, at its one time.
    func testEditKeepsItsType() {
        launch()
        tap(app.tabBars.buttons["Timeline"])
        tap(element(labeled: "Bodysuit change, "))
        expect(app.navigationBars["Edit Activity"])
        XCTAssertTrue(app.buttons["Bodysuit change"].isSelected)
        XCTAssertFalse(app.buttons["Bath"].isSelected)
        expect(app.staticTexts["Time"])
    }

    /// A server without activities: nothing to log, and no activities on the timeline.
    func testNoActivitiesWithoutServerSupport() {
        launch(["BB_NO_ACTIVITIES": "1"])
        tap(app.buttons["Add"])
        tap(app.buttons.labeled("More…"))
        expect(app.buttons["BMI"])
        app.scrollViews.firstMatch.swipeUp()
        XCTAssertFalse(app.staticTexts["ACTIVITIES"].exists)
        XCTAssertFalse(app.buttons["Activity"].exists)
        tap(app.navigationBars["Add Activity"].buttons["Cancel"])

        tap(app.tabBars.buttons["Timeline"])
        expect(element(labeled: "Feeding, "))
        XCTAssertFalse(element(labeled: "Bodysuit change, ").exists)
    }
}

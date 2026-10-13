import XCTest

/// Activities, on a demo server that has them: Bath, Pajama change and Bodysuit change (one moment
/// each), Walk (with a start and an end) and the inactive Haircut, and activities of the first four
/// for the demo child, the newest a bodysuit change.
/// `BB_NO_ACTIVITIES=1` runs the demo as a server without activities.
final class ActivityTests: UITestCase {
    /// Home ▸ "+" ▸ More…, scrolled to the activities. They sit below the measurements, in a lazy
    /// grid that only holds its tiles once they're scrolled into view.
    private func openAddActivity() {
        tap(app.buttons["Add"])
        tap(app.buttons.labeled("More…"))
        expect(app.navigationBars["Add Activity"])
        app.scrollViews.firstMatch.swipeUp()
        expect(app.staticTexts["ACTIVITIES"]) // section headers are drawn in capitals
    }

    /// Add Activity ▸ New activity…, the editor with every type.
    private func openActivityEditor() {
        openAddActivity()
        tap(app.buttons["New activity\u{2026}"])
    }

    /// One tap on a type without duration logs it for the child now: Home's Latest row for
    /// activities moves from the demo's newest activity to it, and the undo toast names it.
    func testLogActivityInOneTap() {
        launch()
        // Until the demo child is selected, Home shows nobody's records: wait for its newest activity.
        expect(element(labeled: "Bodysuit change, "))
        XCTAssertFalse(element(labeled: "Bath, ").exists, "Latest shows only the newest activity")

        openAddActivity()
        tap(app.buttons["Log Bath"])
        expectGone(app.navigationBars["Add Activity"])

        expect(element(labeled: "Logged bath"))
        expect(element(labeled: "Bath, "))
        XCTAssertFalse(element(labeled: "Bodysuit change, ").exists, "One row for activities, the newest")
    }

    /// A type with duration can't be logged in one tap: it opens the editor on that type.
    func testTypeWithDurationOpensTheEditor() {
        launch()
        openAddActivity()
        tap(app.buttons["Log Walk"])
        expect(app.navigationBars["New Activity"])
        XCTAssertTrue(app.buttons["Walk"].isSelected)
        expect(app.staticTexts["End"])
    }

    /// Add Activity offers the child's most used types and "New activity…"; an inactive type is in
    /// neither the sheet nor the editor.
    func testInactiveTypeIsNotOffered() {
        launch()
        openAddActivity()
        for name in ["Bath", "Pajama change", "Bodysuit change", "Walk"] {
            expect(app.buttons["Log \(name)"])
        }
        XCTAssertFalse(app.buttons["Log Haircut"].exists)
        tap(app.buttons["New activity\u{2026}"])
        expect(app.buttons["Bath"])
        XCTAssertFalse(app.buttons["Haircut"].exists)
    }

    /// Home treats activities like every other kind: one Latest row, the newest activity, which opens
    /// the timeline filtered to activities.
    func testLatestRowOpensFilteredTimeline() {
        launch()
        tap(element(labeled: "Bodysuit change, "))
        expect(app.navigationBars["Timeline"])
        XCTAssertFalse(app.navigationBars["Edit Activity"].exists)
        expect(element(labeled: "Walk, "))
        XCTAssertEqual(elements("label BEGINSWITH 'Feeding, '").count, 0, "Only activities pass the filter")
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
        XCTAssertFalse(app.buttons["New activity\u{2026}"].exists)
        XCTAssertFalse(app.buttons["Log Bath"].exists)
        tap(app.navigationBars["Add Activity"].buttons["Cancel"])

        tap(app.tabBars.buttons["Timeline"])
        expect(element(labeled: "Feeding, "))
        XCTAssertFalse(element(labeled: "Bodysuit change, ").exists)
    }
}

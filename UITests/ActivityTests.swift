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
        tap(app.buttons["Walk"]) // unpicked
        tap(app.buttons["Bath"])
        expect(app.staticTexts["Time"])
        XCTAssertFalse(app.staticTexts["End"].exists)
        tap(app.navigationBars["New Activity"].buttons["Cancel"])

        tap(app.tabBars.buttons["Timeline"])
        expect(element(labeled: "Walk, 40m"))
    }

    /// A new activity can be several types at once, saved as one activity each with the same time
    /// and notes. The End row shows only while a picked type tracks duration.
    func testLogSeveralActivitiesAtOnce() {
        launch()
        openActivityEditor()
        let bar = expect(app.navigationBars["New Activity"])
        tap(app.buttons["Bath"])
        tap(app.buttons["Pajama change"])
        XCTAssertTrue(app.buttons["Bath"].isSelected)
        XCTAssertTrue(app.buttons["Pajama change"].isSelected)
        expect(app.staticTexts["Time"])
        XCTAssertFalse(app.staticTexts["End"].exists)

        tap(app.buttons["Walk"])
        expect(app.staticTexts["End"])
        XCTAssertFalse(app.buttons["Start timer instead"].exists, "Only one type can be timed")
        tap(app.buttons["Walk"]) // unpicked
        expectGone(app.staticTexts["End"])

        let notes = elements("placeholderValue == 'Add a note\u{2026}'").firstMatch
        tap(notes)
        notes.typeText("Bedtime")
        tap(bar.buttons["Save"])
        expectGone(bar)
        expect(element(labeled: "Logged 2 activities"))

        tap(app.tabBars.buttons["Timeline"])
        let search = app.searchFields.firstMatch
        tap(search)
        search.typeText("Bedtime")
        expect(element(labeled: "Bath, Bedtime, "))
        expect(element(labeled: "Pajama change, Bedtime, "))
    }

    /// An activity opens in the editor on its own type, at its one time. It stays one type: picking
    /// another replaces it.
    func testEditKeepsItsType() {
        launch()
        tap(app.tabBars.buttons["Timeline"])
        tap(element(labeled: "Bodysuit change, "))
        expect(app.navigationBars["Edit Activity"])
        XCTAssertTrue(app.buttons["Bodysuit change"].isSelected)
        XCTAssertFalse(app.buttons["Bath"].isSelected)
        expect(app.staticTexts["Time"])
        tap(app.buttons["Bath"])
        XCTAssertTrue(app.buttons["Bath"].isSelected)
        XCTAssertFalse(app.buttons["Bodysuit change"].isSelected)
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

    // MARK: Managing activity types

    /// Settings ▸ Activity types, for a user the server lets manage them: add a type that tracks
    /// duration, and it's offered in the editor with a start and an end; rename it, and its slug stays.
    func testAddAndRenameType() {
        launch(["BB_START_TAB": "settings"])
        tap(app.buttons.labeled("Activity types"))
        expect(app.navigationBars["Activity types"])
        expect(app.buttons.labeled("Walk"))

        tap(app.buttons["Add activity type"])
        let new = expect(app.navigationBars["New activity type"])
        let name = app.textFields["Name"]
        tap(name)
        name.typeText("Stroller walk")
        toggle(app.switches["Track duration"], to: "1")
        tap(new.buttons["Save"])
        expectGone(new)
        tap(app.buttons.labeled("Stroller walk"))

        let edit = expect(app.navigationBars["Edit activity type"])
        expect(element(labeled: "The type\u{2019}s key (stroller-walk) stays the same"))
        replaceText(app.textFields["Name"], with: "Pram walk")
        tap(edit.buttons["Save"])
        expectGone(edit)
        expect(app.buttons.labeled("Pram walk"))
        XCTAssertFalse(app.buttons.labeled("Stroller walk").exists)

        tap(app.tabBars.buttons["Home"])
        openActivityEditor()
        tap(app.buttons["Pram walk"])
        expect(app.staticTexts["End"])
    }

    /// Deactivating a type takes it out of the editor; its activities stay on the timeline.
    func testDeactivateType() {
        launch(["BB_START_TAB": "settings"])
        tap(app.buttons.labeled("Activity types"))
        tap(app.buttons.labeled("Bodysuit change"))
        let edit = expect(app.navigationBars["Edit activity type"])
        toggle(app.switches["Active"], to: "0")
        tap(edit.buttons["Save"])
        expectGone(edit)
        expect(app.buttons["Bodysuit change, Inactive"])

        tap(app.tabBars.buttons["Timeline"])
        expect(element(labeled: "Bodysuit change, "))
        tap(app.tabBars.buttons["Home"])
        openActivityEditor()
        expect(app.buttons["Bath"])
        XCTAssertFalse(app.buttons["Bodysuit change"].exists)
    }

    /// Deleting a type that activities use asks first, counting them: Cancel keeps the type; Delete
    /// removes it and its activities, so Home's Latest row moves on to the next newest activity.
    func testDeleteTypeWithActivitiesAsksFirst() {
        launch(["BB_START_TAB": "settings"])
        tap(app.buttons.labeled("Activity types"))
        let title = "Delete \u{201C}Bodysuit change\u{201D} and its 1 activity?"

        tap(app.buttons.labeled("Bodysuit change"))
        tap(app.buttons["Delete activity type"])
        tap(app.alerts.buttons["Delete"])
        expect(app.alerts[title])
        expect(app.staticTexts["Every activity of this type will be removed. This can\u{2019}t be undone."])
        tap(app.alerts[title].buttons["Cancel"])
        expectGone(app.alerts[title])
        tap(app.navigationBars["Edit activity type"].buttons["Cancel"])
        expect(app.buttons.labeled("Bodysuit change"))

        tap(app.buttons.labeled("Bodysuit change"))
        tap(app.buttons["Delete activity type"])
        tap(app.alerts.buttons["Delete"])
        tap(app.alerts[title].buttons["Delete"])
        expectGone(app.navigationBars["Edit activity type"])
        expectGone(app.buttons.labeled("Bodysuit change"))

        tap(app.tabBars.buttons["Home"])
        expect(element(labeled: "Walk, "))
        XCTAssertFalse(element(labeled: "Bodysuit change, ").exists, "Its activity went with it")
    }

    /// The way to manage activity types is where they're used too: under the editor's type list, and
    /// in the timeline's filter once it's on activities.
    func testManageTypesFromEditorAndFilter() {
        launch()
        openActivityEditor()
        tap(app.buttons["Manage activity types"])
        expect(app.navigationBars["Activity types"])
        tap(app.navigationBars["Activity types"].buttons.element(boundBy: 0)) // back
        tap(app.navigationBars["New Activity"].buttons["Cancel"])

        tap(app.tabBars.buttons["Timeline"])
        tap(app.buttons["Filters"])
        tap(app.buttons.labeled("Type"))
        tap(app.buttons["Activity"])
        tap(app.buttons["Manage activity types"])
        expect(app.navigationBars["Activity types"])
    }

    /// A user the server doesn't let manage activity types sees neither the screen nor the links.
    func testReadOnlyHidesActivityTypes() {
        launch(["BB_START_TAB": "settings", "BB_ACTIVITY_TYPES_READONLY": "1"])
        expect(app.navigationBars["Settings"])
        XCTAssertFalse(app.buttons.labeled("Activity types").exists)

        tap(app.tabBars.buttons["Home"])
        openActivityEditor()
        expect(app.navigationBars["New Activity"])
        XCTAssertFalse(app.buttons["Manage activity types"].exists)
    }

    // MARK: Timers

    /// A type with duration can be timed like tummy time: the Start Timer sheet offers it (and not a
    /// type without duration), the running timer is named after it, and Stop logs it in one tap.
    func testTimeAnActivity() {
        launch(["BB_TOAST_SECONDS": "30"])
        tap(app.buttons["Stop"])
        tap(app.buttons["Discard timer"]) // the seeded timer, so one Stop button below

        tap(app.buttons["Add"])
        tap(app.buttons["Start timer"])
        let startSheet = expect(app.navigationBars["Start Timer"])
        expect(app.staticTexts["ACTIVITIES"])
        XCTAssertFalse(app.buttons["Bath"].exists, "A moment can't be timed")
        tap(app.buttons["Walk"])
        tap(app.buttons["Start walk timer"])
        expectGone(startSheet)
        expect(element(labeled: "Walk running"))

        tap(app.buttons["Stop"])
        expect(app.navigationBars["Stop Timer"])
        tap(app.buttons["Log walk"]) // preselected: the timer remembers its type
        expect(element(labeled: "Logged walk"))
        expect(app.buttons.labeled("Start a timer"))
    }

    /// The editor's "Start timer instead" times a type with duration from the form's start.
    func testStartTimerInsteadFromEditor() {
        launch()
        openActivityEditor()
        tap(app.buttons["Bath"])
        XCTAssertFalse(app.buttons["Start timer instead"].exists, "A moment can't be timed")
        tap(app.buttons["Bath"]) // unpicked
        tap(app.buttons["Walk"])
        tap(app.buttons["Start timer instead"])
        expectGone(app.navigationBars["New Activity"])
        expect(element(labeled: "Walk running"))
    }
}

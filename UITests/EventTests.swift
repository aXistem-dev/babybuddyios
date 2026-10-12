import XCTest

/// Events, on a demo server that has them: six event types (Massage, Nail trim, Outfit change, Tooth
/// brushing, Sunscreen, Haircut) and events of the first three for the demo child, among them a massage
/// and a nail trim logged together. `BB_NO_EVENTS=1` runs the demo as a server without events.
final class EventTests: UITestCase {
    /// Home ▸ "+" ▸ More…, where each event type logs in one tap. The events sit below the
    /// measurements, in a lazy grid that only holds its tiles once they're scrolled into view.
    private func openAddActivity(scrollToEvents: Bool = true) {
        tap(app.buttons["Add"])
        tap(app.buttons.labeled("More…"))
        expect(app.navigationBars["Add Activity"])
        if scrollToEvents { app.scrollViews.firstMatch.swipeUp() }
    }

    /// One tap on an event type logs it for the child now: Home's Latest row for events moves from
    /// the demo's newest event to it, and the undo toast names it.
    func testLogEventFromQuickAdd() {
        launch()
        // Until the demo child is selected, Home shows nobody's records: wait for its newest event.
        expect(element(labeled: "Outfit change, "))
        XCTAssertFalse(element(labeled: "Massage, ").exists, "Latest shows only the newest event")

        openAddActivity()
        expect(app.staticTexts["EVENTS"]) // section headers are drawn in capitals
        tap(app.buttons["Log Massage"])
        expectGone(app.navigationBars["Add Activity"])

        expect(element(labeled: "Logged massage"))
        expect(element(labeled: "Massage, "))
        XCTAssertFalse(element(labeled: "Outfit change, ").exists, "One row for events, the newest")
    }

    /// Several types at once: "New event…" opens the editor, where each ticked type becomes its own
    /// event at the identical time, both on the timeline.
    func testLogSeveralAtOnce() {
        launch()
        openAddActivity()
        tap(app.buttons["New event\u{2026}"])
        let bar = expect(app.navigationBars["New Event"])
        expect(element(labeled: "Can\u{2019}t save yet. Choose at least one event type."))
        XCTAssertFalse(bar.buttons["Save"].isEnabled)

        tap(app.buttons["Nail trim"])
        tap(app.buttons["Outfit change"])
        XCTAssertTrue(app.buttons["Nail trim"].isSelected)
        XCTAssertTrue(app.buttons["Outfit change"].isSelected)
        XCTAssertFalse(app.buttons["Massage"].isSelected)
        // A vertical text field: found by its prompt, as a field or a text view, whichever the OS exposes.
        let notes = elements("placeholderValue == 'Add a note\u{2026}'").firstMatch
        tap(notes)
        notes.typeText("Together")
        tap(bar.buttons["Save"])
        expectGone(bar)

        tap(app.tabBars.buttons["Timeline"])
        let search = app.searchFields.firstMatch
        tap(search)
        search.typeText("Together")
        let trim = expect(element(labeled: "Nail trim, Together, ")).label
        let outfit = expect(element(labeled: "Outfit change, Together, ")).label
        // "…, Together, 3:41 PM[, waiting to sync]": the same time on both.
        XCTAssertEqual(trim.dropFirst("Nail trim, ".count), outfit.dropFirst("Outfit change, ".count))
        XCTAssertFalse(elements("label BEGINSWITH 'Massage, Together'").firstMatch.exists)
    }

    /// Home treats events like every other kind: one Latest row, the newest event, which opens the
    /// timeline filtered to events.
    func testLatestEventRowOpensFilteredTimeline() {
        launch()
        tap(element(labeled: "Outfit change, "))
        expect(app.navigationBars["Timeline"])
        XCTAssertFalse(app.navigationBars["Edit Event"].exists)
        expect(element(labeled: "Massage, "))
        XCTAssertEqual(elements("label BEGINSWITH 'Feeding, '").count, 0, "Only events pass the filter")
    }

    /// Add Activity offers the child's 5 most used event types, unused ones by name, and "New
    /// event…" for the rest: of the six, the unused Tooth brushing is left out.
    func testQuickAddShowsMostUsed() {
        launch()
        openAddActivity()
        for name in ["Massage", "Outfit change", "Nail trim", "Haircut", "Sunscreen"] {
            expect(app.buttons["Log \(name)"])
        }
        XCTAssertFalse(app.buttons["Log Tooth brushing"].exists)
        expect(app.buttons["New event\u{2026}"])
    }

    /// A server without events: no card, no event types to log, no events on the timeline.
    func testNoEventsWithoutServerSupport() {
        launch(["BB_NO_EVENTS": "1"])
        expect(app.buttons["Add"])
        XCTAssertFalse(app.staticTexts["LAST EVENTS"].exists)
        openAddActivity()
        expect(app.buttons["BMI"])
        XCTAssertFalse(app.staticTexts["EVENTS"].exists)
        XCTAssertFalse(app.buttons["Log Massage"].exists)
        XCTAssertFalse(app.buttons["New event\u{2026}"].exists)
    }

    // MARK: Managing event types

    /// Settings ▸ Event types, for a user the server lets manage them: add a type with an emoji,
    /// then rename it; its slug stays.
    func testAdminAddsAndRenamesType() {
        launch(["BB_START_TAB": "settings"])
        tap(app.buttons.labeled("Event types"))
        expect(app.navigationBars["Event types"])
        expect(app.buttons["Massage"])

        tap(app.buttons["Add event type"])
        let new = expect(app.navigationBars["New event type"])
        let name = app.textFields["Name"]
        tap(name)
        name.typeText("Stroller walk")
        let emoji = app.textFields["One emoji"]
        tap(emoji)
        emoji.typeText("\u{1F6B6}")
        tap(new.buttons["Save"])
        expectGone(new)
        expect(app.buttons["Stroller walk"])

        tap(app.buttons["Stroller walk"])
        let edit = expect(app.navigationBars["Edit event type"])
        expect(element(labeled: "The type\u{2019}s key (stroller-walk) stays the same"))
        replaceText(app.textFields["Name"], with: "Pram walk")
        tap(edit.buttons["Save"])
        expectGone(edit)
        expect(app.buttons["Pram walk"])
        XCTAssertFalse(app.buttons["Stroller walk"].exists)
    }

    /// The way to manage event types is where they're used too: under the editor's type list, and in
    /// the timeline's filter once it's on events.
    func testManageEventTypesFromEditorAndFilter() {
        launch()
        openAddActivity()
        tap(app.buttons["New event\u{2026}"])
        expect(app.navigationBars["New Event"])
        tap(app.buttons["Manage event types"])
        expect(app.navigationBars["Event types"])
        expect(app.buttons["Massage"])
        tap(app.navigationBars["Event types"].buttons.element(boundBy: 0)) // back
        tap(app.navigationBars["New Event"].buttons["Cancel"])

        tap(app.tabBars.buttons["Timeline"])
        tap(app.buttons["Filters"])
        tap(app.buttons.labeled("Type"))
        tap(app.buttons["Event"])
        tap(app.buttons["Manage event types"])
        expect(app.navigationBars["Event types"])
    }

    /// A type that events still use can't be deleted: the server's reason shows.
    func testDeletingUsedTypeIsRefused() {
        launch(["BB_START_TAB": "settings"])
        tap(app.buttons.labeled("Event types"))
        tap(app.buttons["Massage"])
        expect(app.navigationBars["Edit event type"])
        tap(app.buttons["Delete event type"])
        tap(app.alerts.buttons["Delete"])
        expect(element(labeled: "This event type is used by events and can not be deleted."))
    }

    /// A user the server doesn't let manage event types doesn't see the screen at all.
    func testReadOnlyHidesEventTypes() {
        launch(["BB_START_TAB": "settings", "BB_EVENT_TYPES_READONLY": "1"])
        expect(app.navigationBars["Settings"])
        XCTAssertFalse(app.buttons.labeled("Event types").exists)
        XCTAssertFalse(app.staticTexts["EVENTS"].exists)

        tap(app.tabBars.buttons["Home"])
        tap(app.buttons["Add"])
        tap(app.buttons.labeled("More\u{2026}"))
        app.scrollViews.firstMatch.swipeUp()
        tap(app.buttons["New event\u{2026}"])
        expect(app.navigationBars["New Event"])
        XCTAssertFalse(app.buttons["Manage event types"].exists)
    }
}

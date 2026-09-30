import XCTest

/// Events, on a demo server that has them: three event types (Bath, Nail trim, Outfit change) and
/// events of them for the demo child, among them a bath and a nail trim logged together.
/// `BB_NO_EVENTS=1` runs the demo as a server without events.
final class EventTests: UITestCase {
    /// Home ▸ "+" ▸ More…, where each event type logs in one tap. The events sit below the
    /// measurements, in a lazy grid that only holds its tiles once they're scrolled into view.
    private func openAddActivity(scrollToEvents: Bool = true) {
        tap(app.buttons["Add"])
        tap(app.buttons.labeled("More…"))
        expect(app.navigationBars["Add Activity"])
        if scrollToEvents { app.scrollViews.firstMatch.swipeUp() }
    }

    /// One tap on an event type logs it for the child now: the Last events card moves from the
    /// seeded bath to one just now, and the undo toast names it.
    func testLogEventFromQuickAdd() {
        launch()
        // Until the demo child is selected, Home shows nobody's events: wait for the demo's bath.
        let before = expect(elements("label BEGINSWITH 'Bath, ' AND NOT (label ENDSWITH 'never')").firstMatch).label

        openAddActivity()
        expect(app.staticTexts["EVENTS"]) // section headers are drawn in capitals
        tap(app.buttons["Log Bath"])
        expectGone(app.navigationBars["Add Activity"])

        expect(element(labeled: "Logged bath"))
        let after = expect(element(labeled: "Bath, ")).label
        XCTAssertNotEqual(after, before, "The card shows the new bath")
        XCTAssertTrue(after == "Bath, now" || after.hasSuffix("seconds ago") || after.hasSuffix("second ago"),
                      "A bath just now, not \(after)")
    }

    /// Several types at once: "Event…" opens the editor, where each ticked type becomes its own
    /// event at the identical time, both on the timeline.
    func testLogSeveralAtOnce() {
        launch()
        openAddActivity()
        tap(app.buttons["Event\u{2026}"])
        let bar = expect(app.navigationBars["New Event"])
        expect(element(labeled: "Can\u{2019}t save yet. Choose at least one event type."))
        XCTAssertFalse(bar.buttons["Save"].isEnabled)

        tap(app.buttons["Nail trim"])
        tap(app.buttons["Outfit change"])
        XCTAssertTrue(app.buttons["Nail trim"].isSelected)
        XCTAssertTrue(app.buttons["Outfit change"].isSelected)
        XCTAssertFalse(app.buttons["Bath"].isSelected)
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
        XCTAssertFalse(elements("label BEGINSWITH 'Bath, Together'").firstMatch.exists)
    }

    /// Home lists every event type with how long ago the child last had one.
    func testLastEventsCard() {
        launch()
        expect(app.staticTexts["LAST EVENTS"]) // section headers are drawn in capitals
        expect(element(labeled: "Bath, "))
        expect(element(labeled: "Nail trim, "))
        expect(element(labeled: "Outfit change, "))
    }

    /// A server without events: no card, no event types to log, no events on the timeline.
    func testNoEventsWithoutServerSupport() {
        launch(["BB_NO_EVENTS": "1"])
        expect(app.buttons["Add"])
        XCTAssertFalse(app.staticTexts["LAST EVENTS"].exists)
        openAddActivity()
        expect(app.buttons["BMI"])
        XCTAssertFalse(app.staticTexts["EVENTS"].exists)
        XCTAssertFalse(app.buttons["Log Bath"].exists)
        XCTAssertFalse(app.buttons["Event\u{2026}"].exists)
    }
}

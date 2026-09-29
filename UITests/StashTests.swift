import XCTest

/// The milk stash, on a demo server that has it: one parent, Robin, linked to the demo child.
/// `BB_NO_STASH=1` runs the demo as a server without it.
final class StashTests: UITestCase {
    /// A new pumping is logged on the child's only parent and goes into the stash by default. It
    /// has no child, and still shows on the stash screen and the child's timeline. (Demo history
    /// pumps 60–140 ml.)
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

        openStash()
        expect(elements("label BEGINSWITH 'Pumping, ' AND label CONTAINS '185 ml'").firstMatch)

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

    // MARK: Stash screen

    /// Home ▸ Milk stash.
    private func openStash() {
        tap(app.buttons.labeled("Milk stash"))
        expect(app.navigationBars["Milk stash"])
    }

    /// The stash screen's balance, e.g. 315 from "In the stash, 315 ml". The demo's amounts are
    /// whole millilitres.
    private func balance() -> Int {
        let label = expect(element(labeled: "In the stash, ")).label
        let figure = label.dropFirst("In the stash, ".count).replacingOccurrences(of: " ml", with: "")
        return Int(figure) ?? .min
    }

    /// Discarding milk logs a stash entry with its reason, and the balance drops by it once the
    /// sync after saving has refreshed the summary.
    func testDiscardMilkFromStash() {
        launch()
        openStash()
        let before = balance()
        XCTAssertNotEqual(before, .min, "The demo summary has a balance")

        tap(app.buttons["Discard milk"])
        let bar = expect(app.navigationBars["New Stash adjustment"])
        XCTAssertTrue(expect(app.buttons["Discarded"]).isSelected)
        XCTAssertFalse(app.staticTexts["Whose milk"].exists, "Robin is the only parent")
        let amount = app.textFields["0"]
        tap(amount)
        amount.typeText("20")
        let reason = app.textFields["Reason (optional)"]
        tap(reason)
        reason.typeText("Spilled")
        tap(bar.buttons["Save"])
        expectGone(bar)

        expect(elements("label BEGINSWITH 'Stash adjustment, ' AND label CONTAINS '20 ml · Spilled'").firstMatch)
        expect(element(labeled: "In the stash, \(before - 20) ml"))
    }

    /// The demo's oldest lot (Robin's 240 ml session, 80 h ago, 35 ml left after the bottles and
    /// discards since) has expired. "Throw away" on it opens a discard pre-filled with what's left
    /// and why.
    func testThrowAwayExpiredLot() {
        launch()
        openStash()
        expect(app.buttons["Throw away all expired milk"])
        tap(app.buttons["Throw away"])
        expect(app.navigationBars["New Stash adjustment"])
        XCTAssertTrue(expect(app.buttons["Discarded"]).isSelected)
        expect(app.textFields.matching(NSPredicate(format: "value == %@", "35")).firstMatch)
        expect(app.textFields.matching(NSPredicate(format: "value == %@", "Older than 72 h")).firstMatch)
    }

    /// The 10 ml spilled from a demo bottle is that bottle's: read-only here, with no Save or
    /// Delete, and a way to the bottle.
    func testLinkedDiscardEditsOnItsFeeding() {
        launch()
        openStash()
        tap(elements("label BEGINSWITH 'Stash adjustment, ' AND label CONTAINS '10 ml · Spilled'").firstMatch)
        let bar = expect(app.navigationBars["Edit Stash adjustment"])
        XCTAssertFalse(bar.buttons["Save"].isEnabled)
        XCTAssertFalse(app.buttons["Delete Stash adjustment"].exists)
        XCTAssertFalse(app.buttons["Discarded"].exists, "The kind isn't editable here")

        tap(app.buttons["Edit on the feeding"])
        expect(app.navigationBars["Edit Feeding"])
        expectValue(app.switches["Some was discarded"], "1")
    }

    /// Settings turns the stash's below-zero warning back on after it was dismissed; the row is
    /// only there with the milk stash.
    func testBelowZeroWarningSetting() {
        launch(["BB_START_TAB": "settings"])
        expectValue(app.switches["Below-zero stash warning"], "1")
    }

    func testNoStashCardWithoutStash() {
        launch(["BB_NO_STASH": "1"])
        expect(app.buttons["Add"])
        XCTAssertFalse(app.buttons.labeled("Milk stash").exists)
        tap(app.tabBars.buttons["Settings"])
        expect(app.navigationBars["Settings"])
        XCTAssertFalse(app.switches["Below-zero stash warning"].exists)
        XCTAssertFalse(app.switches["Milk age alerts"].exists)
    }

    // MARK: Milk age alerts

    /// Settings ▸ Notifications has the milk age alerts, with the server's age limits. They are on
    /// by default in the app; UI tests start them off (`BB_UITEST`), so the demo's old milk doesn't
    /// raise the permission prompt over every other test.
    func testMilkAgeAlertsSetting() {
        launch(["BB_START_TAB": "settings"])
        let alerts = expect(app.switches["Milk age alerts"])
        expect(app.staticTexts["Use first after 48 h, throw away after 72 h (set on the server)"])
        expectValue(alerts, "0")
        toggle(alerts, to: "1")
        allowNotificationsIfAsked() // turning them on is what asks for permission
    }

    /// The demo stash holds a lot past its use-first age. `BB_STASH_ALERT_SECONDS` brings its
    /// "Milk is getting old" to 25 s after launch; tapping it opens the stash screen, where
    /// "Throw away" is the next step.
    func testMilkAgeAlertOpensStash() {
        launch(["BB_STASH_ALERT_SECONDS": "25"])
        allowNotificationsIfAsked() // the hook turns the alerts on, so the reset install asks
        expect(app.buttons.labeled("Milk stash"))

        pressHome()
        let banner = springboard.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Milk is getting old")).firstMatch
        if !banner.waitForExistence(timeout: 60) {
            // It may have come and gone while the app was away; Notification Center keeps it.
            openNotificationCenter()
            XCTAssertTrue(banner.waitForExistence(timeout: 10), "No “Milk is getting old” notification")
        }
        banner.tap()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "The tap should bring the app back")
        expect(app.navigationBars["Milk stash"])
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

import XCTest

/// The milk stash, on a demo server that has it: a fixed stash of expired, expiring and fresh milk.
/// `BB_NO_STASH=1` runs the demo as a server without the milk stash.
final class StashTests: UITestCase {
    /// "Store this milk" starts off, and a new pumping starts with the last choice.
    func testPumpingIntoStashRemembersTheLastChoice() {
        launch(["BB_TOAST_SECONDS": "30"])
        openEditor("Pumping")
        let bar = expect(app.navigationBars["New Pumping"])
        let intoStash = app.switches["Store this milk"]
        expectValue(intoStash, "0")
        toggle(intoStash, to: "1")
        let amount = app.textFields["0"]
        tap(amount)
        amount.typeText("80")
        tap(bar.buttons["Save"])
        expectGone(bar)
        expect(app.otherElements["Logged Pumping"])

        openEditor("Pumping")
        expect(app.navigationBars["New Pumping"])
        expectValue(app.switches["Store this milk"], "1")
    }

    /// "From stored milk" is only offered for breast milk not fed at the breast, with an amount.
    func testFromStashOnlyForBreastMilkBottles() {
        launch()
        openEditor("Feeding")
        expect(app.navigationBars["New Feeding"])
        let fromStash = app.switches["From stored milk"]
        XCTAssertFalse(fromStash.exists, "A breastfeed doesn't come from the stash")

        tap(app.buttons.labeled("Left Breast"))
        tap(app.buttons["Bottle"])
        expectGone(app.buttons["Parent Fed"]) // the method menu has closed
        XCTAssertFalse(fromStash.exists, "Not without an amount")
        let amount = app.textFields["0"]
        tap(amount)
        amount.typeText("60")
        expectValue(fromStash, "0")

        tap(app.buttons["Formula"])
        expectGone(fromStash)
        tap(app.buttons["Fortified"])
        expect(fromStash)
    }

    /// Without the milk stash neither editor shows a stash switch.
    func testNoStashSwitchesWithoutStash() {
        launch(["BB_NO_STASH": "1"])
        openEditor("Pumping")
        expect(app.navigationBars["New Pumping"])
        XCTAssertFalse(app.switches["Store this milk"].exists)
        tap(app.navigationBars["New Pumping"].buttons["Cancel"])
        openEditor("Feeding")
        expect(app.navigationBars["New Feeding"])
        tap(app.buttons.labeled("Left Breast"))
        tap(app.buttons["Bottle"])
        expectGone(app.buttons["Parent Fed"])
        let amount = app.textFields["0"]
        tap(amount)
        amount.typeText("60")
        XCTAssertFalse(app.switches["From stored milk"].exists)
    }

    /// Home shows the stash while it holds milk, and its screen lists the demo's milk oldest first:
    /// 80 ml expired, 120 ml expiring soon and 150 ml fresh.
    func testStashScreenShowsBalanceAndMilk() {
        launch()
        tap(element(labeled: "Stored milk, 350 ml, Some milk has expired"))
        expect(app.navigationBars["Stored milk"])
        expect(element(labeled: "In storage, 350 ml"))
        let lots = elements("label CONTAINS ', Stored '")
        expect(lots.firstMatch)
        XCTAssertEqual(lots.count, 3)
        XCTAssertTrue(lots.element(boundBy: 0).label.hasPrefix("80 ml"))
        XCTAssertTrue(lots.element(boundBy: 0).label.hasSuffix("Expired"))
        XCTAssertTrue(lots.element(boundBy: 1).label.hasSuffix("Expiring soon"))
        XCTAssertTrue(lots.element(boundBy: 2).label.hasSuffix("Fresh"))
    }

    /// A lot opens the record it came from: the 50-hour lot its pumping, the 75-hour lot the milk added
    /// by hand. The 6-hour lot names no source, so it's not a button.
    func testLotOpensItsSource() {
        launch()
        openStashFromAddSheet()
        let lots = app.buttons.matching(NSPredicate(format: "label CONTAINS ', Stored '"))
        expect(lots.firstMatch)
        XCTAssertEqual(lots.count, 2, "Only the lots with a source this phone has")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '150 ml, Stored '")).firstMatch.exists)

        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '120 ml, Stored '")).firstMatch)
        let pumping = expect(app.navigationBars["Edit Pumping"])
        tap(pumping.buttons["Cancel"])
        expectGone(pumping)

        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '80 ml, Stored '")).firstMatch)
        expect(app.navigationBars["Edit Stored Milk Entry"])
    }

    /// The history lists the demo's movements newest first, signed: the bottle from the stash, the
    /// pumping into it, the milk added by hand. A row opens its record.
    func testHistoryListsMovements() {
        launch()
        openStashFromAddSheet()
        app.swipeUp()
        expect(app.staticTexts["HISTORY"]) // section headers are drawn in capitals
        let rows = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH 'Bottle, ' OR label BEGINSWITH 'Pumping, ' OR label BEGINSWITH 'Added, '"))
        expect(rows.firstMatch)
        XCTAssertTrue(rows.element(boundBy: 0).label.hasPrefix("Bottle, \u{2212}40 ml"))
        XCTAssertTrue(rows.element(boundBy: 1).label.hasPrefix("Pumping, +160 ml"))
        XCTAssertTrue(rows.element(boundBy: 2).label.hasPrefix("Added, +80 ml"))

        tap(app.buttons.labeled("Bottle, "))
        expect(app.navigationBars["Edit Feeding"])
    }

    /// Milk added by hand can be deleted from the history, after confirming; a pumping can't be from
    /// here (its editor deletes it).
    func testDeleteManualEntryFromHistory() {
        launch()
        openStashFromAddSheet()
        app.swipeUp()
        app.buttons.labeled("Pumping, ").press(forDuration: 1)
        XCTAssertFalse(app.buttons["Delete"].waitForExistence(timeout: 2), "No delete for a pumping")
        // Without a menu, letting go may count as a tap on the row, which opens the pumping.
        let editor = app.navigationBars["Edit Pumping"]
        if editor.waitForExistence(timeout: 2) {
            tap(editor.buttons["Cancel"])
            expectGone(editor)
        }

        let added = app.buttons.labeled("Added, +80 ml")
        expect(added).press(forDuration: 1)
        tap(app.buttons["Delete"])
        let alert = expect(app.alerts["Delete this stored milk entry?"])
        tap(alert.buttons["Delete"])
        expectGone(added)
        expect(app.buttons.labeled("Pumping, "))
    }

    /// Adding milk from the screen queues a milk stash entry, and throwing away expired milk waits
    /// until the server has it.
    func testAddMilkFromTheScreen() {
        launch()
        openStashFromAddSheet()
        tap(app.buttons["Add Milk"])
        let bar = expect(app.navigationBars["Add Milk"])
        XCTAssertTrue(app.buttons["Added"].isSelected)
        let amount = app.textFields["0"]
        tap(amount)
        amount.typeText("60")
        tap(bar.buttons["Save"])
        expectGone(bar)

        expect(app.staticTexts["Waiting to sync the last stored milk entry first."])
        XCTAssertFalse(app.buttons["Throw Away Expired Milk"].isEnabled)
    }

    /// "Throw away expired milk" opens a discard of exactly the expired milk.
    func testThrowAwayIsPrefilledWithTheExpiredMilk() {
        launch()
        openStashFromAddSheet()
        tap(app.buttons["Throw Away Expired Milk"])
        let bar = expect(app.navigationBars["Discard Milk"])
        XCTAssertTrue(app.buttons["Discarded"].isSelected)
        expectValue(app.textFields["0"], "80")
        tap(bar.buttons["Save"])
        expectGone(bar)
        XCTAssertFalse(app.buttons["Throw Away Expired Milk"].isEnabled, "Not twice before it syncs")
    }

    /// Without the milk stash neither Home nor the Add Activity sheet mentions it.
    func testNoStashWithoutStash() {
        launch(["BB_NO_STASH": "1"])
        expect(element(labeled: "Diapers, "))
        XCTAssertFalse(element(labeled: "Stored milk").exists)
        tap(app.buttons["Add"])
        tap(app.buttons.labeled("More…"))
        expect(app.navigationBars["Add Activity"])
        XCTAssertFalse(app.buttons.labeled("Stored milk").exists)
    }

    private func openStashFromAddSheet() {
        tap(app.buttons["Add"])
        tap(app.buttons.labeled("More…"))
        expect(app.navigationBars["Add Activity"])
        tap(app.buttons.labeled("Stored milk"))
        expect(app.navigationBars["Stored milk"])
    }

    /// Settings offers the milk stash's expiry alerts only on a server with the stash. (UI tests
    /// start with them off; delivering an alert is covered by the unit tests.)
    func testMilkStashExpirySetting() {
        launch(["BB_START_TAB": "settings"])
        let expiry = app.switches["Stored milk expiry"]
        expectValue(expiry, "0")

        launch(["BB_START_TAB": "settings", "BB_NO_STASH": "1"])
        expect(app.switches["Medication reminders"])
        XCTAssertFalse(app.switches["Stored milk expiry"].exists)
    }

    /// A milk stash alert's link opens the stash screen.
    func testStashLinkOpensTheScreen() {
        launch()
        expect(element(labeled: "Diapers, "))
        app.open(URL(string: "babybuddy://stash")!)
        expect(app.navigationBars["Stored milk"])
    }
}

import XCTest

/// The milk stash, on a demo server that has it: a fixed stash of expired, expiring and fresh milk.
/// `BB_NO_STASH=1` runs the demo as a server without the milk stash.
final class StashTests: UITestCase {
    /// "Into the milk stash" starts off, and a new pumping starts with the last choice.
    func testPumpingIntoStashRemembersTheLastChoice() {
        launch(["BB_TOAST_SECONDS": "30"])
        openEditor("Pumping")
        let bar = expect(app.navigationBars["New Pumping"])
        let intoStash = app.switches["Into the milk stash"]
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
        expectValue(app.switches["Into the milk stash"], "1")
    }

    /// "From the milk stash" is only offered for breast milk not fed at the breast, with an amount.
    func testFromStashOnlyForBreastMilkBottles() {
        launch()
        openEditor("Feeding")
        expect(app.navigationBars["New Feeding"])
        let fromStash = app.switches["From the milk stash"]
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

    /// Without the milk stash both editors are upstream's.
    func testNoStashSwitchesWithoutStash() {
        launch(["BB_NO_STASH": "1"])
        openEditor("Pumping")
        expect(app.navigationBars["New Pumping"])
        XCTAssertFalse(app.switches["Into the milk stash"].exists)
        tap(app.navigationBars["New Pumping"].buttons["Cancel"])
        openEditor("Feeding")
        expect(app.navigationBars["New Feeding"])
        tap(app.buttons.labeled("Left Breast"))
        tap(app.buttons["Bottle"])
        expectGone(app.buttons["Parent Fed"])
        let amount = app.textFields["0"]
        tap(amount)
        amount.typeText("60")
        XCTAssertFalse(app.switches["From the milk stash"].exists)
    }

    /// Home shows the stash while it holds milk, and its screen lists the demo's milk oldest first:
    /// 80 ml expired, 120 ml expiring soon and 150 ml fresh.
    func testStashScreenShowsBalanceAndMilk() {
        launch()
        tap(element(labeled: "Milk stash, 350 ml, Some milk has expired"))
        expect(app.navigationBars["Milk stash"])
        expect(element(labeled: "In the stash, 350 ml"))
        let lots = elements("label CONTAINS ', Stored '")
        expect(lots.firstMatch)
        XCTAssertEqual(lots.count, 3)
        XCTAssertTrue(lots.element(boundBy: 0).label.hasPrefix("80 ml"))
        XCTAssertTrue(lots.element(boundBy: 0).label.hasSuffix("Expired"))
        XCTAssertTrue(lots.element(boundBy: 1).label.hasSuffix("Expiring soon"))
        XCTAssertTrue(lots.element(boundBy: 2).label.hasSuffix("Fresh"))
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

        expect(app.staticTexts["Waiting to sync the last milk stash entry first."])
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
        XCTAssertFalse(element(labeled: "Milk stash").exists)
        tap(app.buttons["Add"])
        tap(app.buttons.labeled("More…"))
        expect(app.navigationBars["Add Activity"])
        XCTAssertFalse(app.buttons.labeled("Milk stash").exists)
    }

    private func openStashFromAddSheet() {
        tap(app.buttons["Add"])
        tap(app.buttons.labeled("More…"))
        expect(app.navigationBars["Add Activity"])
        tap(app.buttons.labeled("Milk stash"))
        expect(app.navigationBars["Milk stash"])
    }

    /// Settings offers the milk stash's expiry alerts only on a server with the stash. (UI tests
    /// start with them off; delivering an alert is covered by the unit tests.)
    func testMilkStashExpirySetting() {
        launch(["BB_START_TAB": "settings"])
        let expiry = app.switches["Milk stash expiry"]
        expectValue(expiry, "0")

        launch(["BB_START_TAB": "settings", "BB_NO_STASH": "1"])
        expect(app.switches["Medication reminders"])
        XCTAssertFalse(app.switches["Milk stash expiry"].exists)
    }

    /// A milk stash alert's link opens the stash screen.
    func testStashLinkOpensTheScreen() {
        launch()
        expect(element(labeled: "Diapers, "))
        app.open(URL(string: "babybuddy://stash")!)
        expect(app.navigationBars["Milk stash"])
    }
}

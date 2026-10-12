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
}

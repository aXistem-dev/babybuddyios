import XCTest

/// The next-feed estimate, on a demo whose feeds come every 3 hours around the clock
/// (`BB_SEED_STEADY_FEEDS=1`), so it shows whatever time of day the test runs.
final class FeedEstimateTests: UITestCase {
    /// Off by default: Home shows no estimate, even with a steady pattern to estimate from.
    func testOffByDefault() {
        launch(["BB_SEED_STEADY_FEEDS": "1"])
        expect(element(labeled: "Feedings, "))
        XCTAssertFalse(element(labeled: "Next feed estimate").exists)
    }

    /// Settings ▸ Feeding switches it on; Home then says how often the child usually feeds and when
    /// the next feed is likely.
    func testSwitchedOnShowsTheEstimate() {
        launch(["BB_SEED_STEADY_FEEDS": "1", "BB_START_TAB": "settings"])
        expect(app.staticTexts["FEEDING"]) // section headers are drawn in capitals
        let estimateSwitch = expect(app.switches["Next feed estimate"])
        expectValue(estimateSwitch, "0")
        toggle(estimateSwitch, to: "1")

        tap(app.tabBars.buttons["Home"])
        let line = expect(element(labeled: "Next feed estimate: Usually every ~3h"))
        XCTAssertTrue(line.label.contains("next around"))
    }
}

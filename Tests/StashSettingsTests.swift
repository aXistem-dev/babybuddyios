import XCTest
@testable import BabyBuddy

/// Settings ▸ Milk stash: the server's stash settings, detected from the API root, cached for
/// offline, and changed with a PATCH of only what changed.
@MainActor
final class StashSettingsTests: XCTestCase {
    override func tearDown() async throws {
        StashCapability.reset()
    }

    private let defaults = StashSettingsDTO(pumping_to_stash: true, bottle_from_stash: true,
                                            warn_age_hours: 48, max_age_hours: 72, can_edit: true)

    func testDecodes() throws {
        let s = try APICoders.decoder.decode(StashSettingsDTO.self, from: Data("""
        {"pumping_to_stash": false, "bottle_from_stash": true,
         "warn_age_hours": 24, "max_age_hours": 96, "can_edit": false}
        """.utf8))
        XCTAssertEqual(s, StashSettingsDTO(pumping_to_stash: false, bottle_from_stash: true,
                                           warn_age_hours: 24, max_age_hours: 96, can_edit: false))
    }

    /// Only the fields that changed are sent, and never `can_edit`.
    func testPatchBodyHasOnlyChanges() {
        XCTAssertTrue(StashSettingsEdit.body(from: defaults, to: defaults).isEmpty)

        var toggled = defaults
        toggled.bottle_from_stash = false
        toggled.can_edit = false
        let body = StashSettingsEdit.body(from: defaults, to: toggled)
        XCTAssertEqual(body.count, 1)
        XCTAssertEqual(body["bottle_from_stash"] as? Bool, false)

        var aged = defaults
        aged.warn_age_hours = 24
        aged.max_age_hours = 96
        let ages = StashSettingsEdit.body(from: defaults, to: aged)
        XCTAssertEqual(ages["warn_age_hours"] as? Int, 24)
        XCTAssertEqual(ages["max_age_hours"] as? Int, 96)
        XCTAssertNil(ages["pumping_to_stash"])
    }

    /// "Use first" has to come before "throw away", in whole hours from zero.
    func testAgesCheck() {
        XCTAssertTrue(StashSettingsEdit.agesAreValid(warn: 48, max: 72))
        XCTAssertTrue(StashSettingsEdit.agesAreValid(warn: 0, max: 1))
        XCTAssertFalse(StashSettingsEdit.agesAreValid(warn: 72, max: 72))
        XCTAssertFalse(StashSettingsEdit.agesAreValid(warn: 80, max: 72))
        XCTAssertFalse(StashSettingsEdit.agesAreValid(warn: -1, max: 72))
    }

    /// The section exists only with the stash and the settings route on the root; a server without
    /// the route (or the stash) also drops the cached settings.
    func testDetection() {
        StashCapability.update(rootJSON: Data(
            #"{"parents": "x", "stash-adjustments": "x", "stash": "x", "stash/settings": "x"}"#.utf8))
        XCTAssertTrue(StashCapability.hasSettings)
        StashCapability.store(settings: defaults)

        StashCapability.update(rootJSON: Data(#"{"parents": "x", "stash-adjustments": "x", "stash": "x"}"#.utf8))
        XCTAssertTrue(StashCapability.isSupported)
        XCTAssertFalse(StashCapability.hasSettings, "An older stash server")
        XCTAssertNil(StashCapability.settings)

        StashCapability.update(rootJSON: Data(#"{"stash/settings": "x"}"#.utf8))
        XCTAssertFalse(StashCapability.hasSettings, "No settings without the stash")
    }

    /// The last settings are cached for offline, and sign-out forgets them with the rest.
    func testCacheAndReset() {
        StashCapability.update(rootJSON: Data(
            #"{"parents": "x", "stash-adjustments": "x", "stash": "x", "stash/settings": "x"}"#.utf8))
        StashCapability.store(settings: defaults)
        XCTAssertEqual(StashCapability.settings, defaults)
        StashCapability.store(settings: nil)
        XCTAssertNil(StashCapability.settings)

        StashCapability.store(settings: defaults)
        StashCapability.reset()
        XCTAssertNil(StashCapability.settings)
        XCTAssertFalse(StashCapability.hasSettings)
    }

    #if DEBUG
    /// Demo mode keeps a change in memory, and its stash summary follows the settings.
    func testDemoSettings() {
        let before = DemoData.demoStashSettings
        defer { DemoData.demoStashSettings = before }
        let after = DemoData.patchDemoStashSettings(["pumping_to_stash": false, "warn_age_hours": 24])
        XCTAssertFalse(after.pumping_to_stash)
        XCTAssertEqual(after.warn_age_hours, 24)
        XCTAssertEqual(after.max_age_hours, before.max_age_hours)
        XCTAssertEqual(DemoData.demoStashSettings, after)

        let summary = DemoData.demoStashSummary(entities: [], now: .now, settings: after)
        XCTAssertEqual(summary.warn_age_hours, 24)
        XCTAssertFalse(summary.defaults.pumping_to_stash)
    }
    #endif
}

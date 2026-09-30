import Foundation

/// Whether the connected server has the milk stash, and the last stash summary it returned.
/// The server is authoritative for milk age: the app syncs only a recent window of entries, so it
/// can't run FIFO over the whole history itself. Kept in the App Group's defaults so the widgets
/// can read it too.
enum StashCapability {
    private static let supportedKey = "stashSupported"
    private static let summaryKey = "stashSummary"
    private static let settingsSupportedKey = "stashSettingsSupported"
    private static let settingsKey = "stashSettings"
    /// Whether the negative-balance warning was dismissed. It belongs to the server's stash, so
    /// ``reset()`` forgets it with the rest.
    static let negativeWarningDismissedKey = "stashNegativeWarningDismissed"

    /// The API root keys a server with the milk stash lists.
    static let rootKeys = ["parents", "stash-adjustments", "stash"]

    static var isSupported: Bool { SharedDefaults.suite.bool(forKey: supportedKey) }

    /// The API root key of the stash settings. Older stash servers don't list it.
    static let settingsRootKey = "stash/settings"

    /// Whether the server has the stash and its settings route: the Settings section's condition.
    static var hasSettings: Bool {
        isSupported && SharedDefaults.suite.bool(forKey: settingsSupportedKey)
    }

    /// The last stash settings the server returned, shown (read-only) while offline.
    static var settings: StashSettingsDTO? {
        guard let data = SharedDefaults.suite.data(forKey: settingsKey) else { return nil }
        return try? JSONDecoder().decode(StashSettingsDTO.self, from: data)
    }

    /// Cache the settings from `GET` or `PATCH /api/stash/settings`, or clear them with `nil`.
    static func store(settings: StashSettingsDTO?) {
        if let settings, let data = try? JSONEncoder().encode(settings) {
            SharedDefaults.suite.set(data, forKey: settingsKey)
        } else {
            SharedDefaults.suite.removeObject(forKey: settingsKey)
        }
    }

    static var summary: StashSummaryDTO? {
        guard let data = SharedDefaults.suite.data(forKey: summaryKey) else { return nil }
        return try? APICoders.decoder.decode(StashSummaryDTO.self, from: data)
    }

    /// Set the flag from the `GET /api/` root response. A server without the stash also drops any
    /// cached summary.
    static func update(rootJSON: Data) {
        let root = (try? JSONSerialization.jsonObject(with: rootJSON)) as? [String: Any] ?? [:]
        let supported = rootKeys.allSatisfy { root[$0] != nil }
        SharedDefaults.suite.set(supported, forKey: supportedKey)
        let hasSettings = supported && root[settingsRootKey] != nil
        SharedDefaults.suite.set(hasSettings, forKey: settingsSupportedKey)
        if !supported { store(summary: nil) }
        if !hasSettings { store(settings: nil) }
    }

    /// Cache the summary from `GET /api/stash`, or clear it with `nil`.
    static func store(summary: StashSummaryDTO?) {
        if let summary, summary.balance >= 0 {
            // Back at or above zero: the next dip shows the warning again.
            SharedDefaults.suite.removeObject(forKey: negativeWarningDismissedKey)
        }
        if let summary, let data = try? APICoders.encoder.encode(summary) {
            SharedDefaults.suite.set(data, forKey: summaryKey)
        } else {
            SharedDefaults.suite.removeObject(forKey: summaryKey)
        }
    }

    /// Forget all of it (the flags, the summary and the settings) and a dismissed negative-balance
    /// warning, e.g. on sign-out, so the next server starts from "not supported" and shows its own
    /// warning.
    static func reset() {
        SharedDefaults.suite.removeObject(forKey: supportedKey)
        SharedDefaults.suite.removeObject(forKey: summaryKey)
        SharedDefaults.suite.removeObject(forKey: settingsSupportedKey)
        SharedDefaults.suite.removeObject(forKey: settingsKey)
        SharedDefaults.suite.removeObject(forKey: negativeWarningDismissedKey)
    }
}

import Foundation

/// Whether the connected server has the milk stash, and the last stash summary it returned.
/// The server is authoritative for milk age: the app syncs only a recent window of entries, so it
/// can't run FIFO over the whole history itself. Kept in the App Group's defaults so the widgets
/// can read it too.
enum StashCapability {
    private static let supportedKey = "stashSupported"
    private static let summaryKey = "stashSummary"

    /// The API root keys a server with the milk stash lists.
    static let rootKeys = ["parents", "stash-adjustments", "stash"]

    static var isSupported: Bool { SharedDefaults.suite.bool(forKey: supportedKey) }

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
        if !supported { store(summary: nil) }
    }

    /// Cache the summary from `GET /api/stash`, or clear it with `nil`.
    static func store(summary: StashSummaryDTO?) {
        if let summary, let data = try? APICoders.encoder.encode(summary) {
            SharedDefaults.suite.set(data, forKey: summaryKey)
        } else {
            SharedDefaults.suite.removeObject(forKey: summaryKey)
        }
    }

    /// Forget both, e.g. on sign-out, so the next server starts from "not supported".
    static func reset() {
        SharedDefaults.suite.removeObject(forKey: supportedKey)
        SharedDefaults.suite.removeObject(forKey: summaryKey)
    }
}

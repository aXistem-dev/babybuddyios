import Foundation

/// Whether the connected server has the milk stash, and the last stash summary it returned. Kept in
/// the App Group's defaults so the widgets can read it too.
enum StashCapability {
    private static let supportedKey = "stashSupported"
    private static let summaryKey = "stashSummary"

    /// The phone's last choice of "Into the milk stash" on pumping and "From the milk stash" on a
    /// bottle, which the next one starts with (`UserDefaults.standard`).
    static let pumpingToStashKey = "pumpingToStash"
    static let bottleFromStashKey = "bottleFromStash"

    /// Whether a feed can come from the milk stash, as the server checks it: breast milk or
    /// fortified breast milk, not fed at the breast, with an amount.
    static func canComeFromStash(type: FeedingType, method: FeedingMethod, amount: Double?) -> Bool {
        [.breastMilk, .fortifiedBreastMilk].contains(type)
            && ![.leftBreast, .rightBreast, .bothBreasts].contains(method)
            && (amount ?? 0) > 0
    }

    /// The API root keys a server with the milk stash lists.
    static let rootKeys = ["stash-adjustments", "stash"]

    static var isSupported: Bool { SharedDefaults.suite.bool(forKey: supportedKey) }

    static var summary: StashSummaryDTO? {
        guard let data = SharedDefaults.suite.data(forKey: summaryKey) else { return nil }
        return try? APICoders.decoder.decode(StashSummaryDTO.self, from: data)
    }

    /// Whether the `GET /api/` root lists the stash routes.
    static func listsStash(rootJSON: Data) -> Bool {
        let root = (try? JSONSerialization.jsonObject(with: rootJSON)) as? [String: Any] ?? [:]
        return rootKeys.allSatisfy { root[$0] != nil }
    }

    /// Record the stash as available with this summary, or, with `nil`, as not available (a server
    /// without it, or a user it refuses the stash to) and drop the cached summary.
    static func store(summary: StashSummaryDTO?) {
        if let summary, let data = try? APICoders.encoder.encode(summary) {
            SharedDefaults.suite.set(true, forKey: supportedKey)
            SharedDefaults.suite.set(data, forKey: summaryKey)
        } else {
            reset()
        }
    }

    /// Forget all of it, e.g. on sign-out, so the next server starts from "not supported".
    static func reset() {
        SharedDefaults.suite.removeObject(forKey: supportedKey)
        SharedDefaults.suite.removeObject(forKey: summaryKey)
    }
}

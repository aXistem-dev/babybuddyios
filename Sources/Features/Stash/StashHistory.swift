import Foundation

/// The milk stash's records on this phone, for the stash screen. Pure, so it's testable without a
/// view.
enum StashHistory {
    /// The cached record a lot came from, if this phone has it: a lot older than the synced window,
    /// or one from a server that doesn't say, has none.
    static func record(for source: StashLotSourceDTO?, in entities: [LocalEntity]) -> LocalEntity? {
        guard let source else { return nil }
        let kind: EntityKind
        switch source.type {
        case "pumping": kind = .pumping
        case "stash_adjustment": kind = .stashAdjustment
        default: return nil
        }
        return entities.first { $0.kind == kind && $0.serverID == source.id && $0.syncState != .pendingDelete }
    }
}

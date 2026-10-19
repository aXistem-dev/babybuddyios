import Foundation

/// The milk stash's records on this phone, for the stash screen. Pure, so it's testable without a
/// view.
enum StashHistory {
    /// Milk into or out of the stash, as one of this phone's records says.
    struct Movement: Identifiable {
        enum Kind: Equatable {
            case pumping, bottle, added, discarded

            var label: String {
                switch self {
                case .pumping: return "Pumping"
                case .bottle: return "Bottle"
                case .added: return "Added"
                case .discarded: return "Discarded"
                }
            }
        }

        let record: LocalEntity
        let kind: Kind
        let time: Date
        let amount: Double

        var id: UUID { record.localID }
        var isIn: Bool { kind == .pumping || kind == .added }
        /// Only milk added or discarded by hand is deleted from the stash's own list: a pumping or a
        /// bottle is a record of its own, deleted from its editor.
        var isDeletableHere: Bool { kind == .added || kind == .discarded }
        /// "+160 ml" or "−40 ml".
        var signedAmount: String { (isIn ? "+" : "\u{2212}") + EntityFormatting.formatAmount(amount) }
    }

    /// The newest `limit` movements, newest first, from the records the phone has synced, as the
    /// server counts them: a milk stash entry at its time, a pumping into the stash at its end, and a
    /// bottle from the stash (with an amount) at its start. At the same time, milk in counts before
    /// milk out, as on the server, so in this newest-first list the out comes first. Records being
    /// deleted are left out.
    static func movements(in entities: [LocalEntity], limit: Int = 10) -> [Movement] {
        let all = entities.compactMap { entity -> Movement? in
            guard entity.syncState != .pendingDelete else { return nil }
            let p = entity.payloadObject
            let amount = p["amount"] as? Double ?? 0
            switch entity.kind {
            case .stashAdjustment:
                guard amount > 0 else { return nil }
                let kind: Movement.Kind = p["kind"] as? String == StashKind.discarded.rawValue ? .discarded : .added
                return Movement(record: entity, kind: kind, time: entity.timestamp, amount: amount)
            case .pumping:
                guard p["to_stash"] as? Bool == true, amount > 0,
                      let end = (p["end"] as? String).flatMap(APIDate.parse) else { return nil }
                return Movement(record: entity, kind: .pumping, time: end, amount: amount)
            case .feeding:
                guard p["from_stash"] as? Bool == true, amount > 0 else { return nil }
                return Movement(record: entity, kind: .bottle, time: entity.timestamp, amount: amount)
            default:
                return nil
            }
        }
        let chronological = all.sorted {
            $0.time != $1.time ? $0.time < $1.time : ($0.isIn && !$1.isIn)
        }
        return Array(chronological.reversed().prefix(limit))
    }

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

import Foundation

/// Which cached records a child's views show. Most records carry their child, but on a server with
/// the milk stash some belong to a parent instead: pumping logged on a parent has `child: null`, and
/// stash adjustments have no child at all. Those show for every child linked to that parent, so
/// they never vanish from the app.
///
/// SwiftData predicates can't look inside the JSON payload, so the views fetch these records
/// broadly (by kind, with no child) and apply ``isVisible(_:forChild:parentIDs:)`` in memory.
enum EntityVisibility {
    /// The ids of the parents linked to `child`: those whose `children` list includes it. A parent
    /// created on this device has no `serverID` yet, so its payload `id` is read first.
    static func parentIDs(forChild child: Int, in entities: [LocalEntity]) -> Set<Int> {
        var ids = Set<Int>()
        for entity in entities where entity.kind == .parent {
            let payload = entity.payloadObject
            guard let id = (payload["id"] as? Int) ?? entity.serverID,
                  let children = payload["children"] as? [Int], children.contains(child)
            else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// Whether `entity` shows in `child`'s views, given the ids of the parents linked to that child
    /// (``parentIDs(forChild:in:)``):
    /// - a record of this child is visible (pumping logged on a child included);
    /// - pumping with no child is visible when its `parent` is linked to this child;
    /// - a stash adjustment is visible under the same rule, and for every child when it has no
    ///   parent, since the stash is shared. It belongs in the timeline only: other views leave the
    ///   kind out, and the timeline shows it only when the server has the milk stash;
    /// - a parent is never visible: it's metadata, not an event.
    static func isVisible(_ entity: LocalEntity, forChild child: Int, parentIDs: Set<Int>) -> Bool {
        let kind = entity.kind
        if kind == .parent { return false }
        if let owner = entity.childID { return owner == child }
        let parent = entity.payloadObject["parent"] as? Int
        switch kind {
        case .pumping:
            guard let parent else { return false }
            return parentIDs.contains(parent)
        case .stashAdjustment:
            guard let parent else { return true }
            return parentIDs.contains(parent)
        default:
            return false
        }
    }
}

/// The parents who produce breast milk (`produces_milk`), the only ones a server with the milk stash
/// takes as who pumped, who breastfed or whose milk. A parent synced before the server sent the flag
/// produces milk, as the server's default says. With exactly one, the server fills that parent in
/// wherever one is needed, so the app hides every parent picker and name.
enum MilkParents {
    /// A cached parent, as the parent pickers and the stash screen list it.
    struct Parent: Equatable {
        let id: Int
        let name: String
        let producesMilk: Bool
        /// The children this parent is linked to.
        let children: [Int]
    }

    /// Every cached parent that isn't being deleted, by first name. A parent created on this device
    /// has no `serverID` yet, so its payload `id` is read first.
    static func all(in entities: [LocalEntity]) -> [Parent] {
        entities.compactMap { entity -> Parent? in
            guard entity.kind == .parent, entity.syncState != .pendingDelete else { return nil }
            let p = entity.payloadObject
            guard let id = (p["id"] as? Int) ?? entity.serverID else { return nil }
            return Parent(id: id, name: p["first_name"] as? String ?? "",
                          producesMilk: p["produces_milk"] as? Bool ?? true,
                          children: p["children"] as? [Int] ?? [])
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The parents a picker offers: those who produce milk, and `current`, an entry's own saved
    /// parent, so an entry from before its parent stopped producing milk stays editable (the server
    /// takes that one back, and refuses any other parent who doesn't produce milk).
    static func choices(_ parents: [Parent], keeping current: Int?) -> [Parent] {
        parents.filter { $0.producesMilk || $0.id == current }
    }

    /// The only parent who produces milk; nil with none or several.
    static func single(_ parents: [Parent]) -> Parent? {
        let milk = parents.filter(\.producesMilk)
        return milk.count == 1 ? milk.first : nil
    }

    /// Whether parents are told apart by name: only with several who produce milk.
    static func showsNames(_ parents: [Parent]) -> Bool {
        parents.filter(\.producesMilk).count > 1
    }
}

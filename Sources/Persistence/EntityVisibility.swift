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

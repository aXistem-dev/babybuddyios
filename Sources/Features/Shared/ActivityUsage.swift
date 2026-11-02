import Foundation

/// Which activity types the Add Activity sheet puts first, from the synced activities.
/// Pure, so the ranking is testable without a view.
enum ActivityUsage {
    /// How far back "most used" looks: the app's pull window, so every counted activity is synced.
    static let usageDays = 30

    /// Up to `limit` of the active `types`, most used first: the number of `child`'s activities of
    /// each type in the last ``usageDays`` days up to `now`. A tie goes to the type used most
    /// recently, then to the server's order; types not used at all fill the rest in that order.
    /// Deleted activities don't count, and inactive types are left out.
    static func topTypes(activities: [LocalEntity], types: [ActivitiesCapability.TypeInfo], child: Int,
                         now: Date, limit: Int = 5,
                         calendar: Calendar = .current) -> [ActivitiesCapability.TypeInfo] {
        let since = calendar.date(byAdding: .day, value: -usageDays, to: now) ?? now
        var counts: [Int: Int] = [:]
        var lastUse: [Int: Date] = [:]
        for activity in activities where activity.kind == .activity && activity.childID == child
            && activity.syncState != .pendingDelete && activity.timestamp >= since && activity.timestamp <= now {
            guard let type = activity.payloadObject["type"] as? Int else { continue }
            counts[type, default: 0] += 1
            if lastUse[type].map({ activity.timestamp > $0 }) ?? true { lastUse[type] = activity.timestamp }
        }
        let ordered = ActivitiesCapability.sorted(types.filter(\.active))
        let position = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
        let ranked = ordered.sorted { a, b in
            let ca = counts[a.id] ?? 0, cb = counts[b.id] ?? 0
            if ca != cb { return ca > cb }
            let la = lastUse[a.id] ?? .distantPast, lb = lastUse[b.id] ?? .distantPast
            if la != lb { return la > lb }
            return position[a.id, default: 0] < position[b.id, default: 0]
        }
        return Array(ranked.prefix(limit))
    }
}

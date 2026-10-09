import Foundation

/// Which event types the Add Activity sheet puts first, from the synced events.
/// Pure, so the ranking is testable without a view.
enum EventUsage {
    /// How far back "most used" looks: the app's pull window, so every counted event is synced.
    static let usageDays = 30

    /// Up to `limit` event types, most used first: the number of `child`'s events of each type in
    /// the last ``usageDays`` days up to `now`. A tie goes to the type used most recently, then to the
    /// name; types not used at all fill the rest in name order. Deleted events don't count.
    static func topTypes(events: [LocalEntity], types: [EntityEditorView.EventTypeChoice], child: Int,
                         now: Date, limit: Int = 5,
                         calendar: Calendar = .current) -> [EntityEditorView.EventTypeChoice] {
        let since = calendar.date(byAdding: .day, value: -usageDays, to: now) ?? now
        var counts: [String: Int] = [:]
        var lastUse: [String: Date] = [:]
        for event in events where event.kind == .event && event.childID == child
            && event.syncState != .pendingDelete && event.timestamp >= since && event.timestamp <= now {
            guard let slug = event.payloadObject["type"] as? String else { continue }
            counts[slug, default: 0] += 1
            if lastUse[slug].map({ event.timestamp > $0 }) ?? true { lastUse[slug] = event.timestamp }
        }
        let ranked = types.sorted { a, b in
            let ca = counts[a.slug] ?? 0, cb = counts[b.slug] ?? 0
            if ca != cb { return ca > cb }
            let la = lastUse[a.slug] ?? .distantPast, lb = lastUse[b.slug] ?? .distantPast
            if la != lb { return la > lb }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return Array(ranked.prefix(limit))
    }
}

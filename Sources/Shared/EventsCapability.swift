import Foundation

/// Whether the connected server has events (user-defined event types, and events of those types
/// logged on a child), and the event types' names by slug. Kept in the App Group's defaults, like
/// ``StashCapability``, so a row can name an event without a store lookup. The types are the
/// server's data: the app never names or special-cases any of them.
enum EventsCapability {
    /// Public so views can watch the flag with `@AppStorage` and redraw when a sync turns it on.
    static let supportedKey = "eventsSupported"
    private static let typeNamesKey = "eventTypeNames"

    /// The API root keys a server with events lists.
    static let rootKeys = ["event-types", "events"]

    static var isSupported: Bool { SharedDefaults.suite.bool(forKey: supportedKey) }

    /// Set the flag from the `GET /api/` root response. A server without events also drops the
    /// cached type names.
    static func update(rootJSON: Data) {
        let root = (try? JSONSerialization.jsonObject(with: rootJSON)) as? [String: Any] ?? [:]
        let supported = rootKeys.allSatisfy { root[$0] != nil }
        SharedDefaults.suite.set(supported, forKey: supportedKey)
        if !supported { store(typeNames: [:]) }
    }

    /// The event types' names by slug, as last cached.
    static var typeNames: [String: String] {
        SharedDefaults.suite.dictionary(forKey: typeNamesKey) as? [String: String] ?? [:]
    }

    /// Cache the names of the event types in `entities` (the cached `.eventType` records), keyed by
    /// slug; types being deleted are left out.
    static func store(typesIn entities: [LocalEntity]) {
        var names: [String: String] = [:]
        for entity in entities where entity.kind == .eventType && entity.syncState != .pendingDelete {
            let p = entity.payloadObject
            guard let slug = p["slug"] as? String, !slug.isEmpty else { continue }
            names[slug] = p["name"] as? String ?? slug
        }
        store(typeNames: names)
    }

    static func store(typeNames: [String: String]) {
        if typeNames.isEmpty {
            SharedDefaults.suite.removeObject(forKey: typeNamesKey)
        } else {
            SharedDefaults.suite.set(typeNames, forKey: typeNamesKey)
        }
    }

    /// An event type's name; its slug for a type this phone hasn't synced (or one without a name).
    static func name(forSlug slug: String) -> String {
        guard let name = typeNames[slug], !name.isEmpty else { return slug }
        return name
    }

    /// When `child` last had an event of each type (by slug) among `entities`; a type with none is
    /// missing from the result. Events being deleted don't count.
    static func lastTimes(in entities: [LocalEntity], child: Int) -> [String: Date] {
        var last: [String: Date] = [:]
        for entity in entities where entity.kind == .event && entity.childID == child
            && entity.syncState != .pendingDelete {
            guard let slug = entity.payloadObject["type"] as? String else { continue }
            if let seen = last[slug], seen >= entity.timestamp { continue }
            last[slug] = entity.timestamp
        }
        return last
    }

    /// Forget both, e.g. on sign-out, so the next server starts from "no events".
    static func reset() {
        SharedDefaults.suite.removeObject(forKey: supportedKey)
        SharedDefaults.suite.removeObject(forKey: typeNamesKey)
    }
}

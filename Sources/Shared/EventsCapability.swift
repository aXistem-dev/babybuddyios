import Foundation

/// Whether the connected server has events (user-defined event types, and events of those types
/// logged on a child), and the event types' names by slug. Kept in the App Group's defaults, like
/// ``StashCapability``, so a row can name an event without a store lookup. The types are the
/// server's data: the app never names or special-cases any of them.
enum EventsCapability {
    /// Public so views can watch the flag with `@AppStorage` and redraw when a sync turns it on.
    static let supportedKey = "eventsSupported"
    private static let typeNamesKey = "eventTypeNames"
    private static let typeEmojiKey = "eventTypeEmoji"
    /// Public so Settings can watch it with `@AppStorage` and show Event types once a sync allows it.
    static let permissionsKey = "eventTypePermissions"

    /// The API root keys a server with events lists.
    static let rootKeys = ["event-types", "events"]

    static var isSupported: Bool { SharedDefaults.suite.bool(forKey: supportedKey) }

    /// Set the flag from the `GET /api/` root response. A server without events also drops the
    /// cached type names, emoji and permissions.
    static func update(rootJSON: Data) {
        let root = (try? JSONSerialization.jsonObject(with: rootJSON)) as? [String: Any] ?? [:]
        let supported = rootKeys.allSatisfy { root[$0] != nil }
        SharedDefaults.suite.set(supported, forKey: supportedKey)
        if !supported {
            store(typeNames: [:])
            SharedDefaults.suite.removeObject(forKey: typeEmojiKey)
            SharedDefaults.suite.removeObject(forKey: permissionsKey)
        }
    }

    /// The event types' names by slug, as last cached.
    static var typeNames: [String: String] {
        SharedDefaults.suite.dictionary(forKey: typeNamesKey) as? [String: String] ?? [:]
    }

    /// Cache the names and emoji of the event types in `entities` (the cached `.eventType`
    /// records), keyed by slug; types being deleted are left out.
    static func store(typesIn entities: [LocalEntity]) {
        var names: [String: String] = [:]
        var emoji: [String: String] = [:]
        for entity in entities where entity.kind == .eventType && entity.syncState != .pendingDelete {
            let p = entity.payloadObject
            guard let slug = p["slug"] as? String, !slug.isEmpty else { continue }
            names[slug] = p["name"] as? String ?? slug
            if let e = p["emoji"] as? String, !e.isEmpty { emoji[slug] = e }
        }
        store(typeNames: names)
        if emoji.isEmpty {
            SharedDefaults.suite.removeObject(forKey: typeEmojiKey)
        } else {
            SharedDefaults.suite.set(emoji, forKey: typeEmojiKey)
        }
    }

    /// The event types' emoji by slug, as last cached; types without one are missing.
    static var typeEmoji: [String: String] {
        SharedDefaults.suite.dictionary(forKey: typeEmojiKey) as? [String: String] ?? [:]
    }

    /// An event type's emoji, by slug; nil when it has none (its SF Symbol shows instead).
    static func emoji(forSlug slug: String) -> String? {
        let emoji = typeEmoji[slug]
        return emoji?.isEmpty == false ? emoji : nil
    }

    /// What the signed-in user may do with event types, as the server says on its type list. The
    /// app never works this out itself.
    struct Permissions: Codable, Equatable {
        var add = false
        var change = false
        var delete = false
        /// May delete a type together with its events (deleting both types and events); false on a
        /// server from before this flag.
        var deleteWithEvents = false

        /// Whether there's anything to manage at all.
        var any: Bool { add || change || delete }

        init(add: Bool = false, change: Bool = false, delete: Bool = false, deleteWithEvents: Bool = false) {
            self.add = add
            self.change = change
            self.delete = delete
            self.deleteWithEvents = deleteWithEvents
        }

        /// A flag missing from the cache (one written before it existed) reads as false.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            add = try c.decodeIfPresent(Bool.self, forKey: .add) ?? false
            change = try c.decodeIfPresent(Bool.self, forKey: .change) ?? false
            delete = try c.decodeIfPresent(Bool.self, forKey: .delete) ?? false
            deleteWithEvents = try c.decodeIfPresent(Bool.self, forKey: .deleteWithEvents) ?? false
        }
    }

    /// The last permissions the server sent; all false until then, and on an older server.
    static var permissions: Permissions {
        guard let data = SharedDefaults.suite.data(forKey: permissionsKey),
              let p = try? JSONDecoder().decode(Permissions.self, from: data) else { return Permissions() }
        return p
    }

    static func store(permissions: Permissions) {
        if let data = try? JSONEncoder().encode(permissions) {
            SharedDefaults.suite.set(data, forKey: permissionsKey)
        }
    }

    /// The type list's route, with the trailing slash the server's router expects. Without it the
    /// server redirects, and the redirect drops the token, so the request is refused.
    static let typeListPath = EntityKind.eventType.path + "/"

    /// The `permissions` object of a `GET /api/event-types/` page (the same on every page); all
    /// false when it's missing (an older server) or unreadable.
    static func permissions(fromListJSON data: Data) -> Permissions {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let p = root["permissions"] as? [String: Any] else { return Permissions() }
        return Permissions(add: p["add"] as? Bool ?? false, change: p["change"] as? Bool ?? false,
                           delete: p["delete"] as? Bool ?? false,
                           deleteWithEvents: p["delete_with_events"] as? Bool ?? false)
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

    /// Forget both, e.g. on sign-out, so the next server starts from "no events".
    static func reset() {
        SharedDefaults.suite.removeObject(forKey: supportedKey)
        SharedDefaults.suite.removeObject(forKey: typeNamesKey)
        SharedDefaults.suite.removeObject(forKey: typeEmojiKey)
        SharedDefaults.suite.removeObject(forKey: permissionsKey)
    }
}

extension LocalEntity {
    /// An event's type emoji, for its icon; nil for other records and types without one.
    var eventEmoji: String? {
        guard kind == .event, let slug = payloadObject["type"] as? String else { return nil }
        return EventsCapability.emoji(forSlug: slug)
    }
}

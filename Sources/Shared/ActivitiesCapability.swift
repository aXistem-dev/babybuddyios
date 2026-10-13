import Foundation

/// Whether the connected server has activities (user-defined activity types, and activities of
/// those types logged on a child), and what this phone last synced of the types. Kept in the App
/// Group's defaults, so a row can name an activity without a store lookup. The types are the
/// server's data: the app never names or special-cases any of them.
enum ActivitiesCapability {
    /// Public so views can watch the flag with `@AppStorage` and redraw when a sync turns it on.
    static let supportedKey = "activitiesSupported"
    /// Public so views can watch the cached types with `@AppStorage` and redraw on a rename.
    static let typesKey = "activityTypes"

    /// The API root keys a server with activities lists.
    static let rootKeys = ["activity-types", "activities"]

    static var isSupported: Bool { SharedDefaults.suite.bool(forKey: supportedKey) }

    /// Whether a `GET /api/` root response lists the activity routes.
    static func listsActivities(rootJSON: Data) -> Bool {
        let root = (try? JSONSerialization.jsonObject(with: rootJSON)) as? [String: Any] ?? [:]
        return rootKeys.allSatisfy { root[$0] != nil }
    }

    /// Set the flag from the `GET /api/` root response. A server without activities also drops the
    /// cached types.
    static func update(rootJSON: Data) {
        let supported = listsActivities(rootJSON: rootJSON)
        SharedDefaults.suite.set(supported, forKey: supportedKey)
        if !supported { SharedDefaults.suite.removeObject(forKey: typesKey) }
    }

    /// What a row needs to know about an activity type.
    struct TypeInfo: Codable, Equatable, Identifiable {
        var id: Int
        var name: String
        var icon: String
        var emoji: String
        var hasDuration: Bool
        var active: Bool
        var order: Int

        /// What the type's tile shows: its emoji, else its icon.
        var tileIcon: ActivityIcon { ActivityIcon(icon: icon, emoji: emoji) }

        /// A cached `.activityType` record's fields; nil for anything else, or a type without an id.
        init?(_ entity: LocalEntity) {
            guard entity.kind == .activityType, let id = entity.serverID else { return nil }
            self.init(id: id, payload: entity.payloadObject)
        }

        init(id: Int, payload p: [String: Any]) {
            self.id = id
            let name = p["name"] as? String ?? ""
            self.name = name.isEmpty ? "Activity" : name
            icon = p["icon"] as? String ?? ""
            emoji = p["emoji"] as? String ?? ""
            hasDuration = p["has_duration"] as? Bool ?? false
            active = p["active"] as? Bool ?? true
            order = p["order"] as? Int ?? 0
        }
    }

    /// The activity types as last cached, in the server's order (then by name).
    static var types: [TypeInfo] { types(from: SharedDefaults.suite.data(forKey: typesKey)) }

    static func types(from data: Data?) -> [TypeInfo] {
        data.flatMap { try? JSONDecoder().decode([TypeInfo].self, from: $0) } ?? []
    }

    /// The cached type with this id; nil for a type this phone hasn't synced.
    static func type(id: Int) -> TypeInfo? { types.first { $0.id == id } }

    /// Cache the activity types in `entities` (the cached `.activityType` records); types being
    /// deleted are left out.
    static func store(typesIn entities: [LocalEntity]) {
        let infos = sorted(entities.filter { $0.syncState != .pendingDelete }.compactMap(TypeInfo.init))
        if infos.isEmpty {
            SharedDefaults.suite.removeObject(forKey: typesKey)
        } else if let data = try? JSONEncoder().encode(infos) {
            SharedDefaults.suite.set(data, forKey: typesKey)
        }
    }

    /// In the server's order, then by name.
    static func sorted(_ types: [TypeInfo]) -> [TypeInfo] {
        types.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Forget all of it, e.g. on sign-out, so the next server starts from "no activities".
    static func reset() {
        SharedDefaults.suite.removeObject(forKey: supportedKey)
        SharedDefaults.suite.removeObject(forKey: typesKey)
    }
}

/// What an activity type's tile shows: its emoji, one of the app's own glyphs where the server's
/// icon name matches a record kind, or an SF Symbol for the rest of the server's icon list.
enum ActivityIcon: Equatable {
    case emoji(String)
    case glyph(EntityKind)
    case symbol(String)

    init(icon: String, emoji: String) {
        if !emoji.isEmpty {
            self = .emoji(emoji)
        } else if let kind = Self.glyphs[icon] {
            self = .glyph(kind)
        } else {
            self = .symbol(Self.symbols[icon] ?? EntityKind.activity.systemImage)
        }
    }

    /// The server's icon names that are one of the app's record kinds.
    static let glyphs: [String: EntityKind] = [
        "bmi": .bmi, "child": .child, "diaperchange": .change, "feeding": .feeding,
        "head-circumference": .headCircumference, "height": .height, "medication": .medication,
        "note": .note, "pumping": .pumping, "sleep": .sleep, "temperature": .temperature,
        "timer": .timer, "tummytime": .tummyTime, "weight": .weight,
    ]

    /// The rest of the server's icon names (`ACTIVITY_ICONS`), as SF Symbols. `activities`, the
    /// default, and any name the app doesn't know use the activity kind's own symbol.
    static let symbols: [String: String] = [
        "calendar": "calendar", "camera": "camera.fill", "chat": "bubble.left.fill",
        "clock": "clock.fill", "dashboard": "gauge.with.dots.needle.33percent",
        "graph": "chart.xyaxis.line", "list": "list.bullet", "lock": "lock.fill",
        "mail": "envelope.fill", "measurements": "ruler", "refresh": "arrow.clockwise",
        "sad": "cloud.drizzle.fill", "source": "chevron.left.forwardslash.chevron.right",
        "stop": "stop.fill", "tag": "tag.fill", "timeline": "clock.arrow.circlepath",
        "today": "sun.max.fill", "user": "person.fill",
    ]
}

extension LocalEntity {
    /// An activity's type, as last cached; nil for other records and types this phone hasn't synced.
    var activityType: ActivitiesCapability.TypeInfo? {
        guard kind == .activity, let id = payloadObject["type"] as? Int else { return nil }
        return ActivitiesCapability.type(id: id)
    }

    /// What this record's tile shows in place of its kind's glyph: an activity's type icon.
    var tileIcon: ActivityIcon? { activityType?.tileIcon }
}

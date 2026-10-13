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
    /// Public so Settings can watch it with `@AppStorage` and show Activity types once a sync allows it.
    static let permissionsKey = "activityTypePermissions"

    /// The API root keys a server with activities lists.
    static let rootKeys = ["activity-types", "activities"]

    static var isSupported: Bool { SharedDefaults.suite.bool(forKey: supportedKey) }

    /// Whether a `GET /api/` root response lists the activity routes.
    static func listsActivities(rootJSON: Data) -> Bool {
        let root = (try? JSONSerialization.jsonObject(with: rootJSON)) as? [String: Any] ?? [:]
        return rootKeys.allSatisfy { root[$0] != nil }
    }

    /// Set the flag from the `GET /api/` root response. A server without activities also drops the
    /// cached types and permissions.
    static func update(rootJSON: Data) {
        let supported = listsActivities(rootJSON: rootJSON)
        SharedDefaults.suite.set(supported, forKey: supportedKey)
        if !supported {
            SharedDefaults.suite.removeObject(forKey: typesKey)
            SharedDefaults.suite.removeObject(forKey: permissionsKey)
        }
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

    // MARK: Timers

    /// A timer's local `timerActivityRaw` for an activity type, so stopping it files straight to that
    /// type.
    static func timerActivityRaw(typeID: Int) -> String { "activity:\(typeID)" }

    /// The activity type a timer is timing: the one it was started for on this phone, else the active
    /// type with duration it's named after (as one started on another phone is). Nil for a type this
    /// phone doesn't have, or one without duration.
    static func timerType(of timer: LocalEntity) -> TypeInfo? {
        guard isSupported, timer.kind == .timer else { return nil }
        let types = self.types.filter(\.hasDuration)
        if let raw = timer.timerActivityRaw, raw.hasPrefix("activity:"), let id = Int(raw.dropFirst("activity:".count)) {
            return types.first { $0.id == id }
        }
        guard let name = timer.payloadObject["name"] as? String, !name.isEmpty else { return nil }
        return types.first { $0.active && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Permissions

    /// What the signed-in user may do with activity types, as the server says on its type list. The
    /// app never works this out itself.
    struct Permissions: Codable, Equatable {
        var add = false
        var change = false
        var delete = false
        /// May delete a type together with its activities.
        var deleteWithActivities = false

        /// Whether there's anything to manage at all.
        var any: Bool { add || change || delete }
    }

    /// The last permissions the server sent; all false until then.
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
    static let typeListPath = EntityKind.activityType.path + "/"

    /// The `permissions` object of a `GET /api/activity-types/` page (the same on every page); all
    /// false when it's missing or unreadable.
    static func permissions(fromListJSON data: Data) -> Permissions {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let p = root["permissions"] as? [String: Any] else { return Permissions() }
        return Permissions(add: p["add"] as? Bool ?? false, change: p["change"] as? Bool ?? false,
                           delete: p["delete"] as? Bool ?? false,
                           deleteWithActivities: p["delete_with_activities"] as? Bool ?? false)
    }

    /// Forget all of it, e.g. on sign-out, so the next server starts from "no activities".
    static func reset() {
        SharedDefaults.suite.removeObject(forKey: supportedKey)
        SharedDefaults.suite.removeObject(forKey: typesKey)
        SharedDefaults.suite.removeObject(forKey: permissionsKey)
    }
}

/// What an activity type's tile shows: its emoji, one of the app's own glyphs where the server's
/// icon name matches a record kind, or an SF Symbol for the rest of the server's icon list.
enum ActivityIcon: Equatable {
    case emoji(String)
    case glyph(EntityKind)
    case symbol(String)

    /// The server's icon names (`ACTIVITY_ICONS`), in its order, with their titles.
    static let serverIcons: [(name: String, title: String)] = [
        ("activities", "Activities"), ("bmi", "BMI"), ("calendar", "Calendar"), ("camera", "Camera"),
        ("chat", "Chat"), ("child", "Child"), ("clock", "Clock"), ("dashboard", "Dashboard"),
        ("diaperchange", "Diaper Change"), ("feeding", "Feeding"), ("graph", "Graph"),
        ("head-circumference", "Head Circumference"), ("height", "Height"), ("list", "List"),
        ("lock", "Lock"), ("mail", "Mail"), ("measurements", "Measurements"), ("medication", "Medication"),
        ("note", "Note"), ("pumping", "Pumping"), ("refresh", "Refresh"), ("sad", "Sad"), ("sleep", "Sleep"),
        ("source", "Source"), ("stop", "Stop"), ("tag", "Tag"), ("temperature", "Temperature"),
        ("timeline", "Timeline"), ("timer", "Timer"), ("today", "Today"), ("tummytime", "Tummy Time"),
        ("user", "User"), ("weight", "Weight"),
    ]

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

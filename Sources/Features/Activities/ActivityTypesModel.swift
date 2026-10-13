import Foundation
import Observation
import SwiftData

/// Managing the server's activity types: add, edit, delete. Only what the server's `permissions`
/// allow, and only online: a change is sent at once and never queued, so a stale one can't overwrite
/// a change made elsewhere meanwhile. The server's reply goes into the cache straight away, and a
/// sync follows.
@MainActor
@Observable
final class ActivityTypesModel {
    enum Status: Equatable {
        case idle
        case working
        /// The server couldn't be reached: the list is read-only.
        case offline
        /// The server refused a change; its reason, as it said it.
        case refused(String)
    }

    private(set) var status: Status = .idle

    /// A type the server wouldn't delete because activities use it, offered for deleting together
    /// with those activities once confirmed.
    struct Cascade: Identifiable {
        let type: LocalEntity
        let name: String
        let activityCount: Int
        var id: UUID { type.localID }
    }
    var pendingCascade: Cascade?

    /// Whether changes can be sent now (the permission itself is the server's `permissions`).
    var isOnline: Bool { status != .offline }

    /// Check the server is reachable and re-read what this user may do.
    func refresh(session: AppSession) async {
        #if DEBUG
        if session.isDemo { status = .idle; return }
        #endif
        guard let config = session.config else { status = .offline; return }
        do {
            let page = try await APIClient(config: config).getRawPath(ActivitiesCapability.typeListPath)
            ActivitiesCapability.store(permissions: ActivitiesCapability.permissions(fromListJSON: page))
            if status == .offline { status = .idle }
        } catch {
            status = .offline
        }
    }

    /// Add a type. Returns whether it worked, so the form can close.
    func create(_ fields: ActivityTypeFields, session: AppSession, context: ModelContext,
                sync: SyncEngine) async -> Bool {
        let body = fields.body
        return await send(session: session, context: context, sync: sync) { client in
            let data = try await client.createRaw(path: EntityKind.activityType.path,
                                                  body: try JSONSerialization.data(withJSONObject: body))
            LocalStore.upsertFromServer(data, kind: .activityType, in: context)
        } demo: {
            #if DEBUG
            DemoData.createDemoActivityType(body, in: context)
            #endif
        }
    }

    /// Change a type; only the fields that changed are sent. Its slug never changes.
    func update(_ type: LocalEntity, to fields: ActivityTypeFields, session: AppSession, context: ModelContext,
                sync: SyncEngine) async -> Bool {
        guard let id = type.serverID else { return false }
        let body = fields.changes(from: type.payloadObject)
        guard !body.isEmpty else { return true }
        return await send(session: session, context: context, sync: sync) { client in
            let data = try await client.patchRaw(path: EntityKind.activityType.path, id: id,
                                                 body: try JSONSerialization.data(withJSONObject: body))
            LocalStore.upsertFromServer(data, kind: .activityType, in: context)
        } demo: {
            #if DEBUG
            DemoData.updateDemoActivityType(type, with: body, in: context)
            #endif
        }
    }

    /// Delete a type. The server refuses one that activities still use: for a user it lets delete
    /// those activities too, that becomes ``pendingCascade`` to confirm; otherwise its reason shows.
    func delete(_ type: LocalEntity, session: AppSession, context: ModelContext, sync: SyncEngine) async -> Bool {
        guard let id = type.serverID else { return false }
        let name = type.payloadObject["name"] as? String ?? ""
        return await send(session: session, context: context, sync: sync, conflict: { conflict in
            if ActivityTypeFields.offersCascade(conflict, permissions: ActivitiesCapability.permissions),
               let count = conflict.activityCount {
                self.pendingCascade = Cascade(type: type, name: name, activityCount: count)
                self.status = .idle
            } else {
                self.status = .refused(conflict.message ?? ActivityTypeFields.inUseMessage)
            }
        }) { client in
            try await client.deleteInUse(path: EntityKind.activityType.path, id: id)
            context.delete(type)
        } demo: {
            #if DEBUG
            try DemoData.deleteDemoActivityType(type, in: context)
            #endif
        }
    }

    /// Delete a type and every activity of it, all or nothing on the server, once confirmed. The
    /// activities go from this phone too, so Home, the timeline and quick add stop showing them.
    func deleteWithActivities(_ type: LocalEntity, session: AppSession, context: ModelContext,
                              sync: SyncEngine) async -> Bool {
        pendingCascade = nil
        guard let id = type.serverID else { return false }
        return await send(session: session, context: context, sync: sync) { client in
            try await client.deleteInUse(path: EntityKind.activityType.path, id: id,
                                         query: [URLQueryItem(name: "delete_activities", value: "true")])
            Self.removeActivities(ofType: id, in: context)
            context.delete(type)
        } demo: {
            Self.removeActivities(ofType: id, in: context)
            context.delete(type)
        }
    }

    /// Drop this phone's copies of the activities of a deleted type.
    static func removeActivities(ofType id: Int, in context: ModelContext) {
        let kind = EntityKind.activity.rawValue
        let activities = (try? context.fetch(FetchDescriptor<LocalEntity>(
            predicate: #Predicate { $0.kindRaw == kind }))) ?? []
        for activity in activities where activity.payloadObject["type"] as? Int == id { context.delete(activity) }
    }

    /// Run a change against the server (or the demo's store), then refresh the cached types and sync.
    /// Errors set ``status``; returns whether the change went through.
    private func send(session: AppSession, context: ModelContext, sync: SyncEngine,
                      conflict: ((DeleteConflict) -> Void)? = nil,
                      server: (APIClient) async throws -> Void, demo: () throws -> Void) async -> Bool {
        status = .working
        do {
            #if DEBUG
            if session.isDemo {
                try demo()
                return finish(context: context, sync: sync)
            }
            #endif
            guard let config = session.config else { throw APIError.offline() }
            try await server(APIClient(config: config))
            return finish(context: context, sync: sync)
        } catch let refused as DeleteConflict {
            if let conflict {
                conflict(refused)
            } else {
                status = .refused(refused.message ?? "Baby Buddy didn\u{2019}t accept that.")
            }
            return false
        } catch let error as APIError {
            switch error {
            case .offline: status = .offline
            case .badRequest(_, let message, _):
                status = .refused(message ?? "Baby Buddy didn\u{2019}t accept that.")
            case .forbidden: status = .refused("You can\u{2019}t change activity types on this server.")
            default: status = .refused("Couldn\u{2019}t save the change. Try again.")
            }
            return false
        } catch {
            status = .refused("Couldn\u{2019}t save the change. Try again.")
            return false
        }
    }

    private func finish(context: ModelContext, sync: SyncEngine) -> Bool {
        try? context.save()
        let kind = EntityKind.activityType.rawValue
        let types = (try? context.fetch(FetchDescriptor<LocalEntity>(
            predicate: #Predicate { $0.kindRaw == kind }))) ?? []
        ActivitiesCapability.store(typesIn: types)
        status = .idle
        Task { await sync.sync() }
        return true
    }
}

/// An activity type's editable fields, and their rules, kept apart from the view so they can be
/// tested. The server picks a new type's colour; the app doesn't show it.
struct ActivityTypeFields: Equatable {
    /// The longest name the server takes.
    static let maxNameLength = 100

    var name = ""
    var emoji = ""
    var icon = "activities"
    var hasDuration = false
    var active = true

    init() {}

    /// A cached type's fields.
    init(payload p: [String: Any]) {
        name = p["name"] as? String ?? ""
        emoji = p["emoji"] as? String ?? ""
        icon = p["icon"] as? String ?? icon
        hasDuration = p["has_duration"] as? Bool ?? false
        active = p["active"] as? Bool ?? true
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why the name can't be saved, or nil.
    var nameProblem: String? {
        let name = Self.trimmed(name)
        if name.isEmpty { return "Enter a name." }
        if name.count > Self.maxNameLength { return "Use at most \(Self.maxNameLength) characters." }
        return nil
    }

    /// An emoji is one character (a `Character` is a whole grapheme, flags and skin tones included),
    /// or none. The server checks that it's an emoji.
    var emojiIsValid: Bool { Self.trimmed(emoji).count <= 1 }

    var isValid: Bool { nameProblem == nil && emojiIsValid }

    /// A new type's POST body.
    var body: [String: Any] {
        ["name": Self.trimmed(name), "emoji": Self.trimmed(emoji), "icon": icon,
         "has_duration": hasDuration, "active": active]
    }

    /// The PATCH body for a type whose payload is `current`: only the fields that changed.
    func changes(from current: [String: Any]) -> [String: Any] {
        let before = ActivityTypeFields(payload: current)
        var body: [String: Any] = [:]
        if Self.trimmed(name) != before.name { body["name"] = Self.trimmed(name) }
        if Self.trimmed(emoji) != before.emoji { body["emoji"] = Self.trimmed(emoji) }
        if icon != before.icon { body["icon"] = icon }
        if hasDuration != before.hasDuration { body["has_duration"] = hasDuration }
        if active != before.active { body["active"] = active }
        return body
    }

    static let inUseMessage = "This activity type is in use and can\u{2019}t be deleted."

    /// Whether a refused delete can become deleting the type with its activities: the server counted
    /// activities using it, and lets this user delete them too.
    static func offersCascade(_ conflict: DeleteConflict, permissions: ActivitiesCapability.Permissions) -> Bool {
        (conflict.activityCount ?? 0) > 0 && permissions.deleteWithActivities
    }

    /// The confirmation's title: `Delete "Name" and its 1 activity?`, or `… its N activities?`.
    static func cascadeTitle(name: String, activityCount: Int) -> String {
        let activities = activityCount == 1 ? "1 activity" : "\(activityCount) activities"
        return "Delete \u{201C}\(name)\u{201D} and its \(activities)?"
    }

    static let cascadeMessage = "Every activity of this type will be removed. This can\u{2019}t be undone."
}

import Foundation
import Observation
import SwiftData

/// Managing the server's event types: add, rename or change the emoji, delete. Only what the
/// server's `permissions` allow, and only online, like the stash settings: a change is sent at once
/// and never queued, so a stale one can't overwrite a change made elsewhere meanwhile. The server's
/// reply goes into the cache straight away, and a sync follows.
@MainActor
@Observable
final class EventTypesModel {
    enum Status: Equatable {
        case idle
        case working
        /// The server couldn't be reached: the list is read-only.
        case offline
        /// The server refused a change; its reason, as it said it.
        case refused(String)
    }

    private(set) var status: Status = .idle

    /// A type the server wouldn't delete because events use it, offered for deleting together with
    /// those events once confirmed.
    struct Cascade: Identifiable {
        let type: LocalEntity
        let name: String
        let eventCount: Int
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
            let page = try await APIClient(config: config).getRawPath(EventsCapability.typeListPath)
            EventsCapability.store(permissions: EventsCapability.permissions(fromListJSON: page))
            if status == .offline { status = .idle }
        } catch {
            status = .offline
        }
    }

    /// Add a type. Returns whether it worked, so the form can close.
    func create(name: String, emoji: String, session: AppSession, context: ModelContext,
                sync: SyncEngine) async -> Bool {
        let body: [String: Any] = ["name": EventTypeEdit.trimmed(name), "emoji": EventTypeEdit.trimmed(emoji)]
        return await send(session: session, context: context, sync: sync) { client in
            let data = try await client.createRaw(path: EntityKind.eventType.path,
                                                  body: try JSONSerialization.data(withJSONObject: body))
            LocalStore.upsertFromServer(data, kind: .eventType, in: context)
        } demo: {
            #if DEBUG
            DemoData.createDemoEventType(name: body["name"] as? String ?? "", emoji: body["emoji"] as? String ?? "",
                                         in: context)
            #endif
        }
    }

    /// Rename a type or change its emoji; only what changed is sent. Its slug never changes.
    func update(_ type: LocalEntity, name: String, emoji: String, session: AppSession, context: ModelContext,
                sync: SyncEngine) async -> Bool {
        guard let slug = type.payloadObject["slug"] as? String else { return false }
        let body = EventTypeEdit.changes(of: type.payloadObject, name: name, emoji: emoji)
        guard !body.isEmpty else { return true }
        return await send(session: session, context: context, sync: sync) { client in
            let data = try await client.patchRaw(path: EntityKind.eventType.path, lookup: slug,
                                                 body: try JSONSerialization.data(withJSONObject: body))
            LocalStore.upsertFromServer(data, kind: .eventType, in: context)
        } demo: {
            #if DEBUG
            DemoData.updateDemoEventType(type, with: body, in: context)
            #endif
        }
    }

    /// Delete a type. The server refuses one that events still use: for a user it lets delete those
    /// events too, that becomes ``pendingCascade`` to confirm; otherwise its reason shows.
    func delete(_ type: LocalEntity, session: AppSession, context: ModelContext, sync: SyncEngine) async -> Bool {
        guard let slug = type.payloadObject["slug"] as? String else { return false }
        let name = type.payloadObject["name"] as? String ?? slug
        return await send(session: session, context: context, sync: sync, conflict: { conflict in
            if EventTypeEdit.offersCascade(conflict, permissions: EventsCapability.permissions),
               let count = conflict.eventCount {
                self.pendingCascade = Cascade(type: type, name: name, eventCount: count)
                self.status = .idle
            } else {
                self.status = .refused(conflict.message ?? "This event type is in use and can\u{2019}t be deleted.")
            }
        }) { client in
            try await client.deleteRaw(path: EntityKind.eventType.path, lookup: slug)
            context.delete(type)
        } demo: {
            #if DEBUG
            try DemoData.deleteDemoEventType(type, in: context)
            #endif
        }
    }

    /// Delete a type and every event of it, all or nothing on the server, once confirmed. The events
    /// go from this phone too, so Home, the timeline and quick add stop showing them.
    func deleteWithEvents(_ type: LocalEntity, session: AppSession, context: ModelContext,
                          sync: SyncEngine) async -> Bool {
        pendingCascade = nil
        guard let slug = type.payloadObject["slug"] as? String else { return false }
        return await send(session: session, context: context, sync: sync) { client in
            try await client.deleteRaw(path: EntityKind.eventType.path, lookup: slug,
                                       query: [URLQueryItem(name: "delete_events", value: "true")])
            Self.removeEvents(ofType: slug, in: context)
            context.delete(type)
        } demo: {
            #if DEBUG
            Self.removeEvents(ofType: slug, in: context)
            context.delete(type)
            #endif
        }
    }

    /// Drop this phone's copies of the events of a deleted type.
    static func removeEvents(ofType slug: String, in context: ModelContext) {
        let kind = EntityKind.event.rawValue
        let events = (try? context.fetch(FetchDescriptor<LocalEntity>(
            predicate: #Predicate { $0.kindRaw == kind }))) ?? []
        for event in events where event.payloadObject["type"] as? String == slug { context.delete(event) }
    }

    /// Run a change against the server (or the demo's store), then refresh the cached names and emoji
    /// and sync. Errors set ``status``; returns whether the change went through.
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
            case .forbidden: status = .refused("You can\u{2019}t change event types on this server.")
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
        let kind = EntityKind.eventType.rawValue
        let types = (try? context.fetch(FetchDescriptor<LocalEntity>(
            predicate: #Predicate { $0.kindRaw == kind }))) ?? []
        EventsCapability.store(typesIn: types)
        status = .idle
        Task { await sync.sync() }
        return true
    }
}

/// The rules for an event type's name and emoji, kept apart from the view so they can be tested.
enum EventTypeEdit {
    /// The longest name the server takes.
    static let maxNameLength = 100

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why a name can't be saved, or nil.
    static func nameProblem(_ name: String) -> String? {
        let name = trimmed(name)
        if name.isEmpty { return "Enter a name." }
        if name.count > maxNameLength { return "Use at most \(maxNameLength) characters." }
        return nil
    }

    /// An emoji is one character (a `Character` is a whole grapheme, flags and skin tones included),
    /// or none. The server checks that it's an emoji.
    static func emojiIsValid(_ emoji: String) -> Bool {
        trimmed(emoji).count <= 1
    }

    /// Whether a refused delete can become deleting the type with its events: the server counted
    /// events using it, and lets this user delete them too.
    static func offersCascade(_ conflict: DeleteConflict, permissions: EventsCapability.Permissions) -> Bool {
        (conflict.eventCount ?? 0) > 0 && permissions.deleteWithEvents
    }

    /// The confirmation's title: `Delete "Name" and its 1 event?`, or `… its N events?`.
    static func cascadeTitle(name: String, eventCount: Int) -> String {
        let events = eventCount == 1 ? "1 event" : "\(eventCount) events"
        return "Delete \u{201C}\(name)\u{201D} and its \(events)?"
    }

    static let cascadeMessage = "Every event of this type will be removed. This can\u{2019}t be undone."

    /// The PATCH body for a type whose payload is `current`: only the name and emoji that changed.
    static func changes(of current: [String: Any], name: String, emoji: String) -> [String: Any] {
        var body: [String: Any] = [:]
        let name = trimmed(name), emoji = trimmed(emoji)
        if name != (current["name"] as? String ?? "") { body["name"] = name }
        if emoji != (current["emoji"] as? String ?? "") { body["emoji"] = emoji }
        return body
    }
}

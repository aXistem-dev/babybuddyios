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

    /// Delete a type. The server refuses one that events still use, and its reason shows.
    func delete(_ type: LocalEntity, session: AppSession, context: ModelContext, sync: SyncEngine) async -> Bool {
        guard let slug = type.payloadObject["slug"] as? String else { return false }
        return await send(session: session, context: context, sync: sync) { client in
            try await client.deleteRaw(path: EntityKind.eventType.path, lookup: slug)
            context.delete(type)
        } demo: {
            #if DEBUG
            try DemoData.deleteDemoEventType(type, in: context)
            #endif
        }
    }

    /// Run a change against the server (or the demo's store), then refresh the cached names and emoji
    /// and sync. Errors set ``status``; returns whether the change went through.
    private func send(session: AppSession, context: ModelContext, sync: SyncEngine,
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

    /// The PATCH body for a type whose payload is `current`: only the name and emoji that changed.
    static func changes(of current: [String: Any], name: String, emoji: String) -> [String: Any] {
        var body: [String: Any] = [:]
        let name = trimmed(name), emoji = trimmed(emoji)
        if name != (current["name"] as? String ?? "") { body["name"] = name }
        if emoji != (current["emoji"] as? String ?? "") { body["emoji"] = emoji }
        return body
    }
}

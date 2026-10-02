import XCTest
@testable import BabyBuddy

/// Events, on a server that has them: user-defined event types (data from the server, never named
/// by the app) and events of those types on a child, referenced by the type's slug.
@MainActor
final class EventsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func tearDown() async throws {
        EventsCapability.reset()
    }

    private func entity(_ kind: EntityKind, _ payload: [String: Any],
                        state: SyncState = .synced) -> LocalEntity {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return LocalEntity(kind: kind, serverID: payload["id"] as? Int, childID: kind.childID(from: payload),
                           timestamp: kind.timestamp(from: payload), payload: data, syncState: state)
    }

    private func iso(_ hoursAgo: Double) -> String {
        APIDate.isoDateTime.string(from: now.addingTimeInterval(-hoursAgo * 3600))
    }

    private func event(_ type: String, hoursAgo: Double, child: Int = 1,
                       state: SyncState = .synced) -> LocalEntity {
        entity(.event, ["child": child, "type": type, "time": iso(hoursAgo)], state: state)
    }

    private func type(_ id: Int, _ name: String, _ slug: String, state: SyncState = .synced) -> LocalEntity {
        entity(.eventType, ["id": id, "name": name, "slug": slug], state: state)
    }

    // MARK: API

    func testDTOsDecode() throws {
        let type = try APICoders.decoder.decode(EventTypeDTO.self, from: Data("""
        {"id": 3, "name": "Nail trim", "slug": "nail-trim"}
        """.utf8))
        XCTAssertEqual(type.slug, "nail-trim")
        XCTAssertEqual(type.name, "Nail trim")

        let event = try APICoders.decoder.decode(EventDTO.self, from: Data("""
        {"id": 9, "child": 1, "type": "nail-trim", "time": "2026-09-30T08:00:00+02:00",
         "notes": null, "tags": ["night"]}
        """.utf8))
        XCTAssertEqual(event.type, "nail-trim", "An event names its type by slug")
        XCTAssertEqual(event.time, APIDate.parse("2026-09-30T08:00:00+02:00"))
        XCTAssertNil(event.notes)
        XCTAssertEqual(event.tags, ["night"])
    }

    /// Events are windowed and time-stamped like notes (`date_min`/`date_max` on `time`) and show on
    /// the timeline; their types are metadata, pulled in full and never on the timeline.
    func testKinds() {
        XCTAssertEqual(EntityKind.event.path, "events")
        XCTAssertEqual(EntityKind.event.timeField, "time")
        XCTAssertEqual(EntityKind.event.rangeFilterParam, "date")
        XCTAssertTrue(EntityKind.event.isWindowed)
        XCTAssertEqual(EntityKind.eventType.path, "event-types")
        XCTAssertFalse(EntityKind.eventType.isWindowed)
        XCTAssertTrue(EntityKind.timelineKinds.contains(.event))
        XCTAssertFalse(EntityKind.timelineKinds.contains(.eventType))
    }

    // MARK: Payloads

    /// Several types at once make one event each, all at the identical time, with the child, notes
    /// and tags on every one; one type makes one.
    func testPayloadsShareTheirTime() {
        let time = iso(0)
        let two = EntityEditorView.eventPayloads(child: 1, types: ["nail-trim", "massage"], time: time,
                                                 notes: "Before bed", tags: ["night"])
        XCTAssertEqual(two.map { $0["type"] as? String }, ["massage", "nail-trim"], "Sorted by slug")
        for p in two {
            XCTAssertEqual(p["child"] as? Int, 1)
            XCTAssertEqual(p["time"] as? String, time)
            XCTAssertEqual(p["notes"] as? String, "Before bed")
            XCTAssertEqual(p["tags"] as? [String], ["night"])
        }

        let one = EntityEditorView.eventPayloads(child: 2, types: ["massage"], time: time, notes: "", tags: [])
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one.first?["child"] as? Int, 2)
        XCTAssertTrue(EntityEditorView.eventPayloads(child: 1, types: [], time: time, notes: "", tags: []).isEmpty)
    }

    /// An event needs at least one type, and like every time-stamped record no time in the future.
    func testValidation() {
        var draft = ActivityDraft(kind: .event)
        draft.now = now
        draft.time = now
        XCTAssertEqual(draft.problem, .eventTypeRequired)
        draft.eventTypeCount = 2
        XCTAssertNil(draft.problem)
        draft.time = now.addingTimeInterval(3600)
        XCTAssertEqual(draft.problem, .futureTimestamp)
    }

    // MARK: Types

    /// The editor lists the cached types by name, leaves out deleted ones, and keeps an edited
    /// event's own type (by its slug) when this phone hasn't synced it.
    func testTypeChoices() {
        let records = [type(1, "Nail trim", "nail-trim"), type(2, "Massage", "massage"),
                       type(3, "Gone", "gone", state: .pendingDelete)]
        XCTAssertEqual(EntityEditorView.eventTypeChoices(records, keeping: nil).map(\.slug), ["massage", "nail-trim"])
        XCTAssertEqual(EntityEditorView.eventTypeChoices(records, keeping: "unsynced").map(\.slug),
                       ["massage", "nail-trim", "unsynced"])
        XCTAssertEqual(EntityEditorView.eventTypeChoices(records, keeping: "massage").count, 2)
    }

    // MARK: Capability

    /// The API root turns events on only when it lists both routes; a server without them also
    /// drops the cached names. Sign-out forgets both.
    func testCapability() {
        EventsCapability.update(rootJSON: Data(#"{"event-types": "x", "events": "x"}"#.utf8))
        XCTAssertTrue(EventsCapability.isSupported)
        EventsCapability.store(typesIn: [type(1, "Massage", "massage"), type(2, "Gone", "gone", state: .pendingDelete)])
        XCTAssertEqual(EventsCapability.typeNames, ["massage": "Massage"])

        EventsCapability.update(rootJSON: Data(#"{"events": "x"}"#.utf8))
        XCTAssertFalse(EventsCapability.isSupported)
        XCTAssertTrue(EventsCapability.typeNames.isEmpty)

        EventsCapability.update(rootJSON: Data(#"{"event-types": "x", "events": "x"}"#.utf8))
        EventsCapability.store(typesIn: [type(1, "Massage", "massage")])
        EventsCapability.reset()
        XCTAssertFalse(EventsCapability.isSupported)
        XCTAssertTrue(EventsCapability.typeNames.isEmpty)
    }

    /// A row names an event by its type; a type this phone doesn't know yet by its slug.
    func testEventTitle() {
        EventsCapability.store(typeNames: ["massage": "Massage"])
        XCTAssertEqual(EntityFormatting.title(event("massage", hoursAgo: 1)), "Massage")
        XCTAssertEqual(EntityFormatting.title(event("unknown-type", hoursAgo: 1)), "unknown-type")
        XCTAssertEqual(EntityFormatting.title(entity(.event, ["child": 1, "time": iso(1)])), "Event")
        XCTAssertEqual(EntityFormatting.title(entity(.note, ["child": 1, "time": iso(1)])), "Note")
    }

    // MARK: v2: permissions route and most used

    private func choice(_ slug: String, _ name: String) -> EntityEditorView.EventTypeChoice {
        .init(slug: slug, name: name)
    }

    /// The type list (where the permissions come from) is asked for with its trailing slash: without
    /// it the server redirects, the redirect drops the token, and the permissions never arrive.
    func testTypeListPathHasTrailingSlash() {
        XCTAssertEqual(EventsCapability.typeListPath, "event-types/")
    }

    /// The most used types for the child over the last 30 days come first; a tie goes to the most
    /// recent use, then the name; unused types fill up to 5 by name; older events, other children's
    /// and deleted ones don't count.
    func testTopTypes() {
        let types = [choice("massage", "Massage"), choice("nail", "Nail trim"), choice("outfit", "Outfit change"),
                     choice("teeth", "Tooth brushing"), choice("sun", "Sunscreen"), choice("hair", "Haircut")]
        let events = [
            event("massage", hoursAgo: 50), event("massage", hoursAgo: 26),        // massage: 2
            event("nail", hoursAgo: 26), event("outfit", hoursAgo: 3),       // tie at 1: outfit is newer
            event("teeth", hoursAgo: 24 * 31), event("teeth", hoursAgo: 24 * 40), // older than 30 days
            event("sun", hoursAgo: 1, child: 2), event("sun", hoursAgo: 2, child: 2), // another child
            event("hair", hoursAgo: 1, state: .pendingDelete),               // being deleted
        ]
        let top = EventUsage.topTypes(events: events, types: types, child: 1, now: now)
        XCTAssertEqual(top.map(\.slug), ["massage", "outfit", "nail", "hair", "sun"])
        XCTAssertEqual(EventUsage.topTypes(events: events, types: types, child: 1, now: now, limit: 2).map(\.slug),
                       ["massage", "outfit"])

        // Same count and same last use: by name.
        let same = [event("sun", hoursAgo: 5), event("hair", hoursAgo: 5)]
        XCTAssertEqual(EventUsage.topTypes(events: same, types: types, child: 1, now: now, limit: 2).map(\.slug),
                       ["hair", "sun"])
        // Nothing used: the first 5 by name.
        XCTAssertEqual(EventUsage.topTypes(events: [], types: types, child: 1, now: now).map(\.slug),
                       ["hair", "massage", "nail", "outfit", "sun"])
    }

    // MARK: v2: emoji and permissions

    /// A type's emoji decodes when the server sends it, and is simply absent on an older server.
    func testEmojiDecodes() throws {
        let v2 = try APICoders.decoder.decode(EventTypeDTO.self, from: Data("""
        {"id": 1, "name": "Massage", "slug": "massage", "emoji": "\u{1F486}"}
        """.utf8))
        XCTAssertEqual(v2.emoji, "\u{1F486}")
        let v1 = try APICoders.decoder.decode(EventTypeDTO.self, from: Data("""
        {"id": 1, "name": "Massage", "slug": "massage"}
        """.utf8))
        XCTAssertNil(v1.emoji)
    }

    /// The type list's `permissions`, as the server says them; all false without the key (an older
    /// server) or when they can't be read.
    func testPermissionsFromList() {
        let list = Data(#"""
        {"count": 1, "next": null, "previous": null,
         "permissions": {"add": true, "change": true, "delete": false},
         "results": [{"id": 1, "name": "Massage", "slug": "massage", "emoji": ""}]}
        """#.utf8)
        XCTAssertEqual(EventsCapability.permissions(fromListJSON: list),
                       .init(add: true, change: true, delete: false))
        let older = Data(#"{"count": 0, "next": null, "previous": null, "results": []}"#.utf8)
        XCTAssertEqual(EventsCapability.permissions(fromListJSON: older), .init())
        XCTAssertFalse(EventsCapability.permissions(fromListJSON: older).any)
        XCTAssertEqual(EventsCapability.permissions(fromListJSON: Data("not json".utf8)), .init())
    }

    /// Emoji are cached by slug with the names; an event shows its type's, and a type without one
    /// (or a record that isn't an event) has none. Sign-out forgets them and the permissions.
    func testEmojiCacheAndReset() {
        EventsCapability.update(rootJSON: Data(#"{"event-types": "x", "events": "x"}"#.utf8))
        EventsCapability.store(typesIn: [
            entity(.eventType, ["id": 1, "name": "Massage", "slug": "massage", "emoji": "\u{1F486}"]),
            entity(.eventType, ["id": 2, "name": "Nail trim", "slug": "nail-trim", "emoji": ""]),
        ])
        EventsCapability.store(permissions: .init(add: true, change: false, delete: false))
        XCTAssertEqual(EventsCapability.emoji(forSlug: "massage"), "\u{1F486}")
        XCTAssertNil(EventsCapability.emoji(forSlug: "nail-trim"))
        XCTAssertEqual(event("massage", hoursAgo: 1).eventEmoji, "\u{1F486}")
        XCTAssertNil(event("nail-trim", hoursAgo: 1).eventEmoji)
        XCTAssertNil(entity(.note, ["child": 1, "time": iso(1)]).eventEmoji)
        XCTAssertTrue(EventsCapability.permissions.add)

        EventsCapability.reset()
        XCTAssertNil(EventsCapability.emoji(forSlug: "massage"))
        XCTAssertEqual(EventsCapability.permissions, .init())
    }

    // MARK: v2: managing types

    /// A name is needed, and at most 100 characters (the server's limit).
    func testTypeNameRules() {
        XCTAssertEqual(EventTypeEdit.nameProblem("  "), "Enter a name.")
        XCTAssertNil(EventTypeEdit.nameProblem(" Massage "))
        XCTAssertNil(EventTypeEdit.nameProblem(String(repeating: "a", count: 100)))
        XCTAssertNotNil(EventTypeEdit.nameProblem(String(repeating: "a", count: 101)))
    }

    /// One emoji or none: a `Character` is a whole grapheme, so an emoji made of several code points
    /// (a variation selector, a flag, a family, a skin tone) still counts as one.
    func testEmojiIsOneCharacter() {
        for ok in ["", " ", "\u{1F486}", "\u{2702}\u{FE0F}", "\u{1F1E7}\u{1F1EA}",
                   "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "\u{1F44D}\u{1F3FD}"] {
            XCTAssertTrue(EventTypeEdit.emojiIsValid(ok), ok)
        }
        XCTAssertFalse(EventTypeEdit.emojiIsValid("\u{1F486}\u{1F486}"))
        XCTAssertFalse(EventTypeEdit.emojiIsValid("ab"))
    }

    /// An edit sends only what changed, trimmed; the slug is never part of it.
    func testTypeChanges() {
        let current: [String: Any] = ["id": 1, "name": "Massage", "slug": "massage", "emoji": ""]
        XCTAssertTrue(EventTypeEdit.changes(of: current, name: " Massage ", emoji: "").isEmpty)
        let renamed = EventTypeEdit.changes(of: current, name: "Evening massage", emoji: "")
        XCTAssertEqual(renamed.count, 1)
        XCTAssertEqual(renamed["name"] as? String, "Evening massage")
        let emoji = EventTypeEdit.changes(of: current, name: "Massage", emoji: "\u{1F486}")
        XCTAssertEqual(emoji["emoji"] as? String, "\u{1F486}")
        XCTAssertNil(emoji["slug"])
    }

    // MARK: v2: deleting a type with its events

    /// `delete_with_events` decodes when the server sends it and is false on an older one; a cache
    /// written before the flag existed still reads, with it false.
    func testDeleteWithEventsPermission() throws {
        let list = Data(#"{"count": 0, "results": [], "permissions": {"add": true, "change": true, "delete": true, "delete_with_events": true}}"#.utf8)
        XCTAssertTrue(EventsCapability.permissions(fromListJSON: list).deleteWithEvents)
        let older = Data(#"{"count": 0, "results": [], "permissions": {"add": true, "change": true, "delete": true}}"#.utf8)
        XCTAssertFalse(EventsCapability.permissions(fromListJSON: older).deleteWithEvents)
        XCTAssertTrue(EventsCapability.permissions(fromListJSON: older).delete)

        let oldCache = Data(#"{"add": true, "change": false, "delete": true}"#.utf8)
        let decoded = try JSONDecoder().decode(EventsCapability.Permissions.self, from: oldCache)
        XCTAssertEqual(decoded, .init(add: true, change: false, delete: true, deleteWithEvents: false))
    }

    /// A refused delete carries the server's reason and, from a newer server, how many events use it.
    func testDeleteConflictDecodes() {
        let newer = DeleteConflict(from: Data(#"{"detail": "In use.", "event_count": 4}"#.utf8))
        XCTAssertEqual(newer, DeleteConflict(message: "In use.", eventCount: 4))
        let older = DeleteConflict(from: Data(#"{"detail": "In use."}"#.utf8))
        XCTAssertEqual(older, DeleteConflict(message: "In use.", eventCount: nil))
    }

    /// The confirmation is offered only when events use the type and the user may delete them too;
    /// otherwise the server's reason shows. Its title counts the events.
    func testCascadeOfferAndTitle() {
        let all = EventsCapability.Permissions(add: true, change: true, delete: true, deleteWithEvents: true)
        let noEvents = EventsCapability.Permissions(add: true, change: true, delete: true, deleteWithEvents: false)
        XCTAssertTrue(EventTypeEdit.offersCascade(.init(message: nil, eventCount: 2), permissions: all))
        XCTAssertFalse(EventTypeEdit.offersCascade(.init(message: nil, eventCount: 2), permissions: noEvents))
        XCTAssertFalse(EventTypeEdit.offersCascade(.init(message: nil, eventCount: 0), permissions: all))
        XCTAssertFalse(EventTypeEdit.offersCascade(.init(message: nil, eventCount: nil), permissions: all))

        XCTAssertEqual(EventTypeEdit.cascadeTitle(name: "Nail trim", eventCount: 1),
                       "Delete \u{201C}Nail trim\u{201D} and its 1 event?")
        XCTAssertEqual(EventTypeEdit.cascadeTitle(name: "Nail trim", eventCount: 4),
                       "Delete \u{201C}Nail trim\u{201D} and its 4 events?")
    }
}

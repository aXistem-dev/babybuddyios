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
        let two = EntityEditorView.eventPayloads(child: 1, types: ["nail-trim", "bath"], time: time,
                                                 notes: "Before bed", tags: ["night"])
        XCTAssertEqual(two.map { $0["type"] as? String }, ["bath", "nail-trim"], "Sorted by slug")
        for p in two {
            XCTAssertEqual(p["child"] as? Int, 1)
            XCTAssertEqual(p["time"] as? String, time)
            XCTAssertEqual(p["notes"] as? String, "Before bed")
            XCTAssertEqual(p["tags"] as? [String], ["night"])
        }

        let one = EntityEditorView.eventPayloads(child: 2, types: ["bath"], time: time, notes: "", tags: [])
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
        let records = [type(1, "Nail trim", "nail-trim"), type(2, "Bath", "bath"),
                       type(3, "Gone", "gone", state: .pendingDelete)]
        XCTAssertEqual(EntityEditorView.eventTypeChoices(records, keeping: nil).map(\.slug), ["bath", "nail-trim"])
        XCTAssertEqual(EntityEditorView.eventTypeChoices(records, keeping: "unsynced").map(\.slug),
                       ["bath", "nail-trim", "unsynced"])
        XCTAssertEqual(EntityEditorView.eventTypeChoices(records, keeping: "bath").count, 2)
    }

    // MARK: Capability

    /// The API root turns events on only when it lists both routes; a server without them also
    /// drops the cached names. Sign-out forgets both.
    func testCapability() {
        EventsCapability.update(rootJSON: Data(#"{"event-types": "x", "events": "x"}"#.utf8))
        XCTAssertTrue(EventsCapability.isSupported)
        EventsCapability.store(typesIn: [type(1, "Bath", "bath"), type(2, "Gone", "gone", state: .pendingDelete)])
        XCTAssertEqual(EventsCapability.typeNames, ["bath": "Bath"])

        EventsCapability.update(rootJSON: Data(#"{"events": "x"}"#.utf8))
        XCTAssertFalse(EventsCapability.isSupported)
        XCTAssertTrue(EventsCapability.typeNames.isEmpty)

        EventsCapability.update(rootJSON: Data(#"{"event-types": "x", "events": "x"}"#.utf8))
        EventsCapability.store(typesIn: [type(1, "Bath", "bath")])
        EventsCapability.reset()
        XCTAssertFalse(EventsCapability.isSupported)
        XCTAssertTrue(EventsCapability.typeNames.isEmpty)
    }

    /// A row names an event by its type; a type this phone doesn't know yet by its slug.
    func testEventTitle() {
        EventsCapability.store(typeNames: ["bath": "Bath"])
        XCTAssertEqual(EntityFormatting.title(event("bath", hoursAgo: 1)), "Bath")
        XCTAssertEqual(EntityFormatting.title(event("unknown-type", hoursAgo: 1)), "unknown-type")
        XCTAssertEqual(EntityFormatting.title(entity(.event, ["child": 1, "time": iso(1)])), "Event")
        XCTAssertEqual(EntityFormatting.title(entity(.note, ["child": 1, "time": iso(1)])), "Note")
    }

    // MARK: Time since last

    /// The newest event of each type, for this child only; deleted events don't count.
    func testLastTimesPerType() {
        let last = EventsCapability.lastTimes(in: [
            event("bath", hoursAgo: 50), event("bath", hoursAgo: 26), event("nail-trim", hoursAgo: 26),
            event("bath", hoursAgo: 2, child: 2), event("nail-trim", hoursAgo: 1, state: .pendingDelete),
            entity(.note, ["child": 1, "time": iso(0)]),
        ], child: 1)
        XCTAssertEqual(last["bath"], now.addingTimeInterval(-26 * 3600))
        XCTAssertEqual(last["nail-trim"], now.addingTimeInterval(-26 * 3600))
        XCTAssertNil(last["outfit"], "Never")
        XCTAssertEqual(last.count, 2)
    }
}

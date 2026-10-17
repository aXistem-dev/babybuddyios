import SwiftUI
import XCTest
@testable import BabyBuddy

/// Activities, on a server that has them: user-defined activity types (data from the server, never
/// named by the app) and activities of those types on a child, referenced by the type's id.
@MainActor
final class ActivitiesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func tearDown() async throws {
        ActivitiesCapability.reset()
    }

    private func entity(_ kind: EntityKind, _ payload: [String: Any],
                        state: SyncState = .synced) -> LocalEntity {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return LocalEntity(kind: kind, serverID: payload["id"] as? Int, childID: kind.childID(from: payload),
                           timestamp: kind.timestamp(from: payload), payload: data, syncState: state)
    }

    private func iso(_ minutesAgo: Double) -> String {
        APIDate.isoDateTime.string(from: now.addingTimeInterval(-minutesAgo * 60))
    }

    private func activity(_ type: Int, start minutesAgo: Double, minutes: Double = 0, child: Int = 1,
                          notes: String = "", state: SyncState = .synced) -> LocalEntity {
        entity(.activity, ["child": child, "type": type, "start": iso(minutesAgo),
                           "end": iso(minutesAgo - minutes), "notes": notes], state: state)
    }

    private func type(_ id: Int, _ name: String, emoji: String = "", icon: String = "activities",
                      hasDuration: Bool = false, active: Bool = true, order: Int = 0,
                      state: SyncState = .synced) -> LocalEntity {
        entity(.activityType, ["id": id, "name": name, "slug": name.lowercased(), "icon": icon,
                               "emoji": emoji, "color": "#123456", "has_duration": hasDuration,
                               "active": active, "order": order], state: state)
    }

    private func supportActivities() {
        ActivitiesCapability.update(rootJSON: Data(#"{"activity-types": "x", "activities": "x"}"#.utf8))
    }

    // MARK: API

    func testDTOsDecode() throws {
        let type = try APICoders.decoder.decode(ActivityTypeDTO.self, from: Data("""
        {"id": 3, "name": "Walk", "slug": "walk", "icon": "activities", "emoji": "🚶",
         "color": "#8455b8", "has_duration": true, "active": true, "order": 2}
        """.utf8))
        XCTAssertEqual(type.name, "Walk")
        XCTAssertEqual(type.has_duration, true)
        XCTAssertEqual(type.order, 2)

        let activity = try APICoders.decoder.decode(ActivityDTO.self, from: Data("""
        {"id": 9, "child": 1, "type": 3, "start": "2026-09-30T08:00:00+02:00",
         "end": "2026-09-30T08:40:00+02:00", "timer": null, "duration": "00:40:00",
         "notes": null, "tags": ["park"]}
        """.utf8))
        XCTAssertEqual(activity.type, 3, "An activity names its type by id")
        XCTAssertEqual(activity.start, APIDate.parse("2026-09-30T08:00:00+02:00"))
        XCTAssertEqual(activity.end, APIDate.parse("2026-09-30T08:40:00+02:00"))
        XCTAssertNil(activity.notes)
        XCTAssertEqual(activity.tags, ["park"])
    }

    /// Activities are windowed on `start` like tummy time and show on the timeline; their types are
    /// metadata, pulled in full and never on the timeline.
    func testKinds() {
        XCTAssertEqual(EntityKind.activity.path, "activities")
        XCTAssertEqual(EntityKind.activity.timeField, "start")
        XCTAssertEqual(EntityKind.activity.rangeFilterParam, "start")
        XCTAssertTrue(EntityKind.activity.isWindowed)
        XCTAssertEqual(EntityKind.activityType.path, "activity-types")
        XCTAssertFalse(EntityKind.activityType.isWindowed)
        XCTAssertTrue(EntityKind.timelineKinds.contains(.activity))
        XCTAssertFalse(EntityKind.timelineKinds.contains(.activityType))
    }

    /// A server without activities isn't asked for their routes.
    func testSyncedKinds() {
        XCTAssertFalse(EntityKind.syncedKinds.contains(.activity))
        XCTAssertFalse(EntityKind.syncedKinds.contains(.activityType))
        XCTAssertTrue(EntityKind.syncedKinds.contains(.feeding))
        supportActivities()
        XCTAssertTrue(EntityKind.syncedKinds.contains(.activity))
        XCTAssertTrue(EntityKind.syncedKinds.contains(.activityType))
    }

    // MARK: Payloads

    /// A type with duration sends its start and end; one without sends its one time as both.
    func testPayload() {
        let start = now.addingTimeInterval(-3600), end = now.addingTimeInterval(-1200), time = now
        let walk = EntityEditorView.activityPayload(child: 1, type: 4, hasDuration: true, start: start,
                                                    end: end, time: time, notes: "Park", tags: ["out"])
        XCTAssertEqual(walk["child"] as? Int, 1)
        XCTAssertEqual(walk["type"] as? Int, 4)
        XCTAssertEqual(walk["start"] as? String, APIDate.isoDateTime.string(from: start))
        XCTAssertEqual(walk["end"] as? String, APIDate.isoDateTime.string(from: end))
        XCTAssertEqual(walk["notes"] as? String, "Park")
        XCTAssertEqual(walk["tags"] as? [String], ["out"])

        let bath = EntityEditorView.activityPayload(child: 2, type: 1, hasDuration: false, start: start,
                                                    end: end, time: time, notes: "", tags: [])
        XCTAssertEqual(bath["start"] as? String, APIDate.isoDateTime.string(from: time))
        XCTAssertEqual(bath["end"] as? String, APIDate.isoDateTime.string(from: time))
    }

    private func payloads(_ types: [ActivitiesCapability.TypeInfo], start: Date, end: Date,
                          time: Date) -> [[String: Any]] {
        EntityEditorView.activityPayloads(child: 2, types: types, start: start, end: end, time: time,
                                          notes: "Park", tags: ["out"])
    }

    private func iso(_ date: Date) -> String { APIDate.isoDateTime.string(from: date) }

    /// Several types, some with duration: one activity each, with the same child, notes and tags. The
    /// types with duration run from the start to the end; the others are the moment of the start.
    func testSeveralTypesMixed() {
        let start = now.addingTimeInterval(-3600), end = now.addingTimeInterval(-1200)
        let saved = payloads([info(1, "Bath"), info(4, "Walk", hasDuration: true), info(2, "Pajama change")],
                             start: start, end: end, time: now)
        XCTAssertEqual(saved.map { $0["type"] as? Int }, [1, 4, 2])
        XCTAssertEqual(saved.map { $0["child"] as? Int }, [2, 2, 2])
        XCTAssertEqual(saved.map { $0["notes"] as? String }, ["Park", "Park", "Park"])
        XCTAssertEqual(saved.map { $0["tags"] as? [String] }, [["out"], ["out"], ["out"]])
        XCTAssertEqual(saved.map { $0["start"] as? String }, [iso(start), iso(start), iso(start)])
        XCTAssertEqual(saved.map { $0["end"] as? String }, [iso(start), iso(end), iso(start)])
    }

    /// Several types without duration: each is the one time, and none gets the end.
    func testSeveralTypesWithoutDuration() {
        let start = now.addingTimeInterval(-3600), end = now.addingTimeInterval(-1200)
        let saved = payloads([info(1, "Bath"), info(2, "Pajama change")], start: start, end: end, time: now)
        XCTAssertEqual(saved.map { $0["type"] as? Int }, [1, 2])
        XCTAssertEqual(saved.map { $0["start"] as? String }, [iso(now), iso(now)])
        XCTAssertEqual(saved.map { $0["end"] as? String }, [iso(now), iso(now)])
    }

    /// Several types with duration: each runs from the start to the end.
    func testSeveralTypesWithDuration() {
        let start = now.addingTimeInterval(-3600), end = now.addingTimeInterval(-1200)
        let saved = payloads([info(4, "Walk", hasDuration: true), info(6, "Swim", hasDuration: true)],
                             start: start, end: end, time: now)
        XCTAssertEqual(saved.map { $0["type"] as? Int }, [4, 6])
        XCTAssertEqual(saved.map { $0["start"] as? String }, [iso(start), iso(start)])
        XCTAssertEqual(saved.map { $0["end"] as? String }, [iso(end), iso(end)])
    }

    // MARK: Validation

    /// An activity needs a type. One without duration is one time, never in the future; one with
    /// duration follows the sleep rules, its end included.
    func testValidation() {
        var draft = ActivityDraft(kind: .activity)
        draft.now = now
        draft.time = now
        XCTAssertEqual(draft.problem, .activityTypeRequired)
        draft.activityType = 1
        XCTAssertNil(draft.problem)
        draft.time = now.addingTimeInterval(3600)
        XCTAssertEqual(draft.problem, .futureTimestamp)

        draft.activityHasDuration = true
        draft.start = now.addingTimeInterval(-1800)
        draft.end = now
        XCTAssertNil(draft.problem, "The time isn't used by a type with duration")
        draft.end = now.addingTimeInterval(-3600)
        XCTAssertEqual(draft.problem, .startAfterEnd)
        draft.start = now.addingTimeInterval(-25 * 3600)
        draft.end = now
        XCTAssertEqual(draft.problem, .over24Hours)
        draft.start = now
        draft.end = now.addingTimeInterval(3600)
        XCTAssertEqual(draft.problem, .futureTimestamp)
    }

    /// The server refuses an activity that overlaps another of the same type for the same child;
    /// other types, and moments that only touch, don't count.
    func testOverlapIsPerType() {
        let walk = activity(4, start: 60, minutes: 40)
        let other = activity(5, start: 60, minutes: 40)
        let start = now.addingTimeInterval(-30 * 60), end = now
        XCTAssertIdentical(ActivityDraft.overlapping(kind: .activity, childID: 1, start: start, end: end,
                                                     excluding: nil, activityType: 4, in: [other, walk]), walk)
        XCTAssertNil(ActivityDraft.overlapping(kind: .activity, childID: 1, start: start, end: end,
                                               excluding: nil, activityType: 6, in: [other, walk]))
        XCTAssertNil(ActivityDraft.overlapping(kind: .activity, childID: 1, start: now.addingTimeInterval(-20 * 60),
                                               end: end, excluding: nil, activityType: 4, in: [walk]),
                     "Starting as the other ends only touches it")
    }

    // MARK: Types

    /// The editor lists the active types in the server's order, leaves out deleted ones, and keeps
    /// an edited activity's own type when it's inactive.
    func testTypeChoices() {
        let records = [type(1, "Walk", order: 2), type(2, "Bath", order: 1),
                       type(3, "Old", active: false, order: 0),
                       type(4, "Gone", order: 0, state: .pendingDelete)]
        XCTAssertEqual(EntityEditorView.activityTypeChoices(records, keeping: []).map(\.name), ["Bath", "Walk"])
        XCTAssertEqual(EntityEditorView.activityTypeChoices(records, keeping: [3]).map(\.name), ["Old", "Bath", "Walk"])
    }

    /// The emoji first; else the app's own glyph where the server's icon is a record kind; else an
    /// SF Symbol, the default one for the `activities` icon and any name the app doesn't know.
    func testTileIcon() {
        XCTAssertEqual(ActivityIcon(icon: "sleep", emoji: "🛁"), .emoji("🛁"))
        XCTAssertEqual(ActivityIcon(icon: "tummytime", emoji: ""), .glyph(.tummyTime))
        XCTAssertEqual(ActivityIcon(icon: "diaperchange", emoji: ""), .glyph(.change))
        XCTAssertEqual(ActivityIcon(icon: "calendar", emoji: ""), .symbol("calendar"))
        XCTAssertEqual(ActivityIcon(icon: "activities", emoji: ""), .symbol(EntityKind.activity.systemImage))
        XCTAssertEqual(ActivityIcon(icon: "not-a-server-icon", emoji: ""), .symbol(EntityKind.activity.systemImage))
    }

    /// Every icon the server offers (`ACTIVITY_ICONS`) has its own image, except the default, and the
    /// type form offers exactly those, in the server's order.
    func testEveryServerIconIsMapped() {
        let server = ["activities", "bmi", "calendar", "camera", "chat", "child", "clock", "dashboard",
                      "diaperchange", "feeding", "graph", "head-circumference", "height", "list", "lock",
                      "mail", "measurements", "medication", "note", "pumping", "refresh", "sad", "sleep",
                      "source", "stop", "tag", "temperature", "timeline", "timer", "today", "tummytime",
                      "user", "weight"]
        XCTAssertEqual(ActivityIcon.serverIcons.map(\.name), server)
        let mapped = Set(ActivityIcon.glyphs.keys).union(ActivityIcon.symbols.keys)
        XCTAssertEqual(Set(server).subtracting(mapped), ["activities"])
        XCTAssertTrue(mapped.isSubset(of: server))
    }

    // MARK: Capability

    /// The API root turns activities on only when it lists both routes; a server without them also
    /// drops the cached types. Sign-out forgets both.
    func testCapability() {
        supportActivities()
        XCTAssertTrue(ActivitiesCapability.isSupported)
        ActivitiesCapability.store(typesIn: [type(2, "Walk", emoji: "🚶", hasDuration: true, order: 2),
                                             type(1, "Bath", order: 1),
                                             type(3, "Gone", state: .pendingDelete)])
        XCTAssertEqual(ActivitiesCapability.types.map(\.name), ["Bath", "Walk"])
        XCTAssertEqual(ActivitiesCapability.type(id: 2)?.hasDuration, true)
        XCTAssertEqual(ActivitiesCapability.type(id: 2)?.tileIcon, .emoji("🚶"))

        ActivitiesCapability.update(rootJSON: Data(#"{"activities": "x"}"#.utf8))
        XCTAssertFalse(ActivitiesCapability.isSupported)
        XCTAssertTrue(ActivitiesCapability.types.isEmpty)

        supportActivities()
        ActivitiesCapability.store(typesIn: [type(1, "Bath")])
        ActivitiesCapability.reset()
        XCTAssertFalse(ActivitiesCapability.isSupported)
        XCTAssertTrue(ActivitiesCapability.types.isEmpty)
    }

    /// A row names an activity by its type, shows a duration only for one that has it, and its notes.
    func testRowText() {
        supportActivities()
        ActivitiesCapability.store(typesIn: [type(1, "Bath", emoji: "🛁"), type(4, "Walk", hasDuration: true)])
        let bath = activity(1, start: 60, notes: "Before bed")
        XCTAssertEqual(EntityFormatting.title(bath), "Bath")
        XCTAssertEqual(EntityFormatting.subtitle(bath), "Before bed", "A moment has no duration")
        XCTAssertEqual(bath.tileIcon, .emoji("🛁"))
        XCTAssertNotNil(bath.tileColor)

        let walk = activity(4, start: 60, minutes: 40)
        XCTAssertEqual(EntityFormatting.title(walk), "Walk")
        XCTAssertEqual(EntityFormatting.subtitle(walk), EntityFormatting.formatInterval(40 * 60))

        let unknown = activity(99, start: 60)
        XCTAssertEqual(EntityFormatting.title(unknown), "Activity", "A type this phone hasn't synced")
        XCTAssertNil(unknown.tileIcon)
        XCTAssertNil(unknown.tileColor)
        XCTAssertEqual(EntityFormatting.title(entity(.note, ["child": 1, "time": iso(1)])), "Note")
    }

    // MARK: Colors

    /// A type's tile takes the server's color at 75% opacity; without one, or with one that isn't
    /// `#rrggbb`, it keeps the activity color.
    func testTypeColor() throws {
        let bath = ActivitiesCapability.TypeInfo(id: 1, payload: ["name": "Bath", "color": "#8455b8"])
        XCTAssertEqual(bath.color, "#8455b8")
        let resolved = try XCTUnwrap(bath.tileColor).resolve(in: EnvironmentValues())
        XCTAssertEqual(resolved.opacity, 0.75, accuracy: 0.001)
        XCTAssertEqual(resolved.red, Color(hex: "#8455b8")!.resolve(in: EnvironmentValues()).red, accuracy: 0.001)

        XCTAssertNil(ActivitiesCapability.TypeInfo(id: 2, payload: ["name": "Walk", "color": ""]).tileColor)
        XCTAssertNil(ActivitiesCapability.TypeInfo(id: 3, payload: ["name": "Walk", "color": "purple"]).tileColor)
        XCTAssertNil(ActivitiesCapability.TypeInfo(id: 4, payload: ["name": "Walk"]).tileColor)
    }

    /// Types cached before colors still read, without a color.
    func testTypesCachedWithoutAColor() {
        let cached = Data(#"[{"id":1,"name":"Bath","icon":"","emoji":"🛁","hasDuration":false,"active":true,"order":1}]"#.utf8)
        let types = ActivitiesCapability.types(from: cached)
        XCTAssertEqual(types.map(\.name), ["Bath"])
        XCTAssertNil(types.first?.color)
    }

    // MARK: Most used

    private func info(_ id: Int, _ name: String, hasDuration: Bool = false, active: Bool = true,
                      order: Int = 0) -> ActivitiesCapability.TypeInfo {
        ActivitiesCapability.TypeInfo(id: id, payload: ["name": name, "has_duration": hasDuration,
                                                        "active": active, "order": order])
    }

    /// The child's most used active types in the last 30 days first; a tie goes to the type used most
    /// recently, then to the server's order, and unused types fill the rest. Other children's,
    /// deleted and older activities don't count.
    func testTopTypes() {
        let types = [info(1, "Bath", order: 1), info(2, "Walk", order: 2), info(3, "Pajama change", order: 3),
                     info(4, "Bodysuit change", order: 4), info(5, "Haircut", active: false, order: 5)]
        let activities = [
            activity(2, start: 60), activity(2, start: 120),
            activity(3, start: 30), activity(1, start: 240),
            activity(1, start: 10, child: 2), activity(1, start: 20, state: .pendingDelete),
            activity(4, start: 31 * 24 * 60), activity(5, start: 5),
        ]
        let top = ActivityUsage.topTypes(activities: activities, types: types, child: 1, now: now)
        XCTAssertEqual(top.map(\.name), ["Walk", "Pajama change", "Bath", "Bodysuit change"],
                       "Walk twice, then the newer of the two used once, then the unused; never the inactive")
        XCTAssertEqual(ActivityUsage.topTypes(activities: activities, types: types, child: 1, now: now, limit: 2)
            .map(\.name), ["Walk", "Pajama change"])
    }

    // MARK: Managing types

    /// The type list's `permissions` say what this user may do; missing ones read as false. A server
    /// without activities, and sign-out, forget them.
    func testPermissions() {
        let page = Data(#"""
        {"count": 0, "next": null, "previous": null, "results": [],
         "permissions": {"add": true, "change": true, "delete": false, "delete_with_activities": true}}
        """#.utf8)
        let p = ActivitiesCapability.permissions(fromListJSON: page)
        XCTAssertEqual(p, .init(add: true, change: true, delete: false, deleteWithActivities: true))
        XCTAssertTrue(p.any)
        XCTAssertEqual(ActivitiesCapability.permissions(fromListJSON: Data(#"{"results": []}"#.utf8)), .init())
        XCTAssertFalse(ActivitiesCapability.Permissions().any)
        XCTAssertEqual(ActivitiesCapability.typeListPath, "activity-types/")

        supportActivities()
        ActivitiesCapability.store(permissions: p)
        XCTAssertEqual(ActivitiesCapability.permissions, p)
        ActivitiesCapability.update(rootJSON: Data(#"{"children": "x"}"#.utf8))
        XCTAssertEqual(ActivitiesCapability.permissions, .init())
        ActivitiesCapability.store(permissions: p)
        ActivitiesCapability.reset()
        XCTAssertEqual(ActivitiesCapability.permissions, .init())
    }

    /// A name is required and at most 100 characters; an emoji is one character or none. A new type
    /// sends every field; an edit only what changed, trimmed.
    func testTypeFields() {
        var fields = ActivityTypeFields()
        XCTAssertEqual(fields.nameProblem, "Enter a name.")
        fields.name = String(repeating: "a", count: 101)
        XCTAssertNotNil(fields.nameProblem)
        fields.name = " Walk "
        XCTAssertNil(fields.nameProblem)
        fields.emoji = "🚶🚶"
        XCTAssertFalse(fields.isValid)
        fields.emoji = "👍🏽"
        XCTAssertTrue(fields.isValid, "A skin tone is part of one emoji")
        fields.hasDuration = true

        let body = fields.body
        XCTAssertEqual(body["name"] as? String, "Walk")
        XCTAssertEqual(body["icon"] as? String, "activities")
        XCTAssertEqual(body["has_duration"] as? Bool, true)
        XCTAssertEqual(body["active"] as? Bool, true)

        let current: [String: Any] = ["id": 4, "name": "Walk", "slug": "walk", "icon": "activities",
                                      "emoji": "🚶", "has_duration": true, "active": true, "order": 4]
        var edit = ActivityTypeFields(payload: current)
        XCTAssertTrue(edit.changes(from: current).isEmpty)
        edit.name = "Stroll "
        edit.active = false
        edit.icon = "sleep"
        let changes = edit.changes(from: current)
        XCTAssertEqual(Set(changes.keys), ["name", "active", "icon"])
        XCTAssertEqual(changes["name"] as? String, "Stroll")
        XCTAssertEqual(changes["active"] as? Bool, false)
    }

    /// A refused delete offers deleting the activities too only when the server counted some and lets
    /// this user delete them; the question counts them.
    func testDeleteCascade() {
        let conflict = DeleteConflict(from: Data(#"{"detail": "In use.", "activity_count": 3}"#.utf8))
        XCTAssertEqual(conflict, DeleteConflict(message: "In use.", activityCount: 3))
        let may = ActivitiesCapability.Permissions(delete: true, deleteWithActivities: true)
        XCTAssertTrue(ActivityTypeFields.offersCascade(conflict, permissions: may))
        XCTAssertFalse(ActivityTypeFields.offersCascade(conflict, permissions: .init(delete: true)))
        XCTAssertFalse(ActivityTypeFields.offersCascade(DeleteConflict(message: nil, activityCount: nil),
                                                        permissions: may))
        XCTAssertEqual(ActivityTypeFields.cascadeTitle(name: "Bath", activityCount: 1),
                       "Delete \u{201C}Bath\u{201D} and its 1 activity?")
        XCTAssertEqual(ActivityTypeFields.cascadeTitle(name: "Bath", activityCount: 2),
                       "Delete \u{201C}Bath\u{201D} and its 2 activities?")
    }

    // MARK: Timers

    private func timer(name: String, raw: String? = nil) -> LocalEntity {
        let payload: [String: Any] = ["child": 1, "start": iso(10), "name": name]
        return LocalEntity(kind: .timer, serverID: 7, childID: 1, timestamp: EntityKind.timer.timestamp(from: payload),
                           payload: try! JSONSerialization.data(withJSONObject: payload), syncState: .synced,
                           timerActivityRaw: raw)
    }

    /// A timer times the type it was started for on this phone; one started elsewhere, the active
    /// type with duration it's named after. Types without duration, inactive ones by name, and
    /// servers without activities give none.
    func testTimerType() {
        supportActivities()
        ActivitiesCapability.store(typesIn: [type(1, "Bath"), type(4, "Walk", hasDuration: true),
                                             type(6, "Swim", hasDuration: true, active: false)])
        XCTAssertEqual(ActivitiesCapability.timerActivityRaw(typeID: 4), "activity:4")
        XCTAssertEqual(ActivitiesCapability.timerType(of: timer(name: "Stroll", raw: "activity:4"))?.id, 4)
        XCTAssertEqual(ActivitiesCapability.timerType(of: timer(name: "walk"))?.id, 4, "By name, any case")
        XCTAssertNil(ActivitiesCapability.timerType(of: timer(name: "Bath")), "A moment can't be timed")
        XCTAssertNil(ActivitiesCapability.timerType(of: timer(name: "Swim")), "Inactive, by name")
        XCTAssertEqual(ActivitiesCapability.timerType(of: timer(name: "x", raw: "activity:6"))?.id, 6,
                       "Started for it before it was made inactive")
        XCTAssertNil(ActivitiesCapability.timerType(of: timer(name: "Sleep", raw: "sleep")))

        ActivitiesCapability.update(rootJSON: Data(#"{"children": "x"}"#.utf8))
        XCTAssertNil(ActivitiesCapability.timerType(of: timer(name: "Walk", raw: "activity:4")))
    }
}

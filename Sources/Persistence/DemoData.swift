#if DEBUG
import Foundation
import SwiftData
import UIKit
import UserNotifications

/// Seeds the local cache with sample records so the authenticated UI can be exercised in
/// the simulator without a live Baby Buddy server. Activated by launching with the
/// environment variable `BB_DEMO=1`.
enum DemoData {
    /// `BB_UITEST=1`: start a UI-test launch from a clean install, so no test inherits another's
    /// records, settings, nudge counters, sign-in or pending notifications. The store and the
    /// defaults otherwise persist across launches on the simulator, and demo data is only seeded
    /// into an empty store. With `BB_DEMO=1` the sample data goes in straight away — the demo pull
    /// seeds too, but only after the first frame, too late for `BB_OPEN`'s `onAppear`.
    ///
    /// Called first thing in `BabyBuddyApp.init`, before anything reads defaults or the store.
    @MainActor
    static func resetForUITests(_ context: ModelContext) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BB_UITEST"] == "1" else { return }
        if let domain = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        SharedDefaults.suite.removePersistentDomain(forName: LocalStore.appGroupID)
        LocalStore.wipe(in: context)
        KeychainStore.clear()
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        if environment["BB_DEMO"] == "1" { seedIfNeeded(into: context) }
    }

    @MainActor
    static func seedIfNeeded(into context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<LocalEntity>()))?.isEmpty ?? true
        guard existing else {
            refreshDemoStash(in: context)
            refreshDemoEvents(in: context)
            return
        }

        insert(.child, id: 1, [
            "id": 1, "first_name": "Maya", "last_name": "Guy",
            "birth_date": "2025-11-02", "slug": "maya-guy",
            "picture": demoChildPicture() as Any,
        ], context)

        let now = Date()
        func iso(_ offsetMinutes: Int) -> String {
            APIDate.isoDateTime.string(from: now.addingTimeInterval(Double(-offsetMinutes * 60)))
        }

        // Cached tags so the picker has colored suggestions offline.
        for dto in [
            TagDTO(slug: "hungry", name: "hungry", color: "#ff7f7f", last_used: now),
            TagDTO(slug: "night", name: "night", color: "#00007f", last_used: now),
            TagDTO(slug: "fussy", name: "fussy", color: "#ffff7f", last_used: now),
            TagDTO(slug: "milestone", name: "milestone", color: "#007f7f", last_used: now),
        ] {
            LocalStore.upsertTag(dto, in: context)
        }

        insert(.feeding, id: 10, [
            "id": 10, "child": 1, "start": iso(90), "end": iso(70),
            "type": "breast milk", "method": "left breast", "amount": NSNull(),
            "tags": ["hungry", "night"],
        ], context)
        insert(.feeding, id: 11, [
            "id": 11, "child": 1, "start": iso(330), "end": iso(310),
            "type": "formula", "method": "bottle", "amount": 90, "tags": [],
        ], context)
        insert(.change, id: 20, [
            "id": 20, "child": 1, "time": iso(45), "wet": true, "solid": false,
            "color": "", "tags": [],
        ], context)
        insert(.change, id: 21, [
            "id": 21, "child": 1, "time": iso(200), "wet": true, "solid": true,
            "color": "yellow", "tags": [],
        ], context)
        insert(.sleep, id: 30, [
            "id": 30, "child": 1, "start": iso(420), "end": iso(180), "nap": false,
            "tags": ["night"],
        ], context)
        insert(.timer, id: 40, [
            "id": 40, "child": 1, "name": "Tummy time", "start": iso(8),
        ], context)
        insert(.weight, id: 50, [
            "id": 50, "child": 1, "weight": 5.4, "date": APIDate.dateOnly.string(from: now), "tags": [],
        ], context)
        insert(.note, id: 60, [
            "id": 60, "child": 1, "time": iso(150), "note": "Looking out at the garden.",
            "image": demoNoteImage() as Any, "tags": ["milestone"],
        ], context)

        seedHistory(into: context)
        if ProcessInfo.processInfo.environment["BB_NO_STASH"] != "1" {
            seedStash(into: context)
        }
        if ProcessInfo.processInfo.environment["BB_NO_EVENTS"] != "1" {
            seedEvents(into: context)
        }

        if ProcessInfo.processInfo.environment["BB_SEED_CONFLICT"] == "1" {
            seedConflict(into: context)
        }
        if ProcessInfo.processInfo.environment["BB_SEED_PENDING"] == "1" {
            seedPending(into: context)
        }
        if let sick = ProcessInfo.processInfo.environment["BB_SEED_SICK"], ["1", "clear"].contains(sick) {
            seedSick(clear: sick == "clear", into: context)
        }
        if ProcessInfo.processInfo.environment["BB_SEED_SECOND_CHILD"] == "1" {
            seedSecondChild(into: context)
        }
        try? context.save()
        refreshDemoStash(in: context)
        refreshDemoEvents(in: context)
    }

    // MARK: Events

    /// Events, as a server with them would hold them: three event types, and events of them for the
    /// demo child, among them a bath and a nail trim logged together at the identical time (one
    /// event per type, as the app logs several at once). ids 5000+ (types 1–3).
    @MainActor
    private static func seedEvents(into context: ModelContext) {
        let now = Date()
        func iso(_ hoursAgo: Double) -> String {
            APIDate.isoDateTime.string(from: now.addingTimeInterval(-hoursAgo * 3600))
        }
        for (id, name, slug) in [(1, "Bath", "bath"), (2, "Nail trim", "nail-trim"),
                                 (3, "Outfit change", "outfit-change")] {
            insert(.eventType, id: id, ["id": id, "name": name, "slug": slug], context)
        }
        let together = iso(26)
        for (id, type, time) in [(5000, "bath", iso(50)), (5001, "bath", together),
                                 (5002, "nail-trim", together), (5003, "outfit-change", iso(3))] {
            insert(.event, id: id, [
                "id": id, "child": 1, "type": type, "time": time, "notes": "", "tags": [],
            ], context)
        }
    }

    /// Demo mode's stand-in for what a sync learns about events from `GET /api/`, and the cached
    /// event types' names. `BB_NO_EVENTS=1` runs the demo as a server without events.
    @MainActor
    private static func refreshDemoEvents(in context: ModelContext) {
        guard ProcessInfo.processInfo.environment["BB_NO_EVENTS"] != "1" else {
            EventsCapability.update(rootJSON: Data(#"{"children":"x","notes":"x"}"#.utf8))
            return
        }
        EventsCapability.update(rootJSON: Data(#"{"event-types":"x","events":"x"}"#.utf8))
        let kind = EntityKind.eventType.rawValue
        let types = (try? context.fetch(FetchDescriptor<LocalEntity>(
            predicate: #Predicate { $0.kindRaw == kind }))) ?? []
        EventsCapability.store(typesIn: types)
    }

    // MARK: Milk stash

    /// The milk stash, as a server with it would hold it: two parents linked to the demo child,
    /// Robin, who produces milk, and Sam, who doesn't; pumping on Robin put into the stash;
    /// breast-milk bottles taken from it, one with some spilled; donor milk added, and a discard
    /// with no reason. Timed so FIFO leaves one lot about 80 h old (expired), one about 50 h old
    /// (warn) and two fresh ones, so every lot state and both milk age alerts can be seen. ids 4000+
    /// (the parents are 1 and 2).
    ///
    /// `BB_MILK_PARENTS=2` adds Casey (parent 3), a second parent who produces milk, with a session
    /// in the stash, so the parent pickers show and lots are told apart by parent.
    @MainActor
    private static func seedStash(into context: ModelContext) {
        let now = Date()
        func iso(_ hoursAgo: Double) -> String {
            APIDate.isoDateTime.string(from: now.addingTimeInterval(-hoursAgo * 3600))
        }

        insert(.parent, id: 1, [
            "id": 1, "first_name": "Robin", "last_name": "", "slug": "robin",
            "picture": NSNull(), "children": [1], "produces_milk": true,
        ], context)
        insert(.parent, id: 2, [
            "id": 2, "first_name": "Sam", "last_name": "", "slug": "sam",
            "picture": NSNull(), "children": [1], "produces_milk": false,
        ], context)
        if ProcessInfo.processInfo.environment["BB_MILK_PARENTS"] == "2" {
            insert(.parent, id: 3, [
                "id": 3, "first_name": "Casey", "last_name": "", "slug": "casey",
                "picture": NSNull(), "children": [1], "produces_milk": true,
            ], context)
            insert(.pumping, id: 4003, [
                "id": 4003, "child": NSNull(), "parent": 3, "start": iso(40.33), "end": iso(40),
                "amount": 50.0, "stash_amount": 50.0, "notes": "", "tags": [],
            ], context)
        }

        // Pumping on Robin: `child` is null, as the server stores it. The second session keeps
        // 10 ml out of the stash.
        for (id, hoursAgo, amount, stashed) in [(4000, 80.0, 240.0, 240.0), (4001, 50.0, 130.0, 120.0),
                                                (4002, 20.0, 100.0, 100.0)] {
            insert(.pumping, id: id, [
                "id": id, "child": NSNull(), "parent": 1, "start": iso(hoursAgo + 0.33), "end": iso(hoursAgo),
                "amount": amount, "stash_amount": stashed, "notes": "", "tags": [],
            ], context)
        }

        // Bottles from the stash. The first had 10 ml spilled: the server backs that with a linked
        // discard at the bottle's start.
        for (id, hoursAgo, amount, discarded, reason) in [(4010, 70.0, 90.0, 10.0, "Spilled"),
                                                          (4011, 10.0, 60.0, 0.0, ""),
                                                          (4012, 6.0, 40.0, 0.0, "")] {
            var payload: [String: Any] = [
                "id": id, "child": 1, "parent": NSNull(), "start": iso(hoursAgo), "end": iso(hoursAgo - 0.25),
                "type": "breast milk", "method": "bottle", "amount": amount, "stash_amount": amount,
                "stash_discard_reason": reason, "notes": "", "tags": [],
            ]
            payload["stash_discarded"] = discarded > 0 ? discarded : NSNull()
            insert(.feeding, id: id, payload, context)
        }

        let adjustments: [(id: Int, hoursAgo: Double, kind: StashKind, amount: Double, reason: String,
                           parent: Int?, feeding: Int?)] = [
            (4020, 70.0, .discarded, 10, "Spilled", 1, 4010),
            (4021, 30.0, .added, 60, "Donor milk", nil, nil),
            (4022, 8.0, .discarded, 5, "", 1, nil),
        ]
        for a in adjustments {
            let parent: Any = a.parent.map { $0 as Any } ?? NSNull()
            let feeding: Any = a.feeding.map { $0 as Any } ?? NSNull()
            insert(.stashAdjustment, id: a.id, [
                "id": a.id, "time": iso(a.hoursAgo), "amount": a.amount, "kind": a.kind.rawValue,
                "reason": a.reason, "signed_amount": a.kind.sign * a.amount,
                "parent": parent, "feeding": feeding,
                "notes": "", "tags": [],
            ], context)
        }
    }

    /// Demo mode's stand-in for a sync's `GET /api/` and `GET /api/stash`. Runs on every demo pull,
    /// so the cached summary follows what is logged in the demo as it would after a real sync.
    /// `BB_NO_STASH=1` runs the demo as a server without the milk stash.
    @MainActor
    private static func refreshDemoStash(in context: ModelContext) {
        guard ProcessInfo.processInfo.environment["BB_NO_STASH"] != "1" else {
            StashCapability.update(rootJSON: Data(#"{"children":"x","pumping":"x"}"#.utf8))
            return
        }
        StashCapability.update(rootJSON: Data(#"{"parents":"x","stash-adjustments":"x","stash":"x"}"#.utf8))
        let kinds = [EntityKind.pumping, .feeding, .stashAdjustment].map(\.rawValue)
        let pendingDelete = SyncState.pendingDelete.rawValue
        let descriptor = FetchDescriptor<LocalEntity>(predicate: #Predicate { entity in
            kinds.contains(entity.kindRaw) && entity.syncStateRaw != pendingDelete
        })
        let entities = (try? context.fetch(descriptor)) ?? []
        StashCapability.store(summary: demoStashSummary(entities: entities, now: Date()))
    }

    /// The stash summary a server with the milk stash would return for `entities`, for demo mode,
    /// which has none. Mirrors the server's FIFO:
    /// - events oldest first, milk in before milk out at the same time: pumping `stash_amount` at
    ///   its end, a bottle's `stash_amount` at its start, an adjustment's signed amount at its time;
    /// - a lot is one inflow, and is the parent's of its pumping or "added" entry;
    /// - every outflow uses the oldest milk first. A discard with a parent takes that parent's
    ///   oldest milk first, and only then anyone's; bottles have no parent. Milk taken from an empty
    ///   stash is a shortfall the next inflow repays;
    /// - lots under 0.01 ml are dropped;
    /// - a lot is `warn` from 48 h and `expired` from 72 h old. `amount` is rounded to 2 decimals,
    ///   `throw_away_amount` is not, and `is_oldest_expired` marks only the first expired lot.
    static func demoStashSummary(entities: [LocalEntity], now: Date) -> StashSummaryDTO {
        let warnHours = 48.0, maxHours = 72.0, epsilon = 1e-9
        func date(_ value: Any?) -> Date? { (value as? String).flatMap(APIDate.parse) }

        var events: [(time: Date, amount: Double, parent: Int?)] = []
        for entity in entities {
            let p = entity.payloadObject
            let parent = p["parent"] as? Int
            switch entity.kind {
            case .pumping:
                if let stashed = p["stash_amount"] as? Double, let end = date(p["end"]) {
                    events.append((end, stashed, parent))
                }
            case .feeding:
                if let taken = p["stash_amount"] as? Double, let start = date(p["start"]) {
                    events.append((start, -taken, nil))
                }
            case .stashAdjustment:
                guard let time = date(p["time"]) else { continue }
                if let signed = p["signed_amount"] as? Double {
                    events.append((time, signed, parent))
                } else if let amount = p["amount"] as? Double,
                          let kind = (p["kind"] as? String).flatMap(StashKind.init(rawValue:)) {
                    events.append((time, kind.sign * amount, parent))
                }
            default:
                continue
            }
        }
        events.sort { a, b in
            if a.time != b.time { return a.time < b.time }
            return a.amount >= 0 && b.amount < 0 // milk in before milk out at the same time
        }

        var lots: [(time: Date, amount: Double, parent: Int?)] = []
        /// Takes `need` ml from the oldest lots, only `parent`'s when given; returns what's left.
        func takeOldest(_ need: Double, parent: Int? = nil) -> Double {
            var need = need
            for index in lots.indices where need > epsilon {
                if let parent, lots[index].parent != parent { continue }
                let used = min(lots[index].amount, need)
                lots[index].amount -= used
                need -= used
            }
            lots.removeAll { $0.amount <= epsilon }
            return need
        }
        var shortfall = 0.0
        for event in events {
            if event.amount > 0 {
                let amount = event.amount - shortfall
                shortfall = max(-amount, 0)
                if amount > epsilon { lots.append((event.time, amount, event.parent)) }
                continue
            }
            var need = -event.amount
            if let parent = event.parent { need = takeOldest(need, parent: parent) }
            need = takeOldest(need)
            if need > epsilon { shortfall += need }
        }
        lots.removeAll { $0.amount < 0.01 }

        var lotDTOs: [StashLotDTO] = []
        var seenExpired = false
        for lot in lots {
            let age = now.timeIntervalSince(lot.time) / 3600
            let status: StashStatus = age >= maxHours ? .expired : age >= warnHours ? .warn : .ok
            lotDTOs.append(StashLotDTO(
                time: lot.time, amount: (lot.amount * 100).rounded() / 100, throw_away_amount: lot.amount,
                age_hours: (age * 10).rounded() / 10,
                warn_at: lot.time.addingTimeInterval(warnHours * 3600),
                expires_at: lot.time.addingTimeInterval(maxHours * 3600),
                status: status, is_oldest_expired: status == .expired && !seenExpired, parent: lot.parent))
            if status == .expired { seenExpired = true }
        }
        let status: StashStatus = lotDTOs.contains(where: { $0.status == .expired }) ? .expired
            : lotDTOs.contains(where: { $0.status == .warn }) ? .warn : .ok
        let balance = events.reduce(0) { $0 + $1.amount }
        return StashSummaryDTO(
            balance: (balance * 100).rounded() / 100, status: status,
            warn_age_hours: warnHours, max_age_hours: maxHours,
            oldest: lotDTOs.first?.time, oldest_age_hours: lotDTOs.first?.age_hours,
            lots: lotDTOs, defaults: .init(pumping_to_stash: true, bottle_from_stash: true))
    }

    /// `BB_SEED_SECOND_CHILD=1`: a second child with no records of her own, so the Editor's Baby
    /// picker and the ChildSwitcher have somewhere to reassign/switch to. Exercises the
    /// multi-child gate on both (``EntityEditorView/showsChildPicker``, ``ChildSwitcher``),
    /// which the single-child demo household never reaches.
    private static func seedSecondChild(into context: ModelContext) {
        insert(.child, id: 2, [
            "id": 2, "first_name": "Leo", "last_name": "Guy",
            "birth_date": "2025-11-02", "slug": "leo-guy", "picture": NSNull(),
        ], context)
    }

    /// `BB_SEED_SICK=1`: a day and a half of fever for the demo child, with sick mode on since the
    /// first reading over the line, as on board j4. Readings are stored in °F, which either unit's
    /// phone reads correctly. Ibuprofen (every 6 hr) is OK now and acetaminophen (every 4 hr) is
    /// waiting; wet diapers and bottle feeds fill the Today grid. ids 3000+.
    ///
    /// `BB_SEED_SICK=clear` moves the fever and the doses 30 hours back and adds readings under the
    /// line since, so Home asks to end sick mode, as on board j7.
    @MainActor
    private static func seedSick(clear: Bool, into context: ModelContext) {
        let now = Date()
        func iso(_ hoursAgo: Double) -> String {
            APIDate.isoDateTime.string(from: now.addingTimeInterval(-hoursAgo * 3600))
        }
        let shift = clear ? 30.0 : 0
        var id = 3000
        func add(_ kind: EntityKind, _ payload: [String: Any]) {
            insert(kind, id: id, payload.merging(["id": id, "child": 1, "tags": []]) { $1 }, context)
            id += 1
        }
        let readings: [(hoursAgo: Double, value: Double)] = [
            (34, 99.1), (30, 99.6), (27, 100.9), (24, 100.2), (21, 99.8), (18, 101.7),
            (15, 102.8), (12, 101.4), (9, 100.5), (4.5, 101.9), (1.33, 100.8),
        ]
        for reading in readings {
            add(.temperature, ["temperature": reading.value, "time": iso(reading.hoursAgo + shift)])
        }
        if clear {
            for (hoursAgo, value) in [(26.2, 99.6), (14.0, 99.3), (1.4, 98.9)] {
                add(.temperature, ["temperature": value, "time": iso(hoursAgo)])
            }
        }
        for (name, interval, times) in [("Acetaminophen", "04:00:00", [21.5, 15, 8.5, 2.83]),
                                        ("Ibuprofen", "06:00:00", [14.5, 6.25])] {
            for hoursAgo in times {
                add(.medication, ["name": name, "dosage": 5, "dosage_unit": "mL", "time": iso(hoursAgo + shift),
                                  "next_dose_interval": interval])
            }
        }
        for hoursAgo in [2.4, 5.5, 9.2] {
            add(.change, ["time": iso(hoursAgo), "wet": true, "solid": false, "color": ""])
        }
        for (hoursAgo, amount) in [(0.9, 120.0), (3.6, 90.0), (6.9, 120.0)] {
            add(.feeding, ["start": iso(hoursAgo + 0.25), "end": iso(hoursAgo), "type": "formula",
                           "method": "bottle", "amount": amount])
        }
        add(.note, ["time": iso(1.67), "note": "Pulling at left ear after nap"])
        // The boards have no running timer; the demo's own would sit above the sick card.
        if let timer = LocalStore.fetch(kind: .timer, serverID: 40, in: context) { context.delete(timer) }
        SickModeStore.shared.start(1, at: now.addingTimeInterval(-(27 + shift) * 3600))
    }

    /// Seed a few queued writes — one create, one update, one delete, one blocked create, and a
    /// queued photo — so the Pending Changes sheet can be verified in demo, where the sync engine
    /// never actually pushes. The blocked and photo rows are the states that have no other way to
    /// be reached by hand: a real 400 and a real photo pick against a live server.
    private static func seedPending(into context: ModelContext) {
        func data(_ o: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8) }
        let iso = APIDate.isoDateTime.string(from: Date())

        // Create: a brand-new pumping not yet on the server.
        let newPayload: [String: Any] = ["child": 1, "start": iso, "end": iso, "amount": 75, "tags": []]
        let created = LocalEntity(kind: .pumping, serverID: nil, childID: 1,
                                  timestamp: Date(), payload: data(newPayload), syncState: .pendingCreate)
        context.insert(created)
        context.insert(PendingMutation(localID: created.localID, kind: .pumping, op: .create, payload: data(newPayload)))

        // Update: edit the cached diaper change (id 20).
        if let change = LocalStore.fetch(kind: .change, serverID: 20, in: context) {
            let base = change.payload
            var edited = change.payloadObject
            edited["solid"] = true; edited["color"] = "green"
            change.baseSnapshot = base
            change.payload = data(edited)
            change.syncState = .pendingUpdate
            context.insert(PendingMutation(localID: change.localID, kind: .change, op: .update,
                                           payload: data(edited), baseSnapshot: base, serverID: 20))
        }

        // Delete: remove the cached sleep (id 30).
        if let sleep = LocalStore.fetch(kind: .sleep, serverID: 30, in: context) {
            sleep.syncState = .pendingDelete
            context.insert(PendingMutation(localID: sleep.localID, kind: .sleep, op: .delete,
                                           payload: Data("{}".utf8), baseSnapshot: sleep.payload, serverID: 30))
        }

        // Blocked: a create the server refused on validation. Parked, not retried.
        let rejectedPayload: [String: Any] = ["child": 1, "start": iso, "end": iso, "tags": []]
        let rejected = LocalEntity(kind: .feeding, serverID: nil, childID: 1,
                                   timestamp: Date(), payload: data(rejectedPayload), syncState: .pendingCreate)
        context.insert(rejected)
        let blocked = PendingMutation(localID: rejected.localID, kind: .feeding, op: .create,
                                      payload: data(rejectedPayload))
        blocked.fail("Another entry intersects the specified time period. Conflicting entry: 09/12/2026 4:02 p.m. to 09/12/2026 4:17 p.m.", blocked: true)
        context.insert(blocked)

        // A timer conversion whose server timer is gone: Retry and "Create without timer".
        let stalePayload: [String: Any] = ["child": 1, "timer": 999, "start": iso, "end": iso,
                                           "milestone": "", "tags": []]
        let staleTimed = LocalEntity(kind: .tummyTime, serverID: nil, childID: 1,
                                     timestamp: Date(), payload: data(stalePayload), syncState: .pendingCreate)
        context.insert(staleTimed)
        let stale = PendingMutation(localID: staleTimed.localID, kind: .tummyTime, op: .create,
                                    payload: data(stalePayload))
        stale.fail(LocalRepository.staleTimerMessage, disposition: .blockedStaleTimer)
        context.insert(stale)

        // A queued photo for the cached note (id 60) — pending work that used to be invisible here.
        if let note = LocalStore.fetch(kind: .note, serverID: 60, in: context) {
            context.insert(PendingImageUpload(localID: note.localID, kind: .note,
                                              filename: "demo-pending.jpg", mimeType: "image/jpeg"))
        }
    }

    /// Reveal the slice of the fixed historic dataset whose dates fall within `[start, end]`,
    /// mimicking a server fetch for that older window. Drives BB_DEMO verification of "load
    /// older": each `SyncEngine.loadOlderHistory()` chunk uncovers the entries it spans, all
    /// dated older than the rolling 60-day window but after Maya's birth (2025-11-02). ids are
    /// namespaced (1000+) so they never collide with the recent seeds; upsert keeps re-reveals
    /// idempotent.
    static func seedOlderBatch(from start: Date, to end: Date, into context: ModelContext) {
        let now = Date()
        func day(_ daysAgo: Int) -> Date { now.addingTimeInterval(Double(-daysAgo) * 86_400) }
        func iso(_ d: Date) -> String { APIDate.isoDateTime.string(from: d) }
        func mins(_ d: Date, _ m: Int) -> String { iso(d.addingTimeInterval(Double(m) * 60)) }

        let historic: [(id: Int, kind: EntityKind, daysAgo: Int, payload: (Date) -> [String: Any])] = [
            (1001, .feeding, 70, { ["start": mins($0, -20), "end": iso($0), "type": "formula",
                                    "method": "bottle", "amount": 100, "tags": []] }),
            (1002, .change, 72, { ["time": iso($0), "wet": true, "solid": false, "color": "", "tags": []] }),
            (1003, .sleep, 95, { ["start": mins($0, -180), "end": iso($0), "nap": true, "tags": ["night"]] }),
            (1004, .feeding, 100, { ["start": mins($0, -15), "end": iso($0), "type": "breast milk",
                                     "method": "left breast", "amount": NSNull(), "tags": ["hungry"]] }),
            (1005, .note, 115, { ["time": iso($0), "note": "First real smile!", "tags": ["milestone"]] }),
            (1006, .change, 130, { ["time": iso($0), "wet": true, "solid": true, "color": "yellow", "tags": []] }),
            (1007, .sleep, 140, { ["start": mins($0, -240), "end": iso($0), "nap": false, "tags": ["night"]] }),
            (1008, .tummyTime, 175, { ["start": mins($0, -10), "end": iso($0), "tags": []] }),
            (1009, .feeding, 200, { ["start": mins($0, -18), "end": iso($0), "type": "formula",
                                     "method": "bottle", "amount": 60, "tags": []] }),
            (1010, .change, 210, { ["time": iso($0), "wet": true, "solid": false, "color": "", "tags": []] }),
        ]

        for item in historic {
            let when = day(item.daysAgo)
            guard when >= start, when <= end else { continue }
            var p = item.payload(when)
            p["id"] = item.id
            p["child"] = 1
            insert(item.kind, id: item.id, p, context)
        }
        try? context.save()
    }

    /// Seed ~30 days of deterministic feedings, diaper changes, sleep, tummy time, and pumping so the Trends charts
    /// (and Timeline history) have something to plot in demo mode. Values are derived
    /// arithmetically from the day offset so screenshots stay stable across runs. ids are
    /// namespaced (2000+) so they never collide with the recent seeds or the load-older batch.
    private static func seedHistory(into context: ModelContext) {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        var nextID = 2000

        /// ISO datetime `daysAgo` days back at the given fractional `hour`.
        func iso(_ daysAgo: Int, _ hour: Double) -> String {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: startOfToday) ?? startOfToday
            return APIDate.isoDateTime.string(from: day.addingTimeInterval(hour * 3600))
        }

        // (type, method, carries an amount) — bottle feeds record ml; breast feeds don't.
        let feedKinds: [(String, String, Bool)] = [
            ("formula", "bottle", true),
            ("breast milk", "left breast", false),
            ("breast milk", "right breast", false),
            ("fortified breast milk", "bottle", true),
        ]

        for daysAgo in 1...30 {
            // Feedings: 5–7 spread across the waking day.
            let feedCount = 5 + (daysAgo % 3)
            for f in 0..<feedCount {
                let hour = 6.5 + Double(f) * (15.0 / Double(feedCount))
                let (type, method, hasAmount) = feedKinds[(daysAgo + f) % feedKinds.count]
                var payload: [String: Any] = [
                    "id": nextID, "child": 1, "start": iso(daysAgo, hour - 0.25), "end": iso(daysAgo, hour),
                    "type": type, "method": method, "tags": [],
                ]
                payload["amount"] = hasAmount ? Double(60 + ((daysAgo * 7 + f * 13) % 70)) : NSNull()
                insert(.feeding, id: nextID, payload, context); nextID += 1
            }

            // Diaper changes: 4–7, every so often a solid.
            let changeCount = 4 + (daysAgo % 4)
            for c in 0..<changeCount {
                let hour = 6.0 + Double(c) * (16.0 / Double(changeCount))
                let solid = (daysAgo + c) % 3 == 0
                insert(.change, id: nextID, [
                    "id": nextID, "child": 1, "time": iso(daysAgo, hour), "wet": true, "solid": solid,
                    "color": solid ? "yellow" : "", "tags": [],
                ], context); nextID += 1
            }

            // Sleep: an early-morning block plus two naps, all within the day (~9–11h total).
            let blocks: [(Double, Double)] = [
                (0.0, 5.5 + Double(daysAgo % 3) * 0.5),
                (9.0, 10.5),
                (13.0, 15.0 + Double(daysAgo % 2) * 0.5),
            ]
            for (start, end) in blocks {
                insert(.sleep, id: nextID, [
                    "id": nextID, "child": 1, "start": iso(daysAgo, start), "end": iso(daysAgo, end),
                    "nap": start > 6, "tags": [],
                ], context); nextID += 1
            }

            // Tummy time: 2–3 short sessions (3–8 min) — every fourth day skipped.
            if daysAgo % 4 != 0 {
                for t in 0..<(2 + daysAgo % 2) {
                    let minutes = Double(3 + (daysAgo * 3 + t * 5) % 6)
                    let hour = 11.0 + Double(t) * 3.0
                    insert(.tummyTime, id: nextID, [
                        "id": nextID, "child": 1, "start": iso(daysAgo, hour),
                        "end": iso(daysAgo, hour + minutes / 60), "milestone": "", "tags": [],
                    ], context); nextID += 1
                }
            }

            // Pumping: 3–4 sessions of 60–140 ml.
            for s in 0..<(3 + daysAgo % 2) {
                let hour = 7.0 + Double(s) * 4.5
                insert(.pumping, id: nextID, [
                    "id": nextID, "child": 1, "start": iso(daysAgo, hour - 0.33), "end": iso(daysAgo, hour),
                    "amount": Double(60 + ((daysAgo * 11 + s * 23) % 80)), "tags": [],
                ], context); nextID += 1
            }
        }
    }

    /// Seed a single update-vs-update conflict on the most recent feeding. Diverges in four
    /// fields (end time, amount, tags, notes) while start/type/method match, so the merge
    /// screen exercises scalar choices, a tag diff, and the silently-kept summary row.
    private static func seedConflict(into context: ModelContext) {
        guard let feeding = LocalStore.fetch(kind: .feeding, serverID: 11, in: context) else { return }
        let base = feeding.payload
        let iso: (Int) -> String = { APIDate.isoDateTime.string(from: Date().addingTimeInterval(Double(-$0 * 60))) }
        var mine = feeding.payloadObject
        mine["end"] = iso(305); mine["amount"] = 120; mine["tags"] = ["hungry", "night"]; mine["notes"] = "Extra hungry"
        var theirs = feeding.payloadObject
        theirs["amount"] = 60; theirs["notes"] = "Spit up a little"
        feeding.syncState = .conflicted
        context.insert(ConflictRecord(
            localID: feeding.localID, kind: .feeding, op: .update, serverID: 11,
            localPayload: (try? JSONSerialization.data(withJSONObject: mine)) ?? base,
            serverPayload: (try? JSONSerialization.data(withJSONObject: theirs)) ?? base,
            basePayload: base))
    }

    private static func insert(_ kind: EntityKind, id: Int, _ obj: [String: Any], _ context: ModelContext) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        LocalStore.upsertFromServer(data, kind: kind, in: context)
    }

    // MARK: Demo images
    //
    // The display feature fetches media from the server, which demo mode has no access to. To
    // exercise the image UI (avatar + note thumbnail) offline, render a couple of placeholder
    // images to the caches directory and seed their `file://` URLs — `RemoteImage` loads file URLs
    // directly with no network.

    /// A simple flat "portrait" (distinct from the initials fallback so the loaded photo is
    /// visually obvious), written once to caches.
    private static func demoChildPicture() -> String? {
        renderDemoImage(named: "child", size: CGSize(width: 240, height: 240)) { ctx, rect in
            UIColor(hex: "F4A6C0").setFill()
            ctx.fill(rect)
            UIColor(hex: "FFE0B2").setFill()  // face
            ctx.fillEllipse(in: rect.insetBy(dx: rect.width * 0.26, dy: rect.height * 0.18))
            UIColor(hex: "5D4037").setFill()  // eyes
            ctx.fillEllipse(in: CGRect(x: rect.width * 0.40, y: rect.height * 0.42, width: rect.width * 0.06, height: rect.width * 0.06))
            ctx.fillEllipse(in: CGRect(x: rect.width * 0.54, y: rect.height * 0.42, width: rect.width * 0.06, height: rect.width * 0.06))
        }
    }

    /// A simple flat "garden" scene, written once to caches, for the seeded note's thumbnail.
    private static func demoNoteImage() -> String? {
        renderDemoImage(named: "note", size: CGSize(width: 320, height: 320)) { ctx, rect in
            UIColor(hex: "BFE3F5").setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.6))
            UIColor(hex: "A8D08D").setFill()
            ctx.fill(CGRect(x: 0, y: rect.height * 0.6, width: rect.width, height: rect.height * 0.4))
            UIColor(hex: "FFD54A").setFill()
            let sun = CGRect(x: rect.width * 0.66, y: rect.height * 0.1, width: rect.width * 0.22, height: rect.width * 0.22)
            ctx.fillEllipse(in: sun)
        }
    }

    private static func renderDemoImage(named name: String, size: CGSize,
                                        draw: (CGContext, CGRect) -> Void) -> String? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("bbdemo_\(name).png")
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in draw(ctx.cgContext, CGRect(origin: .zero, size: size)) }
        guard let data = image.pngData() else { return nil }
        try? data.write(to: url, options: .atomic)
        return url.absoluteString
    }
}
#endif

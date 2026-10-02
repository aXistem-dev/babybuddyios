import Foundation
import SwiftData

/// Performs the bulk pull (server → cache) on a background context so parsing and
/// inserting large datasets never blocks the main thread. It shares the app's
/// `ModelContainer`, so records it saves are merged into the main context that drives
/// the UI's `@Query`s.
///
/// Push, conflict detection, and conflict resolution stay on the main context in
/// ``SyncEngine`` — they're network-bound, low-volume, and user-initiated.
@ModelActor
actor SyncActor {
    /// Sentinel returned when the server rejects the token, so the caller can sign out.
    static let unauthorized = "##unauthorized##"

    /// Outcome of a bulk pull: an error message (or `nil` on success), and whether any cached
    /// record was actually inserted, updated, or deleted (so the caller can tell a meaningful
    /// sync from a no-op one).
    struct PullOutcome {
        let error: String?
        let changed: Bool
    }

    /// Pull every kind into the store.
    func pullAll(config: ServerConfig, windowDays: Int) async -> PullOutcome {
        let client = APIClient(config: config)
        var changed = false
        do {
            try await pullTags(client: client)
            if modelContext.hasChanges { try modelContext.save() }
        } catch APIError.notFound {
            // Tags endpoint absent on this server version — skip.
            Analytics.serverEndpointMissing("tags")
        } catch APIError.unauthorized {
            return PullOutcome(error: Self.unauthorized, changed: changed)
        } catch let error as APIError {
            return Self.fail(error, endpoint: "tags", changed: changed)
        } catch {
            Analytics.error(network: "pull-unknown")
            return PullOutcome(error: error.localizedDescription, changed: changed)
        }
        var serverError: APIError?   // last 5xx seen; surfaced only if *every* kind fails this way
        var pulledAnyKind = false
        for kind in EntityKind.allCases {
            do {
                try await pull(kind: kind, client: client, windowDays: windowDays)
                // Save only when the pull actually changed something: an unchanged kind's save
                // would still fan out change notifications that re-run every observing @Query.
                if modelContext.hasChanges {
                    changed = true               // real insert/update/delete this kind
                    try modelContext.save()      // commit per kind so the UI fills in progressively
                }
                pulledAnyKind = true
            } catch APIError.notFound {
                Analytics.serverEndpointMissing(kind.rawValue)
                continue                      // endpoint absent on this server version
            } catch APIError.unauthorized {
                return PullOutcome(error: Self.unauthorized, changed: changed)
            } catch let error as APIError where error.isServer {
                // A 5xx on one kind is transient and must not abort the whole pull — skip this
                // kind so the others still sync, and let the next sync retry it. Discard the
                // failed kind's partial upserts so a half-pulled page never gets committed by the
                // next kind's save. Only if *every* kind 5xxes (server broadly unhealthy) is the
                // error surfaced, after the loop.
                // Deliberately not reported per kind: a server that is down 5xxes every kind, so
                // that would be one signal per kind per sync. Reported once below, if it turns out
                // nothing synced at all.
                modelContext.rollback()
                serverError = error
                continue
            } catch let error as APIError {
                return Self.fail(error, endpoint: kind.rawValue, changed: changed)
            } catch {
                Analytics.error(network: "pull-unknown")
                return PullOutcome(error: error.localizedDescription, changed: changed)
            }
        }
        // Surface a server error only when nothing synced at all; a partial pull keeps its data.
        if !pulledAnyKind, let serverError {
            return Self.fail(serverError, endpoint: "all", changed: changed)
        }
        if await refreshStash(client: client) { changed = true }
        if await refreshEventTypes(client: client) { changed = true }
        return PullOutcome(error: nil, changed: changed)
    }

    /// Cache the pulled event types' names and emoji by slug, for the rows that show an event, and
    /// what this user may do with event types (the `permissions` of the type list's first page). See
    /// ``EventsCapability``. Returns whether any of it changed, so a rename shows without new events.
    private func refreshEventTypes(client: APIClient) async -> Bool {
        guard EventsCapability.isSupported else { return false }
        let names = EventsCapability.typeNames
        let emoji = EventsCapability.typeEmoji
        let permissions = EventsCapability.permissions
        let kind = EntityKind.eventType.rawValue
        let types = (try? modelContext.fetch(FetchDescriptor<LocalEntity>(
            predicate: #Predicate { $0.kindRaw == kind }))) ?? []
        EventsCapability.store(typesIn: types)
        // A failed request keeps the permissions this phone last had.
        if let page = try? await client.getRawPath(EventsCapability.typeListPath) {
            EventsCapability.store(permissions: EventsCapability.permissions(fromListJSON: page))
        }
        return EventsCapability.typeNames != names
            || EventsCapability.typeEmoji != emoji
            || EventsCapability.permissions != permissions
    }

    /// Refresh whether the server has the milk stash (its API root lists the stash routes) and, if
    /// it does, the cached stash summary. Never fails the sync: a network or HTTP error keeps what
    /// was cached, and a summary that doesn't decode is reported and cleared.
    /// Returns whether either changed, so the pull counts as a change and what shows the stash
    /// (the stash card, the milk age alerts) refreshes.
    private func refreshStash(client: APIClient) async -> Bool {
        let wasSupported = StashCapability.isSupported
        let hadEvents = EventsCapability.isSupported
        let previous = StashCapability.summary
        do {
            let root = try await client.getRawPath("")
            StashCapability.update(rootJSON: root)
            // The same root says whether the server has events.
            EventsCapability.update(rootJSON: root)
            if StashCapability.hasSettings {
                // The Settings section's values, cached for offline. A failure keeps the cache.
                if let data = try? await client.getRawPath(StashCapability.settingsRootKey),
                   let settings = try? APICoders.decoder.decode(StashSettingsDTO.self, from: data) {
                    StashCapability.store(settings: settings)
                }
            }
            if StashCapability.isSupported {
                let data = try await client.getRawPath("stash")
                do {
                    let summary = try APICoders.decoder.decode(StashSummaryDTO.self, from: data)
                    StashCapability.store(summary: summary)
                } catch {
                    // A summary this app can't read is dropped rather than shown stale, and reported.
                    Analytics.report(.decoding(String(describing: error)), context: "pull-stash")
                    StashCapability.store(summary: nil)
                }
            }
        } catch let error as APIError {
            Analytics.report(error, context: "pull-stash")
        } catch {
            Analytics.error(network: "pull-stash")
        }
        return StashCapability.isSupported != wasSupported || EventsCapability.isSupported != hadEvents
            || Self.stashSummaryChanged(from: previous, to: StashCapability.summary)
    }

    /// Whether the stash summary changed in what the stash shows and alerts on, so a sync that
    /// brought nothing new stays a no-op. Both sides are compared as ``comparable(_:)`` makes them,
    /// whichever of them came from the cache and whichever straight from the server.
    static func stashSummaryChanged(from previous: StashSummaryDTO?, to current: StashSummaryDTO?) -> Bool {
        comparable(previous) != comparable(current)
    }

    /// A summary with its age readings cleared, and its dates as the cache keeps them. The ages tick
    /// with the clock on every request, while amounts, lot times and status change only with the
    /// data or when a lot crosses an age limit. The cache stores dates in whole seconds and the
    /// server may send microseconds, so both sides go through the same encoder and decoder.
    private static func comparable(_ summary: StashSummaryDTO?) -> StashSummaryDTO? {
        guard var summary else { return nil }
        summary.oldest_age_hours = nil
        summary.lots = summary.lots.map { lot in
            var lot = lot
            lot.age_hours = 0
            return lot
        }
        guard let data = try? APICoders.encoder.encode(summary),
              let coded = try? APICoders.decoder.decode(StashSummaryDTO.self, from: data) else { return summary }
        return coded
    }

    /// Report a pull failure and turn it into the outcome the caller surfaces. `endpoint` is the
    /// kind that failed (or `all` when every kind did), so a pull error says *what* couldn't be
    /// fetched rather than only that a pull failed.
    private static func fail(_ error: APIError, endpoint: String, changed: Bool) -> PullOutcome {
        Analytics.report(error, context: "pull-\(endpoint)")
        return PullOutcome(error: error.userMessage, changed: changed)
    }

    /// Pull the server's global tag list into the cache for the picker's autocomplete.
    /// Tags are low-volume and not child-scoped, so we pull all and reconcile deletions.
    ///
    /// The only caller that opts into an unpaginated bare-array response: some servers answer
    /// `tags` that way, and because this list is small and un-windowed the whole collection
    /// really does arrive in one body. See ``APIClient/splitPage(_:allowsUnpaginatedArray:)``.
    private func pullTags(client: APIClient) async throws {
        let records = try await client.listAllRaw(path: "tags", allowsUnpaginatedArray: true)
        var names = Set<String>()
        for record in records {
            guard let dto = try? APICoders.decoder.decode(TagDTO.self, from: record) else { continue }
            LocalStore.upsertTag(dto, in: modelContext)
            names.insert(dto.name)
        }
        let cached = (try? modelContext.fetch(FetchDescriptor<CachedTag>())) ?? []
        for tag in cached where !names.contains(tag.name) {
            modelContext.delete(tag)
        }
    }

    private func pull(kind: EntityKind, client: APIClient, windowDays: Int) async throws {
        var query = ListQuery(ordering: "-\(kind.timeField)")
        // Only high-volume event kinds are windowed; children, timers, and growth
        // measurements are pulled in full (measurements expose no range filter on the API).
        let windowStart = kind.isWindowed
            ? Calendar.current.date(byAdding: .day, value: -windowDays, to: .now)
            : nil
        if let windowStart {
            query.timeParam = kind.rangeFilterParam
            query.timeMin = windowStart
        }

        let records = try await client.listAllRaw(path: kind.path, query: query)
        var serverIDs = Set<Int>()
        for record in records {
            if let entity = LocalStore.upsertFromServer(record, kind: kind, in: modelContext),
               let id = entity.serverID {
                serverIDs.insert(id)
            }
        }
        reconcileDeletions(kind: kind, serverIDs: serverIDs, windowStart: windowStart)
    }

    /// Pull a historic date window `[dateMin, dateMax]` across every windowed kind, merging
    /// the results into the cache for on-demand "load older" history. Unlike
    /// ``pull(kind:client:windowDays:)`` this **only ever upserts and never reconciles
    /// deletions**, so records already cached — by this call, an earlier history page, or the
    /// rolling window — are never dropped. Returns `nil` on success, or an error message.
    func pullOlderWindow(config: ServerConfig, dateMin: Date, dateMax: Date) async -> String? {
        let client = APIClient(config: config)
        var serverError: String?     // last 5xx seen; surfaced only if *every* kind fails this way
        var pulledAnyKind = false
        for kind in EntityKind.allCases where kind.isWindowed {
            do {
                var query = ListQuery(ordering: "-\(kind.timeField)")
                query.timeParam = kind.rangeFilterParam
                query.timeMin = dateMin
                query.timeMax = dateMax
                let records = try await client.listAllRaw(path: kind.path, query: query)
                for record in records {
                    LocalStore.upsertFromServer(record, kind: kind, in: modelContext)
                }
                if modelContext.hasChanges {
                    try modelContext.save()   // commit per kind so the UI fills in progressively
                }
                pulledAnyKind = true
            } catch APIError.notFound {
                continue                       // endpoint absent on this server version
            } catch APIError.unauthorized {
                return Self.unauthorized
            } catch let error as APIError where error.isServer {
                // 5xx on one kind: skip it so the rest of the window still loads, and let a
                // later "load older" retry it. Discard the failed kind's partial upserts.
                modelContext.rollback()
                serverError = error.userMessage
                continue
            } catch let error as APIError {
                return error.userMessage
            } catch {
                return error.localizedDescription
            }
        }
        // Fail the load only if nothing loaded at all; a partial window keeps what it fetched.
        if !pulledAnyKind, let serverError { return serverError }
        return nil
    }

    /// Remove synced local records the server no longer returns within the pulled window
    /// (deleted elsewhere). Pending/conflicted records are never touched.
    private func reconcileDeletions(kind: EntityKind, serverIDs: Set<Int>, windowStart: Date?) {
        let kindRaw = kind.rawValue
        let descriptor = FetchDescriptor<LocalEntity>(
            predicate: #Predicate { $0.kindRaw == kindRaw && $0.serverID != nil })
        guard let locals = try? modelContext.fetch(descriptor) else { return }
        for local in locals where Self.shouldPurge(
            syncState: local.syncState, timestamp: local.timestamp, serverID: local.serverID,
            serverIDs: serverIDs, windowStart: windowStart) {
            modelContext.delete(local)
        }
    }

    /// Whether a cached record should be purged as a server-side deletion. Only *synced*
    /// records the windowed pull no longer returned are candidates, and only those at or
    /// after `windowStart`: records older than the rolling window — fetched by "load older"
    /// history paging — are preserved so a narrower pull never drops them. Pending/conflicted
    /// local edits are never purged. Pure, so the window invariant is unit-testable.
    static func shouldPurge(syncState: SyncState, timestamp: Date, serverID: Int?,
                            serverIDs: Set<Int>, windowStart: Date?) -> Bool {
        guard syncState == .synced, let serverID else { return false }
        if let windowStart, timestamp < windowStart { return false } // outside pulled window — keep
        return !serverIDs.contains(serverID)
    }
}

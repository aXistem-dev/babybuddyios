import Foundation
import Observation

/// The milk stash's server settings behind Settings ▸ Milk stash: read from the server when the
/// section opens (and on every sync), cached for offline, and changed with a PATCH of only what
/// changed. Never queued: a stale queued change could overwrite one made on the web meanwhile, so
/// offline the section is read-only.
@MainActor
@Observable
final class StashSettingsModel {
    enum Status: Equatable {
        case idle
        case saving
        /// The last request didn't reach the server: the cached values, read-only.
        case offline
        /// The server refused a change; its message, shown once the values are reverted.
        case refused(String)
    }

    private(set) var settings: StashSettingsDTO?
    private(set) var status: Status = .idle

    init() {
        settings = StashCapability.settings
    }

    /// Whether the controls can change anything: the server says this user may, and it's reachable.
    var isEditable: Bool {
        settings?.can_edit == true && status != .offline && status != .saving
    }

    /// Re-read the settings from the server.
    func refresh(session: AppSession) async {
        do {
            let fresh = try await fetch(session: session)
            StashCapability.store(settings: fresh)
            settings = fresh
            if status == .offline { status = .idle }
        } catch {
            settings = StashCapability.settings
            status = .offline
        }
    }

    /// Change the settings to `new`, sending only the fields that differ. On success the stash
    /// summary is re-read at once, so the editors' defaults and the expiry alerts follow without
    /// waiting for the next sync; on a refusal the values go back and the server's reason shows.
    func save(_ new: StashSettingsDTO, session: AppSession, sync: SyncEngine) async {
        guard let old = settings, old.can_edit else { return }
        let body = StashSettingsEdit.body(from: old, to: new)
        guard !body.isEmpty else { return }
        if new.warn_age_hours != old.warn_age_hours || new.max_age_hours != old.max_age_hours,
           !StashSettingsEdit.agesAreValid(warn: new.warn_age_hours, max: new.max_age_hours) {
            status = .refused(StashSettingsEdit.agesMessage)
            return
        }
        settings = new
        status = .saving
        do {
            let saved = try await patch(body, session: session)
            StashCapability.store(settings: saved)
            settings = saved
            status = .idle
            await refreshSummary(session: session, sync: sync)
            await LocalAlerts.shared.reconcile()
        } catch let error as APIError {
            settings = old
            switch error {
            case .offline:
                status = .offline
            case .badRequest(_, let message, _):
                status = .refused(message ?? "Baby Buddy didn\u{2019}t accept that change.")
            case .forbidden:
                status = .refused("Only an administrator can change these.")
                await refresh(session: session)
            default:
                status = .refused("Couldn\u{2019}t save the change. Try again.")
            }
        } catch {
            settings = old
            status = .refused("Couldn\u{2019}t save the change. Try again.")
        }
    }

    // MARK: Server

    private func fetch(session: AppSession) async throws -> StashSettingsDTO {
        #if DEBUG
        if session.isDemo { return DemoData.demoStashSettings }
        #endif
        guard let config = session.config else { throw APIError.offline() }
        let data = try await APIClient(config: config).getRawPath(StashCapability.settingsRootKey)
        return try APICoders.decoder.decode(StashSettingsDTO.self, from: data)
    }

    private func patch(_ body: [String: Any], session: AppSession) async throws -> StashSettingsDTO {
        #if DEBUG
        if session.isDemo { return DemoData.patchDemoStashSettings(body) }
        #endif
        guard let config = session.config else { throw APIError.offline() }
        let json = try JSONSerialization.data(withJSONObject: body)
        let data = try await APIClient(config: config).patchRawPath(StashCapability.settingsRootKey, body: json)
        return try APICoders.decoder.decode(StashSettingsDTO.self, from: data)
    }

    /// The stash summary carries the defaults and ages the editors and the alerts use: re-read it now.
    private func refreshSummary(session: AppSession, sync: SyncEngine) async {
        #if DEBUG
        if session.isDemo {
            await sync.sync() // the demo pull recomputes the summary from the new settings
            return
        }
        #endif
        guard let config = session.config,
              let data = try? await APIClient(config: config).getRawPath("stash"),
              let summary = try? APICoders.decoder.decode(StashSummaryDTO.self, from: data) else { return }
        StashCapability.store(summary: summary)
        NotificationCenter.default.post(name: .syncDidFinish, object: nil)
    }
}

/// The rules for changing the stash settings, kept apart from the view so they can be tested.
enum StashSettingsEdit {
    /// The PATCH body from `old` to `new`: only the fields that changed (never `can_edit`).
    static func body(from old: StashSettingsDTO, to new: StashSettingsDTO) -> [String: Any] {
        var body: [String: Any] = [:]
        if new.pumping_to_stash != old.pumping_to_stash { body["pumping_to_stash"] = new.pumping_to_stash }
        if new.bottle_from_stash != old.bottle_from_stash { body["bottle_from_stash"] = new.bottle_from_stash }
        if new.warn_age_hours != old.warn_age_hours { body["warn_age_hours"] = new.warn_age_hours }
        if new.max_age_hours != old.max_age_hours { body["max_age_hours"] = new.max_age_hours }
        return body
    }

    /// Whole hours from zero, with "expiring soon" before "expires", as the server requires.
    static func agesAreValid(warn: Int, max: Int) -> Bool {
        warn >= 0 && max >= 0 && warn < max
    }

    static let agesMessage = "\u{201C}Expiring soon after\u{201D} has to be less than \u{201C}Expires after\u{201D}."
}

import Foundation
import Combine
import Observation

// The milk stash screen's logic, kept out of the views so it can be tested without SwiftUI.

/// Throwing expired milk away. Stash milk is used oldest first, so only the oldest expired lot can
/// be thrown away on its own; "Throw away all expired milk" takes every expired lot at once.
enum StashThrowAway {
    /// A lot's amount as the editor pre-fills it: rounded **down** to 2 decimals, so throwing a lot
    /// away never takes more than is left and the stash can't dip below zero by a rounding sliver.
    /// A leftover under 0.01 ml is dropped by the server.
    static func amount(_ value: Double) -> Double {
        floor(value * 100 + 1e-6) / 100
    }

    /// The lot that offers "Throw away": the one the server flags `is_oldest_expired`. A summary
    /// cached before the server sent that flag carries it on no lot; then the first expired lot.
    static func lotOffers(_ summary: StashSummaryDTO) -> StashLotDTO? {
        if summary.lots.contains(where: { $0.is_oldest_expired != nil }) {
            return summary.lots.first { $0.is_oldest_expired == true }
        }
        return summary.lots.first { $0.status == .expired }
    }

    /// Every expired lot's milk, unrounded where the server sent it, then rounded down as one amount.
    static func allExpiredAmount(_ summary: StashSummaryDTO) -> Double {
        let total = summary.lots
            .filter { $0.status == .expired }
            .reduce(0.0) { $0 + ($1.throw_away_amount ?? $1.amount) }
        return amount(total)
    }

    /// The reason a throw-away is logged with.
    static func reason(maxAgeHours: Double) -> String {
        "Older than \(Int(maxAgeHours)) h"
    }
}

/// How much milk each child had from the stash: the `stash_amount` of their synced feedings. There
/// is no endpoint for it, so it only covers what this phone has synced (a recent window).
enum StashUse {
    struct Totals: Equatable {
        var today: Double
        var week: Double
    }

    /// `child`'s milk from the stash today and over the last 7 days (today and the 6 before it).
    static func totals(_ entities: [LocalEntity], childID: Int, now: Date = .now,
                       calendar: Calendar = .current) -> Totals {
        let today = calendar.startOfDay(for: now)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        var totals = Totals(today: 0, week: 0)
        for entity in entities where entity.kind == .feeding && entity.childID == childID
            && entity.syncState != .pendingDelete {
            guard let taken = entity.payloadObject["stash_amount"] as? Double,
                  entity.timestamp >= weekStart, entity.timestamp <= now else { continue }
            totals.week += taken
            if entity.timestamp >= today { totals.today += taken }
        }
        return totals
    }
}

/// The warning shown while the stash balance is below zero: more milk was logged leaving the stash
/// than going in, usually because milk that went into the fridge was never logged.
/// Dismissing it hides it for the current dip only: the App Group's defaults keep a token of that
/// dip, which ``StashCapability`` forgets once the balance is back at or above zero.
enum StashNegativeWarning {
    static let dismissedKey = StashCapability.negativeWarningDismissedKey

    static let message = "The stash is below zero: more milk was taken out than was ever put in. Add the missing milk with an \"Added\" entry."

    /// Identifies the current dip below zero; nil while the balance isn't below zero (or there is
    /// no summary yet). A server that doesn't say when the dip started gets one fixed token.
    static func token(for summary: StashSummaryDTO?) -> String? {
        guard let summary, summary.balance < 0 else { return nil }
        guard let since = summary.negative_since else { return "negative" }
        return String(Int(since.timeIntervalSince1970))
    }

    static func shows(summary: StashSummaryDTO?, dismissedToken: String?) -> Bool {
        guard let token = token(for: summary) else { return false }
        return token != dismissedToken
    }
}

/// What a new stash entry starts with: "Add to stash", "Discard milk" and the throw-away buttons
/// each open the editor pre-set.
struct StashEntryPreset: Identifiable {
    let id = UUID()
    var kind: StashKind
    var amount: Double?
    var reason = ""

    /// Throwing milk away: discarded, the amount rounded down, and why.
    static func throwAway(_ amount: Double, maxAgeHours: Double) -> StashEntryPreset {
        StashEntryPreset(kind: .discarded, amount: StashThrowAway.amount(amount),
                         reason: StashThrowAway.reason(maxAgeHours: maxAgeHours))
    }
}

extension LocalEntity {
    /// A discard the server made for a bottle's "Some was discarded". It belongs to that bottle: it
    /// is changed or removed there, never repeated or deleted on its own.
    var isLinkedStashDiscard: Bool {
        kind == .stashAdjustment && stashFeedingID != nil
    }

    /// The bottle a linked stash discard belongs to.
    var stashFeedingID: Int? {
        payloadObject["feeding"] as? Int
    }
}

extension Notification.Name {
    /// Posted on the main actor after every sync pass, whether or not it changed anything: demo mode
    /// refreshes the stash summary without reporting a change.
    static let syncDidFinish = Notification.Name("BabyBuddy.syncDidFinish")
}

/// The stash summary the stash screen and the Home card show. The server is authoritative, so this
/// is the cached `GET /api/stash`, re-read after each sync (never from the offline queue).
@MainActor
@Observable
final class StashViewModel {
    private(set) var summary: StashSummaryDTO?
    /// Whether the server has the milk stash, as of the last sync.
    private(set) var isSupported: Bool
    @ObservationIgnored private var subscription: AnyCancellable?

    init(center: NotificationCenter = .default) {
        summary = StashCapability.summary
        isSupported = StashCapability.isSupported
        subscription = center.publisher(for: .syncDidFinish).sink { [weak self] _ in
            guard let self else { return }
            // Posted on the main actor (``SyncEngine``), and delivered synchronously.
            MainActor.assumeIsolated { self.refreshAfterSync() }
        }
    }

    /// Re-read the summary the last sync cached.
    func refreshAfterSync() {
        summary = StashCapability.summary
        isSupported = StashCapability.isSupported
    }
}

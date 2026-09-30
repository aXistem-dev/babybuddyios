import Foundation

/// Why a draft activity can't be saved. Deliberately a closed set of reasons the client can
/// know *offline*, so a later telemetry signal can classify a block without carrying any
/// family data (no dates, durations, amounts, or child ids).
enum ActivityProblem: Equatable {
    case amountRequired
    case stashAmountRequired
    case valueRequired
    case notANumber
    case noteRequired
    case medicationNameRequired
    case parentRequired
    case noParents
    case storedAmountInvalid
    case stashBottleAmountRequired
    case stashTakenInvalid
    case discardedAmountRequired
    case startAfterEnd
    case over24Hours
    case futureTimestamp
    case futureDate

    /// Inline, user-facing explanation of the block.
    var message: String {
        switch self {
        case .amountRequired:        return "Enter how much was pumped — Baby Buddy needs an amount."
        case .stashAmountRequired:   return "Enter how much milk, more than 0 ml."
        case .valueRequired:         return "Enter a value."
        case .notANumber:            return "That isn't a number Baby Buddy can read. Use digits, like 90 or 4.5."
        case .noteRequired:          return "Write something for this note."
        case .medicationNameRequired: return "Enter the medication name."
        case .parentRequired:        return "Choose who pumped."
        case .noParents:             return "Add a parent in Baby Buddy to log pumping."
        case .storedAmountInvalid:   return "The amount stored has to be more than 0 ml and no more than the amount pumped. Change it under More."
        case .stashBottleAmountRequired: return "Enter an amount to take from the stash."
        case .stashTakenInvalid:     return "The amount from the stash has to be more than 0 ml and no more than the amount fed. Change it under More."
        case .discardedAmountRequired: return "Enter how much was discarded, at least 0.1 ml."
        case .startAfterEnd:         return "The start time is after the end time."
        case .over24Hours:           return "Baby Buddy won't accept more than 24 hours between start and end."
        case .futureTimestamp:       return "That time is in the future — Baby Buddy only accepts times up to now."
        case .futureDate:            return "That date is in the future — Baby Buddy only accepts dates up to today."
        }
    }
}

/// The editor's fields, minus the UI. Holds just enough to apply the Baby Buddy validation rules
/// the client can evaluate locally, so they're testable without standing up a SwiftUI view.
///
/// Mirrors upstream `core/models.py` per kind — the `clean()` implementations, not an abstract
/// form schema: `validate_time(start)` for feeding/pumping, `validate_time(start)` *and* `(end)`
/// for sleep/tummy time, `validate_duration` (start ≤ end, ≤ 24h) for all four, `validate_time(time)`
/// for changes/temperature/medication (notes are exempt upstream), and `validate_date(date)` for the
/// growth measurements. Overlap (`validate_unique_period`) is not a block here: the local cache is
/// windowed and can be stale, so a local check would be wrong in both directions. The editor shows
/// ``overlapping(kind:childID:start:end:excluding:in:)`` as a warning instead.
struct ActivityDraft {
    var kind: EntityKind
    var start = Date()
    var end = Date()
    var time = Date()
    var date = Date()
    var amount = ""
    var value = ""
    var dosage = ""
    var noteText = ""
    var medName = ""
    /// Who pumped. On a server with the milk stash (`requiresParent`) pumping is logged on a
    /// parent, so it needs one.
    var parentID: Int?
    var requiresParent = false
    /// Whether any parent who produces milk is on offer. With none the picker is hidden, so "Choose
    /// who pumped." would point at nothing: the parent has to be added on the server first.
    var hasParents = true
    // The milk stash, on a server with it (the editor sets these only there): pumping with
    // "Store in stash" on, or a breast-milk bottle with "Taken from stash" on; the amount stored or
    // taken ("More"; blank means the whole amount); and, on such a bottle, any of it discarded.
    var storesInStash = false
    var takesFromStash = false
    var stashAmount = ""
    var discardsSome = false
    var discardedAmount = ""
    /// Injected so the future-timestamp rules are testable against a fixed clock.
    var now = Date()

    var isValid: Bool { problem == nil }

    var problem: ActivityProblem? {
        switch kind {
        case .feeding:
            // Amount is optional upstream, but a value that doesn't parse used to be dropped
            // silently — if something was typed it has to be a number.
            return amountProblem(required: false) ?? stashBottleProblem ?? durationProblem(futureEnd: false)
        case .pumping:
            return amountProblem(required: true) ?? parentProblem ?? storedAmountProblem
                ?? durationProblem(futureEnd: false)
        case .sleep, .tummyTime:
            return durationProblem(futureEnd: true)
        case .change:
            return isFuture(time) ? .futureTimestamp : nil
        case .note:
            return noteText.trimmingCharacters(in: .whitespaces).isEmpty ? .noteRequired : nil
        case .temperature:
            return valueProblem ?? (isFuture(time) ? .futureTimestamp : nil)
        case .weight, .height, .headCircumference, .bmi:
            return valueProblem ?? (isFutureDay(date) ? .futureDate : nil)
        case .medication:
            if medName.trimmingCharacters(in: .whitespaces).isEmpty { return .medicationNameRequired }
            if !dosage.trimmingCharacters(in: .whitespaces).isEmpty, Self.number(dosage) == nil { return .notANumber }
            return isFuture(time) ? .futureTimestamp : nil
        case .stashAdjustment:
            return stashAmountProblem ?? (isFuture(time) ? .futureTimestamp : nil)
        case .timer, .child, .parent:
            return nil // not editable in this form
        }
    }

    // MARK: Rules

    private func amountProblem(required: Bool) -> ActivityProblem? {
        if amount.trimmingCharacters(in: .whitespaces).isEmpty { return required ? .amountRequired : nil }
        guard let parsed = Self.number(amount), parsed >= 0 else { return .notANumber }
        return nil
    }

    /// A stash entry moves some milk: an amount above zero.
    private var stashAmountProblem: ActivityProblem? {
        if amount.trimmingCharacters(in: .whitespaces).isEmpty { return .stashAmountRequired }
        guard let parsed = Self.number(amount) else { return .notANumber }
        return parsed > 0 ? nil : .stashAmountRequired
    }

    private var parentProblem: ActivityProblem? {
        guard requiresParent, parentID == nil else { return nil }
        return hasParents ? .parentRequired : .noParents
    }

    /// Pumping into the stash: the amount stored, when typed, is above zero and at most the amount
    /// (upstream `validate_pumping_stash_amount`). An amount of 0 stores nothing, so there's nothing
    /// to check: the editor then sends no stash amount.
    private var storedAmountProblem: ActivityProblem? {
        guard storesInStash, let pumped = Self.number(amount), pumped > 0 else { return nil }
        return stashPartProblem(of: pumped, invalid: .storedAmountInvalid)
    }

    /// A bottle taken from the stash takes an amount above zero, and at most that from the stash
    /// (upstream `Feeding.clean`). Anything discarded from it is at least 0.1 ml, the serializer's
    /// minimum.
    private var stashBottleProblem: ActivityProblem? {
        guard takesFromStash else { return nil }
        guard let fed = Self.number(amount), fed > 0 else { return .stashBottleAmountRequired }
        if let problem = stashPartProblem(of: fed, invalid: .stashTakenInvalid) { return problem }
        guard discardsSome else { return nil }
        if discardedAmount.trimmingCharacters(in: .whitespaces).isEmpty { return .discardedAmountRequired }
        guard let discarded = Self.number(discardedAmount) else { return .notANumber }
        return discarded >= 0.1 ? nil : .discardedAmountRequired
    }

    /// The stored or taken amount against the whole: blank follows the whole, so it's fine. An edit
    /// that lowers the amount below what was stored lands here too.
    private func stashPartProblem(of whole: Double, invalid: ActivityProblem) -> ActivityProblem? {
        if stashAmount.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        guard let part = Self.number(stashAmount) else { return .notANumber }
        return part > 0 && part <= whole ? nil : invalid
    }

    private var valueProblem: ActivityProblem? {
        if value.trimmingCharacters(in: .whitespaces).isEmpty { return .valueRequired }
        return Self.number(value) == nil ? .notANumber : nil
    }

    /// Shared by the four start/end kinds. `futureEnd` reflects which of them upstream checks:
    /// feeding and pumping validate only `start`, so rejecting their future `end` would be
    /// stricter than the server.
    private func durationProblem(futureEnd: Bool) -> ActivityProblem? {
        if start > end { return .startAfterEnd }
        // Upstream is `end - start > 24h`, so exactly 24 hours is allowed.
        if end.timeIntervalSince(start) > 24 * 3600 { return .over24Hours }
        if isFuture(start) || (futureEnd && isFuture(end)) { return .futureTimestamp }
        return nil
    }

    /// A minute of slack: the phone's clock and a self-hosted server's rarely agree to the second,
    /// and every ordinary entry is "now". The rejections telemetry saw were hours or days out.
    private func isFuture(_ moment: Date) -> Bool { moment.timeIntervalSince(now) > 60 }

    private func isFutureDay(_ day: Date) -> Bool {
        let calendar = Calendar.current
        return calendar.startOfDay(for: day) > calendar.startOfDay(for: now)
    }

    // MARK: Overlap

    /// The kinds Baby Buddy refuses to let overlap another of the same kind for the same child
    /// (`validate_unique_period` in each model's `clean()`).
    static let overlapCheckedKinds: Set<EntityKind> = [.feeding, .sleep, .tummyTime, .pumping]

    /// The first cached record that `start...end` intersects, by upstream's test
    /// (`start < other.end && end > other.start`, so touching ends don't count). `excluding` is the
    /// record being edited; records waiting to be deleted are ignored.
    static func overlapping(kind: EntityKind, childID: Int, start: Date, end: Date,
                            excluding: UUID?, in records: [LocalEntity]) -> LocalEntity? {
        guard overlapCheckedKinds.contains(kind), start < end else { return nil }
        return records.first { record in
            guard record.kind == kind, record.childID == childID, record.localID != excluding,
                  record.syncState != .pendingDelete,
                  let range = period(of: record) else { return false }
            return range.lowerBound < end && range.upperBound > start
        }
    }

    /// A start/end record's period, from its payload.
    static func period(of record: LocalEntity) -> Range<Date>? {
        let payload = record.payloadObject
        guard let start = (payload["start"] as? String).flatMap(APIDate.parse),
              let end = (payload["end"] as? String).flatMap(APIDate.parse), start < end else { return nil }
        return start..<end
    }

    // MARK: Numeric input

    /// Parse a number the way the editor's `decimalPad` offers it. `Double("1,5")` is nil, and the
    /// pad shows the *locale's* decimal separator — which is how a comma-locale amount ended up
    /// silently omitted from the payload. Returns nil for blank or unparseable input.
    static func number(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parsed = Double(trimmed) ?? Double(trimmed.replacingOccurrences(of: ",", with: "."))
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }
}

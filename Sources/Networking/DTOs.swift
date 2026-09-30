import Foundation

// MARK: - Resource protocol

/// A Baby Buddy API resource. `path` is the collection path under `/api/`.
protocol APIResource: Codable, Identifiable {
    static var path: String { get }
    var id: Int? { get }
}

// MARK: - Paged list envelope

/// DRF's paginated list response.
struct Paged<T: Codable>: Codable {
    let count: Int
    let next: String?
    let previous: String?
    let results: [T]
}

// MARK: - Enums

enum FeedingType: String, Codable, CaseIterable, Identifiable {
    case breastMilk = "breast milk"
    case formula = "formula"
    case fortifiedBreastMilk = "fortified breast milk"
    case solidFood = "solid food"
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum FeedingMethod: String, Codable, CaseIterable, Identifiable {
    case bottle = "bottle"
    case leftBreast = "left breast"
    case rightBreast = "right breast"
    case bothBreasts = "both breasts"
    case parentFed = "parent fed"
    case selfFed = "self fed"
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum DiaperColor: String, Codable, CaseIterable, Identifiable {
    case black, brown, green, yellow
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Which way a manual stash adjustment moves milk: into the stash, or out of it.
enum StashKind: String, Codable, CaseIterable, Identifiable {
    case added, discarded
    var id: String { rawValue }
    var sign: Double { self == .added ? 1 : -1 }
    var label: String { self == .added ? "Added" : "Discarded" }
}

/// How old a stash lot (or the stash as a whole, by its oldest lot) is.
enum StashStatus: String, Codable {
    case ok, warn, expired

    var label: String {
        switch self {
        case .ok: return "Fresh"
        case .warn: return "Use first"
        case .expired: return "Expired"
        }
    }
}

// MARK: - Resources
//
// Each DTO carries the full set of serializer fields. Read-only fields (`id`,
// `duration`, `slug`, `picture`) are optional so the same struct can also be encoded
// for writes — DRF silently ignores read-only fields on input. `timer` is write-only
// and only set when converting a stopped timer into an entry.

struct ChildDTO: APIResource {
    static let path = "children"
    var id: Int?
    var first_name: String
    var last_name: String
    var birth_date: Date
    var birth_time: Date?
    var slug: String?
    var picture: String?

    var displayName: String { [first_name, last_name].filter { !$0.isEmpty }.joined(separator: " ") }
}

struct FeedingDTO: APIResource {
    static let path = "feedings"
    var id: Int?
    var child: Int
    var start: Date
    var end: Date
    var duration: String?
    var type: FeedingType
    var method: FeedingMethod
    var amount: Double?
    var notes: String?
    var tags: [String]?
    var timer: Int?
    // Milk stash fields (only on a server with the milk stash).
    /// Millilitres of this bottle taken from the stash.
    var stash_amount: Double?
    /// Millilitres of it discarded (spilled, left over), backed by a linked stash adjustment.
    var stash_discarded: Double?
    /// Free-text reason for the discard, `""` when none.
    var stash_discard_reason: String?
    /// The parent who breastfed; kept by the server only on breast methods.
    var parent: Int?
}

struct DiaperChangeDTO: APIResource {
    static let path = "changes"
    var id: Int?
    var child: Int
    var time: Date
    var wet: Bool?
    var solid: Bool?
    var color: DiaperColor?
    var amount: Double?
    var notes: String?
    var tags: [String]?
}

struct SleepDTO: APIResource {
    static let path = "sleep"
    var id: Int?
    var child: Int
    var start: Date
    var end: Date
    var duration: String?
    var nap: Bool?
    var notes: String?
    var tags: [String]?
    var timer: Int?
}

struct TummyTimeDTO: APIResource {
    static let path = "tummy-times"
    var id: Int?
    var child: Int
    var start: Date
    var end: Date
    var duration: String?
    var milestone: String?
    var tags: [String]?
    var timer: Int?
}

struct PumpingDTO: APIResource {
    static let path = "pumping"
    var id: Int?
    /// `nil` for pumping logged on a parent (a server with the milk stash).
    var child: Int?
    var parent: Int?
    /// Millilitres of this session put into the stash.
    var stash_amount: Double?
    var start: Date
    var end: Date
    var duration: String?
    var amount: Double?
    var notes: String?
    var tags: [String]?
    var timer: Int?
}

struct NoteDTO: APIResource {
    static let path = "notes"
    var id: Int?
    var child: Int
    var note: String
    var time: Date
    var tags: [String]?
}

struct TimerDTO: APIResource {
    static let path = "timers"
    var id: Int?
    var child: Int?
    var name: String?
    var start: Date
    var duration: String?
    var user: Int?
}

struct WeightDTO: APIResource {
    static let path = "weight"
    var id: Int?
    var child: Int
    var weight: Double
    var date: Date
    var notes: String?
    var tags: [String]?
}

struct HeightDTO: APIResource {
    static let path = "height"
    var id: Int?
    var child: Int
    var height: Double
    var date: Date
    var notes: String?
    var tags: [String]?
}

struct HeadCircumferenceDTO: APIResource {
    static let path = "head-circumference"
    var id: Int?
    var child: Int
    var head_circumference: Double
    var date: Date
    var notes: String?
    var tags: [String]?
}

struct TemperatureDTO: APIResource {
    static let path = "temperature"
    var id: Int?
    var child: Int
    var temperature: Double
    var time: Date
    var notes: String?
    var tags: [String]?
}

struct BMIDTO: APIResource {
    static let path = "bmi"
    var id: Int?
    var child: Int
    var bmi: Double
    var date: Date
    var notes: String?
    var tags: [String]?
}

struct MedicationDTO: APIResource {
    static let path = "medication"
    var id: Int?
    var child: Int
    var name: String
    var dosage: Double?
    var dosage_unit: String?
    var time: Date
    var next_dose_interval: String?
    var notes: String?
    var tags: [String]?
}

struct ParentDTO: APIResource {
    static let path = "parents"
    var id: Int?
    var first_name: String
    var last_name: String?
    var slug: String?
    var picture: String?
    var children: [Int]
    /// Whether the parent produces breast milk: only those pump, breastfeed or own stash milk.
    /// Missing (a server from before the flag) means true, the server's default.
    var produces_milk: Bool?
}

/// A user-defined event type, on a server with events. Looked up by its `slug`, which is fixed when
/// the type is created and survives a rename.
struct EventTypeDTO: APIResource {
    static let path = "event-types"
    var id: Int?
    var name: String
    var slug: String
}

/// Something that happened to a child, of one event type: `type` is that type's slug.
struct EventDTO: APIResource {
    static let path = "events"
    var id: Int?
    var child: Int
    var type: String
    var time: Date
    var notes: String?
    var tags: [String]?
}

struct StashAdjustmentDTO: APIResource {
    static let path = "stash-adjustments"
    var id: Int?
    var time: Date
    var amount: Double
    var kind: StashKind
    /// Free text, `""` when empty.
    var reason: String?
    /// `amount` signed by `kind`; read-only.
    var signed_amount: Double?
    var parent: Int?
    /// Set only on a discard linked to a bottle; read-only in the app.
    var feeding: Int?
    var notes: String?
    var tags: [String]?
}

/// One lot of milk still in the stash (`GET /api/stash`), oldest first.
struct StashLotDTO: Codable, Equatable {
    var time: Date
    var amount: Double
    /// The unrounded lot amount, so throwing the lot away empties it exactly. Optional so a
    /// summary cached before the server sent it still decodes.
    var throw_away_amount: Double?
    var age_hours: Double
    var warn_at: Date
    var expires_at: Date
    var status: StashStatus
    /// True only on the oldest expired lot, the one milk can be thrown away from on its own.
    var is_oldest_expired: Bool?
    /// Whose milk the lot is: its pumping's parent, or an "added" entry's; nil for neither.
    var parent: Int? = nil
}

/// The server's milk stash summary (`GET /api/stash`). The server is authoritative: it runs FIFO
/// over the whole history, which the app only syncs a recent window of.
struct StashSummaryDTO: Codable, Equatable {
    struct Defaults: Codable, Equatable { var pumping_to_stash: Bool; var bottle_from_stash: Bool }
    /// Can be negative.
    var balance: Double
    var status: StashStatus
    var warn_age_hours: Double
    var max_age_hours: Double
    var oldest: Date?
    var oldest_age_hours: Double?
    var lots: [StashLotDTO]
    var defaults: Defaults
    /// When the balance last dropped below zero; nil while it isn't (or from a server that doesn't
    /// send it). Identifies the current dip, so a dismissed warning returns for the next one.
    var negative_since: Date? = nil
}

struct TagDTO: Codable, Identifiable, Hashable {
    var slug: String?
    var name: String
    var color: String?
    var last_used: Date?
    var id: String { slug ?? name }
}

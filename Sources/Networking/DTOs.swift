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

/// Which way a milk stash entry moves milk: into the stash, or out of it.
enum StashKind: String, Codable, CaseIterable, Identifiable {
    case added, discarded
    var id: String { rawValue }
    var label: String { self == .added ? "Added" : "Discarded" }
}

/// How old milk in the stash is.
enum StashStatus: String, Codable {
    case ok, warn, expired

    var label: String {
        switch self {
        case .ok: return "Fresh"
        case .warn: return "Expiring soon"
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
    /// Whether this bottle's milk came from the milk stash (a server with the milk stash only).
    var from_stash: Bool?
    var notes: String?
    var tags: [String]?
    var timer: Int?
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
    var child: Int
    var start: Date
    var end: Date
    var duration: String?
    var amount: Double?
    /// Whether the milk went into the milk stash (a server with the milk stash only).
    var to_stash: Bool?
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

/// Milk added to the milk stash or discarded from it by hand.
struct StashAdjustmentDTO: APIResource {
    static let path = "stash-adjustments"
    var id: Int?
    var time: Date
    var amount: Double
    var kind: StashKind
    var notes: String?
    var tags: [String]?
}

/// Milk still in the stash from one moment (`GET /api/stash`).
struct StashLotDTO: Codable, Equatable {
    var time: Date
    var amount: Double
    var warn_at: Date
    var expires_at: Date
    /// The server's status when the summary was made; ``status(at:)`` is current.
    var status: StashStatus
    /// The movement in that this lot is what's left of; absent on a server from before it.
    var source: StashLotSourceDTO? = nil

    func status(at now: Date) -> StashStatus {
        if now >= expires_at { return .expired }
        if now >= warn_at { return .warn }
        return .ok
    }
}

/// Where a lot of milk came from: a pumping into the stash, or milk added by hand.
struct StashLotSourceDTO: Codable, Equatable {
    /// `pumping` or `stash_adjustment`.
    var type: String
    /// That record's id in `/api/pumping/` or `/api/stash-adjustments/`.
    var id: Int
}

/// The milk stash (`GET /api/stash`). The server works it out over the whole history, which the app
/// only syncs a recent window of.
struct StashSummaryDTO: Codable, Equatable {
    /// Below zero when more was taken out than was put in; the lots are empty then.
    var balance: Double
    var status: StashStatus
    var warn_age_hours: Double
    var max_age_hours: Double
    var expired_amount: Double
    /// Oldest first.
    var lots: [StashLotDTO]

    /// The status of the oldest milk at `now`.
    func status(at now: Date) -> StashStatus {
        lots.map { $0.status(at: now) }.max { $0.rank < $1.rank } ?? .ok
    }

    /// How much of the milk has expired at `now`.
    func expiredAmount(at now: Date) -> Double {
        lots.filter { $0.status(at: now) == .expired }.reduce(0) { $0 + $1.amount }
    }
}

private extension StashStatus {
    var rank: Int {
        switch self {
        case .ok: return 0
        case .warn: return 1
        case .expired: return 2
        }
    }
}

struct TagDTO: Codable, Identifiable, Hashable {
    var slug: String?
    var name: String
    var color: String?
    var last_used: Date?
    var id: String { slug ?? name }
}

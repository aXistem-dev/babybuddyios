import Foundation

/// When a child is likely to feed next, from their own recent feeds: "usually every ~2h 45m, next
/// around 3:15". The median of the last few gaps, no tuning per child, and clearly an estimate:
/// nothing is shown while the history is short or irregular, or once the time has passed.
///
/// Babies differ widely in how often they feed (Kent et al. 2006, Pediatrics: 6 to 18 breastfeeds
/// a day), so the estimate only uses this child's own history. Gaps are measured from the start of
/// one feed to the start of the next, as in feeding-pattern studies (Casiday et al. 2004). The amount
/// fed isn't used: a feed's size goes with the gap before it far more than the gap after it
/// (Matheny et al. 1990), and the NHS notes that a big feed doesn't mean a longer gap.
///
/// Pure: the Dashboard and the status widget both call ``compute(from:childID:now:)`` on the cached
/// records.
struct FeedEstimate: Equatable {
    /// The typical time from the start of one feed to the start of the next.
    let interval: TimeInterval
    /// When the next feed is likely to start, to the nearest 15 minutes.
    let next: Date

    // MARK: Rules

    /// Feeds starting this soon after the previous one ended are one feed (one breast then the
    /// other, a top-up).
    static let sessionGap: TimeInterval = 30 * 60
    /// Only feeds this recent count: about two days of gaps even at 4–5 feeds a day.
    static let lookBack: TimeInterval = 3 * 86_400
    /// The gaps used: the last ten, so day and night are both in.
    static let gapCount = 10
    /// Gaps whose middle half spreads over more than this share of the typical gap (cluster
    /// feeding, an irregular day) give no estimate.
    static let widestSpread = 0.5
    /// The estimate is shown to the nearest quarter hour.
    static let rounding: TimeInterval = 15 * 60

    // MARK: Settings

    /// Off by default. Kept in the App Group's defaults so the status widget reads the same.
    enum Settings {
        static let enabledKey = "nextFeedEstimateEnabled"

        static var isEnabled: Bool { SharedDefaults.suite.bool(forKey: enabledKey) }
    }

    // MARK: Steps

    /// One logged milk feed (solid food follows mealtimes, not the milk rhythm, so it's left out).
    struct Feed: Equatable {
        let start: Date
        let end: Date
    }

    static func compute(from entities: [LocalEntity], childID: Int, now: Date = .now) -> FeedEstimate? {
        estimate(feeds: entities.compactMap { feed(from: $0, childID: childID) }, now: now)
    }

    static func feed(from entity: LocalEntity, childID: Int) -> Feed? {
        guard entity.kind == .feeding, entity.childID == childID, entity.syncState != .pendingDelete,
              let start = entity.startEndDates.start,
              entity.payloadObject["type"] as? String != "solid food" else { return nil }
        return Feed(start: start, end: max(entity.startEndDates.end ?? start, start))
    }

    static func estimate(feeds: [Feed], now: Date) -> FeedEstimate? {
        let recent = feeds
            .filter { $0.start <= now && now.timeIntervalSince($0.start) <= lookBack }
            .sorted { $0.start < $1.start }
        let starts = sessionStarts(recent)
        let gaps = zip(starts, starts.dropFirst()).map { $1.timeIntervalSince($0) }.suffix(gapCount)
        guard gaps.count == gapCount, let last = starts.last else { return nil }

        let median = quantile(Array(gaps), 0.5)
        guard median > 0, quantile(Array(gaps), 0.75) - quantile(Array(gaps), 0.25) <= median * widestSpread
        else { return nil }
        let next = rounded(last.addingTimeInterval(median))
        guard next >= now else { return nil }
        return FeedEstimate(interval: median, next: next)
    }

    /// The start of each feed, counting feeds (sorted by start) that begin within ``sessionGap`` of
    /// the previous one's end as one.
    static func sessionStarts(_ feeds: [Feed]) -> [Date] {
        var starts: [Date] = []
        var end = Date.distantPast
        for feed in feeds {
            if feed.start.timeIntervalSince(end) > sessionGap { starts.append(feed.start) }
            end = max(end, feed.end)
        }
        return starts
    }

    /// The `q` quantile of `values`, interpolating between the two nearest (the median of an even
    /// count is the mean of the middle two).
    static func quantile(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let position = Double(sorted.count - 1) * q
        let low = Int(position.rounded(.down)), high = min(low + 1, sorted.count - 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }

    static func rounded(_ date: Date) -> Date {
        let seconds = date.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / rounding).rounded() * rounding)
    }

    // MARK: Wording

    /// "~2h 45m", to the nearest 5 minutes.
    var intervalText: String {
        let minutes = Int((interval / 300).rounded()) * 5
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "~\(m)m" }
        return m == 0 ? "~\(h)h" : "~\(h)h \(m)m"
    }

    private var timeText: String { next.formatted(date: .omitted, time: .shortened) }

    /// The widget's short form: "next ~3:15 AM".
    var shortText: String { "next ~\(timeText)" }

    /// The whole line: "Usually every ~2h 45m · next around 3:15 AM".
    var line: String { "Usually every \(intervalText) \u{00B7} next around \(timeText)" }
}

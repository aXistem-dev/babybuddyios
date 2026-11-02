import XCTest
@testable import BabyBuddy

/// The next-feed estimate: which feeds count, the median of the last ten gaps, and when nothing is
/// shown.
@MainActor
final class FeedEstimateTests: XCTestCase {
    /// 2026-06-15 12:00 UTC, on a quarter hour.
    private let now = Date(timeIntervalSince1970: 1_781_524_800)

    /// The switch lives in the shared App Group defaults, so a run starts and ends without it.
    override func setUp() async throws { SharedDefaults.suite.removeObject(forKey: FeedEstimate.Settings.enabledKey) }

    override func tearDown() async throws { SharedDefaults.suite.removeObject(forKey: FeedEstimate.Settings.enabledKey) }

    private func hours(_ h: Double) -> Date { now.addingTimeInterval(h * 3_600) }

    private func feed(_ hoursAgo: Double, minutes: Double = 15) -> FeedEstimate.Feed {
        .init(start: hours(-hoursAgo), end: hours(-hoursAgo).addingTimeInterval(minutes * 60))
    }

    /// `count` feeds `every` hours apart, the newest `newest` hours ago.
    private func regular(every: Double, count: Int, newest: Double = 1) -> [FeedEstimate.Feed] {
        (0..<count).map { feed(newest + Double($0) * every) }
    }

    /// Feeds with these gaps (oldest first), the newest `newest` hours ago.
    private func gaps(_ gaps: [Double], newest: Double) -> [FeedEstimate.Feed] {
        var hoursAgo = newest
        var feeds = [feed(hoursAgo, minutes: 10)]
        for gap in gaps.reversed() {
            hoursAgo += gap
            feeds.append(feed(hoursAgo, minutes: 10))
        }
        return feeds
    }

    private func estimate(_ feeds: [FeedEstimate.Feed]) -> FeedEstimate? {
        FeedEstimate.estimate(feeds: feeds, now: now)
    }

    func testNeedsTenGaps() {
        XCTAssertNil(estimate(regular(every: 2.5, count: 10)), "Nine gaps")
        XCTAssertNotNil(estimate(regular(every: 2.5, count: 11)))
    }

    func testSteadyPattern() throws {
        let e = try XCTUnwrap(estimate(regular(every: 2.5, count: 15)))
        XCTAssertEqual(e.interval, 2.5 * 3_600)
        XCTAssertEqual(e.next, hours(1.5))
        XCTAssertEqual(e.intervalText, "~2h 30m")
    }

    /// Last feed an hour ago, every 2h 40m: due in 1h 40m, shown as 1h 45m.
    func testRoundsToAQuarterHour() throws {
        let e = try XCTUnwrap(estimate(regular(every: 2 + 40.0 / 60, count: 12)))
        XCTAssertEqual(e.next, hours(1.75))
    }

    /// A feed starting within 30 minutes of the previous one's end is the same feed.
    func testCloseFeedsAreOneFeed() {
        let first = feed(5)                                   // ends 4h 45m ago
        let joined = feed(4.25)                               // 30 min after: same feed, ends 4h ago
        let separate = feed(4 - 31.0 / 60)                    // 31 min after that: a new feed
        XCTAssertEqual(FeedEstimate.sessionStarts([first, joined, separate]), [first.start, separate.start])
    }

    /// Only the last three days count, however many older feeds there are.
    func testOlderFeedsDontCount() {
        let older = (0..<20).map { feed(73 + Double($0) * 2.5) }
        XCTAssertNil(estimate(older + regular(every: 2.5, count: 5)))
    }

    /// Cluster feeding: mostly hourly with a few 3-hour gaps, too irregular to estimate.
    func testClusterFeedingShowsNothing() {
        XCTAssertNil(estimate(gaps([1, 1, 1, 3, 1, 1, 3, 1, 3.5, 1], newest: 0.5)))
    }

    /// Gaps between 2h 15m and 3h: the median, 2h 37.5m.
    func testModerateSpreadShows() throws {
        let e = try XCTUnwrap(estimate(gaps([2.5, 3, 2.5, 3, 2.75, 2.5, 3, 2.25, 3, 2.5], newest: 40.0 / 60)))
        XCTAssertEqual(e.interval, 2.625 * 3_600, accuracy: 0.001)
        XCTAssertEqual(e.next, hours(2))
    }

    /// One long night gap doesn't move the median.
    func testOneLongGapDoesntMatter() throws {
        let e = try XCTUnwrap(estimate(gaps([2.5, 2.5, 2.5, 2.5, 8, 2.5, 2.5, 2.5, 2.5, 2.5], newest: 1)))
        XCTAssertEqual(e.interval, 2.5 * 3_600)
    }

    func testHiddenOnceTheTimeHasPassed() {
        XCTAssertNil(estimate(regular(every: 2, count: 12, newest: 2.5)), "Due half an hour ago")
        XCTAssertEqual(estimate(regular(every: 2, count: 12, newest: 2))?.next, now, "Due now")
    }

    func testWording() {
        let e = FeedEstimate(interval: 2 * 3_600 + 44 * 60, next: now)
        XCTAssertEqual(e.intervalText, "~2h 45m")
        XCTAssertTrue(e.line.hasPrefix("Usually every ~2h 45m \u{00B7} next around "))
        XCTAssertTrue(e.shortText.hasPrefix("next ~"))
        XCTAssertEqual(FeedEstimate(interval: 44 * 60, next: now).intervalText, "~45m")
    }

    // MARK: From the cached records

    private func entity(_ hoursAgo: Double, child: Int = 1, type: String = "breast milk",
                        state: SyncState = .synced) -> LocalEntity {
        let start = hours(-hoursAgo)
        let payload: [String: Any] = [
            "child": child, "type": type, "method": type == "solid food" ? "parent fed" : "left breast",
            "start": APIDate.isoDateTime.string(from: start),
            "end": APIDate.isoDateTime.string(from: start.addingTimeInterval(900)),
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return LocalEntity(kind: .feeding, serverID: nil, childID: child,
                           timestamp: EntityKind.feeding.timestamp(from: payload), payload: data, syncState: state)
    }

    /// Solid food between milk feeds doesn't split their gaps.
    func testSolidFoodIsLeftOut() throws {
        let milk = stride(from: 1.0, through: 40, by: 3).map { entity($0) }
        let solids = stride(from: 2.5, through: 40, by: 3).map { entity($0, type: "solid food") }
        let e = try XCTUnwrap(FeedEstimate.compute(from: milk + solids, childID: 1, now: now))
        XCTAssertEqual(e.interval, 3 * 3_600)
    }

    /// The status widget gets an estimate only while it's switched on (off by default), for this
    /// child, from records that aren't being deleted.
    func testChildStatusFollowsTheSwitch() {
        let feeds = stride(from: 1.0, through: 70, by: 3).map { entity($0) }
        XCTAssertFalse(FeedEstimate.Settings.isEnabled, "Off by default")
        XCTAssertNil(ChildStatus.compute(from: feeds, childID: 1, now: now).nextFeed)

        SharedDefaults.suite.set(true, forKey: FeedEstimate.Settings.enabledKey)
        XCTAssertEqual(ChildStatus.compute(from: feeds, childID: 1, now: now).nextFeed?.next, hours(2))
        XCTAssertNil(ChildStatus.compute(from: feeds, childID: 2, now: now).nextFeed, "Another child's feeds")
        let deleting = stride(from: 1.0, through: 70, by: 3).map { entity($0, state: .pendingDelete) }
        XCTAssertNil(FeedEstimate.compute(from: deleting, childID: 1, now: now))
    }
}

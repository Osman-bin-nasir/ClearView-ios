import XCTest
@testable import ClearView

/// Tests for the Protection tab's pure logic: the anonymous identity, the Activity
/// dashboard's aggregation and the submission status rules.
final class ProtectionStatsTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!

    /// A UTC instant at a given day/time, so the assertions are about days and not about
    /// the machine's zone.
    private func at(_ day: Int, _ hour: Int = 12) -> Int64 {
        let base: Int64 = 1_800_000_000_000  // 2027-01-15T08:00:00Z, an arbitrary anchor
        let dayStart = BlockActivityStats.dayIndex(base, timeZone: utc)
        return dayStart + Int64(day) * 86_400_000 + Int64(hour) * 3_600_000
    }

    // MARK: - The anonymous id

    /// The id is generated once and reused, so reports from one device de-duplicate.
    func testTheAnonymousIdIsStable() {
        let suite = "AnonymousIdTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AnonymousIdStore(defaults: defaults)

        let first = store.current
        XCTAssertTrue(AnonymousIdStore.isValid(first))
        XCTAssertEqual(store.current, first, "the same id every time")
        XCTAssertEqual(AnonymousIdStore(defaults: defaults).current, first, "and across instances")
        XCTAssertTrue(store.hasStoredId)
    }

    /// Regenerating replaces the id, and resetting forgets it so the next read mints a new
    /// one.
    func testRegeneratingAndResetting() {
        let suite = "AnonymousIdRegenTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AnonymousIdStore(defaults: defaults)

        let first = store.current
        let second = store.regenerate()

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(store.current, second)

        store.reset()
        XCTAssertFalse(store.hasStoredId)
        XCTAssertNotEqual(store.current, second, "a forgotten id is replaced, not resurrected")
    }

    /// A corrupted id is replaced rather than sent: the server refuses anything that is not
    /// a canonical UUID, so keeping it would earn the same rejection forever.
    func testACorruptedIdIsReplaced() {
        let suite = "AnonymousIdCorruptTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("not-a-uuid", forKey: AnonymousIdStore.Key.anonymousId)
        let store = AnonymousIdStore(defaults: defaults)

        XCTAssertFalse(store.hasStoredId)
        XCTAssertTrue(AnonymousIdStore.isValid(store.current))
    }

    /// The validity rule: canonical UUIDs only.
    func testTheValidityRule() {
        XCTAssertTrue(AnonymousIdStore.isValid("6BA7B810-9DAD-11D1-80B4-00C04FD430C8"))
        XCTAssertTrue(AnonymousIdStore.isValid("6ba7b810-9dad-11d1-80b4-00c04fd430c8"))
        XCTAssertFalse(AnonymousIdStore.isValid(nil))
        XCTAssertFalse(AnonymousIdStore.isValid(""))
        XCTAssertFalse(AnonymousIdStore.isValid("   "))
        XCTAssertFalse(AnonymousIdStore.isValid("6ba7b8109dad11d180b400c04fd430c8"), "no dashes")
        XCTAssertFalse(
            AnonymousIdStore.isValid("{6ba7b810-9dad-11d1-80b4-00c04fd430c8}"),
            "braces are not canonical"
        )
        XCTAssertFalse(AnonymousIdStore.isValid("6ba7b810-9dad-11d1-80b4-00c04fd430c"), "too short")
    }

    // MARK: - The Activity summary

    /// Today, the week and the total, counted by local day.
    func testCountsArePerLocalDay() {
        let events = [
            BlockEvent(atMs: at(0, 9), category: "Adult"),
            BlockEvent(atMs: at(0, 23), category: "Adult"),
            BlockEvent(atMs: at(-3), category: "Brain Rot"),
            BlockEvent(atMs: at(-10), category: "Adult"),
        ]

        let summary = BlockActivityStats.summarise(events, nowMs: at(0, 23), timeZone: utc)

        XCTAssertEqual(summary.totalBlocks, 4)
        XCTAssertEqual(summary.todayBlocks, 2)
        XCTAssertEqual(summary.weekBlocks, 3, "the last seven local days, today included")
    }

    /// The top lists are ordered by count, ties broken alphabetically so two identical
    /// scans cannot reshuffle the dashboard.
    func testTopListsAreOrderedAndTieBroken() {
        let events = [
            BlockEvent(atMs: at(0), category: "Adult", keyword: "Gambling"),
            BlockEvent(atMs: at(0), category: "Adult", keyword: "gambling"),
            BlockEvent(atMs: at(0), category: "Brain Rot", keyword: "Drama", channel: "ChanB"),
            BlockEvent(atMs: at(0), category: "Adult", keyword: "Gambling"),
            BlockEvent(atMs: at(0), category: "Search", keyword: "Casino", channel: "ChanA"),
        ]

        let summary = BlockActivityStats.summarise(events, nowMs: at(0), timeZone: utc)

        XCTAssertEqual(summary.topKeywords.map(\.keyword), ["gambling", "casino", "drama"], "case-insensitive")
        XCTAssertEqual(summary.topKeywords.map(\.count), [3, 1, 1])
        XCTAssertEqual(summary.topChannels.map(\.channel), ["chana", "chanb"])
        XCTAssertEqual(
            summary.blocksByCategory.map(\.category),
            ["Adult", "Brain Rot", "Search"],
            "categories keep the app's own casing"
        )
        XCTAssertEqual(summary.blocksByCategory.first?.count, 3)
    }

    /// The top lists are capped, keeping the highest counts.
    func testTopListsAreCapped() {
        let events = (0..<8).map { index in
            BlockEvent(atMs: at(0), category: "Adult", keyword: "term\(index)")
        }

        let summary = BlockActivityStats.summarise(events, nowMs: at(0), timeZone: utc)

        XCTAssertEqual(summary.topKeywords.count, BlockActivityStats.topCount)
        XCTAssertEqual(summary.topKeywords.map(\.keyword), ["term0", "term1", "term2", "term3", "term4"])
    }

    /// The streak counts consecutive days backwards from today, and today still counting
    /// as "in progress" rather than breaking it.
    func testTheStreak() {
        // Today and the two days before it.
        let threeDays = [at(0), at(-1), at(-2)]
            .map { BlockEvent(atMs: $0, category: "Adult") }
        XCTAssertEqual(BlockActivityStats.summarise(threeDays, nowMs: at(0), timeZone: utc).streakDays, 3)

        // Nothing today yet, but yesterday and the day before: the streak survives the
        // morning.
        let sinceYesterday = [at(-1), at(-2)]
            .map { BlockEvent(atMs: $0, category: "Adult") }
        XCTAssertEqual(
            BlockActivityStats.summarise(sinceYesterday, nowMs: at(0), timeZone: utc).streakDays,
            2,
            "a day with no blocks yet does not break the streak"
        )

        // A gap two days back ends the run.
        let gapped = [at(0), at(-1), at(-3)]
            .map { BlockEvent(atMs: $0, category: "Adult") }
        XCTAssertEqual(BlockActivityStats.summarise(gapped, nowMs: at(0), timeZone: utc).streakDays, 2)

        XCTAssertEqual(
            BlockActivityStats.summarise([BlockEvent(atMs: at(-5), category: "Adult")], nowMs: at(0), timeZone: utc).streakDays,
            0,
            "a gap longer than a day is no streak at all"
        )
    }

    /// Blank keywords and channels are not counted, and no events is an empty summary.
    func testBlankValuesAndNoEvents() {
        let events = [
            BlockEvent(atMs: at(0), category: "Adult", keyword: "   ", channel: ""),
            BlockEvent(atMs: at(0), category: "", keyword: "term"),
        ]

        let summary = BlockActivityStats.summarise(events, nowMs: at(0), timeZone: utc)

        XCTAssertEqual(summary.topKeywords.map(\.keyword), ["term"])
        XCTAssertTrue(
            summary.topChannels.isEmpty,
            "the first event has a blank channel, and the second has none"
        )
        XCTAssertEqual(
            summary.blocksByCategory.map(\.category),
            ["Adult"],
            "the second event's blank category is dropped, not counted"
        )
        XCTAssertEqual(summary.totalBlocks, 2, "the blocks themselves are still counted")

        XCTAssertEqual(BlockActivityStats.summarise([], nowMs: at(0), timeZone: utc), BlockActivitySummary())
    }

    /// The stored log is bounded: the newest events are kept and the oldest fall off.
    func testTheEventLogIsTrimmedToTheNewest() {
        var events: [BlockEvent] = []
        for index in 0..<(BlockActivityStats.maxEvents + 10) {
            events = BlockActivityStats.append(events, BlockEvent(atMs: Int64(index), category: "Adult"))
        }

        XCTAssertEqual(events.count, BlockActivityStats.maxEvents)
        XCTAssertEqual(events.first?.atMs, 10, "the ten oldest fell off")
        XCTAssertEqual(events.last?.atMs, Int64(BlockActivityStats.maxEvents + 9))
    }

    /// The day boundary is a parameter, so "today" is the day it is *there*: the same
    /// instant can be two different days in two zones, and that is the caller's decision,
    /// not an accident of the machine.
    func testTheDayIndexDependsOnTheZone() {
        let midnightUtc = at(0, 0)
        XCTAssertEqual(BlockActivityStats.dayIndex(midnightUtc, timeZone: utc), midnightUtc)

        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertNotEqual(
            BlockActivityStats.dayIndex(midnightUtc, timeZone: tokyo),
            BlockActivityStats.dayIndex(midnightUtc, timeZone: losAngeles)
        )
    }

    // MARK: - Submission status

    /// Approved-and-still-live is the only state that reads as approved; approved-and-gone
    /// reads as removed, so the screen never claims a rule is in force when it is not.
    func testTheDisplayStatus() {
        XCTAssertEqual(SubmissionStatus.display(status: "approved", liveGlobally: true), "approved")
        XCTAssertEqual(SubmissionStatus.display(status: "approved", liveGlobally: false), "removed")
        XCTAssertEqual(SubmissionStatus.display(status: "rejected", liveGlobally: false), "rejected")
        XCTAssertEqual(
            SubmissionStatus.display(status: "rejected", liveGlobally: true),
            "rejected",
            "a rule that is live for everyone else does not change what happened to this request"
        )
        XCTAssertEqual(SubmissionStatus.display(status: "pending", liveGlobally: false), "pending")
    }

    /// A removed request reads as never sent, which is what offers the Send action again.
    func testTheEffectiveStatusAndResending() {
        XCTAssertNil(SubmissionStatus.effective(status: "approved", liveGlobally: false))
        XCTAssertEqual(SubmissionStatus.effective(status: "approved", liveGlobally: true), "approved")
        XCTAssertEqual(SubmissionStatus.effective(status: "rejected", liveGlobally: false), "rejected")

        XCTAssertTrue(SubmissionStatus.canResend(status: "rejected", liveGlobally: false))
        XCTAssertTrue(SubmissionStatus.canResend(status: "approved", liveGlobally: false))
        XCTAssertFalse(SubmissionStatus.canResend(status: "approved", liveGlobally: true))
        XCTAssertFalse(SubmissionStatus.canResend(status: "pending", liveGlobally: false))
    }

    /// The row's wording, which is about what happened rather than about the wire value.
    func testTheStatusLabels() {
        XCTAssertEqual(SubmissionStatus.label(status: "approved", liveGlobally: true), "Blocked for everyone")
        XCTAssertEqual(SubmissionStatus.label(status: "approved", liveGlobally: false), "Was blocked, since removed")
        XCTAssertEqual(SubmissionStatus.label(status: "rejected", liveGlobally: false), "Not added")
        XCTAssertEqual(SubmissionStatus.label(status: "pending", liveGlobally: false), "Waiting for review")
        XCTAssertEqual(SubmissionStatus.label(status: "something-else", liveGlobally: true), "Unknown")
    }
}

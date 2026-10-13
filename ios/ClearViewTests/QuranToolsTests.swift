import XCTest
@testable import ClearView
import SharedKotlin

/// Tests for the Quran tab's *tools* — the parts of the slice that are not the
/// reader: the Islamic date, the Dhikr counter, and the reminder's cadence and
/// notification rules.
///
/// The anchors used here are the ones the Android tests already assert against
/// (`IslamicDateFormatterTest`), which is deliberate: they were confirmed on the JVM
/// against `java.time`'s Umm al-Qura table, so if iOS's `.islamicUmmAlQura` disagreed
/// the failure is a real cross-platform divergence and not a mistake in this file.
final class QuranToolsTests: XCTestCase {

    // MARK: - The Islamic date

    /// The Gregorian day `2025-01-01` in UTC, at midday — safely inside the day, so
    /// the assertion is about the date and not about where the time zone happens to
    /// put midnight.
    private func utcDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private let utc = TimeZone(identifier: "UTC")!

    /// The Islamic New Year, and the anchor a reader is most likely to notice being
    /// wrong by a day.
    func testJune26th2025IsOneMuharram1447() {
        XCTAssertEqual(
            IslamicDate.format(date: utcDate(2025, 6, 26), timeZone: utc),
            "1 Muharram 1447 AH"
        )
    }

    /// A second JVM-confirmed anchor, half a year away from the first — so a
    /// systematic off-by-one in the table conversion cannot pass both.
    func testJanuary1st2025IsOneRajab1446() {
        XCTAssertEqual(
            IslamicDate.format(date: utcDate(2025, 1, 1), timeZone: utc),
            "1 Rajab 1446 AH"
        )
    }

    /// And a third, in 1448, where the two calendars' month lengths differ from the
    /// solar year.
    func testAugust10th2026Is27Safar1448() {
        XCTAssertEqual(
            IslamicDate.format(date: utcDate(2026, 8, 10), timeZone: utc),
            "27 Safar 1448 AH"
        )
    }

    /// The reason the conversion goes through the start of the day: the Islamic date
    /// must not depend on the hour the screen redrew. Only the user's ±1 adjustment
    /// may move it.
    func testTheDateDoesNotDependOnTheTimeOfDay() {
        let morning = IslamicDate.format(date: utcDate(2026, 8, 10, hour: 0), timeZone: utc)
        let night = IslamicDate.format(date: utcDate(2026, 8, 10, hour: 23), timeZone: utc)

        XCTAssertEqual(morning, "27 Safar 1448 AH")
        XCTAssertEqual(morning, night)
    }

    /// +1 shows the next Hijri day, −1 the previous, and the two are a day apart
    /// rather than a month or a year.
    func testTheAdjustmentMovesTheDateByExactlyOneDay() {
        let base = IslamicDate.hijriComponents(for: utcDate(2026, 8, 10), timeZone: utc)
        let plus = IslamicDate.hijriComponents(
            for: utcDate(2026, 8, 10), adjustmentDays: 1, timeZone: utc
        )
        let minus = IslamicDate.hijriComponents(
            for: utcDate(2026, 8, 10), adjustmentDays: -1, timeZone: utc
        )

        XCTAssertEqual(base.day, 27)
        XCTAssertEqual(plus.day, 28)
        XCTAssertEqual(minus.day, 26)
        XCTAssertEqual(plus.month, base.month)
        XCTAssertEqual(minus.month, base.month)
    }

    /// The month boundary: 29 Muharram 1448 + 1 day is 1 Safar 1448, not 30 Muharram.
    func testTheAdjustmentRollsOverAMonthBoundary() {
        XCTAssertEqual(
            IslamicDate.format(date: utcDate(2026, 7, 14), timeZone: utc),
            "29 Muharram 1448 AH"
        )
        XCTAssertEqual(
            IslamicDate.format(date: utcDate(2026, 7, 14), adjustmentDays: 1, timeZone: utc),
            "1 Safar 1448 AH"
        )
    }

    /// Twelve distinct month names, so the formatter can never index the wrong one
    /// silently.
    func testTheMonthNamesAreTheTwelveUmmAlQuraMonths() {
        XCTAssertEqual(IslamicDate.monthNames.count, 12)
        XCTAssertEqual(Set(IslamicDate.monthNames).count, 12)
        XCTAssertEqual(IslamicDate.monthNames.first, "Muharram")
        XCTAssertEqual(IslamicDate.monthNames.last, "Dhu al-Hijjah")
    }

    /// The adjustment is a ±1 preference, clamped on the way in and out: the store
    /// is what the settings sheet writes to, and a value of 5 there would move the
    /// date by five days without the formatter noticing.
    func testTheAdjustmentStoreClampsToPlusOrMinusOne() {
        let suite = "IslamicDateStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = IslamicDateStore(defaults: defaults)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(store.adjustmentDays, 0, "a fresh install uses the calculated date")

        store.adjustmentDays = 1
        XCTAssertEqual(store.adjustmentDays, 1)
        store.adjustmentDays = -1
        XCTAssertEqual(store.adjustmentDays, -1)
        store.adjustmentDays = 5
        XCTAssertEqual(store.adjustmentDays, 1)
        store.adjustmentDays = -9
        XCTAssertEqual(store.adjustmentDays, -1)

        store.reset()
        XCTAssertEqual(store.adjustmentDays, 0)
    }

    // MARK: - The Dhikr counter

    /// The built-ins are the six Android ships, with the classic targets.
    func testTheBuiltInDhikrAreTheSixWithTheirTargets() {
        let items = DhikrCodec.defaults()

        XCTAssertEqual(items.map(\.id), [
            "subhanallah", "alhamdulillah", "allahu-akbar",
            "la-ilaha-illallah", "astaghfirullah", "salawat",
        ])
        XCTAssertEqual(items.map(\.target), [33, 33, 34, 100, 100, 100])
        XCTAssertTrue(items.allSatisfy(\.visible))
        XCTAssertEqual(items.map(\.order), [0, 1, 2, 3, 4, 5])
        XCTAssertTrue(items.allSatisfy { !$0.arabic.isEmpty })
    }

    /// Every mutation is list-in, list-out, and the list survives the JSON round
    /// trip with the Android field names.
    func testTheListRoundTripsThroughTheStoredJson() {
        let items = DhikrCodec.incremented(DhikrCodec.defaults(), id: "subhanallah")
        let json = DhikrCodec.encode(items)

        XCTAssertTrue(json.contains("\"lastCompletedCount\""), "the Android field names, not Swift's")
        XCTAssertEqual(DhikrCodec.decode(json), items)
    }

    /// A stored record missing fields keeps what it has and defaults the rest —
    /// losing a count because one key is absent would be data loss, not validation.
    func testADecodedRecordFillsInMissingFields() {
        let json = """
        [{"id":"subhanallah","name":"SubhanAllah","count":7}]
        """

        let decoded = DhikrCodec.decode(json)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.count, 7)
        XCTAssertEqual(decoded.first?.target, DhikrItem.defaultTarget)
        XCTAssertEqual(decoded.first?.visible, true)
        XCTAssertEqual(decoded.first?.lastCompletedAt, 0)
    }

    /// One unreadable record does not take the others with it, and a record with no
    /// id is skipped rather than kept as an anonymous dhikr.
    func testOneBadRecordDoesNotLoseTheRest() {
        let json = """
        [
          {"id":"subhanallah","name":"SubhanAllah","count":4},
          "not an object",
          {"name":"no id at all","count":99},
          {"id":"alhamdulillah","name":"Alhamdulillah","count":2}
        ]
        """

        let decoded = DhikrCodec.decode(json)

        XCTAssertEqual(decoded.map(\.id), ["subhanallah", "alhamdulillah"])
        XCTAssertEqual(decoded.map(\.count), [4, 2])
    }

    /// A store that cannot be read at all is empty rather than a crash, which is what
    /// lets the store fall back to the built-ins.
    func testGarbageDecodesAsNothing() {
        XCTAssertEqual(DhikrCodec.decode("not json"), [])
        XCTAssertEqual(DhikrCodec.decode(""), [])
        XCTAssertEqual(DhikrCodec.decode(nil), [])
        XCTAssertEqual(DhikrCodec.decode("{}"), [])
    }

    /// Negative counts and targets are coerced on read. A hand-edited store should
    /// not produce a ring that draws backwards.
    func testNegativeNumbersAreCoercedOnDecode() {
        let json = """
        [{"id":"subhanallah","name":"S","target":-5,"count":-2,"lastCompletedCount":-1,"lastCompletedAt":-9}]
        """

        let decoded = DhikrCodec.decode(json).first

        XCTAssertEqual(decoded?.target, 0)
        XCTAssertEqual(decoded?.count, 0)
        XCTAssertEqual(decoded?.lastCompletedCount, 0)
        XCTAssertEqual(decoded?.lastCompletedAt, 0)
    }

    /// The crossing fires once — on the tap that reaches the target, not on the tap
    /// after it. This is what stops the celebration and the recorded session from
    /// repeating 3000 times.
    func testTheTargetIsCrossedExactlyOnce() {
        var items = DhikrCodec.withTarget(DhikrCodec.defaults(), id: "subhanallah", target: 3)

        var crossings = 0
        var at = Int64(1_000)
        for _ in 0..<5 {
            items = DhikrCodec.incremented(items, id: "subhanallah")
            if DhikrCodec.crossesTarget(items, id: "subhanallah") {
                crossings += 1
                items = DhikrCodec.markedCompleted(items, id: "subhanallah", at: at)
            }
            at += 1
        }

        XCTAssertEqual(crossings, 1)
        XCTAssertEqual(DhikrCodec.item(items, "subhanallah")?.count, 5)
        XCTAssertEqual(DhikrCodec.item(items, "subhanallah")?.lastCompletedCount, 3)
    }

    /// A dhikr with no target can never be "completed" — the ring stays empty and
    /// nothing is recorded, which is the difference between "no goal" and "goal 0
    /// reached".
    func testADhikrWithNoTargetNeverCrosses() {
        var items = DhikrCodec.withTarget(DhikrCodec.defaults(), id: "subhanallah", target: 0)
        items = DhikrCodec.incremented(items, id: "subhanallah")

        XCTAssertFalse(DhikrCodec.crossesTarget(items, id: "subhanallah"))
    }

    /// Resetting keeps the last completed session: it is history, and the "Last: 33"
    /// line is how the user knows they finished a round.
    func testResettingKeepsTheCompletedSession() {
        var items = DhikrCodec.defaults()
        items = DhikrCodec.incremented(items, id: "subhanallah")
        items = DhikrCodec.markedCompleted(items, id: "subhanallah", at: 42)
        items = DhikrCodec.resetItem(items, id: "subhanallah")

        let item = DhikrCodec.item(items, "subhanallah")
        XCTAssertEqual(item?.count, 0)
        XCTAssertEqual(item?.lastCompletedCount, 33)
        XCTAssertEqual(item?.lastCompletedAt, 42)
    }

    /// Resetting everything clears history but keeps the user's phrases and targets.
    func testResetAllProgressKeepsThePhrases() {
        var items = DhikrCodec.markedCompleted(DhikrCodec.incremented(DhikrCodec.defaults(), id: "salawat"), id: "salawat", at: 7)
        items = DhikrCodec.withTarget(items, id: "salawat", target: 1000)

        let reset = DhikrCodec.resetAllProgress(items)

        XCTAssertEqual(reset.map(\.id), DhikrCodec.defaults().map(\.id))
        XCTAssertEqual(DhikrCodec.item(reset, "salawat")?.target, 1000)
        XCTAssertEqual(DhikrCodec.item(reset, "salawat")?.count, 0)
        XCTAssertEqual(DhikrCodec.item(reset, "salawat")?.lastCompletedAt, 0)
    }

    /// A move is clamped at the ends and a no-op move returns the list untouched —
    /// both so the top row's "move up" can stay enabled without corrupting the order.
    func testMovesAreClampedAndReindexed() {
        let items = DhikrCodec.defaults()

        let up = DhikrCodec.moved(items, id: "subhanallah", delta: -1)
        XCTAssertEqual(up.map(\.id), items.map(\.id), "moving the first dhikr up changes nothing")

        let down = DhikrCodec.moved(items, id: "subhanallah", delta: 1)
        XCTAssertEqual(down.map(\.id).first, "alhamdulillah")
        XCTAssertEqual(down.map(\.id)[1], "subhanallah")
        XCTAssertEqual(down.map(\.order), [0, 1, 2, 3, 4, 5], "order is re-indexed to the new positions")
    }

    /// Editing a dhikr takes the four editable fields and nothing else: renaming a
    /// phrase must not reset the running count or the history.
    func testEditingKeepsTheCountAndHistory() {
        var items = DhikrCodec.incremented(DhikrCodec.defaults(), id: "subhanallah")
        items = DhikrCodec.markedCompleted(items, id: "subhanallah", at: 99)

        var edited = DhikrCodec.item(items, "subhanallah")!
        edited.name = "Subhan Allah"
        edited.target = 100
        edited.count = 0
        edited.lastCompletedAt = 0

        let updated = DhikrCodec.updated(items, item: edited)
        let item = DhikrCodec.item(updated, "subhanallah")

        XCTAssertEqual(item?.name, "Subhan Allah")
        XCTAssertEqual(item?.target, 100)
        XCTAssertEqual(item?.count, 1, "the count is the stored record's, not the edit's")
        XCTAssertEqual(item?.lastCompletedAt, 99)
    }

    /// A newly added dhikr lands at the end, visible, with its own id and order.
    func testAddingAppendsAVisibleDhikr() {
        let added = DhikrCodec.added(
            DhikrCodec.defaults(),
            item: DhikrItem(id: "custom-1", name: "Ya Allah", arabic: "يا الله", target: 1000)
        )

        XCTAssertEqual(added.count, 7)
        XCTAssertEqual(added.last?.id, "custom-1")
        XCTAssertEqual(added.last?.order, 6)
        XCTAssertEqual(added.last?.visible, true)
        XCTAssertEqual(added.last?.target, 1000)
    }

    /// Removing re-indexes the rest, so the stored order stays 0…n−1.
    func testRemovingReindexesTheRest() {
        let removed = DhikrCodec.removed(DhikrCodec.defaults(), id: "allahu-akbar")

        XCTAssertEqual(removed.map(\.id), ["subhanallah", "alhamdulillah", "la-ilaha-illallah", "astaghfirullah", "salawat"])
        XCTAssertEqual(removed.map(\.order), [0, 1, 2, 3, 4])
    }

    /// Hidden dhikr are skipped by the pager but still order the selection, and the
    /// pager wraps at both ends.
    func testThePagerSkipsHiddenDhikrAndWraps() {
        var items = DhikrCodec.withVisibility(DhikrCodec.defaults(), id: "alhamdulillah", visible: false)

        XCTAssertEqual(
            DhikrCodec.adjacent(items, id: "subhanallah", step: 1)?.id,
            "allahu-akbar",
            "the hidden dhikr is never the next one"
        )
        XCTAssertEqual(DhikrCodec.adjacent(items, id: "salawat", step: 1)?.id, "subhanallah")
        XCTAssertEqual(DhikrCodec.adjacent(items, id: "subhanallah", step: -1)?.id, "salawat")

        // Everything hidden leaves nothing to count, rather than an invalid selection.
        items = DhikrCodec.defaults().map { DhikrCodec.withVisibility([$0], id: $0.id, visible: false) }.flatMap { $0 }
        XCTAssertNil(DhikrCodec.adjacent(items, id: "subhanallah", step: 1))
        XCTAssertNil(DhikrCodec.initialSelection(items, selectedId: "subhanallah"))
    }

    /// The order is stable: two dhikr sharing an `order` keep their positions, so a
    /// store written by a buggy build does not reshuffle on every launch.
    func testSortingDoesNotReshuffleEqualOrders() {
        let items = [
            DhikrItem(id: "a", name: "A", order: 0),
            DhikrItem(id: "b", name: "B", order: 0),
            DhikrItem(id: "c", name: "C", order: 0),
        ]

        XCTAssertEqual(DhikrCodec.ordered(items).map(\.id), ["a", "b", "c"])
    }

    /// The store is the codec plus `UserDefaults`: it falls back to the built-ins,
    /// saves through a round trip, and drops a stale selection when the list it refers
    /// to has been lost.
    func testTheDhikrStorePersistsAndRecovers() {
        let suite = "DhikrStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DhikrStore(defaults: defaults)

        XCTAssertEqual(store.items.map(\.id), DhikrCodec.defaults().map(\.id))
        XCTAssertNil(store.selectedId)
        XCTAssertTrue(store.vibrationEnabled)

        store.saveItems(DhikrCodec.incremented(DhikrCodec.defaults(), id: "salawat"))
        store.selectedId = "salawat"
        store.vibrationEnabled = false

        XCTAssertEqual(store.items.first { $0.id == "salawat" }?.count, 1)
        XCTAssertEqual(store.selectedId, "salawat")
        XCTAssertFalse(store.vibrationEnabled)

        // A blank selection is not an id.
        store.selectedId = "   "
        XCTAssertNil(store.selectedId)

        // A store whose list is unusable falls back to the built-ins *and* forgets
        // the selection, which pointed into the list that was lost.
        store.saveItems(DhikrCodec.defaults())
        store.selectedId = "salawat"
        defaults.set("not json", forKey: DhikrStore.Key.items)
        XCTAssertEqual(store.items.count, 6)
        XCTAssertNil(store.selectedId)
    }

    /// The counter model's behaviour, end to end: a tap counts and persists, the
    /// target is recorded exactly once, and the selection survives a relaunch.
    @MainActor
    func testATapCountsPersistsAndCompletes() throws {
        let suite = "DhikrCounterModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DhikrStore(defaults: defaults)

        var clock: Int64 = 1_700_000_000_000
        let model = DhikrCounterModel(store: store) { clock }
        model.setTarget(3, id: try XCTUnwrap(model.selectedId))

        XCTAssertNil(model.tap(), "the first tap does not reach the target")
        XCTAssertNil(model.tap())
        let completion = try XCTUnwrap(model.tap())
        XCTAssertEqual(completion.count, 3)
        XCTAssertEqual(completion.at, clock)
        XCTAssertNil(model.tap(), "the tap after the target does not fire again")

        XCTAssertEqual(model.count(of: completion.itemId), 4)
        XCTAssertEqual(model.lastCompletedCount(of: completion.itemId), 3)

        model.acknowledgeCompletion()
        XCTAssertNil(model.lastCompletion)

        // A fresh model over the same store sees the same count — the write-through
        // is what makes a count tapped on a moving bus survive.
        clock += 1000
        let reopened = DhikrCounterModel(store: store) { clock }
        XCTAssertEqual(reopened.count(of: completion.itemId), 4)
        XCTAssertEqual(reopened.selectedId, completion.itemId)
    }

    /// Hiding the selected dhikr moves the selection to one that is still reachable,
    /// and selecting a hidden one is refused.
    @MainActor
    func testHidingTheSelectionMovesIt() throws {
        let suite = "DhikrHideTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DhikrCounterModel(store: DhikrStore(defaults: defaults))

        let first = try XCTUnwrap(model.selectedId)
        model.setVisible(false, id: first)

        XCTAssertNotEqual(model.selectedId, first)
        XCTAssertTrue(
            try XCTUnwrap(model.selected).visible,
            "the selection moves to a dhikr the pager can still reach"
        )

        model.select(id: first)
        XCTAssertNotEqual(model.selectedId, first, "a hidden dhikr cannot be selected")
    }

    // MARK: - The reminder's cadence

    /// The options are the ones Android offers, and anything else is corrected to the
    /// default rather than honoured.
    func testTheIntervalOptionsAreTheAndroidOnes() {
        XCTAssertEqual(QuranReminder.intervalOptions, [1, 3, 6, 12, 24])
        XCTAssertEqual(QuranReminder.defaultIntervalHours, 6)

        XCTAssertEqual(QuranReminder.normalizedInterval(1), 1)
        XCTAssertEqual(QuranReminder.normalizedInterval(24), 24)
        XCTAssertEqual(QuranReminder.normalizedInterval(2), 6, "a retired option falls back to the default")
        XCTAssertEqual(QuranReminder.normalizedInterval(0), 6)
        XCTAssertEqual(QuranReminder.normalizedInterval(-3), 6)
    }

    /// A verse refreshed an hour ago on a six-hour interval is due in five hours.
    func testAPlanCountsFromTheLastChange() {
        let now = utcDate(2026, 8, 10)
        let lastUpdated = now.addingTimeInterval(-3600)

        let plan = QuranReminder.plan(lastUpdated: lastUpdated, intervalHours: 6, now: now)

        XCTAssertFalse(plan.isOverdue)
        XCTAssertEqual(plan.intervalHours, 6)
        XCTAssertEqual(plan.fireAt.timeIntervalSince(lastUpdated), 6 * 3600, accuracy: 0.5)
        XCTAssertEqual(plan.hoursUntil(from: now), 5)
    }

    /// An overdue plan is due *now*, never in the past: the caller's next step is to
    /// refresh, and a date in the past would make the screen say "in 0 hours" forever.
    func testAnOverduePlanIsDueNow() {
        let now = utcDate(2026, 8, 10)
        let lastUpdated = now.addingTimeInterval(-9 * 3600)

        let plan = QuranReminder.plan(lastUpdated: lastUpdated, intervalHours: 6, now: now)

        XCTAssertTrue(plan.isOverdue)
        XCTAssertEqual(plan.fireAt, now)
        XCTAssertTrue(QuranReminder.isRefreshDue(lastUpdated: lastUpdated, intervalHours: 6, now: now))
    }

    /// Before the first verse exists there is nothing to remind anyone about, so the
    /// first reminder is one whole interval away rather than immediate.
    func testAFreshInstallIsNotOverdue() {
        let now = utcDate(2026, 8, 10)

        let plan = QuranReminder.plan(lastUpdated: nil, intervalHours: 3, now: now)

        XCTAssertFalse(plan.isOverdue)
        XCTAssertEqual(plan.fireAt, now.addingTimeInterval(3 * 3600))
        XCTAssertFalse(QuranReminder.isRefreshDue(lastUpdated: nil, intervalHours: 3, now: now))
    }

    /// The notification copy: Android's "New verse · Surah" title, the verse in
    /// curly quotes, and the reference on the subtitle alone.
    func testTheNotificationCopy() {
        let verse = QuranVerse(
            surahNumber: 2,
            ayahNumber: 255,
            surahName: "Al-Baqarah",
            surahTranslation: "The Cow",
            text: "Allah — there is no deity except Him, the Ever-Living.",
            arabicText: "",
            totalAyahs: 286
        )

        XCTAssertEqual(QuranReminder.title(surahName: "Al-Baqarah"), "New verse · Al-Baqarah")
        XCTAssertEqual(QuranReminder.title(surahName: ""), "New verse")
        XCTAssertEqual(
            QuranReminder.body(for: verse),
            "\u{201C}Allah — there is no deity except Him, the Ever-Living.\u{201D}"
        )
        XCTAssertEqual(QuranReminder.subtitle(for: verse), "Al-Baqarah · 2:255")
        XCTAssertEqual(QuranReminder.intervalLabel(hours: 1), "Every hour")
        XCTAssertEqual(QuranReminder.intervalLabel(hours: 12), "Every 12 hours")
    }

    // MARK: - The reminder's settings and permission

    /// The settings model applies the stored values, and an interval the app no longer
    /// offers is corrected on disk as well as in the model — otherwise the picker and
    /// the schedule disagree again at the next launch.
    @MainActor
    func testLoadingCorrectsAStoredInterval() async {
        let suite = "ReminderSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuranStore(defaults: defaults)
        let deliverer = RecordingQuranReminder(authorization: .authorized)

        defaults.set(2, forKey: QuranStore.Key.refreshIntervalHours)
        let model = QuranReminderSettingsModel(store: store, deliverer: deliverer)

        await model.load()

        XCTAssertEqual(model.intervalHours, 6)
        XCTAssertEqual(
            defaults.integer(forKey: QuranStore.Key.refreshIntervalHours),
            6,
            "the correction is written back, not just displayed"
        )
        XCTAssertEqual(model.authorization, .authorized)
        XCTAssertFalse(model.permissionDenied)
        XCTAssertEqual(model.intervalOptions.map { $0.hours }, [1, 3, 6, 12, 24])
    }

    /// Turning reminders on asks the OS first, and a refusal leaves the setting off
    /// with an explanation — not a toggle that reads "on" and never fires.
    @MainActor
    func testARefusedPermissionLeavesRemindersOff() async {
        let suite = "ReminderDeniedTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuranStore(defaults: defaults)
        let deliverer = RecordingQuranReminder()
        deliverer.grantsAuthorization = false
        let model = QuranReminderSettingsModel(store: store, deliverer: deliverer)

        let enabled = await model.setNotifications(enabled: true, verse: Self.verse(2, 255))

        XCTAssertTrue(deliverer.didRequestAuthorization)
        XCTAssertFalse(enabled)
        XCTAssertFalse(model.notificationsEnabled)
        XCTAssertFalse(model.remindersActive)
        XCTAssertTrue(model.permissionDenied)
        XCTAssertEqual(deliverer.scheduled.count, 0, "nothing is scheduled without permission")
        XCTAssertEqual(deliverer.cancelCount, 0, "nothing was pending to cancel either")
        XCTAssertEqual(store.notificationsEnabled, false, "the refusal is remembered, so we do not re-prompt")
        XCTAssertTrue(model.statusNote.contains("iOS Settings"))
    }

    /// Granted, the verse is scheduled at the chosen interval — and re-scheduling
    /// replaces the pending reminder rather than adding a second one.
    @MainActor
    func testAGrantedPermissionSchedulesTheVerse() async throws {
        let suite = "ReminderGrantedTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuranStore(defaults: defaults)
        let deliverer = RecordingQuranReminder()
        let model = QuranReminderSettingsModel(store: store, deliverer: deliverer)
        let verse = Self.verse(2, 255)

        let enabled = await model.setNotifications(enabled: true, verse: verse)

        XCTAssertTrue(enabled)
        XCTAssertTrue(model.remindersActive)
        XCTAssertFalse(model.permissionDenied)
        XCTAssertEqual(deliverer.scheduled.count, 1)
        XCTAssertEqual(deliverer.scheduled.first?.intervalHours, 6)
        XCTAssertEqual(deliverer.scheduled.first?.verse.surahNumber, 2)
        XCTAssertEqual(deliverer.scheduled.first?.verse.ayahNumber, 255)

        // Changing the interval takes effect immediately, as Android's UPDATE policy
        // does, rather than after the old countdown.
        let stored = await model.setInterval(hours: 1, verse: verse)
        XCTAssertEqual(stored, 1)
        XCTAssertEqual(deliverer.scheduled.count, 2)
        XCTAssertEqual(deliverer.scheduled.last?.intervalHours, 1)
        XCTAssertEqual(store.refreshIntervalHours, 1)

        // An interval the app does not offer is corrected rather than scheduled.
        let corrected = await model.setInterval(hours: 7, verse: verse)
        XCTAssertEqual(corrected, 6)
        XCTAssertEqual(deliverer.scheduled.last?.intervalHours, 6)
    }

    /// Switching reminders off cancels the pending notification, so the next verse
    /// arrives silently.
    @MainActor
    func testTurningRemindersOffCancelsThePendingOne() async {
        let suite = "ReminderOffTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuranStore(defaults: defaults)
        let deliverer = RecordingQuranReminder(authorization: .authorized)
        let model = QuranReminderSettingsModel(store: store, deliverer: deliverer)
        await model.load()
        await model.setNotifications(enabled: true, verse: Self.verse(1, 1))

        let enabled = await model.setNotifications(enabled: false, verse: Self.verse(1, 1))

        XCTAssertFalse(enabled)
        XCTAssertFalse(model.remindersActive)
        XCTAssertEqual(deliverer.cancelCount, 1)
        XCTAssertEqual(store.notificationsEnabled, false)
        XCTAssertTrue(model.statusNote.contains("No notification"))
    }

    /// A verse change with nothing to show — no verse yet — cancels rather than
    /// scheduling a reminder for a verse that does not exist.
    @MainActor
    func testSchedulingWithoutAVerseCancels() async {
        let suite = "ReminderNoVerseTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuranStore(defaults: defaults)
        let deliverer = RecordingQuranReminder(authorization: .authorized)
        let model = QuranReminderSettingsModel(store: store, deliverer: deliverer)
        await model.load()

        await model.syncSchedule(verse: nil)

        XCTAssertEqual(deliverer.scheduled.count, 0)
        XCTAssertEqual(deliverer.cancelCount, 1)
    }

    /// The foreground refresh posts the new verse itself, gated on the same two
    /// conditions as the schedule.
    @MainActor
    func testTheForegroundRefreshPostsTheNewVerse() async {
        let suite = "ReminderPostTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuranStore(defaults: defaults)
        // Undecided permission: the toggle defaults on, and the reminder still must
        // not post anything the user has not agreed to.
        let deliverer = RecordingQuranReminder()
        let model = QuranReminderSettingsModel(store: store, deliverer: deliverer)
        await model.load()
        let verse = Self.verse(112, 1)

        let withoutPermission = await model.notifyIfEnabled(verse: verse)
        XCTAssertFalse(withoutPermission, "a fresh install has the toggle on but no permission yet")

        await model.setNotifications(enabled: true, verse: verse)
        let withPermission = await model.notifyIfEnabled(verse: verse)
        XCTAssertTrue(withPermission)
        XCTAssertEqual(deliverer.posted.count, 1)
        XCTAssertEqual(deliverer.posted.first?.surahNumber, 112)
    }

    /// The store's reminder settings: the interval is coerced in both directions, the
    /// notification toggle defaults on, and saving a verse stamps when it changed —
    /// which is the input to the "is a new verse due?" question.
    func testTheReminderSettingsRoundTripThroughTheStore() {
        let suite = "QuranReminderStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuranStore(defaults: defaults)

        XCTAssertEqual(store.refreshIntervalHours, 6)
        XCTAssertTrue(store.notificationsEnabled)
        XCTAssertNil(store.currentVerseUpdatedAt)

        store.refreshIntervalHours = 12
        XCTAssertEqual(store.refreshIntervalHours, 12)
        store.refreshIntervalHours = 4
        XCTAssertEqual(store.refreshIntervalHours, 6, "an unoffered interval is corrected on the way in")

        store.notificationsEnabled = false
        XCTAssertFalse(store.notificationsEnabled)

        let at = utcDate(2026, 8, 10)
        store.saveCurrentVerse(Self.verse(2, 255), at: at)
        XCTAssertEqual(
            store.currentVerseUpdatedAt?.timeIntervalSince1970 ?? 0,
            at.timeIntervalSince1970,
            accuracy: 0.001
        )
        // Compared field by field rather than whole-object: `QuranVerse` comes from
        // the shared Kotlin module, where a data class bridges to a Swift class and
        // does not conform to `Equatable` for free.
        XCTAssertEqual(store.currentVerse?.surahNumber, 2)
        XCTAssertEqual(store.currentVerse?.ayahNumber, 255)
        XCTAssertEqual(store.currentVerse?.text, "verse text")
    }

    /// The keys the reminder writes are the Android store's, so a verse and its
    /// settings are recognisably the same record on both platforms.
    func testTheReminderUsesTheAndroidKeys() {
        XCTAssertEqual(QuranStore.Key.refreshIntervalHours, "refresh_interval_hours")
        XCTAssertEqual(QuranStore.Key.quranNotificationsEnabled, "quran_notifications_enabled")
        XCTAssertEqual(QuranStore.Key.currentVerseUpdatedAt, "current_verse_updated_at")
    }

    private static func verse(_ surah: Int32, _ ayah: Int32) -> QuranVerse {
        QuranVerse(
            surahNumber: surah,
            ayahNumber: ayah,
            surahName: "Test",
            surahTranslation: "",
            text: "verse text",
            arabicText: "",
            totalAyahs: 7
        )
    }
}

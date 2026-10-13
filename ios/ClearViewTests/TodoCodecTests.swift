import XCTest
@testable import ClearView

/// Tests for the Todo domain: the JSON the store writes, the day rules, the strict
/// interval, the mutations, the filters and sorts, the history and the labels.
///
/// The anchors are real dates with known epoch days and weekdays (`2026-08-10` is
/// Monday = 20675), so the day arithmetic is checked against the calendar rather than
/// against itself, and the tests never depend on the machine's time zone: every rule
/// is asked about an explicit day.
final class TodoCodecTests: XCTestCase {

    /// Monday 2026-08-10.
    private let monday: Int64 = 20675
    /// Tuesday 2026-08-11.
    private let tuesday: Int64 = 20676
    /// Friday 2026-08-14.
    private let friday: Int64 = 20679
    /// Monday 2026-08-17.
    private let nextMonday: Int64 = 20682
    /// Tuesday 2026-10-13.
    private let october: Int64 = 20739

    private func minutes(_ hour: Int, _ minute: Int = 0) -> Int { hour * 60 + minute }

    /// A plain todo running on one day.
    private func temporary(
        _ id: String = "t1",
        title: String = "Read",
        day: Int64? = nil,
        endDay: Int64? = nil
    ) -> TodoItem {
        TodoItem(
            id: id,
            title: title,
            startDateEpochDay: day ?? monday,
            endDateEpochDay: endDay
        )
    }

    private func permanent(
        _ id: String = "p1",
        days: Set<Int>? = nil,
        time: Int? = nil
    ) -> TodoItem {
        TodoItem(
            id: id,
            title: "Permanent",
            type: .permanent,
            startDateEpochDay: monday,
            scheduledDays: days,
            timeMinutes: time
        )
    }

    // MARK: - Persistence

    /// Everything the model carries survives the round trip, including the history
    /// that makes statistics work.
    func testAFullTodoRoundTrips() {
        var item = permanent(days: [1, 3, 5], time: minutes(20, 30))
        item.details = "with detail"
        item.behavior = .time
        item.targetDurationMinutes = 45
        item.priority = .high
        item.strictInterval = true
        item.timeStartMinutes = minutes(9)
        item.timeEndMinutes = minutes(20)
        item.timeMinutes = nil
        item.reminder = ReminderConfig(
            timesMinutes: [minutes(9), minutes(20)],
            repeats: true,
            enabled: true,
            asAlarm: true,
            alarmMinutes: 5,
            alarmUri: "file:///alarm.m4a"
        )
        item.completions = [monday: 1_700_000_000_000]
        item.events = [
            .created(timestampMillis: 1, title: "Permanent", timeMinutes: nil, durationMinutes: 45),
            .completed(timestampMillis: 2, epochDay: monday),
            .attempted(timestampMillis: 3, epochDay: tuesday),
            .timeAdded(timestampMillis: 4, epochDay: tuesday, addedMinutes: 12),
        ]

        let decoded = TodoCodec.decode(TodoCodec.encode([item]))

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first, item)
    }

    /// A stored record written by an older or buggier build still loads — with the
    /// invalid parts dropped rather than taken along.
    func testDecodingToleratesUnknownAndInvalidValues() {
        let json = """
        [{
          "id": "t1",
          "title": "Read",
          "type": "NOT_A_TYPE",
          "priority": "NOT_A_PRIORITY",
          "behavior": "NOT_A_BEHAVIOR",
          "start": 20675,
          "time": 1440,
          "timeStart": -5,
          "timeEnd": 1200,
          "days": [0, 3, 9, 5],
          "reminder": { "times": [1500, 600, 600, -1], "repeat": true, "alarmMinutes": 999 },
          "completions": { "20675": 5, "not-a-day": 6 },
          "interval": true
        }]
        """

        let item = try? XCTUnwrap(TodoCodec.decode(json).first)

        XCTAssertEqual(item?.type, .temporary)
        XCTAssertEqual(item?.priority, .normal)
        XCTAssertEqual(item?.behavior, .normal)
        XCTAssertNil(item?.timeMinutes, "1440 is not a valid time of day")
        XCTAssertNil(item?.timeStartMinutes, "a negative time is dropped")
        XCTAssertEqual(item?.timeEndMinutes, 1200)
        XCTAssertEqual(item?.scheduledDays, [3, 5], "only 1…7 survive")
        XCTAssertEqual(item?.reminder?.timesMinutes, [600], "valid, distinct, sorted")
        XCTAssertEqual(item?.reminder?.alarmMinutes, ReminderConfig.maxAlarmMinutes)
        XCTAssertEqual(item?.completions, [20675: 5])
        XCTAssertTrue(item?.strictInterval == true)
    }

    /// Android's older field names are still read, so a store written before the
    /// renames keeps its history and behaviour.
    func testDecodingReadsTheOlderFieldNames() {
        let json = """
        [{
          "id": "t1",
          "title": "Read",
          "start": 20675,
          "kind": "TIME",
          "totalDuration": 30,
          "history": [{"ev": "Completed", "ts": 9, "epochDay": 20675}]
        }]
        """

        let item = TodoCodec.decode(json).first

        XCTAssertEqual(item?.behavior, .time)
        XCTAssertEqual(item?.targetDurationMinutes, 30)
        XCTAssertEqual(item?.events, [.completed(timestampMillis: 9, epochDay: monday)])
    }

    /// A store that cannot be read at all is empty, and a record with no id is not a
    /// todo — it could never be completed or found again.
    func testGarbageAndAnonymousRecordsAreDropped() {
        XCTAssertEqual(TodoCodec.decode("not json"), [])
        XCTAssertEqual(TodoCodec.decode(""), [])
        XCTAssertEqual(TodoCodec.decode(nil), [])
        XCTAssertEqual(TodoCodec.decode("[{\"title\":\"no id\"}]"), [])
    }

    // MARK: - Which days a todo applies on

    /// A temporary todo is active every day of its period and no day outside it.
    func testATemporaryTodoIsActiveOnlyInsideItsPeriod() {
        let item = temporary(day: tuesday, endDay: friday)

        XCTAssertFalse(TodoCodec.isActiveOn(item, epochDay: monday), "before it starts")
        XCTAssertTrue(TodoCodec.isActiveOn(item, epochDay: tuesday))
        XCTAssertTrue(TodoCodec.isActiveOn(item, epochDay: friday), "the end day is inclusive")
        XCTAssertFalse(TodoCodec.isActiveOn(item, epochDay: friday + 1))
    }

    /// A permanent todo repeats on the weekdays it names — with Monday as 1, the same
    /// numbering Android stores.
    func testAPermanentTodoRepeatsOnItsSelectedDays() {
        let item = permanent(days: [1, 3, 5])

        XCTAssertTrue(TodoCodec.isActiveOn(item, epochDay: monday))
        XCTAssertFalse(TodoCodec.isActiveOn(item, epochDay: tuesday))
        XCTAssertTrue(TodoCodec.isActiveOn(item, epochDay: monday + 2), "Wednesday")
        XCTAssertTrue(TodoCodec.isActiveOn(item, epochDay: friday))
        XCTAssertFalse(TodoCodec.isActiveOn(item, epochDay: friday + 1), "Saturday")
    }

    /// No selected days means every day — not "never".
    func testAPermanentTodoWithNoSelectedDaysIsEveryDay() {
        let item = permanent(days: nil)

        XCTAssertTrue(TodoCodec.isActiveOn(item, epochDay: monday))
        XCTAssertTrue(TodoCodec.isActiveOn(item, epochDay: october))
    }

    /// Archiving is about the plan's own lifetime: deleted, or a temporary whose
    /// *end* has passed. A temporary todo with no end never expires (it is open-ended,
    /// not "yesterday's"), and a permanent todo is never archived by time.
    func testArchivingRules() {
        XCTAssertFalse(
            TodoCodec.isArchived(temporary(day: monday), today: friday),
            "no end date means it stays until it is deleted"
        )
        XCTAssertTrue(TodoCodec.isArchived(temporary(day: monday, endDay: monday), today: friday))
        XCTAssertFalse(TodoCodec.isArchived(temporary(day: monday, endDay: monday), today: monday))
        XCTAssertFalse(TodoCodec.isArchived(temporary(day: monday, endDay: october), today: friday))
        XCTAssertFalse(TodoCodec.isArchived(permanent(), today: october))

        var deleted = temporary()
        deleted.isDeleted = true
        XCTAssertTrue(TodoCodec.isArchived(deleted, today: monday))

        let items = [temporary("expired", day: monday, endDay: monday), permanent("forever")]
        XCTAssertEqual(
            TodoCodec.visibleItems(items, today: friday).map(\.id),
            ["forever"],
            "an expired temporary leaves the working set"
        )
    }

    /// The next applicable day skips over the days a permanent todo does not repeat
    /// on, and there is none once a period has ended.
    func testNextActiveDate() {
        XCTAssertEqual(TodoCodec.nextActiveDate(permanent(days: [1]), today: monday), nextMonday)
        XCTAssertEqual(
            TodoCodec.nextActiveDate(temporary(day: monday + 5, endDay: friday + 5), today: monday),
            monday + 5,
            "a future temporary todo is not active before it starts"
        )
        XCTAssertNil(
            TodoCodec.nextActiveDate(temporary(day: monday, endDay: monday), today: monday),
            "a period that ends today has no next date"
        )
    }

    // MARK: - Completing

    /// Completing is strict: it records the day and an event, and completing twice
    /// does not move the recorded instant.
    func testCompletingIsStrictAndRecordedAsAnEvent() {
        let once = TodoCodec.completed([temporary()], id: "t1", epochDay: monday, at: 100)
        let twice = TodoCodec.completed(once, id: "t1", epochDay: monday, at: 200)

        XCTAssertEqual(twice.first?.completions, [monday: 100])
        XCTAssertEqual(
            twice.first?.events,
            [.completed(timestampMillis: 100, epochDay: monday)],
            "the second completion is refused, not re-recorded"
        )
        XCTAssertEqual(twice.first?.updatedAtEpochMillis, 100)
    }

    /// The interactive toggle adds, then removes, and says which happened — the caller
    /// needs that to cancel the day's reminders.
    func testTheToggleAddsThenRemovesAndReportsTheState() {
        let (done, isCompleted) = TodoCodec.toggled([temporary()], id: "t1", epochDay: monday, at: 10)
        XCTAssertTrue(isCompleted)
        XCTAssertEqual(done.first?.completions, [monday: 10])

        let (undone, isStillCompleted) = TodoCodec.toggled(done, id: "t1", epochDay: monday, at: 20)
        XCTAssertFalse(isStillCompleted)
        XCTAssertEqual(undone.first?.completions, [:])
        XCTAssertEqual(
            undone.first?.events,
            [
                .completed(timestampMillis: 10, epochDay: monday),
                .uncompleted(timestampMillis: 20, epochDay: monday),
            ],
            "taking a completion back is itself history"
        )
    }

    /// Marking attempted twice does not pile up events, and a completed day is never
    /// also "attempted" — the states are exclusive.
    func testAttemptedIsIdempotentAndExclusiveWithCompletion() {
        let once = TodoCodec.attempted([temporary()], id: "t1", epochDay: monday, at: 1)
        let twice = TodoCodec.attempted(once, id: "t1", epochDay: monday, at: 2)
        XCTAssertEqual(twice.first?.events.count, 1)

        XCTAssertTrue(TodoCodec.isAttemptedOn(twice[0], epochDay: monday))
        let completed = TodoCodec.completed(twice, id: "t1", epochDay: monday, at: 3)
        XCTAssertFalse(
            TodoCodec.isAttemptedOn(completed[0], epochDay: monday),
            "a completed day is not still attempted"
        )
    }

    /// Clearing the attempted state removes the day's events outright, so the partial
    /// credit it earned leaves the score.
    func testUnattemptingRemovesTheDaysEvents() {
        var item = temporary()
        item.events = [
            .attempted(timestampMillis: 1, epochDay: monday),
            .attempted(timestampMillis: 2, epochDay: tuesday),
            .completed(timestampMillis: 3, epochDay: friday),
        ]

        let cleared = TodoCodec.unattempted([item], id: "t1", epochDay: monday, at: 9)

        XCTAssertEqual(
            cleared.first?.events,
            [
                .attempted(timestampMillis: 2, epochDay: tuesday),
                .completed(timestampMillis: 3, epochDay: friday),
            ]
        )
    }

    /// Logged time is per day, and adds up across entries.
    func testTimeIsLoggedPerDayAndSummed() {
        var items = TodoCodec.timeAdded([temporary()], id: "t1", epochDay: monday, at: 1, addedMinutes: 10)
        items = TodoCodec.timeAdded(items, id: "t1", epochDay: monday, at: 2, addedMinutes: 5)
        items = TodoCodec.timeAdded(items, id: "t1", epochDay: tuesday, at: 3, addedMinutes: 60)

        XCTAssertEqual(TodoCodec.timeSpentOn(items[0], epochDay: monday), 15)
        XCTAssertEqual(TodoCodec.timeSpentOn(items[0], epochDay: tuesday), 60)
        XCTAssertEqual(TodoCodec.timeSpentOn(items[0], epochDay: friday), 0)
    }

    // MARK: - The strict interval

    /// The window is open inside its bounds and closed after them.
    func testAStrictWindowIsOpenInsideAndClosedAfter() {
        var item = temporary()
        item.strictInterval = true
        item.timeStartMinutes = minutes(9)
        item.timeEndMinutes = minutes(20)

        XCTAssertTrue(TodoCodec.hasStrictInterval(item))
        XCTAssertFalse(TodoCodec.intervalOpen(item, epochDay: monday, nowMillis: TodoCodec.dayTimeMillis(epochDay: monday, minutes: minutes(8))))
        XCTAssertTrue(TodoCodec.intervalOpen(item, epochDay: monday, nowMillis: TodoCodec.dayTimeMillis(epochDay: monday, minutes: minutes(12))))
        XCTAssertTrue(TodoCodec.intervalOpen(item, epochDay: monday, nowMillis: TodoCodec.dayTimeMillis(epochDay: monday, minutes: minutes(20))))
        XCTAssertFalse(TodoCodec.intervalOpen(item, epochDay: monday, nowMillis: TodoCodec.dayTimeMillis(epochDay: monday, minutes: minutes(21))))
        XCTAssertTrue(TodoCodec.intervalEnded(item, epochDay: monday, nowMillis: TodoCodec.dayTimeMillis(epochDay: monday, minutes: minutes(21))))
    }

    /// "Can't redo": once the window has closed the day cannot be completed, and the
    /// refusal says why.
    func testCompletionIsRefusedOnceTheWindowClosed() {
        var item = temporary()
        item.strictInterval = true
        item.timeStartMinutes = minutes(9)
        item.timeEndMinutes = minutes(20)
        let afterWindow = TodoCodec.dayTimeMillis(epochDay: monday, minutes: minutes(23))

        XCTAssertFalse(TodoCodec.canCompleteOn(item, epochDay: monday, nowMillis: afterWindow))
        XCTAssertEqual(
            TodoCodec.completionRefusal(item, epochDay: monday, nowMillis: afterWindow, today: monday),
            .windowClosed
        )
        XCTAssertEqual(
            TodoCodec.completionRefusal(item, epochDay: monday, nowMillis: afterWindow, today: monday)?.message,
            "The time window has closed — that day is missed."
        )
    }

    /// Every refusal reason, in the order the rules are checked.
    func testTheRefusalReasonsMatchTheRules() {
        var item = temporary(day: monday, endDay: monday)
        let midday = TodoCodec.dayTimeMillis(epochDay: monday, minutes: minutes(12))

        XCTAssertEqual(
            TodoCodec.completionRefusal(item, epochDay: tuesday, nowMillis: midday, today: monday),
            .futureDay
        )
        XCTAssertEqual(
            TodoCodec.completionRefusal(item, epochDay: friday, nowMillis: midday, today: october),
            .notActiveDay
        )
        item = TodoCodec.completed([item], id: "t1", epochDay: monday, at: 1)[0]
        XCTAssertEqual(
            TodoCodec.completionRefusal(item, epochDay: monday, nowMillis: midday, today: monday),
            .alreadyCompleted
        )
        XCTAssertNil(
            TodoCodec.completionRefusal(temporary(), epochDay: monday, nowMillis: midday, today: monday)
        )
    }

    /// Answering a reminder is not a redo: a closed window does not refuse it, so a
    /// snoozed alarm that rings after the deadline can still be answered.
    func testAReminderAnsweredLateIgnoresTheClosedWindow() {
        var item = temporary()
        item.strictInterval = true
        item.timeStartMinutes = minutes(9)
        item.timeEndMinutes = minutes(20)

        XCTAssertEqual(
            TodoCodec.completionRefusal(item, epochDay: monday, nowMillis: TodoCodec.dayTimeMillis(epochDay: monday, minutes: minutes(23)), today: monday),
            .windowClosed
        )
        XCTAssertNil(
            TodoCodec.reminderCompletionRefusal(item, epochDay: monday, today: monday),
            "the same day is answerable from its reminder"
        )
    }

    /// A reminder still cannot complete a day that has not arrived, one the todo does
    /// not apply on, or one already done.
    func testAReminderStillRespectsTheTodosOwnRules() {
        let item = temporary(day: monday, endDay: friday)

        XCTAssertEqual(
            TodoCodec.reminderCompletionRefusal(item, epochDay: tuesday, today: monday),
            .futureDay
        )
        XCTAssertEqual(
            TodoCodec.reminderCompletionRefusal(item, epochDay: october, today: october),
            .notActiveDay
        )
        let completed = TodoCodec.completed([item], id: "t1", epochDay: monday, at: 1)[0]
        XCTAssertEqual(
            TodoCodec.reminderCompletionRefusal(completed, epochDay: monday, today: monday),
            .alreadyCompleted
        )
    }

    /// Without a window every todo is open — "no deadline" must not mean "never".
    func testATodoWithoutAWindowIsAlwaysOpen() {
        let item = temporary()

        XCTAssertFalse(TodoCodec.hasStrictInterval(item))
        XCTAssertTrue(TodoCodec.intervalOpen(item, epochDay: monday, nowMillis: 0))
        XCTAssertTrue(
            TodoCodec.canCompleteOn(item, epochDay: monday, nowMillis: TodoCodec.dayTimeMillis(epochDay: monday, minutes: minutes(23)))
        )
    }

    /// A window with only one end is not a strict interval: half a rule cannot lock a
    /// day.
    func testAWindowNeedsBothEnds() {
        var item = temporary()
        item.strictInterval = true
        item.timeStartMinutes = minutes(9)

        XCTAssertFalse(TodoCodec.hasStrictInterval(item))
        XCTAssertTrue(TodoCodec.intervalOpen(item, epochDay: monday, nowMillis: 0))
    }

    // MARK: - Filters and sorts

    /// Today and Upcoming are disjoint: a todo due today is never also upcoming, and a
    /// future todo is never in today's list.
    func testTodayAndUpcomingAreDisjoint() {
        let items = [
            temporary("today", day: monday),
            temporary("tomorrow", day: tuesday),
            permanent("weekdays", days: [1]),
            permanent("everyday"),
        ]

        let today = TodoCodec.filter(items, filter: .today, today: monday).map(\.id)
        let upcoming = TodoCodec.filter(items, filter: .upcoming, today: monday).map(\.id)

        XCTAssertEqual(today.sorted(), ["everyday", "today", "weekdays"])
        XCTAssertEqual(upcoming, ["tomorrow"])
    }

    /// History is the record of the past, so it includes todos that have left the
    /// active list — and the active lists do not.
    func testHistoryIncludesArchivedTodos() {
        var done = temporary("done", day: monday, endDay: monday)
        done.completions = [monday: 1]
        let expired = temporary("expired", day: monday, endDay: monday)

        let history = TodoCodec.filter([done, expired], filter: .history, today: friday).map(\.id)

        XCTAssertEqual(history.sorted(), ["done", "expired"])
        XCTAssertTrue(
            TodoCodec.filter([done, expired], filter: .all, today: friday).isEmpty,
            "expired todos are not in the active list"
        )
        XCTAssertTrue(TodoCodec.filter([done, expired], filter: .today, today: friday).isEmpty)
    }

    /// The Completed filter is about what was ticked off today — not about anything
    /// ever completed.
    func testTheCompletedFilterCountsTodaysCompletions() {
        var todayItem = temporary("today", day: monday)
        todayItem.completions = [monday: 1]
        var oldItem = temporary("old", day: monday)
        oldItem.completions = [monday: 1]
        oldItem.isDeleted = true
        let unfinished = temporary("unfinished", day: monday)

        let completed = TodoCodec.filter([todayItem, oldItem, unfinished], filter: .completed, today: monday)

        XCTAssertEqual(completed.map(\.id), ["today"])
    }

    /// The type filters split the list, and neither includes the other's todos.
    func testTheTypeFiltersSplitTheList() {
        let items = [temporary("t"), permanent("p")]

        XCTAssertEqual(TodoCodec.filter(items, filter: .temporary, today: monday).map(\.id), ["t"])
        XCTAssertEqual(TodoCodec.filter(items, filter: .permanent, today: monday).map(\.id), ["p"])
    }

    /// Smart sort puts what is still to do today first, then orders by time, priority
    /// and creation.
    func testSmartSortPutsTodaysIncompleteFirst() {
        var done = permanent("done", time: minutes(8))
        done.completions = [monday: 1]
        let later = permanent("later", time: minutes(18))
        let earlier = permanent("earlier", time: minutes(9))
        let untimed = permanent("untimed", time: nil)

        let sorted = TodoCodec.sorted([done, later, earlier, untimed], sort: .smart, today: monday).map(\.id)

        XCTAssertEqual(sorted, ["earlier", "later", "untimed", "done"], "ticked-off work sinks to the bottom")
    }

    /// Priority sort is highest-first, and the time breaks the tie.
    func testPrioritySortIsHighestFirst() {
        var high = permanent("high", time: minutes(20))
        high.priority = .high
        var low = permanent("low", time: minutes(8))
        low.priority = .low
        let normal = permanent("normal", time: minutes(12))

        let sorted = TodoCodec.sorted([high, low, normal], sort: .priority, today: monday).map(\.id)

        XCTAssertEqual(sorted, ["high", "normal", "low"])
    }

    /// Sorting is stable: two todos identical in every key keep the order they were
    /// stored in, so the list does not reshuffle between redraws.
    func testSortsAreStableForEqualKeys() {
        var first = permanent("first", time: minutes(9))
        first.createdAtEpochMillis = 5
        var second = permanent("second", time: minutes(9))
        second.createdAtEpochMillis = 5

        XCTAssertEqual(
            TodoCodec.sorted([first, second], sort: .smart, today: monday).map(\.id),
            ["first", "second"]
        )
        XCTAssertEqual(
            TodoCodec.sorted([second, first], sort: .smart, today: monday).map(\.id),
            ["second", "first"]
        )
    }

    // MARK: - History

    /// Completed and missed occurrences are counted day by day. Today itself is not
    /// missed: it is still actionable, and calling it missed would score the reader
    /// down for a day that has not finished.
    func testOccurrenceCountsCountCompletionsAndMisses() {
        var item = temporary("t1", day: monday, endDay: friday)
        item.completions = [monday: 1, tuesday: 1]

        let (completed, missed) = TodoCodec.occurrenceCounts(item, today: friday)

        XCTAssertEqual(completed, 2)
        XCTAssertEqual(missed, 2, "Wednesday and Thursday passed uncompleted")
    }

    /// A strict window that closed today is a missed occurrence *immediately* — the
    /// day is locked, so it cannot be waiting to happen.
    func testAStrictWindowClosedTodayCountsAsMissedImmediately() {
        var item = temporary("t1", day: monday, endDay: monday)
        item.strictInterval = true
        item.timeStartMinutes = minutes(9)
        item.timeEndMinutes = minutes(20)
        let afterWindow = TodoCodec.dayTimeMillis(epochDay: monday, minutes: minutes(21))

        let (completed, missed) = TodoCodec.occurrenceCounts(item, today: monday, nowMillis: afterWindow)
        XCTAssertEqual(completed, 0)
        XCTAssertEqual(missed, 1)
    }

    /// Clearing the History cards hides them from the History view and changes nothing
    /// else: the completions are still there, and they still count for today.
    func testClearWatermarksHideCardsWithoutLosingCompletions() {
        var item = temporary("t1", day: monday, endDay: friday)
        item.completions = [monday: 1, tuesday: 1]
        let items = [item]

        let cleared = TodoCodec.clearHistory(items, today: friday)

        XCTAssertEqual(cleared.first?.completedClearedBefore, friday + 1)
        XCTAssertEqual(cleared.first?.missedClearedBefore, friday + 1)
        XCTAssertEqual(
            cleared.first?.completions,
            [monday: 1, tuesday: 1],
            "clearing history must not undo the completions"
        )
        let (completed, missed) = TodoCodec.occurrenceCounts(cleared[0], today: friday)
        XCTAssertEqual(completed, 0, "the watermark hides the completed days")
        XCTAssertEqual(missed, 0, "and the missed ones")
        XCTAssertTrue(TodoCodec.historySorted(cleared, today: friday).isEmpty)
    }

    /// Each section's clear only hides its own section: clearing the completed cards
    /// leaves the missed ones listed, and the other way round.
    func testEachSectionClearsIndependently() {
        var done = temporary("done", day: monday, endDay: friday)
        done.completions = [monday: 1]
        var missed = temporary("missed", day: monday, endDay: friday)
        missed.completions = [:]

        let completedCleared = TodoCodec.removeCompletedHistory([done, missed], today: friday)
        XCTAssertEqual(completedCleared[0].completedClearedBefore, friday + 1)
        XCTAssertNil(completedCleared[0].missedClearedBefore, "the completed card is not hidden from missed")
        XCTAssertNil(completedCleared[1].completedClearedBefore, "a todo with no completions is untouched")
        XCTAssertEqual(
            TodoCodec.historyMissed(completedCleared, today: friday).map(\.item.id),
            ["done", "missed"],
            "the missed section still lists both — nothing in it was cleared"
        )

        let missedCleared = TodoCodec.removeMissedHistory([done, missed], today: friday)
        XCTAssertEqual(missedCleared[1].missedClearedBefore, friday + 1)
        XCTAssertNil(missedCleared[1].completedClearedBefore, "the completed section is untouched")
        XCTAssertEqual(
            TodoCodec.historyCompleted(missedCleared, today: friday).map(\.item.id),
            ["done"],
            "the completed section still lists what was completed"
        )
    }

    /// The rules for "has history", including the ones that short-circuit.
    func testHasHistoryRules() {
        XCTAssertFalse(
            TodoCodec.hasHistory(temporary(day: october, endDay: october), today: monday),
            "a todo entirely in the future has no history"
        )

        var completedToday = temporary()
        completedToday.completions = [monday: 1]
        XCTAssertTrue(TodoCodec.hasHistory(completedToday, today: monday))

        var missedYesterday = temporary(day: monday, endDay: monday)
        missedYesterday.completions = [:]
        XCTAssertTrue(TodoCodec.hasHistory(missedYesterday, today: tuesday), "yesterday passed uncompleted")

        let expired = temporary(day: monday, endDay: monday)
        XCTAssertTrue(TodoCodec.hasHistory(expired, today: friday), "an expired temporary always had days")

        var cleared = completedToday
        cleared.completedClearedBefore = monday + 1
        XCTAssertFalse(TodoCodec.hasHistory(cleared, today: monday), "a cleared card is hidden")

        XCTAssertFalse(TodoCodec.hasHistory(permanent(days: [1]), today: monday), "due today, nothing yet")
        XCTAssertTrue(TodoCodec.hasHistory(permanent(days: [1]), today: tuesday), "yesterday was a Monday")
    }

    /// A history row aggregates the behaviour badges as well as the counts.
    func testAHistoryEntryAggregatesAttemptsAndMinutes() {
        var item = temporary("t1", day: monday, endDay: friday)
        item.behavior = .time
        item.completions = [monday: 1]
        item.events = [
            .attempted(timestampMillis: 1, epochDay: tuesday),
            .attempted(timestampMillis: 2, epochDay: friday),
            .timeAdded(timestampMillis: 3, epochDay: tuesday, addedMinutes: 20),
            .timeAdded(timestampMillis: 4, epochDay: friday, addedMinutes: 40),
        ]

        let entry = TodoCodec.entry(item, today: friday)

        XCTAssertEqual(entry.completedCount, 1)
        XCTAssertEqual(entry.missedCount, 3, "Tuesday, Wednesday and Thursday")
        XCTAssertEqual(entry.attemptedCount, 2)
        XCTAssertEqual(entry.totalMinutes, 60)
        XCTAssertEqual(entry.lastOccurrence, friday)
    }

    /// The most recent occurrence, and the History order (most recent first).
    func testLastOccurrenceAndHistoryOrder() {
        let weekdaysOnly = permanent("weekdays", days: [1])
        XCTAssertEqual(TodoCodec.lastOccurrence(weekdaysOnly, today: tuesday), monday)
        XCTAssertNil(
            TodoCodec.lastOccurrence(temporary(day: october, endDay: october), today: monday),
            "a future todo has no occurrence yet"
        )

        var first = temporary("first", day: monday, endDay: monday)
        first.completions = [monday: 1]
        var second = temporary("second", day: friday, endDay: friday)
        second.completions = [friday: 1]

        let ordered = TodoCodec.historySorted([first, second], today: friday).map(\.item.id)
        XCTAssertEqual(ordered, ["second", "first"])
    }

    /// The destructive reset really is destructive, and the soft delete really is not.
    func testSoftDeleteKeepsHistoryAndTheHardDeleteDoesNot() {
        var done = temporary("t1")
        done.completions = [monday: 1]

        let soft = TodoCodec.removed([done], id: "t1")
        XCTAssertTrue(soft.first?.isDeleted == true)
        XCTAssertEqual(soft.first?.completions, [monday: 1], "the history is kept for statistics")
        XCTAssertEqual(soft.count, 1)

        XCTAssertTrue(TodoCodec.removedWithHistory([done], id: "t1").isEmpty)
        XCTAssertTrue(TodoCodec.resetEverything().isEmpty)
    }

    /// Editing changes the plan and only the plan: the count and the record stay.
    func testEditingKeepsTheHistory() {
        var item = temporary("t1", day: monday, endDay: friday)
        item.completions = [monday: 1]
        item.events = [.completed(timestampMillis: 1, epochDay: monday)]

        var edited = item
        edited.title = "Renamed"
        edited.startDateEpochDay = tuesday
        edited.completions = [:]
        edited.events = []

        let updated = TodoCodec.updated([item], item: edited)
        let result = TodoCodec.updated(updated, item: edited)[0]

        XCTAssertEqual(result.title, "Renamed")
        XCTAssertEqual(result.startDateEpochDay, tuesday)
        XCTAssertEqual(result.completions, [monday: 1], "an edit never rewrites what was done")
        XCTAssertEqual(result.events, [.completed(timestampMillis: 1, epochDay: monday)])
        XCTAssertGreaterThan(result.updatedAtEpochMillis, 0)
    }

    /// Adding assigns an id when there is none, starts with no completions, and
    /// records the creation.
    func testAddingStartsACleanTodo() {
        var draft = temporary("")
        draft.id = ""
        draft.completions = [monday: 1]

        let added = TodoCodec.added([], item: draft)

        XCTAssertEqual(added.count, 1)
        XCTAssertFalse(added[0].id.isEmpty)
        XCTAssertTrue(added[0].completions.isEmpty)
        XCTAssertEqual(added[0].events.count, 1)
        if case .created = added[0].events[0] {} else {
            XCTFail("a new todo records its creation")
        }
    }

    // MARK: - Labels

    /// The schedule label says what the todo *is*: a day, a range, the weekdays it
    /// repeats on, or every day.
    func testScheduleLabels() {
        XCTAssertEqual(TodoCodec.scheduleLabel(temporary(day: monday), today: monday), "Today")
        XCTAssertEqual(TodoCodec.scheduleLabel(temporary(day: tuesday), today: monday), "Tomorrow")
        XCTAssertEqual(TodoCodec.scheduleLabel(temporary(day: october), today: monday), "Tue, Oct 13")
        XCTAssertEqual(
            TodoCodec.scheduleLabel(temporary(day: monday, endDay: friday), today: monday),
            "Today – Aug 14"
        )
        XCTAssertEqual(
            TodoCodec.scheduleLabel(temporary(day: october, endDay: october + 2), today: monday),
            "Tue, Oct 13 – Oct 15"
        )
        XCTAssertEqual(TodoCodec.scheduleLabel(permanent(days: nil), today: monday), "Every day")
        XCTAssertEqual(TodoCodec.scheduleLabel(permanent(days: [1, 3, 5]), today: monday), "Mon • Wed • Fri")
        XCTAssertEqual(
            TodoCodec.scheduleLabel(permanent(days: [1, 2, 3, 4, 5, 6, 7]), today: monday),
            "Every day",
            "all seven days is every day"
        )
    }

    /// Time labels survive invalid values, and a range reads as a range.
    func testTimeAndReminderLabels() {
        XCTAssertEqual(TodoCodec.timeLabel(minutes(20)), "8:00 PM")
        XCTAssertEqual(TodoCodec.timeLabel(minutes(0)), "12:00 AM")
        XCTAssertEqual(TodoCodec.timeLabel(1440), "12:00 AM", "1440 wraps rather than throwing")
        XCTAssertEqual(TodoCodec.timeLabel(-60), "11:00 PM", "and so does a negative value")

        var ranged = temporary()
        ranged.timeStartMinutes = minutes(9)
        ranged.timeEndMinutes = minutes(20)
        XCTAssertEqual(TodoCodec.scheduledTimeLabel(ranged), "9:00 AM – 8:00 PM")

        var timed = temporary()
        timed.timeMinutes = minutes(21, 30)
        XCTAssertEqual(TodoCodec.scheduledTimeLabel(timed), "9:30 PM")
        XCTAssertNil(TodoCodec.scheduledTimeLabel(temporary()), "no time, no label")

        timed.reminder = ReminderConfig(timesMinutes: [minutes(9), minutes(20)], repeats: true)
        XCTAssertEqual(TodoCodec.reminderLabel(timed), "9:00 AM · 8:00 PM")
        XCTAssertNil(TodoCodec.reminderLabel(temporary()), "no reminder, no label")
    }

    /// Spread times include both ends, and a short range collapses instead of
    /// repeating itself.
    func testRangeTimesSpreadAcrossTheWindow() {
        XCTAssertEqual(
            TodoCodec.rangeTimes(startMinutes: minutes(9), endMinutes: minutes(20), count: 3),
            [minutes(9), minutes(14, 30), minutes(20)]
        )
        XCTAssertEqual(
            TodoCodec.rangeTimes(startMinutes: minutes(9), endMinutes: minutes(20), count: 1),
            [minutes(9)],
            "one time is the start of the window"
        )
        XCTAssertEqual(
            TodoCodec.rangeTimes(startMinutes: minutes(9), endMinutes: minutes(9), count: 4),
            [minutes(9)],
            "a zero-width window yields the one time it has"
        )
        XCTAssertEqual(
            TodoCodec.rangeTimes(startMinutes: minutes(9), endMinutes: minutes(9, 3), count: 4),
            [minutes(9), minutes(9, 1), minutes(9, 2), minutes(9, 3)]
        )
    }

    // MARK: - The calendar under it

    /// The day arithmetic against the calendar: 2026-08-10 is a Monday with epoch day
    /// 20675, and the weekday numbering is the one Android stores (1 = Monday).
    func testEpochDaysAndWeekdaysMatchTheCalendar() {
        XCTAssertEqual(TodoCalendar.epochDay(of: date(2026, 8, 10)), monday)
        XCTAssertEqual(TodoCalendar.epochDay(of: date(2026, 8, 14)), friday)
        XCTAssertEqual(TodoCalendar.epochDay(of: date(2026, 10, 13)), october)
        XCTAssertEqual(TodoCalendar.weekday(epochDay: monday), 1, "Monday")
        XCTAssertEqual(TodoCalendar.weekday(epochDay: friday), 5, "Friday")
        XCTAssertEqual(TodoCalendar.weekday(epochDay: nextMonday), 1)
        XCTAssertEqual(TodoCalendar.weekday(epochDay: monday - 1), 7, "Sunday")
    }

    /// Minutes wrap into a valid time of day instead of clamping, which would shorten
    /// a window that ends at midnight.
    func testNormalizedMinutesWrap() {
        XCTAssertEqual(TodoCalendar.normalizedMinutes(0), 0)
        XCTAssertEqual(TodoCalendar.normalizedMinutes(1439), 1439)
        XCTAssertEqual(TodoCalendar.normalizedMinutes(1440), 0)
        XCTAssertEqual(TodoCalendar.normalizedMinutes(-1), 1439)
        XCTAssertEqual(TodoCalendar.normalizedMinutes(-60), 1380)
    }

    /// The wall-clock conversion of a day and a time is the local midnight plus the
    /// minutes — checked through the same day it was built from, so a DST change in the
    /// test's own zone cannot make it flaky.
    func testDayTimeMillisIsTheLocalDayPlusTheMinutes() {
        let start = TodoCalendar.startOfDayMillis(epochDay: monday)

        XCTAssertEqual(TodoCodec.dayTimeMillis(epochDay: monday, minutes: 0), start)
        XCTAssertEqual(TodoCalendar.epochDay(ofMillis: start), monday)
        XCTAssertEqual(TodoCalendar.epochDay(ofMillis: start + 3_600_000), monday, "midday is still Monday")
    }

    /// A `Date` at UTC midday for the given day — the tests' own anchor, built without
    /// the code under test.
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        return utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
}

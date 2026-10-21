import XCTest
@testable import ClearView

/// The rules behind the Todo tab's numbers.
///
/// Every figure on the productivity panel, the heatmap and the calendar comes out of these
/// functions, so a mistake here is not a wrong pixel — it is a wrong week, a miss that never
/// happened, or a streak that counts a day nothing was asked of. The three that matter most are
/// pinned first: a future day is not a miss, a week starts on Monday, and a day with nothing due is
/// not a zero.
final class TodoStatsTests: XCTestCase {

    // MARK: - Fixtures

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
        return Int64(floor(date.timeIntervalSince1970 / 86_400))
    }

    /// A daily todo running over a window, so a test can speak about days rather than fields.
    private func daily(
        id: String = "t",
        from: Int64,
        to: Int64?,
        completions: [Int64: Int64] = [:],
        attempted: [Int64] = [],
        behavior: TodoBehavior = .normal,
        strict: Bool = false
    ) -> TodoItem {
        var item = TodoItem(id: id, title: id, startDateEpochDay: from, endDateEpochDay: to)
        item.completions = completions
        item.behavior = behavior
        item.strictInterval = strict
        for occurred in attempted {
            item.events.append(.attempted(timestampMillis: occurred * 86_400_000, epochDay: occurred))
        }
        return item
    }

    private var today: Int64 { day(2026, 10, 14) }

    // MARK: - Weeks

    func testAWeekStartsOnMonday() {
        let days = TodoStats.weekDays(today: today)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(TodoCalendar.weekday(epochDay: days[0]), 1, "the first day of a week is a Monday")
        XCTAssertEqual(TodoCalendar.weekday(epochDay: days[6]), 7, "and the last is a Sunday")
        XCTAssertEqual(days[0], TodoStats.mondayOf(today: today))
        XCTAssertTrue(days.contains(today))
    }

    func testAMonthIsItsWholeCalendarMonth() {
        let days = TodoStats.daysInMonthContaining(epochDay: day(2026, 2, 10))
        XCTAssertEqual(days.count, 28)
        XCTAssertEqual(days.first, day(2026, 2, 1))
        XCTAssertEqual(days.last, day(2026, 2, 28))

        // A leap year is 29, which is the point of reading the calendar rather than assuming.
        XCTAssertEqual(TodoStats.daysInMonthContaining(epochDay: day(2028, 2, 10)).count, 29)
    }

    func testMonthStepsLandOnTheFirstOfTheMonth() {
        let thisMonth = TodoStats.monthStart(epochDay: today, offset: 0)
        XCTAssertEqual(thisMonth, day(2026, 10, 1))
        XCTAssertEqual(TodoStats.monthStart(epochDay: thisMonth, offset: -1), day(2026, 9, 1))
        XCTAssertEqual(TodoStats.monthStart(epochDay: thisMonth, offset: 1), day(2026, 11, 1))
        // Crossing a year boundary is the case a naive `month - 1` gets wrong.
        XCTAssertEqual(TodoStats.monthStart(epochDay: day(2026, 1, 15), offset: -1), day(2025, 12, 1))
    }

    // MARK: - One day

    func testAFutureDayIsDueAndNotMissed() {
        let item = daily(from: today, to: today + 3)
        let stats = TodoStats.dayStats(items: [item], day: today + 2, today: today)
        XCTAssertEqual(stats.due, 1)
        XCTAssertEqual(stats.completed, 0)
        XCTAssertEqual(stats.missed, 0, "a schedule is not a failure")
        XCTAssertEqual(stats.attempted, 0)
    }

    func testAPastUnfinishedDayIsMissed() {
        let item = daily(from: today - 3, to: today)
        let stats = TodoStats.dayStats(items: [item], day: today - 2, today: today)
        XCTAssertEqual(stats.due, 1)
        XCTAssertEqual(stats.missed, 1)
    }

    func testTodayWithAnOpenWindowIsNotMissed() {
        let item = daily(from: today - 1, to: today + 1)
        let stats = TodoStats.dayStats(items: [item], day: today, today: today)
        XCTAssertEqual(stats.due, 1)
        XCTAssertEqual(stats.missed, 0, "today is still actionable until it is not")
    }

    /// A strict-interval todo whose window has closed TODAY is already locked — the one case where a
    /// day that is still happening counts as missed.
    func testATodaysClosedStrictWindowIsMissed() {
        var item = daily(from: today, to: today, strict: true)
        item.timeStartMinutes = 8 * 60
        item.timeEndMinutes = 9 * 60
        let afterWindow = TodoCalendar.millis(epochDay: today, minutes: 11 * 60)
        let stats = TodoStats.dayStats(items: [item], day: today, today: today, nowMillis: afterWindow)
        XCTAssertEqual(stats.missed, 1)

        let insideWindow = TodoCalendar.millis(epochDay: today, minutes: 8 * 60 + 30)
        let open = TodoStats.dayStats(items: [item], day: today, today: today, nowMillis: insideWindow)
        XCTAssertEqual(open.missed, 0)
    }

    func testTheThreeStatesAreDisjointAndAddUpToWhatWasDue() {
        let done = daily(id: "done", from: today, to: today, completions: [today: 1])
        let tried = daily(id: "tried", from: today, to: today, attempted: [today], behavior: .attempted)
        let missed = daily(id: "missed", from: today - 1, to: today - 1)
        let stats = TodoStats.dayStats(items: [done, tried, missed], day: today, today: today)
        XCTAssertEqual(stats.completed, 1)
        XCTAssertEqual(stats.attempted, 1)
        XCTAssertEqual(stats.due, 2, "only the two active today are due today")

        let yesterday = TodoStats.dayStats(items: [done, tried, missed], day: today - 1, today: today)
        XCTAssertEqual(yesterday.due, 1)
        XCTAssertEqual(yesterday.missed, 1)
    }

    /// Deleting a todo without its history is a promise that its past days keep counting.
    func testDeletedTodosStillCountTheirPast() {
        var item = daily(from: today - 2, to: today)
        item.isDeleted = true
        let stats = TodoStats.dayStats(items: [item], day: today - 1, today: today)
        XCTAssertEqual(stats.due, 1)
        XCTAssertEqual(stats.missed, 1)
    }

    // MARK: - Heat levels

    func testAnEmptyDayHasNoLevelRatherThanZero() {
        let stats = TodoDayStats()
        XCTAssertNil(stats.completionRatio)
        XCTAssertEqual(TodoStats.heatLevel(stats), .none)
    }

    func testTheLevelsFollowTheCompletedShare() {
        XCTAssertEqual(TodoStats.heatLevel(TodoDayStats(due: 4, completed: 0, attempted: 0, missed: 4)), .low)
        XCTAssertEqual(TodoStats.heatLevel(TodoDayStats(due: 4, completed: 1, attempted: 0, missed: 3)), .medium)
        XCTAssertEqual(TodoStats.heatLevel(TodoDayStats(due: 4, completed: 3, attempted: 0, missed: 1)), .high)
        XCTAssertEqual(TodoStats.heatLevel(TodoDayStats(due: 4, completed: 4, attempted: 0, missed: 0)), .full)
    }

    // MARK: - The heatmap's shape

    /// Whole Monday-first weeks, ending with the week today is in — a grid that started mid-week
    /// would have its Monday row half empty and read as missing data.
    func testTheHeatmapIsWholeWeeksEndingWithThisWeek() {
        for range in TodoHeatRange.allCases {
            let days = TodoStats.heatDays(today: today, range: range)
            XCTAssertEqual(days.count % 7, 0, "\(range.label) is whole weeks")
            XCTAssertEqual(TodoCalendar.weekday(epochDay: days[0]), 1)
            XCTAssertEqual(days.last, TodoStats.mondayOf(today: today) + 6)
            XCTAssertTrue(days.contains(today))
        }
    }

    func testTheHeatmapRangesGetLonger() {
        let four = TodoStats.heatDays(today: today, range: .lastFourWeeks).count
        let thirteen = TodoStats.heatDays(today: today, range: .lastThirteenWeeks).count
        let year = TodoStats.heatDays(today: today, range: .thisYear).count
        XCTAssertEqual(four, 28)
        XCTAssertEqual(thirteen, 91)
        XCTAssertGreaterThan(year, thirteen)
    }

    func testTheMonthLabelsNameEachMonthOnce() {
        let days = TodoStats.heatDays(today: today, range: .lastThirteenWeeks)
        let labels = TodoStats.heatMonthLabels(days: days)
        XCTAssertFalse(labels.isEmpty)
        XCTAssertEqual(Set(labels.map(\.label)).count, labels.count, "one label per month")
        XCTAssertEqual(labels.first?.label, TodoStats.heatMonthLabels(days: days).first?.label)
        // Every label sits inside the range it labels.
        for label in labels {
            XCTAssertTrue(days.contains(label.epochDay))
        }
    }

    // MARK: - Streaks

    func testAStreakCountsConsecutiveDaysWithACompletion() {
        let items = [
            daily(id: "a", from: today - 2, to: today, completions: [today - 2: 1, today - 1: 1, today: 1]),
        ]
        XCTAssertEqual(TodoStats.currentStreak(items: items, today: today), 3)
    }

    func testAGapEndsTheStreak() {
        let items = [
            daily(id: "a", from: today - 2, to: today, completions: [today - 2: 1, today: 1]),
        ]
        XCTAssertEqual(TodoStats.currentStreak(items: items, today: today), 1, "today-1 has nothing")
    }

    /// The point of ending yesterday: a day that is still happening cannot take a run away from you.
    func testAnUnfinishedTodayDoesNotBreakTheStreak() {
        let items = [
            daily(id: "a", from: today - 2, to: today, completions: [today - 2: 1, today - 1: 1]),
        ]
        XCTAssertEqual(TodoStats.currentStreak(items: items, today: today), 2)
    }

    /// Today only counts once something was actually completed — otherwise a morning would show a
    /// streak that has not been earned yet.
    func testTodayOnlyCountsOnceSomethingWasCompleted() {
        let all = [
            daily(id: "a", from: today, to: today, completions: [today: 1]),
        ]
        XCTAssertEqual(TodoStats.currentStreak(items: all, today: today), 1)

        let pending = [
            daily(id: "a", from: today, to: today),
        ]
        XCTAssertEqual(TodoStats.currentStreak(items: pending, today: today), 0)
    }

    func testTheLongestStreakBreaksOnAnyDayWithoutACompletion() {
        let days = TodoStats.weekDays(today: today) + TodoStats.weekDays(today: today + 7)
        var stats: [Int64: TodoDayStats] = [:]
        for day in days {
            stats[day] = TodoDayStats(due: 1, completed: 1, attempted: 0, missed: 0)
        }
        XCTAssertEqual(TodoStats.longestStreak(days: days, stats: stats), 14)

        // An empty day in the middle of the first week splits the run into 2 + 11.
        stats[days[2]] = TodoDayStats()
        XCTAssertEqual(TodoStats.longestStreak(days: days, stats: stats), 11)

        // A missed day beside it splits it again: 2 + 10.
        stats[days[3]] = TodoDayStats(due: 1, completed: 0, attempted: 0, missed: 1)
        XCTAssertEqual(TodoStats.longestStreak(days: days, stats: stats), 10)
    }

    // MARK: - The productivity dashboard

    /// A future day is not part of the period yet: it cannot be completed, so counting it as due
    /// would make the completion rate fall as the week goes on.
    func testTheWeekCountsOnlyDaysThatHaveArrived() {
        let item = daily(from: today, to: today + 3)
        let insights = TodoStats.periodInsights(items: [item], today: today, period: .week)
        XCTAssertEqual(insights.due, 1, "only today has arrived")
        XCTAssertEqual(insights.todayDue, 1)
    }

    func testWhatIsLeftTodayExcludesATodoThatIsAlreadyDone() {
        let open = daily(id: "open", from: today, to: today)
        let done = daily(id: "done", from: today, to: today, completions: [today: TodoCalendar.millis(epochDay: today, minutes: 9 * 60)])
        let insights = TodoStats.periodInsights(items: [open, done], today: today, period: .week)
        XCTAssertEqual(insights.due, 2)
        XCTAssertEqual(insights.completed, 1)
        XCTAssertEqual(insights.remainingToday, 1, "the completed one is not still waiting on you")
    }

    /// The trend compares like with like: this period's rate against the one before it.
    func testTheTrendComparesWithThePreviousPeriod() {
        // Last week everything due was done; this week nothing is.
        let lastWeek = daily(id: "a", from: today - 7, to: today - 7, completions: [today - 7: 1])
        let thisWeek = daily(id: "b", from: today, to: today)
        let insights = TodoStats.periodInsights(items: [lastWeek, thisWeek], today: today, period: .week)
        XCTAssertEqual(insights.improvementPoints, -100)
        XCTAssertFalse(insights.firstPeriod)
    }

    func testAPeriodWithNoEarlierPeriodIsFlaggedAsTheFirst() {
        let item = daily(from: today, to: today)
        let insights = TodoStats.periodInsights(items: [item], today: today, period: .week)
        XCTAssertNil(insights.improvementPoints)
        XCTAssertTrue(insights.firstPeriod, "there is nothing honest to compare against yet")
    }

    /// "Usual" is the reader's own recent average, and a period with nothing due is skipped rather
    /// than counted as a zero — no data is not the same fact as no effort.
    func testUsualIsTheAverageOfPeriodsThatHadSomethingDue() {
        let busy = daily(id: "busy", from: today - 7, to: today - 7, completions: [today - 7: 1])
        var second = daily(id: "second", from: today - 7, to: today - 7)
        second.completions = [today - 7: 1]
        let insights = TodoStats.periodInsights(items: [busy, second], today: today, period: .week)
        XCTAssertEqual(insights.usualCompleted, 2)

        let fresh = daily(from: today, to: today)
        XCTAssertNil(TodoStats.periodInsights(items: [fresh], today: today, period: .week).usualCompleted)
    }

    /// The ring follows partial work, so marking something attempted is visibly progress rather than
    /// a change that only the score notices.
    func testAnAttemptedTodoLiftsTheRingButNotTheCompletionCount() {
        let item = daily(from: today, to: today, attempted: [today], behavior: .attempted)
        let insights = TodoStats.periodInsights(items: [item], today: today, period: .week)
        XCTAssertEqual(insights.completed, 0)
        XCTAssertEqual(insights.creditRate, 0.5, accuracy: 0.001)
        XCTAssertEqual(insights.creditPercent, 50)
        XCTAssertTrue(insights.hasPartialCredit)
    }

    /// The score is built from what actually happened, so doing the work scores higher than not — and
    /// a period where everything due was completed earns full credit on the completion component.
    func testTheScoreRewardsWhatWasActuallyDone() {
        let done = daily(id: "done", from: today, to: today,
                         completions: [today: TodoCalendar.millis(epochDay: today, minutes: 8 * 60)])
        let doneInsights = TodoStats.periodInsights(items: [done], today: today, period: .week)
        XCTAssertEqual(doneInsights.breakdown?.completion, doneInsights.breakdown?.completionMax)
        XCTAssertGreaterThan(doneInsights.score ?? 0, 0)

        // The same day's work, with a todo from yesterday that was never done: the completion
        // component is now half, so the score has to fall.
        let missed = daily(id: "missed", from: today - 1, to: today - 1)
        let mixed = TodoStats.periodInsights(items: [done, missed], today: today, period: .week)
        XCTAssertLessThan(mixed.score ?? 0, doneInsights.score ?? 0)
        XCTAssertLessThan(mixed.breakdown?.completion ?? 0, mixed.breakdown?.completionMax ?? 0)
    }

    func testAPeriodWithNothingDueHasNoScoreRatherThanZero() {
        let insights = TodoStats.periodInsights(items: [], today: today, period: .week)
        XCTAssertNil(insights.score, "nothing to measure is not a score of zero")
        XCTAssertEqual(insights.due, 0)
    }

    func testTheMostProductiveWindowNeedsTwoCompletions() {
        var one = daily(id: "one", from: today, to: today)
        one.completions = [today: TodoCalendar.millis(epochDay: today, minutes: 5 * 60)]
        XCTAssertNil(TodoStats.mostProductiveWindow(items: [one], fromEpochDay: today, toEpochDay: today + 1))

        // Three completions in one morning hour and one at night: the window has to cover the
        // morning, wherever the reader's clock puts those hours.
        let cluster = [6 * 60, 6 * 60 + 30, 7 * 60]
        var items: [TodoItem] = []
        for (index, minutes) in cluster.enumerated() {
            var item = daily(id: "cluster\(index)", from: today, to: today)
            item.completions = [today: TodoCalendar.millis(epochDay: today, minutes: minutes)]
            items.append(item)
        }
        var evening = daily(id: "eve", from: today, to: today)
        evening.completions = [today: TodoCalendar.millis(epochDay: today, minutes: 20 * 60)]
        items.append(evening)

        let window = TodoStats.mostProductiveWindow(items: items, fromEpochDay: today, toEpochDay: today + 1)
        guard let window else { return XCTFail("four completions have a most productive window") }
        XCTAssertEqual(window.end - window.start, 2, "the window is two hours wide")
        let hours = cluster.map {
            Calendar.current.component(.hour, from: Date(
                timeIntervalSince1970: Double(TodoCalendar.millis(epochDay: today, minutes: $0)) / 1000
            ))
        }
        XCTAssertGreaterThanOrEqual(
            hours.filter { $0 >= window.start && $0 < window.end }.count, 3,
            "the window covers where the work actually happened"
        )
    }

    func testTheHeatmapSummaryCountsTheDaysTheGridShades() {
        let done = daily(id: "done", from: today - 1, to: today - 1, completions: [today - 1: 1])
        let tried = daily(id: "tried", from: today - 2, to: today - 2, attempted: [today - 2], behavior: .attempted)
        let days = TodoStats.weekDays(today: today)
        var stats: [Int64: TodoDayStats] = [:]
        for day in days { stats[day] = TodoStats.dayStats(items: [done, tried], day: day, today: today) }
        let summary = TodoStats.heatmapSummary(days: days, stats: stats)
        XCTAssertEqual(summary.completed, 1)
        XCTAssertEqual(summary.activeDays, 2, "an attempted day earned something too")
        XCTAssertEqual(summary.maxStreak, 2)
    }

    // MARK: - A period

    func testAPeriodAddsItsDaysUp() {
        let items = [
            daily(id: "a", from: today, to: today, completions: [today: 1]),
            daily(id: "b", from: today, to: today - 0, completions: [:]),
        ]
        let stats = TodoStats.weekStats(items: items, today: today)
        XCTAssertEqual(stats.days.count, 7)
        XCTAssertEqual(stats.due, 2)
        XCTAssertEqual(stats.completed, 1)
        XCTAssertEqual(stats.dueDays, 1)
        XCTAssertEqual(stats.activeDays, 1)
        XCTAssertEqual(stats.completionRatio, 0.5)
    }

    func testAnEmptyPeriodHasNoRatioAtAll() {
        let stats = TodoStats.monthStats(items: [], today: today)
        XCTAssertEqual(stats.due, 0)
        XCTAssertNil(stats.completionRatio, "an empty month is not a failed one")
        XCTAssertEqual(stats.streak, 0)
    }
}

import Foundation

/// How one day went, for the list, the calendar and the heatmap.
///
/// `due` counts the todos that were applicable on the day, and the other three are the disjoint
/// states that add up to it: completed, attempted-but-not-done, and missed. A day that is still in
/// the future has everything due and nothing missed — a schedule is not a failure.
struct TodoDayStats: Equatable {
    var due = 0
    var completed = 0
    var attempted = 0
    var missed = 0

    /// True when nothing was scheduled for the day at all.
    var isEmpty: Bool { due == 0 }

    /// Completed as a fraction of what was due, or nil for a day with nothing due.
    ///
    /// Nil rather than zero on purpose: an empty day is not a failed one, and colouring the two the
    /// same is how a heatmap ends up telling somebody they were unproductive on their holiday.
    var completionRatio: Double? {
        guard due > 0 else { return nil }
        return Double(completed) / Double(due)
    }
}

/// A stretch of days with everything the insights card reports about it.
struct TodoPeriodStats: Equatable {
    var days: [Int64] = []
    var dayStats: [Int64: TodoDayStats] = [:]
    var due = 0
    var completed = 0
    var attempted = 0
    var missed = 0
    /// Days in the period with something due — the denominator of "active days".
    var dueDays = 0
    /// Days in the period with at least one completion.
    var activeDays = 0

    var completionRatio: Double? {
        guard due > 0 else { return nil }
        return Double(completed) / Double(due)
    }

    /// The best run of consecutive due days on which something was completed.
    var streak: Int { TodoStats.longestStreak(days: days, stats: dayStats) }
}

/// The period the insights card is showing.
enum TodoPeriod: String, CaseIterable {
    case week, month

    var label: String {
        switch self {
        case .week: return "Weekly"
        case .month: return "Monthly"
        }
    }

    /// The noun the sentences around it use — "this week", "this month".
    var noun: String {
        switch self {
        case .week: return "week"
        case .month: return "month"
        }
    }

    var title: String {
        switch self {
        case .week: return "Weekly Insights & Statistics"
        case .month: return "Monthly Insights & Statistics"
        }
    }
}

/// The stretch the heatmap draws.
enum TodoHeatRange: String, CaseIterable {
    /// Four weeks, which is what a month of habit looks like at a glance.
    case lastFourWeeks
    /// Thirteen weeks, the classic quarter view.
    case lastThirteenWeeks
    /// Every day of the current year so far.
    case thisYear

    var label: String {
        switch self {
        case .lastFourWeeks: return "4 weeks"
        case .lastThirteenWeeks: return "3 months"
        case .thisYear: return "This year"
        }
    }
}

/// How full a heatmap cell is, from nothing due to everything done.
///
/// Five steps rather than a continuous ramp: a colour a person can name is what makes two cells
/// comparable, and a smooth ramp between them makes the difference invisible.
enum TodoHeatLevel: Int, CaseIterable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3
    case full = 4
}

/// The statistics the Todo tab is drawn from.
///
/// Pure functions over the stored items, so the screen, the heatmap and the calendar cannot disagree
/// about a number — and so the rules that are easy to get wrong (a future day is not a miss, a week
/// starts on Monday, an empty day is not a zero) are pinned by tests rather than by the drawing code.
enum TodoStats {

    /// The Monday of the week containing `today`, as an epoch day.
    ///
    /// Monday because `TodoCalendar.weekday` is 1 = Monday, which is the numbering `scheduledDays`
    /// is stored in — a week here and a repeat rule there have to agree about which day is first.
    static func mondayOf(today: Int64) -> Int64 {
        today - Int64(TodoCalendar.weekday(epochDay: today) - 1)
    }

    /// The seven days of the week containing `today`, Monday first.
    static func weekDays(today: Int64) -> [Int64] {
        let monday = mondayOf(today: today)
        return (0..<7).map { monday + Int64($0) }
    }

    /// The days of the month containing `today`, as epoch days.
    static func monthDays(today: Int64) -> [Int64] {
        let days = daysInMonthContaining(epochDay: today)
        return days
    }

    /// Every day of the month this epoch day falls in.
    static func daysInMonthContaining(epochDay: Int64) -> [Int64] {
        let date = TodoCalendar.date(epochDay: epochDay)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let range = utc.range(of: .day, in: .month, for: date) else { return [] }
        let first = epochDay - Int64(utc.component(.day, from: date) - 1)
        return range.map { first + Int64($0 - 1) }
    }

    /// The first day of the month `months` away from the month of `epochDay`.
    static func monthStart(epochDay: Int64, offset: Int) -> Int64 {
        let date = TodoCalendar.date(epochDay: epochDay)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let shifted = utc.date(byAdding: .month, value: offset, to: date) ?? date
        let components = utc.dateComponents([.year, .month], from: shifted)
        let first = utc.date(from: DateComponents(year: components.year, month: components.month, day: 1)) ?? shifted
        return Int64(floor(first.timeIntervalSince1970 / 86_400))
    }

    /// How one day went.
    ///
    /// Deleted todos are deliberately **not** excluded: deleting a todo without its history keeps its
    /// past days counting, which is exactly what the delete dialog promises. A future day is counted
    /// as due and never as missed, and a strict-interval day whose window has closed is missed even
    /// though it is today.
    static func dayStats(
        items: [TodoItem],
        day: Int64,
        today: Int64,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> TodoDayStats {
        var stats = TodoDayStats()
        for item in items {
            guard TodoCodec.isActiveOn(item, epochDay: day) else { continue }
            stats.due += 1
            if TodoCodec.completedOn(item, epochDay: day) {
                stats.completed += 1
            } else if TodoCodec.isAttemptedOn(item, epochDay: day) {
                stats.attempted += 1
            } else if day < today
                        || (day == today && TodoCodec.intervalEnded(item, epochDay: day, nowMillis: nowMillis)) {
                stats.missed += 1
            }
        }
        return stats
    }

    /// Everything the insights card reports about a stretch of days.
    static func periodStats(
        items: [TodoItem],
        days: [Int64],
        today: Int64,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> TodoPeriodStats {
        var period = TodoPeriodStats(days: days)
        for day in days {
            let stats = dayStats(items: items, day: day, today: today, nowMillis: nowMillis)
            period.dayStats[day] = stats
            period.due += stats.due
            period.completed += stats.completed
            period.attempted += stats.attempted
            period.missed += stats.missed
            if stats.due > 0 { period.dueDays += 1 }
            if stats.completed > 0 { period.activeDays += 1 }
        }
        return period
    }

    static func weekStats(
        items: [TodoItem],
        today: Int64,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> TodoPeriodStats {
        periodStats(items: items, days: weekDays(today: today), today: today, nowMillis: nowMillis)
    }

    static func monthStats(
        items: [TodoItem],
        today: Int64,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> TodoPeriodStats {
        periodStats(items: items, days: monthDays(today: today), today: today, nowMillis: nowMillis)
    }

    /// The current run of consecutive days with at least one completion.
    ///
    /// Ending today when today already has a completion, otherwise ending **yesterday** — an
    /// unfinished current day must not break a run that is still intact, which is the difference
    /// between "you are on a streak and today is not over" and "you lost it at midnight".
    static func currentStreak(items: [TodoItem], today: Int64) -> Int {
        func anyCompleted(_ day: Int64) -> Bool {
            items.contains { TodoCodec.completedOn($0, epochDay: day) }
        }
        var day = anyCompleted(today) ? today : today - 1
        var count = 0
        // The walk terminates on its own: a day before the first completion of any todo has nothing
        // to find. The bound is only there so a corrupt timestamp cannot spin forever.
        while anyCompleted(day) && count < 3_650 {
            count += 1
            day -= 1
        }
        return count
    }

    /// The longest run of consecutive days inside `days` with at least one completion.
    ///
    /// A day with nothing completed breaks the run, which is the same rule as the current streak —
    /// one definition of a streak, used in both places, so a number and a graph cannot disagree.
    static func longestStreak(days: [Int64], stats: [Int64: TodoDayStats]) -> Int {
        var best = 0
        var run = 0
        for day in days {
            guard let day_ = stats[day] else { continue }
            run = day_.completed > 0 ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }

    /// How full a day's cell is drawn.
    ///
    /// `full` is reserved for a day on which EVERYTHING due got done, so three of four is visibly
    /// not the same as four of four — the one distinction somebody looks at a heatmap to make.
    static func heatLevel(_ stats: TodoDayStats) -> TodoHeatLevel {
        guard let ratio = stats.completionRatio else { return .none }
        switch ratio {
        case ..<0.25: return .low
        case ..<0.5: return .medium
        case ..<1: return .high
        default: return .full
        }
    }

    /// The days the heatmap draws, as whole Monday-first weeks ending with the week `today` is in.
    ///
    /// Whole weeks rather than a trailing day count so every column has seven cells and the rows line
    /// up as weekdays — a grid that started mid-week would have its Monday row half empty and read as
    /// a gap in the data.
    static func heatDays(today: Int64, range: TodoHeatRange) -> [Int64] {
        let thisMonday = mondayOf(today: today)
        switch range {
        case .lastFourWeeks:
            return days(from: thisMonday - 21, to: thisMonday + 6)
        case .lastThirteenWeeks:
            return days(from: thisMonday - 84, to: thisMonday + 6)
        case .thisYear:
            let year = utcCalendar().component(.year, from: TodoCalendar.date(epochDay: today))
            let firstOfYear = utcCalendar().date(from: DateComponents(year: year, month: 1, day: 1))
                ?? TodoCalendar.date(epochDay: today)
            let firstDay = Int64(floor(firstOfYear.timeIntervalSince1970 / 86_400))
            return days(from: mondayOf(today: firstDay), to: thisMonday + 6)
        }
    }

    /// The first day of each month the heatmap covers, with its short name — the column labels.
    static func heatMonthLabels(days: [Int64]) -> [(epochDay: Int64, label: String)] {
        guard let first = days.first, let last = days.last else { return [] }
        var labels: [(Int64, String)] = []
        var day = first
        var lastMonth = -1
        while day <= last {
            let date = TodoCalendar.date(epochDay: day)
            let month = utcCalendar().component(.month, from: date)
            if month != lastMonth {
                lastMonth = month
                labels.append((day, monthName(date)))
            }
            day += 1
        }
        return labels
    }

    private static func days(from: Int64, to: Int64) -> [Int64] {
        guard to >= from else { return [] }
        return stride(from: from, through: to, by: 1).map { $0 }
    }

    private static func monthName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "MMM"
        return formatter.string(from: date)
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
}

// MARK: - The Productivity dashboard

/// One column of the progress strip: a day in the week view, a Monday-based week in the month view.
struct TodoPeriodBar: Equatable {
    /// The day itself (week), or the first day of that week inside the month (month).
    var epochDay: Int64
    var due: Int
    var completed: Int
    var attempted: Int
    var isToday: Bool
    var isFuture: Bool
}

/// The five components the score is made of, each already scaled to the 100-point total.
///
/// Kept as one value rather than five numbers on the card: the rows in a breakdown have to add up
/// to the total the reader was shown, and the only way that stays true is if they are computed
/// together, once.
struct TodoScoreBreakdown: Equatable {
    var completion = 0
    var completionMax = 0
    var consistency = 0
    var consistencyMax = 0
    var streak = 0
    var streakMax = 0
    var streakDays = 0
    var timeliness = 0
    var timelinessMax = 0
    var volume = 0
    var volumeMax = 0
    var baselineCompleted: Double?
    var closedItems = 0
    var overdueCount = 0
    var missedCount = 0
    var total = 0
}

/// Everything the insights card and its charts render, for ONE period.
///
/// One value rather than the card asking `TodoStats` six times: the ring's percentage, the trend
/// beside it and the score at the bottom are all read off the same counts, so no two numbers on the
/// panel can disagree about the same week.
struct TodoPeriodInsights {
    var period: TodoPeriod
    var bars: [TodoPeriodBar] = []
    var due = 0
    var completed = 0
    var attempted = 0
    var missed = 0
    /// Days in the period with something due.
    var daysWithDue = 0
    /// Days with at least one completion.
    var activeDays = 0
    /// The divisor of "active days": 7 for a week, elapsed days for a month.
    var activeDaysWindow = 7
    var streak = 0
    var longestStreak = 0
    var productiveMinutes = 0
    /// The best day of the period: its epoch day and its completion percentage.
    var bestDay: (epochDay: Int64, percent: Int)?
    /// The most productive 2-hour window, as start/end hours.
    var mostProductiveWindow: (start: Int, end: Int)?
    /// What is still completable today.
    var remainingToday = 0
    var todayDue = 0
    var todayCompleted = 0
    /// Completion-rate points against the same period one step back; nil without data.
    var improvementPoints: Int?
    /// True when there is no earlier period to compare against.
    var firstPeriod = false
    /// The user's own recent baseline — the average completed count of the previous periods that
    /// had something due. Nil when there is no past to compare against, never a fabricated zero.
    var usualCompleted: Int?
    var score: Int?
    var breakdown: TodoScoreBreakdown?
    /// Priority-weighted credit behind the ring: partial work (attempted, part of a time target)
    /// moves it, so the headline is progress rather than only completions.
    var dueWeight = 0.0
    var doneWeight = 0.0
    /// Occurrences that earned something without being completed.
    var partialOccurrences = 0

    /// Raw completion rate (completed / due).
    var completionRate: Double { due > 0 ? min(1, Double(completed) / Double(due)) : 0 }
    var percent: Int { Int(completionRate * 100) }
    /// The ring's fraction: behaviour-aware credit, so an attempt visibly counts.
    var creditRate: Double { dueWeight > 0 ? min(1, doneWeight / dueWeight) : completionRate }
    var creditPercent: Int { Int((creditRate * 100).rounded()) }
    /// True when partial work is what lifted the ring above raw completions.
    var hasPartialCredit: Bool { creditRate > completionRate + 0.0001 }
}

extension TodoStats {

    /// Base points for one completed occurrence, before behaviour weighting.
    static let basePoints: Double = 10

    /// Behaviour credit for one occurrence as a fraction of full value.
    static func creditFraction(_ item: TodoItem, epochDay: Int64) -> Double {
        min(1, max(0, occurrenceScore(item, epochDay: epochDay) / basePoints))
    }

    /// Minutes logged against a `.time` todo's target, as a 0…1 fraction.
    private static func timeFraction(_ item: TodoItem, epochDay: Int64) -> Double {
        let target = item.targetDurationMinutes ?? 0
        guard target > 0 else { return 1 }
        return min(1, max(0, Double(TodoCodec.timeSpentOn(item, epochDay: epochDay)) / Double(target)))
    }

    /// THE score for one occurrence — the single source every figure that says "points" uses.
    ///
    /// Partial states are worth something rather than nothing, because effort spent is real: an
    /// attempted day earns half, a time todo earns its logged share of the target, and ticking a
    /// time todo off without logging anything still earns half (the reader asserted they did it).
    static func occurrenceScore(
        _ item: TodoItem,
        epochDay: Int64,
        basePoints: Double = TodoStats.basePoints
    ) -> Double {
        let attempted = TodoCodec.isAttemptedOn(item, epochDay: epochDay)
        let minutes = TodoCodec.timeSpentOn(item, epochDay: epochDay)
        if TodoCodec.completedOn(item, epochDay: epochDay) {
            switch item.behavior {
            case .normal: return basePoints
            case .attempted: return basePoints * 0.5
            case .time:
                let target = item.targetDurationMinutes ?? 0
                if target <= 0 { return basePoints }
                return max(timeFraction(item, epochDay: epochDay), 0.5) * basePoints
            }
        }
        switch item.behavior {
        case .attempted where attempted:
            return basePoints * 0.5
        case .time:
            let byTime = minutes > 0 ? timeFraction(item, epochDay: epochDay) : 0
            let byAttempt = attempted ? 0.5 : 0
            return max(byTime, byAttempt) * basePoints
        default:
            return 0
        }
    }

    /// What is still completable today — the honest reading of "left today".
    ///
    /// A strict-interval todo whose window already closed is locked as missed, so it is not still
    /// waiting on the reader and must not be counted as work left to do.
    static func remainingToday(
        items: [TodoItem],
        today: Int64,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> Int {
        items.filter { TodoCodec.canCompleteOn($0, epochDay: today, nowMillis: nowMillis) }.count
    }

    /// The most productive 2-hour window among the completions of `from..<to`.
    ///
    /// Nil below two completions: a single completion says nothing about when somebody works, and a
    /// "most productive time" built from one data point would be a guess dressed as a finding.
    static func mostProductiveWindow(items: [TodoItem], fromEpochDay: Int64, toEpochDay: Int64) -> (start: Int, end: Int)? {
        var hours: [Int] = []
        for item in items {
            for (day, at) in item.completions where day >= fromEpochDay && day < toEpochDay {
                let hour = Calendar.current.component(.hour, from: Date(timeIntervalSince1970: Double(at) / 1000))
                hours.append(hour)
            }
        }
        guard hours.count >= 2 else { return nil }
        var bestStart = 0
        var bestCount = -1
        for start in 0...22 {
            let count = hours.filter { $0 >= start && $0 < start + 2 }.count
            if count > bestCount {
                bestCount = count
                bestStart = start
            }
        }
        return (bestStart, bestStart + 2)
    }

    /// The days of `days` that earned something, the completions on them, and the longest run.
    ///
    /// Read off the same day list the grid is drawn from, so the headline over a heatmap can never
    /// disagree with the squares under it.
    static func heatmapSummary(days: [Int64], stats: [Int64: TodoDayStats]) -> (completed: Int, activeDays: Int, maxStreak: Int) {
        var completed = 0
        var active = 0
        var run = 0
        var best = 0
        for day in days {
            let s = stats[day] ?? TodoDayStats()
            completed += s.completed
            if s.completed > 0 || s.attempted > 0 {
                active += 1
                run += 1
                best = max(best, run)
            } else {
                run = 0
            }
        }
        return (completed, active, best)
    }

    /// The ONE scorer behind the score on the card, ported from the Android rules.
    ///
    /// Completion 45 (priority-weighted), consistency 18, streak 12, timeliness 10, volume 15. A
    /// component whose denominator is zero is EXCLUDED and the remaining weights are rescaled, so a
    /// half-measurable period still reaches 100 — and a period with nothing due scores nil rather
    /// than a free zero.
    private static func score(
        dueWeight: Double,
        doneWeight: Double,
        daysWithDue: Int,
        activeDays: Int,
        streak: Int,
        closedItems: Int,
        overdue: Int,
        missed: Int,
        completed: Int,
        baselineCompleted: Double?
    ) -> TodoScoreBreakdown? {
        guard dueWeight > 0 else { return nil }
        let wCompletion = 45.0, wConsistency = 18.0, wStreak = 12.0, wTimeliness = 10.0, wVolume = 15.0
        let completionRaw = wCompletion * (doneWeight / dueWeight)
        let consistencyRaw = daysWithDue > 0 ? wConsistency * (Double(activeDays) / Double(daysWithDue)) : 0
        let streakRaw = wStreak * (Double(min(streak, 7)) / 7)
        let timelinessRaw = closedItems > 0
            ? wTimeliness * (1 - Double(overdue + missed) / Double(closedItems))
            : 0
        let hasBaseline = baselineCompleted != nil
        let baseline = baselineCompleted ?? 0
        let volumeRaw: Double = {
            guard hasBaseline else { return 0 }
            if baseline <= 0 { return completed > 0 ? wVolume : 0 }
            return wVolume * min(1, max(0, Double(completed) / baseline))
        }()
        let included = wCompletion + wConsistency + wStreak
            + (closedItems > 0 ? wTimeliness : 0)
            + (hasBaseline ? wVolume : 0)
        let scale = 100 / included
        func scaled(_ raw: Double) -> Int { min(100, max(0, Int((scale * raw).rounded()))) }
        var breakdown = TodoScoreBreakdown()
        breakdown.completion = scaled(completionRaw)
        breakdown.completionMax = scaled(wCompletion)
        breakdown.consistency = scaled(consistencyRaw)
        breakdown.consistencyMax = scaled(wConsistency)
        breakdown.streak = scaled(streakRaw)
        breakdown.streakMax = scaled(wStreak)
        breakdown.streakDays = streak
        breakdown.timeliness = closedItems > 0 ? scaled(timelinessRaw) : 0
        breakdown.timelinessMax = closedItems > 0 ? scaled(wTimeliness) : 0
        breakdown.volume = hasBaseline ? scaled(volumeRaw) : 0
        breakdown.volumeMax = hasBaseline ? scaled(wVolume) : 0
        breakdown.baselineCompleted = baselineCompleted
        breakdown.closedItems = closedItems
        breakdown.overdueCount = overdue
        breakdown.missedCount = missed
        breakdown.total = scaled(completionRaw + consistencyRaw + streakRaw + timelinessRaw + volumeRaw)
        return breakdown
    }

    /// The four previous periods' average completion count, or nil when none of them had anything due.
    ///
    /// Weeks with nothing due are skipped rather than counted as zero: "no data" and "no effort" are
    /// different facts, and scoring somebody against an empty past would punish them for having
    /// just started.
    static func usualCompleted(
        items: [TodoItem],
        today: Int64,
        period: TodoPeriod,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> Int? {
        var totals: [Int] = []
        for back in 1...4 {
            let days: [Int64]
            switch period {
            case .week:
                days = weekDays(today: today - Int64(back * 7))
            case .month:
                var anchor = monthStart(epochDay: today, offset: 0)
                for _ in 0..<back { anchor = monthStart(epochDay: anchor - 1, offset: 0) }
                days = daysInMonthContaining(epochDay: anchor)
            }
            let stats = periodStats(items: items, days: days, today: today, nowMillis: nowMillis)
            if stats.due > 0 { totals.append(stats.completed) }
        }
        guard !totals.isEmpty else { return nil }
        return Int((Double(totals.reduce(0, +)) / Double(totals.count)).rounded())
    }

    /// One bar per month of the year containing `today`, up to the current month.
    ///
    /// The month view charts its whole YEAR rather than its four or five weeks: "how does this month
    /// compare with the others" is the question a monthly reader has, and a bar per week would answer
    /// a question they did not ask.
    static func yearMonthBars(
        items: [TodoItem],
        today: Int64,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> [TodoPeriodBar] {
        let date = TodoCalendar.date(epochDay: today)
        let year = utcCalendar().component(.year, from: date)
        let january = utcCalendar().date(from: DateComponents(year: year, month: 1, day: 1)) ?? date
        let yearStart = Int64(floor(january.timeIntervalSince1970 / 86_400))
        var bars: [TodoPeriodBar] = []
        for month in 0..<12 {
            let start = monthStart(epochDay: yearStart, offset: month)
            let days = daysInMonthContaining(epochDay: start)
            guard let first = days.first else { continue }
            guard first <= today else { break }
            var due = 0, completed = 0, attempted = 0
            for day in days.filter({ $0 <= today }) {
                let stats = dayStats(items: items, day: day, today: today, nowMillis: nowMillis)
                due += stats.due
                completed += stats.completed
                attempted += stats.attempted
            }
            bars.append(
                TodoPeriodBar(
                    epochDay: first,
                    due: due,
                    completed: completed,
                    attempted: attempted,
                    isToday: days.contains(today),
                    isFuture: false
                )
            )
        }
        return bars
    }

    /// Everything the Productivity card and its chart read, for the period containing `today`.
    ///
    /// Only days that have ARRIVED count — the same rule as everywhere else: a future schedule is
    /// not due, so it can neither be completed nor held against the reader. The month's bars are its
    /// Monday-based weeks, so a phone gets seven readable columns instead of thirty slivers.
    static func periodInsights(
        items: [TodoItem],
        today: Int64,
        period: TodoPeriod,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> TodoPeriodInsights {
        var insights = TodoPeriodInsights(period: period)
        let allDays = period == .week ? weekDays(today: today) : daysInMonthContaining(epochDay: today)
        let elapsed = allDays.filter { $0 <= today }
        var stats: [Int64: TodoDayStats] = [:]
        for day in allDays {
            stats[day] = day <= today ? dayStats(items: items, day: day, today: today, nowMillis: nowMillis) : TodoDayStats()
        }

        insights.due = elapsed.reduce(0) { $0 + (stats[$1]?.due ?? 0) }
        insights.completed = elapsed.reduce(0) { $0 + (stats[$1]?.completed ?? 0) }
        insights.attempted = elapsed.reduce(0) { $0 + (stats[$1]?.attempted ?? 0) }
        insights.missed = elapsed.reduce(0) { $0 + (stats[$1]?.missed ?? 0) }
        insights.daysWithDue = elapsed.filter { (stats[$0]?.due ?? 0) > 0 }.count
        insights.activeDays = elapsed.filter { (stats[$0]?.completed ?? 0) > 0 }.count
        insights.activeDaysWindow = period == .week ? 7 : elapsed.count
        insights.streak = currentStreak(items: items, today: today)
        insights.longestStreak = longestStreak(days: elapsed, stats: stats)
        insights.remainingToday = remainingToday(items: items, today: today, nowMillis: nowMillis)
        let todayStats = dayStats(items: items, day: today, today: today, nowMillis: nowMillis)
        insights.todayDue = todayStats.due
        insights.todayCompleted = todayStats.completed
        insights.productiveMinutes = elapsed.reduce(0) { sum, day in
            sum + items.filter { TodoCodec.isActiveOn($0, epochDay: day) }
                .reduce(0) { $0 + TodoCodec.timeSpentOn($1, epochDay: day) }
        }

        // The best day only exists once something was actually completed: "100% of two" on a day
        // with two one-off todos the reader never touched is not a best day, it is an empty one.
        if insights.completed > 0 {
            let candidates = elapsed.filter { (stats[$0]?.due ?? 0) > 0 }
            let best = candidates.max { a, b in
                let sa = stats[a] ?? TodoDayStats(), sb = stats[b] ?? TodoDayStats()
                if sa.completionRatio != sb.completionRatio {
                    return (sa.completionRatio ?? 0) < (sb.completionRatio ?? 0)
                }
                return sa.completed < sb.completed
            }
            if let best, let ratio = stats[best]?.completionRatio {
                insights.bestDay = (best, Int(ratio * 100))
            }
        }

        // The bars: days for a week, Monday-based weeks for a month.
        if period == .week {
            insights.bars = allDays.map { day in
                let s = stats[day] ?? TodoDayStats()
                return TodoPeriodBar(
                    epochDay: day,
                    due: s.due,
                    completed: s.completed,
                    attempted: day <= today ? items.filter { TodoCodec.isAttemptedOn($0, epochDay: day) }.count : 0,
                    isToday: day == today,
                    isFuture: day > today
                )
            }
        } else {
            var week: [Int64] = []
            for day in allDays {
                week.append(day)
                let isLast = day == allDays.last
                if TodoCalendar.weekday(epochDay: day) == 7 || isLast {
                    let inside = week.filter { $0 <= today }
                    insights.bars.append(
                        TodoPeriodBar(
                            epochDay: week[0],
                            due: inside.reduce(0) { $0 + (stats[$1]?.due ?? 0) },
                            completed: inside.reduce(0) { $0 + (stats[$1]?.completed ?? 0) },
                            attempted: inside.reduce(0) { sum, d in
                                sum + items.filter { TodoCodec.isAttemptedOn($0, epochDay: d) }.count
                            },
                            isToday: week.contains(today),
                            isFuture: week.allSatisfy { $0 > today }
                        )
                    )
                    week = []
                }
            }
        }

        // Priority-weighted credit for the elapsed days — the ring and the score's completion
        // component read the same numbers, so partial work cannot count in one place and not the other.
        var closedItems = 0
        var overdue = 0
        var missedCount = 0
        for day in elapsed {
            for item in items where TodoCodec.isActiveOn(item, epochDay: day) {
                let weight = Double(item.priority.scoreWeight)
                insights.dueWeight += weight
                let credit = creditFraction(item, epochDay: day)
                insights.doneWeight += weight * credit
                if credit > 0 && credit < 1 && !TodoCodec.completedOn(item, epochDay: day) {
                    insights.partialOccurrences += 1
                }
                let closed = day < today || TodoCodec.intervalEnded(item, epochDay: day, nowMillis: nowMillis)
                guard closed else { continue }
                closedItems += 1
                if !TodoCodec.completedOn(item, epochDay: day) {
                    if TodoCodec.isArchived(item, today: today) { missedCount += 1 } else { overdue += 1 }
                }
            }
        }

        let previousDays: [Int64]
        switch period {
        case .week:
            previousDays = weekDays(today: today - 7)
        case .month:
            let anchor = monthStart(epochDay: monthStart(epochDay: today, offset: 0) - 1, offset: 0)
            previousDays = daysInMonthContaining(epochDay: anchor)
        }
        let previous = periodStats(items: items, days: previousDays, today: today, nowMillis: nowMillis)
        if insights.due > 0 && previous.due > 0 {
            insights.improvementPoints = Int((insights.completionRate - Double(previous.completed) / Double(previous.due)) * 100)
            insights.firstPeriod = false
        } else {
            insights.firstPeriod = insights.due > 0
        }

        insights.mostProductiveWindow = mostProductiveWindow(
            items: items,
            fromEpochDay: allDays.first ?? today,
            toEpochDay: (allDays.last ?? today) + 1
        )
        insights.usualCompleted = usualCompleted(items: items, today: today, period: period, nowMillis: nowMillis)
        insights.breakdown = score(
            dueWeight: insights.dueWeight,
            doneWeight: insights.doneWeight,
            daysWithDue: insights.daysWithDue,
            activeDays: insights.activeDays,
            streak: insights.streak,
            closedItems: closedItems,
            overdue: overdue,
            missed: missedCount,
            completed: insights.completed,
            baselineCompleted: insights.usualCompleted.map(Double.init)
        )
        insights.score = insights.breakdown?.total
        return insights
    }
}

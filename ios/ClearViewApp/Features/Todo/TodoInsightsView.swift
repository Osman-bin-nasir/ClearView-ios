import SwiftUI
import Charts

/// Colours the Todo statistics need beyond the shared palette — the same values the Android screen
/// draws with, so the two platforms read the same.
enum TodoStatPalette {
    static let done = Color(red: 0x43 / 255, green: 0xA0 / 255, blue: 0x47 / 255)
    static let missed = Color(red: 0xE5 / 255, green: 0x39 / 255, blue: 0x35 / 255)
    static let attempted = Color(red: 0xF9 / 255, green: 0xA8 / 255, blue: 0x25 / 255)
}

/// The Todo tab's productivity dashboard: a period switch, the period's card, and the volume chart.
///
/// They are one section rather than three because they answer one question at three distances: the
/// card says how the period went, its strip says which days it went that way, and the chart below
/// says how that compares with the periods before it. Every figure comes from one
/// `TodoPeriodInsights`, so a number and the graph under it cannot disagree.
struct TodoInsightsCard: View {
    let items: [TodoItem]
    let today: Int64
    let dailyTarget: Int
    let onEditTarget: () -> Void

    @State private var period: TodoPeriod = .week
    @State private var showBreakdown = false

    private var insights: TodoPeriodInsights {
        TodoStats.periodInsights(items: items, today: today, period: period)
    }

    private var monthBars: [TodoPeriodBar] {
        TodoStats.yearMonthBars(items: items, today: today)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Productivity").font(.title3.bold())
                Spacer(minLength: 0)
                // ONE control showing the period it is reading, with an arrow: the period is a lens
                // on the same card, so it costs no row of its own.
                Menu {
                    Picker("Period", selection: $period) {
                        ForEach(TodoPeriod.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(period.label).font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color.cvPrimary)
                }
                .accessibilityLabel("Change the period")
            }

            card

            volumeChart
        }
        .sheet(isPresented: $showBreakdown) {
            TodoScoreBreakdownSheet(insights: insights)
        }
    }

    // MARK: - The card

    private var card: some View {
        CVCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(period.title).font(.subheadline.bold())

                if insights.due == 0 {
                    // Said plainly rather than drawn as an empty ring at 0%, which would read as a
                    // period of failure instead of a period with nothing in it.
                    Text("No todos were due this \(period.noun) — add a todo to start building your insights.")
                        .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                } else {
                    hero
                    if period == .week { weeklyProgress }
                    Divider()
                    tiles
                    Divider()
                    facts
                    scoreRow
                }
            }
        }
    }

    /// The ring, what it counts, what is left today, and how this period compares with the last.
    private var hero: some View {
        HStack(alignment: .center, spacing: 18) {
            TodoRing(fraction: insights.creditRate, percent: insights.creditPercent, caption: "of \(insights.due)")
            VStack(alignment: .leading, spacing: 4) {
                Text("This \(period.noun)").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                Text("\(insights.completed) of \(insights.due) completed").font(.subheadline.bold())
                // Partial work is real progress — say so when it is what lifted the ring, so the
                // percentage can never be read as "completed".
                if insights.hasPartialCredit {
                    Text("\(insights.partialOccurrences) with partial credit")
                        .font(.caption2).foregroundStyle(TodoStatPalette.attempted)
                }
                HStack(spacing: 6) {
                    Image(systemName: insights.remainingToday == 0 ? "checkmark.circle.fill" : "hourglass")
                        .font(.system(size: 13))
                        .foregroundStyle(insights.remainingToday == 0 ? TodoStatPalette.done : TodoStatPalette.attempted)
                    Text(insights.remainingToday == 0 ? "All done today" : "\(insights.remainingToday) left today")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(insights.remainingToday == 0 ? TodoStatPalette.done : Color.cvOnSurface)
                }
                trendChip
            }
            Spacer(minLength: 0)
        }
    }

    /// How the period compares with the one before it — or an honest line when there is nothing to
    /// compare against. Never a made-up percentage.
    private var trendChip: some View {
        let delta = insights.improvementPoints
        let (text, tint, symbol): (String, Color, String) = {
            switch delta {
            case .some(let value) where value > 0:
                return ("↑ \(value)% vs last \(period.noun)", TodoStatPalette.done, "chart.line.uptrend.xyaxis")
            case .some(let value) where value < 0:
                return ("↓ \(-value)% vs last \(period.noun)", TodoStatPalette.missed, "chart.line.downtrend.xyaxis")
            case .some:
                return ("No change vs last \(period.noun)", Color.cvOnSurfaceVariant, "equal")
            case .none where insights.firstPeriod:
                return ("First \(period.noun) — no comparison yet", Color.cvOnSurfaceVariant, "chart.line.uptrend.xyaxis")
            case .none:
                return ("No change vs last \(period.noun)", Color.cvOnSurfaceVariant, "equal")
            }
        }()
        return HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
            Text(text).font(.caption2.weight(.semibold)).lineLimit(2)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
    }

    /// The week at a glance: one column per day, split into done / attempted / still to do, with the
    /// day's letter and its completed count under it.
    ///
    /// Stacked rather than a single completion bar, because "three due, three missed" and "three due,
    /// three done" are the same height and opposite facts.
    private var weeklyProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Weekly Progress").font(.subheadline.bold())
                Spacer(minLength: 0)
                Text("\(insights.percent)%").font(.subheadline.bold()).foregroundStyle(Color.cvPrimary)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(insights.bars, id: \.epochDay) { bar in
                    VStack(spacing: 4) {
                        barColumn(bar, height: 56)
                        Text(TodoCalendar.weekdayName(TodoCalendar.weekday(epochDay: bar.epochDay)).prefix(1))
                            .font(.caption2)
                            .foregroundStyle(bar.isToday ? Color.cvPrimary : Color.cvOnSurfaceVariant)
                        Text("\(bar.completed)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(bar.completed > 0 ? TodoStatPalette.done : Color.cvOnSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Text("\(insights.completed) / \(insights.due) Todos completed").font(.caption)
                .foregroundStyle(Color.cvOnSurfaceVariant)
            CompletedBar(fraction: insights.completionRate)
        }
    }

    /// Four figures about the period, each answering something the others do not.
    private var tiles: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            StatTile(symbol: "checkmark.circle.fill",
                     value: "\(insights.todayCompleted) / \(insights.todayDue)",
                     label: "Completed today",
                     tint: TodoStatPalette.done)
            StatTile(symbol: "flame.fill",
                     value: insights.streak > 0 ? "\(insights.streak) day\(insights.streak == 1 ? "" : "s")" : "—",
                     label: "Current streak",
                     tint: insights.streak > 0 ? TodoStatPalette.attempted : Color.cvOnSurfaceVariant)
            StatTile(symbol: "calendar.badge.checkmark",
                     value: "\(insights.activeDays) of \(insights.activeDaysWindow)",
                     label: "Active days this \(period.noun)",
                     tint: Color.cvPrimary)
            // The comparison is stated in the LABEL so the tile never shows a bare number with no
            // context — and a missing baseline says so instead of implying a zero.
            StatTile(symbol: "chart.line.uptrend.xyaxis",
                     value: insights.usualCompleted != nil ? "\(insights.completed)" : "—",
                     label: insights.usualCompleted.map { "Usual \($0) this \(period.noun)" } ?? "No history yet",
                     tint: Color.cvPrimary)
        }
    }

    /// The period's secondary facts: one row each, label hard-left and value hard-right.
    private var facts: some View {
        VStack(spacing: 6) {
            InsightRow(label: "Longest streak", value: "\(insights.longestStreak) day\(insights.longestStreak == 1 ? "" : "s")")
            if let best = insights.bestDay {
                InsightRow(
                    label: "Best day",
                    // A week has one of each weekday, so the name is unambiguous there; a month has
                    // four or five of them, so the month view names the actual date.
                    value: "\(period == .week ? TodoCalendar.weekdayName(TodoCalendar.weekday(epochDay: best.epochDay)) : TodoCalendar.shortDateLabel(epochDay: best.epochDay)) — \(best.percent)%"
                )
            }
            if let window = insights.mostProductiveWindow {
                InsightRow(
                    label: "Most productive time",
                    value: "\(TodoCodec.timeLabel(window.start * 60)) – \(TodoCodec.timeLabel(window.end * 60))"
                )
            }
            if insights.productiveMinutes > 0 {
                InsightRow(label: "Productive time", value: Self.minutesLabel(insights.productiveMinutes))
            }
        }
    }

    /// The score, and the way into what it is made of.
    private var scoreRow: some View {
        Button { showBreakdown = true } label: {
            HStack(alignment: .center, spacing: 10) {
                Text("\(period.noun) Score").font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text(insights.score != nil ? "Keep going" : "Nothing to score yet")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                Text(insights.score != nil ? "\(insights.score ?? 0) / 100" : "— / 100")
                    .font(.subheadline.bold()).foregroundStyle(Color.cvPrimary)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(insights.score == nil)
        .accessibilityLabel("What the score is made of")
    }

    // MARK: - The volume chart

    /// How much was due and how it went, per day of the week or per month of the year.
    ///
    /// The same stacked language as the card's strip, so the two read as one chart at two zooms.
    private var volumeChart: some View {
        let bars = period == .week ? insights.bars : monthBars
        return VStack(alignment: .leading, spacing: 10) {
            Text(period == .week ? "Total Todos" : "Total Todos by month").font(.headline)

            HStack(spacing: 12) {
                legendSwatch(TodoStatPalette.done, "Done")
                legendSwatch(TodoStatPalette.attempted, "Attempted")
                legendSwatch(TodoStatPalette.missed, "Incomplete")
            }

            HStack(alignment: .bottom, spacing: 6) {
                ForEach(bars, id: \.epochDay) { bar in
                    VStack(spacing: 4) {
                        barColumn(bar, height: 84)
                        Text(axisLabel(bar))
                            .font(.caption2)
                            .foregroundStyle(bar.isToday ? Color.cvPrimary : Color.cvOnSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity)
                    .opacity(bar.isFuture ? 0.4 : 1)
                }
            }
        }
    }

    /// The letter under a column: the weekday for a week, the month for a year.
    private func axisLabel(_ bar: TodoPeriodBar) -> String {
        if period == .week {
            return String(TodoCalendar.weekdayName(TodoCalendar.weekday(epochDay: bar.epochDay)).prefix(1))
        }
        let date = TodoCalendar.date(epochDay: bar.epochDay)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let names = ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"]
        let month = calendar.component(.month, from: date)
        return (1...12).contains(month) ? names[month - 1] : "?"
    }

    /// One column of the stacked bar: what was done at the bottom, then what was attempted, then what
    /// never happened.
    private func barColumn(_ bar: TodoPeriodBar, height: CGFloat) -> some View {
        let total = max(bar.due, bar.completed + bar.attempted + (bar.due - bar.completed - bar.attempted))
        let unit = bar.due > 0 ? height / CGFloat(total) : 0
        let remaining = max(0, bar.due - bar.completed - bar.attempted)
        return VStack(spacing: 1) {
            Spacer(minLength: 0)
            if remaining > 0 {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.cvOnSurfaceVariant.opacity(0.18))
                    .frame(height: max(2, unit * CGFloat(remaining)))
            }
            if bar.attempted > 0 {
                RoundedRectangle(cornerRadius: 3)
                    .fill(TodoStatPalette.attempted)
                    .frame(height: max(2, unit * CGFloat(bar.attempted)))
            }
            if bar.completed > 0 {
                RoundedRectangle(cornerRadius: 3)
                    .fill(TodoStatPalette.done)
                    .frame(height: max(2, unit * CGFloat(bar.completed)))
            }
            if bar.due == 0 {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.cvOnSurfaceVariant.opacity(0.12))
                    .frame(height: 3)
            }
        }
        .frame(height: height)
        .accessibilityLabel("\(TodoCalendar.shortDateLabel(epochDay: bar.epochDay)): \(bar.completed) of \(bar.due) completed")
    }

    private func legendSwatch(_ colour: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
        }
    }

    /// "1 h 20 m" / "45 m" — minutes, said the way a duration is said.
    static func minutesLabel(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) m" }
        if rest == 0 { return "\(hours) h" }
        return "\(hours) h \(rest) m"
    }
}

/// A period's completion, as a ring that carries its own number.
private struct TodoRing: View {
    let fraction: Double
    let percent: Int
    let caption: String

    var body: some View {
        ZStack {
            Circle().stroke(Color.cvOnSurfaceVariant.opacity(0.15), lineWidth: 10)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(fraction >= 1 ? TodoStatPalette.done : Color.cvPrimary,
                        style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(percent)%").font(.headline.monospacedDigit())
                Text(caption).font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant).lineLimit(1)
            }
        }
        .frame(width: 94, height: 94)
        .accessibilityLabel("\(percent) percent complete, \(caption)")
    }
}

/// One dashboard figure: a tinted icon and value, with its label underneath.
private struct StatTile: View {
    let symbol: String
    let value: String
    let label: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(tint)
                Text(value).font(.subheadline.bold())
            }
            Text(label).font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant).lineLimit(2)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cvSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The completed share of a period, as one bar.
///
/// Drawn rather than a `ProgressView` so the fill is the app's own accent at every size and style,
/// and so the bar reads the same in both colour schemes as the columns above it.
private struct CompletedBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.cvOnSurfaceVariant.opacity(0.18))
                Capsule()
                    .fill(Color.cvPrimary)
                    .frame(width: max(6, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 8)
        .accessibilityLabel("\(Int((min(1, max(0, fraction)) * 100).rounded())) percent completed")
    }
}

/// One label/value row: label hard-left, value hard-right, one shared value edge.
private struct InsightRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
            Spacer(minLength: 0)
            Text(value).font(.subheadline.weight(.semibold))
        }
    }
}

/// What the score is made of, so the number above it is explainable rather than a verdict.
private struct TodoScoreBreakdownSheet: View {
    let insights: TodoPeriodInsights
    @Environment(\.dismiss) private var dismiss

    private var rows: [(String, Int, Int)] {
        guard let b = insights.breakdown else { return [] }
        var rows: [(String, Int, Int)] = [
            ("Completion", b.completion, b.completionMax),
            ("Consistency", b.consistency, b.consistencyMax),
            ("Streak", b.streak, b.streakMax),
        ]
        if b.timelinessMax > 0 { rows.append(("Timeliness", b.timeliness, b.timelinessMax)) }
        if b.volumeMax > 0 { rows.append(("Volume vs usual", b.volume, b.volumeMax)) }
        return rows
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(insights.score ?? 0)").font(.system(size: 44, weight: .bold))
                        Text("/ 100").font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                        Spacer(minLength: 0)
                    }
                    Text("\(insights.completed) of \(insights.due) completed this \(insights.period.noun) · \(insights.activeDays) active day\(insights.activeDays == 1 ? "" : "s") · \(insights.streak) day streak")
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)

                    CVCard {
                        VStack(spacing: 10) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(row.0).font(.subheadline.weight(.semibold))
                                        Spacer(minLength: 0)
                                        Text("\(row.1) / \(row.2)").font(.subheadline)
                                            .foregroundStyle(Color.cvOnSurfaceVariant)
                                    }
                                    ProgressView(value: row.2 > 0 ? Double(row.1) / Double(row.2) : 0)
                                        .tint(Color.cvPrimary)
                                }
                            }
                        }
                    }

                    Text("Partial work counts: an attempted todo earns half, and logged time earns its share of the target. A component a period cannot measure is left out and the rest is rescaled, so the score is never docked for something you were never asked to do.")
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }
                .padding(16)
            }
            .background(Color.cvBackground)
            .navigationTitle("\(insights.period.noun.capitalized) score")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .tint(.cvPrimary)
    }
}

/// Every day for months, coloured by how much of what was due got done, with the range's totals.
struct TodoHeatmapCard: View {
    let items: [TodoItem]
    let today: Int64

    @State private var range: TodoHeatRange = .lastThirteenWeeks

    private var days: [Int64] { TodoStats.heatDays(today: today, range: range) }

    /// The heatmap is whole weeks, so the columns are weeks and the rows are weekdays.
    private var weeks: [[Int64]] {
        let all = days
        return stride(from: 0, to: all.count, by: 7).map { Array(all[$0..<min($0 + 7, all.count)]) }
    }

    private var counts: [Int64: TodoDayStats] {
        var result: [Int64: TodoDayStats] = [:]
        for day in days where day <= today {
            result[day] = TodoStats.dayStats(items: items, day: day, today: today)
        }
        return result
    }

    /// The headline numbers, read off the same days the squares are drawn from.
    private var summary: (completed: Int, activeDays: Int, maxStreak: Int) {
        TodoStats.heatmapSummary(days: days.filter { $0 <= today }, stats: counts)
    }

    private var headline: String {
        switch range {
        case .lastFourWeeks: return "\(summary.completed) completed in the last 4 weeks"
        case .lastThirteenWeeks: return "\(summary.completed) completed in the last 3 months"
        case .thisYear:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let year = calendar.component(.year, from: TodoCalendar.date(epochDay: today))
            return "\(summary.completed) completed in \(year)"
        }
    }

    var body: some View {
        CVCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(headline).font(.subheadline.bold())
                    Spacer(minLength: 8)
                    // The range is part of the headline rather than a control above it: it is what the
                    // number beside it means, so the two belong on one line.
                    Menu {
                        Picker("Range", selection: $range) {
                            ForEach(TodoHeatRange.allCases, id: \.self) { option in
                                Text(option.label).tag(option)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(range.label).font(.caption.weight(.semibold))
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Color.cvPrimary)
                    }
                    .accessibilityLabel("Choose the period to show")
                }

                HStack(spacing: 14) {
                    Text("Total active days: \(summary.activeDays)").font(.caption)
                        .foregroundStyle(Color.cvOnSurfaceVariant)
                    Text("Max streak: \(summary.maxStreak)").font(.caption)
                        .foregroundStyle(Color.cvOnSurfaceVariant)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 3) {
                        ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                            VStack(spacing: 3) {
                                ForEach(week, id: \.self) { day in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(colour(for: day))
                                        .frame(width: 12, height: 12)
                                        .accessibilityLabel(accessibilityLabel(for: day))
                                }
                            }
                        }
                    }
                }
                // A day with nothing due is deliberately the faintest step rather than the same as a
                // failed one — "nothing was asked" and "nothing was done" are not the same fact, and a
                // grid that colours them alike is a grid that nags.
                HStack(spacing: 6) {
                    Text("Less").font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                    ForEach(TodoHeatLevel.allCases, id: \.self) { level in
                        RoundedRectangle(cornerRadius: 2).fill(colour(level)).frame(width: 12, height: 12)
                    }
                    Text("More").font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                    Spacer(minLength: 0)
                    Text("Dots: nothing due").font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                }
            }
        }
    }

    private func colour(for day: Int64) -> Color {
        guard let stats = counts[day] else { return Color.cvSurfaceContainerLow }
        return colour(TodoStats.heatLevel(stats))
    }

    private func colour(_ level: TodoHeatLevel) -> Color {
        switch level {
        case .none: return Color.cvSurfaceContainerLow
        case .low: return Color.cvPrimary.opacity(0.25)
        case .medium: return Color.cvPrimary.opacity(0.45)
        case .high: return Color.cvPrimary.opacity(0.7)
        case .full: return Color.cvPrimary
        }
    }

    private func accessibilityLabel(for day: Int64) -> String {
        let label = TodoCalendar.shortDateLabel(epochDay: day)
        guard let stats = counts[day], stats.due > 0 else { return "\(label): nothing due" }
        return "\(label): \(stats.completed) of \(stats.due) completed"
    }
}

/// A month at a time, each day marked by what happened on it, and a tap showing that day's todos.
struct TodoCalendarCard: View {
    let items: [TodoItem]
    let today: Int64

    @State private var monthStart: Int64
    @State private var selectedDay: Int64?

    init(items: [TodoItem], today: Int64) {
        self.items = items
        self.today = today
        _monthStart = State(initialValue: TodoStats.monthStart(epochDay: today, offset: 0))
    }

    private var days: [Int64] { TodoStats.daysInMonthContaining(epochDay: monthStart) }

    private var monthLabel: String {
        let date = TodoCalendar.date(epochDay: monthStart)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")!
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: date)
    }

    /// How much of this month's plan has been completed — said above the grid rather than left for the
    /// reader to count out of the dots.
    private var monthPercent: Int {
        var due = 0
        var completed = 0
        for day in days where day <= today {
            let stats = TodoStats.dayStats(items: items, day: day, today: today)
            due += stats.due
            completed += stats.completed
        }
        guard due > 0 else { return 0 }
        return Int((Double(completed) / Double(due) * 100).rounded())
    }

    /// The blank cells before the first of the month, so the weekday columns line up.
    private var leadingBlanks: Int {
        TodoCalendar.weekday(epochDay: monthStart) - 1
    }

    var body: some View {
        CVCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "calendar").foregroundStyle(Color.cvPrimary)
                    Text(monthLabel).font(.subheadline.bold())
                    Spacer(minLength: 0)
                    Button {
                        monthStart = TodoStats.monthStart(epochDay: monthStart, offset: -1)
                    } label: {
                        Image(systemName: "chevron.left").frame(width: 40, height: 40)
                    }
                    .accessibilityLabel("Previous month")
                    Button {
                        monthStart = TodoStats.monthStart(epochDay: monthStart, offset: 1)
                    } label: {
                        Image(systemName: "chevron.right").frame(width: 40, height: 40)
                    }
                    .accessibilityLabel("Next month")
                }

                Text("This month: \(monthPercent)% completed")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)

                // One letter per column, the same width as a day cell: a month is seven columns
                // wide, and "Wednesday" would either be clipped or push the grid out of line.
                HStack(spacing: 0) {
                    ForEach(1...7, id: \.self) { weekday in
                        Text(TodoCalendar.weekdayName(weekday).prefix(1))
                            .font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                            .frame(maxWidth: .infinity)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(0..<leadingBlanks, id: \.self) { index in
                        Color.clear.frame(height: 42).id("blank-\(index)")
                    }
                    ForEach(days, id: \.self) { day in
                        cell(day)
                    }
                }

                HStack(spacing: 10) {
                    legendSwatch(TodoStatPalette.done, "Done")
                    legendSwatch(TodoStatPalette.missed, "Missed")
                    legendSwatch(Color.cvOnSurfaceVariant.opacity(0.45), "Scheduled")
                }
            }
        }
        .sheet(item: Binding(
            get: { selectedDay.map(DaySelection.init) },
            set: { if $0 == nil { selectedDay = nil } }
        )) { selection in
            TodoDayDetailSheet(items: items, day: selection.day, today: today)
        }
    }

    /// One day: its number, and a dot for what happened on it.
    ///
    /// One dot rather than a bar per todo, because a month is thirty cells wide: the dot answers
    /// \"did this day happen\" and the tap answers \"what was on it\". Green means something was
    /// completed, red means something was missed, and grey means the day is simply scheduled — which
    /// is not a failure and must not be coloured like one.
    private func cell(_ day: Int64) -> some View {
        let date = TodoCalendar.date(epochDay: day)
        let dayNumber = Calendar.utcDayNumber(date)
        let stats = TodoStats.dayStats(items: items, day: day, today: today)
        let isToday = day == today
        return Button {
            selectedDay = day
        } label: {
            VStack(spacing: 3) {
                Text("\(dayNumber)").font(.caption2.weight(isToday ? .bold : .regular))
                Circle()
                    .fill(dotColour(for: stats))
                    .frame(width: 6, height: 6)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(isToday ? Color.cvPrimary.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(day, stats: stats))
    }

    private func dotColour(for stats: TodoDayStats) -> Color {
        if stats.completed > 0 { return TodoStatPalette.done }
        if stats.missed > 0 { return TodoStatPalette.missed }
        return Color.cvOnSurfaceVariant.opacity(0.45)
    }

    private func accessibilityLabel(_ day: Int64, stats: TodoDayStats) -> String {
        let label = TodoCalendar.shortDateLabel(epochDay: day)
        guard stats.due > 0 else { return "\(label): nothing due" }
        return "\(label): \(stats.completed) of \(stats.due) completed"
    }

    private func legendSwatch(_ colour: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(colour).frame(width: 8, height: 8)
            Text(label).font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
        }
    }
}

/// One day chosen from the calendar, wrapped so it can drive a sheet.
private struct DaySelection: Identifiable {
    let day: Int64
    var id: Int64 { day }
}

/// What was scheduled for one day, and how each of it went.
private struct TodoDayDetailSheet: View {
    let items: [TodoItem]
    let day: Int64
    let today: Int64
    @Environment(\.dismiss) private var dismiss

    private var dayItems: [TodoItem] {
        items.filter { TodoCodec.isActiveOn($0, epochDay: day) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if dayItems.isEmpty {
                        CVEmptyState(
                            title: "No todos on this day",
                            message: "Nothing was scheduled for \(TodoCalendar.shortDateLabel(epochDay: day)).",
                            symbol: "calendar"
                        ).padding(.top, 24)
                    }
                    ForEach(dayItems) { item in
                        CVCard {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.subheadline.weight(.semibold))
                                    .strikethrough(TodoCodec.completedOn(item, epochDay: day))
                                Text(stateLabel(item)).font(.caption)
                                    .foregroundStyle(stateColour(item))
                                if !item.details.isEmpty {
                                    Text(item.details).font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Color.cvBackground)
            .navigationTitle(TodoCalendar.shortDateLabel(epochDay: day))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .tint(.cvPrimary)
    }

    private func stateLabel(_ item: TodoItem) -> String {
        if TodoCodec.completedOn(item, epochDay: day) { return "Completed" }
        if TodoCodec.isAttemptedOn(item, epochDay: day) { return "Attempted" }
        if day < today { return "Missed" }
        if day == today { return "Still to do today" }
        return "Scheduled"
    }

    private func stateColour(_ item: TodoItem) -> Color {
        if TodoCodec.completedOn(item, epochDay: day) { return TodoStatPalette.done }
        if TodoCodec.isAttemptedOn(item, epochDay: day) { return TodoStatPalette.attempted }
        if day < today { return TodoStatPalette.missed }
        return Color.cvOnSurfaceVariant
    }
}

extension Calendar {
    /// The day of the month this UTC date falls on, which is the number a calendar cell shows.
    static func utcDayNumber(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.component(.day, from: date)
    }
}

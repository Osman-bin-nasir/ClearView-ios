import SwiftUI
import Charts

@MainActor
@Observable
final class TodoScreenModel {
    var items: [TodoItem]
    var filter: TodoFilter = .today
    var search = ""
    var sort: TodoSort { didSet { store.sort = sort } }
    var dailyTarget: Int { didSet { store.dailyTarget = dailyTarget } }
    var today = TodoCalendar.epochDay(of: Date())
    private let store: TodoStore

    init(store: TodoStore = TodoStore()) {
        self.store = store
        items = store.items
        sort = store.sort
        dailyTarget = store.dailyTarget
    }

    var visible: [TodoItem] {
        TodoCodec.sorted(TodoCodec.filter(items, filter: filter, today: today), sort: sort, today: today)
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var completedToday: Int { items.filter { TodoCodec.isActiveOn($0, epochDay: today) && $0.completions[today] != nil }.count }
    var dueToday: Int { TodoCodec.filter(items, filter: .today, today: today).count }
    var progress: Double { min(1, Double(completedToday) / Double(max(1, dailyTarget))) }

    /// How many todos each filter would show, rendered inside its chip.
    ///
    /// Counted from the same `TodoCodec` calls the lists themselves use, so a chip can never
    /// promise a number the list below it does not deliver. History is counted through
    /// `historySorted` because its list is the history entries, not the todos that have any.
    func count(for filter: TodoFilter) -> Int {
        let q = search.trimmed.lowercased()
        let matches = { (item: TodoItem) in
            q.isEmpty || item.title.lowercased().contains(q) || item.details.lowercased().contains(q)
        }
        if filter == .history {
            return TodoCodec.historySorted(items, today: today).filter { matches($0.item) }.count
        }
        return TodoCodec.filter(items, filter: filter, today: today).filter(matches).count
    }

    /// The history cards that were completed, and those that were missed.
    ///
    /// Two lists rather than one: "this got done" and "this did not" are different answers with
    /// different actions, and the search query filters them here so the header count and the
    /// sections can never disagree.
    var historyCompleted: [TodoCodec.HistoryEntry] { historyEntries.filter { $0.completedCount > 0 } }
    var historyMissed: [TodoCodec.HistoryEntry] { historyEntries.filter { $0.missedCount > 0 } }

    private var historyEntries: [TodoCodec.HistoryEntry] {
        let q = search.trimmed.lowercased()
        return TodoCodec.historySorted(items, today: today).filter {
            q.isEmpty || $0.item.title.lowercased().contains(q) || $0.item.details.lowercased().contains(q)
        }
    }

    /// Upcoming todos grouped by the date they are next required, earliest first.
    var upcomingGroups: [(day: Int64, items: [TodoItem])] {
        let upcoming = TodoCodec.filter(items, filter: .upcoming, today: today)
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
        let grouped = Dictionary(grouping: upcoming) { TodoCodec.nextActiveDate($0, today: today) ?? today }
        return grouped.keys.sorted().map { ($0, TodoCodec.sorted(grouped[$0] ?? [], sort: sort, today: today)) }
    }

    /// True when everything due today is done — what the Today tab uses to surface what is next.
    var todayAllDone: Bool { dueToday > 0 && completedToday >= dueToday }

    func clearCompletedHistory() {
        items = TodoCodec.removeCompletedHistory(items, today: today)
        store.saveItems(items)
    }

    func clearMissedHistory() {
        items = TodoCodec.removeMissedHistory(items, today: today)
        store.saveItems(items)
    }

    func clearAllHistory() {
        items = TodoCodec.clearHistory(items, today: today)
        store.saveItems(items)
    }

    /// The destructive reset: every todo goes, and so does every reminder queued for one.
    func resetEverything() {
        items = []
        store.saveItems(items)
        Task { await TodoReminderScheduler.shared.refresh() }
    }

    func refreshDay() {
        today = TodoCalendar.epochDay(of: Date())
        items = store.items
        Task { await TodoReminderScheduler.shared.refresh() }
    }

    func attempt(_ item: TodoItem) {
        refreshDay()
        guard !item.isDeleted, TodoCodec.isActiveOn(item, epochDay: today), item.completions[today] == nil else { return }
        if TodoCodec.isAttemptedOn(item, epochDay: today) {
            items = TodoCodec.unattempted(items, id: item.id, epochDay: today, at: TodoStoreClock.nowMillis())
        } else {
            items = TodoCodec.attempted(items, id: item.id, epochDay: today, at: TodoStoreClock.nowMillis())
        }
        store.saveItems(items)
    }

    func logTime(_ item: TodoItem, minutes: Int) {
        refreshDay()
        guard !item.isDeleted, TodoCodec.isActiveOn(item, epochDay: today), (1...1440).contains(minutes) else { return }
        items = TodoCodec.timeAdded(items, id: item.id, epochDay: today, at: TodoStoreClock.nowMillis(), addedMinutes: minutes)
        store.saveItems(items)
    }

    func deleteHistory(_ item: TodoItem) {
        items = TodoCodec.removedWithHistory(items, id: item.id)
        store.saveItems(items)
    }

    func save(_ item: TodoItem) {
        items = items.contains { $0.id == item.id } ? TodoCodec.updated(items, item: item) : TodoCodec.added(items, item: item)
        store.saveItems(items)
    }

    func toggle(_ item: TodoItem) {
        refreshDay()
        guard item.completions[today] != nil || TodoCodec.canCompleteOn(item, epochDay: today, nowMillis: TodoStoreClock.nowMillis()) else { return }
        items = TodoCodec.toggled(items, id: item.id, epochDay: today, at: TodoStoreClock.nowMillis()).items
        store.saveItems(items)
    }

    func remove(_ item: TodoItem) {
        items = TodoCodec.removed(items, id: item.id)
        store.saveItems(items)
    }
}

struct TodoView: View {
    @State private var model = TodoScreenModel()
    @State private var editing: TodoItem?
    @State private var deleting: TodoItem?
    @State private var showSearch = false
    @State private var logging: TodoItem?
    @State private var loggedMinutes = 10
    @State private var reminders = TodoReminderScheduler.shared
    @State private var showTarget = false
    @State private var targetDraft = 3
    @State private var showReset = false
    @State private var resetText = ""
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showSearch { CVSearchField(text: $model.search, prompt: "Search by todo name or details") }
                if let message = reminders.message { CVErrorBanner(message: message) }

                // Every filter, with its live count, in the order the lists are meant to be read.
                // The count is part of the chip so the reader can see where things are without
                // tapping through all seven — and it always matches the list below, because both
                // come from the same `TodoCodec` calls.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(TodoFilter.allCases, id: \.self) { filter in
                            CVChip(title: "\(filter.label) · \(model.count(for: filter))",
                                   selected: model.filter == filter) { model.filter = filter }
                        }
                    }
                }

                listHeader

                if model.items.isEmpty {
                    CVEmptyState(title: "No Todos yet",
                        message: "Add something you want to accomplish today.", symbol: "checklist")
                } else {
                    listContent
                }

                TodoInsightsCard(items: model.items, today: model.today, dailyTarget: model.dailyTarget) {
                    targetDraft = model.dailyTarget
                    showTarget = true
                }
                TodoHeatmapCard(items: model.items, today: model.today)
                TodoCalendarCard(items: model.items, today: model.today)
            }.padding(16).padding(.bottom, 80)
        }.background(Color.cvBackground).navigationTitle("Todo").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                Button {
                    showSearch.toggle()
                    if !showSearch { model.search = "" }
                } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("Search tasks")
                Menu {
                    Picker("Show", selection: $model.filter) {
                        ForEach(TodoFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Sort by", selection: $model.sort) {
                        ForEach(TodoSort.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Stepper("Daily target: \(model.dailyTarget)", value: $model.dailyTarget, in: 1...50)
                } label: { Image(systemName: "line.3.horizontal.decrease") }.accessibilityLabel("Task options")
            }
            .overlay(alignment: .bottomTrailing) {
                Button {
                    editing = TodoItem(id: UUID().uuidString, title: "", startDateEpochDay: model.today, endDateEpochDay: model.today)
                } label: {
                    Image(systemName: "plus").font(.title2.weight(.medium)).foregroundStyle(Color.cvOnPrimary)
                        .frame(width: 52, height: 52).background(Color.cvPrimary, in: RoundedRectangle(cornerRadius: 17))
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                }.buttonStyle(.plain).accessibilityLabel("Add task").padding(16)
            }
            .sheet(item: $editing) { item in TodoEditor(item: item) { model.save($0) } }
            .confirmationDialog("Delete this task? Its history will be kept.", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete task", role: .destructive) { if let deleting { model.remove(deleting) }; deleting = nil }
                Button("Delete task and its history", role: .destructive) { if let deleting { model.deleteHistory(deleting) }; deleting = nil }
            }
            .sheet(item: $logging) { item in
                NavigationStack {
                    Form {
                        Section(item.title) { Stepper("\(loggedMinutes) minutes", value: $loggedMinutes, in: 1...1440) }
                        Button("Log time") { model.logTime(item, minutes: loggedMinutes); logging = nil }
                    }.navigationTitle("Log time").toolbar { Button("Cancel") { logging = nil } }
                }
            }
            .sheet(isPresented: $showTarget) {
                NavigationStack {
                    Form {
                        Stepper("Target todos per day: \(targetDraft)", value: $targetDraft, in: 1...50)
                        Text("How many todos you aim to complete each day. It is shown as your 🎯 daily progress.")
                            .font(.footnote)
                    }
                    .navigationTitle("Daily completion target")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showTarget = false } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                model.dailyTarget = targetDraft
                                showTarget = false
                            }
                        }
                    }
                }
                .tint(.cvPrimary)
            }
            // The destructive one, and it asks for the WORD.
            //
            // A button that deletes every todo is one tap away from the row above it, and this
            // screen is a screen of rows that look alike. Typing RESET is what turns a tap into a
            // decision — it cannot be done without reading what it says.
            .alert("Reset everything?", isPresented: $showReset) {
                TextField("Type RESET to confirm", text: $resetText)
                Button("Reset everything", role: .destructive) {
                    guard resetText.trimmed.uppercased() == "RESET" else { return }
                    model.resetEverything()
                    resetText = ""
                }
                .disabled(resetText.trimmed.uppercased() != "RESET")
                Button("Cancel", role: .cancel) { resetText = "" }
            } message: {
                Text("This permanently deletes EVERY todo and all of its progress, history and statistics — the app goes back to how it looks on a fresh install. Completed and missed days, streaks, the progress bar, the calendar, the bar graph, the heatmap and the score all go. Reminders for those todos are cancelled too. This cannot be undone.")
            }
            .onAppear { model.refreshDay() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshDay() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in model.refreshDay() }
    }

    /// The header above the list: which filter this is, and what it is counting.
    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title(for: model.filter)).font(.title3.bold())
            if model.filter == .today {
                if model.dueToday > 0 {
                    // The same figures the ring is drawn from, said in words: a percentage of a
                    // target the reader chose, which is what makes it a goal rather than a score.
                    let percent = min(100, max(0, Int((Double(model.completedToday) / Double(max(1, model.dailyTarget)) * 100).rounded())))
                    Text("🎯 \(model.completedToday) / \(model.dailyTarget) completed · \(percent)% of today's target")
                        .font(.caption.bold()).foregroundStyle(Color.cvPrimary)
                } else {
                    Text("Nothing due today").font(.caption.bold()).foregroundStyle(Color.cvPrimary)
                }
                Button {
                    targetDraft = model.dailyTarget
                    showTarget = true
                } label: {
                    HStack(spacing: 5) {
                        Text("Daily target: \(model.dailyTarget) Todos").font(.caption2)
                        Image(systemName: "pencil").font(.system(size: 11))
                    }
                    .foregroundStyle(Color.cvOnSurfaceVariant)
                }.buttonStyle(.plain)
            } else {
                Text("\(shownCount) todo\(shownCount == 1 ? "" : "s")")
                    .font(.caption.bold()).foregroundStyle(Color.cvPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func title(for filter: TodoFilter) -> String {
        switch filter {
        case .today: return "Today's Todos"
        case .upcoming: return "Upcoming"
        case .completed: return "Completed Today"
        case .history: return "History"
        case .all: return "All Todos"
        case .temporary: return "Temporary"
        case .permanent: return "Permanent"
        }
    }

    /// How many rows the current filter is showing.
    ///
    /// History counts its two sections together, because that is what the screen shows; every other
    /// filter counts the list itself.
    private var shownCount: Int {
        model.filter == .history
            ? model.historyCompleted.count + model.historyMissed.count
            : model.visible.count
    }

    // MARK: - The list

    @ViewBuilder
    private var listContent: some View {
        switch model.filter {
        case .history:
            historySection

        case .upcoming:
            if model.upcomingGroups.isEmpty {
                emptyLine(model.search.isEmpty ? "Nothing scheduled ahead" : "No todos match this filter or search")
            } else {
                ForEach(model.upcomingGroups, id: \.day) { group in
                    Text(upcomingGroupLabel(group.day))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.cvPrimary)
                        .padding(.top, 8)
                    ForEach(group.items) { item in
                        // Upcoming is a view-only list: the manage actions live in the Temporary and
                        // Permanent lists, and nothing here is actionable today.
                        taskCard(item, showActions: false)
                    }
                }
            }

        default:
            LazyVStack(spacing: 6) {
                if model.visible.isEmpty {
                    // "Completed" gets its own nudge, because nothing done yet is a normal state
                    // rather than a failed search.
                    emptyLine(model.filter == .completed
                        ? "Nothing completed yet today — tick a todo off on the Today tab and it shows up here."
                        : "No todos match this filter or search")
                }
                ForEach(model.visible) { item in
                    taskCard(item, showActions: showActions(for: model.filter))
                }
            }

            // Today all done → surface what is next, without pretending it is actionable now.
            if model.filter == .today && model.todayAllDone && !upcomingPreview.isEmpty {
                Divider().padding(.vertical, 8)
                Text("All done for today! 🎉").font(.subheadline.bold())
                Text("Upcoming").font(.caption.weight(.semibold)).foregroundStyle(Color.cvPrimary)
                ForEach(upcomingPreview) { item in
                    taskCard(item, showActions: false)
                }
            }
        }
    }

    /// The ⋮ menu belongs to the lists that manage a plan: Today (whose cards are the ones being
    /// ticked), Temporary and Permanent. Upcoming, Completed and All stay view-only, so a control
    /// that would only edit something out of sight is not offered.
    private func showActions(for filter: TodoFilter) -> Bool {
        filter == .today || filter == .temporary || filter == .permanent
    }

    /// The next few upcoming todos, for the "all done today" teaser.
    private var upcomingPreview: [TodoItem] {
        Array(
            TodoCodec.filter(model.items, filter: .upcoming, today: model.today)
                .sorted {
                    (TodoCodec.nextActiveDate($0, today: model.today) ?? 0)
                        < (TodoCodec.nextActiveDate($1, today: model.today) ?? 0)
                }
                .prefix(5)
        )
    }

    /// "Tomorrow" / "Wednesday" / "Mon, Aug 12" — the same wording Android groups by, so a date is
    /// only spelled out when it is far enough away for the weekday to stop being an answer.
    private func upcomingGroupLabel(_ day: Int64) -> String {
        if day == model.today + 1 { return "Tomorrow" }
        if day <= model.today + 7 {
            let names = ["", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
            let weekday = TodoCalendar.weekday(epochDay: day)
            return (1...7).contains(weekday) ? names[weekday] : TodoCalendar.shortDateLabel(epochDay: day)
        }
        return TodoCalendar.shortDateLabel(epochDay: day)
    }

    // MARK: - History

    /// The past, in two halves.
    ///
    /// "Completed" and "Incomplete / Missed" are separate sections because they are separate facts
    /// with separate actions — and "Clear" here hides the CARDS only: the completions stay, so
    /// today's count, the target, the ring and the heatmap keep counting them. Reset is the
    /// destructive one, and it asks for the word.
    @ViewBuilder
    private var historySection: some View {
        HStack(spacing: 12) {
            Text("✓ \(model.historyCompleted.count) completed")
                .font(.caption.bold()).foregroundStyle(Color.cvPrimary)
            Text("✗ \(model.historyMissed.count) missed")
                .font(.caption.bold()).foregroundStyle(Color.cvError)
            Spacer(minLength: 0)
            Button("Clear All") { model.clearAllHistory() }
                .font(.caption.bold())
                .disabled(model.historyCompleted.isEmpty && model.historyMissed.isEmpty)
            Button("Reset") { resetText = ""; showReset = true }
                .font(.caption.bold()).foregroundStyle(Color.cvError)
        }

        HStack {
            Text("Completed").font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            if !model.historyCompleted.isEmpty {
                Button("Clear") { model.clearCompletedHistory() }.font(.caption)
            }
        }.padding(.top, 6)

        if model.historyCompleted.isEmpty {
            emptyLine("No completed todos yet — finish a todo on its due date and it appears here.")
        } else {
            ForEach(model.historyCompleted) { entry in
                historyCard(entry, completed: true)
            }
        }

        HStack {
            Text("Incomplete / Missed").font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            if !model.historyMissed.isEmpty {
                Button("Clear") { model.clearMissedHistory() }.font(.caption)
            }
        }.padding(.top, 6)

        if model.historyMissed.isEmpty {
            emptyLine("Nothing missed — todos that pass their due date uncompleted appear here.")
        } else {
            ForEach(model.historyMissed) { entry in
                historyCard(entry, completed: false)
            }
        }
    }

    private func historyCard(_ entry: TodoCodec.HistoryEntry, completed: Bool) -> some View {
        CVCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.item.title).font(.subheadline.weight(.semibold))
                Text((completed ? "✓ \(entry.completedCount) completed" : "✗ \(entry.missedCount) missed")
                     + "  ·  last \(TodoCalendar.shortDateLabel(epochDay: entry.lastOccurrence))")
                    .font(.caption).foregroundStyle(completed ? Color.cvPrimary : Color.cvError)
                if entry.attemptedCount > 0 {
                    Text("◐ \(entry.attemptedCount) attempted")
                        .font(.caption).foregroundStyle(Color.cvPrimary)
                }
                if entry.totalMinutes > 0 {
                    Text("⏱ \(entry.totalMinutes) minutes logged")
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }
                HStack(spacing: 14) {
                    Button("Edit") { editing = entry.item }.font(.caption.bold())
                    Button("Delete", role: .destructive) { deleting = entry.item }.font(.caption.bold())
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 16)
    }

    // MARK: - One card

    /// One todo, as it appears in whichever list is showing.
    ///
    /// What a card offers depends on the list it is in, and that is the permission model rather than
    /// a preference: the **checkbox** exists only on Today, because that is the one place a todo is
    /// actionable — a future todo can never be completed early, and a completed one in another list
    /// is shown as done rather than made toggleable. A strict-interval day whose window has closed is
    /// locked BOTH ways ("can't redo"), so its box is drawn ticked and refuses the tap.
    private func taskCard(_ item: TodoItem, showActions: Bool) -> some View {
        let now = TodoStoreClock.nowMillis()
        let isDueToday = TodoCodec.isActiveOn(item, epochDay: model.today)
        let completedToday = isDueToday && TodoCodec.completedOn(item, epochDay: model.today)
        let missedToday = isDueToday && !completedToday
            && TodoCodec.intervalEnded(item, epochDay: model.today, nowMillis: now)
        let canComplete = TodoCodec.canCompleteOn(item, epochDay: model.today, nowMillis: now)
        let isAttempted = TodoCodec.isAttemptedOn(item, epochDay: model.today)
        let timeSpent = TodoCodec.timeSpentOn(item, epochDay: model.today)
        let points = TodoStats.occurrenceScore(item, epochDay: model.today)
        // Type accent for the left bar: amber = Temporary, blue = Permanent.
        let typeAccent = (item.type == .temporary
            ? Color(red: 0.70, green: 0.42, blue: 0.00)
            : Color(red: 0.08, green: 0.40, blue: 0.75))
            .opacity(completedToday ? 0.45 : 1)
        // ONE meta line: the schedule, the time and the reminders, in the order they happen. It
        // used to be three labelled rows, which read as three separate facts about one schedule.
        let meta: String = {
            let scheduled = TodoCodec.scheduledTimeLabel(item)
            let reminders = TodoCodec.reminderLabel(item)
            var text = TodoCodec.scheduleLabel(item, today: model.today)
            if let scheduled { text += " • \(scheduled)" }
            if let reminders, reminders != scheduled { text += " · \(reminders)" }
            return text
        }()

        return HStack(alignment: .top, spacing: 0) {
            // A thin colour bar rather than a text pill: temporary / permanent is a property of the
            // card, and a pill on every row is icon soup.
            Rectangle().fill(typeAccent).frame(width: 5)

            HStack(alignment: .center, spacing: 8) {
                leadingMarker(item: item, isDueToday: isDueToday, completedToday: completedToday,
                              missedToday: missedToday, canComplete: canComplete)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        // A small violet dot marks "scheduled, not yet due" — the one state the card
                        // has no other way to say.
                        if !isDueToday && !missedToday {
                            Circle().fill(TodoPalette.upcomingViolet).frame(width: 6, height: 6)
                        }
                        Text(item.title).font(.subheadline.weight(.semibold))
                            .strikethrough(completedToday)
                            .foregroundStyle(completedToday || missedToday ? Color.cvOnSurfaceVariant : Color.cvOnSurface)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if missedToday {
                            Text("Missed").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.cvError)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.cvError.opacity(0.14), in: Capsule())
                        }
                    }
                    if !item.details.isEmpty {
                        Text(item.details).font(.caption).lineLimit(1)
                            .foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                    Text(meta).font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                    // The state line: what the card is waiting for, and what the current state has
                    // already banked — a partial state is worth something and says so.
                    if item.behavior == .attempted && !completedToday {
                        Text(isAttempted
                             ? "State: Attempted ✓  ·  +\(Int(points.rounded())) pts"
                             : "State: Not started")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(isAttempted ? Color.cvPrimary : Color.cvOnSurfaceVariant)
                    } else if item.behavior == .time && !completedToday {
                        let target = item.targetDurationMinutes ?? 60
                        Text("Time: \(timeSpent)m / \(target)m  ·  +\(Int(points.rounded())) pts")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(timeSpent >= target ? Color.cvPrimary
                                             : timeSpent > 0 ? Color.cvPrimary : Color.cvOnSurfaceVariant)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if showActions {
                    Menu {
                        if !missedToday {
                            Button("Edit", systemImage: "pencil") { editing = item }
                        }
                        if item.behavior != .normal && !completedToday && !missedToday && !item.isDeleted {
                            Button(isAttempted ? "Mark Unattempted" : "Mark Attempted",
                                   systemImage: isAttempted ? "xmark" : "checkmark") { model.attempt(item) }
                        }
                        if item.behavior == .time && !completedToday && !missedToday && !item.isDeleted {
                            Button("+15 min", systemImage: "plus") { model.logTime(item, minutes: 15) }
                            Button("+30 min", systemImage: "plus") { model.logTime(item, minutes: 30) }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 34, height: 44)
                            .foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                    .accessibilityLabel("Options for \(item.title)")
                }
            }
            .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(completedToday ? Color.cvPrimary.opacity(0.07) : Color.cvSurfaceContainerHigh)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// The 44pt slot at the head of a card: the one control that fits the card's state.
    ///
    /// A closed strict window shows a red warning and no checkbox — that day is locked as missed and
    /// cannot be redone. Today's own list gets the real checkbox; anywhere else a completed todo is
    /// shown as a green tick and a scheduled one as a calendar, because a todo that is not
    /// actionable here must not offer to be completed.
    @ViewBuilder
    private func leadingMarker(
        item: TodoItem,
        isDueToday: Bool,
        completedToday: Bool,
        missedToday: Bool,
        canComplete: Bool
    ) -> some View {
        if missedToday {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 17))
                .foregroundStyle(Color.cvError)
                .frame(width: 44, height: 44)
        } else if model.filter == .today && isDueToday && (canComplete || completedToday) {
            Button { model.toggle(item) } label: {
                Image(systemName: completedToday ? "checkmark.square.fill" : "square")
                    .font(.title2)
                    .foregroundStyle(Color.cvPrimary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(completedToday ? "Uncomplete" : "Complete") \(item.title)")
        } else {
            Image(systemName: completedToday ? "checkmark.circle.fill" : "calendar")
                .font(.system(size: 17))
                .foregroundStyle(completedToday ? Color.cvPrimary : Color.cvOnSurfaceVariant.opacity(0.6))
                .frame(width: 44, height: 44)
        }
    }
}

/// Colours the Todo cards need beyond the shared palette.
enum TodoPalette {
    /// "Scheduled, not yet due" — the dot in front of a future todo's title.
    static let upcomingViolet = Color(red: 0.42, green: 0.30, blue: 0.78)
}
struct TodoEditor: View {
    @State var item: TodoItem
    var onSave: (TodoItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var initialized = false
    @State private var start = Date()
    @State private var end = Date()
    @State private var timeMode = "none"
    @State private var singleMinutes = 1200
    @State private var rangeStart = 540
    @State private var rangeEnd = 1020
    @State private var reminderMode = "notification"
    @State private var reminderTimes: [Int] = []
    @State private var reminderCount = 3
    @State private var repeats = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Your intention") {
                    TextField("Task name", text: $item.title).accessibilityIdentifier("todo.title")
                    TextField("Notes (optional)", text: $item.details, axis: .vertical).lineLimit(3...6)
                    Picker("Priority", selection: $item.priority) {
                        Text("Low").tag(TodoPriority.low)
                        Text("Normal").tag(TodoPriority.normal)
                        Text("High").tag(TodoPriority.high)
                    }
                    Picker("Behavior", selection: $item.behavior) {
                        Text("Checkbox").tag(TodoBehavior.normal)
                        Text("Attempted or complete").tag(TodoBehavior.attempted)
                        Text("Time tracking").tag(TodoBehavior.time)
                    }
                    if item.behavior == .time {
                        Stepper("Target: \(item.targetDurationMinutes ?? 30) minutes", value: Binding(get: { item.targetDurationMinutes ?? 30 }, set: { item.targetDurationMinutes = $0 }), in: 1...1440)
                    }
                }
                Section("Schedule") {
                    Picker("Repeat", selection: $item.type) {
                        Text("Temporary").tag(TodoType.temporary)
                        Text("Repeating").tag(TodoType.permanent)
                    }
                    DatePicker("Starts", selection: $start, displayedComponents: .date)
                    if item.type == .temporary {
                        DatePicker("Ends", selection: $end, in: start..., displayedComponents: .date)
                    } else {
                        ForEach(1...7, id: \.self) { weekday in
                            Toggle(TodoCalendar.weekdayName(weekday), isOn: Binding(get: {
                                item.scheduledDays?.contains(weekday) ?? true
                            }, set: { enabled in
                                var days = item.scheduledDays ?? Set(1...7)
                                if enabled { days.insert(weekday) } else { days.remove(weekday) }
                                item.scheduledDays = days
                            }))
                        }
                    }
                    Picker("Time", selection: $timeMode) {
                        Text("No time").tag("none")
                        Text("One time").tag("single")
                        Text("Time range").tag("range")
                    }
                    if timeMode == "single" { minutePicker("At", minutes: $singleMinutes) }
                    if timeMode == "range" {
                        minutePicker("From", minutes: $rangeStart)
                        minutePicker("Until", minutes: $rangeEnd)
                        Toggle("Strict interval", isOn: $item.strictInterval)
                        Text("Strict tasks can only be completed within this window. When the window ends, the missed day cannot be redone.").font(.footnote)
                    }
                }
                if timeMode != "none" {
                    Section("Reminders") {
                        Picker("Style", selection: $reminderMode) {
                            Text("Off").tag("off")
                            Text("Notification").tag("notification")
                            Text("Time-sensitive notification").tag("alarm")
                        }
                        if reminderMode != "off" {
                            Toggle("Remind on every scheduled day", isOn: $repeats)
                            if timeMode == "range" {
                                Stepper("Spread \(reminderCount) reminders", value: $reminderCount, in: 2...6)
                                Button("Spread across this interval") { spreadReminders() }
                                ForEach(reminderTimes.indices, id: \.self) { index in
                                    HStack {
                                        minutePicker("Reminder \(index + 1)", minutes: Binding(get: { reminderTimes.indices.contains(index) ? reminderTimes[index] : rangeStart }, set: { if reminderTimes.indices.contains(index) { reminderTimes[index] = $0 } }))
                                        Button(role: .destructive) { if reminderTimes.indices.contains(index) { reminderTimes.remove(at: index) } } label: { Image(systemName: "minus.circle") }
                                    }
                                }
                                Button("Add reminder time") { reminderTimes.append(rangeStart) }.disabled(reminderTimes.count >= 6)
                            }
                            Text("iOS delivers a notification with the system sound, not Android's continuous alarm. Time-sensitive delivery depends on your notification settings. Open ClearView periodically to refresh the queued reminders.").font(.footnote)
                        }
                    }
                }
            }.navigationTitle(item.title.isEmpty ? "New task" : "Edit task").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save(); dismiss() }.disabled(!valid)
                    }
                }
                .onAppear { initialize() }
        }.tint(.cvPrimary)
    }

    private var valid: Bool {
        !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (item.type != .permanent || item.scheduledDays?.isEmpty != true)
            && (timeMode != "range" || rangeEnd > rangeStart)
    }

    private func minutePicker(_ title: String, minutes: Binding<Int>) -> some View {
        DatePicker(title, selection: Binding(get: {
            Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            minutes.wrappedValue = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
        }), displayedComponents: .hourAndMinute)
    }

    private func initialize() {
        guard !initialized else { return }
        initialized = true
        start = Date(timeIntervalSince1970: Double(TodoCalendar.startOfDayMillis(epochDay: item.startDateEpochDay)) / 1000)
        end = Date(timeIntervalSince1970: Double(TodoCalendar.startOfDayMillis(epochDay: item.endDateEpochDay ?? item.startDateEpochDay)) / 1000)
        timeMode = item.timeStartMinutes != nil ? "range" : item.timeMinutes != nil ? "single" : "none"
        singleMinutes = item.timeMinutes ?? 1200
        rangeStart = item.timeStartMinutes ?? 540
        rangeEnd = item.timeEndMinutes ?? 1020
        reminderMode = item.reminder?.enabled == false ? "off" : item.reminder?.asAlarm == true ? "alarm" : "notification"
        reminderTimes = item.reminder?.timesMinutes ?? []
        repeats = item.reminder?.repeats ?? true
    }

    private func spreadReminders() {
        guard rangeEnd > rangeStart else { return }
        reminderTimes = (0..<reminderCount).map { rangeStart + (rangeEnd - rangeStart) * $0 / (reminderCount - 1) }
    }

    private func save() {
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.startDateEpochDay = TodoCalendar.epochDay(of: start)
        item.endDateEpochDay = item.type == .permanent ? nil : max(item.startDateEpochDay, TodoCalendar.epochDay(of: end))
        if item.type == .temporary { item.scheduledDays = nil }
        item.timeMinutes = timeMode == "single" ? singleMinutes : nil
        item.timeStartMinutes = timeMode == "range" ? rangeStart : nil
        item.timeEndMinutes = timeMode == "range" ? rangeEnd : nil
        if timeMode != "range" { item.strictInterval = false }
        if item.behavior == .time && item.targetDurationMinutes == nil { item.targetDurationMinutes = 30 }
        if timeMode == "none" {
            item.reminder = nil
        } else {
            if timeMode == "range" && reminderTimes.isEmpty { spreadReminders() }
            let times = timeMode == "single" ? [singleMinutes] : reminderTimes.filter { (rangeStart...rangeEnd).contains($0) }
            var reminder = item.reminder ?? ReminderConfig(timesMinutes: times, repeats: repeats)
            reminder.timesMinutes = ReminderConfig.normalized(times: times.isEmpty ? [rangeStart] : times)
            reminder.repeats = repeats
            reminder.enabled = reminderMode != "off"
            reminder.asAlarm = reminderMode == "alarm"
            item.reminder = reminder
        }
        onSave(item)
    }
}

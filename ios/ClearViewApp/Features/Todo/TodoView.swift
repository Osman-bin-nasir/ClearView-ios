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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showSearch { CVSearchField(text: $model.search, prompt: "Find a task") }
                if let message = reminders.message { CVErrorBanner(message: message) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach([TodoFilter.today, .upcoming, .completed], id: \.self) { filter in
                            CVChip(title: "\(filter.label) · \(TodoCodec.filter(model.items, filter: filter, today: model.today).count)",
                                   selected: model.filter == filter) { model.filter = filter }
                        }
                    }
                }
                CVSectionHeader(title: model.filter == .today ? "Today's todos" : model.filter.label,
                    subtitle: "Daily completed: \(model.completedToday) / \(model.dailyTarget) today's target")
                if model.visible.isEmpty {
                    CVEmptyState(title: model.search.isEmpty ? "A little room for a good habit" : "No matching tasks",
                        message: model.search.isEmpty ? "Tap + to plan something that matters to you." : "Try another search.", symbol: "checklist")
                }
                LazyVStack(spacing: 4) {
                    ForEach(model.visible) { item in taskRow(item) }
                }
                productivity
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
            .onAppear { model.refreshDay() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshDay() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in model.refreshDay() }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(Color.cvPrimary.opacity(0.15), lineWidth: 7)
                    Circle().trim(from: 0, to: weeklyProgress)
                        .stroke(Color.cvPrimary, style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(Int(weeklyProgress * 100))%").font(.headline.monospacedDigit())
                }.frame(width: 70, height: 70)
                VStack(alignment: .leading, spacing: 5) {
                    Text("This week").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    Text("\(weeklyCompleted) of \(weeklyScheduled) completed").font(.subheadline.bold())
                    Text("\(max(0, model.dueToday - model.completedToday)) left today").font(.caption).foregroundStyle(Color.cvPrimary)
                }
            }
        }
    }

    private func taskRow(_ item: TodoItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Button { model.toggle(item) } label: {
                    Image(systemName: item.completions[model.today] != nil ? "checkmark.square.fill" : "square")
                        .font(.title2).foregroundStyle(Color.cvPrimary).frame(minWidth: 32, minHeight: 40)
                }.buttonStyle(.plain).accessibilityLabel("Complete \(item.title)")
                    .disabled(item.completions[model.today] == nil && !TodoCodec.canCompleteOn(item, epochDay: model.today, nowMillis: TodoStoreClock.nowMillis()))
                Button { editing = item } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.subheadline.weight(.semibold)).strikethrough(item.completions[model.today] != nil)
                        if !item.details.isEmpty { Text(item.details).font(.caption).lineLimit(2).foregroundStyle(Color.cvOnSurfaceVariant) }
                        Text(TodoCodec.scheduleLabel(item, today: model.today)).font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                        if let time = TodoCodec.scheduledTimeLabel(item) {
                            Label(time, systemImage: "clock").font(.caption2).foregroundStyle(Color.cvPrimary)
                        }
                        if model.filter == .history {
                            Text("\(item.completions.count) completions recorded").font(.caption2).foregroundStyle(Color.cvPrimary)
                        }
                        if item.behavior == .attempted && TodoCodec.isAttemptedOn(item, epochDay: model.today) {
                            Label("Attempted today", systemImage: "circle.lefthalf.filled").font(.caption).foregroundStyle(Color.cvPrimary)
                        }
                        if item.behavior == .time {
                            Text("\(TodoCodec.timeSpentOn(item, epochDay: model.today)) / \(item.targetDurationMinutes ?? 30) minutes today")
                                .font(.caption).foregroundStyle(Color.cvPrimary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                Menu {
                    Button("Edit", systemImage: "pencil") { editing = item }
                    if item.behavior == .attempted && !item.isDeleted {
                        Button(TodoCodec.isAttemptedOn(item, epochDay: model.today) ? "Clear attempt" : "Mark attempted", systemImage: "circle.lefthalf.filled") { model.attempt(item) }
                    }
                    if item.behavior == .time && !item.isDeleted {
                        Button("Log time", systemImage: "clock") { loggedMinutes = 10; logging = item }
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
                } label: { Image(systemName: "ellipsis").frame(width: 30, height: 40) }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cvSurfaceContainerHigh, in: RoundedRectangle(cornerRadius: 10))
    }

    private var weekDays: [Int64] {
        let monday = model.today - Int64(TodoCalendar.weekday(epochDay: model.today) - 1)
        return (0..<7).map { monday + Int64($0) }
    }

    private var weeklyCompleted: Int {
        weekDays.reduce(0) { count, day in count + model.items.filter { $0.completions[day] != nil }.count }
    }

    private var weeklyScheduled: Int {
        weekDays.reduce(0) { count, day in count + model.items.filter { TodoCodec.isActiveOn($0, epochDay: day) }.count }
    }

    private var weeklyProgress: Double { min(1, Double(weeklyCompleted) / Double(max(1, weeklyScheduled))) }

    private var productivity: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Productivity").font(.headline)
                Spacer()
                Text("Weekly").font(.subheadline.bold()).foregroundStyle(Color.cvPrimary)
            }
            CVCard {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Weekly Insights & Statistics").font(.subheadline.bold())
                    summary
                    HStack {
                        Text("Weekly Progress").font(.caption.bold())
                        Spacer()
                        Text("\(Int(weeklyProgress * 100))%").font(.caption.bold()).foregroundStyle(Color.cvPrimary)
                    }
                    Chart(weekDays, id: \.self) { day in
                        let completed = model.items.filter { $0.completions[day] != nil }.count
                        BarMark(x: .value("Day", TodoCalendar.weekdayName(TodoCalendar.weekday(epochDay: day))), y: .value("Completed", completed))
                            .foregroundStyle(Color.cvPrimary).cornerRadius(4)
                    }.frame(height: 90).chartYAxis(.hidden)
                    ProgressView(value: weeklyProgress).tint(Color.cvPrimary)
                    HStack {
                        statistic("\(model.completedToday) / \(model.dailyTarget)", label: "Completed today")
                        statistic("\(weekDays.filter { day in model.items.contains { $0.completions[day] != nil } }.count) of 7", label: "Active days this week")
                    }
                    Text("\(model.items.reduce(0) { $0 + $1.completions.count }) tasks completed in total")
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }
            }
        }
    }

    private func statistic(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.subheadline.bold()).foregroundStyle(Color.cvPrimary)
            Text(label).font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cvSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 10))
    }
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

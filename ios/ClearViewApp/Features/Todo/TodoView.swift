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

    func refreshDay() { today = TodoCalendar.epochDay(of: Date()) }

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
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showSearch { CVSearchField(text: $model.search, prompt: "Find a task") }
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
            }
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
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                Menu {
                    Button("Edit", systemImage: "pencil") { editing = item }
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
    @State private var hasTime = false
    @State private var time = Date()
    @State private var start = Date()
    @State private var end = Date()

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
                }
                Section("Schedule") {
                    Picker("Repeat", selection: $item.type) {
                        Text("Temporary").tag(TodoType.temporary)
                        Text("Every day").tag(TodoType.permanent)
                    }
                    DatePicker("Starts", selection: $start, displayedComponents: .date)
                    if item.type == .temporary { DatePicker("Ends", selection: $end, in: start..., displayedComponents: .date) }
                    Toggle("Set a time", isOn: $hasTime)
                    if hasTime { DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute) }
                }
            }.navigationTitle(item.title.isEmpty ? "New task" : "Edit task").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
                            item.startDateEpochDay = TodoCalendar.epochDay(of: start)
                            item.endDateEpochDay = item.type == .permanent ? nil : max(item.startDateEpochDay, TodoCalendar.epochDay(of: end))
                            item.scheduledDays = nil
                            item.timeMinutes = hasTime ? Calendar.current.component(.hour, from: time) * 60 + Calendar.current.component(.minute, from: time) : nil
                            item.timeStartMinutes = nil
                            item.timeEndMinutes = nil
                            item.strictInterval = false
                            onSave(item)
                            dismiss()
                        }.disabled(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear {
                    start = Date(timeIntervalSince1970: Double(TodoCalendar.startOfDayMillis(epochDay: item.startDateEpochDay)) / 1000)
                    end = Date(timeIntervalSince1970: Double(TodoCalendar.startOfDayMillis(epochDay: item.endDateEpochDay ?? item.startDateEpochDay)) / 1000)
                    hasTime = item.timeMinutes != nil
                    if let minutes = item.timeMinutes {
                        time = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
                    }
                }
        }.tint(.cvPrimary)
    }
}

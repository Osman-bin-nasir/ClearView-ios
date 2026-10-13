import Foundation

/// A single Todo.
///
/// The Swift shape of the Android `TodoItem`, field for field, because everything
/// below it — the codec, the schedule rules, the statistics — is ported from there
/// and the two stores have to agree on what a todo *is*.
///
/// **Date model.** A todo is only ever *applicable* on its own required days: every
/// day of its `startDateEpochDay`…`endDateEpochDay` period for a temporary todo,
/// and every selected weekday for a permanent one (`scheduledDays`, 1 = Monday …
/// 7 = Sunday; nil = every day). A future todo is not applicable today: it cannot be
/// completed, must not count as missed, and must not affect today's score.
///
/// **Storage.** Dates are epoch days and times are minutes from midnight, so both
/// are timezone- and DST-safe. Completions are epoch day → completion instant, and
/// they are never pruned: weekly statistics depend on them, and the History tab's
/// "clear" hides cards rather than deleting data.
struct TodoItem: Identifiable, Equatable {
    var id: String
    var title: String
    var details: String = ""
    var type: TodoType = .temporary
    /// First day this todo is active (epoch day).
    var startDateEpochDay: Int64
    /// Last active day; nil = no end (the permanent shape).
    var endDateEpochDay: Int64?
    /// Repeat weekdays for permanent todos (1 = Monday … 7 = Sunday); nil = every day.
    var scheduledDays: Set<Int>?
    /// Optional scheduled time of day (minutes from midnight).
    var timeMinutes: Int?
    /// Optional scheduled time *range*, mutually exclusive with `timeMinutes`.
    var timeStartMinutes: Int?
    var timeEndMinutes: Int?
    /// Strict interval: with a start and end set, the todo can only be completed
    /// inside that window on an applicable day. When the window ends uncompleted the
    /// day is locked as missed and can never be completed afterwards ("can't redo").
    var strictInterval: Bool = false
    var reminder: ReminderConfig?
    var priority: TodoPriority = .normal
    var createdAtEpochMillis: Int64 = TodoStoreClock.nowMillis()
    var updatedAtEpochMillis: Int64 = TodoStoreClock.nowMillis()
    /// Completion history: epoch day → completed-at millis. Never pruned.
    var completions: [Int64: Int64] = [:]
    /// History-clear watermark for **missed** occurrences: days strictly before this
    /// are no longer listed. Nil = nothing cleared. The watermark is exclusive, so a
    /// clear on day X records X + 1 while days after it count normally.
    var missedClearedBefore: Int64?
    /// History-clear watermark for **completed** occurrences, kept deliberately
    /// separate from the completion data itself: clearing the History cards must not
    /// undo the completions, because today's count, the progress bar, the daily
    /// target and the weekly score all still count them.
    var completedClearedBefore: Int64?
    /// How the todo is checked off.
    var behavior: TodoBehavior = .normal
    /// For `.time`: the target duration, in minutes.
    var targetDurationMinutes: Int?
    /// Permanent history of modifications and daily state changes.
    var events: [TodoEvent] = []
    /// True when the todo was deleted but its history was preserved.
    var isDeleted: Bool = false

    /// Whether the todo repeats rather than occupying one period.
    var isPermanent: Bool { type == .permanent }

    /// Whether the todo has a single scheduled time.
    var hasSingleTime: Bool { timeMinutes != nil }

    /// Whether the todo has a time window rather than a time.
    var hasTimeRange: Bool { timeStartMinutes != nil && timeEndMinutes != nil }
}

/// A temporary todo leaves the active list after its period; a permanent one stays
/// until it is deleted.
enum TodoType: String, CaseIterable {
    case temporary = "TEMPORARY"
    case permanent = "PERMANENT"
}

/// The task behaviour, independent of its temporary/permanent persistence.
enum TodoBehavior: String, CaseIterable {
    /// A plain checkbox.
    case normal = "NORMAL"
    /// "Attempted" is a real state between not-started and done.
    case attempted = "ATTEMPTED"
    /// Time tracking: time is logged against the todo until the target is reached.
    case time = "TIME"
}

/// Priority: `weight` sorts the list (higher = more important), `scoreWeight` is the
/// multiplier inside the weekly score's priority-weighted completion component
/// (High 3×, Medium 2×, Low 1× — low still counts, it is never zero).
enum TodoPriority: String, CaseIterable {
    case low = "LOW"
    case normal = "NORMAL"
    case high = "HIGH"

    var weight: Int {
        switch self {
        case .low: return 0
        case .normal: return 1
        case .high: return 2
        }
    }

    var scoreWeight: Int {
        switch self {
        case .low: return 1
        case .normal: return 2
        case .high: return 3
        }
    }
}

/// Permanent historical events for a todo.
///
/// An enum with associated values rather than Android's sealed class: the same six
/// shapes, and the encoded form keeps Android's `type` names (`Created`, `Edited`,
/// `Attempted`, `Completed`, `Uncompleted`, `TimeAdded`) so the JSON stays readable
/// by both platforms.
enum TodoEvent: Equatable {
    /// The todo was created.
    case created(timestampMillis: Int64, title: String, timeMinutes: Int?, durationMinutes: Int?)
    /// The plan was edited.
    case edited(
        timestampMillis: Int64,
        oldTitle: String?,
        newTitle: String?,
        oldTimeMinutes: Int?,
        newTimeMinutes: Int?,
        oldDurationMinutes: Int?,
        newDurationMinutes: Int?
    )
    /// A day was marked attempted.
    case attempted(timestampMillis: Int64, epochDay: Int64)
    /// A day was completed.
    case completed(timestampMillis: Int64, epochDay: Int64)
    /// A completion was taken back.
    case uncompleted(timestampMillis: Int64, epochDay: Int64)
    /// Time was logged against a day.
    case timeAdded(timestampMillis: Int64, epochDay: Int64, addedMinutes: Int)

    var timestampMillis: Int64 {
        switch self {
        case .created(let ts, _, _, _): return ts
        case .edited(let ts, _, _, _, _, _, _): return ts
        case .attempted(let ts, _): return ts
        case .completed(let ts, _): return ts
        case .uncompleted(let ts, _): return ts
        case .timeAdded(let ts, _, _): return ts
        }
    }

    /// The day an occurrence event happened on, or nil for the plan-level events.
    var epochDay: Int64? {
        switch self {
        case .attempted(_, let day), .completed(_, let day),
             .uncompleted(_, let day), .timeAdded(_, let day, _):
            return day
        case .created, .edited:
            return nil
        }
    }

    /// The stored name, which is Android's class name.
    var typeName: String {
        switch self {
        case .created: return "Created"
        case .edited: return "Edited"
        case .attempted: return "Attempted"
        case .completed: return "Completed"
        case .uncompleted: return "Uncompleted"
        case .timeAdded: return "TimeAdded"
        }
    }
}

/// Reminder configuration: one or more reminder times of day (minutes from
/// midnight).
///
/// `repeat` fires the reminders on every active day (a recurring todo); otherwise
/// they fire on the first active day only. `enabled` is the per-todo off switch — a
/// reminder can keep its times while its alarms are switched off.
///
/// `asAlarm` chooses *how* it fires. On Android that is a real system alarm
/// (`AlarmManager.setAlarmClock`) instead of a notification; on iOS there is no
/// public API to set the system alarm clock, so an `.alarm` reminder becomes a
/// time-sensitive local notification and the field is kept so the intent survives a
/// move between the platforms (and so the iOS UI can be honest about the difference
/// rather than silently dropping the setting).
struct ReminderConfig: Equatable {
    var timesMinutes: [Int]
    /// True fires the reminders on every active day; false only on the first one.
    /// Named `repeats` in Swift because `repeat` is a keyword here; the stored JSON
    /// key stays `repeat`, which is what Android reads.
    var repeats: Bool
    var enabled: Bool = true
    var asAlarm: Bool = false
    /// How long an alarm-style reminder rings before going quiet, in minutes.
    var alarmMinutes: Int = ReminderConfig.defaultAlarmMinutes
    /// An audio file the reader picked off the device, as a persisted URL string —
    /// or nil for the system alarm sound.
    var alarmUri: String?

    /// The ring length used before it became a setting, in minutes.
    static let defaultAlarmMinutes = 1
    /// Offered ring lengths, in minutes — the editor's chips.
    static let alarmMinuteChoices = [1, 3, 5, 10, 15, 30]
    /// Longest ring a single alarm can run: a longer one is a mistake.
    static let maxAlarmMinutes = 60

    /// `alarmMinutes` as a duration, clamped to a sane window (1–60 minutes).
    ///
    /// The single place the ring length becomes a duration, so the notifier and
    /// anything that previews it agree — including for data written by a build that
    /// allowed a different range.
    var alarmDurationSeconds: TimeInterval {
        TimeInterval(min(max(alarmMinutes, 1), ReminderConfig.maxAlarmMinutes) * 60)
    }

    /// The reminder times, validated: minutes outside 0…1439 are dropped rather than
    /// allowed to become an invalid time, and at least one time is always present.
    static func normalized(times: [Int]) -> [Int] {
        let valid = times.filter { (0...1439).contains($0) }
        let unique = Array(Set(valid)).sorted()
        return unique.isEmpty ? [20 * 60] : unique
    }
}

/// The list filters offered by the Todo screen, in the order Android shows them.
enum TodoFilter: String, CaseIterable {
    case today = "TODAY"
    case upcoming = "UPCOMING"
    /// Everything actionable today that is already ticked off.
    case completed = "COMPLETED"
    case history = "HISTORY"
    case all = "ALL"
    case temporary = "TEMPORARY"
    case permanent = "PERMANENT"

    /// The label the filter chips show.
    var label: String {
        switch self {
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .completed: return "Completed"
        case .history: return "History"
        case .all: return "All"
        case .temporary: return "Temporary"
        case .permanent: return "Permanent"
        }
    }
}

/// The list sort orders offered by the Todo screen.
enum TodoSort: String, CaseIterable {
    case smart = "SMART"
    case time = "TIME"
    case priority = "PRIORITY"
    case created = "CREATED"
    case status = "STATUS"

    var label: String {
        switch self {
        case .smart: return "Smart"
        case .time: return "Time"
        case .priority: return "Priority"
        case .created: return "Created"
        case .status: return "Status"
        }
    }
}

/// The clock the model reads.
///
/// A seam rather than `Date()` scattered through the codec: every rule here is about
/// "now" (a window being open, a day having passed, a reminder being due), and a test
/// that cannot choose the time can only assert the rules that do not involve it.
enum TodoStoreClock {
    /// Epoch milliseconds, monotonic enough for these rules and matching Android's
    /// `System.currentTimeMillis()`.
    static func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

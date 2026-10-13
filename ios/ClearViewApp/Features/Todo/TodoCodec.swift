import Foundation

/// Pure Todo logic: JSON (de)serialisation, every mutation of a `[TodoItem]`,
/// active-day and archive rules, the strict-interval window, the filters and sort
/// orders, the history (completed vs missed occurrences) and the human-readable
/// labels.
///
/// The port of Android's `TodoCodec`, kept free of `UserDefaults` and of
/// `UserNotifications` for the same reason Android keeps its own free of `Context`:
/// the whole lifecycle — planning, completing, missing, editing, clearing history —
/// is unit-testable as a pure function of a list and a day, and the store and the
/// scheduler stay thin wrappers around what is decided here.
///
/// Two rules in here are load-bearing enough to state up front, because they are the
/// ones the Android code was fixed to have:
///
/// 1. **History is immutable.** A completion is kept forever, even after the plan is
///    edited or the todo deleted. Editing changes the *plan* and nothing else — the
///    old behaviour rewrote history and silently changed past scores and streaks.
/// 2. **Deleting is soft by default.** `removed` marks the todo deleted so its
///    completions still count towards streaks and the heatmap; discarding the history
///    is the separate, explicitly-named `removedWithHistory`.
enum TodoCodec {

    /// A fresh id. Android uses `UUID.randomUUID().toString()`; the Swift UUID has
    /// the same shape, so an id written by either platform is recognisable.
    static func newId() -> String { UUID().uuidString.lowercased() }

    // MARK: - Persistence

    /// JSON-encodes the list, in the order given.
    static func encode(_ items: [TodoItem]) -> String {
        let array: [[String: Any]] = items.map { item in
            var dictionary: [String: Any] = [
                "id": item.id,
                "title": item.title,
                "details": item.details,
                "type": item.type.rawValue,
                "start": item.startDateEpochDay,
                "end": orNull(item.endDateEpochDay),
                "days": orNull(item.scheduledDays.map { $0.sorted() }),
                "time": orNull(item.timeMinutes),
                "timeStart": orNull(item.timeStartMinutes),
                "timeEnd": orNull(item.timeEndMinutes),
                "priority": item.priority.rawValue,
                "interval": item.strictInterval,
                "createdAt": item.createdAtEpochMillis,
                "updatedAt": item.updatedAtEpochMillis,
                "missedCleared": orNull(item.missedClearedBefore),
                "completedCleared": orNull(item.completedClearedBefore),
                "behavior": item.behavior.rawValue,
                "targetDurationMinutes": orNull(item.targetDurationMinutes),
                "isDeleted": item.isDeleted,
            ]
            dictionary["reminder"] = item.reminder.map { reminder in
                [
                    "times": reminder.timesMinutes,
                    "repeat": reminder.repeats,
                    "enabled": reminder.enabled,
                    "asAlarm": reminder.asAlarm,
                    "alarmMinutes": reminder.alarmMinutes,
                    "alarmUri": orNull(reminder.alarmUri),
                ] as [String: Any]
            } ?? NSNull()
            // Completion days are object keys, as Android writes them, so the JSON is
            // a map from day to instant on both platforms.
            var completions: [String: Int64] = [:]
            for (day, at) in item.completions { completions[String(day)] = at }
            dictionary["completions"] = completions
            dictionary["events"] = item.events.map(encodeEvent)
            return dictionary
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return json
    }

    /// JSON-decodes the list. Empty on blank or corrupt input — a store that cannot be
    /// read is "no todos", which is a usable app, not a crash.
    static func decode(_ json: String?) -> [TodoItem] {
        guard let json, !json.trimmed.isEmpty, let data = json.data(using: .utf8) else { return [] }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return array.compactMap { element in
            guard let dictionary = element as? [String: Any] else { return nil }
            // A record with no id is not a todo: it could never be completed,
            // edited, or found again.
            guard let id = string(dictionary["id"]), !id.isBlank else { return nil }
            return decodeItem(id: id, dictionary: dictionary)
        }
    }

    /// Decodes one stored todo, filling in defaults for anything absent.
    ///
    /// Tolerant on purpose — Android's `optX` behaviour — because the alternative to
    /// a default is losing a todo. Times are validated on the way in (minutes outside
    /// 0…1439 are *dropped*, not wrapped) since they would otherwise be handed to a
    /// time formatter as an invalid time of day, and the reminder's ring length is
    /// clamped to the offered range.
    private static func decodeItem(id: String, dictionary: [String: Any]) -> TodoItem {
        TodoItem(
            id: id,
            title: string(dictionary["title"]) ?? "",
            details: string(dictionary["details"]) ?? "",
            type: TodoType(rawValue: string(dictionary["type"]) ?? "") ?? .temporary,
            startDateEpochDay: int64(dictionary["start"])
                ?? TodoCalendar.today(),
            endDateEpochDay: int64(dictionary["end"]),
            scheduledDays: days(dictionary["days"]),
            timeMinutes: minutes(dictionary["time"]),
            timeStartMinutes: minutes(dictionary["timeStart"]),
            timeEndMinutes: minutes(dictionary["timeEnd"]),
            strictInterval: bool(dictionary["interval"]) ?? false,
            reminder: reminder(dictionary["reminder"]),
            priority: TodoPriority(rawValue: string(dictionary["priority"]) ?? "") ?? .normal,
            createdAtEpochMillis: int64(dictionary["createdAt"]) ?? 0,
            updatedAtEpochMillis: int64(dictionary["updatedAt"]) ?? 0,
            completions: completions(dictionary["completions"]),
            missedClearedBefore: int64(dictionary["missedCleared"]),
            completedClearedBefore: int64(dictionary["completedCleared"]),
            behavior: behavior(dictionary),
            targetDurationMinutes: int(dictionary["targetDurationMinutes"])
                ?? int(dictionary["totalDuration"]),
            events: events(dictionary),
            isDeleted: bool(dictionary["isDeleted"]) ?? false
        )
    }

    // MARK: - Decoding helpers

    private static func encodeEvent(_ event: TodoEvent) -> [String: Any] {
        var dictionary: [String: Any] = [
            "type": event.typeName,
            "ts": event.timestampMillis,
        ]
        switch event {
        case .created(_, let title, let timeMinutes, let durationMinutes):
            dictionary["title"] = title
            dictionary["time"] = orNull(timeMinutes)
            dictionary["duration"] = orNull(durationMinutes)
        case .edited(_, let oldTitle, let newTitle, let oldTime, let newTime, let oldDuration, let newDuration):
            dictionary["oldTitle"] = orNull(oldTitle)
            dictionary["newTitle"] = orNull(newTitle)
            dictionary["oldTime"] = orNull(oldTime)
            dictionary["newTime"] = orNull(newTime)
            dictionary["oldDuration"] = orNull(oldDuration)
            dictionary["newDuration"] = orNull(newDuration)
        case .attempted(_, let epochDay), .completed(_, let epochDay), .uncompleted(_, let epochDay):
            dictionary["epochDay"] = epochDay
        case .timeAdded(_, let epochDay, let addedMinutes):
            dictionary["epochDay"] = epochDay
            dictionary["addedMinutes"] = addedMinutes
        }
        return dictionary
    }

    private static func events(_ dictionary: [String: Any]) -> [TodoEvent] {
        // `history` and `ev` are Android's older names for the same array and the same
        // field; read both so a store written by an older build keeps its record.
        let raw = dictionary["events"] as? [Any] ?? dictionary["history"] as? [Any] ?? []
        return raw.compactMap { element in
            guard let object = element as? [String: Any] else { return nil }
            let timestamp = int64(object["ts"]) ?? 0
            let name = string(object["type"]) ?? string(object["ev"]) ?? ""
            switch name {
            case "Created":
                return .created(
                    timestampMillis: timestamp,
                    title: string(object["title"]) ?? string(dictionary["title"]) ?? "",
                    timeMinutes: int(object["time"]),
                    durationMinutes: int(object["duration"])
                )
            case "Edited":
                return .edited(
                    timestampMillis: timestamp,
                    oldTitle: string(object["oldTitle"]),
                    newTitle: string(object["newTitle"]),
                    oldTimeMinutes: int(object["oldTime"]),
                    newTimeMinutes: int(object["newTime"]),
                    oldDurationMinutes: int(object["oldDuration"]),
                    newDurationMinutes: int(object["newDuration"])
                )
            case "Attempted":
                return .attempted(timestampMillis: timestamp, epochDay: int64(object["epochDay"]) ?? 0)
            case "Completed":
                return .completed(timestampMillis: timestamp, epochDay: int64(object["epochDay"]) ?? 0)
            case "Uncompleted":
                return .uncompleted(timestampMillis: timestamp, epochDay: int64(object["epochDay"]) ?? 0)
            case "TimeAdded":
                return .timeAdded(
                    timestampMillis: timestamp,
                    epochDay: int64(object["epochDay"]) ?? 0,
                    addedMinutes: int(object["addedMinutes"]) ?? 0
                )
            default:
                return nil
            }
        }
    }

    private static func reminder(_ value: Any?) -> ReminderConfig? {
        guard let object = value as? [String: Any] else { return nil }
        let times = (object["times"] as? [Any] ?? []).compactMap { int($0) }
        return ReminderConfig(
            timesMinutes: ReminderConfig.normalized(times: times),
            repeats: bool(object["repeat"]) ?? false,
            enabled: bool(object["enabled"]) ?? true,
            asAlarm: bool(object["asAlarm"]) ?? false,
            // Absent in data written before the ring length was a setting: the old
            // hardcoded minute is the honest answer.
            alarmMinutes: min(
                max(int(object["alarmMinutes"]) ?? ReminderConfig.defaultAlarmMinutes, 1),
                ReminderConfig.maxAlarmMinutes
            ),
            alarmUri: string(object["alarmUri"])?.nilIfBlank
        )
    }

    private static func behavior(_ dictionary: [String: Any]) -> TodoBehavior {
        // `kind` is the field's older name.
        let raw = string(dictionary["behavior"]) ?? string(dictionary["kind"]) ?? ""
        return TodoBehavior(rawValue: raw) ?? .normal
    }

    private static func days(_ value: Any?) -> Set<Int>? {
        guard let array = value as? [Any] else { return nil }
        let valid = Set(array.compactMap { int($0) }.filter { (1...7).contains($0) })
        return valid.isEmpty ? nil : valid
    }

    private static func minutes(_ value: Any?) -> Int? {
        guard let value = int(value), (0...1439).contains(value) else { return nil }
        return value
    }

    private static func completions(_ value: Any?) -> [Int64: Int64] {
        guard let object = value as? [String: Any] else { return [:] }
        var result: [Int64: Int64] = [:]
        for (key, raw) in object {
            guard let day = Int64(key), let at = int64(raw) else { continue }
            result[day] = at
        }
        return result
    }

    private static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? String
    }

    private static func int(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }

    private static func int64(_ value: Any?) -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.int64Value }
        return value as? Int64
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        return value as? Bool
    }

    /// A JSON-safe value: the wrapped value, or `NSNull` when it is absent.
    ///
    /// Generic over `T?` rather than taking `Any?` on purpose. Handing an `Int?` to an
    /// `Any?` parameter wraps the optional *inside* `Any`, so a nil arrives as a
    /// present `.some(Optional.none)` — which is not a valid `JSONSerialization`
    /// object, and would have made the whole encode fail and the list save as `[]`.
    /// Matching `T?` directly keeps nil meaning nil.
    private static func orNull<T>(_ value: T?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    // MARK: - Which days a todo applies on

    /// True when `item` is due on `day`: inside its period, and — for a permanent todo
    /// with selected weekdays — on one of them.
    static func isActiveOn(_ item: TodoItem, epochDay: Int64) -> Bool {
        if epochDay < item.startDateEpochDay { return false }
        if let end = item.endDateEpochDay, epochDay > end { return false }
        if item.type == .permanent, let days = item.scheduledDays {
            if !days.contains(TodoCalendar.weekday(epochDay: epochDay)) { return false }
        }
        return true
    }

    /// True when a todo is deleted, or a temporary todo's period has ended: it leaves
    /// the active list, while its history stays for statistics.
    static func isArchived(_ item: TodoItem, today: Int64) -> Bool {
        if item.isDeleted { return true }
        guard item.type == .temporary, let end = item.endDateEpochDay else { return false }
        return today > end
    }

    /// The non-archived todos — the working set for the active list.
    static func visibleItems(_ items: [TodoItem], today: Int64) -> [TodoItem] {
        items.filter { !isArchived($0, today: today) }
    }

    /// True when `item` has a completion recorded for `day`.
    static func completedOn(_ item: TodoItem, epochDay: Int64) -> Bool {
        item.completions[epochDay] != nil
    }

    /// True when `item` was marked attempted on `day` and is not completed — the two
    /// states are exclusive, so a completed todo never also reads as attempted.
    static func isAttemptedOn(_ item: TodoItem, epochDay: Int64) -> Bool {
        if completedOn(item, epochDay: epochDay) { return false }
        return attemptedEvents(item).contains { $0 == epochDay }
    }

    /// Total minutes logged against `item` on `day`.
    static func timeSpentOn(_ item: TodoItem, epochDay: Int64) -> Int {
        item.events.compactMap { event -> Int? in
            guard case .timeAdded(_, let day, let minutes) = event, day == epochDay else { return nil }
            return minutes
        }
        .reduce(0, +)
    }

    /// The day the todo is due, or nil when it is not due today.
    static func isDueToday(_ item: TodoItem, today: Int64) -> Bool {
        isActiveOn(item, epochDay: today)
    }

    /// When `item`'s reminder first comes due on `day`, or nil when it has none.
    ///
    /// Nil covers the three ways a todo declines to interrupt: no reminder
    /// configured, a reminder switched off, or one on a day the todo is not active.
    /// Callers listing reminders therefore get "nothing to say" rather than a
    /// midnight default that would look like one.
    static func reminderMomentMillis(_ item: TodoItem, epochDay: Int64) -> Int64? {
        guard let reminder = item.reminder, reminder.enabled else { return nil }
        guard isActiveOn(item, epochDay: epochDay) else { return nil }
        // A todo with a range reminds from the start of its window; one with a
        // reminder but no time at all reminds from the start of the day.
        let minutes = item.timeMinutes ?? item.timeStartMinutes
        if let minutes {
            return TodoCalendar.millis(epochDay: epochDay, minutes: minutes)
        }
        return TodoCalendar.startOfDayMillis(epochDay: epochDay)
    }

    // MARK: - Strict interval (the deadline window)

    /// Epoch millis of `day` at `minutes` past local midnight.
    static func dayTimeMillis(epochDay: Int64, minutes: Int) -> Int64 {
        TodoCalendar.millis(epochDay: epochDay, minutes: minutes)
    }

    /// True when `item` has a strict completion window.
    static func hasStrictInterval(_ item: TodoItem) -> Bool {
        item.strictInterval && item.timeStartMinutes != nil && item.timeEndMinutes != nil
    }

    /// True when the strict window on `day` has closed (`now` is past the end) — the
    /// day is locked as missed and can never be completed afterwards.
    static func intervalEnded(_ item: TodoItem, epochDay: Int64, nowMillis: Int64) -> Bool {
        guard hasStrictInterval(item), let end = item.timeEndMinutes else { return false }
        return nowMillis > dayTimeMillis(epochDay: epochDay, minutes: end)
    }

    /// True when the strict window on `day` is open. A todo with no window is always
    /// open: "no deadline" must not mean "never allowed".
    static func intervalOpen(_ item: TodoItem, epochDay: Int64, nowMillis: Int64) -> Bool {
        guard hasStrictInterval(item), let start = item.timeStartMinutes, let end = item.timeEndMinutes else {
            return true
        }
        return nowMillis >= dayTimeMillis(epochDay: epochDay, minutes: start)
            && nowMillis <= dayTimeMillis(epochDay: epochDay, minutes: end)
    }

    /// Whether `item` can be completed on `day` right now.
    static func canCompleteOn(_ item: TodoItem, epochDay: Int64, nowMillis: Int64) -> Bool {
        isActiveOn(item, epochDay: epochDay)
            && !completedOn(item, epochDay: epochDay)
            && intervalOpen(item, epochDay: epochDay, nowMillis: nowMillis)
    }

    /// Why a completion was refused.
    enum CompletionRefusal: String, Equatable {
        /// The day has not arrived yet.
        case futureDay = "FUTURE_DAY"
        /// The todo is not scheduled for that day at all.
        case notActiveDay = "NOT_ACTIVE_DAY"
        /// It is already ticked off for that day.
        case alreadyCompleted = "ALREADY_COMPLETED"
        /// A strict window that has already closed: locked as missed.
        case windowClosed = "WINDOW_CLOSED"

        /// The sentence the surface shows. In the app because the refusal exists so
        /// that the surfaces which *can* speak say which rule refused them, instead of
        /// a checkbox that silently does nothing.
        var message: String {
            switch self {
            case .futureDay: return "That day hasn’t arrived yet."
            case .notActiveDay: return "This isn’t scheduled for that day."
            case .alreadyCompleted: return "Already completed that day."
            case .windowClosed: return "The time window has closed — that day is missed."
            }
        }
    }

    /// Why `day` cannot be completed right now, or nil when it can.
    static func completionRefusal(
        _ item: TodoItem,
        epochDay: Int64,
        nowMillis: Int64,
        today: Int64 = TodoCalendar.today()
    ) -> CompletionRefusal? {
        if epochDay > today { return .futureDay }
        if !isActiveOn(item, epochDay: epochDay) { return .notActiveDay }
        if completedOn(item, epochDay: epochDay) { return .alreadyCompleted }
        if !intervalOpen(item, epochDay: epochDay, nowMillis: nowMillis) { return .windowClosed }
        return nil
    }

    /// Why a **reminder's** Complete action was refused, or nil when it can be.
    ///
    /// A reminder is the app's own alarm being answered, and it is answered for the
    /// occurrence it rang for — never for "today" standing in for it. Two rules follow,
    /// and both were bugs before they were rules:
    ///
    ///  - The strict-window lock that guards the in-app checkbox does **not** apply.
    ///    The reader set the reminder, was reminded, may have snoozed it, and is
    ///    answering it now; refusing because the window closed while they were being
    ///    reminded is a dead end. (Answering a long-missed day from the app stays
    ///    locked — that is a deliberate redo, not an answer to a reminder.)
    ///  - The completion lands on `epochDay`, the occurrence's own day, so a reminder
    ///    answered the next morning still completes the occurrence it belongs to.
    static func reminderCompletionRefusal(
        _ item: TodoItem,
        epochDay: Int64,
        today: Int64 = TodoCalendar.today()
    ) -> CompletionRefusal? {
        if epochDay > today { return .futureDay }
        if !isActiveOn(item, epochDay: epochDay) { return .notActiveDay }
        if completedOn(item, epochDay: epochDay) { return .alreadyCompleted }
        return nil
    }

    /// The next date strictly after `today` on which `item` is active, or nil when it
    /// never applies again. Used by the Upcoming grouping.
    static func nextActiveDate(_ item: TodoItem, today: Int64) -> Int64? {
        if let end = item.endDateEpochDay, end <= today { return nil }
        var day = today + 1
        let last = item.endDateEpochDay ?? (today + 400)
        while day <= last {
            if isActiveOn(item, epochDay: day) { return day }
            day += 1
        }
        return nil
    }

    // MARK: - Mutations

    /// Appends a new todo. The id is always fresh and completions start empty, so a
    /// caller cannot create a todo that is already half-completed.
    static func added(_ items: [TodoItem], item: TodoItem) -> [TodoItem] {
        var added = item
        added.id = item.id.isBlank ? newId() : item.id
        added.completions = [:]
        added.events = item.events + [
            .created(
                timestampMillis: TodoStoreClock.nowMillis(),
                title: item.title,
                timeMinutes: item.timeMinutes,
                durationMinutes: item.targetDurationMinutes
            ),
        ]
        return items + [added]
    }

    /// Replaces the todo's **plan**, keeping its history exactly.
    static func updated(_ items: [TodoItem], item: TodoItem) -> [TodoItem] {
        replacePlan(items, item: item)
    }

    /// Editing a completed or missed todo.
    ///
    /// The same operation as `updated`, and that is the point: editing changes the
    /// plan and never the record of what was done. The Android app used to clear the
    /// history here, which destroyed past scores; the two names remain because the
    /// screens call them from different places, and both now mean "plan edit".
    static func editedAsNew(_ items: [TodoItem], item: TodoItem) -> [TodoItem] {
        replacePlan(items, item: item)
    }

    private static func replacePlan(_ items: [TodoItem], item: TodoItem) -> [TodoItem] {
        items.map { existing in
            guard existing.id == item.id else { return existing }
            var updated = existing
            updated.title = item.title
            updated.details = item.details
            updated.type = item.type
            updated.startDateEpochDay = item.startDateEpochDay
            updated.endDateEpochDay = item.endDateEpochDay
            updated.scheduledDays = item.scheduledDays
            updated.timeMinutes = item.timeMinutes
            updated.timeStartMinutes = item.timeStartMinutes
            updated.timeEndMinutes = item.timeEndMinutes
            updated.reminder = item.reminder
            updated.priority = item.priority
            updated.strictInterval = item.strictInterval
            updated.behavior = item.behavior
            updated.targetDurationMinutes = item.targetDurationMinutes
            updated.isDeleted = item.isDeleted
            // History is preserved verbatim — never pruned by an edit.
            updated.events = existing.events
            updated.completions = existing.completions
            updated.updatedAtEpochMillis = TodoStoreClock.nowMillis()
            return updated
        }
    }

    /// Deletes the todo by **soft** deletion: it is marked deleted and stays in the
    /// store, so its completions, attempts, streaks, past scores and heatmap data
    /// remain intact. Active queries hide it; history and statistics keep counting it.
    static func removed(_ items: [TodoItem], id: String) -> [TodoItem] {
        items.map { item in
            guard item.id == id else { return item }
            var removed = item
            removed.isDeleted = true
            removed.updatedAtEpochMillis = TodoStoreClock.nowMillis()
            return removed
        }
    }

    /// Deletes `id` **together with its history**: the item leaves the store entirely,
    /// so its completions, attempts and logged time all disappear. The destructive
    /// counterpart of `removed`, and only ever called behind an explicit choice.
    static func removedWithHistory(_ items: [TodoItem], id: String) -> [TodoItem] {
        items.filter { $0.id != id }
    }

    /// Marks `id` completed on `day` — **strict**: a day already completed stays
    /// completed. Callers own the date rule (a todo can only be completed on a day it
    /// applies on, never a future day); the refusal reasons are above.
    static func completed(_ items: [TodoItem], id: String, epochDay: Int64, at: Int64) -> [TodoItem] {
        items.map { item in
            guard item.id == id else { return item }
            guard item.completions[epochDay] == nil else { return item }
            var completed = item
            completed.completions[epochDay] = at
            completed.events.append(.completed(timestampMillis: at, epochDay: epochDay))
            completed.updatedAtEpochMillis = at
            return completed
        }
    }

    /// Adds or removes the completion of `id` on `day` — the interactive toggle the
    /// Today checkboxes use. Returns the new list **and** whether it is now completed,
    /// so the caller can react (cancel that day's reminders, celebrate, or nothing).
    static func toggled(
        _ items: [TodoItem],
        id: String,
        epochDay: Int64,
        at: Int64
    ) -> (items: [TodoItem], completed: Bool) {
        var nowCompleted = false
        let updated = items.map { item -> TodoItem in
            guard item.id == id else { return item }
            var toggled = item
            if toggled.completions.removeValue(forKey: epochDay) != nil {
                nowCompleted = false
                toggled.events.append(.uncompleted(timestampMillis: at, epochDay: epochDay))
            } else {
                toggled.completions[epochDay] = at
                nowCompleted = true
                toggled.events.append(.completed(timestampMillis: at, epochDay: epochDay))
            }
            toggled.updatedAtEpochMillis = at
            return toggled
        }
        return (updated, nowCompleted)
    }

    /// Marks `id` attempted on `day`. Idempotent: a day already attempted is left
    /// untouched, so repeated taps cannot pile up duplicate events that the History
    /// and Attempted counts would each have to de-duplicate.
    static func attempted(_ items: [TodoItem], id: String, epochDay: Int64, at: Int64) -> [TodoItem] {
        items.map { item in
            guard item.id == id else { return item }
            guard !isAttemptedOn(item, epochDay: epochDay) else { return item }
            var attempted = item
            attempted.events.append(.attempted(timestampMillis: at, epochDay: epochDay))
            attempted.updatedAtEpochMillis = at
            return attempted
        }
    }

    /// Clears the attempted state of `id` on `day`. Every attempted event for that day
    /// is removed rather than appended to, so the occurrence really returns to
    /// untouched and the partial credit it earned leaves the score. Completions are
    /// untouched.
    static func unattempted(_ items: [TodoItem], id: String, epochDay: Int64, at: Int64) -> [TodoItem] {
        items.map { item in
            guard item.id == id else { return item }
            var cleared = item
            cleared.events = item.events.filter { event in
                if case .attempted(_, let day) = event { return day != epochDay }
                return true
            }
            cleared.updatedAtEpochMillis = at
            return cleared
        }
    }

    /// Logs `addedMinutes` against `id` on `day` (the `.time` behaviour).
    static func timeAdded(
        _ items: [TodoItem],
        id: String,
        epochDay: Int64,
        at: Int64,
        addedMinutes: Int
    ) -> [TodoItem] {
        items.map { item in
            guard item.id == id else { return item }
            var logged = item
            logged.events.append(
                .timeAdded(timestampMillis: at, epochDay: epochDay, addedMinutes: addedMinutes)
            )
            logged.updatedAtEpochMillis = at
            return logged
        }
    }

    // MARK: - Filters and sorts

    /// The rows a filter shows.
    ///
    /// History includes **archived** todos — it is the record of the past, not a view
    /// of the active list — and Today and Upcoming are disjoint by construction: a todo
    /// that is due today is never also upcoming.
    static func filter(
        _ items: [TodoItem],
        filter: TodoFilter,
        today: Int64,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> [TodoItem] {
        if filter == .history {
            return items.filter { hasHistory($0, today: today, nowMillis: nowMillis) }
        }
        let visible = visibleItems(items, today: today)
        switch filter {
        case .all:
            return visible
        case .today:
            return visible.filter { isActiveOn($0, epochDay: today) }
        case .upcoming:
            return visible.filter {
                !isActiveOn($0, epochDay: today) && nextActiveDate($0, today: today) != nil
            }
        case .temporary:
            return visible.filter { $0.type == .temporary }
        case .permanent:
            return visible.filter { $0.type == .permanent }
        case .completed:
            // Ticked-off todos that were due today. A todo completed on a day it is
            // not due is never shown here, and archived todos stay in History.
            return visible.filter {
                isActiveOn($0, epochDay: today) && completedOn($0, epochDay: today)
            }
        case .history:
            return []  // handled above
        }
    }

    /// The list in the requested order.
    ///
    /// Sorted stably, with the input position as the final tie-break: `sorted(by:)` in
    /// Swift is not stable, and two todos created in the same millisecond would
    /// otherwise swap places between redraws. Android's `sortedWith` is stable, so this
    /// is also what keeps both platforms showing the same order for the same list.
    static func sorted(_ items: [TodoItem], sort: TodoSort, today: Int64) -> [TodoItem] {
        stableSorted(items) { first, second in
            switch sort {
            case .smart:
                // Today's incomplete first, then by time, priority, creation. The
                // "actionable" flag is compared as an Int because Swift's Bool is not
                // `Comparable` — 0 sorts first, which is what "still to do" wants.
                let firstActionable = isActiveOn(first, epochDay: today) && !completedOn(first, epochDay: today) ? 0 : 1
                let secondActionable = isActiveOn(second, epochDay: today) && !completedOn(second, epochDay: today) ? 0 : 1
                if firstActionable != secondActionable { return firstActionable < secondActionable }
                return withinTimeThenPriorityThenCreation(first, second)
            case .time:
                if first.timeMinutes != second.timeMinutes {
                    return (first.timeMinutes ?? Int.max) < (second.timeMinutes ?? Int.max)
                }
                return first.title.lowercased() < second.title.lowercased()
            case .priority:
                if first.priority.weight != second.priority.weight {
                    return first.priority.weight > second.priority.weight
                }
                return withinTimeThenPriorityThenCreation(first, second)
            case .created:
                return first.createdAtEpochMillis < second.createdAtEpochMillis
            case .status:
                let firstDone = completedOn(first, epochDay: today) ? 1 : 0
                let secondDone = completedOn(second, epochDay: today) ? 1 : 0
                if firstDone != secondDone { return firstDone < secondDone }
                return withinTimeThenPriorityThenCreation(first, second)
            }
        }
    }

    /// Time, then priority, then creation — the tail the Smart, Priority and Status
    /// orders share, written once so the three cannot drift apart.
    private static func withinTimeThenPriorityThenCreation(_ first: TodoItem, _ second: TodoItem) -> Bool {
        let firstTime = first.timeMinutes ?? Int.max
        let secondTime = second.timeMinutes ?? Int.max
        if firstTime != secondTime { return firstTime < secondTime }
        if first.priority.weight != second.priority.weight {
            return first.priority.weight > second.priority.weight
        }
        return first.createdAtEpochMillis < second.createdAtEpochMillis
    }

    /// History entries, most recent occurrence first.
    static func historySorted(
        _ items: [TodoItem],
        today: Int64,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> [HistoryEntry] {
        historySortedEntries(items, today: today, nowMillis: nowMillis)
            .sorted { $0.lastOccurrence > $1.lastOccurrence }
    }

    /// One history row: an item with its past completed / missed counts.
    struct HistoryEntry: Equatable, Identifiable {
        let item: TodoItem
        let completedCount: Int
        let missedCount: Int
        let lastOccurrence: Int64
        /// Attempted occurrences (marked attempted, never completed).
        let attemptedCount: Int
        /// Total minutes logged against a `.time` todo.
        let totalMinutes: Int

        var id: String { item.id }
    }

    /// The completed and missed counts of `item`'s occurrences so far — every day up
    /// to and including `today` on which the todo was applicable.
    ///
    ///  - **Completed** counts a completion on its required day, today included:
    ///    completing a todo today appears in History immediately.
    ///  - **Missed** counts applicable days left uncompleted whose day has passed,
    ///    plus today for a strict-interval todo whose window has already closed — that
    ///    day is locked the moment the window ends. A normal todo today is still
    ///    actionable, so it is never counted as missed.
    ///
    /// The two clear watermarks hide days from this view **only**; the completion data
    /// itself is untouched, so today's count, the progress bar, the daily target and the
    /// weekly score keep counting a cleared day (see `TodoStats`).
    static func occurrenceCounts(
        _ item: TodoItem,
        today: Int64,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> (completed: Int, missed: Int) {
        var completed = 0
        var missed = 0
        let first = item.startDateEpochDay
        let last = min(item.endDateEpochDay ?? today, today)
        var day = first
        while day <= last {
            if isActiveOn(item, epochDay: day) {
                if completedOn(item, epochDay: day) {
                    if item.completedClearedBefore == nil || day >= item.completedClearedBefore! {
                        completed += 1
                    }
                } else if day < today || intervalEnded(item, epochDay: day, nowMillis: nowMillis) {
                    if item.missedClearedBefore == nil || day >= item.missedClearedBefore! {
                        missed += 1
                    }
                }
            }
            day += 1
        }
        return (completed, missed)
    }

    /// True when `item` has any history to show.
    ///
    /// Fast paths first (a completion, a strict window that closed today, an expired
    /// temporary), then a bounded scan for the remaining case: a permanent todo whose
    /// selected weekday is not today but which has past occurrences — at most six days
    /// apart, so the scan cannot run long.
    static func hasHistory(
        _ item: TodoItem,
        today: Int64,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> Bool {
        if item.completions.keys.contains(where: { day in
            day <= today && isActiveOn(item, epochDay: day)
                && (item.completedClearedBefore == nil || day >= item.completedClearedBefore!)
        }) {
            return true
        }
        if intervalEnded(item, epochDay: today, nowMillis: nowMillis)
            && isActiveOn(item, epochDay: today)
            && !completedOn(item, epochDay: today)
            && (item.missedClearedBefore == nil || today >= item.missedClearedBefore!) {
            return true
        }
        if item.startDateEpochDay >= today { return false }
        if item.type == .temporary, let end = item.endDateEpochDay, end < today,
           item.missedClearedBefore == nil || end >= item.missedClearedBefore! {
            return true
        }
        let last = min(item.endDateEpochDay ?? (today - 1), today - 1)
        var day = item.startDateEpochDay
        while day <= last {
            if isActiveOn(item, epochDay: day),
               item.missedClearedBefore == nil || day >= item.missedClearedBefore! {
                return true
            }
            day += 1
        }
        return false
    }

    /// One history row, with its behaviour aggregates.
    static func entry(
        _ item: TodoItem,
        today: Int64,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> HistoryEntry {
        let counts = occurrenceCounts(item, today: today, nowMillis: nowMillis)
        var attempted = 0
        var minutes = 0
        let last = min(item.endDateEpochDay ?? today, today)
        var day = item.startDateEpochDay
        while day <= last {
            if isActiveOn(item, epochDay: day) {
                minutes += timeSpentOn(item, epochDay: day)
                if isAttemptedOn(item, epochDay: day) { attempted += 1 }
            }
            day += 1
        }
        return HistoryEntry(
            item: item,
            completedCount: counts.completed,
            missedCount: counts.missed,
            lastOccurrence: lastOccurrence(item, today: today) ?? (today - 1),
            attemptedCount: attempted,
            totalMinutes: minutes
        )
    }

    /// The most recent occurrence of `item` up to and including `today`, or nil.
    static func lastOccurrence(_ item: TodoItem, today: Int64) -> Int64? {
        var day = min(item.endDateEpochDay ?? today, today)
        while day >= item.startDateEpochDay {
            if isActiveOn(item, epochDay: day) { return day }
            day -= 1
        }
        return nil
    }

    /// History entries with at least one completion required of them.
    static func historyCompleted(
        _ items: [TodoItem],
        today: Int64,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> [HistoryEntry] {
        historySorted(items, today: today, nowMillis: nowMillis).filter { $0.completedCount > 0 }
    }

    /// History entries with at least one required day that passed uncompleted.
    static func historyMissed(
        _ items: [TodoItem],
        today: Int64,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> [HistoryEntry] {
        historySorted(items, today: today, nowMillis: nowMillis).filter { $0.missedCount > 0 }
    }

    /// "Clear" on the Completed section: hides the completed cards from the History
    /// view **only**. The completion records are deliberately kept, because today's
    /// count, the progress bar, the daily target and the weekly score all read the
    /// completions directly. A cleared day can never resurface as missed either.
    static func removeCompletedHistory(
        _ items: [TodoItem],
        today: Int64,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> [TodoItem] {
        markCleared(
            items,
            ids: Set(historyCompleted(items, today: today, nowMillis: nowMillis).map(\.item.id)),
            today: today,
            completed: true
        )
    }

    /// "Clear" on the Incomplete section: hides the missed cards from the History view
    /// only — the todos and their schedules are untouched, and today's progress is
    /// unaffected. Days after the clear count normally.
    static func removeMissedHistory(
        _ items: [TodoItem],
        today: Int64,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> [TodoItem] {
        markCleared(
            items,
            ids: Set(historyMissed(items, today: today, nowMillis: nowMillis).map(\.item.id)),
            today: today,
            completed: false
        )
    }

    /// "Clear All": hides every History card from the History view. It never deletes
    /// todos and never touches completion data, so the History tab can look empty while
    /// the app still remembers everything for its calculations.
    static func clearHistory(
        _ items: [TodoItem],
        today: Int64,
        nowMillis: Int64 = TodoStoreClock.nowMillis()
    ) -> [TodoItem] {
        let ids = Set(items.filter { hasHistory($0, today: today, nowMillis: nowMillis) }.map(\.id))
        let clearedBefore = today + 1
        return items.map { item in
            guard ids.contains(item.id) else { return item }
            var cleared = item
            cleared.completedClearedBefore = clearedBefore
            cleared.missedClearedBefore = clearedBefore
            return cleared
        }
    }

    /// The **destructive** reset: every todo goes, so the feature returns to its
    /// fresh-install state and there is no watermark to set.
    ///
    /// The reminder bookkeeping that lives outside the items (scheduled notifications,
    /// pending snoozes) has to be cleared by the caller before this runs — a pure list
    /// function cannot reach the alarms.
    static func resetEverything() -> [TodoItem] { [] }

    // MARK: - Human-readable labels

    /// "Today", "Tomorrow", "Mon, Aug 10", "Every day", "Mon • Wed • Fri", or a range.
    ///
    /// A permanent todo is defined by the days it **repeats** on, never by the day it
    /// was created: when `scheduledDays` names the days, print them; when it is nil (or
    /// all seven) the todo is due every day and saying so is the honest label.
    static func scheduleLabel(_ item: TodoItem, today: Int64) -> String {
        let start = item.startDateEpochDay
        let startText: String
        if start == today {
            startText = "Today"
        } else if start == today + 1 {
            startText = "Tomorrow"
        } else {
            startText = "\(TodoCalendar.weekdayName(TodoCalendar.weekday(epochDay: start))), "
                + TodoCalendar.shortDateLabel(epochDay: start)
        }
        if item.type == .permanent {
            if let days = item.scheduledDays, days.count < 7 {
                return days.sorted().map { TodoCalendar.weekdayName($0) }.joined(separator: " • ")
            }
            return "Every day"
        }
        guard let end = item.endDateEpochDay else { return startText }
        if end == start { return startText }
        return "\(startText) – \(TodoCalendar.shortDateLabel(epochDay: end))"
    }

    /// "9:00 AM · 1:00 PM · 8:00 PM" for the reminder times, or nil when there are none.
    static func reminderLabel(_ item: TodoItem) -> String? {
        guard let reminder = item.reminder, !reminder.timesMinutes.isEmpty else { return nil }
        return reminder.timesMinutes.map { timeLabel($0) }.joined(separator: " · ")
    }

    /// "10:00 PM" for a minutes-of-day value. Never throws: a stored 1440 wraps to
    /// midnight rather than crashing the row that draws it.
    static func timeLabel(_ minutes: Int) -> String {
        TodoCalendar.timeLabel(minutes: minutes)
    }

    /// "2:08 PM" for an epoch-millis instant (snoozed reminder fire times).
    static func timeLabelFromMillis(_ millis: Int64) -> String {
        TodoCalendar.timeLabel(Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }

    /// "8:00 PM" for a single time, "9:00 AM – 8:00 PM" for a range, nil when the todo
    /// has no scheduled time.
    static func scheduledTimeLabel(_ item: TodoItem) -> String? {
        if let minutes = item.timeMinutes { return timeLabel(minutes) }
        guard let start = item.timeStartMinutes, let end = item.timeEndMinutes else { return nil }
        return "\(timeLabel(start)) – \(timeLabel(end))"
    }

    /// `count` times spread evenly across `startMinutes`…`endMinutes` inclusive,
    /// rounded to whole minutes.
    ///
    /// Both endpoints are included when `count > 1`, and duplicates collapse — so a
    /// short range yields fewer distinct times rather than a list that repeats itself.
    /// This is how a todo with a 9:00–20:00 window gets, say, three spread reminders.
    static func rangeTimes(startMinutes: Int, endMinutes: Int, count: Int) -> [Int] {
        let n = max(count, 1)
        let span = max(endMinutes - startMinutes, 0)
        if n == 1 || span == 0 { return [startMinutes] }
        var times: [Int] = []
        for index in 0..<n {
            let minutes = startMinutes + Int((Double(index) * Double(span) / Double(n - 1)).rounded())
            let clamped = min(max(minutes, 0), 1439)
            if !times.contains(clamped) { times.append(clamped) }
        }
        return times
    }

    // MARK: - Private helpers

    private static func attemptedEvents(_ item: TodoItem) -> [Int64] {
        item.events.compactMap { event in
            if case .attempted(_, let day) = event { return day }
            return nil
        }
    }

    private static func historySortedEntries(
        _ items: [TodoItem],
        today: Int64,
        nowMillis: Int64
    ) -> [HistoryEntry] {
        items.filter { hasHistory($0, today: today, nowMillis: nowMillis) }
            .map { entry($0, today: today, nowMillis: nowMillis) }
    }

    private static func markCleared(
        _ items: [TodoItem],
        ids: Set<String>,
        today: Int64,
        completed: Bool
    ) -> [TodoItem] {
        let clearedBefore = today + 1
        return items.map { item in
            guard ids.contains(item.id) else { return item }
            var cleared = item
            if completed {
                cleared.completedClearedBefore = clearedBefore
            } else {
                cleared.missedClearedBefore = clearedBefore
            }
            return cleared
        }
    }

    /// `sorted(by:)`, but ties keep their input order.
    private static func stableSorted(_ items: [TodoItem], by areInIncreasingOrder: (TodoItem, TodoItem) -> Bool) -> [TodoItem] {
        items.enumerated()
            .sorted { first, second in
                if areInIncreasingOrder(first.element, second.element) { return true }
                if areInIncreasingOrder(second.element, first.element) { return false }
                return first.offset < second.offset
            }
            .map(\.element)
    }
}

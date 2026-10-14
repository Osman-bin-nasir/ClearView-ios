import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class TodoReminderScheduler {
    static let shared = TodoReminderScheduler()
    static let prefix = "clearview.todo."
    var message: String?
    var scheduledCount = 0
    private var generation = 0
    private var updating = false
    private var refreshRequested = false

    func refresh() async {
        refreshRequested = true
        guard !updating else { return }
        updating = true
        defer { updating = false }
        while refreshRequested {
            refreshRequested = false
            await rebuild()
        }
    }

    private func rebuild() async {
        generation += 1
        let requestGeneration = generation
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard generation == requestGeneration else { return }
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix(Self.prefix) }.map(\.identifier))
        scheduledCount = 0
        message = nil
        let store = TodoStore()
        guard store.notificationsEnabled else { return }
        let today = TodoCalendar.epochDay(of: Date())
        let now = Date()
        var occurrences: [(Date, TodoItem)] = []
        for item in store.items where !item.isDeleted {
            guard let reminder = item.reminder, reminder.enabled else { continue }
            let firstActive = (0..<7).map { item.startDateEpochDay + Int64($0) }
                .first { TodoCodec.isActiveOn(item, epochDay: $0) }
            for offset in 0..<90 {
                let day = today + Int64(offset)
                guard TodoCodec.isActiveOn(item, epochDay: day), item.completions[day] == nil,
                      reminder.repeats || day == firstActive else { continue }
                for minutes in ReminderConfig.normalized(times: reminder.timesMinutes) {
                    let midnight = Date(timeIntervalSince1970: Double(TodoCalendar.startOfDayMillis(epochDay: day)) / 1000)
                    guard let date = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: midnight) else { continue }
                    if date > now { occurrences.append((date, item)) }
                }
            }
        }
        guard !occurrences.isEmpty else { return }
        do {
            let allowed = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            guard generation == requestGeneration else { return }
            guard allowed else { message = "Task notifications are off. Allow notifications for ClearView in Settings."; return }
            let settings = await center.notificationSettings()
            guard generation == requestGeneration else { return }
            let otherCount = pending.filter { !$0.identifier.hasPrefix(Self.prefix) }.count
            let capacity = min(48, max(0, 60 - otherCount))
            for (date, item) in occurrences.sorted(by: { $0.0 < $1.0 }).prefix(capacity) {
                guard generation == requestGeneration else { return }
                let day = TodoCalendar.epochDay(of: date)
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.details.isEmpty ? "A reminder for your intention today." : item.details
                content.sound = .default
                content.categoryIdentifier = "clearview.todo"
                content.userInfo = ["todoID": item.id, "epochDay": day]
                if item.reminder?.asAlarm == true && settings.timeSensitiveSetting == .enabled {
                    content.interruptionLevel = .timeSensitive
                }
                let trigger = UNCalendarNotificationTrigger(dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date), repeats: false)
                let identifier = "\(Self.prefix)\(item.id).\(Int64(date.timeIntervalSince1970))"
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
                scheduledCount += 1
            }
            if capacity == 0 { message = "The notification queue is full. Open ClearView later to refresh reminders." }
        } catch {
            if generation == requestGeneration { message = "Some task reminders could not be scheduled: \(error.localizedDescription)" }
        }
    }
}

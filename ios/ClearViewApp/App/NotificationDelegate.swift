import UIKit
import UserNotifications

final class NotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let complete = UNNotificationAction(identifier: "clearview.todo.complete", title: "Complete", options: [.authenticationRequired])
        center.setNotificationCategories([UNNotificationCategory(identifier: "clearview.todo", actions: [complete], intentIdentifiers: [])])
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == "clearview.todo.complete",
              let identifier = response.notification.request.content.userInfo["todoID"] as? String,
              let day = response.notification.request.content.userInfo["epochDay"] as? NSNumber else { return }
        await MainActor.run {
            let store = TodoStore()
            let items = store.items
            let today = TodoCalendar.epochDay(of: Date())
            if day.int64Value == today,
               let item = items.first(where: { $0.id == identifier && !$0.isDeleted }),
               TodoCodec.canCompleteOn(item, epochDay: today, nowMillis: TodoStoreClock.nowMillis()) {
                store.saveItems(TodoCodec.completed(items, id: identifier, epochDay: today, at: TodoStoreClock.nowMillis()))
            }
        }
        await TodoReminderScheduler.shared.refresh()
    }
}

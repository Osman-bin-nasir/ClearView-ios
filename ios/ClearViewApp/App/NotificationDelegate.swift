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
        await Self.refreshSavedContent()
        return [.banner, .list, .sound]
    }

    /// A notification is the moment the app is told that something changed, so it is the moment to
    /// bring the saved tab up to date: this is the client half of Android's update pass, run on the
    /// news rather than on a fifteen-minute timer.
    ///
    /// It reads, it does not display — the notification itself is already built by the time this
    /// runs — and a failure is deliberately silent: the next open fetches the same thing anyway,
    /// and a refresh nobody asked for must not be able to produce an error nobody can dismiss.
    nonisolated static func refreshSavedContent() async {
        await GoodPostRepository().refreshSavedContent()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        // Tapped (or dismissed): the reader is on the way into the app, and the tab is about to be
        // opened. Whether the notification was a Todo or a channel update is not this decision's
        // business — the pass is idempotent and bounded.
        await Self.refreshSavedContent()
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

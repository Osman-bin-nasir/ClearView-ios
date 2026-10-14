import Foundation
import Observation
import FamilyControls
import DeviceActivity
import ManagedSettings
import LocalAuthentication
import UserNotifications

@MainActor
@Observable
final class DeviceControlsController {
    static let shared = DeviceControlsController()
    static let monitorName = DeviceActivityName("clearview.focus")
    var state = DeviceControlState.load()
    var authorized = AuthorizationCenter.shared.authorizationStatus == .approved
    var message: String?
    var busy = false
    var expired = false

    var groupAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: DeviceControlState.groupID) != nil
    }

    func authorize() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            guard groupAvailable else { throw ControlError.configuration }
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            refresh()
            message = authorized ? nil : "Screen Time permission was not granted."
        } catch {
            message = "Screen Time could not be enabled: \(error.localizedDescription)"
        }
    }

    func refresh() {
        state = DeviceControlState.load()
        let legacyDeadline = UserDefaults.standard.double(forKey: "focus.end")
        if legacyDeadline > 0 {
            if state.focusDeadline == nil && legacyDeadline > Date().timeIntervalSince1970 {
                state.focusDeadline = Date(timeIntervalSince1970: legacyDeadline)
                state.focusRestrictsApps = false
                state.save()
            }
            UserDefaults.standard.removeObject(forKey: "focus.end")
        }
        authorized = AuthorizationCenter.shared.authorizationStatus == .approved
        if authorized { state.apply() }
        else { ManagedSettingsStore(named: DeviceControlState.storeName).clearAllSettings() }
        expired = state.focusExpired
    }

    func refreshExpiry() {
        if expired != state.focusExpired { refresh() }
    }

    func setSelection(_ selection: FamilyActivitySelection) {
        guard !state.protectionEnabled || !state.shieldSelection || !ProtectionModel.shared.isLocked else {
            message = "Unlock Protection before changing its blocked apps."
            return
        }
        state.selection = selection
        persist()
    }

    func setShield(_ enabled: Bool) {
        guard !ProtectionModel.shared.isLocked else { message = "Unlock Protection first."; return }
        guard !enabled || (authorized && state.hasSelection) else {
            message = "Allow Screen Time and select apps or categories first."
            return
        }
        state.shieldSelection = enabled
        persist()
    }

    func setWebFiltering(_ enabled: Bool) {
        guard !ProtectionModel.shared.isLocked else { message = "Unlock Protection first."; return }
        guard !enabled || authorized else { message = "Allow Screen Time first."; return }
        state.filterAdultWebsites = enabled
        persist()
    }

    func syncProtection(enabled: Bool, domains: [String]) {
        guard state.protectionEnabled != enabled || state.blockedDomains != domains else { return }
        state.protectionEnabled = enabled
        state.blockedDomains = domains
        persist()
    }

    func start(seconds: Int, restrictApps: Bool) async -> Bool {
        guard !busy, (1...86_400).contains(seconds) else { return false }
        guard state.focusDeadline == nil else { message = "Finish the current phone limit first."; return false }
        guard !restrictApps || groupAvailable else { message = ControlError.configuration.localizedDescription; return false }
        guard !restrictApps || (authorized && state.hasSelection) else {
            message = "Allow Screen Time and choose the apps to block before starting."
            return false
        }
        busy = true
        defer { busy = false }
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        var pending = state
        pending.focusDeadline = deadline
        pending.focusRestrictsApps = restrictApps
        pending.timerSelection = state.selection
        let previous = state
        DeviceActivityCenter().stopMonitoring([Self.monitorName])
        pending.save()
        if restrictApps {
            let calendar = Calendar.current
            let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
            let schedule = DeviceActivitySchedule(
                intervalStart: calendar.dateComponents(fields, from: deadline),
                intervalEnd: calendar.dateComponents(fields, from: deadline.addingTimeInterval(20 * 60)),
                repeats: false)
            do { try DeviceActivityCenter().startMonitoring(Self.monitorName, during: schedule) }
            catch {
                previous.save()
                message = "The background limit could not be scheduled: \(error.localizedDescription)"
                return false
            }
        }
        state = pending
        expired = false
        message = nil
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["clearview.focus"])
        do {
            let allowed = try await center.requestAuthorization(options: [.alert, .sound])
            guard state.focusDeadline == deadline else { return true }
            if allowed {
                let content = UNMutableNotificationContent()
                content.title = "Your phone limit is up"
                content.body = restrictApps ? "Your selected apps are now restricted. Open ClearView to unlock." : "Open ClearView to finish your focus session."
                content.sound = .default
                content.userInfo = ["destination": "focus"]
                try await center.add(UNNotificationRequest(identifier: "clearview.focus", content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, deadline.timeIntervalSinceNow), repeats: false)))
            } else { message = "Countdown started. Notifications are disabled in iOS Settings." }
        } catch { message = "Countdown started, but its notification could not be scheduled: \(error.localizedDescription)" }
        return true
    }

    func endEarly() {
        guard !state.focusExpired else { refresh(); return }
        cancel()
    }

    private func cancel() {
        DeviceActivityCenter().stopMonitoring([Self.monitorName])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["clearview.focus"])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["clearview.focus"])
        state.focusDeadline = nil
        state.focusRestrictsApps = false
        expired = false
        persist()
    }

    func unlock() async {
        do {
            let context = LAContext()
            let approved = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your ClearView phone limit")
            if approved { cancel() }
        } catch { message = "Could not unlock: \(error.localizedDescription)" }
    }

    private func persist() {
        state.save()
        if authorized { state.apply() }
        message = nil
    }

    enum ControlError: LocalizedError {
        case configuration
        var errorDescription: String? {
            "This build needs the ClearView App Group and Family Controls entitlements. Select a development team for both app and monitor targets in Xcode."
        }
    }
}

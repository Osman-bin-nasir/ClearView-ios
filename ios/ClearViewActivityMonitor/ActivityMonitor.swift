import DeviceActivity
import FamilyControls

final class ActivityMonitor: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        guard activity.rawValue == "clearview.focus" else { return }
        enforce()
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        guard activity.rawValue == "clearview.focus" else { return }
        enforce()
    }

    private func enforce() {
        guard AuthorizationCenter.shared.authorizationStatus == .approved else { return }
        DeviceControlState.load().apply()
    }
}

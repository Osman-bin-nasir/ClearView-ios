import SwiftUI
import UserNotifications

struct FocusTimerView: View {
    @AppStorage("focus.end") private var endTimestamp = 0.0
    @AppStorage("focus.duration") private var duration = 25
    @State private var notificationNote: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int(ceil(endTimestamp - context.date.timeIntervalSince1970)))
            let active = remaining > 0
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(active ? "Phone limit is running" : "Set a countdown").font(.headline)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: "%02d:%02d", active ? remaining / 60 : duration, active ? remaining % 60 : 0))
                            .font(.system(size: 48, weight: .bold, design: .monospaced)).foregroundStyle(Color.cvPrimary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(active ? "Time remaining" : "Minutes : seconds").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.cvSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 16))
                    if !active {
                        Text("Duration").font(.subheadline.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach([5, 15, 25, 45], id: \.self) { minutes in
                                    CVChip(title: "\(minutes)m", selected: duration == minutes) { duration = minutes }
                                }
                            }
                        }
                        Stepper("\(duration) minutes", value: $duration, in: 1...180, step: 1)
                    }
                    Button(active ? "End session" : "Start focus session") {
                        if active {
                            endTimestamp = 0
                            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["clearview.focus"])
                        } else { Task { await start() } }
                    }.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity, alignment: .trailing)
                    Text("A gentle reminder when your time is up. This timer doesn't lock your phone or block other apps.")
                        .font(.footnote).foregroundStyle(Color.cvOnSurfaceVariant)
                    if let notificationNote { CVErrorBanner(message: notificationNote) }
                }.padding(20)
            }.background(Color.cvBackground)
        }.navigationTitle("Set Phone Limit").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }

    private func start() async {
        endTimestamp = Date().timeIntervalSince1970 + Double(duration * 60)
        let scheduledEnd = endTimestamp
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                notificationNote = "Notifications are off. Your timer still runs here."
                return
            }
            guard endTimestamp == scheduledEnd else { return }
            let content = UNMutableNotificationContent()
            content.title = "A moment well spent"
            content.body = "Your ClearView focus session is complete."
            content.sound = .default
            let remaining = max(1, endTimestamp - Date().timeIntervalSince1970)
            try await center.add(UNNotificationRequest(identifier: "clearview.focus", content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: remaining, repeats: false)))
            notificationNote = nil
        } catch { notificationNote = "Your timer is running, but its notification couldn't be scheduled." }
    }
}

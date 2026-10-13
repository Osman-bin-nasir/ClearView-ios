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
                VStack(spacing: 32) {
                    Image(systemName: "leaf").font(.system(size: 42, weight: .light)).foregroundStyle(Color.cvPrimary)
                    Text(active ? "A little space to focus." : endTimestamp > 0 ? "A moment well spent." : "Choose your moment.")
                        .font(.title2.bold()).multilineTextAlignment(.center)
                    ZStack {
                        Circle().stroke(Color.cvSurfaceContainerHigh, lineWidth: 10)
                        Circle().trim(from: 0, to: active ? min(1, Double(remaining) / Double(duration * 60)) : 1)
                            .stroke(Color.cvPrimary, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90))
                        Text(String(format: "%02d:%02d", active ? remaining / 60 : duration, active ? remaining % 60 : 0))
                            .font(.system(size: 64, weight: .light, design: .rounded)).monospacedDigit()
                    }.frame(width: 260, height: 260)
                    if !active {
                        HStack {
                            ForEach([5, 15, 25, 45], id: \.self) { minutes in
                                CVChip(title: "\(minutes)m", selected: duration == minutes) { duration = minutes }
                            }
                        }
                        Stepper("\(duration) minutes", value: $duration, in: 1...180, step: 1)
                    }
                    Button(active ? "End session" : "Start focus session") {
                        if active {
                            endTimestamp = 0
                            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["clearview.focus"])
                        } else { Task { await start() } }
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Text("A gentle reminder when your time is up. This timer doesn't lock your phone or block other apps.")
                        .font(.footnote).foregroundStyle(Color.cvOnSurfaceVariant).multilineTextAlignment(.center)
                    if let notificationNote { CVErrorBanner(message: notificationNote) }
                }.padding(24).padding(.top, 24)
            }.background(Color.cvBackground)
        }.navigationTitle("Set Phone Limit").navigationBarTitleDisplayMode(.inline)
    }

    private func start() async {
        endTimestamp = Date().timeIntervalSince1970 + Double(duration * 60)
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                notificationNote = "Notifications are off. Your timer still runs here."
                return
            }
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

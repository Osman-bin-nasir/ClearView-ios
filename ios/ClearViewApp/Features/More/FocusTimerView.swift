import SwiftUI

struct FocusTimerView: View {
    @State private var controls = DeviceControlsController.shared
    @State private var hours = 0
    @State private var minutes = 25
    @State private var seconds = 0
    @State private var restrictApps = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if controls.expired {
                    FocusExpiredView()
                } else if let deadline = controls.state.focusDeadline {
                    Text("Phone limit is running").font(.headline)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = max(0, Int(ceil(deadline.timeIntervalSince(context.date))))
                        Text(String(format: "%02d:%02d:%02d", remaining / 3600, remaining / 60 % 60, remaining % 60))
                            .font(.system(size: 48, weight: .bold, design: .monospaced)).foregroundStyle(Color.cvPrimary)
                            .minimumScaleFactor(0.5).lineLimit(1)
                    }
                    Text(controls.state.focusRestrictsApps ? "Selected apps will be restricted when the countdown ends." : "ClearView will pause when the countdown ends.")
                    Button("End session") { controls.endEarly() }.buttonStyle(.bordered)
                } else {
                    Text("Set a countdown").font(.headline)
                    HStack {
                        durationPicker("Hours", value: $hours, range: 0..<24)
                        durationPicker("Minutes", value: $minutes, range: 0..<60)
                        durationPicker("Seconds", value: $seconds, range: 0..<60)
                    }
                    HStack {
                        ForEach([5, 15, 25, 45], id: \.self) { duration in
                            CVChip(title: "\(duration)m", selected: hours == 0 && minutes == duration && seconds == 0) {
                                hours = 0; minutes = duration; seconds = 0
                            }
                        }
                    }
                    Toggle("Restrict selected apps at expiry", isOn: $restrictApps)
                    if restrictApps { DeviceControlsViewContent() }
                    Text("ClearView pauses at expiry. Blocking other apps requires Screen Time permission and a signed device build. iOS decides when background monitoring runs; this does not lock your entire phone.")
                        .font(.footnote).foregroundStyle(Color.cvOnSurfaceVariant)
                    Button("Start phone limit") {
                        Task { _ = await controls.start(seconds: hours * 3600 + minutes * 60 + seconds, restrictApps: restrictApps) }
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(controls.busy || hours * 3600 + minutes * 60 + seconds == 0)
                }
                if let message = controls.message { CVErrorBanner(message: message) }
            }.padding(20)
        }.background(Color.cvBackground).navigationTitle("Set Phone Limit").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task {
                controls.refresh()
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    controls.refreshExpiry()
                }
            }
    }

    private func durationPicker(_ label: String, value: Binding<Int>, range: Range<Int>) -> some View {
        VStack {
            Text(label).font(.caption)
            Picker(label, selection: value) {
                ForEach(range, id: \.self) { Text(String(format: "%02d", $0)).tag($0) }
            }.pickerStyle(.wheel).frame(maxWidth: .infinity).clipped()
        }
    }
}

struct FocusExpiredView: View {
    @State private var controls = DeviceControlsController.shared

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "hourglass.bottomhalf.filled").font(.system(size: 54)).foregroundStyle(Color.cvPrimary)
            Text("Your phone limit is up").font(.title2.bold())
            Text("Take a break. Authenticate with your device passcode or biometrics to end this session and remove its restrictions.")
                .multilineTextAlignment(.center).foregroundStyle(Color.cvOnSurfaceVariant)
            Button("Unlock") { Task { await controls.unlock() } }.buttonStyle(.borderedProminent).controlSize(.large)
            if let message = controls.message { CVErrorBanner(message: message) }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.cvBackground)
            .interactiveDismissDisabled()
    }
}

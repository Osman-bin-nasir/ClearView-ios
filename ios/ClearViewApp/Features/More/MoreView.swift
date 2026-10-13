import SwiftUI

struct MoreView: View {
    @AppStorage("appearance") private var appearance = "dark"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("A little more intention.").font(.title2.bold())
                        Text("Small tools for a more mindful day.")
                            .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                    }.padding(.top, 8)
                    VStack(spacing: 12) {
                        CVSectionHeader(title: "Your daily tools")
                        NavigationLink { TodoView() } label: {
                            tool("Todo", detail: "Plan, remember, and complete your tasks", icon: "checkmark.circle")
                        }
                        NavigationLink { FocusTimerView() } label: {
                            tool("Set Phone Limit", detail: "Make room for a moment of focus", icon: "timer")
                        }
                        NavigationLink { DhikrCounterView() } label: {
                            tool("Dhikr Counter", detail: "Keep your remembrance close", icon: "circle.dotted.circle")
                        }
                    }
                    CVCard {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "leaf").font(.title2).foregroundStyle(Color.cvPrimary)
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Time well spent").font(.headline)
                                Text("Read something meaningful. Make space for a good habit. Take it one day at a time.")
                                    .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                            }
                        }
                    }
                    NavigationLink { AppSettingsView() } label: {
                        tool("Settings", detail: "Appearance, reminders, and about", icon: "gearshape")
                    }
                    Text("CLEARVIEW · A MINDFUL DIGITAL LIFE")
                        .font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(2)
                        .foregroundStyle(Color.cvOnSurfaceVariant).frame(maxWidth: .infinity).padding(.top, 12)
                }.padding(20)
            }
            .background(Color.cvBackground).navigationTitle("More")
            .toolbar {
                Button { appearance = appearance == "dark" ? "light" : "dark" } label: {
                    Image(systemName: appearance == "dark" ? "sun.max" : "moon")
                }.accessibilityLabel("Switch appearance")
            }.buttonStyle(.plain)
        }
    }

    private func tool(_ title: String, detail: String, icon: String) -> some View {
        CVCard {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).foregroundStyle(Color.cvPrimary)
                    .frame(width: 44, height: 44)
                    .background(Color.cvPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            }.foregroundStyle(Color.cvOnSurface)
        }
    }
}

struct AppSettingsView: View {
    @AppStorage("appearance") private var appearance = "dark"
    @State private var reminders = QuranReminderSettingsModel()
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
            }
            Section("Quran reminders") {
                Toggle("Notifications", isOn: Binding(get: { reminders.notificationsEnabled }, set: { enabled in
                    Task { await reminders.setNotifications(enabled: enabled, verse: QuranStore().currentVerse) }
                }))
                Picker("Remind me", selection: Binding(get: { reminders.intervalHours }, set: { hours in
                    Task { await reminders.setInterval(hours: hours, verse: QuranStore().currentVerse) }
                })) {
                    ForEach(reminders.intervalOptions, id: \.hours) { option in Text(option.label).tag(option.hours) }
                }
                if reminders.permissionDenied {
                    Button("Allow notifications in Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                Text("While the app is closed, reminders repeat the last loaded verse. Open ClearView to refresh it.")
                    .font(.footnote).foregroundStyle(Color.cvOnSurfaceVariant)
            }
            Section("About ClearView") {
                LabeledContent("Version", value: "1.0")
                Text("A calmer place for Quran, thoughtful media, and good habits.")
                Link("Privacy policy", destination: URL(string: "https://muddassir-2025.github.io/ClearView/docs/privacy-policy.html")!)
                Link("Source code", destination: URL(string: "https://github.com/muddassir-2025/ClearView-ios")!)
            }
        }.scrollContentBackground(.hidden).background(Color.cvBackground)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .task { await reminders.load() }
    }
}

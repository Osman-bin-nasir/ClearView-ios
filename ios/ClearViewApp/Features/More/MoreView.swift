import SwiftUI

struct MoreView: View {
    @AppStorage("appearance") private var appearance = "dark"
    @State private var showAppearance = false
    @State private var showSettings = false
    @State private var showPhoneLimit = false
    @State private var deviceControls = DeviceControlsController.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sectionLabel("TOOLS")
                    NavigationLink { TodoView() } label: {
                        MoreToolRow(title: "Todo", detail: "Plan, remember, and complete your tasks", symbol: "checkmark.circle")
                    }
                    Button { showPhoneLimit = true } label: {
                        MoreToolRow(title: "Set Phone Limit", detail: "Countdown, break reminder and optional app restrictions", symbol: "timer")
                    }
                    NavigationLink { DhikrCounterView() } label: {
                        MoreToolRow(title: "Dhikr Counter", detail: "Count your dhikr with ease", emoji: "📿")
                    }
                    sectionLabel("PROTECTION").padding(.top, 4)
                    NavigationLink { ProtectionView(model: ProtectionModel.shared) } label: {
                        MoreToolRow(title: "Protection", detail: "Blocking, keywords, websites, filtering and app lock", symbol: "shield.fill", highlighted: true)
                    }
                }.padding(16)
            }.background(Color.cvBackground).navigationTitle("More")
                .onChange(of: deviceControls.expired) { _, expired in
                    if expired { showPhoneLimit = false; showSettings = false }
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbarBackground(Color.cvBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("More").font(.title2.bold())
                            Text("Tools & protection").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                        }.accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { showAppearance = true } label: { Image(systemName: appearance == "light" ? "sun.max" : "moon") }
                            .accessibilityLabel("Appearance")
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                    }
                }
                .confirmationDialog("Appearance", isPresented: $showAppearance, titleVisibility: .visible) {
                    Button("Use system appearance") { appearance = "system" }
                    Button("Light") { appearance = "light" }
                    Button("Dark") { appearance = "dark" }
                }
                .sheet(isPresented: $showSettings) {
                    NavigationStack {
                        AppSettingsView().toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } }
                        }
                    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                }
                .sheet(isPresented: $showPhoneLimit) {
                    NavigationStack {
                        FocusTimerView().toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { showPhoneLimit = false } }
                        }
                    }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
                }
                .buttonStyle(.plain)
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).font(.caption2.weight(.medium)).foregroundStyle(Color.cvOnSurfaceVariant)
            .padding(.leading, 4).padding(.top, 4).accessibilityAddTraits(.isHeader)
    }
}

private struct MoreToolRow: View {
    let title: String
    let detail: String
    var symbol: String? = nil
    var emoji: String? = nil
    var highlighted = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.cvPrimary.opacity(highlighted ? 0.22 : 0.12))
                if let symbol { Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(Color.cvPrimary) }
                if let emoji { Text(emoji).font(.system(size: 20)) }
            }.frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(highlighted ? Color.cvOnPrimaryContainer : Color.cvOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
        }.foregroundStyle(highlighted ? Color.cvOnPrimaryContainer : Color.cvOnSurface)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Color.cvPrimaryContainer : Color.cvSurfaceContainerLow,
                        in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct AppSettingsView: View {
    @AppStorage("appearance") private var appearance = "dark"
    @State private var reminders = QuranReminderSettingsModel()
    @State private var textScale = QuranStore().arabicTextScale
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Quran · New Verse").font(.headline)
                    Text("New verse every").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(reminders.intervalOptions, id: \.hours) { option in
                                CVChip(title: "\(option.hours) hr", selected: reminders.intervalHours == option.hours) {
                                    Task { await reminders.setInterval(hours: option.hours, verse: QuranStore().currentVerse) }
                                }
                            }
                        }
                    }
                    Text("Refresh interval: \(reminders.intervalLabel).")
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    Divider()
                    HStack {
                        Text("Quran reading size").font(.subheadline)
                        Spacer()
                        Text("\(Int(textScale * 100))%").font(.caption.bold()).foregroundStyle(Color.cvPrimary)
                    }
                    Slider(value: $textScale, in: QuranStore.arabicTextScaleRange, step: 0.05)
                        .accessibilityLabel("Quran reading text size")
                    Text("Adjusts Arabic text in the Quran reader. iOS notification text size is controlled by the system.")
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }.settingsCard()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Notifications").font(.headline)
                    Toggle("Todo reminders", isOn: Binding(get: { TodoStore().notificationsEnabled }, set: { enabled in
                        TodoStore().notificationsEnabled = enabled
                        Task { await TodoReminderScheduler.shared.refresh() }
                    }))
                    if let message = TodoReminderScheduler.shared.message { CVErrorBanner(message: message) }
                    Toggle(isOn: Binding(get: { reminders.notificationsEnabled }, set: { enabled in
                        Task { await reminders.setNotifications(enabled: enabled, verse: QuranStore().currentVerse) }
                    })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Quran Reminders").font(.subheadline.weight(.semibold))
                            Text("Get a notification when a new verse arrives.")
                                .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                        }
                    }
                    if reminders.permissionDenied {
                        Button("Allow notifications in Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }.font(.subheadline.bold())
                    }
                    Text("While the app is closed, reminders repeat the last loaded verse. Open ClearView to refresh it. Channel and media notification settings are not connected on iOS yet.")
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }.settingsCard()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Appearance").font(.headline)
                    Picker("Theme", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }.pickerStyle(.segmented)
                }.settingsCard()
                VStack(alignment: .leading, spacing: 14) {
                    Text("About ClearView").font(.headline)
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    Text("A calmer place for Quran, thoughtful media, and good habits.")
                        .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                    Link("Privacy policy", destination: URL(string: "https://muddassir-2025.github.io/ClearView/docs/privacy-policy.html")!)
                    Link("Source code", destination: URL(string: "https://github.com/muddassir-2025/ClearView-ios")!)
                }.settingsCard()
            }.padding(16)
        }.background(Color.cvBackground).navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .task { await reminders.load() }
            .onChange(of: textScale) { _, scale in
                var store = QuranStore()
                store.arabicTextScale = scale
            }
    }
}

private extension View {
    func settingsCard() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cvSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 16))
    }
}

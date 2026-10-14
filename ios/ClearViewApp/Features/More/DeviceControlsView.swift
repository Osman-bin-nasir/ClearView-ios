import SwiftUI
import FamilyControls

struct DeviceControlsView: View {
    var body: some View {
        ProtectionAccessGate {
            Form {
                Section("Screen Time") { DeviceControlsViewContent() }
                Section("Protection") {
                    DeviceProtectionToggles()
                    Text("These rules apply while Protection is enabled. Phone-limit restrictions remain until you unlock the expired session.")
                        .font(.footnote).foregroundStyle(Color.cvOnSurfaceVariant)
                }
                Section("Web protection") {
                    NavigationLink("Safari website protection") { SafariProtectionView() }
                    NavigationLink("Encrypted family DNS") { FamilyDNSView() }
                    Text("Screen Time filters up to 50 custom domains. ClearView's own content filtering continues to use your full list.")
                        .font(.footnote)
                }
            }
        }.navigationTitle("Device protection").tint(.cvPrimary)
    }
}

struct DeviceControlsViewContent: View {
    @State private var controls = DeviceControlsController.shared
    @State private var choosing = false
    @State private var selection = FamilyActivitySelection()
    @State private var protection = ProtectionModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(controls.authorized ? "Screen Time allowed" : "Screen Time permission needed", systemImage: "shield.lefthalf.filled")
            if !controls.authorized {
                Button("Allow Screen Time") { Task { await controls.authorize() } }.disabled(controls.busy)
            }
            Button("Choose apps, categories and websites") {
                selection = controls.state.selection
                choosing = true
            }.disabled(!controls.authorized || (protection.isLocked && controls.state.protectionEnabled && controls.state.shieldSelection))
            if protection.isLocked && controls.state.protectionEnabled && controls.state.shieldSelection {
                Text("Unlock Protection to change the apps it shields.").font(.caption)
            }
            Text("\(controls.state.selection.applicationTokens.count) apps · \(controls.state.selection.categoryTokens.count) categories · \(controls.state.selection.webDomainTokens.count) websites")
                .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            if let message = controls.message { CVErrorBanner(message: message) }
        }
        .sheet(isPresented: $choosing) {
            NavigationStack {
                FamilyActivityPicker(selection: $selection).navigationTitle("Choose restrictions")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosing = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("Save") { controls.setSelection(selection); choosing = false } }
                    }
            }
        }
        .onAppear { controls.refresh() }
        .onChange(of: protection.isUnlocked) { _, unlocked in if !unlocked { choosing = false } }
    }
}

private struct DeviceProtectionToggles: View {
    @State private var controls = DeviceControlsController.shared
    var body: some View {
        Toggle("Block selected apps and websites", isOn: Binding(get: { controls.state.shieldSelection }, set: { controls.setShield($0) }))
        Toggle("Filter adult websites", isOn: Binding(get: { controls.state.filterAdultWebsites }, set: { controls.setWebFiltering($0) }))
    }
}

import SwiftUI

struct SafariProtectionView: View {
    @State private var controller = SafariProtectionController.shared
    @State private var model = ProtectionModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        ProtectionAccessGate {
            Form {
                Section("Safari website protection") {
                    Label(controller.enabled ? "Extension enabled in Safari" : "Enable extension in Safari Settings", systemImage: "safari")
                    Text(model.protectionEnabled ? "\(controller.installedRules) website rules applied." : "Protection is off; ClearView is not blocking websites in Safari.")
                    Text("Your blocked websites and their subdomains are blocked in Safari when this extension and Protection are enabled. Safari does not share browsing history with ClearView. Page-text keywords, individual YouTube channels and Shorts are only filtered inside ClearView.")
                }
                Section("Setup") {
                    Text("Open iOS Settings → Apps → Safari → Extensions and enable ClearView Website Protection. Enable it for the Safari profiles and private browsing you use, where those options are offered. You remain in control of Safari permissions.")
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                    Button("Refresh website rules") { Task { await sync() } }.disabled(controller.updating)
                }
                if let message = controller.message { Section { CVErrorBanner(message: message) } }
            }
        }.navigationTitle("Safari protection").tint(.cvPrimary)
            .task { await sync() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await controller.refresh() } } }
    }

    private func sync() async {
        await controller.sync(enabled: model.protectionEnabled, domains: model.rules().domains)
    }
}

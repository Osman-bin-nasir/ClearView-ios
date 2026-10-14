import SwiftUI
import NetworkExtension

@MainActor
@Observable
final class FamilyDNSController {
    static let shared = FamilyDNSController()
    var configured = false
    var enabled = false
    var busy = false
    var message: String?
    private let manager = NEDNSSettingsManager.shared()
    private let endpoint = URL(string: "https://family.cloudflare-dns.com/dns-query")!

    func refresh() async {
        do {
            try await manager.loadFromPreferences()
            configured = (manager.dnsSettings as? NEDNSOverHTTPSSettings)?.serverURL == endpoint
            enabled = configured && manager.isEnabled
            message = nil
        } catch {
            configured = false
            enabled = false
            message = "Could not read DNS settings: \(error.localizedDescription)"
        }
    }

    func install() async {
        guard !busy, !ProtectionModel.shared.isLocked else { return }
        busy = true
        defer { busy = false }
        do {
            try await manager.loadFromPreferences()
            let settings = NEDNSOverHTTPSSettings(servers: ["1.1.1.3", "1.0.0.3"])
            settings.serverURL = endpoint
            manager.dnsSettings = settings
            manager.localizedDescription = "ClearView Family DNS"
            manager.onDemandRules = [NEOnDemandRuleConnect()]
            try await manager.saveToPreferences()
            message = nil
            await refresh()
        } catch { message = "DNS configuration was not installed: \(error.localizedDescription)" }
    }

    func remove() async {
        guard !busy, !ProtectionModel.shared.isLocked else { return }
        busy = true
        defer { busy = false }
        do {
            try await manager.loadFromPreferences()
            guard (manager.dnsSettings as? NEDNSOverHTTPSSettings)?.serverURL == endpoint else { await refresh(); return }
            try await manager.removeFromPreferences()
            message = nil
            await refresh()
        } catch { message = "Could not remove DNS configuration: \(error.localizedDescription)" }
    }
}

struct FamilyDNSView: View {
    @State private var controller = FamilyDNSController.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var removing = false

    var body: some View {
        ProtectionAccessGate {
            Form {
                Section("Cloudflare for Families") {
                    Label(controller.enabled ? "Enabled in iOS" : controller.configured ? "Installed — enable in Settings" : "Not installed", systemImage: "network")
                    Text("Encrypted DNS with the provider's malware and adult-domain filtering. This sends DNS queries to Cloudflare. It does not inspect pages or filter individual videos, and other VPN/DNS configurations may override it.")
                    if !controller.configured {
                        Button("Install family DNS") { Task { await controller.install() } }.disabled(controller.busy)
                    } else {
                        Button("Remove ClearView DNS", role: .destructive) { removing = true }.disabled(controller.busy)
                    }
                }
                Section("Enable after installation") {
                    Text("Open iOS Settings → General → VPN & Device Management → DNS and select ClearView Family DNS. Installing a configuration does not automatically enable it.")
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
                    Button("Refresh status") { Task { await controller.refresh() } }
                }
                if let message = controller.message { Section { CVErrorBanner(message: message) } }
            }
        }.navigationTitle("Family DNS").tint(.cvPrimary)
            .task { await controller.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await controller.refresh() } }
                if phase == .background { removing = false }
            }
            .confirmationDialog("Remove ClearView's DNS configuration?", isPresented: $removing, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { Task { await controller.remove() } }
            }
    }
}

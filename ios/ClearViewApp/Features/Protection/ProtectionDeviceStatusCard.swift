import SwiftUI

struct ProtectionDeviceStatusCard: View {
    @State private var controls = DeviceControlsController.shared
    @State private var safari = SafariProtectionController.shared
    @State private var dns = FamilyDNSController.shared
    @State private var protection = ProtectionModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DEVICE PROTECTION").font(.caption.weight(.semibold)).foregroundStyle(Color.cvOnSurfaceVariant)
            NavigationLink { DeviceControlsView() } label: {
                statusRow("Apps & Screen Time", subtitle: appStatus, symbol: "apps.iphone", active: controls.authorized && protection.protectionEnabled && controls.state.shieldSelection)
            }
            Divider()
            NavigationLink { SafariProtectionView() } label: {
                statusRow("Safari websites", subtitle: safari.enabled ? protection.protectionEnabled ? "\(safari.installedRules) website rules · extension enabled" : "Extension enabled · Protection is off" : "Enable ClearView's extension in Safari Settings", symbol: "safari", active: safari.enabled && protection.protectionEnabled)
            }
            Divider()
            NavigationLink { FamilyDNSView() } label: {
                statusRow("DNS Protection", subtitle: dns.enabled ? "Family DNS active in iOS" : dns.configured ? "Installed · enable in iOS DNS Settings" : "Set up encrypted family DNS", symbol: "network", active: dns.enabled)
            }
            Text("Permissions and setup determine which protections are active outside ClearView. Tap a row to configure it.")
                .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
        }.padding(14).background(Color.cvSurfaceVariant, in: RoundedRectangle(cornerRadius: 16))
            .task { await refresh() }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await refresh() } } }
    }

    private var appStatus: String {
        if !controls.authorized { return "Screen Time permission needed" }
        if controls.state.focusExpired && controls.state.focusRestrictsApps { return "Phone limit expired · selected apps restricted" }
        if !protection.protectionEnabled { return "Permission granted · Protection is off" }
        if controls.state.shieldSelection { return "Selected apps and websites restricted" }
        if controls.state.filterAdultWebsites || !controls.state.blockedDomains.isEmpty { return "Website filtering on · app shields off" }
        return "Permission granted · choose restrictions"
    }

    private func statusRow(_ title: String, subtitle: String, symbol: String, active: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.cvPrimary).frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.cvOnSurface)
                Text(subtitle).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Circle().fill(active ? Color.cvPrimary : Color.cvOutline).frame(width: 7, height: 7)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
        }.padding(.vertical, 3)
    }

    private func refresh() async {
        controls.refresh()
        await safari.refresh()
        await dns.refresh()
    }
}

import Foundation
import FamilyControls
import ManagedSettings

struct DeviceControlState: Codable {
    static let groupID = "group.com.muddassir.clearview"
    static let key = "device.controls.v1"
    static let storeName = ManagedSettingsStore.Name("clearview.device")
    static var defaults: UserDefaults {
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil {
            return UserDefaults(suiteName: groupID) ?? .standard
        }
        return .standard
    }

    var selection = FamilyActivitySelection()
    var timerSelection = FamilyActivitySelection()
    var shieldSelection = false
    var filterAdultWebsites = false
    var protectionEnabled = false
    var blockedDomains: [String] = []
    var focusDeadline: Date?
    var focusRestrictsApps = false

    var hasSelection: Bool {
        !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty || !selection.webDomainTokens.isEmpty
    }

    var focusExpired: Bool { focusDeadline.map { $0 <= Date() } ?? false }

    static func load() -> DeviceControlState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return state
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.defaults.set(data, forKey: Self.key)
    }

    func apply() {
        let store = ManagedSettingsStore(named: Self.storeName)
        var apps = Set<ApplicationToken>()
        var categories = Set<ActivityCategoryToken>()
        var websites = Set<WebDomainToken>()
        if protectionEnabled && shieldSelection {
            apps.formUnion(selection.applicationTokens)
            categories.formUnion(selection.categoryTokens)
            websites.formUnion(selection.webDomainTokens)
        }
        if focusExpired && focusRestrictsApps {
            apps.formUnion(timerSelection.applicationTokens)
            categories.formUnion(timerSelection.categoryTokens)
            websites.formUnion(timerSelection.webDomainTokens)
        }
        store.shield.applications = apps.isEmpty ? nil : apps
        store.shield.applicationCategories = categories.isEmpty ? nil : .specific(categories)
        store.shield.webDomains = websites.isEmpty ? nil : websites
        store.shield.webDomainCategories = categories.isEmpty ? nil : .specific(categories)
        let domains = Set(blockedDomains.prefix(50).map { WebDomain(domain: $0) })
        if protectionEnabled && filterAdultWebsites {
            store.webContent.blockedByFilter = .auto(domains)
        } else if protectionEnabled && !domains.isEmpty {
            store.webContent.blockedByFilter = .specific(domains)
        } else {
            store.webContent.blockedByFilter = nil
        }
    }
}

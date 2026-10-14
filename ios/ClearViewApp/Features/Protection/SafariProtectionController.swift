import Foundation
import Observation
import SafariServices

@MainActor
@Observable
final class SafariProtectionController {
    static let shared = SafariProtectionController()
    var enabled = false
    var installedRules = 0
    var message: String?
    var updating = false
    private var pendingRules: (enabled: Bool, domains: [String])?
    private var identifier: String { (Bundle.main.bundleIdentifier ?? "com.muddassir.clearview") + ".safari" }

    func refresh() async {
        do {
            let state = try await SFContentBlockerManager.stateOfContentBlocker(withIdentifier: identifier)
            enabled = state.isEnabled
        } catch {
            enabled = false
            message = "Safari blocker status is unavailable: \(error.localizedDescription)"
        }
    }

    func sync(enabled: Bool, domains: [String]) async {
        pendingRules = (enabled, domains)
        guard !updating else { return }
        updating = true
        defer { updating = false }
        while let request = pendingRules {
            pendingRules = nil
            do {
                guard let destination = SafariRulesFile.url else {
                    throw NSError(domain: "ClearViewSafari", code: 2, userInfo: [NSLocalizedDescriptionKey: "This build is missing the ClearView App Group entitlement."])
                }
                let domains = request.enabled ? Array(Set(request.domains)).sorted() : []
                var rules: [[String: Any]] = domains.map { domain in
                    let host = NSRegularExpression.escapedPattern(for: domain)
                    return ["trigger": ["url-filter": "^https?://([^/]*\\.)?\(host)([/:?]|$)"], "action": ["type": "block"]]
                }
                if rules.isEmpty { rules = [["trigger": ["url-filter": ".*"], "action": ["type": "ignore-previous-rules"]]] }
                let data = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
                let previous = try? Data(contentsOf: destination)
                if data != previous { try data.write(to: destination, options: .atomic) }
                if data != previous || installedRules != domains.count || message != nil {
                    try await SFContentBlockerManager.reloadContentBlocker(withIdentifier: identifier)
                }
                installedRules = domains.count
                message = nil
                await refresh()
            } catch { message = "Safari rules could not be applied: \(error.localizedDescription)" }
        }
    }
}

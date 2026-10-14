import Foundation

/// The client for the shared blocklist (the backend's `/api/v1/brainrot`).
///
/// The same service the Good Post tab talks to, at the same base URL from `Info.plist`,
/// with no account anywhere in it: the device id the app generated for itself is the
/// only identity, which is what lets someone take part in a shared blocklist without
/// signing up or being named.
///
/// **Every call is best-effort, and no call can weaken local protection.** The rule this
/// type is built under: a dead backend leaves the previous cached rules in force and
/// drops a failed suggestion. Nothing here throws into a caller, and nothing here can
/// empty a rule list because a request did not complete.
struct GlobalBlocklistClient {

    /// A read timeout is deliberately short: this runs behind a screen, and a slow answer
    /// is worth less than a responsive tab.
    private static let timeout: TimeInterval = 8

    private let baseUrl: @Sendable () -> String
    private let session: URLSession

    init(
        baseUrl: @escaping @Sendable () -> String = { GoodPostConfiguration.baseURL },
        session: URLSession = .shared
    ) {
        self.baseUrl = baseUrl
        self.session = session
    }

    /// True when this build has a backend configured at all.
    ///
    /// An empty value is a supported state rather than an error: the app then runs on its
    /// own rules, which is exactly the product before a shared list existed.
    var isConfigured: Bool { !baseUrl().trimmed.isEmpty }

    /// The active global rules, or nil on **any** failure.
    ///
    /// A partial response is never returned: a list that lost half its rules would
    /// silently unblock content the previous fetch had covered.
    func fetchRules() async -> GlobalRuleSnapshot? {
        guard isConfigured else { return nil }
        guard let object = await request(path: "/api/v1/brainrot/rules", method: "GET") else { return nil }

        let keywords = (object["keywords"] as? [[String: Any]])?.compactMap { entry -> (String, Int)? in
            guard let keyword = (entry["keyword"] as? String)?.trimmed, !keyword.isEmpty else { return nil }
            return (keyword.lowercased(), IntScalar.value(entry["reports"]) ?? 0)
        } ?? []
        let channels = (object["channels"] as? [[String: Any]])?
            .compactMap { ($0["handle"] as? String)?.trimmed }
            .filter { !$0.isEmpty } ?? []

        var snapshot = GlobalRuleSnapshot()
        snapshot.keywords = keywords.map(\.0)
        snapshot.keywordReports = Dictionary(keywords, uniquingKeysWith: { first, _ in first })
        snapshot.channels = channels
        snapshot.version = (object["version"] as? String) ?? "0"
        snapshot.lastSyncMs = ProtectionStore.nowMs()
        return snapshot
    }

    /// Suggest a keyword or a channel for the shared repository. Inert until approved.
    @discardableResult
    func suggest(
        kind: String,
        value: String,
        displayName: String? = nil,
        note: String? = nil,
        anonymousId: String
    ) async -> Bool {
        guard isConfigured else { return false }
        let body: [String: Any] = [
            "kind": kind,
            "value": value,
            "note": note as Any,
            "source": "app",
            "displayName": displayName as Any,
            "anonymousId": anonymousId,
        ]
        return await request(path: "/api/v1/brainrot/suggestions", method: "POST", body: body) != nil
    }

    /// The requests **this** device made, newest first.
    ///
    /// Unauthenticated in the ordinary sense and deliberately so: the device id is the
    /// identity, and it is the only key that can read this list. That is what lets
    /// someone see the fate of their own request without an account.
    func fetchSubmissions(anonymousId: String) async -> [ProtectionSubmission]? {
        guard isConfigured else { return nil }
        guard let object = await request(
            path: "/api/v1/brainrot/submissions?anonymousId=" + (encode(anonymousId) ?? ""),
            method: "GET"
        ) else { return nil }

        let rows = object["submissions"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let kind = row["kind"] as? String,
                  let value = row["value"] as? String
            else { return nil }
            return ProtectionSubmission(
                id: id,
                kind: kind,
                value: value,
                displayName: (row["displayName"] as? String)?.trimmed.nilWhenBlank,
                status: (row["status"] as? String) ?? SubmissionStatus.pending,
                atMs: ProtectionStore.nowMs()
            )
        }
    }

    // MARK: - Plumbing

    private func request(path: String, method: String, body: [String: Any]? = nil) async -> [String: Any]? {
        guard isConfigured, let url = URL(string: baseUrl().trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = GlobalBlocklistClient.timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        } catch {
            // Offline, DNS, TLS, timeout: all the same answer to a caller — nothing new,
            // keep what you have.
            return nil
        }
    }

    private func encode(_ value: String) -> String? {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    }
}

/// Reading a number out of JSON that may carry it as a number or a string.
///
/// `JSONSerialization` hands back `NSNumber`/`NSNull` rather than a typed value, and the
/// server has returned counts as both over its life. One helper, so no call site has to
/// guess which it is holding.
enum IntScalar {
    static func value(_ raw: Any?) -> Int? {
        switch raw {
        case let number as Int: return number
        case let number as Double: return Int(number)
        case let text as String: return Int(text)
        default: return nil
        }
    }
}

extension String {
    /// This string, or nil when it is empty or only whitespace.
    var nilWhenBlank: String? { isBlank ? nil : self }
}

import Foundation
import Security

actor FirebaseRESTIdentity: GoodPostIdentity {
    static let shared = FirebaseRESTIdentity()
    nonisolated let available: Bool
    private let apiKey: String
    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private var renewal: Task<String?, Never>?

    init(apiKey: String = Bundle.main.object(forInfoDictionaryKey: "FirebaseAPIKey") as? String ?? "") {
        self.apiKey = apiKey
        available = !apiKey.isEmpty && !ProcessInfo.processInfo.arguments.contains("--uitesting")
    }

    func token() async -> String? {
        guard available else { return nil }
        if let accessToken, expiresAt.timeIntervalSinceNow > 60 { return accessToken }
        if let renewal { return await renewal.value }
        let work = Task { await self.obtainReaderToken() }
        renewal = work
        let result = await work.value
        renewal = nil
        return result
    }

    private func obtainReaderToken() async -> String? {
        let stored = ReaderRefreshToken.load()
        let response: [String: Any]?
        if let stored {
            response = await request(host: "securetoken.googleapis.com", path: "v1/token", body: ["grant_type": "refresh_token", "refresh_token": stored], formEncoded: true)
        } else {
            response = await request(host: "identitytoolkit.googleapis.com", path: "v1/accounts:signUp", body: ["returnSecureToken": true])
        }
        guard let response else { return nil }
        if let error = response["error"] as? [String: Any],
           let message = error["message"] as? String,
           ["TOKEN_EXPIRED", "INVALID_REFRESH_TOKEN", "USER_DISABLED", "USER_NOT_FOUND"].contains(message) {
            ReaderRefreshToken.clear()
            accessToken = nil
            return nil
        }
        guard let token = (response["id_token"] ?? response["idToken"]) as? String,
              let refresh = (response["refresh_token"] ?? response["refreshToken"]) as? String else { return nil }
        accessToken = token
        let seconds = Double((response["expires_in"] ?? response["expiresIn"]) as? String ?? "3600") ?? 3600
        expiresAt = Date().addingTimeInterval(seconds)
        ReaderRefreshToken.save(refresh)
        return token
    }

    /// An ID token for the creator account these credentials belong to, or nil.
    ///
    /// `signUp` decides which way round the two Firebase calls go; it does **not** decide whether an
    /// account exists, because only Firebase knows that. Creating an account that is already there is
    /// refused with `EMAIL_EXISTS`, and the useful answer to that is to sign the same credentials in —
    /// so a returning creator and a new one can share one Continue button, which is what makes the
    /// screen one form rather than asking somebody to know which kind of account they have.
    func creatorToken(email: String, password: String, signUp: Bool) async -> String? {
        guard available else { return nil }
        let body: [String: Any] = ["email": email, "password": password, "returnSecureToken": true]
        let host = "identitytoolkit.googleapis.com"

        if signUp {
            if let created = await request(host: host, path: "v1/accounts:signUp", body: body),
               let token = created["idToken"] as? String {
                return token
            }
            // Either the address is taken or the sign-up was refused for a reason a sign-in will
            // report the same way. One attempt, so the caller gets one answer either way.
        }

        let response = await request(
            host: host,
            path: "v1/accounts:signInWithPassword",
            body: body
        )
        return response?["idToken"] as? String
    }

    func googleCreatorToken() async -> GoogleSignIn { .cancelled }
    func creatorSignOut() async {}

    private func request(host: String, path: String, body: [String: Any], formEncoded: Bool = false) async -> [String: Any]? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/\(path)"
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue(formEncoded ? "application/x-www-form-urlencoded" : "application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Bundle.main.bundleIdentifier ?? "com.muddassir.clearview", forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        if formEncoded {
            var form = URLComponents()
            form.queryItems = body.compactMap { key, value in (value as? String).map { URLQueryItem(name: key, value: $0) } }
            request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        } else { request.httpBody = try? JSONSerialization.data(withJSONObject: body) }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<500).contains(http.statusCode) else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch { return nil }
    }
}

private enum ReaderRefreshToken {
    static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.muddassir.clearview.reader", kSecAttrAccount: "firebase-refresh"]
    }

    static func load() -> String? {
        var request = query
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        let data = Data(token.utf8)
        if SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func clear() { SecItemDelete(query as CFDictionary) }
}

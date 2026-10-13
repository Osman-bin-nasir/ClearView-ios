import Foundation
import Security

/// Where an administrator session is kept.
///
/// A protocol so the repository can be tested without touching the device's credential store, and
/// so a host that already has a session (an app group, a shared extension) can supply it.
protocol GoodPostAdminSessionStoring: Sendable {
    func load() -> AdminSession?
    func save(_ session: AdminSession)
    func clear()
}

/// Encrypted-at-rest storage for the administrator session, in the iOS Keychain.
///
/// This is the **only** credential Good Post ever stores, and it belongs to an administrator
/// rather than to a reader: a viewer of this tab has no account and therefore nothing to keep.
/// That is the point of the file existing at all — if it held a normal user's session, Good Post
/// would have users.
///
/// The Keychain is the iOS counterpart of Android's Keystore-encrypted preferences: the value is
/// encrypted by the platform with a key the app never sees, and it is scoped to this device.
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is the accessibility that fits a publishing
/// session — usable after a restart without the unlock happening at that instant (so a background
/// upload is not blocked), never copied to iCloud and never restored onto another phone, which is
/// what "ThisDeviceOnly" buys and why it matters for a credential that can delete a channel.
struct KeychainAdminSessionStore: GoodPostAdminSessionStoring {

    private let service: String
    private let account: String

    init(
        service: String = "com.muddassir.clearview.goodpost",
        account: String = "admin_session"
    ) {
        self.service = service
        self.account = account
    }

    /// Persists the session. A failure is swallowed rather than thrown: the in-memory session
    /// still works for this run, and failing a sign-in over an unhealthy keychain would be worse
    /// than making an administrator sign in again after a restart.
    func save(_ session: AdminSession) {
        guard let data = Self.encode(session) else { return }
        clear()
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Reads the stored session, or nil when there is none.
    ///
    /// Every failure path ends in `clear()`. A keychain item can legitimately become unreadable —
    /// the device was restored, the app's key material changed, the item was written by a build
    /// with a different service name — and the correct response to unreadable credentials is to
    /// forget them and ask for the password again, never to fail on every open of the tab.
    func load() -> AdminSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound { return nil }
            clear()
            return nil
        }

        guard let session = Self.decode(data) else {
            clear()
            return nil
        }
        return session
    }

    /// Removes the stored session. Called on sign-out as well as on damage, so a phone handed to
    /// someone else does not carry publishing rights with it.
    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    // MARK: - Codec

    static func encode(_ session: AdminSession) -> Data? {
        let body: [String: Any] = [
            "token": session.token,
            "refreshToken": session.refreshToken,
            "role": session.role,
            "email": session.email,
            "channelId": session.channelId.map { $0 as Any } ?? NSNull(),
        ]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func decode(_ data: Data) -> AdminSession? {
        guard let dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let token = JSONScalar.string(dictionary["token"]) ?? ""
        // Both halves or neither: a session stored before this app kept the refresh token cannot
        // be renewed, and presenting it as usable would reproduce exactly the failure that made
        // this necessary — every call refused ten minutes in, worded as an empty account. Once,
        // on the update, the administrator signs in again.
        let refresh = JSONScalar.string(dictionary["refreshToken"]) ?? ""
        guard !token.isEmpty, !refresh.isEmpty else { return nil }

        return AdminSession(
            token: token,
            refreshToken: refresh,
            role: JSONScalar.string(dictionary["role"]) ?? "",
            email: JSONScalar.string(dictionary["email"]) ?? "",
            channelId: JSONScalar.nullableString(dictionary["channelId"])
        )
    }
}

/// An in-memory session store, for tests and for a build with no keychain access.
///
/// Deliberately not a persistence fallback: a session written to `UserDefaults` would be a
/// credential in an unencrypted file, which is exactly what the Keychain store exists to avoid.
final class InMemoryAdminSessionStore: GoodPostAdminSessionStoring, @unchecked Sendable {

    private let lock = NSLock()
    private var session: AdminSession?

    init(session: AdminSession? = nil) {
        self.session = session
    }

    func load() -> AdminSession? {
        lock.lock()
        defer { lock.unlock() }
        return session
    }

    func save(_ session: AdminSession) {
        lock.lock()
        defer { lock.unlock() }
        self.session = session
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        session = nil
    }
}

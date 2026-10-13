import Foundation

/// The device's own anonymous identity for the global blocklist.
///
/// A random UUID the app generates for itself on first use. It is deliberately **not**
/// derived from anything the device already carries — no identifier for vendor, no
/// advertising id, no phone number, no account — so it is a value that exists only
/// because the app made one up. That is what lets the Protection screen describe
/// contributions as anonymous rather than merely un-labelled, and it is the reason this
/// file must never grow a "device fingerprint" of any kind.
///
/// It can be regenerated at any time without losing anything: the id is how the server
/// de-duplicates a device's reports, not how it identifies a person, so losing one costs
/// at most a duplicate report.
///
/// The Android app keeps this in its own `SharedPreferences` file; on iOS it is a key in
/// the app's defaults. The *value* is what has to be well-formed, and `isValid` is what
/// guarantees it: the server refuses anything that is not a canonical UUID, so a
/// corrupted id is replaced locally rather than sent to be rejected.
struct AnonymousIdStore {

    enum Key {
        static let anonymousId = "brainrot_anonymous_id"
    }

    private let defaults: UserDefaults
    private let makeId: () -> String

    init(defaults: UserDefaults = .standard, makeId: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.defaults = defaults
        self.makeId = makeId
    }

    /// The stored id, generating and persisting one on first use.
    ///
    /// A stored value that is not a valid UUID is replaced rather than returned: sending
    /// it would earn a rejection, and keeping it would mean the same rejection on every
    /// future contribution.
    var current: String {
        if let existing = defaults.string(forKey: Key.anonymousId), AnonymousIdStore.isValid(existing) {
            return existing
        }
        let fresh = makeId()
        defaults.set(fresh, forKey: Key.anonymousId)
        return fresh
    }

    /// Replaces the id, so the next contribution looks like a different device.
    @discardableResult
    func regenerate() -> String {
        let fresh = makeId()
        defaults.set(fresh, forKey: Key.anonymousId)
        return fresh
    }

    /// Forgets the id entirely; the next read mints one.
    func reset() {
        defaults.removeObject(forKey: Key.anonymousId)
    }

    /// True when there is a usable id stored (without minting one).
    var hasStoredId: Bool {
        guard let existing = defaults.string(forKey: Key.anonymousId) else { return false }
        return AnonymousIdStore.isValid(existing)
    }

    /// True for a well-formed, **canonical** UUID.
    ///
    /// Parsing is the check, and the canonical spelling is compared back: some parsers
    /// accept forms that are not canonical (braces, extra padding, uppercase digits), and
    /// the server's rejection would be the only way to discover one. Comparing the parsed
    /// value's own description is how Android does it, so both platforms accept exactly
    /// the same strings.
    static func isValid(_ value: String?) -> Bool {
        guard let value, !value.trimmed.isEmpty else { return false }
        guard let parsed = UUID(uuidString: value) else { return false }
        return parsed.uuidString.lowercased() == value.lowercased()
    }
}

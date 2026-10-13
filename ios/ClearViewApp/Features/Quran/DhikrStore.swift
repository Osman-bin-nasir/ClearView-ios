import Foundation

/// Local persistence for the Dhikr Counter.
///
/// The Android store's Swift counterpart: one place holding the whole
/// `[DhikrItem]` list as JSON — counts, targets, visibility and order included —
/// plus the selected dhikr and the vibration preference. Reads are instant and
/// writes are cheap, which is what lets the counter save on every single tap
/// without a hitch.
///
/// The keys are prefixed (`dhikr_`) rather than copied verbatim from Android's
/// `items` / `selected_id` / `vibration_enabled`. On Android that file is its own
/// `SharedPreferences` file, so a generic key is harmless; on iOS every store
/// shares one `UserDefaults` domain, where a key called `items` is a collision
/// waiting to happen. The *JSON* is identical field for field — that is the part
/// that has to survive a move between the platforms, and `DhikrItem` keeps it.
struct DhikrStore {

    enum Key {
        static let items = "dhikr_items"
        static let selectedId = "dhikr_selected_id"
        static let vibrationEnabled = "dhikr_vibration_enabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every dhikr with its counting state, in selection order.
    ///
    /// Returns the built-ins when nothing is stored *or* when the stored JSON
    /// yields nothing usable; in the second case the stored selection is dropped
    /// too, because it refers to ids that are about to be replaced and would leave
    /// the counter pointing at a dhikr that no longer exists.
    var items: [DhikrItem] {
        guard let stored = defaults.string(forKey: Key.items) else {
            return DhikrCodec.defaults()
        }
        let decoded = DhikrCodec.decode(stored)
        guard !decoded.isEmpty else {
            defaults.removeObject(forKey: Key.selectedId)
            return DhikrCodec.defaults()
        }
        return DhikrCodec.ordered(decoded)
    }

    /// Persists the full list, re-indexed so the stored `order` matches the
    /// positions the caller handed over — the same normalisation Android does on
    /// save, which is what keeps order values from drifting over time.
    func saveItems(_ items: [DhikrItem]) {
        defaults.set(DhikrCodec.encode(DhikrCodec.reindexed(items)), forKey: Key.items)
    }

    /// The id of the dhikr the user last counted, or nil before the first pick.
    /// A blank stored value reads as nil, since it is not a usable id.
    var selectedId: String? {
        get { defaults.string(forKey: Key.selectedId)?.nilIfBlank }
        nonmutating set {
            guard let newValue, !newValue.isBlank else {
                defaults.removeObject(forKey: Key.selectedId)
                return
            }
            defaults.set(newValue, forKey: Key.selectedId)
        }
    }

    /// Whether counting vibrates on every tap. Defaults to on — the counter is
    /// used without looking at the screen, and the tap is the only confirmation
    /// there is.
    var vibrationEnabled: Bool {
        get {
            guard defaults.object(forKey: Key.vibrationEnabled) != nil else { return true }
            return defaults.bool(forKey: Key.vibrationEnabled)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.vibrationEnabled) }
    }

    /// Forgets everything about the counter — the list, the selection and the
    /// vibration preference — so the next read is the built-ins again. Behind the
    /// screen's "reset the counter" action.
    func reset() {
        defaults.removeObject(forKey: Key.items)
        defaults.removeObject(forKey: Key.selectedId)
        defaults.removeObject(forKey: Key.vibrationEnabled)
    }
}

extension String {
    /// This string with surrounding whitespace and newlines removed.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// True when this string has no characters other than whitespace.
    var isBlank: Bool { trimmed.isEmpty }

    /// This string, or nil when it has no non-whitespace characters.
    var nilIfBlank: String? { isBlank ? nil : self }
}

import Foundation

/// Where the Todo list lives between launches.
///
/// The Swift counterpart of Android's `TodoStore`: the whole `[TodoItem]` list as one
/// JSON string (the codec's), plus the preferences the screen owns. Reads are instant
/// and writes are cheap, which is what lets a checkbox save on the tap that toggled it
/// — a todo ticked off on a moving bus is still ticked off afterwards.
///
/// The keys are prefixed `todo_` rather than copied from Android's own
/// `SharedPreferences` file, where a generic name is harmless; on iOS every store
/// shares one `UserDefaults` domain. The *JSON* is identical field for field, which is
/// the part that has to keep meaning the same thing on both platforms.
struct TodoStore {

    enum Key {
        static let items = "todo_items"
        static let sort = "todo_sort"
        static let notificationsEnabled = "todo_notifications_enabled"
        static let lastSeenDay = "todo_last_seen_day"
        /// The daily target the progress card measures against.
        static let dailyTarget = "todo_daily_target"
    }

    enum Default {
        static let notificationsEnabled = true
        /// Three a day, as Android offers on first launch.
        static let dailyTarget = 3
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every todo, in stored order, with the codec's healing applied.
    ///
    /// A blank or unreadable store reads as an empty list — a fresh install, and a
    /// usable app — rather than as an error the caller has to handle.
    var items: [TodoItem] {
        TodoCodec.decode(defaults.string(forKey: Key.items))
    }

    /// Persists the whole list. The codec writes every field, including the history
    /// that would otherwise be lost, and nothing here prunes it.
    func saveItems(_ items: [TodoItem]) {
        defaults.set(TodoCodec.encode(items), forKey: Key.items)
        if defaults === UserDefaults.standard {
            Task { @MainActor in await TodoReminderScheduler.shared.refresh() }
        }
    }

    /// The list sort last chosen. Stored as the enum's name, like Android, so an
    /// unknown value falls back rather than failing.
    var sort: TodoSort {
        get { TodoSort(rawValue: defaults.string(forKey: Key.sort) ?? "") ?? .smart }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.sort) }
    }

    /// Whether the app posts todo reminders. On by default, as on Android: a reminder
    /// the user has to open the app to see is the feature switched off.
    var notificationsEnabled: Bool {
        get {
            guard defaults.object(forKey: Key.notificationsEnabled) != nil else {
                return Default.notificationsEnabled
            }
            return defaults.bool(forKey: Key.notificationsEnabled)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }

    /// The daily target the progress card and the streak measure against. Never below
    /// one — a target of zero would divide the progress bar by nothing.
    var dailyTarget: Int {
        get {
            guard defaults.object(forKey: Key.dailyTarget) != nil else { return Default.dailyTarget }
            return max(defaults.integer(forKey: Key.dailyTarget), 1)
        }
        nonmutating set { defaults.set(max(newValue, 1), forKey: Key.dailyTarget) }
    }

    /// The last day the Todo screen was opened, so "what's new since I looked" can be
    /// answered without scanning the history on every launch.
    var lastSeenDay: Int64? {
        get {
            guard defaults.object(forKey: Key.lastSeenDay) != nil else { return nil }
            return Int64(defaults.integer(forKey: Key.lastSeenDay))
        }
        nonmutating set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.lastSeenDay)
                return
            }
            defaults.set(Int(newValue), forKey: Key.lastSeenDay)
        }
    }

    /// Writes the list after a destructive reset — the store equivalent of
    /// `TodoCodec.resetEverything()`, which returns an empty list for the caller to
    /// save.
    func reset() {
        saveItems(TodoCodec.resetEverything())
    }
}

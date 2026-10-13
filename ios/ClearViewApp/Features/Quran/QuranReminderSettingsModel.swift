import Foundation
import Observation
import SharedKotlin

/// The reminder's settings and the decisions they imply: how often, whether to
/// notify, and what to do when the OS says no.
///
/// The iOS counterpart of the interval/notification half of Android's
/// `ContentHub` — the state, the permission dance and the re-scheduling, minus the
/// sheet that draws it. Every rule here is a rule the Android app has: a stored
/// interval outside the offered set is corrected rather than honoured, enabling the
/// toggle asks permission first, and a refusal leaves the toggle off with an
/// explanation instead of a switch that lies.
///
/// It is deliberately not responsible for picking a verse: the verse comes from
/// `QuranRepository`, and this type takes it as an argument. That keeps the
/// schedule testable without a downloaded edition.
@MainActor
@Observable
final class QuranReminderSettingsModel {

    /// The chosen interval, in hours, always one of `QuranReminder.intervalOptions`.
    private(set) var intervalHours: Int

    /// Whether the user wants a notification when the verse changes — the toggle's
    /// state, and the stored preference.
    ///
    /// Kept separate from whether reminders can actually be delivered, because the
    /// two disagree in exactly one situation: permission was granted when the user
    /// turned this on and revoked later in iOS Settings. The toggle then still reads
    /// as the user left it (Android does the same, and gates delivery on the OS
    /// permission at post time), and `permissionDenied` explains the gap.
    private(set) var notificationsEnabled: Bool

    /// The OS permission state, refreshed by `load()` and by every attempt to turn
    /// notifications on.
    private(set) var authorization: QuranReminderAuthorization

    /// Set when reminders are wanted but the system will not deliver them. The screen
    /// shows this beside the toggle and points at Settings; nothing in the app can
    /// reverse a denial, so the alternative is a switch that reads "on" and never
    /// fires.
    private(set) var permissionDenied = false

    /// Whether reminders will actually be delivered: wanted *and* permitted. What the
    /// scheduling below is gated on — not the toggle alone.
    var remindersActive: Bool {
        notificationsEnabled && authorization.allowsNotifications
    }

    private let store: QuranStore
    private let deliverer: QuranReminderDelivering
    private let now: () -> Date

    init(
        store: QuranStore = QuranStore(),
        deliverer: QuranReminderDelivering = UserNotificationQuranReminder(),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.deliverer = deliverer
        self.now = now
        self.intervalHours = store.refreshIntervalHours
        self.notificationsEnabled = store.notificationsEnabled
        self.authorization = .notDetermined
    }

    /// Reads the permission state and corrects the stored settings if they no longer
    /// describe something the app can do.
    ///
    /// Called when the settings surface appears: permission can be revoked in
    /// Settings while the app is closed, and a toggle left on would claim reminders
    /// that will never arrive.
    func load() async {
        authorization = await deliverer.authorizationStatus()
        // The store normalises the interval on read, so a value written by a build
        // that offered 2 / 4 / 8 hours already arrives as the default. Writing the
        // normalised value back makes the disk agree with what the picker is about to
        // show, which is what stops the two from drifting apart again on the next
        // launch.
        intervalHours = store.refreshIntervalHours
        store.refreshIntervalHours = intervalHours
        notificationsEnabled = store.notificationsEnabled
        permissionDenied = store.notificationsEnabled && authorization == .denied
    }

    /// The intervals the picker offers, with the labels the screen shows.
    var intervalOptions: [(hours: Int, label: String)] {
        QuranReminder.intervalOptions.map { ($0, QuranReminder.intervalLabel(hours: $0)) }
    }

    /// The label for the current interval.
    var intervalLabel: String { QuranReminder.intervalLabel(hours: intervalHours) }

    /// Chooses a new interval.
    ///
    /// Persists it and, when reminders are actually on, re-schedules at the new
    /// cadence immediately — the same "UPDATE, not KEEP" reasoning as Android's
    /// `QuranWorkScheduler.reschedule`: a user who just chose "every hour" should not
    /// have to wait out the old six-hour countdown to see it take effect.
    ///
    /// Returns the interval that was actually stored, which is not always the one
    /// asked for.
    @discardableResult
    func setInterval(hours: Int, verse: QuranVerse?) async -> Int {
        store.refreshIntervalHours = hours
        intervalHours = store.refreshIntervalHours
        await syncSchedule(verse: verse)
        return intervalHours
    }

    /// Turns the notification on or off.
    ///
    /// Enabling asks the OS for permission first, and only records the setting when
    /// it is granted. Returns the resulting state, so the toggle can be driven from
    /// the model rather than from its own optimistic flip.
    @discardableResult
    func setNotifications(enabled: Bool, verse: QuranVerse?) async -> Bool {
        guard enabled else {
            store.notificationsEnabled = false
            notificationsEnabled = false
            permissionDenied = false
            await deliverer.cancel()
            return false
        }

        let granted = await deliverer.requestAuthorization()
        authorization = await deliverer.authorizationStatus()
        permissionDenied = !granted
        // A refusal is stored as OFF, as Android does on a denied notification
        // permission: the toggle must not spring back on at the next visit and prompt
        // the user again, and the note tells them where to change it.
        store.notificationsEnabled = granted
        notificationsEnabled = granted
        if granted {
            await syncSchedule(verse: verse)
        }
        return granted
    }

    /// Applies the current settings to the OS.
    ///
    /// Called after the verse changes and after either setting changes. Cancels when
    /// there is nothing to show (no verse yet) or nothing to show it with (toggle
    /// off or permission withdrawn) — a pending reminder for a verse that has been
    /// replaced would arrive minutes after the app had already shown the new one.
    func syncSchedule(verse: QuranVerse?) async {
        guard remindersActive, let verse else {
            await deliverer.cancel()
            return
        }
        await deliverer.schedule(intervalHours: intervalHours, verse: verse)
    }

    /// Posts the new verse straight away, when reminders are on.
    ///
    /// The foreground half of what Android's background worker does: on iOS the
    /// verse changes while the user is looking at the app, and a reminder that only
    /// arrives six hours later is not the same feature. Returns whether anything was
    /// posted.
    @discardableResult
    func notifyIfEnabled(verse: QuranVerse) async -> Bool {
        guard remindersActive else { return false }
        await deliverer.postNow(verse: verse)
        return true
    }

    /// When the next verse is due, for the settings screen's "next in…" line.
    func plan(for verse: QuranVerse?) -> QuranReminder.Plan {
        QuranReminder.plan(
            lastUpdated: store.currentVerseUpdatedAt,
            intervalHours: intervalHours,
            now: now()
        )
    }

    /// True when the stored verse is older than the chosen interval, so the app
    /// should pick a new one the next time it can.
    var isRefreshDue: Bool {
        QuranReminder.isRefreshDue(
            lastUpdated: store.currentVerseUpdatedAt,
            intervalHours: intervalHours,
            now: now()
        )
    }

    /// The one-line state the settings screen shows under the toggle: what will
    /// happen, and why it will not. Wording a user can act on — a denied permission
    /// is the one case where the app cannot do anything itself, so it says so.
    var statusNote: String {
        if permissionDenied {
            return "Notifications are turned off in iOS Settings. ClearView can’t turn them back on."
        }
        if !notificationsEnabled {
            return "No notification. The verse still changes on \(intervalLabel.lowercased())."
        }
        return "A new verse every \(intervalHours) hours."
    }
}

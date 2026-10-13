import Foundation
import SharedKotlin
import UserNotifications

/// The reminder's permission state, in this app's own vocabulary.
///
/// A separate enum rather than passing `UNAuthorizationStatus` around: the value is
/// part of the settings screen's state and of the model that decides whether to
/// schedule anything, and neither should have to import UserNotifications to ask
/// "may I notify?". It also collapses `.ephemeral` (iOS's app-clip-only status)
/// into `.authorized`, which is what it means for this app.
enum QuranReminderAuthorization: String, Equatable {
    /// Never asked — the app has to request before it can schedule.
    case notDetermined
    /// Asked and refused. Only Settings can reverse this, so the app must not nag.
    case denied
    /// Asked and granted.
    case authorized

    var allowsNotifications: Bool { self == .authorized }
}

/// How the reminder actually reaches the user.
///
/// A protocol so the settings logic can be tested — and so the feature survives a
/// future decision to deliver reminders some other way (a Live Activity, a widget
/// timeline) without touching the rules.
protocol QuranReminderDelivering: Sendable {
    /// The current permission state, without prompting.
    func authorizationStatus() async -> QuranReminderAuthorization

    /// Asks for permission, returning whether it is now granted. Idempotent: asking
    /// again after a grant must not re-prompt.
    func requestAuthorization() async -> Bool

    /// Ensures exactly one repeating reminder exists, showing [verse] and repeating
    /// every [intervalHours].
    func schedule(intervalHours: Int, verse: QuranVerse) async

    /// Removes the repeating reminder (the notification toggle going off).
    func cancel() async

    /// Posts [verse] right now, without disturbing the repeating schedule.
    func postNow(verse: QuranVerse) async
}

/// The real delivery: a repeating `UNTimeIntervalNotificationTrigger`.
///
/// Why a repeating local notification rather than a background refresh: iOS
/// suspends apps and grants background execution on its own terms
/// (`BGAppRefreshTask` is opportunistic — it may not run for days), so a reminder
/// built on it would silently stop. A repeating trigger is handed to the system
/// and fires on schedule whether or not the app runs. The trade is that the *verse*
/// cannot change while the app is asleep — Android's `WorkManager` job picks a new
/// one each interval — so the app refreshes the verse (and re-schedules with it) on
/// the next foreground launch. The reminder still arrives on time; only the text is
/// as fresh as the last launch, which is stated in the settings copy rather than
/// pretended away.
struct UserNotificationQuranReminder: QuranReminderDelivering {

    /// A distinct identifier for the one-off post.
    ///
    /// Not the repeating identifier: adding a request under an existing identifier
    /// *replaces* it, so posting "here is today's verse" under
    /// `QuranReminder.notificationIdentifier` would quietly cancel the repeating
    /// schedule the user asked for.
    static let immediateIdentifier = QuranReminder.notificationIdentifier + ".now"

    private var center: UNUserNotificationCenter { .current() }

    func authorizationStatus() async -> QuranReminderAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized, .provisional, .ephemeral:
            return .authorized
        @unknown default:
            // A status this build has never heard of is treated as "cannot
            // schedule", which is the direction that does not post notifications
            // the user has not agreed to.
            return .denied
        }
    }

    func requestAuthorization() async -> Bool {
        let current = await authorizationStatus()
        if current == .authorized { return true }
        // `requestAuthorization` is a no-op returning false once denied, so the
        // prompt is only offered when the state is genuinely undecided.
        guard current == .notDetermined else { return false }
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func schedule(intervalHours: Int, verse: QuranVerse) async {
        let hours = QuranReminder.normalizedInterval(intervalHours)
        // The same identifier every time: re-scheduling replaces the pending
        // reminder rather than stacking a second one.
        center.removePendingNotificationRequests(
            withIdentifiers: [QuranReminder.notificationIdentifier]
        )
        let request = UNNotificationRequest(
            identifier: QuranReminder.notificationIdentifier,
            content: Self.content(for: verse),
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: TimeInterval(hours) * 3600,
                repeats: true
            )
        )
        try? await center.add(request)
    }

    func cancel() async {
        center.removePendingNotificationRequests(
            withIdentifiers: [QuranReminder.notificationIdentifier]
        )
    }

    func postNow(verse: QuranVerse) async {
        let request = UNNotificationRequest(
            identifier: Self.immediateIdentifier,
            content: Self.content(for: verse),
            trigger: nil
        )
        try? await center.add(request)
    }

    /// The notification's contents, in one place so the repeating and the one-off
    /// posts can never drift apart in wording.
    ///
    /// The reference travels in `userInfo` as well as in the subtitle: the app needs
    /// to open *that* verse when the notification is tapped, and parsing it back out
    /// of a localised subtitle string would be a bug waiting for a translation.
    static func content(for verse: QuranVerse) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = QuranReminder.title(surahName: verse.surahName)
        content.subtitle = QuranReminder.subtitle(for: verse)
        content.body = QuranReminder.body(for: verse)
        content.sound = .default
        content.userInfo = [
            "surahNumber": Int(verse.surahNumber),
            "ayahNumber": Int(verse.ayahNumber),
        ]
        return content
    }
}

/// A deliverer that records what it was asked to do and does nothing.
///
/// Used by the tests, and by previews: the reminder's *decisions* are what the
/// tests are about, and a deliverer that actually reached
/// `UNUserNotificationCenter` would need a running app to be meaningful.
final class RecordingQuranReminder: QuranReminderDelivering, @unchecked Sendable {

    private(set) var authorization: QuranReminderAuthorization
    /// True when `requestAuthorization` was called, so a test can assert the app
    /// did not prompt twice.
    private(set) var didRequestAuthorization = false
    private(set) var scheduled: [(intervalHours: Int, verse: QuranVerse)] = []
    private(set) var cancelCount = 0
    private(set) var posted: [QuranVerse] = []

    /// What `requestAuthorization` answers. Defaults to granting, since that is the
    /// interesting path; a denied test sets it to false.
    var grantsAuthorization = true

    init(authorization: QuranReminderAuthorization = .notDetermined) {
        self.authorization = authorization
    }

    func authorizationStatus() async -> QuranReminderAuthorization { authorization }

    func requestAuthorization() async -> Bool {
        didRequestAuthorization = true
        if grantsAuthorization {
            authorization = .authorized
        } else if authorization != .authorized {
            authorization = .denied
        }
        return grantsAuthorization
    }

    func schedule(intervalHours: Int, verse: QuranVerse) async {
        scheduled.append((intervalHours, verse))
    }

    func cancel() async { cancelCount += 1 }

    func postNow(verse: QuranVerse) async { posted.append(verse) }
}

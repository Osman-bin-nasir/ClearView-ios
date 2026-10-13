import Foundation
import SharedKotlin

/// The reminder's *rules*: how often a new verse is due, and what the notification
/// says.
///
/// Separated from the store and from the notifier the way the Android app keeps
/// `QuranWorkScheduler` apart from `QuranNotifier`: the cadence is a decision that
/// has to be identical on both platforms and is worth testing on its own, while
/// the delivery is a platform service that a test cannot meaningfully assert.
///
/// iOS has no `WorkManager`, so the mechanism differs even though the behaviour
/// does not: Android enqueues periodic work and posts a notification when it runs;
/// iOS schedules a repeating local notification (which fires whether or not the
/// app is running) and refreshes the verse in the foreground when the app is next
/// opened. The interval, the default and the options are the same on both.
enum QuranReminder {

    /// The only intervals offered (1 / 3 / 6 / 12 / 24 hours) — Android's list, so
    /// a user moving between the apps is not offered a different set of choices.
    static let intervalOptions = [1, 3, 6, 12, 24]

    /// The interval used on first launch, and for any stored value that is not one
    /// of the options (a build that offered 2 / 4 / 8 hours, say).
    static let defaultIntervalHours = 6

    /// The notification identifier. Stable, so re-scheduling *replaces* the pending
    /// reminder instead of posting a second one — the bug a random identifier would
    /// produce: two notifications a few hours apart, both claiming to be new.
    static let notificationIdentifier = "quran_verse_reminder"

    /// The iOS notification channel equivalent. Android's channel is named the same
    /// for the same reason: the user recognises it in Settings.
    static let channelName = "Quran reminders"
    static let channelDescription = "New verse notifications"

    /// `hours` held to the offered options — an unrecognised value becomes the
    /// default, not the nearest option, because a stored 2 h cannot be said to
    /// *mean* 1 or 3 and the default is the documented fallback.
    static func normalizedInterval(_ hours: Int) -> Int {
        intervalOptions.contains(hours) ? hours : defaultIntervalHours
    }

    /// Whether this interval is one the settings screen can show selected.
    static func isOffered(_ hours: Int) -> Bool { intervalOptions.contains(hours) }

    /// When the next verse is due, and whether it is already overdue.
    ///
    /// A value type rather than a bare `Date`, because "overdue" is a different
    /// situation from "due in 40 minutes" and the screens say different things:
    /// the reminder card shows when the verse changes, while the settings row shows
    /// that the schedule has lapsed (the phone was off, or iOS suspended the app)
    /// and the app will refresh it on the next open.
    struct Plan: Equatable {
        /// The instant the next verse is due. Never in the past: an overdue plan
        /// reports `now`, which is what makes "refresh immediately" the caller's
        /// obvious next step.
        let fireAt: Date
        /// The interval the plan was computed with, already normalised.
        let intervalHours: Int
        /// True when the stored verse is older than one whole interval.
        let isOverdue: Bool

        /// Whole hours until the next verse, floored at 0.
        func hoursUntil(from now: Date) -> Int {
            max(Int(fireAt.timeIntervalSince(now) / 3600), 0)
        }
    }

    /// The next due instant for a verse last refreshed at `lastUpdated`.
    ///
    /// `lastUpdated` is nil before the first verse was picked, which is treated as
    /// "due one whole interval from now" rather than "due now": a fresh install has
    /// nothing to remind anyone about until it has picked something.
    static func plan(
        lastUpdated: Date?,
        intervalHours: Int,
        now: Date = Date()
    ) -> Plan {
        let hours = normalizedInterval(intervalHours)
        let interval = TimeInterval(hours) * 3600
        guard let lastUpdated else {
            return Plan(fireAt: now.addingTimeInterval(interval), intervalHours: hours, isOverdue: false)
        }
        let due = lastUpdated.addingTimeInterval(interval)
        guard due > now else {
            return Plan(fireAt: now, intervalHours: hours, isOverdue: true)
        }
        return Plan(fireAt: due, intervalHours: hours, isOverdue: false)
    }

    /// Whether a stored verse should be replaced the next time the app can reach the
    /// edition — i.e. it is older than the chosen interval.
    static func isRefreshDue(
        lastUpdated: Date?,
        intervalHours: Int,
        now: Date = Date()
    ) -> Bool {
        plan(lastUpdated: lastUpdated, intervalHours: intervalHours, now: now).isOverdue
    }

    /// The notification title: Android's "New verse · Al-Fatihah", em dash and all,
    /// with the surah name resolved from the verse rather than stored separately.
    static func title(surahName: String) -> String {
        surahName.isEmpty ? "New verse" : "New verse · \(surahName)"
    }

    /// The notification body: the verse in quotes, exactly as Android posts it.
    /// Straight quotes rather than typographic ones in the stored form are avoided —
    /// the same curly quotes Android uses are reproduced here, since they are what
    /// the user sees on both.
    static func body(for verse: QuranVerse) -> String {
        "\u{201C}\(verse.text)\u{201D}"
    }

    /// The secondary line. iOS shows a subtitle and Android's notification does not,
    /// so this is an addition rather than parity — it carries the reference
    /// ("Al-Fatihah · 1:2") that Android's title folds into the surah name, which
    /// matters here because a notification can be read hours later, out of context.
    static func subtitle(for verse: QuranVerse) -> String {
        "\(verse.surahName) · \(verse.surahNumber):\(verse.ayahNumber)"
    }

    /// The settings copy, kept next to the behaviour it describes so the screen does
    /// not have to re-word the rule.
    static func intervalLabel(hours: Int) -> String {
        hours == 1 ? "Every hour" : "Every \(hours) hours"
    }
}

import Foundation

/// Today's date as the Umm al-Qura Islamic (Hijri) date, in English —
/// "26 Safar 1448 AH".
///
/// The iOS counterpart of the Android `IslamicDateFormatter`, and deliberately
/// the *same calendar*: Android uses java.time's `HijrahChronology`, which is the
/// Umm al-Qura table, and Foundation's `.islamicUmmAlQura` identifier is the same
/// table. That matters more than it sounds — the civil `.islamic` identifier is a
/// different (arithmetic) calendar and would disagree by a day for much of the
/// year, so a date shown here would contradict the one shown on Android.
///
/// Pure: no storage, no clock of its own. The caller passes the date, so the
/// rules below are testable and the screen can hold "today" in a value that
/// advances at midnight.
enum IslamicDate {

    /// English month names as used in Saudi Arabia (Umm al-Qura), in calendar
    /// order. The same twelve strings the Android formatter uses, so the two
    /// platforms say "Rabi al-Awwal", not "Rabi' al-Awwal" and "Rabīʿ I".
    static let monthNames = [
        "Muharram", "Safar", "Rabi al-Awwal", "Rabi al-Thani",
        "Jumada al-Awwal", "Jumada al-Thani", "Rajab", "Sha'ban",
        "Ramadan", "Shawwal", "Dhu al-Qadah", "Dhu al-Hijjah",
    ]

    /// The adjustment the user may apply by hand: the moon is not sighted on a
    /// calculator, so ±1 day is offered and nothing else. 0 is the calculated
    /// date, which is the default.
    static let adjustmentRange = -1...1

    /// The Umm al-Qura calendar this file formats with.
    ///
    /// Built per call rather than stored, because `Calendar` carries a time zone
    /// and a cached one would keep the zone the app launched in even after the
    /// user travels — the day would then flip at the wrong moment.
    private static func hijriCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .islamicUmmAlQura)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The Gregorian calendar used only to find the day [date] falls on.
    private static func gregorianCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The Hijri date for the day [date] falls on, shifted by [adjustmentDays]
    /// (−1 / 0 / +1). +1 shows tomorrow's Hijri date, −1 yesterday's.
    ///
    /// The conversion goes through the *start of the local day* rather than the
    /// instant: "today's Islamic date" is a fact about a day, not about a time,
    /// and converting 14:30 would make the answer depend on the hour the screen
    /// happened to redraw.
    static func hijriComponents(
        for date: Date,
        adjustmentDays: Int = 0,
        timeZone: TimeZone = .current
    ) -> DateComponents {
        let gregorian = gregorianCalendar(timeZone: timeZone)
        let day = gregorian.startOfDay(for: date)
        let shifted = gregorian.date(
            byAdding: .day,
            value: adjustmentDays.clamped(to: adjustmentRange),
            to: day
        ) ?? day
        return hijriCalendar(timeZone: timeZone).dateComponents(
            [.year, .month, .day],
            from: shifted
        )
    }

    /// Formats the day [date] falls on as "26 Safar 1448 AH".
    ///
    /// A component that is somehow absent formats as "…" rather than crashing or
    /// showing a zero: a calendar lookup that cannot answer is a bug worth seeing,
    /// not a reason to take the Quran tab down.
    static func format(
        date: Date,
        adjustmentDays: Int = 0,
        timeZone: TimeZone = .current
    ) -> String {
        let components = hijriComponents(
            for: date,
            adjustmentDays: adjustmentDays,
            timeZone: timeZone
        )
        guard
            let day = components.day,
            let month = components.month,
            (1...monthNames.count).contains(month),
            let year = components.year
        else {
            return "—"
        }
        return "\(day) \(monthNames[month - 1]) \(year) AH"
    }

    /// The Hijri year for the day [date] falls on — what a "Ramadan is coming"
    /// style check will read.
    static func year(for date: Date, adjustmentDays: Int = 0, timeZone: TimeZone = .current) -> Int? {
        hijriComponents(for: date, adjustmentDays: adjustmentDays, timeZone: timeZone).year
    }

    /// The Hijri month number (1 = Muharram) for the day [date] falls on.
    static func month(for date: Date, adjustmentDays: Int = 0, timeZone: TimeZone = .current) -> Int? {
        hijriComponents(for: date, adjustmentDays: adjustmentDays, timeZone: timeZone).month
    }

    /// The Hijri day of the month for the day [date] falls on.
    static func day(for date: Date, adjustmentDays: Int = 0, timeZone: TimeZone = .current) -> Int? {
        hijriComponents(for: date, adjustmentDays: adjustmentDays, timeZone: timeZone).day
    }

    /// The label the Quran tab puts under the date: the Gregorian date alongside
    /// the Hijri one, so a reader who does not read Hijri years can still place
    /// it. Formatted with the user's locale, because this half is not scripture.
    static func gregorianLabel(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

extension Comparable {
    /// This value held inside [range].
    ///
    /// A local helper rather than a call to `min(max(…))` at each site: the
    /// Islamic-date adjustment is clamped in three places (the store's read, the
    /// store's write, and the formatter), and three chances to write the bounds
    /// the wrong way round is two too many.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Persists the user's manual Islamic-date adjustment (±1 day).
///
/// The Android `IslamicDateStore` in Swift: one preference, clamped on both the
/// way in and the way out. The *date itself* is never stored — it is derived from
/// today's Gregorian date whenever it is shown, which is what makes it advance by
/// itself every day while the user's adjustment is preserved.
struct IslamicDateStore {

    enum Key {
        /// The Android preference name, so the two stores are recognisably the
        /// same store and a future importer can map one to the other.
        static let adjustment = "adjustment_days"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored adjustment: −1, 0 or +1 day. A fresh install has none, and a
    /// value written by a build that offered more is clamped rather than honoured.
    var adjustmentDays: Int {
        get {
            guard defaults.object(forKey: Key.adjustment) != nil else { return 0 }
            return defaults.integer(forKey: Key.adjustment).clamped(to: IslamicDate.adjustmentRange)
        }
        nonmutating set {
            defaults.set(
                newValue.clamped(to: IslamicDate.adjustmentRange),
                forKey: Key.adjustment
            )
        }
    }

    /// Clears the adjustment (back to the calculated date).
    func reset() {
        defaults.removeObject(forKey: Key.adjustment)
    }
}

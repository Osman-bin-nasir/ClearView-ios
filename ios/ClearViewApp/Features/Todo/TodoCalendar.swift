import Foundation

/// The date arithmetic the Todo domain is written in.
///
/// Android's `TodoCodec` reasons in `LocalDate` and epoch days; Swift has one
/// `Date` type and a calendar, so the two ideas are separated here explicitly: an
/// **epoch day** is a date with no time zone (the identity of a day), and a
/// **millisecond instant** is a wall-clock moment in the user's zone. Mixing those
/// up is how a todo completed at 11 pm shows as completed "yesterday" for anyone
/// living west of the calendar, so the two conversions live side by side and are
/// named after what they produce.
enum TodoCalendar {

    /// The epoch day of the *local* date this instant falls on.
    ///
    /// Reduced through the user's own calendar first — 23:30 on Monday is Monday,
    /// wherever they are — and only then encoded as a day number. The encoding itself
    /// is UTC-anchored, which is what makes the number independent of the zone: a todo
    /// set for "Aug 10" stays Aug 10 when the reader flies somewhere else.
    static func epochDay(of date: Date) -> Int64 {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return utcEpochDay(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1
        )
    }

    /// Today, as the user's own day — it flips at local midnight, not at UTC midnight.
    static func today() -> Int64 { epochDay(of: Date()) }

    /// The UTC midnight of `epochDay` — the canonical encoding of "that date", and
    /// the right input for anything that formats or inspects the date itself (as
    /// opposed to a moment on it, which is `startOfDayMillis`).
    static func date(epochDay: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(epochDay) * 86_400)
    }

    /// 1 = Monday … 7 = Sunday, matching Kotlin's `DayOfWeek.value` so
    /// `scheduledDays` means the same thing on both platforms.
    static func weekday(epochDay: Int64) -> Int {
        // Foundation counts 1 = Sunday … 7 = Saturday; the UTC calendar is the one the
        // epoch day is anchored to, so the two agree in every zone.
        let foundationWeekday = utcCalendar().component(.weekday, from: date(epochDay: epochDay))
        return ((foundationWeekday + 5) % 7) + 1
    }

    /// The wall-clock instant of local midnight on `epochDay`.
    ///
    /// The calendar date is read off the epoch day's UTC encoding and then
    /// materialised in the user's zone — *not* by asking the local calendar what date
    /// UTC midnight falls on, which is the previous day for anyone west of UTC and
    /// would put a todo's window on the wrong day.
    static func startOfDayMillis(epochDay: Int64) -> Int64 {
        let utc = utcCalendar()
        let components = utc.dateComponents([.year, .month, .day], from: date(epochDay: epochDay))
        let local = Calendar.current
        let midnight = local.date(
            from: DateComponents(year: components.year, month: components.month, day: components.day)
        ) ?? date(epochDay: epochDay)
        return Int64(midnight.timeIntervalSince1970 * 1000)
    }

    /// The wall-clock instant of `minutes` past local midnight on `epochDay`.
    static func millis(epochDay: Int64, minutes: Int) -> Int64 {
        startOfDayMillis(epochDay: epochDay) + Int64(normalizedMinutes(minutes)) * 60_000
    }

    /// The epoch day `millis` falls on, in the user's zone.
    static func epochDay(ofMillis millis: Int64) -> Int64 {
        epochDay(of: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }

    /// `minutes` held inside 0…1439, wrapping rather than clamping: 1440 ("24:00",
    /// the exclusive end of a 22:00–24:00 window) is midnight, and a negative value
    /// wraps the same way. Clamping instead would turn a 24:00 window end into
    /// 23:59 and quietly shorten the day.
    static func normalizedMinutes(_ minutes: Int) -> Int {
        if (0...1439).contains(minutes) { return minutes }
        let wrapped = minutes % 1440
        return wrapped < 0 ? wrapped + 1440 : wrapped
    }

    /// A `"MMM d"` label (Aug 10) in English, as Android's formatter prints it.
    ///
    /// Formatted in UTC because `date(epochDay:)` is UTC midnight — formatting it in
    /// the user's zone would print the previous day everywhere west of UTC.
    static func shortDateLabel(epochDay: Int64) -> String {
        formatter(pattern: "MMM d", timeZone: TimeZone(identifier: "UTC")!)
            .string(from: date(epochDay: epochDay))
    }

    /// A weekday short name (Mon) in English.
    static func weekdayName(_ weekday: Int) -> String {
        let names = ["", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return (1...7).contains(weekday) ? names[weekday] : ""
    }

    /// An `"h:mm a"` label (2:08 PM) for a wall-clock instant.
    static func timeLabel(_ date: Date) -> String {
        formatter(pattern: "h:mm a", timeZone: .current).string(from: date)
    }

    /// An `"h:mm a"` label (10:00 PM) for a minutes-from-midnight value.
    ///
    /// Formatted in UTC deliberately: a time of day has no date and no zone, so
    /// building it from an instant in the user's zone would shift it by their offset
    /// and print a 20:00 todo as 1:30 AM in India.
    static func timeLabel(minutes: Int) -> String {
        let normalized = normalizedMinutes(minutes)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(
            from: DateComponents(year: 2000, month: 1, day: 1, hour: normalized / 60, minute: normalized % 60)
        ) ?? Date(timeIntervalSince1970: 0)
        return formatter(pattern: "h:mm a", timeZone: TimeZone(identifier: "UTC")!).string(from: date)
    }

    /// A formatter pinned to English, matching the Android labels: the app has no
    /// runtime locale switching and the todo labels are stored-ish strings, so a
    /// device in another language must not start printing "10.08" for a date its
    /// sibling app prints as "Aug 10".
    private static func formatter(pattern: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter
    }

    /// A Gregorian calendar pinned to UTC — the calendar that decodes and encodes the
    /// day numbers, so they mean the same thing on every device.
    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func utcEpochDay(year: Int, month: Int, day: Int) -> Int64 {
        let date = utcCalendar().date(from: DateComponents(year: year, month: month, day: day)) ?? Date()
        return Int64(floor(date.timeIntervalSince1970 / 86_400))
    }
}

import Foundation

/// How long an advertisement card runs (§11).
///
/// A length rather than a date, because that is the question an administrator is actually
/// answering: nobody decides to run a card "until the fourteenth", they decide to run it "for a
/// week". The two are the same thing once resolved, which is why this carries the arithmetic and the
/// form keeps the timestamps.
///
/// `custom` exists for the case the presets cannot express — a campaign that has to end on a
/// particular day — and it is what a picked date resolves to. It is deliberately NOT a fixed length:
/// it means "whatever the form's own dates currently say".
enum GoodPostAdDuration: String, CaseIterable {
    /// No end at all; the card runs until it is switched off or deleted.
    case noExpiry
    case oneDay
    case oneWeek
    case oneMonth
    case custom

    /// The pill's own word, which is a length rather than a date for the same reason this type is.
    var label: String {
        switch self {
        case .noExpiry: return "No end"
        case .oneDay: return "1 day"
        case .oneWeek: return "1 week"
        case .oneMonth: return "1 month"
        case .custom: return "Pick dates"
        }
    }

    /// When a card of this length should stop, as an ISO instant, or nil for no end.
    ///
    /// A calendar month rather than thirty days: "a month" from the 31st is the 30th of the next
    /// month, which is what a person means and what a fixed day count would get wrong four times a
    /// year. The calendar is a parameter so the arithmetic can be pinned by a test rather than by the
    /// machine it happens to run on.
    func expiry(from now: Date, calendar: Calendar = .current) -> String? {
        func adding(_ component: Calendar.Component, _ value: Int) -> String? {
            calendar.date(byAdding: component, value: value, to: now).map(isoInstant)
        }
        switch self {
        case .noExpiry, .custom: return nil
        case .oneDay: return adding(.day, 1)
        case .oneWeek: return adding(.weekOfYear, 1)
        case .oneMonth: return adding(.month, 1)
        }
    }

    /// The length an existing card was given, as far as the form can tell.
    ///
    /// Shown as custom unless it has no end at all: there is no way to tell a one-week card from a
    /// one-month one by looking at its end date, and guessing would relabel what the administrator
    /// actually set.
    static func forExistingAd(expiresAt: String?) -> GoodPostAdDuration {
        (expiresAt ?? "").trimmed.isEmpty ? .noExpiry : .custom
    }
}

/// An ISO instant for the START of the local day containing `date`.
///
/// The platform's date picker answers in a moment of a chosen day, and a card that "starts today"
/// should start at midnight where the administrator is sitting — that way the whole first day is
/// there to be seen rather than the part of it after the tap.
func isoFromLocalStart(_ date: Date, calendar: Calendar = .current) -> String {
    isoInstant(calendar.startOfDay(for: date))
}

/// An instant as the wire spells it: UTC, with milliseconds, `2026-10-03T00:00:00.000Z`.
func isoInstant(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
}

/// A short, human label for an instant — "3 Oct 2026" — or nil when there is no readable date.
///
/// The editor prints the resolved dates beside the pills, and an ISO string is not something to put
/// in front of a person. Tolerant of the two shapes the server sends, through the same parser the
/// rest of the tab uses.
func formatAdDate(_ iso: String?, timeZone: TimeZone = .current) -> String? {
    guard let millis = parseIsoMillis(iso) else { return nil }
    var style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
    style.timeZone = timeZone
    return Date(timeIntervalSince1970: Double(millis) / 1000).formatted(style)
}

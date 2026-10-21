import XCTest
@testable import ClearView

/// The advertisement schedule's arithmetic (§11).
///
/// A length is what an administrator chooses and two timestamps are what the server stores, so the
/// conversion is the whole of the feature. It is pinned here because the arithmetic has two traps
/// that no screen would report: a month is not thirty days, and "starts today" has to mean midnight
/// where the administrator is sitting rather than midnight UTC.
final class GoodPostAdScheduleTests: XCTestCase {

    /// A calendar fixed to UTC so the arithmetic is the code's and not the machine's.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        return formatter.date(from: iso)!
    }

    // MARK: - Lengths

    func testNoEndMeansNoDate() {
        XCTAssertNil(GoodPostAdDuration.noExpiry.expiry(from: date("2026-10-03T09:30:00Z"), calendar: calendar))
        XCTAssertNil(GoodPostAdDuration.custom.expiry(from: date("2026-10-03T09:30:00Z"), calendar: calendar))
    }

    func testADayAWeekAndAMonth() {
        let now = date("2026-10-03T09:30:00Z")
        XCTAssertEqual(GoodPostAdDuration.oneDay.expiry(from: now, calendar: calendar), "2026-10-04T09:30:00.000Z")
        XCTAssertEqual(GoodPostAdDuration.oneWeek.expiry(from: now, calendar: calendar), "2026-10-10T09:30:00.000Z")
        XCTAssertEqual(GoodPostAdDuration.oneMonth.expiry(from: now, calendar: calendar), "2026-11-03T09:30:00.000Z")
    }

    /// A month is a calendar month, not thirty days: from the 31st it lands on the last day of the
    /// next month, which is what a person means and what a day count gets wrong four times a year.
    func testAMonthIsACalendarMonthNotThirtyDays() {
        let expiry = GoodPostAdDuration.oneMonth.expiry(from: date("2026-01-31T00:00:00Z"), calendar: calendar)
        XCTAssertEqual(expiry?.prefix(10), "2026-02-28")

        let leap = GoodPostAdDuration.oneMonth.expiry(from: date("2028-01-31T00:00:00Z"), calendar: calendar)
        XCTAssertEqual(leap?.prefix(10), "2028-02-29")
    }

    /// Every preset except the two that mean "no computed date" resolves.
    func testThePillsAreLengthsAndOnlyTheOpenEndedOnesHaveNoDate() {
        let now = date("2026-10-03T09:30:00Z")
        XCTAssertEqual(GoodPostAdDuration.allCases.count, 5)
        XCTAssertEqual(
            GoodPostAdDuration.allCases.filter { $0.expiry(from: now, calendar: calendar) == nil },
            [.noExpiry, .custom]
        )
        XCTAssertEqual(GoodPostAdDuration.allCases.map(\.label),
                       ["No end", "1 day", "1 week", "1 month", "Pick dates"])
    }

    // MARK: - What an existing card shows

    /// There is no way to tell a one-week card from a one-month one by looking at its end date, so
    /// an end date that exists reads as custom rather than as a guess.
    func testAnExistingCardIsCustomUnlessItHasNoEnd() {
        XCTAssertEqual(GoodPostAdDuration.forExistingAd(expiresAt: nil), .noExpiry)
        XCTAssertEqual(GoodPostAdDuration.forExistingAd(expiresAt: "  "), .noExpiry)
        XCTAssertEqual(GoodPostAdDuration.forExistingAd(expiresAt: "2026-11-03T09:30:00.000Z"), .custom)
    }

    // MARK: - Days, not moments

    /// A picked day starts at the local start of that day, so the whole first day is there to be
    /// seen rather than the part of it after the tap.
    func testAPickedDayIsAnchoredToTheLocalStart() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 2 * 3600)!
        let picked = date("2026-10-03T17:45:00Z")
        let iso = isoFromLocalStart(picked, calendar: calendar)
        // 19:45 local on the 3rd, so the day starts at 22:00 UTC on the 2nd.
        XCTAssertEqual(iso, "2026-10-02T22:00:00.000Z")
    }

    func testARoundTripKeepsTheDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!
        let picked = date("2026-12-31T12:00:00Z")
        let iso = isoFromLocalStart(picked, calendar: calendar)
        let label = formatAdDate(iso, timeZone: calendar.timeZone)
        XCTAssertNotNil(label)
        XCTAssertTrue(label!.contains("31"), label!)
        XCTAssertTrue(label!.contains("2026"), label!)
    }

    // MARK: - Labels

    func testAnUnreadableDateHasNoLabel() {
        XCTAssertNil(formatAdDate(nil))
        XCTAssertNil(formatAdDate(""))
        XCTAssertNil(formatAdDate("not a date"))
    }

    func testBothWireShapesRead() {
        // The server sends milliseconds in the instant; the tab's own parser accepts both.
        XCTAssertNotNil(formatAdDate("2026-10-03T00:00:00.000Z"))
        XCTAssertNotNil(formatAdDate("2026-10-03T00:00:00Z"))
    }
}

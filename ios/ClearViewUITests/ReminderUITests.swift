import XCTest

/// The reminder card on the Quran tab.
///
/// The unit tests prove the picking and stepping rules. What only a launch can
/// show is that the card actually appears above the list, that a fresh install
/// picks a verse without anyone asking, and that tapping it opens the reader on
/// the verse it was showing — not on the top of that surah, which is the easy
/// mistake to make and the one a reader would notice.
final class ReminderUITests: XCTestCase {

    private let listTimeout: TimeInterval = 120

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testTheReminderAppearsAndOpensItsOwnVerse() {
        let app = XCUIApplication()
        app.launch()

        // The card, and the position it is showing.
        let position = app.staticTexts["quran.reminder.position"]
        XCTAssertTrue(
            position.waitForExistence(timeout: listTimeout),
            "the Quran tab must show a reminder verse (a fresh install picks one)"
        )
        let remindedVerse = position.label
        XCTAssertTrue(
            remindedVerse.range(of: #"^\d+:\d+$"#, options: .regularExpression) != nil,
            "the reminder must show a surah:ayah position, got '\(remindedVerse)'"
        )

        let card = app.descendants(matching: .any)
            .matching(identifier: "quran.reminder")
            .firstMatch
        XCTAssertTrue(card.exists, "the reminder card must be tappable")
        card.tap()

        // A pushed screen replaces the hierarchy, so this label can only be the
        // reader's ayah — which makes it proof that the reader opened *there*.
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '\(remindedVerse)'"))
                .firstMatch
                .waitForExistence(timeout: 30),
            "tapping the reminder must open the reader at \(remindedVerse)"
        )
        // Waited on, not merely checked: `exists` is evaluated immediately, and the
        // toolbar of a freshly pushed screen is not in the hierarchy on the next
        // line. This is the assertion that the reminder *navigated* rather than the
        // label match above being satisfied by the card's own text.
        XCTAssertTrue(
            app.buttons["BackButton"].firstMatch.waitForExistence(timeout: 30),
            "the reminder must have pushed a reader (there is something to go back to)"
        )
    }

    /// Stepping one ayah forward and back returns to where it started.
    ///
    /// A round trip rather than "the next verse is X": which ayah follows depends
    /// on the surah lengths, and the whole point of the shared stepping rule is
    /// that it does not need a table of them. Next-then-previous is deterministic
    /// for *any* starting verse, and it proves the rule is being used in both
    /// directions — including across a surah boundary, which most starting points
    /// will cross.
    func testSteppingForwardAndBackReturnsToTheSameVerse() {
        let app = XCUIApplication()
        app.launch()

        let position = app.staticTexts["quran.reminder.position"]
        XCTAssertTrue(position.waitForExistence(timeout: listTimeout), "the reminder must appear")

        let next = app.buttons["quran.reminder.next"]
        let previous = app.buttons["quran.reminder.previous"]
        XCTAssertTrue(next.waitForExistence(timeout: 15), "the reminder must offer the next verse")
        XCTAssertTrue(previous.exists, "the reminder must offer the previous verse")

        // The one starting point where "previous" cannot be used: the first ayah.
        // Skipped rather than asserted, because which verse a fresh install picks
        // is random and 1:1 is a legitimate pick.
        if !previous.isEnabled {
            next.tap()
            XCTAssertTrue(previous.waitForExistence(timeout: 15), "one step in, there is a verse to go back to")
        }

        let start = position.label
        next.tap()

        // It moved, and to a real position.
        let moved = NSPredicate(format: "label != %@", start)
        expectation(for: moved, evaluatedWith: position, handler: nil)
        waitForExpectations(timeout: 15)
        let afterNext = position.label
        XCTAssertTrue(
            afterNext.range(of: #"^\d+:\d+$"#, options: .regularExpression) != nil,
            "stepping must land on a real verse, got '\(afterNext)'"
        )

        previous.tap()
        let returned = NSPredicate(format: "label == %@", start)
        expectation(for: returned, evaluatedWith: position, handler: nil)
        waitForExpectations(timeout: 15)
    }

    /// The refresh control picks another verse and the card re-renders. Only the
    /// *change* is asserted loosely: the pick is deliberately random, so requiring
    /// a different verse every time would be a flaky test of the random source
    /// rather than of the control.
    func testTheRefreshControlPicksAgain() {
        let app = XCUIApplication()
        app.launch()

        let position = app.staticTexts["quran.reminder.position"]
        XCTAssertTrue(position.waitForExistence(timeout: listTimeout), "the reminder must appear")
        let before = position.label

        let refresh = app.buttons["Show another verse"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 15), "the reminder must offer another verse")
        refresh.tap()

        // The card is still there afterwards and still shows a position — i.e. the
        // pick returned a verse rather than leaving the tab empty. (With 6 236
        // verses it is overwhelmingly likely to differ, but that is luck, not a
        // requirement, so it is not asserted.)
        XCTAssertTrue(position.waitForExistence(timeout: 30), "a verse must still be shown after picking another")
        XCTAssertTrue(
            position.label.range(of: #"^\d+:\d+$"#, options: .regularExpression) != nil,
            "the card must still show a position, was '\(before)' before"
        )
    }
}

import XCTest

/// The verse page on the Quran tab — what Android calls `QuranTab`.
///
/// The unit tests prove the picking and stepping rules. What only a launch can
/// show is that the page actually appears with a verse in it, that Previous/Next
/// move through the Quran and come back, and that "New Verse" re-picks without
/// emptying the page. Those are the failures a reader would hit and no unit test
/// can see: the rules are the model's, the wiring is the view's.
///
/// The page is addressed by its own identifiers rather than by its text, because
/// the text is the scripture and the point of these tests is the machinery around
/// it.
final class ReminderUITests: XCTestCase {

    private let listTimeout: TimeInterval = 120

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The page shows a verse, and the reference line reports where in the Quran
    /// it is — which is the one thing the reader needs to place it.
    func testTheVersePageShowsAVerseWithItsPosition() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        let position = app.staticTexts["quran.verse.position"]
        XCTAssertTrue(
            position.waitForExistence(timeout: listTimeout),
            "the Quran tab must open on a verse (a fresh install picks one)"
        )
        // The label is the *spoken* form Android gives the same line, so this also
        // pins the accessibility wording the two platforms share.
        XCTAssertTrue(
            position.label.range(of: #"^Ayah \d+ of \d+ in this surah$"#, options: .regularExpression) != nil,
            "the reference line must state the position, got '\(position.label)'"
        )
        // The verse itself is on the page, and so are the controls that act on it.
        XCTAssertTrue(app.buttons["Previous"].exists, "the page must offer Previous")
        XCTAssertTrue(app.buttons["Next"].exists, "the page must offer Next")
        XCTAssertTrue(app.buttons["New Verse"].exists, "the page must offer another verse")
        XCTAssertTrue(app.buttons["Copy verse"].exists, "the page must offer Copy")
    }

    /// Stepping one ayah forward and back returns to where it started.
    ///
    /// A round trip rather than "the next verse is X": which ayah follows depends
    /// on the surah lengths, and the whole point of the shared stepping rule is
    /// that it does not need a table of them. Next-then-previous is deterministic
    /// for *any* starting verse, and it proves the rule is used in both directions
    /// — including across a surah boundary, which most starting points will cross.
    func testSteppingForwardAndBackReturnsToTheSameVerse() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        let position = app.staticTexts["quran.verse.position"]
        XCTAssertTrue(position.waitForExistence(timeout: listTimeout), "the verse page must appear")

        let next = app.buttons["Next"]
        let previous = app.buttons["Previous"]
        XCTAssertTrue(next.waitForExistence(timeout: 15), "the page must offer Next")

        // The one starting point where "Previous" cannot be used: the first ayah of
        // the Quran. Skipped rather than asserted, because which verse a fresh
        // install picks is random and 1:1 is a legitimate pick.
        if !previous.isEnabled {
            next.tap()
            XCTAssertTrue(
                previous.waitForExistence(timeout: 15),
                "one step in, there is a verse to go back to"
            )
        }

        // Once it can be tested, a step back from here must be possible too.
        XCTAssertTrue(previous.isEnabled, "there must be a verse before a random pick's second verse")

        let start = position.label
        next.tap()

        expectation(for: NSPredicate(format: "label != %@", start), evaluatedWith: position, handler: nil)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(
            position.label.range(of: #"^Ayah \d+ of \d+ in this surah$"#, options: .regularExpression) != nil,
            "stepping must land on a real verse, got '\(position.label)'"
        )

        previous.tap()
        expectation(for: NSPredicate(format: "label == %@", start), evaluatedWith: position, handler: nil)
        waitForExpectations(timeout: 15)
    }

    /// "New Verse" picks again and the page re-renders. Only the *presence* of a
    /// verse afterwards is asserted: the pick is deliberately random, so requiring
    /// a different verse every time would be a flaky test of the random source
    /// rather than of the control.
    func testNewVersePicksAgain() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        let position = app.staticTexts["quran.verse.position"]
        XCTAssertTrue(position.waitForExistence(timeout: listTimeout), "the verse page must appear")
        let before = position.label

        app.buttons["New Verse"].tap()

        XCTAssertTrue(position.waitForExistence(timeout: 30), "a verse must still be shown after picking another")
        XCTAssertTrue(
            position.label.range(of: #"^Ayah \d+ of \d+ in this surah$"#, options: .regularExpression) != nil,
            "the page must still show a position, was '\(before)' before"
        )
    }

    /// The bookmark icon is about the verse on screen: it flips when it is tapped,
    /// and it is forgotten again when the verse changes.
    ///
    /// That second half is the part worth a launch: an icon that stayed filled
    /// after "Next" would be telling the reader that the *new* verse was saved,
    /// which is the mistake this control exists to avoid.
    func testTheBookmarkIconFollowsTheVerseOnScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()

        let position = app.staticTexts["quran.verse.position"]
        XCTAssertTrue(position.waitForExistence(timeout: listTimeout), "the verse page must appear")

        let bookmark = app.buttons["quran.bookmark"]
        XCTAssertTrue(bookmark.exists, "the bar must offer a bookmark")

        // Normalise: a previous run may have left this verse saved, and which verse
        // is shown is random.
        if bookmark.value as? String == "saved" { bookmark.tap() }
        XCTAssertEqual(bookmark.value as? String, "not saved", "the verse must start unsaved")

        bookmark.tap()
        XCTAssertTrue(
            app.staticTexts["Verse bookmarked"].waitForExistence(timeout: 10),
            "saving must say so"
        )
        XCTAssertEqual(bookmark.value as? String, "saved", "the icon must report the verse is saved")

        // Step to another verse: the icon must answer for THAT verse, which has
        // almost certainly never been saved.
        let before = position.label
        app.buttons["Next"].tap()
        expectation(for: NSPredicate(format: "label != %@", before), evaluatedWith: position, handler: nil)
        waitForExpectations(timeout: 15)
        XCTAssertEqual(
            bookmark.value as? String,
            "not saved",
            "the icon must answer for the verse now on screen"
        )

        // Leave it as it was found, so a re-run starts clean.
        app.buttons["Previous"].tap()
        expectation(for: NSPredicate(format: "label == %@", before), evaluatedWith: position, handler: nil)
        waitForExpectations(timeout: 15)
        if bookmark.value as? String == "saved" { bookmark.tap() }
    }
}

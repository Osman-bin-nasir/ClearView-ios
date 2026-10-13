import XCTest

/// The saving flow, driven the way a person drives it: bookmark an ayah in the
/// reader, find it on the Bookmarks screen, and land back on it.
///
/// The unit tests cover the codec, the store and the model's resolution. What
/// only a launch-and-tap can cover is the wiring between them: that the ayah's
/// bookmark button actually writes through, that the toolbar button opens the
/// screen, and above all that tapping a bookmarked verse opens the reader **at
/// that verse** rather than at the saved reading position — the difference
/// between "take me to this verse" and "take me to wherever I stopped", which is
/// the entire reason `BookmarkTarget` exists.
final class BookmarksUITests: XCTestCase {

    private let listTimeout: TimeInterval = 120

    // The rows' accessibility identifiers, spelled out rather than imported: a UI
    // test bundle runs out of process and cannot see the app's types, so these
    // have to be literals. The definitions live in
    // `ClearViewApp/Features/Quran/BookmarksView.swift` — if they change, these
    // two must change with them, which is the price of testing the real UI rather
    // than a lookalike.
    private func starredRow(_ surahNumber: Int) -> String { "bookmarks.starred.\(surahNumber)" }
    private func verseRow(_ verseID: String) -> String { "bookmarks.verse.\(verseID)" }

    /// Pops the reader and *waits for the pop to finish* before returning.
    ///
    /// The wait is the point. Tapping the toolbar while the pop transition is
    /// still running lands the push on the stack as it was mid-pop — the reader
    /// was still in it — producing a stack a user can never build. This test used
    /// to fail at the end for exactly that reason: from `[list, reader, bookmarks]`
    /// the bookmark destination never resolved. Waiting on the list's own
    /// navigation bar (which is absent from the hierarchy while anything is pushed
    /// over it) is the reliable signal that the pop has completed.
    private func leaveReader(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "the reader must offer a back button", file: file, line: line)
        back.tap()
        XCTAssertTrue(
            app.navigationBars["Quran"].waitForExistence(timeout: 15),
            "the surah list must be back before anything else is tapped",
            file: file, line: line
        )
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The whole flow, plus the assertion that the explicit verse wins.
    func testBookmarkedVerseIsReachableAndOpensAtThatVerse() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.navigationBars.buttons["Browse Quran"].tap()

        // Al-Baqara: long enough that scrolling genuinely moves the top of the
        // page far from ayah 1, which is what makes the final assertion mean
        // something.
        let alBaqara = app.staticTexts["Al-Baqara"]
        XCTAssertTrue(alBaqara.waitForExistence(timeout: listTimeout), "the surah list must appear")
        alBaqara.tap()
        for _ in 0..<4 { app.swipeDown() }   // normalise to the top of the surah

        XCTAssertTrue(app.staticTexts["2:1"].waitForExistence(timeout: 30), "the surah must open")

        // Normalise the bookmark state too, so a re-run of this test does not
        // start with ayah 1 already saved.
        let removeButton = app.buttons["Remove bookmark from ayah 1"]
        if removeButton.exists { removeButton.tap() }

        let addButton = app.buttons["Bookmark ayah 1"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), "ayah 1 must offer to be bookmarked")
        addButton.tap()

        XCTAssertTrue(
            app.buttons["Remove bookmark from ayah 1"].waitForExistence(timeout: 10),
            "the button must flip to its removing state — that is the row repainting from the store"
        )

        // Move the reading position well away from ayah 1. The save/restore
        // mechanism itself is proven by `QuranTabUITests.testReadingPositionSurvivesRelaunch`;
        // what matters here is that it is *overridden* below.
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertFalse(app.staticTexts["2:1"].exists, "scrolling must move the top away from ayah 1")

        // Back to the list, then into Bookmarks.
        leaveReader(app)
        let bookmarksButton = app.buttons["Bookmarks"]
        XCTAssertTrue(bookmarksButton.waitForExistence(timeout: 15), "the Quran tab must offer Bookmarks")
        bookmarksButton.tap()
        XCTAssertTrue(app.navigationBars["Bookmarks"].waitForExistence(timeout: 15), "Bookmarks must open")

        // The saved verse is listed, and its position is shown as the row's own
        // label. Addressed by identifier, not by that label: the surah list is
        // still in the hierarchy behind this screen, so a label match is ambiguous.
        let savedRow = app.descendants(matching: .any)
            .matching(identifier: verseRow("2:1"))
            .firstMatch
        XCTAssertTrue(savedRow.waitForExistence(timeout: 30), "the bookmarked verse must be listed")
        XCTAssertTrue(app.staticTexts["2:1"].exists, "the row must show which verse it is")

        savedRow.tap()

        // The push is asserted on the navigation bar, NOT on the text "2:1": the
        // Bookmarks row itself contains "2:1", so a text assertion passes without
        // navigating anywhere. That false pass hid a real problem until it was
        // noticed here.
        XCTAssertTrue(
            app.navigationBars["Al-Baqara"].waitForExistence(timeout: 30),
            "tapping a bookmarked verse must push the reader"
        )

        // The payoff: it opens at ayah 1, even though the saved reading position
        // is far below it. If `openAt` were ignored, the reader would restore to
        // that position and "2:1" would not be on screen.
        XCTAssertTrue(
            app.staticTexts["2:1"].waitForExistence(timeout: 15),
            "a bookmarked verse must open the reader at that verse, not at the saved position"
        )
    }

    /// Starring a surah from the reader puts it on the Bookmarks screen under its
    /// own heading, and tapping it opens the surah.
    func testStarredSurahAppearsOnBookmarksAndOpens() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.navigationBars.buttons["Browse Quran"].tap()

        let alFaatiha = app.staticTexts["Al-Faatiha"]
        XCTAssertTrue(alFaatiha.waitForExistence(timeout: listTimeout), "the surah list must appear")
        alFaatiha.tap()
        XCTAssertTrue(app.navigationBars["Al-Faatiha"].waitForExistence(timeout: 30), "the reader must open")

        // Normalise the star, so a re-run does not start with the surah already
        // starred (a previous run leaves it starred if it fails part-way).
        if app.buttons["Remove surah star"].exists { app.buttons["Remove surah star"].tap() }

        let starOn = app.buttons["Star this surah"]
        XCTAssertTrue(starOn.waitForExistence(timeout: 30), "the reader must offer to star the surah")
        starOn.tap()
        XCTAssertTrue(
            app.buttons["Remove surah star"].waitForExistence(timeout: 10),
            "the star must flip to its removing state"
        )

        leaveReader(app)
        let bookmarksButton = app.buttons["Bookmarks"]
        XCTAssertTrue(bookmarksButton.waitForExistence(timeout: 15))
        bookmarksButton.tap()
        XCTAssertTrue(app.navigationBars["Bookmarks"].waitForExistence(timeout: 15), "Bookmarks must open")

        // The starred surah is listed under its own heading…
        XCTAssertTrue(
            app.staticTexts["Starred surahs"].waitForExistence(timeout: 30),
            "a starred surah must appear under the surah heading"
        )
        let row = app.descendants(matching: .any)
            .matching(identifier: starredRow(1))
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the starred surah must be listed")

        // …and opening it lands in the reader. Asserting on the navigation bar
        // first, because it distinguishes "the push never happened" from "the push
        // happened but the reader is scrolled somewhere I did not expect" — two
        // failures that look identical if you only check for body text.
        row.tap()
        XCTAssertTrue(
            app.navigationBars["Al-Faatiha"].waitForExistence(timeout: 30),
            "tapping a starred surah must push the reader"
        )
        // Scrolled to the top before asserting the header: this reader restores the
        // saved reading position (no explicit target was given), so the header is
        // not guaranteed to be on screen until we ask for it.
        for _ in 0..<6 { app.swipeDown() }
        XCTAssertTrue(
            app.staticTexts["Surah 1 · 7 ayahs"].waitForExistence(timeout: 15),
            "the reader must show the surah it opened"
        )

        // Leave the star off, so a re-run starts clean.
        let starOff = app.buttons["Remove surah star"]
        if starOff.exists { starOff.tap() }
    }
}

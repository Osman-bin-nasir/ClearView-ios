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

    /// Opens the surah list from the Quran tab.
    ///
    /// The tab opens on the verse page (it is Android's `QuranTab`), and the
    /// magnifier in its bar is the way to the surahs — the same route the Android
    /// reader takes, rather than the "Browse Quran" card the page used to carry.
    /// Waited on, because a cold launch shows the page before the bar's controls
    /// are live: the bar's actions are disabled until there is a verse to act on.
    private func openSurahList(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let search = app.buttons["quran.search"]
        XCTAssertTrue(search.waitForExistence(timeout: listTimeout), "the Quran tab must offer search", file: file, line: line)
        XCTAssertTrue(
            app.staticTexts["quran.verse.position"].waitForExistence(timeout: listTimeout),
            "the bar's actions are live once a verse is on the page",
            file: file, line: line
        )
        search.tap()
        let surahs = app.buttons["quran.section.Surah"]
        XCTAssertTrue(surahs.waitForExistence(timeout: 15))
        surahs.tap()
    }

    /// Scrolls a surah back to its top, and fails if it cannot get there.
    ///
    /// A bounded loop rather than a count of swipes, because a count is a guess
    /// about how much of the surah fits on a screen — and that changed the moment
    /// the reader became a mushaf page: 30-point Arabic at a 2.0 line box is a verse
    /// to a screen, where the old cards fitted two or three.
    ///
    /// The header is the signal: it is the one thing on the page that is only
    /// visible at the very top, and the reader saves the reading position, so a
    /// surah opened from this list may well not start at its first ayah.
    private func scrollToTop(_ app: XCUIApplication, surah: Int, file: StaticString = #filePath, line: UInt = #line) {
        let header = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Surah \(surah) · "))
            .firstMatch
        for _ in 0..<40 where !header.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(
            header.isHittable,
            "the surah must be back at its top before anything below is asserted",
            file: file,
            line: line
        )
    }

    /// The whole flow, plus the assertion that the explicit verse wins.
    func testBookmarkedVerseIsReachableAndOpensAtThatVerse() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        openSurahList(app)

        // Al-Baqara: long enough that scrolling genuinely moves the top of the
        // page far from ayah 1, which is what makes the final assertion mean
        // something.
        let alBaqara = app.staticTexts["Al-Baqara"]
        XCTAssertTrue(alBaqara.waitForExistence(timeout: listTimeout), "the surah list must appear")
        alBaqara.tap()
        // Pushed, then brought back to its top.
        //
        // The push is asserted on the navigation bar first, because "the surah never
        // opened" and "it opened at a saved position I did not scroll back from"
        // look identical if the only check is for body text.
        XCTAssertTrue(
            app.navigationBars["Al-Baqara"].waitForExistence(timeout: 30),
            "tapping a surah must push the reader"
        )
        scrollToTop(app, surah: 2)

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
        XCTAssertTrue(app.textFields["bookmarks.search"].waitForExistence(timeout: 15), "Bookmarks must open")

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
        openSurahList(app)

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
        XCTAssertTrue(app.textFields["bookmarks.search"].waitForExistence(timeout: 15), "Bookmarks must open")

        // The starred surah is listed under its own heading…
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Bookmarked Surahs'")).firstMatch.waitForExistence(timeout: 30),
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

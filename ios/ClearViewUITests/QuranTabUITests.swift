import XCTest

/// Drives the Quran tab the way a person does: the list appears, a surah is
/// tapped, the surah opens and its verses are there.
///
/// This is here because the unit tests cannot see the seam they sit either side
/// of. `QuranRepositoryTests` proves the data arrives; `SurahReaderModelTests`
/// proves the model publishes it. Neither proves that the list actually builds
/// `NavigationLink`s, that tapping one reaches the reader, or that the reader
/// renders verses rather than the first one. Those are exactly the failures a
/// user would hit, and only a launch-and-tap catches them — it caught one
/// already: the reading position was being saved correctly and then not restored.
///
/// The assertions are on text that is *derived*, never hardcoded in the app:
/// "Surah 1 · 7 ayahs" is the ayah count the shared Kotlin parser counted from
/// the downloaded edition. If that string is wrong, the parse is wrong.
final class QuranTabUITests: XCTestCase {

    /// Generous, because the very first launch downloads and parses the full
    /// edition (~3.4 MB across both). Later launches read the cache and are
    /// immediate — this ceiling only has to cover the cold case.
    private let listTimeout: TimeInterval = 120

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The whole slice in one pass: list → tap → every ayah of the surah.
    func testSurahListOpensTheWholeSurah() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(openSurahAtTop("Al-Faatiha", in: app), "the surah list must appear")

        // The header count comes from the parsed edition, and the last ayah
        // proves the reader rendered all 7 — not just the first one it laid out.
        XCTAssertTrue(
            app.staticTexts["Surah 1 · 7 ayahs"].waitForExistence(timeout: 30),
            "the reader header must show the ayah count derived from the edition"
        )
        XCTAssertTrue(app.staticTexts["1:1"].exists, "the first ayah must render")
        XCTAssertTrue(app.staticTexts["1:7"].waitForExistence(timeout: 10), "the last ayah of Al-Faatiha must render")
    }

    /// A long surah opens too, and its header shows the real count (286), which
    /// is the number a hardcoded table would most likely get wrong.
    func testLongSurahOpensWithItsRealAyahCount() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(openSurahAtTop("Al-Baqara", in: app), "the surah list must appear")

        XCTAssertTrue(
            app.staticTexts["Surah 2 · 286 ayahs"].waitForExistence(timeout: 30),
            "Al-Baqara must report its real 286 ayahs"
        )
        XCTAssertTrue(app.staticTexts["2:1"].exists, "the first ayah must render")
    }

    /// The D1 acceptance criterion: the reading position survives a relaunch.
    ///
    /// Only a real relaunch can test this — the store is `UserDefaults` inside the
    /// app's own container, and a unit test with an injected suite proves the
    /// codec, not that the app writes and reads the same place across two launches.
    func testReadingPositionSurvivesRelaunch() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(openSurahAtTop("Al-Baqara", in: app), "the surah list must appear")
        XCTAssertTrue(
            app.staticTexts["2:1"].waitForExistence(timeout: 30),
            "with no saved position the surah must open at its first ayah"
        )

        // Scroll a few screens in, so the top of the page is well past ayah 1.
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertFalse(app.staticTexts["2:1"].exists, "scrolling must move past the first ayah")

        // Leave the reader, then leave the app entirely and come back.
        leaveReader(app)
        app.terminate()
        app.launch()

        let alBaqaraAgain = app.staticTexts["Al-Baqara"]
        XCTAssertTrue(alBaqaraAgain.waitForExistence(timeout: listTimeout), "the surah list must appear again")
        alBaqaraAgain.tap()

        // It must render — and it must NOT be at the first ayah, which is the
        // only observable difference between "restored" and "started over".
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2:'"))
                .firstMatch
                .waitForExistence(timeout: 30),
            "the surah must render after relaunch"
        )
        XCTAssertFalse(
            app.staticTexts["2:1"].exists,
            "the reader must reopen where it was left, not at the first ayah"
        )
    }

    /// Going back returns to the list, so the navigation is real and the tab is
    /// still usable afterwards.
    func testGoingBackReturnsToTheList() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(openSurahAtTop("Al-Faatiha", in: app), "the surah list must appear")
        XCTAssertTrue(app.staticTexts["1:1"].waitForExistence(timeout: 30))

        leaveReader(app)

        // The list is back: its rows are there and the reader's ayah labels are
        // gone. Checking both matters — the list and the reader share the surah
        // name in their text, so the name alone cannot tell them apart.
        XCTAssertTrue(app.staticTexts["Al-Faatiha"].waitForExistence(timeout: 15), "the list must be restored")
        XCTAssertFalse(app.staticTexts["1:1"].exists, "the reader must have been dismissed")
    }

    /// The reader's Arabic text size controls are wired and bounded.
    ///
    /// The size itself cannot be read off a screenshot, but its *bounds* can: the
    /// control that grows the text must switch itself off at the ceiling. That is
    /// what proves the model's published value and the store's clamp agree — if the
    /// model kept growing on its own, the button would still be enabled here.
    func testTheArabicTextSizeControlsAreWiredAndBounded() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(openSurahAtTop("Al-Faatiha", in: app), "the surah list must appear")

        let larger = app.buttons["reader.text.larger"]
        let smaller = app.buttons["reader.text.smaller"]
        XCTAssertTrue(larger.waitForExistence(timeout: 30), "the reader must offer a larger text size")
        XCTAssertTrue(smaller.exists, "the reader must offer a smaller text size")

        // At the default size both directions are available.
        XCTAssertTrue(larger.isEnabled)
        XCTAssertTrue(smaller.isEnabled)

        // Grow it until the control gives up. From 1.0 in steps of 0.2 the ceiling
        // is 2.0, so this is a handful of taps; the loop is generous and the
        // assertion is on the *wait*, not on the count.
        for _ in 0..<8 { larger.tap() }
        expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: larger, handler: nil)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(smaller.isEnabled, "with the text at its largest, smaller must still work")

        // ...and the reader is still showing the surah rather than a blank screen
        // at the biggest size.
        XCTAssertTrue(app.staticTexts["1:1"].exists, "the surah must still render at the largest size")
    }

    // MARK: - Helpers

    /// Opens a surah and scrolls it back to its top.
    ///
    /// The reader remembers where it was left, so a surah opened by a later test
    /// may not start at its first ayah — and the assertions above are about the
    /// top of a surah. Scrolling up also *clears* the saved position (the shared
    /// rule treats ayah 1 as "no position"), so every test starts from the same
    /// state instead of from whatever a previous test left behind.
    /// Pops the reader and waits for the pop to finish.
    ///
    /// The wait is not politeness: tapping anything while the pop transition is
    /// still running acts on the stack as it was mid-pop, with the reader still
    /// in it. Waiting on the list's own navigation bar — which is absent from the
    /// hierarchy while a screen is pushed over it — is the reliable signal that
    /// the pop has completed.
    private func leaveReader(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "the reader must offer a back button", file: file, line: line)
        back.tap()
        XCTAssertTrue(
            app.navigationBars["Quran"].waitForExistence(timeout: 15),
            "the surah list must be back before anything else is done",
            file: file, line: line
        )
    }

    private func openSurahAtTop(_ name: String, in app: XCUIApplication) -> Bool {
        let row = app.staticTexts[name]
        guard row.waitForExistence(timeout: listTimeout) else { return false }

        row.tap()
        guard app.navigationBars[name].waitForExistence(timeout: 30) else { return false }
        for _ in 0..<4 { app.swipeDown() }
        return true
    }
}

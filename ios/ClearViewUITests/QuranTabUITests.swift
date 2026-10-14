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
        app.launchArguments = Self.cleanLaunch
        app.launch()

        XCTAssertTrue(openSurahAtTop("Al-Faatiha", in: app), "the surah list must appear")

        // The header count comes from the parsed edition, and the last ayah
        // proves the reader rendered all 7 — not just the first one it laid out.
        XCTAssertTrue(
            app.staticTexts["Surah 1 · 7 ayahs"].waitForExistence(timeout: 30),
            "the reader header must show the ayah count derived from the edition"
        )
        XCTAssertTrue(app.staticTexts["1:1"].exists, "the first ayah must render")
        // Scrolled to, rather than only looked for: the reader is a lazy list, so
        // "the last ayah renders" is a question about the whole surah and not about
        // how many rows happen to fit on one screen.
        for _ in 0..<2 { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["1:7"].waitForExistence(timeout: 10), "the last ayah of Al-Faatiha must render")
        XCTAssertTrue(app.staticTexts["1:7"].isHittable, "the last ayah must actually be on screen")
    }

    /// A long surah opens too, and its header shows the real count (286), which
    /// is the number a hardcoded table would most likely get wrong.
    func testLongSurahOpensWithItsRealAyahCount() {
        let app = XCUIApplication()
        app.launchArguments = Self.cleanLaunch
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
    func testReadingPositionSurvivesRelaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.cleanLaunch
        app.launch()

        XCTAssertTrue(openSurahAtTop("Al-Baqara", in: app), "the surah list must appear")
        XCTAssertTrue(
            app.staticTexts["2:1"].waitForExistence(timeout: 30),
            "with no saved position the surah must open at its first ayah"
        )

        // Scroll a few screens in, so the top of the page is well past ayah 1.
        // Scrolled until a known ayah is the one on screen, so the assertion after
        // the relaunch has a specific target to demand rather than "not the top".
        for _ in 0..<4 { app.swipeUp() }
        XCTAssertFalse(app.staticTexts["2:1"].isHittable, "scrolling must move the first ayah off screen")
        scrollUntilOnScreen("2:12", in: app)

        // The ayah the reader is looking at when it leaves — the one the relaunch
        // has to bring back.
        //
        // Read off the screen rather than fixed at `2:12`, because the reader saves
        // the ayah at the TOP of the page while the mushaf page shows about a verse
        // to a screen: the verse that was scrolled to and the verse at the top are
        // pages apart, so demanding the fixed one would be demanding that the reader
        // reopen *below* where it was left. The ayah that must come back is the one
        // at the top, which is what is recorded here.
        let leftOn = topVisibleAyah(in: app, surah: 2)
        XCTAssertNotNil(leftOn, "the reader must be able to see which ayah it is on")

        // Leave the reader, then leave the app entirely and come back.
        leaveReader(app)
        app.terminate()
        // Relaunched WITHOUT the reset: a reading position surviving a relaunch is
        // the whole point of this test, and a clean slate would erase what is being
        // asserted.
        app.launchArguments = ["--uitesting"]
        app.launch()

        // The app opens on the verse page, so the surah list is reached the way a
        // reader reaches it: the magnifier in the bar.
        let search = app.buttons["quran.search"]
        XCTAssertTrue(search.waitForExistence(timeout: listTimeout), "the Quran tab must open again")
        search.tap()
        app.buttons["quran.section.Surah"].tap()

        let alBaqaraAgain = app.staticTexts["Al-Baqara"]
        XCTAssertTrue(alBaqaraAgain.waitForExistence(timeout: listTimeout), "the surah list must appear again")
        alBaqaraAgain.tap()

        // It must render — and it must NOT be at the first ayah, which is the
        // only observable difference between "restored" and "started over".
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH '2:'"))
                .firstMatch
                .waitForExistence(timeout: 30),
            "the surah must render after relaunch"
        )
        // The reader must come back to the ayah it was left on — asserted as "that
        // ayah is on screen again" for the reason the test above gives.
        let target = try XCTUnwrap(leftOn)
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: app.staticTexts[target], handler: nil)
        waitForExpectations(timeout: 30)
    }

    /// The reader opens on the ayah the store recorded — the *restore* half alone.
    ///
    /// The position is seeded from outside (`--seed-reading-position 2:13`), so a
    /// failure here is unambiguously a reader that ignored a position rather than a
    /// reader that failed to remember one. The store round-trip itself is covered
    /// by the unit tests and by the two tests below.
    func testTheReaderOpensOnTheRecordedPosition() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--seed-reading-position", "2:13"]
        app.launch()

        XCTAssertTrue(openSurah("Al-Baqara", in: app), "the surah list must appear")

        XCTAssertTrue(
            app.staticTexts["2:13"].waitForExistence(timeout: 30),
            "the reader must show the ayah it was told to open on"
        )
        XCTAssertTrue(app.staticTexts["2:13"].isHittable, "that ayah must be the one on screen")
        XCTAssertFalse(
            app.staticTexts["2:1"].isHittable,
            "the reader must open at the recorded ayah, not at the top of the surah"
        )
    }

    /// Leaving a surah and coming back reopens it where it was left.
    ///
    /// The same rule as the relaunch test below, but without the relaunch: it
    /// isolates "the reader remembers where I was" from "and the memory survives
    /// the app being killed", which are two different failures that look identical
    /// from the outside.
    func testLeavingASurahAndReturningReopensWhereItWasLeft() throws {
        let app = XCUIApplication()
        app.launchArguments = Self.cleanLaunch
        app.launch()

        XCTAssertTrue(openSurahAtTop("Al-Baqara", in: app), "the surah list must appear")
        XCTAssertTrue(app.staticTexts["2:1"].waitForExistence(timeout: 30), "the surah must open at its top")

        for _ in 0..<4 { app.swipeUp() }
        XCTAssertFalse(app.staticTexts["2:1"].isHittable, "scrolling must move the first ayah off screen")

        // What the reader was looking at when they left — read off the screen
        // rather than guessed, and asserted positively afterwards.
        let leftOn = topVisibleAyah(in: app, surah: 2)
        XCTAssertNotNil(leftOn, "the reader must be able to see which ayah they are on")

        leaveReader(app)
        let alBaqaraAgain = app.staticTexts["Al-Baqara"]
        XCTAssertTrue(alBaqaraAgain.waitForExistence(timeout: 15), "the list must be back")
        alBaqaraAgain.tap()

        // The reader must come back to THAT ayah.
        //
        // Written as "the ayah I left on is on screen again", not as "the first ayah
        // is not": a jump to a saved ayah leaves every row above it in the
        // accessibility tree, off screen, so "2:1 is absent" is false either way and
        // reported a working restore as a failure. Asking for the ayah the reader
        // was actually on is both the stronger question and the one that cannot be
        // satisfied by accident.
        let target = try XCTUnwrap(leftOn)
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: app.staticTexts[target], handler: nil)
        waitForExpectations(timeout: 30)
    }

    /// Going back returns to the list, so the navigation is real and the tab is
    /// still usable afterwards.
    func testGoingBackReturnsToTheList() {
        let app = XCUIApplication()
        app.launchArguments = Self.cleanLaunch
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
        app.launchArguments = Self.cleanLaunch
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

    /// The home page is the Android verse page: the surah and its ayah, the
    /// reference with the reader's position inside the surah, the navigation
    /// controls, and the two actions at the bottom.
    ///
    /// The reference string is *derived* — "Surah 1 · Ayah 1 of 7" comes from the
    /// downloaded edition's own ayah count (the shared Kotlin parser counted it),
    /// so a wrong number means a wrong parse rather than a stale literal.
    func testHomePageShowsTheVerseWithItsPosition() {
        let app = XCUIApplication()
        app.launchArguments = Self.cleanLaunch
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Quran Reminder"].waitForExistence(timeout: listTimeout),
            "the Quran tab must open on the verse page"
        )
        // The reference line, and the controls that belong to it. Its label is the
        // spoken form of the same line — "Ayah 3 of 7 in this surah" — which Android
        // gives it too, so a screen reader hears the position once rather than twice.
        XCTAssertTrue(
            app.staticTexts["quran.verse.position"].waitForExistence(timeout: listTimeout),
            "the verse page must state where in the Quran it is"
        )
        XCTAssertTrue(app.buttons["Previous"].exists, "the verse page must offer Previous")
        XCTAssertTrue(app.buttons["Next"].exists, "the verse page must offer Next")
        XCTAssertTrue(app.buttons["New Verse"].exists, "the verse page must offer a new verse")
        XCTAssertTrue(app.buttons["Copy verse"].exists, "the verse page must offer a copy action")
        // The Listen control is revealed by the bar's headphones icon, and is not
        // on the page until it is asked for — which is the whole point of putting
        // it behind a toggle.
        XCTAssertFalse(app.buttons["quran.listen.action"].exists, "Listen must be hidden until the reader asks for it")
        app.buttons["quran.listen.toggle"].tap()
        XCTAssertTrue(
            app.buttons["quran.listen.action"].waitForExistence(timeout: 5),
            "the headphones icon must reveal the Listen control"
        )
        // ...and a second tap puts it away again.
        app.buttons["quran.listen.toggle"].tap()
        XCTAssertFalse(app.buttons["quran.listen.action"].exists, "a second tap must hide it")
    }

    /// The Islamic date sits under the verse with its adjustment target, and the
    /// sheet that opens offers exactly the three choices the rule allows.
    func testIslamicDateOffersTheThreeAdjustments() {
        let app = XCUIApplication()
        app.launchArguments = Self.cleanLaunch
        app.launch()
        XCTAssertTrue(app.staticTexts["Quran Reminder"].waitForExistence(timeout: listTimeout))

        app.buttons["Adjust Islamic date"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["One day back"].waitForExistence(timeout: 10), "the sheet must offer -1")
        XCTAssertTrue(app.staticTexts["The calculated date"].exists, "the sheet must offer the calculated date")
        XCTAssertTrue(app.staticTexts["One day forward"].exists, "the sheet must offer +1")
        app.staticTexts["The calculated date"].tap()
        XCTAssertFalse(app.staticTexts["One day forward"].exists, "choosing must close the sheet")
    }

    /// The bell is the one place the app's notifications live, and the Quran leg
    /// states the reminder's cadence rather than counting towards the badge.
    func testNotificationsSheetStatesTheReminderCadence() {
        let app = XCUIApplication()
        app.launchArguments = Self.cleanLaunch
        app.launch()
        XCTAssertTrue(app.staticTexts["Quran Reminder"].waitForExistence(timeout: listTimeout))

        app.buttons["quran.notifications"].tap()
        XCTAssertTrue(app.staticTexts["Quran reminders"].waitForExistence(timeout: 10), "the sheet must group by kind")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Refreshes automatically every'")).firstMatch.exists,
            "the Quran leg must state the cadence"
        )
    }

    // MARK: - Helpers

    /// The launch arguments for a test that needs a known starting point.
    ///
    /// `--uitesting` keeps the app off the network for identity, and
    /// `--reset-preferences` clears the reader's own state first: the Arabic text
    /// scale, the bookmarks and the reading positions all survive a launch, so a
    /// run that left the scale at its largest would change the layout of the next
    /// one and fail it for a reason that has nothing to do with the app.
    private static let cleanLaunch = ["--uitesting", "--reset-preferences"]

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

    /// The ayah the reader is actually looking at: the smallest-numbered `surah:n`
    /// label currently on screen.
    ///
    /// Addressed by **identifier**, not by label. The reader numbers a verse the
    /// way a mushaf does — the ornament `۝` inside the Arabic — so the visible text
    /// of a verse no longer begins with "2:". `2:12` is still what the verse
    /// answers to, as an accessibility identifier on the verse's own text, and that
    /// is what a test should be reading: the label is scripture now, and the
    /// identifier is the stable name for it.
    private func topVisibleAyah(in app: XCUIApplication, surah: Int) -> String? {
        let prefix = "\(surah):"
        return app.staticTexts.allElementsBoundByIndex
            .filter { $0.isHittable && $0.identifier.hasPrefix(prefix) }
            .compactMap { element -> (String, Int)? in
                guard let number = Int(element.identifier.dropFirst(prefix.count)) else { return nil }
                return (element.identifier, number)
            }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// Scrolls until `label` is on screen (or gives up, and the caller's assertion
    /// says so).
    private func scrollUntilOnScreen(_ label: String, in app: XCUIApplication) {
        for _ in 0..<12 where !app.staticTexts[label].isHittable {
            app.swipeUp()
        }
    }

    /// Opens a surah from the verse page's own search route, leaving it wherever
    /// the reader opens it.
    private func openSurah(_ name: String, in app: XCUIApplication) -> Bool {
        let search = app.buttons["quran.search"]
        if search.waitForExistence(timeout: listTimeout) {
            search.tap()
            guard app.buttons["quran.section.Surah"].waitForExistence(timeout: 15) else { return false }
            app.buttons["quran.section.Surah"].tap()
        }
        let row = app.staticTexts[name]
        guard row.waitForExistence(timeout: listTimeout) else { return false }
        row.tap()
        return app.navigationBars[name].waitForExistence(timeout: 30)
    }

    private func openSurahAtTop(_ name: String, in app: XCUIApplication) -> Bool {
        // The Quran tab opens on the verse page, whose own bar carries the
        // magnifier that opens the surah list — the same route Android's reader
        // takes (Quran tab → search/surah/bookmarks).
        //
        // Waited on rather than checked: a cold launch has the verse page blank
        // for as long as the download takes, and a bare `exists` here would skip
        // the tap and report the surah list as missing.
        if app.buttons["quran.search"].waitForExistence(timeout: listTimeout) {
            app.buttons["quran.search"].tap()
            guard app.buttons["quran.section.Surah"].waitForExistence(timeout: 15) else { return false }
            app.buttons["quran.section.Surah"].tap()
        }
        let row = app.staticTexts[name]
        guard row.waitForExistence(timeout: listTimeout) else { return false }

        row.tap()
        guard app.navigationBars[name].waitForExistence(timeout: 30) else { return false }
        return scrollSurahToTop(in: app)
    }

    /// Brings an open surah back to its top, and says whether it got there.
    ///
    /// Waited for rather than swiped a fixed number of times, because a count of
    /// swipes is a guess about how much of the surah fits on a screen — and that is
    /// a property of the page, not of the reader. The mushaf reader sets 30-point
    /// Arabic at a 2.0 line box, so about a verse to a screen where the old cards
    /// fitted two or three; the same four swipes that reached the top of Al-Baqara
    /// before now land several verses short and fail a test that has nothing to do
    /// with swiping.
    ///
    /// The header is the signal: it is the only thing on the page that is on screen
    /// at the very top and nowhere else.
    private func scrollSurahToTop(in app: XCUIApplication) -> Bool {
        let header = app.staticTexts
            .matching(NSPredicate(format: "label MATCHES %@", "Surah [0-9]+ · [0-9]+ ayahs"))
            .firstMatch
        for _ in 0..<40 where !header.isHittable {
            app.swipeDown()
        }
        return header.isHittable
    }
}

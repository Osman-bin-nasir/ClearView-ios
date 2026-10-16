import XCTest

/// Good Post's saved text, on screen, after a relaunch with no network.
///
/// The unit tests prove the bytes reach the disk and that a repository reads them back. Neither
/// can prove the two things a reader actually cares about: that the *screen* draws them, and
/// that a **relaunch** — a new process, not a new repository — still has them. That is what this
/// test is for, and it is why it launches twice:
///
///  * launch one seeds the device (through the app's own cache and codec) with the updates a
///    previous run would have fetched;
///  * launch two gets **no fixture and no preference reset**, and every request it makes is sent
///    to a port nothing is listening on — so anything on screen came off the disk.
///
/// The dead address is asserted rather than assumed: the screen has to *say* the fetch failed
/// while it shows the saved words, which is what makes "offline" a fact about the run.
final class GoodPostOfflineUITests: XCTestCase {

    private let savedLine = "Saved message one"
    private let savedSecondLine = "Saved message two"
    private let channelName = "Saved Test Channel"
    /// Nothing listens on the discard port, so every request fails immediately and the app
    /// cannot explain the screen with a network read.
    private let deadAddress = "http://127.0.0.1:9"

    override func setUp() {
        continueAfterFailure = false
    }

    func testSavedTextIsShownAfterARelaunchWithNoNetwork() {
        let first = XCUIApplication()
        first.launchArguments = ["--uitesting", "--reset-preferences"]
        first.launchEnvironment["CLEARVIEW_GOODPOST_BASE_URL"] = deadAddress
        first.launchEnvironment["CLEARVIEW_GOODPOST_FIXTURE"] = fixture
        first.launch()

        openChannel(first)
        XCTAssertTrue(app(first, shows: savedLine), "the seeded update should be on screen")
        capture("Good Post saved text", app: first)
        first.terminate()

        // The relaunch: no fixture, no reset. Whatever is here was written by the run above.
        let second = XCUIApplication()
        second.launchArguments = ["--uitesting"]
        second.launchEnvironment["CLEARVIEW_GOODPOST_BASE_URL"] = deadAddress
        second.launch()

        openChannel(second)
        XCTAssertTrue(app(second, shows: savedLine), "saved text must survive a relaunch with no network")
        XCTAssertTrue(app(second, shows: savedSecondLine), "every saved update, not just the newest")
        // And the network really was gone: the screen says so while the updates are readable.
        XCTAssertTrue(app(second, shows: "Couldn't connect. Check your connection and try again."),
                      "the failed fetch should be reported next to the saved text")
        capture("Good Post saved text, offline relaunch", app: second)
    }

    /// Opens Good Post and the seeded channel, and returns once the channel's screen is up.
    private func openChannel(_ app: XCUIApplication) {
        app.tabBars.buttons["Good Post"].tap()
        let row = app.staticTexts[channelName]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the saved channel should be listed")
        row.tap()
        XCTAssertTrue(app.staticTexts[savedLine].waitForExistence(timeout: 30))
    }

    private func app(_ app: XCUIApplication, shows text: String) -> Bool {
        app.staticTexts[text].waitForExistence(timeout: 10)
    }

    private func capture(_ title: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// What a channel's posts look like once they have been fetched — the shape the server
    /// sends, seeded through the app's own codec.
    private var fixture: String {
        """
        {"channels":{"items":[{"id":"chan-saved","slug":"saved","name":"\(channelName)","createdAt":"2026-10-16T08:00:00.000Z"}]},
         "posts":{"chan-saved":{"items":[
           {"id":"saved-1","channelId":"chan-saved","type":"text","body":"\(savedLine)","createdAt":"2026-10-16T10:00:00.000Z","views":3},
           {"id":"saved-2","channelId":"chan-saved","type":"text","body":"\(savedSecondLine)","createdAt":"2026-10-16T09:00:00.000Z","views":1}
         ],"nextCursor":null}}}
        """
    }
}

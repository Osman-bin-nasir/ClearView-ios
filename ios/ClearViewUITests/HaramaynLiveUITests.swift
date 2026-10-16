import XCTest

/// Haramayn Live, end to end and against the real network.
///
/// This is the only check that can prove the two things a unit test cannot: that
/// the app's own URLSession stack actually gets a live broadcast id out of
/// YouTube on the device (the desktop user agent, the header set and the page
/// decoding have to survive YouTube's real response), and that the resolved id
/// really plays in the in-app embed.
///
/// It is deliberately tolerant about WHO plays it: a WKWebView may refuse the
/// embed's autoplay, and the reader's recourse then is the Play control — which
/// is a real part of the screen, so the test uses it too rather than failing on
/// a platform policy.
final class HaramaynLiveUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testHaramaynPlaysMakkahAndMadinahInsideTheApp() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-preferences"]
        app.launch()
        app.tabBars.buttons["Media"].tap()
        XCTAssertTrue(app.staticTexts["All Feed"].waitForExistence(timeout: 30))

        let strip = app.scrollViews["media.channels.strip"]
        let entry = app.staticTexts["Haramayn"]
        for _ in 0..<4 where !entry.isHittable { strip.swipeLeft() }
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()

        XCTAssertTrue(app.navigationBars["Haramayn"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["haramayn.status"].waitForExistence(timeout: 20))
        // The selector is above the player and the Makkah tab starts selected.
        XCTAssertTrue(app.buttons["haramayn.location.makkah"].exists)
        waitForPlayback(app, location: "Makkah")
        capture("Haramayn Makkah Live", app: app)

        // Madinah: the same discovery + validation path for the other channel.
        app.buttons["haramayn.location.madinah"].tap()
        XCTAssertTrue(app.staticTexts["Al-Masjid an-Nabawi · Live from Madinah"].waitForExistence(timeout: 20))
        waitForPlayback(app, location: "Madinah")
        capture("Haramayn Madinah Live", app: app)

        // And back: switching location must not leave a dead player.
        app.buttons["haramayn.location.makkah"].tap()
        waitForPlayback(app, location: "Makkah (again)")
        capture("Haramayn Makkah Live again", app: app)
    }

    /// Waits until the screen reports the broadcast is playing. Autoplay is
    /// attempted first (the embed asks for it); if it was refused, the screen's own
    /// Play control is tapped, which is what a reader would do.
    private func waitForPlayback(_ app: XCUIApplication, location: String, timeout: TimeInterval = 180) {
        let status = app.staticTexts["haramayn.status"]
        let playing = NSPredicate(format: "label == %@", "Live · playing inside the app")
        let deadline = Date().addingTimeInterval(timeout)
        var nudgedAutoplay = false
        while Date() < deadline {
            if playing.evaluate(with: status) { return }
            if !nudgedAutoplay, app.buttons["Play"].exists, !app.buttons["haramayn.retry"].exists {
                nudgedAutoplay = true
                app.buttons["Play"].tap()
            }
            usleep(500_000)
        }
        let shown = status.exists ? status.label : "no status on screen"
        XCTFail("\(location) never started playing inside the app. Screen said: \(shown)")
    }

    private func capture(_ title: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

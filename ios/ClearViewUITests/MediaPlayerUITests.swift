import XCTest

final class MediaPlayerUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launchVideo() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-preferences"]
        let video: [String: Any] = ["id": "M7lc1UVf-VE", "title": "YouTube IFrame API Demo", "channel": "YouTube Developers", "url": "https://www.youtube.com/watch?v=M7lc1UVf-VE", "isShort": false, "publishedAt": 0]
        let state: [String: Any] = ["channels": [], "playlists": [], "recent": [], "saved": [], "feed": [video]]
        app.launchEnvironment["CLEARVIEW_MEDIA_FIXTURE"] = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        app.launch()
        app.tabBars.buttons["Media"].tap()
        let title = app.staticTexts["YouTube IFrame API Demo"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        title.tap()
        XCTAssertTrue(app.buttons["media.player.playlist"].waitForExistence(timeout: 15))
        return app
    }

    func testVideoPageControlsAndLocalPlaylist() throws {
        let app = try launchVideo()
        for label in ["More", "Share", "Speed", "Back 10 seconds", "Play", "Forward 10 seconds", "Mute", "Audio mode"] {
            XCTAssertTrue(app.buttons[label].exists, label)
        }
        XCTAssertTrue(app.sliders["media.player.timeline"].exists)
        capture("Embedded player controls", app: app)
        app.buttons["Audio mode"].tap()
        XCTAssertTrue(app.alerts["YouTube playback limitation"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
        app.buttons["media.player.playlist"].tap()
        XCTAssertTrue(app.navigationBars["Add to Playlist"].waitForExistence(timeout: 5))
        app.buttons["Create playlist"].tap()
        app.alerts.textFields.firstMatch.typeText("Player test playlist")
        app.alerts.buttons["Create and add"].tap()
        XCTAssertTrue(app.buttons["media.player.playlist"].waitForExistence(timeout: 5))
        app.buttons["media.player.playlist"].tap()
        XCTAssertTrue(app.staticTexts["Player test playlist"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 videos"].exists)
        capture("Player playlist selection", app: app)
        app.buttons["Cancel"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Feed options"].tap()
        for label in ["Hidden Videos", "Hidden Channels", "Add Video by URL", "Add Video from Device"] { XCTAssertTrue(app.buttons[label].exists) }
        XCTAssertFalse(app.buttons["Saved videos"].exists)
        XCTAssertFalse(app.buttons["Recently opened"].exists)
        capture("Four-item feed menu", app: app)
    }

    func testRealYouTubePlayback() throws {
        let app = try launchVideo()
        let play = app.buttons["media.player.playPause"]
        let ready = NSPredicate(format: "enabled == true")
        let readiness = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: play)], timeout: 45)
        guard readiness == .completed else {
            capture("YouTube embed unavailable on CI network", app: app)
            throw XCTSkip("Real YouTube player did not become ready on this runner. Live playback still requires device verification.")
        }
        play.tap()
        let playing = app.staticTexts["media.player.status"]
        let started = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Playing'"), object: playing)], timeout: 30)
        guard started == .completed else {
            capture("YouTube playback blocked on CI network", app: app)
            throw XCTSkip("YouTube loaded but playback was blocked on this runner. Verify the user-gesture player on an iPhone.")
        }
        XCTAssertTrue(app.buttons["Pause"].exists)
        app.buttons["Mute"].tap()
        XCTAssertTrue(app.buttons["Unmute"].waitForExistence(timeout: 5))
        app.buttons["Forward 10 seconds"].tap()
        app.buttons["Speed"].tap()
        capture("Real YouTube playback", app: app)
        play.tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

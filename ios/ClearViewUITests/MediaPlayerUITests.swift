import XCTest

final class MediaPlayerUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launchVideo() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-preferences"]
        let video: [String: Any] = ["id": "M7lc1UVf-VE", "title": "YouTube IFrame API Demo", "channel": "YouTube Developers", "url": "https://www.youtube.com/watch?v=M7lc1UVf-VE", "isShort": false, "publishedAt": Int64(Date().timeIntervalSince1970 * 1000)]
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
        for label in ["Back 10 seconds", "Forward 10 seconds", "Audio mode"] {
            XCTAssertTrue(app.buttons[label].exists, label)
        }
        for identifier in ["more", "share", "speed"] { XCTAssertTrue(app.buttons["media.player.\(identifier)"].exists) }
        XCTAssertTrue(app.buttons["media.player.playPause"].exists)
        XCTAssertTrue(app.buttons["media.player.mute"].exists)
        XCTAssertTrue(app.sliders["media.player.timeline"].exists)
        capture("Embedded player controls", app: app)
        // Audio mode is a real pipeline now — it resolves an audio-only stream and opens the
        // player — so the alert that declared the capability unavailable is asserted ABSENT
        // rather than expected. This assertion changed with the behaviour, by request: it used
        // to pin "audio extraction is not available in this iOS build", which is no longer true.
        //
        // The player itself is deliberately NOT required here. Resolving a stream is
        // network-bound and YouTube refuses datacenter addresses, so on a runner the honest
        // outcome is either the player or a stated error — and requiring the player would make
        // this test flaky for a reason that has nothing to do with the app. What IS required is
        // that the app stops claiming the capability does not exist. Device-level extraction is
        // covered by MediaAudioLiveTests, which is skipped unless asked for.
        app.buttons["Audio mode"].tap()
        XCTAssertFalse(
            app.alerts["YouTube playback limitation"].waitForExistence(timeout: 5),
            "Audio mode must not report the capability as unavailable"
        )
        // Clear anything the tap presented before the playlist steps below.
        if app.buttons["Done"].waitForExistence(timeout: 2) { app.buttons["Done"].tap() }
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
        if play.label == "Play" { play.tap() }
        let playing = app.staticTexts["media.player.status"]
        let started = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Playing'"), object: playing)], timeout: 30)
        guard started == .completed else {
            capture("YouTube playback blocked on CI network", app: app)
            throw XCTSkip("YouTube loaded but playback was blocked on this runner. Verify the user-gesture player on an iPhone.")
        }
        XCTAssertTrue(app.buttons["Pause"].exists)
        if app.buttons["media.player.mute"].label == "Unmute" { app.buttons["media.player.mute"].tap() }
        app.buttons["media.player.mute"].tap()
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

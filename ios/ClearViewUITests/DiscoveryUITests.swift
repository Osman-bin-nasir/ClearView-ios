import XCTest

final class DiscoveryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testQuranSearchSurahsAndBookmarks() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-preferences"]
        app.launch()
        XCTAssertTrue(app.staticTexts["quran.verse.position"].waitForExistence(timeout: 120))
        app.buttons["quran.search"].tap()
        XCTAssertTrue(app.buttons["quran.section.Search"].waitForExistence(timeout: 15))
        let search = app.textFields["discovery.search"]
        search.tap()
        search.typeText("2:255\n")
        let result = app.buttons["quran.result.2:255"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        capture("Quran Search", app: app)
        result.tap()
        XCTAssertTrue(app.navigationBars["Al-Baqara"].waitForExistence(timeout: 15))
        app.buttons["BackButton"].tap()
        app.buttons["quran.section.Surah"].tap()
        XCTAssertTrue(app.buttons["quran.surah.1"].waitForExistence(timeout: 15))
        app.buttons["Favorite Al-Faatiha"].tap()
        capture("Quran Surahs", app: app)
        app.buttons["quran.section.Bookmarks"].tap()
        XCTAssertTrue(app.textFields["bookmarks.search"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["bookmarks.starred.1"].waitForExistence(timeout: 15))
        capture("Quran Bookmarks", app: app)
    }

    func testMediaFeedFiltersAndChannelPlatforms() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-preferences"]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let channel: [String: Any] = ["id": "fixture-channel", "platform": "youtube", "handle": "fixture", "name": "UI test channel", "url": "https://www.youtube.com/@fixture", "sort": 0]
        func video(_ identifier: String, title: String, short: Bool = false) -> [String: Any] {
            ["id": identifier, "title": title, "channel": "UI test channel", "channelID": "fixture-channel", "url": "https://www.youtube.com/watch?v=\(identifier)", "isShort": short, "publishedAt": now, "durationSeconds": short ? 45 : 300]
        }
        let started = video("started", title: "Continue watching test video")
        let short = video("short", title: "Shorts test video", short: true)
        let long = video("long", title: "Regular test video")
        let state: [String: Any] = ["channels": [channel], "playlists": [], "recent": [started], "saved": [], "feed": [started, short, long],
            "watchProgress": ["started": ["position": 60, "duration": 300, "updatedAt": Date().timeIntervalSinceReferenceDate]]]
        let data = try JSONSerialization.data(withJSONObject: state)
        app.launchEnvironment["CLEARVIEW_MEDIA_FIXTURE"] = String(decoding: data, as: UTF8.self)
        app.launch()
        app.tabBars.buttons["Media"].tap()
        XCTAssertTrue(app.staticTexts["All Feed"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Continue Watching"].exists)
        XCTAssertTrue(app.staticTexts["Shorts"].exists)
        capture("Media Feed", app: app)
        for _ in 0..<3 {
            if app.staticTexts["Regular test video"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["Regular test video"].waitForExistence(timeout: 10))
        capture("Media Videos", app: app)
        app.swipeDown()
        app.swipeDown()
        app.buttons["media.filters"].tap()
        XCTAssertTrue(app.navigationBars["Filter"].waitForExistence(timeout: 10))
        for title in ["Date", "Platform", "Content", "Source", "Watch status", "Sort by"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "media.filter.\(title)").firstMatch.exists)
        }
        capture("Media Filters", app: app)
        app.descendants(matching: .any).matching(identifier: "media.filter.Platform").firstMatch.tap()
        app.buttons["Instagram"].tap()
        capture("Media Platform Filter", app: app)
        app.buttons["Cancel"].tap()
        app.buttons["media.search"].tap()
        let search = app.textFields["media.search.field"]
        search.tap()
        search.typeText("Regular\n")
        XCTAssertTrue(app.staticTexts["Regular test video"].exists)
        XCTAssertFalse(app.staticTexts["Shorts test video"].exists)
        app.buttons["media.search"].tap()
        app.swipeDown()
        let channels = app.scrollViews["media.channels.strip"]
        channels.swipeLeft()
        let add = app.buttons["Add channel"]
        if !add.isHittable { channels.swipeLeft() }
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(app.navigationBars["Add channel / profile"].waitForExistence(timeout: 10))
        for platform in ["YouTube", "Instagram", "X"] { XCTAssertTrue(app.buttons[platform].exists) }
        app.buttons["Instagram"].tap()
        XCTAssertTrue(app.textFields["media.channel.input"].exists)
        capture("Add Media Channel", app: app)
    }

    /// The ✕ on a channel avatar, end to end: it is there, one tap asks first, the tap
    /// never doubles as "filter the feed", and Remove really removes.
    ///
    /// Worth a UI test rather than a unit test because the ✕ is an overlay ON the
    /// avatar's own button, and the whole point of building it that way is hit testing:
    /// a button nested in another button's label can fire both actions, which would
    /// remove a channel because the avatar was tapped.
    func testMediaChannelRemoveBadgeAsksBeforeRemoving() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-preferences"]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let channel: [String: Any] = ["id": "fixture-channel", "platform": "youtube", "handle": "fixture", "name": "UI test channel", "url": "https://www.youtube.com/@fixture", "sort": 0]
        let video: [String: Any] = ["id": "fixture-video", "title": "Fixture video", "channel": "UI test channel", "channelID": "fixture-channel", "url": "https://www.youtube.com/watch?v=fixture-video", "isShort": false, "publishedAt": now, "durationSeconds": 120]
        let state: [String: Any] = ["channels": [channel], "playlists": [], "recent": [], "saved": [], "feed": [video]]
        app.launchEnvironment["CLEARVIEW_MEDIA_FIXTURE"] = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        app.launch()
        app.tabBars.buttons["Media"].tap()
        XCTAssertTrue(app.staticTexts["All Feed"].waitForExistence(timeout: 20))

        let strip = app.scrollViews["media.channels.strip"]
        let remove = app.buttons["media.channel.remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        // The first channel sits at the strip's right edge, so its ✕ starts half past the
        // scroll view's bounds — and a tap out there lands outside the scroll view, on
        // nothing. Scroll until the whole badge is inside the strip, which is also what a
        // thumb does before tapping it.
        for _ in 0..<4 where !strip.frame.contains(remove.frame) { strip.swipeLeft() }
        XCTAssertTrue(strip.frame.contains(remove.frame))

        remove.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let alert = app.alerts["Remove channel?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        // The bare ✕ must not remove anything on its own, and must not have selected the
        // channel instead either: the feed is still on "All Feed" while the question is
        // on screen.
        XCTAssertTrue(app.staticTexts["All Feed"].exists)
        capture("Media Channel Remove Prompt", app: app)
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["All Feed"].exists)

        remove.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.alerts["Remove channel?"].waitForExistence(timeout: 10))
        app.alerts.buttons["Remove"].tap()
        waitUntilGone(remove)
        XCTAssertEqual(app.buttons.matching(identifier: "media.channel.remove").count, 0)
    }

    /// XCUIElement has no "disappears" wait on the deployment target this suite builds
    /// for, so poll: a removal is asynchronous (the strip re-renders from state).
    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline {
            usleep(200_000)
        }
    }

    private func capture(_ title: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

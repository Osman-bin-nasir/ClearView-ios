import XCTest

final class AppFlowsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testFourTabsAndCaptureScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        // The Quran tab draws its own Material-style bar rather than a navigation
        // bar (it is a port of Android's `TopAppBar`), so its title is a label in
        // the page rather than a navigation-bar title.
        XCTAssertTrue(app.staticTexts["Quran Reminder"].waitForExistence(timeout: 10))
        capture("Quran", app: app)
        for tab in ["Media", "Good Post", "More"] {
            app.tabBars.buttons[tab].tap()
            XCTAssertTrue(app.navigationBars[tab].waitForExistence(timeout: 10))
            capture(tab, app: app)
        }
        XCTAssertTrue(app.staticTexts["Your daily tools"].exists)
        XCTAssertFalse(app.staticTexts["Coming soon"].exists)
    }

    func testTaskPersistsAcrossLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.tabBars.buttons["More"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Todo'")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Todo"].waitForExistence(timeout: 10))
        app.buttons["Add task"].tap()
        let title = "Read for ten minutes \(UUID().uuidString.prefix(5))"
        let field = app.textFields["todo.title"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(title)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        capture("Todo", app: app)
        app.terminate()
        app.launch()
        app.tabBars.buttons["More"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Todo'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
    }

    func testDhikrCounterAndPlaylistCreation() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.tabBars.buttons["More"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Dhikr Counter'")).firstMatch.tap()
        let counter = app.buttons["dhikr.count"]
        XCTAssertTrue(counter.waitForExistence(timeout: 10))
        let before = counter.label
        counter.tap()
        XCTAssertNotEqual(counter.label, before)
        capture("Dhikr", app: app)
        app.tabBars.buttons["Media"].tap()
        app.buttons["Playlists"].tap()
        app.buttons["New playlist"].tap()
        let name = "Mindful learning \(UUID().uuidString.prefix(5))"
        app.alerts.textFields.firstMatch.typeText(name)
        app.alerts.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

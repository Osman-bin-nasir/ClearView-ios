import XCTest

/// The Protection tab, driven the way a person drives it: open it from More, set the
/// password, add a rule, then come back and get through the lock.
///
/// These run against the real app on a real device, so they are the only check that the
/// tab's screens are reachable, that the lock is a lock, and that a rule added in one
/// launch is there in the next. A unit test can prove the store round-trips; only this can
/// prove the screen does.
final class ProtectionUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// The whole journey: set a password, add a keyword and a website, relaunch, get
    /// through the lock, and find the rules still there.
    func testSetPasswordAddRulesAndUnlockAfterRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-preferences"]
        app.launch()
        openProtection(app)

        // No password yet. A mismatched confirmation is reported and the tab stays shut:
        // a lock that opens on a typo is not a lock.
        let password = app.secureTextFields["protection.new-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10), "the tab should offer to set a password")
        password.tap()
        password.typeText("1234")
        let confirmation = app.secureTextFields["protection.confirm-password"]
        confirmation.tap()
        confirmation.typeText("4321")
        app.buttons["protection.set-password-confirm"].tap()
        XCTAssertTrue(
            app.staticTexts["protection.password-error"].waitForExistence(timeout: 5),
            "a mismatched confirmation must be reported, not accepted"
        )
        XCTAssertFalse(
            app.buttons["protection.keywords-card"].exists,
            "a failed set must not open the tab"
        )

        // Start again with a clean slate rather than editing two secure fields in place —
        // a relaunch is the same state a person would be in, and it exercises the store.
        app.terminate()
        app.launchArguments = ["--uitesting"]
        app.launch()
        openProtection(app)

        let fresh = app.secureTextFields["protection.new-password"]
        XCTAssertTrue(fresh.waitForExistence(timeout: 10))
        fresh.tap()
        fresh.typeText("1234")
        let freshConfirmation = app.secureTextFields["protection.confirm-password"]
        freshConfirmation.tap()
        freshConfirmation.typeText("1234")
        app.buttons["protection.set-password-confirm"].tap()

        // The card list is up.
        let keywordsCard = app.buttons["protection.keywords-card"]
        XCTAssertTrue(keywordsCard.waitForExistence(timeout: 10), "the tab should open once a password is set")

        keywordsCard.tap()
        let keywordField = app.textFields["protection.add-keyword"]
        XCTAssertTrue(keywordField.waitForExistence(timeout: 5))
        keywordField.tap()
        keywordField.typeText("drama")
        app.buttons["protection.add-keyword-button"].tap()
        XCTAssertTrue(app.staticTexts["drama"].waitForExistence(timeout: 5), "the keyword should be listed")
        app.buttons["Done"].tap()

        let blockedItems = app.buttons["protection.blocked-items-card"]
        XCTAssertTrue(blockedItems.waitForExistence(timeout: 5))
        blockedItems.tap()
        let websiteField = app.textFields["protection.add-website"]
        XCTAssertTrue(websiteField.waitForExistence(timeout: 5))
        websiteField.tap()
        websiteField.typeText("example.com")
        app.buttons["protection.add-website-button"].tap()
        XCTAssertTrue(app.staticTexts["example.com"].waitForExistence(timeout: 5), "the website should be listed")
        capture("Protection lists", app: app)
        app.buttons["Done"].tap()

        // Relaunch: the password and the rules both persist, and the tab is locked again.
        app.terminate()
        app.launchArguments = ["--uitesting"]
        app.launch()
        openProtection(app)

        let gate = app.secureTextFields["protection.password-field"]
        XCTAssertTrue(gate.waitForExistence(timeout: 10), "the tab must be locked after a relaunch")
        gate.tap()
        gate.typeText("9999")
        app.buttons["protection.unlock"].tap()
        XCTAssertTrue(
            app.staticTexts["protection.password-error"].waitForExistence(timeout: 5),
            "a wrong password must not open the tab"
        )

        gate.tap()
        gate.typeText("1234")
        app.buttons["protection.unlock"].tap()
        XCTAssertTrue(
            app.staticTexts["1 keyword · 1 website"].waitForExistence(timeout: 10),
            "both rules should still be there after the relaunch"
        )
        capture("Protection unlocked", app: app)
    }

    /// The hero switch gates the features below it: while protection is off their switches
    /// are disabled, and turning it on unlocks them.
    func testTheHeroSwitchGatesTheFeatureSwitches() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-preferences"]
        app.launch()
        openProtection(app)

        // The gate is in the way first, as on Android: the tab is set up behind its
        // password rather than shown unprotected.
        let setup = app.secureTextFields["protection.new-password"]
        XCTAssertTrue(setup.waitForExistence(timeout: 10), "the gate should ask for a password on first use")
        setup.tap()
        setup.typeText("1234")
        let confirm = app.secureTextFields["protection.confirm-password"]
        confirm.tap()
        confirm.typeText("1234")
        app.buttons["protection.set-password-confirm"].tap()

        let hero = app.switches["protection.protection-switch"]
        XCTAssertTrue(hero.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Off — turn on to filter"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Protection is off — the switches below unlock once it is on."].exists,
            "the locked hint should be up while protection is off"
        )

        hero.tap()
        XCTAssertTrue(
            waitFor { app.staticTexts["Active — filtering inside ClearView"].exists },
            "the hero card should report protection as active"
        )
        XCTAssertTrue(
            waitFor { !app.staticTexts["Protection is off — the switches below unlock once it is on."].exists },
            "the locked hint should go when protection is on"
        )

        // The features below are unlocked now. They are further down the page, so bring
        // them into view before asking the accessibility tree about them.
        let strict = app.switches["protection.strict-mode-switch"]
        XCTAssertTrue(strict.waitForExistence(timeout: 5))
        if !strict.isHittable { app.swipeUp() }
        XCTAssertTrue(waitFor { strict.isEnabled }, "turning protection on should unlock the features below it")

        strict.tap()
        XCTAssertTrue(
            waitFor { (strict.value as? String) == "1" },
            "the strict mode switch should turn on; its value is \(String(describing: strict.value))"
        )
        capture("Protection switches", app: app)
    }

    // MARK: - Helpers

    private func openProtection(_ app: XCUIApplication) {
        app.tabBars.buttons["More"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Protection'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the More tab should offer Protection")
        row.tap()
        XCTAssertTrue(app.navigationBars["Protection"].waitForExistence(timeout: 10))
    }

    /// Poll a condition, because SwiftUI state changes are not instant.
    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(100_000)
        }
        return condition()
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

import XCTest
@testable import ClearView

/// The Protection model: the gate in front of the tab, the switches behind it, and the
/// record it keeps of what it blocked.
///
/// The model is what the tab's screens bind to, so these are the checks that the screens'
/// state is derived from the store rather than invented — and that the lock is a lock.
@MainActor
final class ProtectionModelTests: XCTestCase {

    private var suiteName = ""
    private var model: ProtectionModel!

    override func setUp() {
        super.setUp()
        suiteName = "ProtectionModelTests-\(UUID().uuidString)"
        model = makeModel()
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeModel() -> ProtectionModel {
        ProtectionModel(
            store: ProtectionStore(defaults: UserDefaults(suiteName: suiteName)!),
            // An unconfigured client, so no test can reach the network by accident.
            client: GlobalBlocklistClient(baseUrl: { "" }),
            anonymousId: AnonymousIdStore(defaults: UserDefaults(suiteName: suiteName)!)
        )
    }

    // MARK: - The gate

    /// The tab opens locked — Android's own gate: the dashboard is set up behind its
    /// password rather than shown unprotected first.
    func testTheTabStartsLockedAndAsksForAPasswordFirst() {
        XCTAssertTrue(model.isLocked)
        XCTAssertTrue(model.isSettingUpPassword, "with no password, the gate sets one rather than asking for one")
        XCTAssertFalse(model.hasPassword)
    }

    /// Setting a password needs a match, a minimum length, and unlocks the session it was
    /// set in — asking for the password twice for one decision would be its own bug.
    func testSettingAPassword() {
        XCTAssertNotNil(model.setPassword("12", confirmation: "12"), "too short")
        XCTAssertNotNil(model.setPassword("1234", confirmation: "4321"), "mismatched")
        XCTAssertTrue(model.isLocked, "a refused password must not open the tab")
        XCTAssertFalse(model.hasPassword)

        XCTAssertNil(model.setPassword("1234", confirmation: "1234"))
        XCTAssertTrue(model.hasPassword)
        XCTAssertFalse(model.isLocked, "the session that set the password is already through the gate")
        XCTAssertFalse(model.isSettingUpPassword)
    }

    /// Leaving the screen re-locks it, and only the right password gets back in.
    func testLockingAndUnlocking() {
        XCTAssertNil(model.setPassword("1234", confirmation: "1234"))

        model.lock()
        XCTAssertTrue(model.isLocked)

        XCTAssertFalse(model.unlock(with: "9999"))
        XCTAssertTrue(model.isLocked, "a wrong password leaves the tab shut")

        XCTAssertTrue(model.unlock(with: "1234"))
        XCTAssertFalse(model.isLocked)
    }

    /// A tab with no password never re-locks: there is nothing to ask for, and locking it
    /// would strand the owner outside their own settings.
    func testATabWithoutAPasswordDoesNotLock() {
        XCTAssertNil(model.setPassword("1234", confirmation: "1234"))
        model.removePassword()
        XCTAssertFalse(model.hasPassword)

        model.lock()
        XCTAssertFalse(model.isLocked)
        XCTAssertTrue(model.isSettingUpPassword)
    }

    // MARK: - The switches

    /// The hero switch is stored, so it survives the screen and the launch — and the
    /// feature switches below it hang off it.
    func testTheHeroSwitchWritesThroughToTheStore() {
        XCTAssertFalse(model.protectionEnabled)
        model.protectionEnabled = true
        XCTAssertTrue(model.protectionEnabled)
        XCTAssertTrue(makeModel().protectionEnabled, "a new model over the same store reads it back")

        XCTAssertTrue(model.enforcementOptions.protectionEnabled)
        XCTAssertTrue(makeModel().enforcementOptions.protectionEnabled, "and a new model reads the same switch")
    }

    /// The switches are the store's, not the screen's.
    func testTheFeatureSwitchesAreTheStoredOnes() {
        XCTAssertNil(model.setPassword("1234", confirmation: "1234"))
        XCTAssertFalse(model.enforcementOptions.youTubeProtection)
        model.youTubeProtection = true
        model.blockShorts = true
        model.strictMode = true

        let options = model.enforcementOptions
        XCTAssertTrue(options.youTubeProtection)
        XCTAssertTrue(options.blockShorts)
        XCTAssertTrue(options.strictMode)
        XCTAssertTrue(makeModel().youTubeProtection, "and they persist")
    }

    /// Mutating a setting must **notify observation**, or every screen bound to this model
    /// would keep showing the old value: the switch would not move, the list would not
    /// grow, and the store on disk would be the only thing that changed. That is a bug no
    /// amount of store-level testing can see, so it is pinned here.
    func testChangingASettingNotifiesObservers() {
        let notified = expectation(description: "observation fired")
        withObservationTracking {
            _ = model.protectionEnabled
        } onChange: {
            notified.fulfill()
        }

        model.protectionEnabled = true
        wait(for: [notified], timeout: 2)
    }

    /// The same for the feature switches, which a screen reads one level down from the
    /// hero card.
    func testChangingAFeatureSwitchNotifiesObservers() {
        let strict = expectation(description: "observation fired for strict mode")
        withObservationTracking {
            _ = model.strictMode
        } onChange: {
            strict.fulfill()
        }
        model.strictMode = true
        wait(for: [strict], timeout: 2)

        let keywords = expectation(description: "observation fired for the keyword list")
        withObservationTracking {
            _ = model.youTubeKeywords
        } onChange: {
            keywords.fulfill()
        }
        model.addYouTubeKeyword("drama")
        wait(for: [keywords], timeout: 2)
    }

    /// The gate has to be observable too: unlocking must redraw the tab, or the password
    /// is accepted and nothing happens — which is how this looked from the phone.
    func testUnlockingNotifiesObservers() {
        XCTAssertNil(model.setPassword("1234", confirmation: "1234"))
        model.lock()

        let notified = expectation(description: "observation fired for the lock")
        withObservationTracking {
            _ = model.isLocked
        } onChange: {
            notified.fulfill()
        }

        XCTAssertTrue(model.unlock(with: "1234"))
        wait(for: [notified], timeout: 2)
    }

    /// Recording a block has to redraw the dashboard, or the Activity card keeps saying
    /// "Nothing blocked yet" while the log fills up.
    func testRecordingABlockNotifiesObservers() {
        let notified = expectation(description: "observation fired for the activity")
        withObservationTracking {
            _ = model.activitySummary
        } onChange: {
            notified.fulfill()
        }

        model.recordBlock(BlockDecision(matched: "drama", category: "Your keywords"))
        wait(for: [notified], timeout: 2)
    }

    // MARK: - Rules

    /// The compiled rules are rebuilt when a rule changes and reused in between — the
    /// difference is invisible from the outside, which is the point: a screen that asked
    /// twice would get the same answer.
    func testTheCompiledRulesFollowTheStore() {
        XCTAssertTrue(model.rules().userKeywords.isEmpty)
        model.addUserKeyword("drama")
        XCTAssertEqual(model.rules().userKeywords.map(\.original), ["drama"])
        XCTAssertEqual(model.rules().userKeywords.map(\.original), ["drama"], "and again, unchanged")

        model.addYouTubeKeyword("prank")
        XCTAssertEqual(model.rules().youTubeKeywords.map(\.original), ["prank"])
        XCTAssertEqual(model.rules().userKeywords.map(\.original), ["drama"], "the YouTube list stays its own")
    }

    // MARK: - Recording what was blocked

    /// A blocked item is counted once, with its reason — and a redraw of the same list is
    /// not a second block. This is the rule that keeps the dashboard honest: a view that
    /// recomputes its list must not inflate the count it exists to report.
    func testABlockIsRecordedOncePerSubject() {
        XCTAssertNil(model.setPassword("1234", confirmation: "1234"))
        model.protectionEnabled = true

        let subjects = [
            ProtectionSubject(id: "blocked", title: "free porn compilation"),
            ProtectionSubject(id: "fine", title: "an ordinary video"),
        ]
        let enforcement = model.enforcement(for: subjects)
        XCTAssertEqual(enforcement.hiddenCount, 1)

        model.noteHidden(enforcement.hidden)
        model.noteHidden(enforcement.hidden)
        model.noteHidden(model.enforcement(for: subjects).hidden)

        let summary = model.activitySummary
        XCTAssertEqual(summary.totalBlocks, 1, "the same block, seen three times, happened once")
        XCTAssertEqual(summary.topKeywords.map(\.keyword), ["free porn"], "the most specific rule that matched")
        XCTAssertEqual(model.notifications.count, 1)
        XCTAssertEqual(model.unreadNotificationCount, 1)
    }

    /// With protection off, nothing is filtered and nothing is recorded.
    func testNothingIsRecordedWhileProtectionIsOff() {
        XCTAssertNil(model.setPassword("1234", confirmation: "1234"))
        let subjects = [ProtectionSubject(id: "blocked", title: "free porn compilation")]
        let enforcement = model.enforcement(for: subjects)
        XCTAssertEqual(enforcement.hiddenCount, 0)
        model.noteHidden(enforcement.hidden)
        XCTAssertEqual(model.activitySummary.totalBlocks, 0)
        XCTAssertTrue(model.notifications.isEmpty)
    }

    /// The notification centre is the tab's own record: readable, and clearable.
    func testNotificationsCanBeMarkedReadAndCleared() {
        XCTAssertNil(model.setPassword("1234", confirmation: "1234"))
        model.protectionEnabled = true
        model.noteHidden(model.enforcement(for: [ProtectionSubject(id: "one", title: "free porn")]).hidden)

        XCTAssertEqual(model.unreadNotificationCount, 1)
        model.markAllNotificationsRead()
        XCTAssertEqual(model.unreadNotificationCount, 0)
        model.clearNotifications()
        XCTAssertTrue(model.notifications.isEmpty)
    }

    /// Clearing the activity leaves the rules alone: the log and the block list are
    /// different things, and a reset of one must never be a reset of the other.
    func testClearingActivityKeepsTheRules() {
        XCTAssertNil(model.setPassword("1234", confirmation: "1234"))
        model.addUserKeyword("drama")
        model.addBlockedChannel("@somechannel")
        model.recordBlock(BlockDecision(matched: "drama", category: "Your keywords"))

        model.clearActivity()
        XCTAssertEqual(model.activitySummary.totalBlocks, 0)
        XCTAssertEqual(model.userKeywords, ["drama"])
        XCTAssertEqual(model.blockedChannels.map(\.handle), ["@somechannel"])
    }
}

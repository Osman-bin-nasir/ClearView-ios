import XCTest
@testable import ClearView

/// The Protection store: the settings, the password, the activity log and the rules about
/// what an anonymous request's status means.
///
/// Every test uses its own `UserDefaults` suite, so one test cannot pass because another
/// ran first — and a rerun cannot pass because the last run left something behind.
final class ProtectionStoreTests: XCTestCase {

    private var suiteName = ""
    private var store: ProtectionStore!

    override func setUp() {
        super.setUp()
        suiteName = "ProtectionStoreTests-\(UUID().uuidString)"
        store = ProtectionStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Keywords

    /// A keyword is stored trimmed and folded, and the same word in different case is the
    /// same block.
    func testKeywordsAreNormalisedAndDeduplicated() {
        XCTAssertTrue(store.addUserKeyword("  Instagram  "))
        XCTAssertEqual(store.userKeywords, ["instagram"])
        XCTAssertFalse(store.addUserKeyword("INSTAGRAM"), "the same term in another case is the same block")
        XCTAssertFalse(store.addUserKeyword("   "), "nothing to add")
        XCTAssertTrue(store.addUserKeyword("tiktok"))
        XCTAssertEqual(store.userKeywords, ["instagram", "tiktok"])

        store.removeUserKeyword("instagram")
        XCTAssertEqual(store.userKeywords, ["tiktok"])
    }

    /// YouTube-only keywords live in their own list: a term added under YouTube Protection
    /// must never become a website rule.
    func testYouTubeKeywordsAreTheirOwnList() {
        XCTAssertTrue(store.addYouTubeKeyword("Drama"))
        XCTAssertEqual(store.youTubeKeywords, ["drama"])
        XCTAssertTrue(store.userKeywords.isEmpty)

        let rules = store.rules()
        XCTAssertTrue(rules.userKeywords.isEmpty)
        XCTAssertEqual(rules.youTubeKeywords.map(\.original), ["drama"])
    }

    // MARK: - Websites

    /// A website is stored as a hostname, and what is not a hostname is refused rather
    /// than stored and never matched.
    func testWebsitesAreStoredAsHostnames() {
        XCTAssertTrue(store.addBlockedDomain("https://www.Reddit.com/r/all"))
        XCTAssertEqual(store.blockedDomains, ["reddit.com"])
        XCTAssertFalse(store.addBlockedDomain("reddit.com"), "already blocked")
        XCTAssertFalse(store.addBlockedDomain("not a domain"))
        XCTAssertTrue(store.blockedDomains == ["reddit.com"], "a refused entry changes nothing")

        store.removeBlockedDomain("https://reddit.com")
        XCTAssertTrue(store.blockedDomains.isEmpty)
    }

    // MARK: - Channels

    /// A channel is stored by handle, and re-blocking a renamed channel updates its label
    /// instead of duplicating the entry.
    func testChannelsAreStoredByHandle() {
        XCTAssertTrue(store.addBlockedChannel(handle: "SomeChannel"))
        XCTAssertEqual(store.blockedChannels.map(\.handle), ["@somechannel"])
        XCTAssertFalse(store.addBlockedChannel(handle: "ab"), "not a handle")

        XCTAssertTrue(store.addBlockedChannel(handle: "@somechannel", name: "Some Channel"))
        XCTAssertEqual(store.blockedChannels.count, 1)
        XCTAssertEqual(store.blockedChannels.first?.name, "Some Channel")

        XCTAssertTrue(store.isChannelBlocked("@SomeChannel"))
        XCTAssertFalse(store.isChannelBlocked("@other"))

        XCTAssertEqual(store.filteredChannels(search: "some").count, 1)
        XCTAssertEqual(store.filteredChannels(search: "drama").count, 0)

        store.removeBlockedChannel("@somechannel")
        XCTAssertTrue(store.blockedChannels.isEmpty)
    }

    // MARK: - The password

    /// The password is stored as a hash, verified against it, and never recoverable.
    func testThePasswordIsHashed() {
        XCTAssertFalse(store.hasPassword)
        XCTAssertFalse(store.verifyPassword("anything"), "no password is not an open door")

        XCTAssertNotNil(store.setPassword("123"), "shorter than the minimum")
        XCTAssertFalse(store.hasPassword)
        XCTAssertNil(store.setPassword("1234"), "four characters is enough")

        XCTAssertTrue(store.hasPassword)
        XCTAssertTrue(store.verifyPassword("1234"))
        XCTAssertFalse(store.verifyPassword("12345"))
        XCTAssertFalse(store.verifyPassword(""))

        let hash = store.passwordHash
        XCTAssertEqual(hash?.count, 64, "a SHA-256 in hex")
        XCTAssertNotEqual(hash, "1234", "the password itself is never stored")
        XCTAssertEqual(hash, ProtectionStore.hash("1234"))

        store.clearPassword()
        XCTAssertFalse(store.hasPassword)
        XCTAssertFalse(store.verifyPassword("1234"))
    }

    // MARK: - The compiled rules

    /// The shared rules are merged into the enforcement set — the user's everywhere
    /// keywords plus the global ones — and never into the list a screen may edit.
    func testSharedRulesAreMergedForEnforcementOnly() {
        store.addUserKeyword("mine")
        var snapshot = GlobalRuleSnapshot()
        snapshot.keywords = ["theirs"]
        snapshot.channels = ["@globalchannel"]
        snapshot.lastSyncMs = ProtectionStore.nowMs()
        store.globalRules = snapshot

        let rules = store.rules()
        XCTAssertEqual(Set(rules.userKeywords.map(\.original)), ["mine", "theirs"])
        XCTAssertEqual(store.userKeywords, ["mine"], "the editable list holds only the user's own entry")
        XCTAssertTrue(rules.channels.contains("@globalchannel"))
        XCTAssertFalse(store.blockedChannels.contains { $0.handle == "@globalchannel" })
    }

    /// The adult preset is always on, and Strict Mode adds to it.
    func testTheAdultTierIsAlwaysOn() {
        let base = store.rules()
        XCTAssertFalse(base.alwaysBlock.isEmpty, "the always-on adult filter is not a setting")
        store.strictMode = true
        XCTAssertGreaterThan(store.rules().alwaysBlock.count, base.alwaysBlock.count)
    }

    /// The compiled rules are a pure function of the settings, so an edit is visible to
    /// the next match rather than to the next launch — and a plain word still only matches
    /// as a whole word.
    func testARuleChangeIsVisibleImmediately() {
        XCTAssertNil(ProtectionMatcher.decision(forText: "a documentary about drone strikes", rules: store.rules()))
        store.addUserKeyword("drone")
        XCTAssertEqual(
            ProtectionMatcher.decision(forText: "a documentary about drone strikes", rules: store.rules())?.matched,
            "drone"
        )
        XCTAssertNil(
            ProtectionMatcher.decision(forText: "drones at the park", rules: store.rules()),
            "a user keyword is a whole word, so it does not block its own plural"
        )
    }

    // MARK: - Activity

    /// A recorded block lands in the log with its explanation, and clearing empties it.
    func testRecordingAndClearingActivity() {
        XCTAssertEqual(store.activitySummary().totalBlocks, 0)

        store.recordBlock(category: "Adult", keyword: "porn", channel: "Some Channel")
        let summary = store.activitySummary()
        XCTAssertEqual(summary.totalBlocks, 1)
        XCTAssertEqual(summary.todayBlocks, 1)
        XCTAssertEqual(summary.streakDays, 1)
        XCTAssertEqual(summary.topKeywords.map(\.keyword), ["porn"])
        XCTAssertEqual(summary.topChannels.map(\.channel), ["some channel"])

        store.clearEvents()
        XCTAssertTrue(store.events.isEmpty)
    }

    /// The log is bounded on disk, keeping the newest.
    func testTheActivityLogIsBounded() {
        for index in 0..<(BlockActivityStats.maxEvents + 5) {
            store.recordBlock(category: "Adult", keyword: "term\(index)")
        }
        XCTAssertEqual(store.events.count, BlockActivityStats.maxEvents)
        XCTAssertNil(store.events.first { $0.keyword == "term0" }, "the oldest fell off")
        XCTAssertNotNil(store.events.last { $0.keyword == "term\(BlockActivityStats.maxEvents + 4)" })
    }

    // MARK: - Notifications

    /// A notification is written once per id, so re-reading the same news is not news.
    func testNotificationsAreIdempotentAndReadable() {
        store.addNotification(id: "one", kind: ProtectionNotification.Kind.blocked, value: "porn", message: "Blocked")
        store.addNotification(id: "one", kind: ProtectionNotification.Kind.blocked, value: "porn", message: "Blocked")
        store.addNotification(id: "two", kind: ProtectionNotification.Kind.submitted, value: "drama", message: "Sent")

        XCTAssertEqual(store.notifications.count, 2)
        XCTAssertEqual(store.notifications.first?.id, "two", "newest first")
        XCTAssertEqual(store.unreadNotificationCount, 2)

        store.markNotificationRead(id: "two")
        XCTAssertEqual(store.unreadNotificationCount, 1)

        store.markAllNotificationsRead()
        XCTAssertEqual(store.unreadNotificationCount, 0)

        store.clearNotifications()
        XCTAssertTrue(store.notifications.isEmpty)
    }

    // MARK: - What a request's status means

    private func submission(id: String, kind: String, value: String, status: String) -> ProtectionSubmission {
        ProtectionSubmission(id: id, kind: kind, value: value, status: status, atMs: 0)
    }

    /// With no synced snapshot, a rule counts as live: a slow network must never relabel a
    /// rule that really is in force.
    func testAnUnsyncedCacheReportsARuleAsLive() {
        store.submissions = [submission(id: "1", kind: "keyword", value: "drama", status: SubmissionStatus.approved)]
        XCTAssertTrue(store.isLiveGlobally(kind: "keyword", value: "drama"))
        XCTAssertEqual(store.submissionStatus(kind: "keyword", value: "drama"), SubmissionStatus.approved)
        XCTAssertEqual(store.displayStatus(of: store.submissions[0]), SubmissionStatus.approved)
    }

    /// A rule that was approved and has since been removed reads as removed — the screen
    /// never claims something is blocked for everyone when it is not.
    func testARemovedRuleReadsAsRemoved() {
        store.submissions = [submission(id: "1", kind: "keyword", value: "drama", status: SubmissionStatus.approved)]
        var snapshot = GlobalRuleSnapshot()
        snapshot.keywords = ["somethingelse"]
        snapshot.lastSyncMs = ProtectionStore.nowMs()
        store.globalRules = snapshot

        XCTAssertFalse(store.isLiveGlobally(kind: "keyword", value: "drama"))
        XCTAssertTrue(store.isRemovedGlobally(kind: "keyword", value: "drama"))
        XCTAssertNil(store.submissionStatus(kind: "keyword", value: "drama"), "a removed request can be sent again")
        XCTAssertEqual(store.displayStatus(of: store.submissions[0]), SubmissionStatus.removed)
    }

    /// A queued request shows as queued, which is what keeps the Send action from being
    /// offered twice — and an approved, still-live one is in the Approved group.
    func testQueuedAndApprovedGroups() {
        store.submissions = [
            submission(id: "1", kind: "keyword", value: "pending-one", status: SubmissionStatus.pending),
            submission(id: "2", kind: "keyword", value: "under-review", status: "under_review"),
            submission(id: "3", kind: "keyword", value: "live", status: SubmissionStatus.approved),
            submission(id: "4", kind: "channel", value: "@other", status: SubmissionStatus.approved),
        ]
        var snapshot = GlobalRuleSnapshot()
        snapshot.keywords = ["live"]
        snapshot.channels = ["@other"]
        snapshot.lastSyncMs = ProtectionStore.nowMs()
        store.globalRules = snapshot

        XCTAssertEqual(store.pendingSubmissions(kind: "keyword").map(\.value), ["pending-one", "under-review"])
        XCTAssertTrue(store.isQueuedForReview(kind: "keyword", value: "pending-one"))
        XCTAssertFalse(store.isQueuedForReview(kind: "keyword", value: "live"))

        XCTAssertEqual(store.approvedSubmissions(kind: "keyword").map(\.value), ["live"])
        XCTAssertTrue(store.isApprovedGlobally(kind: "keyword", value: "live"))
        XCTAssertEqual(store.approvedSubmissions(kind: "channel").map(\.value), ["@other"])
    }

    /// A rejected request can be sent again: a refusal is not a reason to stop asking.
    func testARejectedRequestCanBeSentAgain() {
        store.submissions = [submission(id: "1", kind: "keyword", value: "drama", status: SubmissionStatus.rejected)]
        XCTAssertEqual(store.submissionStatus(kind: "keyword", value: "drama"), SubmissionStatus.rejected)
        XCTAssertEqual(store.displayStatus(of: store.submissions[0]), SubmissionStatus.rejected)
    }

    /// A channel submission is compared by its normalised handle, so a request filed as
    /// "@SomeChannel" is found by "somechannel" — and never by a different value.
    func testChannelSubmissionsMatchByHandle() {
        store.submissions = [submission(id: "1", kind: "channel", value: "@SomeChannel", status: SubmissionStatus.pending)]
        XCTAssertTrue(store.isQueuedForReview(kind: "channel", value: "@somechannel"))
        XCTAssertNil(store.submissionStatus(kind: "channel", value: "@otherchannel"))
        XCTAssertNil(store.submissionStatus(kind: "keyword", value: "@somechannel"), "a channel is not a keyword")
    }

    // MARK: - Reset

    /// Clearing the store forgets everything this tab owns, and leaves nothing behind.
    func testClearAllForgetsEverything() {
        store.strictMode = true
        store.addUserKeyword("instagram")
        store.setPassword("1234")
        store.recordBlock(category: "Adult", keyword: "porn")
        store.clearAll()
        XCTAssertFalse(store.strictMode)
        XCTAssertFalse(store.blockShorts)
        XCTAssertFalse(store.youTubeProtection)
        XCTAssertFalse(store.hasBeenEnabled)
        XCTAssertTrue(store.userKeywords.isEmpty)
        XCTAssertTrue(store.youTubeKeywords.isEmpty)
        XCTAssertTrue(store.blockedDomains.isEmpty)
        XCTAssertTrue(store.blockedChannels.isEmpty)
        XCTAssertFalse(store.hasPassword)
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(store.notifications.isEmpty)
        XCTAssertTrue(store.submissions.isEmpty)
        XCTAssertFalse(store.hasGlobalSnapshot)
    }

    /// Every setting survives a new store over the same defaults — which is what "stored
    /// on the device" has to mean for a block list.
    func testEverySettingRoundTripsThroughTheStore() {
        store.strictMode = true
        store.blockShorts = true
        store.youTubeProtection = true
        store.hasBeenEnabled = true
        store.addUserKeyword("instagram")
        store.addYouTubeKeyword("drama")
        store.addBlockedDomain("reddit.com")
        store.addBlockedChannel(handle: "@somechannel", name: "Some Channel")
        store.setPassword("1234")
        store.recordBlock(category: "Adult", keyword: "porn")
        store.addNotification(id: "n", kind: ProtectionNotification.Kind.blocked, value: "porn", message: "Blocked")
        store.submissions = [submission(id: "1", kind: "keyword", value: "drama", status: SubmissionStatus.pending)]

        let reopened = ProtectionStore(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertTrue(reopened.strictMode)
        XCTAssertTrue(reopened.blockShorts)
        XCTAssertTrue(reopened.youTubeProtection)
        XCTAssertTrue(reopened.hasBeenEnabled)
        XCTAssertEqual(reopened.userKeywords, ["instagram"])
        XCTAssertEqual(reopened.youTubeKeywords, ["drama"])
        XCTAssertEqual(reopened.blockedDomains, ["reddit.com"])
        XCTAssertEqual(reopened.blockedChannels.map(\.handle), ["@somechannel"])
        XCTAssertEqual(reopened.blockedChannels.first?.name, "Some Channel")
        XCTAssertTrue(reopened.verifyPassword("1234"))
        XCTAssertEqual(reopened.events.count, 1)
        XCTAssertEqual(reopened.notifications.count, 1)
        XCTAssertEqual(reopened.submissions.count, 1)
    }
}

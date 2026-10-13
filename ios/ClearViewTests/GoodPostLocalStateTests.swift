import XCTest
@testable import ClearView

/// Tests for the Good Post state that lives on this device: hidden posts, counted views and
/// stars.
///
/// All three exist because the same failure is worse than it looks — a reply that comes back
/// after a restart, a view count that climbs on its own, a bookmark that loses its words — so
/// each test is about surviving a relaunch, not about a single run.
final class GoodPostLocalStateTests: XCTestCase {

    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suite = "GoodPostLocalStateTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try super.tearDownWithError()
    }

    private func entry(_ postId: String, channel: String = "channel-1", body: String? = "Hello") -> GoodPostStarredEntry {
        GoodPostStarredEntry(
            postId: postId,
            channelId: channel,
            channelName: "Some Channel",
            body: body,
            createdAt: "2026-10-13T10:00:00Z"
        )
    }

    // MARK: - Hidden

    /// A hidden post stays hidden across launches — the reason the set is stored rather than
    /// kept in memory.
    func testHiddenPostsSurviveARelaunch() {
        GoodPostHiddenStore(defaults: defaults).hide(["post-1", "post-2"])

        let reopened = GoodPostHiddenStore(defaults: defaults)
        XCTAssertEqual(reopened.ids, ["post-1", "post-2"])
        XCTAssertTrue(reopened.isHidden(postId: "post-1"))
        XCTAssertFalse(reopened.isHidden(postId: "post-3"))
    }

    /// At the cap, the ids just hidden survive and the older ones fall off — a message deleted
    /// this morning must not reappear tonight.
    func testTheHiddenCapKeepsTheNewest() {
        let store = GoodPostHiddenStore(defaults: defaults)
        let old = (0..<GoodPostHiddenStore.limit).map { "old-\($0)" }
        store.hide(old)

        store.hide(["just-deleted"])

        XCTAssertEqual(store.ids.count, GoodPostHiddenStore.limit)
        XCTAssertTrue(store.isHidden(postId: "just-deleted"))
        XCTAssertEqual(
            old.filter { !store.ids.contains($0) }.count,
            1,
            "exactly one older id fell off to make room — and which one is deliberately not asserted, "
                + "since a stored set has no order to predict it from"
        )
    }

    /// Hiding is idempotent, and un-hiding removes exactly one id.
    func testHidingIsIdempotentAndCanBeUndone() {
        let store = GoodPostHiddenStore(defaults: defaults)
        store.hide(["post-1"])
        store.hide(["post-1", "post-2"])

        XCTAssertEqual(store.ids, ["post-1", "post-2"])
        XCTAssertEqual(store.ids.count, 2, "hiding the same id twice does not store it twice")

        store.unhide(postId: "post-1")
        XCTAssertEqual(store.ids, ["post-2"])
    }

    /// A store with nothing in it reads as empty, and an empty call changes nothing.
    func testAFreshHiddenStoreIsEmpty() {
        let store = GoodPostHiddenStore(defaults: defaults)
        XCTAssertTrue(store.ids.isEmpty)

        store.hide([])
        XCTAssertTrue(store.ids.isEmpty)

        store.clear()
        XCTAssertTrue(store.ids.isEmpty)
    }

    // MARK: - Viewed

    /// A counted view is remembered, so a restart does not inflate a post's counter.
    func testCountedViewsSurviveARelaunch() {
        GoodPostViewedStore(defaults: defaults).mark(["post-1"])

        XCTAssertTrue(GoodPostViewedStore(defaults: defaults).seen(postId: "post-1"))
        XCTAssertFalse(GoodPostViewedStore(defaults: defaults).seen(postId: "post-2"))
    }

    /// The cap keeps the most recent reads, and clearing makes everything unseen again.
    func testTheViewedCapAndClear() {
        let store = GoodPostViewedStore(defaults: defaults)
        store.mark((0..<GoodPostViewedStore.limit).map { "old-\($0)" })
        store.mark(["just-read"])

        XCTAssertEqual(store.ids.count, GoodPostViewedStore.limit)
        XCTAssertTrue(store.seen(postId: "just-read"))
        XCTAssertEqual((0..<GoodPostViewedStore.limit).filter { !store.seen(postId: "old-\($0)") }.count, 1)

        store.clear()
        XCTAssertTrue(store.ids.isEmpty)
    }

    // MARK: - Starred

    /// Starring stores the words, not just the id, so a bookmark can be drawn days later
    /// without re-fetching — and it survives the relaunch.
    func testAStarKeepsItsWordsAcrossLaunches() {
        let store = GoodPostStarredStore(defaults: defaults)
        XCTAssertTrue(store.toggle(entry("post-1")))

        let reopened = GoodPostStarredStore(defaults: defaults)
        let starred = try? XCTUnwrap(reopened.all.first)
        XCTAssertEqual(starred?.postId, "post-1")
        XCTAssertEqual(starred?.body, "Hello")
        XCTAssertEqual(starred?.channelId, "channel-1")
        XCTAssertEqual(starred?.kind, "text")
        XCTAssertEqual(starred?.createdAt, "2026-10-13T10:00:00Z")
        XCTAssertTrue(reopened.isStarred(postId: "post-1"))
        XCTAssertEqual(reopened.forChannel("channel-1").count, 1)
        XCTAssertTrue(reopened.forChannel("other").isEmpty)
    }

    /// Toggling is a real toggle, in both directions, and a second toggle does not leave a
    /// duplicate behind.
    func testTogglingAStarBothWays() {
        let store = GoodPostStarredStore(defaults: defaults)

        XCTAssertTrue(store.toggle(entry("post-1")))
        XCTAssertFalse(store.toggle(entry("post-1")))
        XCTAssertTrue(store.all.isEmpty)

        XCTAssertTrue(store.toggle(entry("post-1")))
        XCTAssertEqual(store.all.count, 1)

        store.remove(postId: "post-1")
        XCTAssertTrue(store.all.isEmpty)
        store.remove(postId: "never-starred")
        XCTAssertTrue(store.all.isEmpty)
    }

    /// The newest star comes first, and the cap keeps the newest.
    func testStarsAreNewestFirstAndCapped() {
        var clock: Int64 = 1_000
        let store = GoodPostStarredStore(defaults: defaults, now: { clock })
        for index in 0..<GoodPostStarredStore.limit {
            clock += 1
            store.toggle(entry("post-\(index)"))
        }
        clock += 1
        store.toggle(entry("newest"))

        XCTAssertEqual(store.all.count, GoodPostStarredStore.limit)
        XCTAssertEqual(store.all.first?.postId, "newest")
        XCTAssertEqual(store.all.first?.starredAt, clock)
        XCTAssertFalse(store.isStarred(postId: "post-0"), "the oldest star fell off")
    }

    /// Removing a channel's stars is for the case where the channel itself is gone: its rows
    /// name a channel that no longer exists, and the words alone have no way back.
    func testRemovingAChannelsStars() {
        let store = GoodPostStarredStore(defaults: defaults)
        store.toggle(entry("post-1", channel: "channel-1"))
        store.toggle(entry("post-2", channel: "channel-2"))
        store.toggle(entry("post-3", channel: "channel-1"))

        store.removeChannel("channel-1")

        XCTAssertEqual(store.all.map(\.postId), ["post-2"])
        store.removeChannel("   ")
        XCTAssertEqual(store.all.count, 1, "a blank channel id removes nothing")
    }

    /// A stored body that is blank — or the literal string `null`, which is what a JSON null
    /// becomes when it is written through a string layer — reads as no body, and the row says
    /// so rather than showing the word "null".
    func testBlankAndLiteralNullBodies() {
        let json = """
        [
          {"postId":"a","channelId":"c","channelName":"N","body":"","kind":"text","createdAt":"t","starredAt":1},
          {"postId":"b","channelId":"c","channelName":"N","body":"null","kind":"image","createdAt":"t","starredAt":2},
          {"postId":"c","channelId":"c","channelName":"N","body":"  ","kind":"text","createdAt":"t","starredAt":3},
          {"postId":"d","channelId":"c","channelName":"N","body":"Real words","kind":"text","createdAt":"t","starredAt":4}
        ]
        """
        defaults.set(json, forKey: GoodPostStarredStore.Key.entries)

        let store = GoodPostStarredStore(defaults: defaults)

        XCTAssertEqual(store.all.count, 4)
        XCTAssertNil(store.all[0].body)
        XCTAssertNil(store.all[1].body)
        XCTAssertNil(store.all[2].body)
        XCTAssertEqual(store.all[3].body, "Real words")
        XCTAssertEqual(store.all[0].displayBody, "No text")
        XCTAssertEqual(store.all[3].displayBody, "Real words")
        XCTAssertEqual(store.all[1].kind, "image", "the kind still says what the post was")
    }

    /// A stored row with no id cannot be shown, opened or unstarred, so it is dropped — and a
    /// file that cannot be read at all reads as no stars rather than failing the screen.
    func testUnusableRowsAndUnreadableFiles() {
        defaults.set(
            "[{\"channelId\":\"c\"},{\"postId\":\"   \"},{\"postId\":\"good\"}]",
            forKey: GoodPostStarredStore.Key.entries
        )
        XCTAssertEqual(GoodPostStarredStore(defaults: defaults).all.map(\.postId), ["good"])

        defaults.set("not json", forKey: GoodPostStarredStore.Key.entries)
        XCTAssertTrue(GoodPostStarredStore(defaults: defaults).all.isEmpty)

        defaults.set("{\"not\":\"an array\"}", forKey: GoodPostStarredStore.Key.entries)
        XCTAssertTrue(GoodPostStarredStore(defaults: defaults).all.isEmpty)
    }

    /// A star's timestamp is stamped by the store, not by the caller, so two calls cannot
    /// claim the same instant and the list's order is the store's own record.
    func testTheStoreStampsTheStarTime() {
        let store = GoodPostStarredStore(defaults: defaults, now: { 42 })

        store.toggle(entry("post-1"))

        XCTAssertEqual(store.all.first?.starredAt, 42)
        XCTAssertEqual(
            store.all.first?.starredAt,
            42,
            "a caller-supplied timestamp is replaced"
        )
    }
}

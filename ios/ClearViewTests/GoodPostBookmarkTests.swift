import XCTest
@testable import ClearView

/// What a message becomes when a reader stars it.
///
/// The star control on a feed message and the starred list are two halves of one promise: the
/// control says "keep this", and the list has to be able to draw what was kept. Everything the
/// list needs has to be captured at the moment of the tap, because a bookmark deliberately
/// stores a copy of the post's words rather than an id — the server keeps a post for thirty days
/// and a star outlives it.
///
/// These tests go through `GoodPostCodec` rather than building a `GoodPostPost` by hand, so they
/// assert what a real payload becomes. A hand-built struct is free to disagree with the codec,
/// which would make the test pass while the app was wrong.
final class GoodPostBookmarkTests: XCTestCase {

    private func post(
        id: String = "post-1",
        channelId: String = "channel-1",
        body: String? = "Hello",
        linkUrl: String? = nil,
        mediaKinds: [String] = []
    ) -> GoodPostPost {
        var payload: [String: Any] = [
            "id": id,
            "channelId": channelId,
            "createdAt": "2026-10-13T10:00:00Z",
            "media": mediaKinds.enumerated().map { index, kind in
                ["id": "media-\(index)", "kind": kind, "position": index]
            },
        ]
        if let body { payload["body"] = body }
        if let linkUrl { payload["linkUrl"] = linkUrl }
        guard let post = GoodPostCodec.post(from: payload) else {
            XCTFail("the payload did not parse, so this test would assert nothing")
            return GoodPostPost(
                id: id, channelId: channelId, type: "text", body: body, linkUrl: linkUrl,
                linkTitle: nil, media: [], createdAt: "", editedAt: nil, channel: nil,
                views: 0, reactions: [], myReaction: nil
            )
        }
        return post
    }

    private func channel(id: String = "channel-1", name: String = "Some Channel") -> GoodPostChannel {
        guard let channel = GoodPostCodec.channel(from: ["id": id, "name": name]) else {
            XCTFail("a channel with an id and a name must parse")
            return GoodPostCodec.channel(from: ["id": "fallback", "name": "Fallback"])!
        }
        return channel
    }

    /// A clip wins over a picture when a post carries both.
    ///
    /// Not an arbitrary tie-break: a poster frame on its own is indistinguishable from a
    /// photograph of the same scene, so the mark that says it plays is the one worth keeping.
    /// Getting this backwards shows a clip's bookmark as a photo, which is the one thing the
    /// label exists to prevent.
    func testAClipBeatsAPhotoWhenAPostCarriesBoth() {
        XCTAssertEqual(post(mediaKinds: ["image", "video"]).starredEntry(channel: channel()).kind, "video")
        XCTAssertEqual(post(mediaKinds: ["video", "image"]).starredEntry(channel: channel()).kind, "video")
    }

    func testAPhotoBookmarkKnowsItIsAPhoto() {
        XCTAssertEqual(post(mediaKinds: ["image"]).starredEntry(channel: channel()).kind, "image")
    }

    /// A post that carries a link is `link` even when it also has words.
    ///
    /// This is Android's order, and it is right for the reason `kind` exists at all: the label is
    /// only ever DRAWN when the post has no words (the row shows the body otherwise — see
    /// `GoodPostStarredScreen`'s `entry.body?.takeIf { it.isNotBlank() }`). So "link" describes a
    /// link-only bookmark rather than making a claim about a message that happens to mention one.
    ///
    /// My first version of this test asserted "text", which was my own wrong expectation rather
    /// than the app's behaviour — the implementation was already matching Android.
    func testAPostWithALinkIsALinkEvenWhenItHasWords() {
        XCTAssertEqual(post(body: "Read this", linkUrl: "https://example.com").starredEntry(channel: channel()).kind, "link")
    }

    func testALinkOnlyBookmarkIsALink() {
        XCTAssertEqual(post(body: nil, linkUrl: "https://example.com").starredEntry(channel: channel()).kind, "link")
    }

    func testAnOrdinaryMessageIsText() {
        XCTAssertEqual(post().starredEntry(channel: channel()).kind, "text")
    }

    /// The channel's id and **name** ride along, which is the whole reason the name is stored:
    /// the information page can say where a bookmark came from after the post it points at has
    /// aged out of the server's retention window.
    func testABookmarkCarriesTheChannelTheWordsAndTheTime() {
        let saved = post(channelId: "c-9", body: "Keep this")
            .starredEntry(channel: channel(id: "c-9", name: "Ninth"))

        XCTAssertEqual(saved.postId, "post-1")
        XCTAssertEqual(saved.channelId, "c-9")
        XCTAssertEqual(saved.channelName, "Ninth")
        XCTAssertEqual(saved.body, "Keep this")
        XCTAssertFalse(saved.createdAt.isEmpty, "a bookmark with no time cannot be dated in the list")
    }

    /// A post with no words and no media still becomes a bookmark rather than being dropped: it
    /// is the reader's own choice, and the list has an honest label for it.
    func testASilentPostStillBookmarks() {
        let saved = post(body: nil).starredEntry(channel: channel())
        XCTAssertEqual(saved.kind, "text")
        XCTAssertNil(saved.body)
    }
}

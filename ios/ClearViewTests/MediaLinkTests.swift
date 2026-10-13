import XCTest
@testable import ClearView

/// Tests for the Media tab's link handling: the one YouTube URL parser, the playlist
/// id extractor and the Shorts detection.
///
/// These rules are where the past bugs lived — a `?v=` matched on any host, `/live/`
/// links rejected outright, a Shorts row that stayed empty — so the cases below are
/// mostly the ones that used to fail rather than the ones that were easy to write.
final class MediaLinkTests: XCTestCase {

    // MARK: - The YouTube link parser

    /// The form YouTube's own Share sheet produces for a broadcast, which the old
    /// four-regex parser rejected.
    func testALiveLinkIsUnderstood() {
        let reference = YouTubeLink.parse("https://www.youtube.com/live/iP2PlX4ZAAY?si=ckmlfXyTB5npP41y")

        XCTAssertEqual(reference?.videoId, "iP2PlX4ZAAY")
        XCTAssertEqual(reference?.kind, .live)
        XCTAssertTrue(reference?.isLive == true)
    }

    /// A video id in the query is only a video on a YouTube host: this is the bug that
    /// made any page with `?v=` look playable.
    func testVideoIdsOnOtherHostsAreRejected() {
        XCTAssertNil(YouTubeLink.parse("https://example.com/page?v=dQw4w9WgXcQ"))
        XCTAssertNil(YouTubeLink.parse("https://notyoutube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(
            YouTubeLink.parse("https://evilyoutube.com/watch?v=dQw4w9WgXcQ"),
            "a host that merely ends in the right letters is not YouTube"
        )
    }

    /// Every form YouTube hands out, and the kind each one implies.
    func testEveryLinkFormIsParsedWithItsKind() {
        let expectations: [(String, String, YouTubeUrlKind)] = [
            ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ", .watch),
            ("https://m.youtube.com/watch?v=dQw4w9WgXcQ", "dQw4w9WgXcQ", .watch),
            ("https://music.youtube.com/watch?v=dQw4w9WgXcQ&feature=share", "dQw4w9WgXcQ", .watch),
            ("youtube.com/watch?list=PL1234567890abcdefghijkl&v=dQw4w9WgXcQ", "dQw4w9WgXcQ", .watch),
            ("https://youtu.be/dQw4w9WgXcQ?t=42", "dQw4w9WgXcQ", .shortLink),
            ("https://www.youtube.com/shorts/abcdefghijk", "abcdefghijk", .short),
            ("https://www.youtube.com/embed/dQw4w9WgXcQ", "dQw4w9WgXcQ", .embed),
            ("https://www.youtube.com/v/dQw4w9WgXcQ", "dQw4w9WgXcQ", .embed),
            ("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ", "dQw4w9WgXcQ", .embed),
            ("https://www.youtube.com/?v=dQw4w9WgXcQ", "dQw4w9WgXcQ", .watch),
            ("https://youtube.com/watch?v=dQw4w9WgXcQ#comments", "dQw4w9WgXcQ", .watch),
        ]

        for (input, id, kind) in expectations {
            let reference = YouTubeLink.parse(input)
            XCTAssertEqual(reference?.videoId, id, input)
            XCTAssertEqual(reference?.kind, kind, input)
        }
    }

    /// A bare id is a valid paste, and a `/shorts/` link knows it is a Short.
    func testBareIdsAndShortsAreRecognised() {
        let bare = YouTubeLink.parse("  dQw4w9WgXcQ  ")

        XCTAssertEqual(bare?.videoId, "dQw4w9WgXcQ")
        XCTAssertEqual(bare?.kind, .bareId)
        XCTAssertTrue(YouTubeLink.parse("https://www.youtube.com/shorts/abcdefghijk")?.isShort == true)
        XCTAssertFalse(YouTubeLink.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ")?.isShort == true)
        XCTAssertEqual(YouTubeLink.videoId(from: "https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
    }

    /// Share text around a link is not a reason to reject the pasted field.
    func testALinkInsideAParagraphIsFound() {
        let pasted = "Watch this: https://youtu.be/dQw4w9WgXcQ — it's great"

        XCTAssertEqual(YouTubeLink.parse(pasted)?.videoId, "dQw4w9WgXcQ")
    }

    /// Things that are not videos are refused, including the shapes that look closest:
    /// a channel page, a playlist, a handle and a wrong-length id.
    func testNonVideoLinksAreRefused() {
        let inputs = [
            "",
            "   ",
            nil,
            "https://www.youtube.com/@somechannel",
            "https://www.youtube.com/playlist?list=PL1234567890abcdefghijkl",
            "https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv",
            "https://www.youtube.com/watch?v=tooShort",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQextra",
            "just some text",
            "dQw4w9WgXc",  // 10 characters
        ]

        for input in inputs {
            XCTAssertNil(YouTubeLink.parse(input), input ?? "nil")
        }
    }

    /// The time offset, in all the forms YouTube writes it.
    func testTheStartOffsetIsDecoded() {
        XCTAssertEqual(YouTubeLink.parse("https://youtu.be/dQw4w9WgXcQ?t=90")?.startSeconds, 90)
        XCTAssertEqual(YouTubeLink.parse("https://youtu.be/dQw4w9WgXcQ?t=90s")?.startSeconds, 90)
        XCTAssertEqual(YouTubeLink.parse("https://youtu.be/dQw4w9WgXcQ?t=1m30s")?.startSeconds, 90)
        XCTAssertEqual(YouTubeLink.parse("https://youtu.be/dQw4w9WgXcQ?t=1h2m3s")?.startSeconds, 3723)
        XCTAssertEqual(YouTubeLink.parse("https://youtu.be/dQw4w9WgXcQ?start=90")?.startSeconds, 90)
        XCTAssertEqual(
            YouTubeLink.parse("https://youtu.be/dQw4w9WgXcQ")?.startSeconds,
            0,
            "no offset means no offset"
        )
        XCTAssertEqual(
            YouTubeLink.parse("https://youtu.be/dQw4w9WgXcQ?t=banana")?.startSeconds,
            0,
            "an unparseable offset loses the offset, not the link"
        )
    }

    /// Query parameters are read in any order, and repeated ones take the first.
    func testQueryParametersAreOrderIndependent() {
        let reference = YouTubeLink.parse("https://www.youtube.com/watch?si=abc&v=dQw4w9WgXcQ&t=10")

        XCTAssertEqual(reference?.videoId, "dQw4w9WgXcQ")
        XCTAssertEqual(reference?.startSeconds, 10)
    }

    // MARK: - Playlists

    /// The playlist id forms the app has to route to the playlist screen.
    func testPlaylistIdsAreExtractedFromEveryForm() {
        XCTAssertEqual(
            YouTubePlaylistLink.parse("https://www.youtube.com/playlist?list=PL1234567890abcdefghijkl"),
            "PL1234567890abcdefghijkl"
        )
        XCTAssertEqual(
            YouTubePlaylistLink.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL1234567890abcdefghijkl"),
            "PL1234567890abcdefghijkl"
        )
        XCTAssertEqual(
            YouTubePlaylistLink.parse("https://music.youtube.com/playlist?list=OLAK5uy_kABCDEFGHIJKLMNOP"),
            "OLAK5uy_kABCDEFGHIJKLMNOP"
        )
        XCTAssertEqual(
            YouTubePlaylistLink.parse("https://www.youtube.com/playlist/PL1234567890abcdefghijkl"),
            "PL1234567890abcdefghijkl"
        )
        XCTAssertEqual(
            YouTubePlaylistLink.parse("PL1234567890abcdefghijkl"),
            "PL1234567890abcdefghijkl",
            "a bare id is a valid paste"
        )
        XCTAssertEqual(YouTubePlaylistLink.parse("WL"), "WL", "the short system lists")
        XCTAssertEqual(YouTubePlaylistLink.parse(" LL "), "LL")
    }

    /// A *video* id is never mistaken for a playlist, and neither is a channel.
    func testAVideoIdIsNotAPlaylist() {
        XCTAssertNil(YouTubePlaylistLink.parse("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertNil(YouTubePlaylistLink.parse("dQw4w9WgXcQ"))
        XCTAssertNil(YouTubePlaylistLink.parse("https://www.youtube.com/@somechannel"))
        XCTAssertNil(YouTubePlaylistLink.parse(""))
        XCTAssertFalse(YouTubePlaylistLink.isPlaylistLink("dQw4w9WgXcQ"))
        XCTAssertTrue(
            YouTubePlaylistLink.isPlaylistLink("https://www.youtube.com/playlist?list=PL1234567890abcdefghijkl")
        )
    }

    // MARK: - Shorts

    /// Every video id on a `/shorts` tab page is a Short of that channel.
    func testShortsIdsAreExtractedFromTheChannelPage() {
        let html = """
        {"contents":{"videoId":"abcdefghijk","title":"One"},
        "repeat":{"videoId":"lmnopqrstuv","title":"Two"},
        "noise":{"videoId":"not-an-id-at-all","title":"Three"},
        "short":{"videoId":"12345678901"}}
        """

        XCTAssertEqual(
            ShortsIdResolver.extractShortsIds(from: html),
            ["abcdefghijk", "lmnopqrstuv", "12345678901"]
        )
    }

    /// A page with no ids, or a page that is not the shorts tab at all, yields nothing
    /// rather than something wrong.
    func testShortsExtractionIsEmptyWhenThereIsNothingToFind() {
        XCTAssertEqual(ShortsIdResolver.extractShortsIds(from: ""), [])
        XCTAssertEqual(ShortsIdResolver.extractShortsIds(from: "<html><body>Sign in</body></html>"), [])
        XCTAssertEqual(
            ShortsIdResolver.extractShortsIds(from: "{\"videoId\": \"with spaces\"}"),
            [],
            "the id has to be exactly eleven id characters"
        )
    }

    /// Ids are de-duplicated: the same video appearing twice on a page is one Short.
    func testShortsIdsAreDeduplicated() {
        let html = """
        "videoId":"abcdefghijk" "videoId":"abcdefghijk" "videoId":"lmnopqrstuv"
        """

        XCTAssertEqual(ShortsIdResolver.extractShortsIds(from: html), ["abcdefghijk", "lmnopqrstuv"])
    }
}

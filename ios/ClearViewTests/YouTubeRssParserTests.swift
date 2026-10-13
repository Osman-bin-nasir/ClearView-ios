import XCTest
@testable import ClearView

/// Tests for the YouTube channel RSS parser, against a captured document.
///
/// The cases are the ones the Android app was fixed for: Shorts classified from
/// YouTube's own canonical link rather than guessed from titles, a live broadcast never
/// treated as a Short even when its id appears in the `/shorts` scrape, and a broken
/// entry that must not take the rest of the feed with it.
final class YouTubeRssParserTests: XCTestCase {

    private func feed(_ entries: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015"
              xmlns:media="http://search.yahoo.com/mrss/"
              xmlns="http://www.w3.org/2005/Atom">
          <title>Some Channel</title>
          <author><name>The channel itself</name></author>
          \(entries)
        </feed>
        """
    }

    private func entry(
        id: String,
        title: String,
        link: String?,
        thumbnailSuffix: String = "hqdefault.jpg",
        published: String = "2024-01-01T12:00:00+00:00",
        views: Int? = 1234,
        channelId: String = "UC123",
        channelName: String = "Some Channel"
    ) -> String {
        let alternate = link.map { "<link rel=\"alternate\" href=\"\($0)\"/>" } ?? ""
        let statistics = views.map { "<media:statistics views=\"\($0)\"/>" } ?? ""
        return """
        <entry>
          <id>yt:video:\(id)</id>
          <yt:videoId>\(id)</yt:videoId>
          <yt:channelId>\(channelId)</yt:channelId>
          <title>\(title)</title>
          \(alternate)
          <author><name>\(channelName)</name></author>
          <published>\(published)</published>
          <media:group>
            <media:title>\(title)</media:title>
            <media:thumbnail url="https://i.ytimg.com/vi/\(id)/\(thumbnailSuffix)"/>
            <media:community>\(statistics)</media:community>
          </media:group>
        </entry>
        """
    }

    /// Every field comes off the entry, and the channel-level `<title>`/`<name>` are not
    /// mistaken for part of it.
    func testAnEntryBecomesAVideo() throws {
        let xml = feed(entry(
            id: "dQw4w9WgXcQ",
            title: "A long video",
            link: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            views: 4242
        ))

        let videos = YouTubeRssParser.parse(xml)

        XCTAssertEqual(videos.count, 1)
        let video = try XCTUnwrap(videos.first)
        XCTAssertEqual(video.videoId, "dQw4w9WgXcQ")
        XCTAssertEqual(video.title, "A long video")
        XCTAssertEqual(video.channelId, "UC123")
        XCTAssertEqual(video.channelName, "Some Channel")
        XCTAssertEqual(video.viewCount, 4242)
        XCTAssertEqual(video.thumbnailUrl, "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
        XCTAssertFalse(video.isShort)
        XCTAssertFalse(video.isLive)
        XCTAssertEqual(
            video.publishedAtEpochMillis,
            YouTubeRssParser.parsePublished("2024-01-01T12:00:00+00:00")
        )
        XCTAssertGreaterThan(video.publishedAtEpochMillis, 0)
    }

    /// YouTube's own canonical link decides: `/shorts/` is a Short, `/watch?v=` is not,
    /// regardless of what the title says.
    func testTheCanonicalLinkClassifiesShorts() {
        let xml = feed(
            entry(id: "shortoned", title: "Silly cats", link: "https://www.youtube.com/shorts/shortoned")
                + entry(id: "longone12", title: "A #shorts styled long video", link: "https://www.youtube.com/watch?v=longone12")
        )

        let videos = YouTubeRssParser.parse(xml)

        XCTAssertEqual(videos.map(\.isShort), [true, false])
    }

    /// Without the link, the fallbacks are the hashtag and the caller's scraped ids —
    /// and a live broadcast is never a Short, even when its id turns up in the scrape.
    func testTheFallbacksClassifyShortsButNeverALiveBroadcast() {
        let xml = feed(
            entry(id: "hashtag0001", title: "Quick one #shorts", link: nil)
                + entry(id: "scrapedid01", title: "No hashtag", link: nil)
                + entry(
                    id: "liveid00001",
                    title: "Live now",
                    link: nil,
                    thumbnailSuffix: "hqdefault_live.jpg"
                )
        )

        let videos = YouTubeRssParser.parse(xml, shortsIds: ["scrapedid01", "liveid00001"])

        XCTAssertEqual(videos[0].isShort, true, "the hashtag is a valid fallback")
        XCTAssertEqual(videos[1].isShort, true, "so is the channel's /shorts scrape")
        XCTAssertEqual(videos[2].isShort, false, "a live broadcast is never a Short")
        XCTAssertTrue(videos[2].isLive)
    }

    /// The live signal is the thumbnail, in either size and in any case.
    func testTheLiveThumbnailIsTheLiveSignal() {
        let xml = feed(
            entry(id: "livesmall01", title: "Live", link: nil, thumbnailSuffix: "hqdefault_live.jpg")
                + entry(id: "livebig0001", title: "Live HD", link: nil, thumbnailSuffix: "maxresdefault_LIVE.jpg")
                + entry(id: "notlive0001", title: "Normal", link: nil)
        )

        let videos = YouTubeRssParser.parse(xml)

        XCTAssertEqual(videos.map(\.isLive), [true, true, false])
    }

    /// An entry with no id is skipped, and the rest of the feed still loads.
    func testABrokenEntryDoesNotLoseTheFeed() {
        let xml = feed(
            entry(id: "firstok0001", title: "First", link: "https://www.youtube.com/watch?v=firstok0001")
                + "<entry><title>No id at all</title></entry>"
                + entry(id: "secondok001", title: "Second", link: "https://www.youtube.com/watch?v=secondok001")
        )

        let videos = YouTubeRssParser.parse(xml)

        XCTAssertEqual(videos.map(\.videoId), ["firstok0001", "secondok001"])
    }

    /// A feed that is not a feed yields nothing rather than throwing — the caller shows
    /// "nothing new" instead of an error.
    func testUnparseableInputIsEmpty() {
        XCTAssertEqual(YouTubeRssParser.parse("").count, 0)
        XCTAssertEqual(YouTubeRssParser.parse("not xml at all").count, 0)
        XCTAssertEqual(YouTubeRssParser.parse("<feed><entry>").count, 0)
        XCTAssertEqual(YouTubeRssParser.parse(feed("")).count, 0, "a feed with no entries is empty")
    }

    /// A missing thumbnail falls back to the deterministic `i.ytimg.com` URL, and a
    /// missing or malformed timestamp reads as 0 rather than failing the entry.
    func testMissingFieldsFallBack() {
        let xml = feed("""
        <entry>
          <yt:videoId>fallback001</yt:videoId>
          <title>Bare entry</title>
          <published>not a date</published>
        </entry>
        """)

        let videos = YouTubeRssParser.parse(xml)

        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos[0].thumbnailUrl, "https://i.ytimg.com/vi/fallback001/hqdefault.jpg")
        XCTAssertEqual(videos[0].publishedAtEpochMillis, 0)
        XCTAssertEqual(videos[0].viewCount, 0)
        XCTAssertEqual(videos[0].channelName, "")
        XCTAssertEqual(videos[0].isShort, false, "no link, no hashtag, not scraped")
    }

    /// A malformed view count does not become a crash or a negative number.
    func testAMalformedViewCountReadsAsZero() {
        let xml = feed("""
        <entry>
          <yt:videoId>badviews001</yt:videoId>
          <title>Views</title>
          <media:group><media:community><media:statistics views="lots"/></media:community></media:group>
        </entry>
        """)

        XCTAssertEqual(YouTubeRssParser.parse(xml).first?.viewCount, 0)
    }

    /// The feed is returned in the order it arrived in — YouTube publishes newest first,
    /// and the parser does not re-order it behind the caller's back.
    func testTheFeedOrderIsPreserved() {
        let xml = feed(
            entry(id: "newest00001", title: "Newest", link: nil, published: "2024-03-01T00:00:00+00:00")
                + entry(id: "middle00001", title: "Middle", link: nil, published: "2024-02-01T00:00:00+00:00")
                + entry(id: "oldest00001", title: "Oldest", link: nil, published: "2024-01-01T00:00:00+00:00")
        )

        XCTAssertEqual(YouTubeRssParser.parse(xml).map(\.videoId), ["newest00001", "middle00001", "oldest00001"])
    }

    /// The timestamps are real instants, so the feed can be ordered against any other
    /// source's items.
    func testPublishedTimestampsAreComparable() {
        let earlier = YouTubeRssParser.parsePublished("2024-01-01T12:00:00+00:00")
        let later = YouTubeRssParser.parsePublished("2024-06-01T12:00:00+00:00")
        let offset = YouTubeRssParser.parsePublished("2024-01-01T17:30:00+05:30")

        XCTAssertLessThan(earlier, later)
        XCTAssertEqual(earlier, offset, "the same instant written with an offset is the same instant")
        XCTAssertEqual(YouTubeRssParser.parsePublished(""), 0)
    }
}

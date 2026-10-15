import XCTest
@testable import ClearView

/// Tests for the Media feed's item model and its filter rules.
///
/// "Why is this video missing?" is almost always a filter question, so the cases below
/// are the ones the Android app was fixed for: platform and content type checked
/// together, Reels that are not posts, watch status that treats "never started" as
/// unwatched, and the persisted filters that must never lock the feed behind a chip the
/// user cannot reach.
final class MediaFeedFilterTests: XCTestCase {

    private let now: Int64 = 1_800_000_000_000
    private let day: Int64 = 24 * 60 * 60 * 1000

    private func video(
        _ id: String,
        hoursAgo: Int64 = 1,
        platform: MediaPlatform = .youTube,
        isShort: Bool = false,
        isLive: Bool = false,
        instagramType: InstagramMediaType? = nil,
        mediaUrl: String? = nil
    ) -> MediaVideo {
        MediaVideo(
            videoId: id,
            title: "Video \(id)",
            channelId: "channel",
            channelName: "Channel",
            publishedAtEpochMillis: now - hoursAgo * 3_600_000,
            thumbnailUrl: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg",
            isShort: isShort,
            isLive: isLive,
            platform: platform,
            instagramType: instagramType,
            mediaUrl: mediaUrl
        )
    }

    // MARK: - The item model

    /// A short signal from the title is word-bounded: `#shortsy` and plain `#short` are
    /// not Shorts, and the tag's position in the title does not matter.
    func testTheShortsHashtagSignalIsWordBounded() {
        XCTAssertTrue(MediaVideo.isShortsTitle("A quick one #shorts"))
        XCTAssertTrue(MediaVideo.isShortsTitle("#SHORTS"))
        XCTAssertTrue(MediaVideo.isShortsTitle("Look #shorts!"))
        XCTAssertTrue(MediaVideo.isShortsTitle("Two tags #viral #shorts"))
        XCTAssertFalse(MediaVideo.isShortsTitle("A quick one #shortsy"))
        XCTAssertFalse(MediaVideo.isShortsTitle("A quick one #shortsfortruth"))
        XCTAssertFalse(MediaVideo.isShortsTitle("This is a #short video"))
        XCTAssertFalse(MediaVideo.isShortsTitle("No hashtag at all"))
        XCTAssertFalse(
            MediaVideo.isShortsTitle("Trailing #shorts_"),
            "an underscore continues the word, so this is a longer tag and not a Short"
        )
    }

    /// Reels share the Shorts surface, including older cached entries.
    func testShortsIncludeInstagramReels() {
        XCTAssertTrue(video("a", isShort: true).isShortsEntry)
        XCTAssertTrue(video("b", platform: .instagram, isShort: true, instagramType: .reel).isShortsEntry)
        XCTAssertFalse(video("c").isShortsEntry)
        XCTAssertTrue(video("legacy", platform: .instagram, isShort: true).isShortsEntry)
        XCTAssertFalse(video("long", platform: .instagram, isShort: true, instagramType: .video).isShortsEntry)
    }

    /// The Instagram type decides both ways, and only a missing type falls back to the
    /// media URL.
    func testInstagramVideoAndImageClassification() {
        XCTAssertTrue(video("a", platform: .instagram, instagramType: .reel).isInstagramVideo)
        XCTAssertTrue(video("b", platform: .instagram, instagramType: .video).isInstagramVideo)
        XCTAssertFalse(
            video("c", platform: .instagram, instagramType: .image).isInstagramVideo,
            "an image post is never a video"
        )
        XCTAssertFalse(
            video("d", platform: .instagram, instagramType: .carousel, mediaUrl: "https://x/clip.mp4").isInstagramVideo,
            "a carousel that happens to hold a video is still a post"
        )
        XCTAssertTrue(
            video("e", platform: .instagram, mediaUrl: "https://x/clip.mp4").isInstagramVideo,
            "with no type at all, a progressive video URL is the evidence"
        )
        XCTAssertTrue(video("f", platform: .instagram, instagramType: .image).isInstagramImage)
        XCTAssertTrue(video("g", platform: .instagram, instagramType: .carousel).isInstagramImage)
    }

    /// The legacy `ig_` id prefix is enough to recognise an Instagram item.
    func testTheLegacyInstagramIdPrefixIsRecognised() {
        let legacy = MediaVideo(
            videoId: "ig_ABC123",
            title: "Post",
            channelId: "c",
            channelName: "C",
            publishedAtEpochMillis: now,
            thumbnailUrl: ""
        )

        XCTAssertTrue(legacy.isInstagram)
        XCTAssertTrue(legacy.isInstagramImage, "with no type and no media URL it is a still")
    }

    /// A playable URL is a stream; anything else on X is a post, which is the
    /// distinction that stops tweets rendering as broken videos.
    func testPlayableMediaAndPosts() {
        XCTAssertTrue(video("a", mediaUrl: "https://x/clip.MP4").hasPlayableVideo)
        XCTAssertTrue(video("b", mediaUrl: "https://x/master.m3u8").hasPlayableVideo)
        XCTAssertTrue(video("c", mediaUrl: "https://x/clip.webm").hasPlayableVideo)
        XCTAssertFalse(video("d", mediaUrl: "https://x/photo.jpg").hasPlayableVideo)
        XCTAssertFalse(video("e").hasPlayableVideo)

        XCTAssertTrue(video("f", platform: .x).isPost, "an X item with no video is a post")
        XCTAssertFalse(video("g", platform: .x, mediaUrl: "https://x/clip.mp4").isPost)
        XCTAssertFalse(video("h").isPost, "a YouTube video is never a post")
    }

    /// A playlist may hold a video **and** its offline audio: the two share an id and
    /// must still be two rows.
    func testOfflineAudioSharesTheIdButNotTheRow() {
        var audio = video("dQw4w9WgXcQ")
        audio = MediaVideo(
            videoId: audio.videoId,
            title: audio.title,
            channelId: audio.channelId,
            channelName: audio.channelName,
            publishedAtEpochMillis: audio.publishedAtEpochMillis,
            thumbnailUrl: audio.thumbnailUrl,
            isOfflineAudio: true
        )

        XCTAssertEqual(audio.videoId, "dQw4w9WgXcQ")
        XCTAssertNotEqual(audio.id, video("dQw4w9WgXcQ").id)
    }

    // MARK: - The date preset

    /// "Today" is the local day, not the last 24 hours, and each preset keeps everything
    /// at or after its start.
    func testDatePresetsFilterByWindow() {
        let videos = [
            video("this-morning", hoursAgo: 2),
            video("two-days", hoursAgo: 48),
            video("five-days", hoursAgo: 24 * 5),
            video("forty-days", hoursAgo: 24 * 40),
        ]

        func ids(_ filter: FeedFilter) -> [String] {
            FeedFilters.apply(videos, filter: filter, now: now).map(\.videoId).sorted()
        }

        XCTAssertEqual(ids(FeedFilter(date: .today, watchStatus: .all)).count, 1)
        XCTAssertEqual(ids(FeedFilter(date: .last3Days, watchStatus: .all)).count, 2)
        XCTAssertEqual(ids(FeedFilter(date: .last7Days, watchStatus: .all)).count, 3)
        XCTAssertEqual(ids(FeedFilter(date: .last30Days, watchStatus: .all)).count, 3)
        XCTAssertEqual(ids(FeedFilter(date: .allTime, watchStatus: .all)).count, 4)
    }

    /// A custom range is inclusive at both ends, and only applies when the date filter
    /// actually is custom.
    func testACustomRangeIsInclusiveAndOnlyUsedWhenSelected() {
        let videos = [video("first", hoursAgo: 72), video("middle", hoursAgo: 48), video("last", hoursAgo: 24)]
        let start = now - 72 * 3_600_000
        let end = now - 24 * 3_600_000

        // Newest first is the default sort, so the range comes back in that order
        // rather than the order it was handed over in.
        let custom = FeedFilters.apply(
            videos,
            filter: FeedFilter(
                date: .custom,
                watchStatus: .all,
                customStartEpochMillis: start,
                customEndEpochMillis: end
            ),
            now: now
        )
        XCTAssertEqual(custom.map(\.videoId), ["last", "middle", "first"])

        // The boundaries are inclusive: a window that starts exactly 25 hours ago and
        // ends exactly an hour ago holds the 24-hour-old video and nothing else.
        let narrowed = FeedFilters.apply(
            videos,
            filter: FeedFilter(
                date: .custom,
                watchStatus: .all,
                customStartEpochMillis: now - 25 * 3_600_000,
                customEndEpochMillis: now - 3_600_000
            ),
            now: now
        )
        XCTAssertEqual(narrowed.map(\.videoId), ["last"])

        let notCustom = FeedFilters.apply(
            videos,
            filter: FeedFilter(date: .allTime, watchStatus: .all, customStartEpochMillis: now, customEndEpochMillis: now),
            now: now
        )
        XCTAssertEqual(notCustom.count, 3, "a stored range is ignored unless the date filter is custom")
    }

    // MARK: - Platform and content

    /// Content type and platform are checked together, so "Shorts" means YouTube Shorts.
    func testContentFiltersRespectThePlatform() {
        let videos = [
            video("long", platform: .youTube),
            video("short", platform: .youTube, isShort: true),
            video("live", platform: .youTube, isLive: true),
            video("reel", platform: .instagram, instagramType: .reel),
            video("ig-image", platform: .instagram, instagramType: .image),
            video("tweet", platform: .x),
        ]

        func ids(_ content: FeedContentFilter, _ platform: FeedPlatformFilter = .all) -> [String] {
            FeedFilters.apply(videos, filter: FeedFilter(platform: platform, content: content, watchStatus: .all), now: now)
                .map(\.videoId)
                .sorted()
        }

        XCTAssertEqual(ids(.all).count, 6)
        // "Videos" is "YouTube and not a Short", which is Android's rule and therefore
        // includes a live broadcast — the Live preset is the way to single those out.
        XCTAssertEqual(ids(.videos), ["live", "long"])
        XCTAssertEqual(ids(.shorts), ["reel", "short"])
        XCTAssertEqual(ids(.live), ["live"])
        XCTAssertEqual(ids(.reels), ["reel"], "a Reel is a video, a carousel or photo is not")
        XCTAssertEqual(ids(.imagePosts), ["ig-image", "tweet"])
        XCTAssertEqual(ids(.downloads), [], "Downloads is handled by the screen, not the list")

        XCTAssertEqual(ids(.all, .instagram), ["ig-image", "reel"])
        XCTAssertEqual(ids(.all, .x), ["tweet"])
        XCTAssertEqual(ids(.all, .youTube), ["live", "long", "short"])
    }

    /// The watch-status filter treats "never started" as unwatched, and the two
    /// non-default states are mutually exclusive.
    func testWatchStatusFilter() {
        let videos = [video("fresh"), video("started"), video("done")]
        let progress: [String: Float] = ["started": 0.4, "done": 0.95]

        func ids(_ status: FeedWatchStatus) -> [String] {
            FeedFilters.apply(
                videos,
                filter: FeedFilter(watchStatus: status),
                now: now,
                progressOf: { progress[$0] }
            )
            .map(\.videoId)
            .sorted()
        }

        XCTAssertEqual(ids(.all).count, 3)
        XCTAssertEqual(ids(.unwatched), ["fresh"], "0.4 is past the point of \"unwatched\"")
        XCTAssertEqual(ids(.watched), ["done"])
        XCTAssertEqual(ids(.partiallyWatched), ["started"])

        // The boundaries themselves: exactly 2% counts as started, exactly 90% as done.
        let boundary = [video("at-start"), video("at-watched")]
        let edge: [String: Float] = ["at-start": 0.02, "at-watched": 0.9]
        let partial = FeedFilters.apply(
            boundary,
            filter: FeedFilter(watchStatus: .partiallyWatched),
            now: now,
            progressOf: { edge[$0] }
        )
        XCTAssertEqual(partial.map(\.videoId), ["at-start"])
        let watched = FeedFilters.apply(
            boundary,
            filter: FeedFilter(watchStatus: .watched),
            now: now,
            progressOf: { edge[$0] }
        )
        XCTAssertEqual(watched.map(\.videoId), ["at-watched"])
    }

    /// Where an item came from: by URL, or from the channels. "By RSS" means the same
    /// thing as "From channels" in the feed.
    func testSourceFilter() {
        let videos = [video("manual"), video("feed")]
        let manual: Set<String> = ["manual"]

        func ids(_ source: FeedSourceFilter) -> [String] {
            FeedFilters.apply(
                videos,
                filter: FeedFilter(watchStatus: .all, source: source),
                now: now,
                isManual: { manual.contains($0) }
            )
            .map(\.videoId)
            .sorted()
        }

        XCTAssertEqual(ids(.all).count, 2)
        XCTAssertEqual(ids(.byUrl), ["manual"])
        XCTAssertEqual(ids(.system), ["feed"])
        XCTAssertEqual(ids(.byRss), ["feed"])
    }

    /// Sort is newest-first by default and oldest-first on request.
    func testSortOrder() {
        let videos = [video("old", hoursAgo: 72), video("new", hoursAgo: 1), video("middle", hoursAgo: 24)]

        XCTAssertEqual(
            FeedFilters.apply(videos, filter: FeedFilter(watchStatus: .all), now: now).map(\.videoId),
            ["new", "middle", "old"]
        )
        XCTAssertEqual(
            FeedFilters.apply(videos, filter: FeedFilter(sort: .oldestFirst, watchStatus: .all), now: now).map(\.videoId),
            ["old", "middle", "new"]
        )
    }

    /// Sorting is stable: two items published in the same second keep their input order.
    func testSortingIsStableForEqualTimes() {
        let first = video("first", hoursAgo: 1)
        let second = video("second", hoursAgo: 1)

        XCTAssertEqual(
            FeedFilters.apply([first, second], filter: FeedFilter(watchStatus: .all), now: now).map(\.videoId),
            ["first", "second"]
        )
        XCTAssertEqual(
            FeedFilters.apply([second, first], filter: FeedFilter(watchStatus: .all), now: now).map(\.videoId),
            ["second", "first"]
        )
    }

    // MARK: - Persistence

    /// A filter survives the round trip, including the custom range.
    func testTheFilterRoundTripsThroughItsJson() {
        let filter = FeedFilter(
            date: .custom,
            platform: .instagram,
            content: .reels,
            sort: .oldestFirst,
            watchStatus: .partiallyWatched,
            source: .byUrl,
            playlistType: .video,
            customStartEpochMillis: 1_700_000_000_000,
            customEndEpochMillis: 1_700_000_100_000
        )

        XCTAssertEqual(FeedFilters.decode(FeedFilters.encode(filter)), filter)
    }

    /// An older stored value loads with defaults for the keys it does not have, and a
    /// missing or unreadable one falls back to the caller's default.
    func testDecodingOlderAndBrokenFilters() {
        let older = """
        {"date":"LAST_7_DAYS","platform":"YOUTUBE","content":"VIDEOS","sort":"NEWEST_FIRST"}
        """
        let decoded = FeedFilters.decode(older)

        XCTAssertEqual(decoded?.date, .last7Days)
        XCTAssertEqual(decoded?.platform, .youTube)
        XCTAssertEqual(decoded?.content, .videos)
        XCTAssertEqual(decoded?.watchStatus, .unwatched, "the newer keys fall back to their defaults")
        XCTAssertEqual(decoded?.source, .all)
        XCTAssertEqual(decoded?.playlistType, .all)
        XCTAssertNil(decoded?.customStartEpochMillis)

        XCTAssertNil(FeedFilters.decode(nil))
        XCTAssertNil(FeedFilters.decode(""))
        XCTAssertNil(FeedFilters.decode("not json"))
        XCTAssertNil(FeedFilters.decode("{\"date\":\"NOT_A_DATE\",\"content\":\"ALL\",\"sort\":\"NEWEST_FIRST\"}"))
        XCTAssertNil(
            FeedFilters.decode("{\"date\":\"TODAY\",\"content\":\"NOT_A_TYPE\",\"sort\":\"NEWEST_FIRST\"}"),
            "an unreadable date or content filter is rejected, not silently defaulted"
        )
    }

    /// A stored `live` content filter is migrated to `all`: Live was removed from the
    /// sheet, and an unreachable filter would lock the feed to something the user cannot
    /// clear.
    func testAStoredLiveFilterIsMigratedAway() {
        let stored = """
        {"date":"LAST_3_DAYS","platform":"ALL","content":"LIVE","sort":"NEWEST_FIRST","playlistType":"ALL"}
        """

        XCTAssertEqual(FeedFilters.decode(stored)?.content, .all)
    }

    /// A stored `allTime` date is *not* migrated: it is still an option, so rewriting it
    /// would silently discard the user's own choice on every restart.
    func testAStoredAllTimeFilterIsKept() {
        let stored = """
        {"date":"ALL_TIME","platform":"ALL","content":"ALL","sort":"NEWEST_FIRST","playlistType":"ALL"}
        """

        XCTAssertEqual(FeedFilters.decode(stored)?.date, .allTime)
    }

    // MARK: - What each platform offers, and what the summary says

    /// Switching platform resets a selection the new platform does not offer — the fix
    /// for "Reels is selected but there is no chip for it and the feed is empty".
    func testContentOptionsAndNormalisation() {
        XCTAssertEqual(FeedFilters.contentOptions(for: .youTube), [.all, .videos, .shorts, .downloads])
        XCTAssertEqual(FeedFilters.contentOptions(for: .instagram), [.all, .shorts, .videos, .imagePosts, .downloads])
        XCTAssertEqual(FeedFilters.contentOptions(for: .x), [.all, .videos, .imagePosts, .downloads])
        XCTAssertFalse(
            FeedFilters.contentOptions(for: .all).contains(.live),
            "Live is not offered from this sheet"
        )

        let reelsOnYouTube = FeedFilter(platform: .youTube, content: .reels)
        XCTAssertEqual(FeedFilters.normalizedForPlatform(reelsOnYouTube).content, .all)

        let reelsOnInstagram = FeedFilter(platform: .instagram, content: .reels)
        XCTAssertEqual(FeedFilters.normalizedForPlatform(reelsOnInstagram).content, .shorts)
    }

    /// The default filter reports itself as inactive, and any change from the defaults
    /// reports as active.
    func testTheActiveIndicator() {
        XCTAssertFalse(FeedFilter().isActive)
        XCTAssertTrue(FeedFilter(date: .today).isActive)
        XCTAssertTrue(FeedFilter(platform: .instagram).isActive)
        XCTAssertTrue(FeedFilter(content: .shorts).isActive)
        XCTAssertTrue(FeedFilter(sort: .oldestFirst).isActive)
        XCTAssertTrue(FeedFilter(watchStatus: .all).isActive)
        XCTAssertTrue(FeedFilter(source: .byUrl).isActive)
        XCTAssertTrue(FeedFilter(playlistType: .audio).isActive)
        XCTAssertFalse(
            FeedFilter(customStartEpochMillis: now, customEndEpochMillis: now).isActive,
            "a stored range means nothing while the date filter is not custom"
        )
    }

    /// The summary names only what differs, states the window when asked, and counts the
    /// results — including the platform and the sort, which the older line dropped.
    func testTheFilterSummary() {
        XCTAssertEqual(FeedFilters.summary(FeedFilter()), "")
        XCTAssertEqual(
            FeedFilters.summary(FeedFilter(), includeDefaultDate: true),
            "Last 3 days",
            "the feed header always states its window"
        )
        XCTAssertEqual(
            FeedFilters.summary(FeedFilter(platform: .instagram, content: .reels, sort: .oldestFirst)),
            "Instagram · Reels · Oldest first"
        )
        XCTAssertEqual(
            FeedFilters.feedSummary(FeedFilter(), resultCount: 1),
            "Last 3 days · 1 video"
        )
        XCTAssertEqual(
            FeedFilters.feedSummary(FeedFilter(watchStatus: .all), resultCount: 24),
            "Last 3 days · All · 24 videos"
        )
        XCTAssertEqual(
            FeedFilters.summary(
                FeedFilter(source: .system, playlistType: .audio),
                playlistContext: true
            ),
            "Audio · From device",
            "inside a playlist, \"From channels\" reads as the device audio it really is"
        )
        XCTAssertEqual(
            FeedFilters.dateLabel(FeedFilter(date: .custom)),
            "Custom",
            "a custom filter with no range says so rather than inventing dates"
        )
    }
}

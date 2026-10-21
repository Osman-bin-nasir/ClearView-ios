import XCTest
@testable import ClearView

/// The two pieces of Media's playlist support that are pure logic: reading a
/// YouTube playlist page, and the sentence the app says after emptying Continue
/// Watching.
///
/// Both are ports of Android tests
/// (`media/util/ContinueWatchingMessagesTest.kt` and the playlist parser's cases),
/// pinned here so the two platforms cannot drift into naming a playlist's videos
/// differently or telling a reader they cleared something they did not.
final class MediaPlaylistTests: XCTestCase {

    // MARK: - Continue Watching

    /// The count the store reports becomes a sentence, and the two ends of it
    /// matter: "cleared 4" and "there was nothing to clear".
    func testTheResetMessageReportsHowManyResumePositionsWent() {
        XCTAssertEqual(MediaLibrary.resetContinueWatchingMessage(cleared: 1), "Cleared 1 resume position")
        XCTAssertEqual(MediaLibrary.resetContinueWatchingMessage(cleared: 4), "Cleared 4 resume positions")
    }

    /// 0 is what the store returns for a row that was already empty, so the
    /// message must not claim it cleared anything — and a negative count can only
    /// mean the same thing.
    func testAnEmptyResetSaysSoRatherThanClaimingSuccess() {
        XCTAssertEqual(MediaLibrary.resetContinueWatchingMessage(cleared: 0), "Continue Watching was already empty")
        XCTAssertEqual(MediaLibrary.resetContinueWatchingMessage(cleared: -1), "Continue Watching was already empty")
    }

    // MARK: - Reading a playlist page

    /// A page whose videos come from a single array is read in **document order**,
    /// which is the playlist's own order.
    ///
    /// The ids are chosen so document order and alphabetical order disagree: a
    /// parser that let the JSON dictionary decide, or that sorted the result,
    /// would return them the other way round and shuffle a reader's playlist.
    func testVideosAreReadInPlaylistOrderNotAlphabeticalOrder() {
        let first = "zzzzzzzzzzz"
        let second = "aaaaaaaaaaa"
        let html = page(
            lockupJSON(id: first, title: "First in the playlist", channel: "Chan B", duration: "3:55")
            + "," +
            lockupJSON(id: second, title: "Second in the playlist", channel: "Chan A", duration: "1:02:03")
        )

        let imported = YouTubePlaylistImporter.parse(html: html, playlistId: "PLtest")

        XCTAssertEqual(imported?.title, "Test playlist")
        XCTAssertEqual(imported?.videos.map(\.id), [first, second])
        XCTAssertEqual(imported?.videos.map(\.title), ["First in the playlist", "Second in the playlist"])
    }

    /// Every field the feed needs comes out of the modern `lockupViewModel` shape —
    /// the one YouTube's playlist pages actually serve.
    func testTheModernPlaylistShapeProvidesTitleChannelDurationAndStill() {
        let html = page(lockupJSON(id: "dQw4w9WgXcQ", title: "A song", channel: "Peso Pluma", duration: "3:55"))

        let video = YouTubePlaylistImporter.parse(html: html, playlistId: "PLtest")?.videos.first

        XCTAssertEqual(video?.id, "dQw4w9WgXcQ")
        XCTAssertEqual(video?.title, "A song")
        XCTAssertEqual(video?.channel, "Peso Pluma")
        XCTAssertEqual(video?.durationSeconds, 3 * 60 + 55)
        XCTAssertEqual(video?.url, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(video?.isYouTube, true)
    }

    /// The older `playlistVideoRenderer` shape is still readable, so a page served
    /// in the classic format does not read as an unreadable playlist.
    func testTheClassicPlaylistShapeIsStillReadable() {
        let html = page(
            """
            {"playlistVideoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"Classic entry"}]},
            "shortBylineText":{"runs":[{"text":"Some Channel"}]},
            "lengthText":{"simpleText":"10:50"},
            "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"}]}}}
            """
        )

        let video = YouTubePlaylistImporter.parse(html: html, playlistId: "PLtest")?.videos.first

        XCTAssertEqual(video?.id, "abcdefghijk")
        XCTAssertEqual(video?.title, "Classic entry")
        XCTAssertEqual(video?.channel, "Some Channel")
        XCTAssertEqual(video?.durationSeconds, 10 * 60 + 50)
    }

    /// A page that is not a playlist at all — a consent wall, an error page — has
    /// no `ytInitialData`, and must read as unreadable rather than as an empty
    /// playlist the reader then tries to open.
    func testAPageWithoutInitialDataIsUnreadable() {
        XCTAssertNil(YouTubePlaylistImporter.parse(html: "<html><body>nope</body></html>", playlistId: "PLtest"))
    }

    /// A `lockupViewModel` that is not a video (a channel, a shelf) carries an id
    /// too, so the kind has to be checked or a channel would be imported as a
    /// video that plays nothing.
    func testANonVideoLockupIsNotImportedAsAVideo() {
        let channel = """
        {"lockupViewModel":{"contentId":"UCzrM_068Odho89mTRrrxqbA","contentType":"LOCKUP_CONTENT_TYPE_CHANNEL",
        "metadata":{"lockupMetadataViewModel":{"title":{"content":"A channel"}}}}}
        """
        let real = lockupJSON(id: "dQw4w9WgXcQ", title: "A song", channel: "Chan", duration: "1:00")
        let videos = YouTubePlaylistImporter.parse(html: page(channel + "," + real), playlistId: "PLtest")?.videos

        XCTAssertEqual(videos?.map(\.id), ["dQw4w9WgXcQ"])
    }

    // MARK: - An imported playlist's cache

    /// An imported playlist's videos must actually land in the cache.
    ///
    /// This is a regression test with a specific cause: `dict?[key] = value` on a
    /// **nil** dictionary is a silent no-op in Swift, so the import fetched the videos,
    /// reported success, and cached nothing. The manager's card then read its count out
    /// of an empty cache — "0 videos" — and opening the playlist re-fetched it from
    /// YouTube every time, because "nothing cached" is exactly what a no-op leaves
    /// behind. The number asserted here is the number the card drew.
    @MainActor
    func testImportedPlaylistVideosAreCachedSoTheCardCountsThem() {
        let suite = "cv.media.playlist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MediaLibrary(defaults: defaults)

        // A library that has never held one: the dictionary is nil, which is the
        // state the bug needed. Asserted rather than assumed, so this test cannot
        // quietly stop covering the bug it was written for.
        XCTAssertNil(library.state.importedPlaylistVideos)
        XCTAssertEqual(library.cachedPlaylistVideos("PLtest").count, 0)

        library.storeImportedPlaylistVideos("PLtest", videos: [
            LibraryVideo(id: "aaaaaaaaaaa", title: "One", url: "https://www.youtube.com/watch?v=aaaaaaaaaaa"),
            LibraryVideo(id: "bbbbbbbbbbb", title: "Two", url: "https://www.youtube.com/watch?v=bbbbbbbbbbb"),
        ])

        XCTAssertEqual(library.cachedPlaylistVideos("PLtest").count, 2)
        XCTAssertEqual(library.cachedPlaylistVideos("PLtest").first?.title, "One")
    }

    /// Unsubscribing is a hide, not a toggle, and muting is a different state
    /// altogether — the two the channel list's bell and ✕ write.
    @MainActor
    func testHidingAChannelIsIdempotentAndMutingIsASeparateState() {
        let suite = "cv.media.channels.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MediaLibrary(defaults: defaults)
        let channel = library.state.channels.first!

        library.hideChannel(channel.id)
        library.hideChannel(channel.id)
        XCTAssertEqual((library.state.hiddenChannelIDs ?? []).filter { $0 == channel.id }.count, 1,
                       "hiding twice must not put the id in twice")
        XCTAssertFalse(library.isChannelMuted(channel.id), "hiding is not muting")

        library.toggleChannelNotifications(channel)
        XCTAssertTrue(library.isChannelMuted(channel.id))
        // A muted channel is still subscribed and still in the feed; only its
        // notifications are off, so un-hiding it later must not have been the same tap.
        library.toggleChannelNotifications(channel)
        XCTAssertFalse(library.isChannelMuted(channel.id))
    }

    // MARK: - Fixtures

    /// A minimal playlist page: the real one is ~2 MB of embedded JSON, so the
    /// shape is reproduced rather than the file captured.
    private func page(_ videosJSON: String) -> String {
        """
        <html><head></head><body><script>
        var ytInitialData = {"metadata":{"playlistMetadataRenderer":{"title":"Test playlist"}},
        "contents":[{"itemSectionRenderer":{"contents":[\(videosJSON)]}}]};
        </script></body></html>
        """
    }

    /// One modern playlist entry, spelled the way the page spells it.
    private func lockupJSON(id: String, title: String, channel: String, duration: String) -> String {
        """
        {"lockupViewModel":{"contentId":"\(id)","contentType":"LOCKUP_CONTENT_TYPE_VIDEO",
        "metadata":{"lockupMetadataViewModel":{"title":{"content":"\(title)"},
        "image":{"decoratedAvatarViewModel":{"a11yLabel":"Go to channel \(channel)"}}}},
        "contentImage":{"thumbnailViewModel":{
        "image":{"sources":[{"url":"https://i.ytimg.com/vi/\(id)/hqdefault.jpg"}]},
        "overlays":[{"thumbnailBottomOverlayViewModel":{"badges":[{"thumbnailBadgeViewModel":{"text":"\(duration)"}}]}}]}}}}
        """
    }
}

import XCTest
@testable import ClearView

/// Tests for the audio pipeline (extraction, download chunking, the sleep timer
/// and the on-disk manifest) and for the Instagram / X feed sources.
///
/// The extraction *selection* rules are tested rather than the network call,
/// because the network is the part that cannot be made deterministic: what this
/// code has to get right is which of YouTube's advertised formats it picks, and
/// that is pure. The live endpoint is exercised by hand against the device.
final class MediaAudioTests: XCTestCase {

    // MARK: - YouTube stream selection

    private func format(
        _ itag: Int,
        _ mimeType: String,
        _ bitrate: Int,
        url: String? = "https://example.invalid/audio",
        contentLength: Int64? = nil,
        audioIsDefault: Bool? = nil,
        hasAudioTrack: Bool = false
    ) -> InnertubeAudioFormat {
        InnertubeAudioFormat(
            itag: itag, mimeType: mimeType, bitrate: bitrate, url: url,
            contentLength: contentLength, audioIsDefault: audioIsDefault, hasAudioTrack: hasAudioTrack
        )
    }

    func testSelectsHighestBitrateWithinThePlayablePool() {
        let formats = [
            format(139, #"audio/mp4; codecs="mp4a.40.5""#, 50_152),
            format(140, #"audio/mp4; codecs="mp4a.40.2""#, 130_677),
            format(249, #"audio/webm; codecs="opus""#, 49_496),
            format(251, #"audio/webm; codecs="opus""#, 136_544)
        ]
        // 251 has the top bitrate but is Opus-in-WebM, which AVPlayer cannot
        // decode; 140 is the best AAC, so that is what has to win.
        XCTAssertEqual(YouTubeAudioExtractor.selectBestAudio(formats)?.itag, 140)
    }

    func testPrefersTheOriginalAudioTrackOverAHigherBitrateDub() {
        // The "downloads came out in Arabic" bug: dubs are frequently
        // higher-bitrate than the original, so bitrate alone picks the dub.
        let formats = [
            format(140, #"audio/mp4; codecs="mp4a.40.2""#, 130_000,
                   audioIsDefault: true, hasAudioTrack: true),
            format(140, #"audio/mp4; codecs="mp4a.40.2""#, 200_000,
                   audioIsDefault: false, hasAudioTrack: true)
        ]
        let selected = YouTubeAudioExtractor.selectBestAudio(formats)
        XCTAssertEqual(selected?.bitrate, 130_000)
        XCTAssertEqual(selected?.audioIsDefault, true)
    }

    func testUntaggedStreamsArePreferredWhenNoTrackIsMarkedDefault() {
        let formats = [
            format(140, #"audio/mp4; codecs="mp4a.40.2""#, 90_000, audioIsDefault: false, hasAudioTrack: true),
            format(140, #"audio/mp4; codecs="mp4a.40.2""#, 80_000)
        ]
        XCTAssertEqual(YouTubeAudioExtractor.selectBestAudio(formats)?.bitrate, 80_000)
    }

    func testFallsBackToOpusWhenNothingElseIsOffered() {
        // A saved .webm will not play, but dropping the video entirely would be
        // worse than offering it — the download still succeeds.
        let formats = [format(251, #"audio/webm; codecs="opus""#, 136_544)]
        XCTAssertEqual(YouTubeAudioExtractor.selectBestAudio(formats)?.itag, 251)
    }

    func testSelectReturnsNilForNoFormats() {
        XCTAssertNil(YouTubeAudioExtractor.selectBestAudio([]))
    }

    func testFileExtensionMapping() {
        XCTAssertEqual(YouTubeAudioExtractor.fileExtension(forMimeType: #"audio/mp4; codecs="mp4a.40.2""#), "m4a")
        XCTAssertEqual(YouTubeAudioExtractor.fileExtension(forMimeType: #"audio/webm; codecs="opus""#), "webm")
        XCTAssertEqual(YouTubeAudioExtractor.fileExtension(forMimeType: "audio/ogg"), "ogg")
        XCTAssertEqual(YouTubeAudioExtractor.fileExtension(forMimeType: "application/octet-stream"), "m4a")
    }

    func testVideoIdNormalisation() {
        XCTAssertEqual(YouTubeAudioExtractor.normalizedVideoId("dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeAudioExtractor.normalizedVideoId("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10"), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeAudioExtractor.normalizedVideoId("https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeAudioExtractor.normalizedVideoId("https://www.youtube.com/shorts/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(YouTubeAudioExtractor.normalizedVideoId("https://www.youtube.com/embed/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertNil(YouTubeAudioExtractor.normalizedVideoId(""))
        XCTAssertNil(YouTubeAudioExtractor.normalizedVideoId("https://vimeo.com/12345"))
    }

    func testInnertubeRequestBodyIsValidJSON() {
        let client = YouTubeAudioExtractor.clients[0]
        let data = client.playerRequestBody(videoId: "dQw4w9WgXcQ")
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(root?["videoId"] as? String, "dQw4w9WgXcQ")
        let context = (root?["context"] as? [String: Any])?["client"] as? [String: Any]
        XCTAssertEqual(context?["clientName"] as? String, "ANDROID_VR")
    }

    // MARK: - Download chunking

    func testChunkCountsScaleWithSize() {
        // Thresholds mirror Android's, so the two apps make the same transfer
        // decision on the same file.
        XCTAssertEqual(AudioDownloadChunking.chunkRanges(total: 500 * 1024).count, 1)
        XCTAssertEqual(AudioDownloadChunking.chunkRanges(total: 2 * 1024 * 1024).count, 2)
        XCTAssertEqual(AudioDownloadChunking.chunkRanges(total: 5 * 1024 * 1024).count, 3)
        XCTAssertEqual(AudioDownloadChunking.chunkRanges(total: 20 * 1024 * 1024).count, 4)
        XCTAssertTrue(AudioDownloadChunking.chunkRanges(total: 0).isEmpty)
    }

    func testChunkRangesCoverEveryByteExactlyOnce() {
        for total in [Int64(1_048_576), 3_145_728, 10_485_760, 47_185_920] {
            let ranges = AudioDownloadChunking.chunkRanges(total: total)
            XCTAssertEqual(ranges.first?.lowerBound, 0, "total \(total)")
            XCTAssertEqual(ranges.last?.upperBound, total - 1, "total \(total)")
            // Contiguous and non-overlapping: a gap writes holes, an overlap
            // writes the same bytes twice.
            for (previous, next) in zip(ranges, ranges.dropFirst()) {
                XCTAssertEqual(next.lowerBound, previous.upperBound + 1, "total \(total)")
            }
        }
    }

    func testParseContentRangeTotal() {
        XCTAssertEqual(AudioDownloadChunking.parseContentRangeTotal("bytes 0-0/3449447"), 3_449_447)
        XCTAssertEqual(AudioDownloadChunking.parseContentRangeTotal("bytes 0-999/1000"), 1_000)
        XCTAssertNil(AudioDownloadChunking.parseContentRangeTotal(nil))
        XCTAssertNil(AudioDownloadChunking.parseContentRangeTotal("bytes 0-0/*"))
    }

    func testETANeedsRealElapsedTimeBeforeItWillGuess() {
        let started = Date(timeIntervalSince1970: 1_000)
        // Nothing yet, or under a second elapsed: no estimate rather than noise.
        XCTAssertNil(AudioDownloadChunking.estimateETASeconds(total: 1000, written: 0, startedAt: started, now: started))
        XCTAssertNil(AudioDownloadChunking.estimateETASeconds(total: 1000, written: 100, startedAt: started, now: started.addingTimeInterval(0.2)))
        // 500 bytes in 1s of a 1000-byte file → 1s left.
        XCTAssertEqual(AudioDownloadChunking.estimateETASeconds(total: 1000, written: 500, startedAt: started, now: started.addingTimeInterval(1)), 1)
    }

    // MARK: - Sleep timer

    func testCountdownRoundsUpSoFiveMinutesReadsAsFiveMinutes() {
        // 299.999s must show 5:00, not 4:59 — a control that looks like it
        // ignored the choice.
        XCTAssertEqual(SleepTimer.formatRemaining(300), "5:00")
        XCTAssertEqual(SleepTimer.formatRemaining(299.999), "5:00")
        XCTAssertEqual(SleepTimer.formatRemaining(1), "0:01")
        XCTAssertEqual(SleepTimer.formatRemaining(0), "0:00")
        XCTAssertEqual(SleepTimer.formatRemaining(3600), "1:00:00")
        XCTAssertEqual(SleepTimer.formatRemaining(3750), "1:02:30")
        XCTAssertEqual(SleepTimer.formatRemaining(-5), "0:00")
    }

    func testFadeIsSilentAtTheDeadlineAndFullBeforeIt() {
        XCTAssertEqual(SleepTimer.fadeVolume(remaining: 60), 1)
        XCTAssertEqual(SleepTimer.fadeVolume(remaining: SleepTimer.fadeSeconds), 1)
        XCTAssertEqual(SleepTimer.fadeVolume(remaining: 1.5), 0.5, accuracy: 0.001)
        XCTAssertEqual(SleepTimer.fadeVolume(remaining: 0), 0)
        // A ticker that overshoots the deadline must read as silence, never as
        // a negative volume.
        XCTAssertEqual(SleepTimer.fadeVolume(remaining: -3), 0)
    }

    func testSleepTimerLabel() {
        XCTAssertEqual(SleepTimer.label(forRemaining: 0), "Off")
        XCTAssertEqual(SleepTimer.label(forRemaining: 90), "1:30")
    }

    // MARK: - Manifest

    func testDownloadManifestRoundTripsThroughDisk() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cv-audio-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AudioDownloadStore(root: root)
        try store.ensureDirectory()

        let item = AudioDownloadItem(
            videoId: "dQw4w9WgXcQ", title: "A talk", channelName: "Channel",
            source: AudioDownloadItem.sourceRSS, fileName: "dQw4w9WgXcQ.m4a",
            fileSize: 3_449_447, downloadedAt: 1_700_000_000_000, lastPlayed: 0,
            expiresAt: 0, thumbnailPath: "https://img.example/x.jpg",
            durationSeconds: 213, channelId: "UC123"
        )
        try store.save([item])

        let reloaded = store.load()
        XCTAssertEqual(reloaded, [item])
        XCTAssertEqual(store.fileURL(for: item).lastPathComponent, "dQw4w9WgXcQ.m4a")
        XCTAssertEqual(store.partURL(videoId: "dQw4w9WgXcQ").lastPathComponent, "dQw4w9WgXcQ.part")
    }

    func testCorruptManifestReadsAsEmptyRatherThanThrowing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cv-audio-bad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appendingPathComponent("metadata.json"))
        // One unreadable record must not strand the audio files beside it.
        XCTAssertTrue(AudioDownloadStore(root: root).load().isEmpty)
    }

    // MARK: - Instagram

    private func instagramEmbedHTML() -> String {
        let context = """
        {"context":{"username":"testuser","full_name":"Test User",\
        "profile_pic_url":"https://scontent.cdninstagram.com/v/t51/avatar.jpg",\
        "graphql_media":[{"shortcode_media":{"shortcode":"ABC123","is_video":false,\
        "__typename":"GraphImage","display_url":"https://scontent.cdninstagram.com/v/t51/photo.jpg",\
        "taken_at_timestamp":1700000000,"edge_media_to_caption":{"edges":[{"node":{"text":"Hello world"}}]}}},\
        {"shortcode_media":{"shortcode":"REEL99","is_video":true,"__typename":"GraphVideo",\
        "display_url":"https://scontent.cdninstagram.com/v/t51/reel.jpg",\
        "taken_at_timestamp":1700003600,"video_url":"https://scontent.cdninstagram.com/v/t50/reel.mp4",\
        "edge_liked_by":{"count":42}}}]}}
        """
        // The embed page nests its JSON as an escaped string, which is exactly
        // what the parser has to unwrap.
        let escaped = context.replacingOccurrences(of: "\"", with: "\\\"")
        return "<html><body><script>{\"contextJSON\":\"\(escaped)\"}</script></body></html>"
    }

    func testInstagramEmbedParsesProfileAndPosts() throws {
        let result = try XCTUnwrap(InstagramProfileEmbedParser.parse(html: instagramEmbedHTML(), fallbackUsername: "fallback"))
        XCTAssertEqual(result.username, "testuser")
        XCTAssertEqual(result.displayName, "Test User")
        XCTAssertEqual(result.avatarURL, "https://scontent.cdninstagram.com/v/t51/avatar.jpg")
        XCTAssertEqual(result.items.count, 2)

        let image = result.items[0]
        XCTAssertEqual(image.videoId, "ig_ABC123")
        XCTAssertEqual(image.platform, .instagram)
        XCTAssertEqual(image.instagramType, .image)
        XCTAssertEqual(image.title, "Hello world")
        XCTAssertEqual(image.bodyText, "Hello world")
        XCTAssertEqual(image.instagramUrl, "https://www.instagram.com/p/ABC123/")
        XCTAssertFalse(image.isInstagramVideo)
        // Seconds are widened to milliseconds.
        XCTAssertEqual(image.publishedAtEpochMillis, 1_700_000_000_000)

        let reel = result.items[1]
        XCTAssertEqual(reel.instagramType, .reel)
        XCTAssertTrue(reel.isInstagramVideo)
        XCTAssertEqual(reel.viewCount, 42)
        XCTAssertEqual(reel.mediaUrl, "https://scontent.cdninstagram.com/v/t50/reel.mp4")
    }

    func testInstagramEmbedWithoutPayloadReturnsNil() {
        XCTAssertNil(InstagramProfileEmbedParser.parse(html: "<html>nothing here</html>", fallbackUsername: "x"))
    }

    func testInstagramPrefersTheNonExpiringThumbnail() {
        // A signed CDN URL lapses and answers 403 days later, so the stable
        // media endpoint is used instead.
        let expiring = "https://scontent.cdninstagram.com/v/t51/photo.jpg?oh=abc&oe=def"
        XCTAssertTrue(InstagramProfileEmbedParser.isExpiringImageURL(expiring))
        XCTAssertEqual(
            InstagramProfileEmbedParser.thumbnailURL(shortcode: "ABC123", poster: expiring),
            "https://www.instagram.com/p/ABC123/media/?size=l"
        )
        let stable = "https://scontent.cdninstagram.com/v/t51/photo.jpg"
        XCTAssertFalse(InstagramProfileEmbedParser.isExpiringImageURL(stable))
        XCTAssertEqual(InstagramProfileEmbedParser.thumbnailURL(shortcode: "ABC123", poster: stable), stable)
    }

    func testInstagramHandleValidation() {
        XCTAssertTrue(InstagramProfileEmbedParser.isProfileName("some.handle_1"))
        XCTAssertFalse(InstagramProfileEmbedParser.isProfileName("has spaces"))
        XCTAssertFalse(InstagramProfileEmbedParser.isProfileName("https://instagram.com/x"))
    }

    func testInstagramRejectsPlaceholderAvatars() {
        XCTAssertFalse(InstagramProfileEmbedParser.isRealAvatarURL("https://abs.twimg.com/sticky/default_profile_images/x.png"))
        XCTAssertFalse(InstagramProfileEmbedParser.isRealAvatarURL("https://example.com/a.jpg"))
        XCTAssertTrue(InstagramProfileEmbedParser.isRealAvatarURL("https://scontent.cdninstagram.com/v/t51/a.jpg"))
    }

    // MARK: - X

    private func xBody() -> String {
        """
        <div class="timeline-Tweet" data-tweet-id="1234567890123456789">\
        <p class="timeline-Tweet-text" data-tweet-id="1234567890123456789">Hello from X</p>\
        <img src="https://pbs.twimg.com/media/ABC123.jpg" />\
        </div>\
        <div class="timeline-Tweet" data-tweet-id="1234567890123456790">\
        <p class="timeline-Tweet-text" data-tweet-id="1234567890123456790">Second post</p>\
        "duration_millis": 45000,\
        <source src="https://video.twimg.com/ext_tw_video/999/pu/vid/720/abc.mp4" />\
        </div>
        """
    }

    func testXSyndicationParsesPostsWithIdsTextAndMedia() throws {
        let posts = XFeedParser.parseSyndication(body: xBody(), username: "testuser")
        XCTAssertEqual(posts.count, 2)

        let first = posts[0]
        XCTAssertEqual(first.videoId, "x_1234567890123456789")
        XCTAssertEqual(first.platform, .x)
        XCTAssertEqual(first.channelName, "@testuser")
        XCTAssertEqual(first.bodyText, "Hello from X")
        XCTAssertEqual(first.thumbnailUrl, "https://pbs.twimg.com/media/ABC123.jpg")
        XCTAssertEqual(first.sourceUrl, "https://x.com/testuser/status/1234567890123456789")

        let second = posts[1]
        XCTAssertEqual(second.mediaUrl, "https://video.twimg.com/ext_tw_video/999/pu/vid/720/abc.mp4")
        // duration_millis is milliseconds and is reported in seconds.
        XCTAssertEqual(second.durationSeconds, 45)
        // The first post must NOT inherit the second post's video.
        XCTAssertNil(first.mediaUrl)
    }

    func testXPostTextIsScopedToItsOwnSpan() {
        // A text-only post followed by one with a video: borrowing the next
        // post's mp4 would render it as a video card playing someone else's clip.
        let body = """
        "id_str":"1234567890123456789","full_text":"just text",\
        "id_str":"1234567890123456790","full_text":"has a clip",\
        "media_url":"https://video.twimg.com/v/abc.mp4"
        """
        let posts = XFeedParser.parseSyndication(body: body, username: "u")
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].bodyText, "just text")
        XCTAssertNil(posts[0].mediaUrl)
        XCTAssertEqual(posts[1].bodyText, "has a clip")
        XCTAssertEqual(posts[1].mediaUrl, "https://video.twimg.com/v/abc.mp4")
    }

    func testXSnowflakeDecodesThePostingTime() {
        // A snowflake's top 42 bits are a millisecond timestamp offset by X's epoch.
        let time = try? XCTUnwrap(XFeedParser.snowflakeTime("1234567890123456789"))
        XCTAssertNotNil(time)
        XCTAssertGreaterThan(time ?? 0, 1_500_000_000_000)
        XCTAssertNil(XFeedParser.snowflakeTime("not-a-number"))
    }

    func testXUnescapeNormalisesTheEscapedPayload() {
        XCTAssertEqual(XFeedParser.unescape(#"a\/b"#), "a/b")
        XCTAssertEqual(XFeedParser.unescape(#"x\u0026y"#), "x&y")
        XCTAssertEqual(XFeedParser.unescape(#"a\nb"#), "a b")
        XCTAssertEqual(XFeedParser.unescape("a&amp;b"), "a&b")
    }

    func testXPostSurvivesNonASCIICharacters() {
        // Regression guard for the UTF-16 offset bug. `NSRegularExpression`
        // reports offsets in UTF-16 units, but the first implementation sliced
        // windows by `Character` index. Emoji and Arabic are fewer Characters than
        // UTF-16 units, so every window after them drifted — here the SECOND
        // post's media would be read from the wrong place and lost entirely.
        let body = """
        "id_str":"1234567890123456789","full_text":"مرحبا 😀😀😀",\
        "media_url":"https://pbs.twimg.com/media/ONE.jpg"\
        "id_str":"1234567890123456790","full_text":"second",\
        "media_url":"https://pbs.twimg.com/media/TWO.jpg"
        """
        let posts = XFeedParser.parseSyndication(body: body, username: "u")
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].bodyText, "مرحبا 😀😀😀")
        XCTAssertEqual(posts[0].thumbnailUrl, "https://pbs.twimg.com/media/ONE.jpg")
        XCTAssertEqual(posts[1].bodyText, "second")
        XCTAssertEqual(posts[1].thumbnailUrl, "https://pbs.twimg.com/media/TWO.jpg")
    }

    func testXHandleExtraction() {
        XCTAssertEqual(XSource.extractUsername("@jack"), "jack")
        XCTAssertEqual(XSource.extractUsername("jack"), "jack")
        XCTAssertEqual(XSource.extractUsername("https://x.com/jack"), "jack")
        XCTAssertEqual(XSource.extractUsername("https://twitter.com/jack/status/20"), "jack")
        XCTAssertNil(XSource.extractUsername("https://x.com/home"))
        XCTAssertNil(XSource.extractUsername("@with spaces"))
    }

    func testXAvatarResponseParsing() {
        let payload = Data(#"{"user":{"avatar_url":"https://pbs.twimg.com/profile_images/1/x.jpg"}}"#.utf8)
        XCTAssertEqual(
            XSource.avatarURL(fromProfileResponse: payload, username: "jack"),
            "https://pbs.twimg.com/profile_images/1/x.jpg"
        )
        let placeholder = Data(#"{"user":{"avatar_url":"https://abs.twimg.com/sticky/default_profile_images/x.png"}}"#.utf8)
        XCTAssertNil(XSource.avatarURL(fromProfileResponse: placeholder, username: "jack"))
    }

    // MARK: - Model wiring

    func testNonYouTubeItemsKeepTheirPermalinkInsteadOfAMintedWatchURL() {
        // LibraryVideo's old initialiser hardcoded a YouTube watch URL for every
        // item, which would have pointed an Instagram post at a nonexistent video.
        let instagram = MediaVideo(
            videoId: "ig_ABC", title: "A post", channelId: "ig_testuser", channelName: "Test User",
            publishedAtEpochMillis: 1, thumbnailUrl: "", platform: .instagram, instagramType: .image,
            instagramUrl: "https://www.instagram.com/p/ABC/", sourceUrl: "https://www.instagram.com/p/ABC/",
            bodyText: "caption"
        )
        let library = LibraryVideo(instagram)
        XCTAssertEqual(library.platform, "INSTAGRAM")
        XCTAssertEqual(library.url, "https://www.instagram.com/p/ABC/")
        XCTAssertFalse(library.isYouTube)
        XCTAssertFalse(library.url.contains("youtube.com"))

        // And the platform survives the round trip back to a MediaVideo.
        XCTAssertEqual(library.mediaVideo.platform, .instagram)
        XCTAssertEqual(library.mediaVideo.instagramType, .image)
        XCTAssertEqual(library.mediaVideo.bodyText, "caption")

        let youtube = LibraryVideo(MediaVideo(
            videoId: "dQw4w9WgXcQ", title: "A video", channelId: "UC1", channelName: "Channel",
            publishedAtEpochMillis: 1, thumbnailUrl: "https://i.ytimg.com/x.jpg", platform: .youTube
        ))
        XCTAssertEqual(youtube.url, "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertTrue(youtube.isYouTube)
    }

    func testOlderLibraryJSONWithoutPlatformStillDecodes() throws {
        // A library persisted before the Instagram and X feeds existed has no
        // `platform` key at all; it must still load rather than wipe the feed.
        let legacy = Data(#"[{"id":"dQw4w9WgXcQ","title":"Old","channel":"C","url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ","isShort":false,"publishedAt":0,"live":false}]"#.utf8)
        let videos = try JSONDecoder().decode([LibraryVideo].self, from: legacy)
        XCTAssertEqual(videos.count, 1)
        XCTAssertNil(videos[0].platform)
        XCTAssertTrue(videos[0].isYouTube)
    }

    // MARK: - X: the Next.js payload

    /// A body in the shape the LIVE endpoint actually served, measured by
    /// dumping `__NEXT_DATA__` from the device against `syndication.twitter.com`:
    /// posts at `props.pageProps.timeline.entries[].content.tweet`, media under
    /// `entities.media[]` (NOT `extended_entities`), and an HLS playlist listed
    /// before the MP4 variants.
    private func xNextDataBody() -> String {
        // Built with JSONSerialization rather than written by hand.
        //
        // This matters: a hand-written payload with the wrong brace count is
        // silently invalid, the JSON path declines it, and the parser falls back
        // to the markup scanner — so the test then asserts against the FALLBACK's
        // output while claiming to cover the JSON path. That is exactly how a
        // fixture can look green while the JSON reader is never exercised.
        func tweet(_ id: String, _ text: String, media: [[String: Any]]? = nil) -> [String: Any] {
            [
                "id_str": id,
                "full_text": text,
                "created_at": "Wed Oct 10 20:19:24 +0000 2018",
                "permalink": "https://x.com/jack/status/\(id)",
                // `entities` — NOT `extended_entities`. That is what the live
                // payload was measured to carry (`extended_entities=false`).
                "entities": media.map { ["media": $0] } ?? [String: Any](),
                "user": ["screen_name": "jack"]
            ]
        }
        let video: [String: Any] = [
            "type": "video",
            "media_url_https": "https://pbs.twimg.com/ext_tw_video_thumb/1/pu/img/x.jpg",
            "video_info": [
                "duration_millis": 45_000,
                "variants": [
                    ["content_type": "application/x-mpegURL", "url": "https://video.twimg.com/x/playlist.m3u8"],
                    ["bitrate": 256_000, "content_type": "video/mp4", "url": "https://video.twimg.com/x/low.mp4"],
                    ["bitrate": 832_000, "content_type": "video/mp4", "url": "https://video.twimg.com/x/high.mp4"]
                ]
            ]
        ]
        let photo: [String: Any] = [
            "type": "photo",
            "media_url_https": "https://pbs.twimg.com/media/PIC.jpg"
        ]
        let entries: [[String: Any]] = [
            ["entry_id": "tweet-1", "sort_index": "1", "type": "tweet",
             "content": ["tweet": tweet("1234567890123456789", "text only")]],
            ["entry_id": "tweet-2", "sort_index": "2", "type": "tweet",
             "content": ["tweet": tweet("1234567890123456790", "with photo", media: [photo])]],
            ["entry_id": "tweet-3", "sort_index": "3", "type": "tweet",
             "content": ["tweet": tweet("1234567890123456791", "with video", media: [video])]],
            ["entry_id": "cursor", "sort_index": "4", "type": "cursor", "content": [String: Any]()]
        ]
        let root: [String: Any] = ["props": ["pageProps": ["timeline": ["entries": entries]]]]
        let data = (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
        let json = String(decoding: data, as: UTF8.self)
        return "<html><body><script id=\"__NEXT_DATA__\" type=\"application/json\">\(json)</script></body></html>"
    }

    func testTheXFixtureIsValidJSONAndExercisesTheJSONPath() throws {
        // Guards the trap that hid a broken fixture: if the payload stops being
        // valid JSON the JSON reader declines it, and every JSON test below would
        // silently start asserting against the markup-scanner FALLBACK instead —
        // green, and covering nothing it claims to.
        let body = xNextDataBody()
        let marker = try XCTUnwrap(body.range(of: "__NEXT_DATA__"))
        let open = try XCTUnwrap(body.range(of: ">", range: marker.upperBound..<body.endIndex))
        let close = try XCTUnwrap(body.range(of: "</script>", range: open.upperBound..<body.endIndex))
        let json = String(body[open.upperBound..<close.lowerBound])
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(json.utf8)))
        XCTAssertFalse(
            XFeedParser.parseNextData(body: body, username: "jack").isEmpty,
            "the JSON path produced nothing, so this fixture no longer covers it"
        )
    }

    func testXParsesTheNextDataJSONPayload() throws {
        let posts = XFeedParser.parse(body: xNextDataBody(), username: "jack")
        // The non-tweet entry (a pagination cursor) must not become a post.
        XCTAssertEqual(posts.count, 3)
        XCTAssertEqual(posts.map(\.videoId), [
            "x_1234567890123456789", "x_1234567890123456790", "x_1234567890123456791"
        ])
        XCTAssertEqual(Set(posts.map(\.videoId)).count, posts.count, "duplicate posts")
        XCTAssertTrue(posts.allSatisfy { $0.platform == .x })

        // `created_at` is parsed, not approximated from the snowflake.
        XCTAssertEqual(posts[0].publishedAtEpochMillis, 1_539_202_764_000)

        // Text-only: no media, and it must not borrow the next post's picture.
        XCTAssertEqual(posts[0].bodyText, "text only")
        XCTAssertTrue(posts[0].thumbnailUrl.isEmpty)
        XCTAssertNil(posts[0].mediaUrl)

        // A photo is the thumbnail, and is not treated as playable video.
        XCTAssertEqual(posts[1].thumbnailUrl, "https://pbs.twimg.com/media/PIC.jpg")
        XCTAssertNil(posts[1].mediaUrl)

        // A video: poster thumbnail, progressive MP4 (highest bitrate), and the
        // real duration — never the HLS playlist, which AVPlayer cannot use.
        XCTAssertEqual(posts[2].thumbnailUrl, "https://pbs.twimg.com/ext_tw_video_thumb/1/pu/img/x.jpg")
        XCTAssertEqual(posts[2].mediaUrl, "https://video.twimg.com/x/high.mp4")
        XCTAssertEqual(posts[2].durationSeconds, 45)
    }

    func testXPrefersTheHighestBitrateMP4AndFallsBackToThePlaylist() {
        let info: [String: Any] = ["variants": [
            ["content_type": "application/x-mpegURL", "url": "https://video.twimg.com/p.m3u8"],
            ["bitrate": 100, "content_type": "video/mp4", "url": "https://video.twimg.com/lo.mp4"],
            ["bitrate": 900, "content_type": "video/mp4", "url": "https://video.twimg.com/hi.mp4"]
        ]]
        XCTAssertEqual(XFeedParser.progressiveVideoURL(info), "https://video.twimg.com/hi.mp4")

        let playlistOnly: [String: Any] = ["variants": [
            ["content_type": "application/x-mpegURL", "url": "https://video.twimg.com/p.m3u8"]
        ]]
        XCTAssertEqual(XFeedParser.progressiveVideoURL(playlistOnly), "https://video.twimg.com/p.m3u8")
        XCTAssertNil(XFeedParser.progressiveVideoURL(nil))
        XCTAssertNil(XFeedParser.progressiveVideoURL(["variants": []]))
    }

    func testXCreatedAtUsesAPOSIXLocale() {
        // Parsed in English regardless of device region, so a non-US locale does
        // not silently fall back to the snowflake estimate.
        XCTAssertEqual(XFeedParser.parseCreatedAt("Wed Oct 10 20:19:24 +0000 2018"), 1_539_202_764_000)
        XCTAssertNil(XFeedParser.parseCreatedAt("not a date"))
    }

    func testXStillFallsBackToTheMarkupScanner() {
        // The legacy server-rendered page has no __NEXT_DATA__; the scanner stays
        // as the fallback for it.
        let posts = XFeedParser.parse(body: xBody(), username: "testuser")
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].thumbnailUrl, "https://pbs.twimg.com/media/ABC123.jpg")
    }
}

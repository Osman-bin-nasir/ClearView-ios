import AVFoundation
import XCTest
@testable import ClearView

/// Live checks against YouTube, opt-in only.
///
/// These hit the real service, so they are skipped unless
/// `CLEARVIEW_LIVE_AUDIO=1` is set on the test runner — the same posture as the
/// existing media playback smoke test, and for the same reason: a suite that
/// fails whenever the network is down teaches people to ignore it.
///
/// They exist because extraction is the one thing that cannot be proved by unit
/// tests. YouTube refuses innertube requests from datacenter addresses with
/// `LOGIN_REQUIRED`, so the extractor is only meaningful from the phone's own
/// residential/mobile IP — which means this has to run ON A DEVICE:
///
///     xcodebuild test -scheme ClearView -destination 'id=<device>' \
///       -only-testing:ClearViewTests/MediaAudioLiveTests \
///       TEST_RUNNER_CLEARVIEW_LIVE_AUDIO=1
final class MediaAudioLiveTests: XCTestCase {

    /// A long-lived, embeddable, universally available video.
    private let videoId = "dQw4w9WgXcQ"

    private func requireLiveAudio() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CLEARVIEW_LIVE_AUDIO"] == "1",
            "Set CLEARVIEW_LIVE_AUDIO=1 (run on a real device) to exercise the live YouTube extractor."
        )
    }

    /// The whole point of the feature: this device can resolve a direct,
    /// playable audio URL, and the URL really serves audio bytes.
    func testResolvesAndFetchesARealAudioStream() async throws {
        try requireLiveAudio()

        let extracted = try await YouTubeAudioExtractor().extractAudio(videoId: videoId)
        XCTAssertTrue(
            extracted.url.host?.contains("googlevideo.com") == true,
            "expected a googlevideo CDN URL, got \(extracted.url)")
        XCTAssertFalse(extracted.mimeType.isEmpty)
        XCTAssertGreaterThan(extracted.bitrate, 0)

        // A URL that is merely returned proves nothing; fetch from it.
        var request = URLRequest(url: extracted.url)
        request.setValue(AudioFileDownloader.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertGreaterThan(data.count, 1_000, "the stream answered but carried no audio")
    }

    /// The download path end to end: resolve, transfer to disk, and leave a file
    /// that is actually an MP4 audio track rather than an error page.
    func testDownloadsAudioToDisk() async throws {
        try requireLiveAudio()

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cv-live-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AudioDownloadStore(root: root)
        try store.ensureDirectory()

        let extracted = try await YouTubeAudioExtractor().extractAudio(videoId: videoId)
        let destination = store.audioDirectory.appendingPathComponent("\(videoId).\(extracted.fileExtension)")

        final class Box: @unchecked Sendable { var fractions: [Double] = [] }
        let box = Box()
        let size = try await AudioFileDownloader().download(
            url: extracted.url,
            partURL: store.partURL(videoId: videoId),
            destination: destination,
            expectedTotal: extracted.contentLength
        ) { update in
            box.fractions.append(update.fraction)
        }

        XCTAssertGreaterThan(size, 100_000, "downloaded audio was implausibly small")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        // The .part file must not survive a successful download.
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.partURL(videoId: videoId).path))
        XCTAssertTrue(box.fractions.contains { $0 > 0 }, "no progress was reported during the transfer")

        // An MP4 declares itself with an `ftyp` box in the first bytes; an error
        // page would not.
        let handle = try FileHandle(forReadingFrom: destination)
        let header = try handle.read(upToCount: 12) ?? Data()
        try handle.close()
        XCTAssertGreaterThan(header.count, 8)
        XCTAssertTrue(
            header.range(of: Data("ftyp".utf8)) != nil,
            "downloaded file is not an MP4 container"
        )
    }

    /// The path the other live tests do NOT cover: handing the resolved URL to
    /// `AVPlayer` and actually hearing it play.
    ///
    /// Extraction can succeed and the URL can serve bytes over a ranged GET while
    /// `AVPlayer` still refuses the same URL — it sends its own headers and needs
    /// a container it can demux — so "the download worked" is not evidence that
    /// Audio mode works. This is the check that mirrors what the button does.
    func testAVPlayerPlaysTheExtractedStream() async throws {
        try requireLiveAudio()

        let extracted = try await YouTubeAudioExtractor().extractAudio(videoId: videoId)
        let item = AVPlayerItem(url: extracted.url)
        let player = AVPlayer(playerItem: item)
        player.volume = 0

        // Poll rather than KVO: the point is to report the failure reason, and a
        // polling loop can assert on item.error directly.
        let deadline = Date().addingTimeInterval(20)
        while item.status == .unknown && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(item.status, .readyToPlay,
                       "AVPlayer could not prepare the stream: \(String(describing: item.error))")
        XCTAssertTrue(item.duration.seconds.isFinite && item.duration.seconds > 0,
                      "AVPlayer reported no duration for the stream")

        player.play()
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let advanced = player.currentTime().seconds
        XCTAssertGreaterThan(advanced, 0.3,
                             "AVPlayer reported playing but the playhead did not move (at \(advanced)s)")
        player.pause()
    }

    // MARK: - Feed sources

    /// Whether Instagram's login-free profile embed actually answers from this
    /// device. The parser is unit-tested against a fixture; this is the only way
    /// to find out whether the *endpoint* still serves that markup.

    func testInstagramProfileFetchesLive() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CLEARVIEW_LIVE_FEEDS"] == "1",
            "Set CLEARVIEW_LIVE_FEEDS=1 to exercise the live Instagram/X endpoints."
        )
        do {
            let feed = try await InstagramSource().fetchProfile("nasa")
            XCTAssertFalse(feed.items.isEmpty, "the embed returned no posts")
            XCTAssertEqual(feed.items.first?.platform, .instagram)
        } catch {
            XCTFail("Instagram profile embed failed: \(error.localizedDescription)")
        }
    }

    /// Asserts on what the endpoint ACTUALLY returns, and reports the shape of
    /// the body when it does not match.
    ///
    /// This is the check that matters most for X: the parser reads a page whose
    /// markup is not contractual, so the failure mode to catch is "the page
    /// changed and we silently produce posts with no media", which a fixture can
    /// never reveal. The assertion messages carry the body's shape so a failure
    /// says what moved.
    func testXProfileFetchesLive() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CLEARVIEW_LIVE_FEEDS"] == "1",
            "Set CLEARVIEW_LIVE_FEEDS=1 to exercise the live Instagram/X endpoints."
        )
        let (username, body) = try await XSource().fetchTimelineBody("jack")
        // The real entry point, so this covers the JSON path the app actually uses.
        let items = XFeedParser.parse(body: body, username: username)
        func count(_ needle: String) -> Int { body.components(separatedBy: needle).count - 1 }
        let shape = """
            [bodyBytes=\(body.utf8.count) nextData=\(body.contains("__NEXT_DATA__")) \
            full_text=\(body.contains("full_text")) id_str=\(body.contains("id_str")) \
            rest_id=\(body.contains("rest_id")) dataTweetId=\(body.contains("data-tweet-id")) \
            pbsMedia=\(count("pbs.twimg.com/media")) extTwVideoThumb=\(count("ext_tw_video_thumb")) \
            videoTwimg=\(count("video.twimg.com")) parsedPosts=\(items.count) \
            firstThumb=\(items.first?.thumbnailUrl ?? "<nil>") \
            firstText=\(items.first.map { String($0.bodyText.prefix(60)) } ?? "<nil>")]
            """
        XCTAssertGreaterThan(items.count, 0, "no posts parsed \(shape)")
        XCTAssertEqual(items.first?.platform, .x, shape)
        // The timeline is ~101 entries; the old id-scan produced 135 phantom posts
        // from the same body, so a plausible count is part of the contract.
        XCTAssertLessThanOrEqual(items.count, 120, "implausible post count \(shape)")
        XCTAssertEqual(items.count, Set(items.map(\.videoId)).count, "duplicate posts \(shape)")
        let withMedia = items.filter { !$0.thumbnailUrl.isEmpty }
        XCTAssertGreaterThan(withMedia.count, 0, "no post carried media \(shape)")
        // A video post must resolve to something playable, not just a poster.
        let withVideo = items.filter { $0.mediaUrl != nil }
        XCTAssertTrue(withVideo.allSatisfy { ($0.mediaUrl ?? "").contains("video.twimg.com") },
                      "a post's media URL is not a playable twimg asset \(shape)")
    }
}

import XCTest
@testable import ClearView

/// Haramayn Live's discovery and validation rules.
///
/// The page fixtures are shaped from REAL captures of the official channels'
/// `/live` and `/watch` pages (the canonical tags, ids, status codes and marker
/// names are the ones YouTube actually served; the surrounding HTML is cut down
/// so the test reads as the rule it checks). What is asserted here is the
/// accept/reject policy — the part a wrong `videoId` would break — with no
/// network and no player.
@MainActor
final class LiveStreamResolverTests: XCTestCase {

    // MARK: - Fixtures

    /// The Makkah channel's `/live` page. Every field is one YouTube really
    /// serves for Saudi Qur'an TV's broadcast.
    private let makkahLivePage = """
    <!doctype html><html><head>
    <link rel="canonical" href="https://www.youtube.com/watch?v=eC4LfEVxvKg">
    </head><body><script>var ytInitialPlayerResponse = {"playabilityStatus":{"status":"OK","reason":""},
    "videoDetails":{"videoId":"eC4LfEVxvKg","channelId":"UCos52azQNBgW63_9uDJoPDA","title":"قناة القرآن الكريم | البث المباشر"},
    "microformat":{"playerMicroformatRenderer":{"ownerChannelId":"UCos52azQNBgW63_9uDJoPDA"}},
    "isLive":true,"isLiveNow":true,"liveStreamability":{"liveStreamabilityRenderer":{"videoId":"eC4LfEVxvKg"}}};
    </script></body></html>
    """

    /// The Madinah channel's `/live` page.
    private let madinahLivePage = """
    <!doctype html><html><head>
    <link rel="canonical" href="https://www.youtube.com/watch?v=Rs7St51oDDc">
    </head><body><script>var ytInitialPlayerResponse = {"playabilityStatus":{"status":"OK","reason":""},
    "videoDetails":{"videoId":"Rs7St51oDDc","channelId":"UCROKYPep-UuODNwyipe6JMw","title":"قناة السنة النبوية | البث المباشر"},
    "microformat":{"playerMicroformatRenderer":{"ownerChannelId":"UCROKYPep-UuODNwyipe6JMw"}},
    "isLive":true,"isLiveNow":true,"liveStreamability":{"liveStreamabilityRenderer":{"videoId":"Rs7St51oDDc"}}};
    </script></body></html>
    """

    /// A `/watch` page for that same Makkah broadcast — what validation reads.
    private let makkahWatchPage = """
    <!doctype html><html><head>
    <link rel="canonical" href="https://www.youtube.com/watch?v=eC4LfEVxvKg">
    </head><body><script>var ytInitialPlayerResponse = {"playabilityStatus":{"status":"OK","reason":""},
    "videoDetails":{"videoId":"eC4LfEVxvKg","channelId":"UCos52azQNBgW63_9uDJoPDA"},
    "microformat":{"playerMicroformatRenderer":{"ownerChannelId":"UCos52azQNBgW63_9uDJoPDA"}},
    "isLive":true,"liveStreamability":{}};</script></body></html>
    """

    /// The same video page, but owned by the OTHER Haram: this is the page a
    /// cross-channel substitution attempt would have to pass, and it must not.
    private let madinahWatchPage = """
    <!doctype html><html><head>
    <link rel="canonical" href="https://www.youtube.com/watch?v=Rs7St51oDDc">
    </head><body><script>var ytInitialPlayerResponse = {"playabilityStatus":{"status":"OK","reason":""},
    "videoDetails":{"videoId":"Rs7St51oDDc","channelId":"UCROKYPep-UuODNwyipe6JMw"},
    "microformat":{"playerMicroformatRenderer":{"ownerChannelId":"UCROKYPep-UuODNwyipe6JMw"}},
    "isLive":true,"liveStreamability":{}};</script></body></html>
    """

    /// An UPCOMING broadcast: the player response carries `isLiveNow:false` and no
    /// `liveStreamability`, which is exactly how YouTube marks "not started yet".
    private let upcomingBroadcastPage = """
    <!doctype html><html><head>
    <link rel="canonical" href="https://www.youtube.com/watch?v=aaaaaaaaaaa">
    </head><body><script>var ytInitialPlayerResponse = {"playabilityStatus":{"status":"OK","reason":""},
    "videoDetails":{"videoId":"aaaaaaaaaaa","channelId":"UCos52azQNBgW63_9uDJoPDA"},
    "isLive":false,"isLiveNow":false,"liveBroadcastDetails":{"isLiveNow":false,"startTimestamp":"2026-10-20T00:00:00+00:00"}};
    </script></body></html>
    """

    /// The Restricted-Mode / DNS-filter signature: a player response that is not
    /// playable (the EXACT `ERROR` status the filter serves), no live markers and
    /// no canonical link.
    private let restrictedModePage = """
    <!doctype html><html><head><title>YouTube</title></head><body>
    <script>var ytInitialPlayerResponse = {"playabilityStatus":{"status":"ERROR","reason":"Video unavailable"}};</script>
    </body></html>
    """

    /// A channel home page — what `/live` becomes when nothing is airing. Its
    /// first `videoId` is a featured VOD, and the canonical names the CHANNEL, so
    /// neither tier may accept it.
    private let channelHomePage = """
    <!doctype html><html><head>
    <link rel="canonical" href="https://www.youtube.com/channel/UCos52azQNBgW63_9uDJoPDA">
    </head><body><script>{"videoId":"dQw4w9WgXcQ","title":"Featured upload"}</script></body></html>
    """

    /// The page for a broadcast that has ENDED, on the channel that aired it: a
    /// normal VOD, carrying none of the live markers. This is what the last-known
    /// fallback has to be checked against — a finished stream must not be played.
    private let endedBroadcastPage = """
    <!doctype html><html><head>
    <link rel="canonical" href="https://www.youtube.com/watch?v=Rs7St51oDDc">
    </head><body><script>var ytInitialPlayerResponse = {"playabilityStatus":{"status":"OK","reason":""},
    "videoDetails":{"videoId":"Rs7St51oDDc","channelId":"UCROKYPep-UuODNwyipe6JMw"},
    "microformat":{"playerMicroformatRenderer":{"ownerChannelId":"UCROKYPep-UuODNwyipe6JMw"}},
    "isLiveContent":true,"isLive":false};</script></body></html>
    """

    /// A plain upload that a `/streams` listing can offer as a candidate: the same
    /// channel, a normal video, no live markers.
    private func vodCandidatePage(channelId: String) -> String {
        """
        <!doctype html><html><head>
        <link rel="canonical" href="https://www.youtube.com/watch?v=dQw4w9WgXcQ">
        </head><body><script>var ytInitialPlayerResponse = {"playabilityStatus":{"status":"OK","reason":""},
        "videoDetails":{"videoId":"dQw4w9WgXcQ","channelId":"\(channelId)"},
        "microformat":{"playerMicroformatRenderer":{"ownerChannelId":"\(channelId)"}},
        "isLiveContent":false,"isLive":false};</script></body></html>
        """
    }

    // MARK: - Discovery

    func testFindsEachOfficialChannelCurrentBroadcastOnItsLivePage() {
        XCTAssertEqual(LiveStreamPage.extractLiveVideoId(makkahLivePage), "eC4LfEVxvKg")
        XCTAssertEqual(LiveStreamPage.extractLiveVideoId(madinahLivePage), "Rs7St51oDDc")
        XCTAssertEqual(LiveStreamPage.canonicalVideoId(makkahLivePage), "eC4LfEVxvKg")
        XCTAssertEqual(LiveStreamPage.canonicalVideoId(madinahLivePage), "Rs7St51oDDc")
    }

    func testReadsTheBroadcastFromTheCanonicalLinkWhenThePlayerResponseIsStripped() {
        // Reduced variants drop the player response but keep the SEO tag on a
        // /live URL — tier 2, and the tier that makes those variants playable.
        let stripped = "<html><head><link rel=\"canonical\" href=\"https://www.youtube.com/watch?v=eC4LfEVxvKg\"></head><body></body></html>"
        XCTAssertNil(LiveStreamPage.extractLiveVideoId(stripped))
        XCTAssertEqual(LiveStreamPage.canonicalVideoId(stripped), "eC4LfEVxvKg")
    }

    func testNeverTreatsAChannelHomePageAsABroadcast() {
        XCTAssertNil(LiveStreamPage.extractLiveVideoId(channelHomePage))
        XCTAssertNil(LiveStreamPage.canonicalVideoId(channelHomePage))
        // Tier 3 must stay gated on a player response, or this featured VOD would
        // be handed to the /watch validator as a candidate.
        XCTAssertFalse(channelHomePage.contains("ytInitialPlayerResponse"))
        XCTAssertEqual(LiveStreamPage.firstVideoIdInDocument(channelHomePage), "dQw4w9WgXcQ")
    }

    func testIgnoresAnUpcomingBroadcast() {
        XCTAssertNil(LiveStreamPage.extractLiveVideoId(upcomingBroadcastPage))
        XCTAssertFalse(LiveStreamPage.validateWatchPage(upcomingBroadcastPage, videoId: "aaaaaaaaaaa",
                                                        expectedChannelId: LiveStreamConfig.makkah.channelId))
    }

    // MARK: - Validation

    func testValidatesTheOfficialBroadcastItWasAskedFor() {
        XCTAssertTrue(LiveStreamPage.validateWatchPage(makkahWatchPage, videoId: "eC4LfEVxvKg",
                                                       expectedChannelId: LiveStreamConfig.makkah.channelId))
        XCTAssertTrue(LiveStreamPage.validateWatchPage(madinahWatchPage, videoId: "Rs7St51oDDc",
                                                       expectedChannelId: LiveStreamConfig.madinah.channelId))
    }

    func testRefusesAnotherChannelsBroadcast() {
        // Madinah's broadcast can never stand in for Makkah's, and vice versa.
        XCTAssertFalse(LiveStreamPage.validateWatchPage(madinahWatchPage, videoId: "Rs7St51oDDc",
                                                        expectedChannelId: LiveStreamConfig.makkah.channelId))
        XCTAssertFalse(LiveStreamPage.validateWatchPage(makkahWatchPage, videoId: "eC4LfEVxvKg",
                                                        expectedChannelId: LiveStreamConfig.madinah.channelId))
    }

    func testRefusesACandidateThatIsNotThePageItRead() {
        XCTAssertFalse(LiveStreamPage.validateWatchPage(makkahWatchPage, videoId: "dQw4w9WgXcQ",
                                                        expectedChannelId: LiveStreamConfig.makkah.channelId))
    }

    func testRefusesANonPlayableBroadcast() {
        let blocked = makkahWatchPage.replacingOccurrences(
            of: "\"playabilityStatus\":{\"status\":\"OK\"", with: "\"playabilityStatus\":{\"status\":\"LOGIN_REQUIRED\"")
        XCTAssertFalse(LiveStreamPage.validateWatchPage(blocked, videoId: "eC4LfEVxvKg",
                                                        expectedChannelId: LiveStreamConfig.makkah.channelId))
    }

    // MARK: - Restricted Mode

    func testDetectsTheDnsFilterSignature() {
        XCTAssertTrue(LiveStreamPage.looksRestrictedMode(restrictedModePage))
    }

    func testDoesNotBlameTheDnsFilterForAPageThatIsMerelyOffAir() {
        XCTAssertFalse(LiveStreamPage.looksRestrictedMode(channelHomePage))
        XCTAssertFalse(LiveStreamPage.looksRestrictedMode(makkahLivePage))
        // A playable-but-not-live page is not a filter block either.
        XCTAssertFalse(LiveStreamPage.looksRestrictedMode(endedBroadcastPage))
    }

    // MARK: - The configured sources

    func testPinsTheOfficialChannelIdsTheAndroidAppUses() {
        XCTAssertEqual(LiveStreamConfig.streams.map(\.channelId),
                       ["UCos52azQNBgW63_9uDJoPDA", "UCROKYPep-UuODNwyipe6JMw"])
        XCTAssertEqual(LiveStreamConfig.streams.map(\.id), ["makkah", "madinah"])
    }

    func testGivesMakkahItsDocumentedBackupChannelAndMadinahNone() {
        XCTAssertEqual(LiveStreamConfig.backupStreams["makkah"]?.channelId, "UCfBw_uwZb_oFLyVsjWk6owQ")
        XCTAssertEqual(LiveStreamConfig.backupStreams["makkah"]?.name, "AlQuran4k القرآن الكريم")
        XCTAssertNil(LiveStreamConfig.backupStreams["madinah"])
        XCTAssertEqual(LiveStreamConfig.stream(id: "makkah_backup")?.channelId, "UCfBw_uwZb_oFLyVsjWk6owQ")
    }

    // MARK: - Last-known id store

    func testRemembersTheLastBroadcastPerChannel() {
        let store = makeStore()
        store.rememberResolved(channelId: LiveStreamConfig.makkah.channelId, videoId: "eC4LfEVxvKg")
        XCTAssertEqual(store.lastVideoId(channelId: LiveStreamConfig.makkah.channelId), "eC4LfEVxvKg")
        // Madinah's own slot is untouched: the two can never share an id.
        XCTAssertNil(store.lastVideoId(channelId: LiveStreamConfig.madinah.channelId))

        store.rememberResolved(channelId: LiveStreamConfig.makkah.channelId, videoId: "uFBt3KHGApI")
        XCTAssertEqual(store.lastVideoId(channelId: LiveStreamConfig.makkah.channelId), "uFBt3KHGApI")
        XCTAssertNotNil(store.lastResolvedAt(channelId: LiveStreamConfig.makkah.channelId))
    }

    func testIgnoresAStoredValueThatIsNotAVideoId() {
        let suite = "LiveStoreJunk.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("not-an-id", forKey: "last_video_UCos52azQNBgW63_9uDJoPDA")
        XCTAssertNil(LiveStreamCacheStore(defaults: defaults).lastVideoId(channelId: LiveStreamConfig.makkah.channelId))
    }

    // MARK: - The discovery pipeline, against stubbed pages

    func testResolvesThroughTheCanonicalTierAndRemembersIt() async {
        let stub = StubPages(pages: [
            "https://www.youtube.com/channel/UCos52azQNBgW63_9uDJoPDA/live":
                "<html><head><link rel=\"canonical\" href=\"https://www.youtube.com/watch?v=eC4LfEVxvKg\"></head><body></body></html>",
            "https://www.youtube.com/watch?v=eC4LfEVxvKg": makkahWatchPage,
        ])
        let store = makeStore()
        let resolver = LiveStreamResolver(store: store, session: stub.session)

        let result = await resolver.resolve(LiveStreamConfig.makkah)

        XCTAssertEqual(result.videoId, "eC4LfEVxvKg")
        XCTAssertFalse(result.blockedByFilter)
        XCTAssertEqual(store.lastVideoId(channelId: LiveStreamConfig.makkah.channelId), "eC4LfEVxvKg")
        XCTAssertEqual(stub.requested, [
            "https://www.youtube.com/channel/UCos52azQNBgW63_9uDJoPDA/live",
            "https://www.youtube.com/watch?v=eC4LfEVxvKg",
        ])
    }

    func testDoesNotSpendAWatchPageRequestOnAnOffAirChannel() async {
        let stub = StubPages(pages: [
            "https://www.youtube.com/channel/UCos52azQNBgW63_9uDJoPDA/live": channelHomePage,
            // /streams lists the channel's own uploads; its first id is a VOD, so
            // validation rejects it and the attempt ends honestly.
            "https://www.youtube.com/channel/UCos52azQNBgW63_9uDJoPDA/streams": channelHomePage,
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ": vodCandidatePage(channelId: LiveStreamConfig.makkah.channelId),
        ])
        let resolver = LiveStreamResolver(store: makeStore(), session: stub.session)

        let result = await resolver.resolve(LiveStreamConfig.makkah)

        XCTAssertNil(result.videoId)
        XCTAssertFalse(result.blockedByFilter)
        XCTAssertEqual(stub.requested.count, 3)
    }

    func testReportsTheDnsFilterInsteadOfBurningRequests() async {
        let stub = StubPages(pages: [
            "https://www.youtube.com/channel/UCos52azQNBgW63_9uDJoPDA/live": restrictedModePage,
        ])
        let resolver = LiveStreamResolver(store: makeStore(), session: stub.session)

        let result = await resolver.resolve(LiveStreamConfig.makkah)

        XCTAssertNil(result.videoId)
        XCTAssertTrue(result.blockedByFilter)
        // Filtered: /watch and /streams are equally stripped, so asking is waste.
        XCTAssertEqual(stub.requested, ["https://www.youtube.com/channel/UCos52azQNBgW63_9uDJoPDA/live"])
    }

    func testFallsBackToTheLastKnownBroadcastOnlyAfterReValidatingIt() async {
        let store = makeStore()
        store.rememberResolved(channelId: LiveStreamConfig.madinah.channelId, videoId: "Rs7St51oDDc")
        let stub = StubPages(pages: [
            "https://www.youtube.com/channel/UCROKYPep-UuODNwyipe6JMw/live": channelHomePage
                .replacingOccurrences(of: "UCos52azQNBgW63_9uDJoPDA", with: "UCROKYPep-UuODNwyipe6JMw"),
            "https://www.youtube.com/channel/UCROKYPep-UuODNwyipe6JMw/streams": channelHomePage,
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ": vodCandidatePage(channelId: LiveStreamConfig.madinah.channelId),
            "https://www.youtube.com/watch?v=Rs7St51oDDc": madinahWatchPage,
        ])
        let resolver = LiveStreamResolver(store: store, session: stub.session)

        let result = await resolver.resolve(LiveStreamConfig.madinah)

        XCTAssertEqual(result.videoId, "Rs7St51oDDc")
        XCTAssertTrue(stub.requested.contains("https://www.youtube.com/watch?v=Rs7St51oDDc"))
    }

    func testDiscardsALastKnownBroadcastThatHasEnded() async {
        let store = makeStore()
        store.rememberResolved(channelId: LiveStreamConfig.madinah.channelId, videoId: "Rs7St51oDDc")
        let stub = StubPages(pages: [
            "https://www.youtube.com/channel/UCROKYPep-UuODNwyipe6JMw/live": channelHomePage,
            "https://www.youtube.com/channel/UCROKYPep-UuODNwyipe6JMw/streams": channelHomePage,
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ": vodCandidatePage(channelId: LiveStreamConfig.madinah.channelId),
            "https://www.youtube.com/watch?v=Rs7St51oDDc": endedBroadcastPage,
        ])
        let resolver = LiveStreamResolver(store: store, session: stub.session)

        let result = await resolver.resolve(LiveStreamConfig.madinah)

        XCTAssertNil(result.videoId)
        XCTAssertFalse(result.blockedByFilter)
    }

    func testReusesASuccessfulResolutionUntilItIsForced() async {
        let stub = StubPages(pages: [
            "https://www.youtube.com/channel/UCos52azQNBgW63_9uDJoPDA/live": makkahLivePage,
            "https://www.youtube.com/watch?v=eC4LfEVxvKg": makkahWatchPage,
        ])
        let resolver = LiveStreamResolver(store: makeStore(), session: stub.session)

        _ = await resolver.resolve(LiveStreamConfig.makkah)
        let afterFirst = stub.requested.count
        _ = await resolver.resolve(LiveStreamConfig.makkah)
        XCTAssertEqual(stub.requested.count, afterFirst, "a re-open inside the freshness window must not refetch")

        // A retry DOES refetch: the broadcast may have just changed.
        _ = await resolver.resolve(LiveStreamConfig.makkah, force: true)
        XCTAssertEqual(stub.requested.count, afterFirst + 2)
    }

    // MARK: - Helpers

    private func makeStore() -> LiveStreamCacheStore {
        let suite = "LiveStreamResolverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return LiveStreamCacheStore(defaults: defaults)
    }
}

/// Serves the fixtures for the resolver's three URLs and records what was asked
/// for, so both the accepted path and the requests SKIPPED on a failure can be
/// asserted. Only the URLs it is given a page for are reachable, so a resolver
/// that asks for something unexpected fails loudly instead of silently.
private final class StubPages {
    static var pages: [String: String] = [:]
    static var requested: [String] = []

    let session: URLSession

    init(pages: [String: String]) {
        Self.pages = pages
        Self.requested = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        session = URLSession(configuration: configuration)
    }

    var requested: [String] { Self.requested }

    private final class StubProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let url = request.url?.absoluteString ?? ""
            StubPages.requested.append(url)
            guard let html = StubPages.pages[url] else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(html.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}

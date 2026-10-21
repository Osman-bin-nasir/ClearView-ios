import XCTest
@testable import ClearView

/// Good Post's text, stored on the device.
///
/// The requirement is Android's, unchanged: the words a channel published stay readable on this
/// device once they have been fetched — on a plane, with no account, and with the server
/// unreachable. What is asserted here is the whole path a reader's text takes: the fetch writes
/// it, the file holds it, the signed media URLs are deliberately not in it, and a cold start
/// with no network still draws it.
@MainActor
final class GoodPostOfflineTextTests: XCTestCase {

    /// A channel's posts as the server sends them: two text updates, and one whose picture
    /// arrived as a short-lived signed URL — the kind that must never reach the disk.
    private let postsPage = """
    {"items":[
      {"id":"p1","channelId":"chan-1","type":"text","body":"first message",
       "createdAt":"2026-10-16T10:00:00.000Z","views":4},
      {"id":"p2","channelId":"chan-1","type":"image","body":"second message",
       "createdAt":"2026-10-16T09:00:00.000Z","views":0,
       "media":[{"id":"m1","kind":"image","contentType":"image/jpeg","byteSize":1234,
                 "width":800,"height":600,"position":0,
                 "url":"https://bucket.example.test/m1?X-Amz-Signature=abc&X-Amz-Expires=3600"}]}
    ],"nextCursor":null}
    """

    func testAFetchStoresTheChannelsTextOnTheDevice() async {
        let log = RequestLog()
        let store = makeStore()
        let repository = repository(transport: StubTransport(json: postsPage, log: log), store: store)

        let result = await repository.channelPosts(channelId: "chan-1")

        XCTAssertEqual(result.value?.items.map(\.body), ["first message", "second message"])
        // The request really went to this channel's posts endpoint, so the cache write below is
        // the consequence of that fetch rather than of something else happening to run.
        XCTAssertEqual(log.urls, ["https://example.test/api/v1/channels/chan-1/posts"])

        let cached = await repository.cachedPosts(channelId: "chan-1")
        XCTAssertEqual(cached?.posts.map(\.id), ["p1", "p2"])
        XCTAssertEqual(cached?.posts.map(\.body), ["first message", "second message"])
    }

    func testTheStoredCopyKeepsTheTextAndDropsTheSignedMediaUrl() {
        let store = makeStore()
        let cache = GoodPostCache(defaults: store)

        // The server's own rows, through the same codec the fetch uses.
        let page = (try? JSONSerialization.jsonObject(with: Data(postsPage.utf8))) as? [String: Any] ?? [:]
        let parsed = GoodPostCodec.postPage(from: page).items
        cache.savePosts(channelId: "chan-1", posts: parsed, nowMs: 1_000)

        let stored = cache.loadPosts(channelId: "chan-1")
        XCTAssertEqual(stored?.posts.map(\.body), ["first message", "second message"])
        // A presigned URL is a capability that expires within the hour, so it is not written to
        // disk; the metadata that says "this update had a picture" is what survives.
        XCTAssertEqual(stored?.posts.flatMap { $0.media.compactMap(\.url) }, [])
        XCTAssertEqual(stored?.posts.flatMap { $0.media.map(\.id) }, ["m1"])
        XCTAssertEqual(stored?.posts.flatMap { $0.media.map(\.kind) }, ["image"])
    }

    func testAColdStartWithNoNetworkStillHasTheWords() async {
        let store = makeStore()
        let online = repository(transport: StubTransport(json: postsPage), store: store)
        _ = await online.channelPosts(channelId: "chan-1")

        // A new repository over the same store: the app relaunched without a connection.
        let offline = repository(transport: OfflineTransport(), store: store)
        let fetched = await offline.channelPosts(channelId: "chan-1")
        XCTAssertNil(fetched.value, "the network is gone, so the fetch must fail")

        let cached = await offline.cachedPosts(channelId: "chan-1")
        XCTAssertEqual(cached?.posts.map(\.body), ["first message", "second message"])
        // Text is per channel and never shared: another channel has nothing saved.
        let other = await offline.cachedPosts(channelId: "chan-2")
        XCTAssertNil(other)
    }

    func testTheChannelScreenDrawsTheSavedTextBeforeItReportsTheFailure() async throws {
        let store = makeStore()
        let online = repository(transport: StubTransport(json: postsPage), store: store)
        _ = await online.channelPosts(channelId: "chan-1")

        let offline = repository(transport: OfflineTransport(), store: store)
        let channel = try XCTUnwrap(GoodPostCodec.channel(from: ["id": "chan-1", "name": "Test channel"]))
        let model = ChannelFeedModel(channel: channel, repository: offline)

        await model.load()

        // What the reader sees with no network: the messages themselves, and an honest note that
        // the rest could not be fetched.
        XCTAssertEqual(model.posts.map(\.body), ["first message", "second message"])
        XCTAssertNotNil(model.message)
    }

    func testThePerChannelTextCacheIsBounded() {
        let cache = GoodPostCache(defaults: makeStore())
        let posts = (0..<65).map { index in
            GoodPostPost(
                id: "post-\(index)",
                channelId: "chan-1",
                type: "text",
                body: "message \(index)",
                linkUrl: nil,
                linkTitle: nil,
                media: [],
                createdAt: String(format: "2026-10-16T10:%02d:00.000Z", index),
                editedAt: nil,
                channel: nil,
                views: 0,
                reactions: [],
                myReaction: nil
            )
        }

        cache.savePosts(channelId: "chan-1", posts: posts, nowMs: 1_000)

        XCTAssertEqual(cache.loadPosts(channelId: "chan-1")?.posts.count, GoodPostCache.maxPostsPerChannel)
        XCTAssertEqual(GoodPostCache.maxPostsPerChannel, 60)
    }

    // MARK: - Helpers

    private func makeStore() -> UserDefaults {
        let suite = "GoodPostOfflineText.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// A repository over a given transport and store, with no reader identity: a deployment that
    /// cannot verify anybody is a supported state, and it keeps these tests off the network.
    private func repository(transport: GoodPostTransport, store: UserDefaults) -> GoodPostRepository {
        GoodPostRepository(
            api: GoodPostApi(baseUrl: { "https://example.test" }, transport: transport),
            identity: NoIdentity(),
            cache: GoodPostCache(defaults: store),
            tokens: KeychainAdminSessionStore()
        )
    }

    private final class RequestLog: @unchecked Sendable {
        private(set) var urls: [String] = []
        func record(_ url: String) { urls.append(url) }
    }

    /// Answers every request with one canned body.
    private struct StubTransport: GoodPostTransport {
        let json: String
        var log: RequestLog?

        func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> GoodPostResponse {
            log?.record(url.absoluteString)
            return GoodPostResponse(status: 200, data: Data(json.utf8))
        }

        func put(fileURL: URL, url: URL, headers: [String: String]) async throws -> GoodPostResponse {
            GoodPostResponse(status: 500, data: Data())
        }
    }

    /// This device with no connection at all.
    private struct OfflineTransport: GoodPostTransport {
        func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> GoodPostResponse {
            throw URLError(.notConnectedToInternet)
        }

        func put(fileURL: URL, url: URL, headers: [String: String]) async throws -> GoodPostResponse {
            throw URLError(.notConnectedToInternet)
        }
    }
}

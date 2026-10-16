import XCTest
@testable import ClearView

/// Good Post's video byte cache.
///
/// The requirement is a data-cost one and it has an exact test: open a clip twice and count the
/// requests. What is asserted here is that the stored bytes are keyed by the OBJECT (so a
/// re-signed URL still hits), that the second open is served from the file with no request at
/// all, and that the directory keeps itself inside its budget by dropping the least recently
/// used clip first.
@MainActor
final class GoodPostVideoCacheTests: XCTestCase {

    private let clip = "https://bucket.example.test/clips/makkah-1.mp4"

    /// The same object, re-signed — a new credential and a new expiry, which is what every page
    /// load hands out.
    private let reSignedClip = "https://bucket.example.test/clips/makkah-1.mp4"
        + "?X-Amz-Signature=6f2b1c&X-Amz-Expires=3600&X-Amz-Date=20261016T100000Z"

    // MARK: - The key

    func testAReSignedUrlIsTheSameCacheKey() {
        let store = makeStore()
        let first = URL(string: clip)!
        let second = URL(string: reSignedClip)!
        XCTAssertEqual(store.key(for: first), store.key(for: second))
        // The invariant Android's cache documents: the key holds no scheme and no query, so it
        // can be computed again later and can never be a credential.
        XCTAssertFalse(store.key(for: second).contains("?"))
        XCTAssertFalse(store.key(for: second).contains("://"))
        XCTAssertEqual(store.key(for: second), "bucket.example.test/clips/makkah-1.mp4")
    }

    // MARK: - The second open

    func testTheSecondOpenPlaysTheStoredFileAndMakesNoRequest() async {
        let server = VideoServer(bytes: Self.someVideoBytes)
        let cache = makeCache(session: server.session)

        // First open: nothing stored, so the player is handed the remote URL and the bytes are
        // stored once playback starts.
        XCTAssertEqual(cache.playbackURL(for: clip)?.absoluteString, clip)
        cache.prepare(clip)
        let storedNow = await waitUntilStored(cache)
        XCTAssertTrue(storedNow, "the clip never reached the disk")
        XCTAssertEqual(server.requests, 1)

        // Second open, re-signed URL and all: a file on this device, and no second request.
        let second = try? XCTUnwrap(cache.playbackURL(for: reSignedClip))
        XCTAssertEqual(second?.isFileURL, true, "a stored clip must be played from disk")
        XCTAssertTrue(FileManager.default.fileExists(atPath: second?.path ?? ""))

        cache.prepare(reSignedClip)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(server.requests, 1, "a stored clip must not be fetched again")
        XCTAssertGreaterThan(cache.bytes(for: reSignedClip), 0)
    }

    func testAStoredClipPlaysEvenWhenItsSignatureHasExpired() async {
        let server = VideoServer(bytes: Self.someVideoBytes)
        let cache = makeCache(session: server.session)
        cache.prepare(clip)
        let storedNow = await waitUntilStored(cache)
        XCTAssertTrue(storedNow)

        // An hour-old URL whose expiry has passed: the bytes on this device are still the clip,
        // and the whole point of keying on the object is that the credential's life is not the
        // file's life.
        let expired = clip + "?X-Amz-Signature=dead&X-Amz-Expires=1&X-Amz-Date=20260101T000000Z"
        XCTAssertEqual(cache.playbackURL(for: expired)?.isFileURL, true)
    }

    func testEvictingAClipReportsWhatItFreedAndStreamsItAgain() async {
        let server = VideoServer(bytes: Self.someVideoBytes)
        let cache = makeCache(session: server.session)
        cache.prepare(clip)
        let storedNow = await waitUntilStored(cache)
        XCTAssertTrue(storedNow)
        let stored = cache.bytes(for: clip)
        XCTAssertGreaterThan(stored, 0)

        XCTAssertEqual(cache.evict([clip]), stored)
        XCTAssertEqual(cache.bytes(for: clip), 0)
        XCTAssertEqual(cache.bytesCached(), 0)
        XCTAssertEqual(cache.playbackURL(for: clip)?.absoluteString, clip, "with nothing stored, the remote URL is used again")
    }

    func testClearEmptiesTheDirectory() async {
        let server = VideoServer(bytes: Self.someVideoBytes)
        let cache = makeCache(session: server.session)
        cache.prepare(clip)
        let storedNow = await waitUntilStored(cache)
        XCTAssertTrue(storedNow)

        cache.clear()

        XCTAssertEqual(cache.bytesCached(), 0)
        XCTAssertEqual(cache.playbackURL(for: clip)?.absoluteString, clip)
    }

    func testAServerRefusalIsNotStoredAndDoesNotBreakPlayback() async {
        let server = VideoServer(bytes: Data(), status: 403)
        let cache = makeCache(session: server.session)

        cache.prepare(clip)
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(cache.bytes(for: clip), 0)
        XCTAssertEqual(cache.bytesCached(), 0)
        // The reader still gets the clip: an expired signature means the player streams from a
        // fresh URL, and the next open stores the bytes.
        XCTAssertEqual(cache.playbackURL(for: clip)?.absoluteString, clip)
    }

    // MARK: - Eviction

    func testTheDirectoryDropsTheLeastRecentlyUsedClipFirst() throws {
        let store = GoodPostVideoDiskStore(limitBytes: 2_500, directory: makeDirectory())
        func write(_ name: String, bytes: Int, used: Date) throws {
            let key = "bucket.example.test/clips/\(name)"
            XCTAssertTrue(store.write(key: key, data: Data(repeating: 0x41, count: bytes)))
            try FileManager.default.setAttributes([.modificationDate: used], ofItemAtPath: store.fileURL(key: key).path)
        }
        let now = Date()
        try write("oldest.mp4", bytes: 1_000, used: now.addingTimeInterval(-300))
        try write("middle.mp4", bytes: 1_000, used: now.addingTimeInterval(-200))
        try write("newest.mp4", bytes: 1_000, used: now.addingTimeInterval(-100))
        XCTAssertEqual(store.totalBytes(), 3_000)

        store.trim(to: 2_500)

        XCTAssertEqual(store.bytes(key: "bucket.example.test/clips/oldest.mp4"), 0, "the oldest clip goes first")
        XCTAssertGreaterThan(store.bytes(key: "bucket.example.test/clips/middle.mp4"), 0)
        XCTAssertGreaterThan(store.bytes(key: "bucket.example.test/clips/newest.mp4"), 0)
        XCTAssertLessThanOrEqual(store.totalBytes(), 2_500)
    }

    func testUsingAClipKeepsItOutOfTheEvictionOrder() throws {
        let store = GoodPostVideoDiskStore(limitBytes: 2_500, directory: makeDirectory())
        let older = "bucket.example.test/clips/seen-long-ago.mp4"
        let newer = "bucket.example.test/clips/seen-yesterday.mp4"
        store.write(key: older, data: Data(repeating: 0x41, count: 1_000))
        store.write(key: newer, data: Data(repeating: 0x42, count: 1_000))
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-600)], ofItemAtPath: store.fileURL(key: older).path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-500)], ofItemAtPath: store.fileURL(key: newer).path)

        // The reader watches the clip that was least recently used: it must not be the one that
        // goes next, which is exactly what keying eviction on the timestamp buys.
        XCTAssertNotNil(store.touch(key: older, now: now))
        store.write(key: "bucket.example.test/clips/watched-now.mp4", data: Data(repeating: 0x43, count: 1_000))
        store.trim(to: 2_500)

        XCTAssertGreaterThan(store.bytes(key: older), 0, "the clip just watched survives")
        XCTAssertEqual(store.bytes(key: newer), 0, "the clip not watched since goes")
    }

    // MARK: - Helpers

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("goodpost-video-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeStore(limitBytes: Int64 = GoodPostVideoDiskStore.defaultLimitBytes) -> GoodPostVideoDiskStore {
        GoodPostVideoDiskStore(limitBytes: limitBytes, directory: makeDirectory())
    }

    private func makeCache(session: URLSession) -> GoodPostVideoCache {
        GoodPostVideoCache(store: makeStore(), session: session)
    }

    /// The store is a detached background task, so a test waits for the file rather than for a
    /// flag: what matters is that the bytes are on disk.
    private func waitUntilStored(_ cache: GoodPostVideoCache, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cache.bytesCached() > 0 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return cache.bytesCached() > 0
    }

    /// Enough bytes to be a file, and small enough to be a test.
    private static let someVideoBytes = Data(repeating: 0x00, count: 4_096)

    /// A stand-in bucket: counts the requests it answered.
    private final class VideoServer {
        private let bytes: Data
        private let status: Int
        let session: URLSession

        /// Requests the bucket has answered — what "did this clip get re-downloaded?" means.
        var requests: Int { Server.count }

        init(bytes: Data, status: Int = 200) {
            self.bytes = bytes
            self.status = status
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [Server.self]
            Server.payload = bytes
            Server.status = status
            Server.count = 0
            session = URLSession(configuration: configuration)
        }

        private final class Server: URLProtocol {
            static var payload = Data()
            static var status = 200
            static var count = 0

            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

            override func startLoading() {
                Server.count += 1
                let response = HTTPURLResponse(url: request.url!, statusCode: Server.status, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": "video/mp4"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Server.payload)
                client?.urlProtocolDidFinishLoading(self)
            }

            override func stopLoading() {}
        }
    }
}

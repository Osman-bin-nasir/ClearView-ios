import XCTest
@testable import ClearView

/// The two load-bearing rules of the image cache, both of them about a URL that changes while
/// the bytes it points at do not.
///
/// Good Post's media URLs are signed: the bucket's credential and expiry are query parameters
/// that the server re-issues on every read. A cache keyed on the whole URL is a cache that never
/// hits, which is what `AsyncImage` was doing before this file's subject existed — a channel
/// re-downloaded every picture on every cold open, and nothing was readable offline.
@MainActor
final class RemoteImageCacheTests: XCTestCase {

    private let firstSignature = "https://bucket.example.com/media/photo.jpg?X-Amz-Signature=aaa&X-Amz-Expires=900"
    private let secondSignature = "https://bucket.example.com/media/photo.jpg?X-Amz-Signature=bbb&X-Amz-Expires=900"

    /// A 1x1 PNG, so the decoder has something real to read.
    private static let onePixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    private func cleanUp(_ keys: [String]) {
        for key in keys { try? FileManager.default.removeItem(at: ImageDiskStore.fileURL(key: key)) }
    }

    func testTheKeyIgnoresTheSignatureSoARotatedURLStillHits() throws {
        let one = try XCTUnwrap(RemoteImageCache.parse(firstSignature))
        let two = try XCTUnwrap(RemoteImageCache.parse(secondSignature))
        XCTAssertEqual(RemoteImageCache.key(for: one), RemoteImageCache.key(for: two))
        XCTAssertEqual(RemoteImageCache.key(for: one), "bucket.example.com/media/photo.jpg")
    }

    func testTheKeyKeepsTheHostSoTwoBucketsCannotCollide() throws {
        let mine = try XCTUnwrap(RemoteImageCache.parse("https://a.example.com/media/photo.jpg"))
        let theirs = try XCTUnwrap(RemoteImageCache.parse("https://b.example.com/media/photo.jpg"))
        XCTAssertNotEqual(RemoteImageCache.key(for: mine), RemoteImageCache.key(for: theirs))
    }

    func testOnlyHTTPURLsAreCacheable() {
        XCTAssertNil(RemoteImageCache.parse(nil))
        XCTAssertNil(RemoteImageCache.parse(""))
        XCTAssertNil(RemoteImageCache.parse("file:///tmp/photo.jpg"))
        XCTAssertNotNil(RemoteImageCache.parse("https://bucket.example.com/photo.jpg"))
    }

    func testAStoredFileAnswersForEverySignedFormOfTheSameObject() throws {
        let cache = RemoteImageCache.shared
        let key = RemoteImageCache.key(for: try XCTUnwrap(RemoteImageCache.parse(firstSignature)))
        defer { cleanUp([key]) }
        RemoteImageCache.writeDisk(key: key, data: Data(base64Encoded: Self.onePixelPNG)!)

        XCTAssertGreaterThan(cache.diskBytes(for: firstSignature), 0)
        // The rotated URL names the same object, so it reports those bytes rather than none.
        XCTAssertEqual(cache.diskBytes(for: secondSignature), cache.diskBytes(for: firstSignature))
        // And forgetting one form forgets the object.
        cache.forget([secondSignature])
        XCTAssertEqual(cache.diskBytes(for: firstSignature), 0)
    }

    func testAnExpiredFileIsDeletedRatherThanServed() throws {
        let key = RemoteImageCache.key(for: try XCTUnwrap(RemoteImageCache.parse(firstSignature)))
        let file = ImageDiskStore.fileURL(key: key)
        defer { cleanUp([key]) }
        RemoteImageCache.writeDisk(key: key, data: Data(base64Encoded: Self.onePixelPNG)!)
        XCTAssertNotNil(RemoteImageCache.readDisk(key: key))

        // Eight days old is past the seven-day window.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-8 * 24 * 60 * 60)],
            ofItemAtPath: file.path
        )
        XCTAssertNil(RemoteImageCache.readDisk(key: key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testTheDiskStoreWritesAFilePerObjectThatNoURLCanEscape() throws {
        let key = RemoteImageCache.key(for: try XCTUnwrap(RemoteImageCache.parse("https://bucket.example.com/a/../b/photo.jpg")))
        defer { cleanUp([key]) }
        try FileManager.default.createDirectory(at: ImageDiskStore.directory(), withIntermediateDirectories: true)
        RemoteImageCache.writeDisk(key: key, data: Data([1, 2, 3]))
        let file = ImageDiskStore.fileURL(key: key)
        // Hashed, not derived from the URL: no path traversal, and no name that can collide.
        XCTAssertTrue(file.path.hasPrefix(ImageDiskStore.directory().path))
        XCTAssertNotEqual(file.lastPathComponent, key)
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
    }
}

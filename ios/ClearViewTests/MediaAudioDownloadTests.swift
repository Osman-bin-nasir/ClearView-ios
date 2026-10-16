import AVFoundation
import XCTest
@testable import ClearView

final class MediaAudioDownloadTests: XCTestCase {
    func testParallelRangesProduceTheOriginalAudioBytes() async throws {
        let body = Data((0..<(1024 * 1024 + 100)).map { UInt8($0 % 251) })
        let session = fixtureSession(body: body, ignoreRanges: false, truncateRanges: false)
        defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("audio.m4a")
        let size = try await AudioFileDownloader(session: session).download(
            url: URL(string: "https://audio.test/file")!, partURL: root.appendingPathComponent("audio.part"),
            destination: destination, expectedTotal: Int64(body.count), onProgress: { _ in })
        XCTAssertEqual(size, Int64(body.count))
        XCTAssertEqual(try Data(contentsOf: destination), body)
    }

    func testIgnoredParallelRangesFallBackToASingleIntactDownload() async throws {
        let body = Data(repeating: 42, count: 1024 * 1024 + 100)
        let session = fixtureSession(body: body, ignoreRanges: true, truncateRanges: false)
        defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("audio.m4a")
        _ = try await AudioFileDownloader(session: session).download(
            url: URL(string: "https://audio.test/file")!, partURL: root.appendingPathComponent("audio.part"),
            destination: destination, expectedTotal: Int64(body.count), onProgress: { _ in })
        XCTAssertEqual(try Data(contentsOf: destination), body)
    }

    func testAnIncompletePreallocatedDownloadIsNeverPublished() async throws {
        let body = Data(repeating: 42, count: 1024 * 1024 + 100)
        let session = fixtureSession(body: body, ignoreRanges: false, truncateRanges: true)
        defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("audio.m4a")
        let part = root.appendingPathComponent("audio.part")
        do {
            _ = try await AudioFileDownloader(session: session).download(
                url: URL(string: "https://audio.test/file")!, partURL: part, destination: destination,
                expectedTotal: Int64(body.count), onProgress: { _ in })
            XCTFail("an incomplete audio file must not be published")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: part.path))
    }

    private func fixtureSession(body: Data, ignoreRanges: Bool, truncateRanges: Bool) -> URLSession {
        DownloadFixtureProtocol.response = { request in
            if let range = request.value(forHTTPHeaderField: "Range"), !(ignoreRanges && range != "bytes=0-0") {
                let parts = range.replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
                let first = Int(parts[0])!, last = Int(parts[1])!
                let count = last - first + 1
                let data = body.subdata(in: first..<(last + 1))
                let bytes = truncateRanges && count > 1 ? Data(data.prefix(count / 2)) : data
                return (206, ["Content-Type": "audio/mp4", "Content-Length": "\(count)",
                              "Content-Range": "bytes \(first)-\(last)/\(body.count)"], bytes)
            }
            return (200, ["Content-Type": "audio/mp4", "Content-Length": "\(body.count)"], body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DownloadFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: - Container normalization (the "23 minute download")

    /// A fragmented container is what AVFoundation measures at twice its real
    /// length, so recognising it is what decides whether a remux happens.
    func testAFragmentedContainerIsRecognisedByItsMoofMarker() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // What YouTube serves: `moov` carrying `mvex`, then `moof`/`mdat` pairs.
        let fragmented = root.appendingPathComponent("fragmented.m4a")
        var bytes = Data("ftypM4A moov mvex sidx ".utf8)
        bytes.append(Data("moof".utf8))
        bytes.append(Data(repeating: 0, count: 4096))
        try bytes.write(to: fragmented)
        XCTAssertTrue(FragmentedAudioRemuxer.isFragmented(fragmented))

        // A progressive download — `moov` and `mdat`, no fragments — is measured
        // correctly as it stands and must not be copied for nothing.
        let progressive = root.appendingPathComponent("progressive.m4a")
        try Data("ftypM4A moov mdat audio".utf8).write(to: progressive)
        XCTAssertFalse(FragmentedAudioRemuxer.isFragmented(progressive))

        // Past the sniff window the answer is "not fragmented": a fragmented
        // file carries its first `moof` in its head, which is where the camera
        // looks, and the cost of being wrong here is one unnecessary remux.
        let deep = root.appendingPathComponent("deep.m4a")
        var padded = Data(repeating: 0, count: FragmentedAudioRemuxer.sniffBytes + 16)
        padded.append(Data("moof".utf8))
        try padded.write(to: deep)
        XCTAssertFalse(FragmentedAudioRemuxer.isFragmented(deep))
    }

    @MainActor
    func testADownloadedFragmentedFileIsPublishedAsItsRemuxedSelf() async throws {
        let downloaded = try audioFixture(seconds: 1.6)
        // A deliberately *different* file, so the assertions can tell which of
        // the two was published.
        let remuxed = try audioFixture(seconds: 2.4)
        let session = fixtureSession(body: downloaded, ignoreRanges: false, truncateRanges: false)
        defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AudioDownloadStore(root: root)
        let manager = AudioDownloads(
            store: store,
            extractor: StubAudioExtractor(url: URL(string: "https://audio.test/file")!),
            downloader: AudioFileDownloader(session: session),
            normalizer: StubContainerNormalizer(needsWork: true, fails: false, output: remuxed)
        )
        let video = youTubeVideo()
        manager.download(video)
        try await waitForSubmission(manager, id: video.id)

        XCTAssertNil(manager.errors[video.id])
        let item = try XCTUnwrap(manager.item(for: video.id))
        XCTAssertEqual(
            try Data(contentsOf: store.fileURL(for: item)), remuxed,
            "the remuxed container must be published, not the fragmented original"
        )
        XCTAssertEqual(item.fileSize, Int64(remuxed.count))
        XCTAssertEqual(item.fileName, "\(video.id).m4a")
        XCTAssertGreaterThanOrEqual(
            item.durationSeconds, 1,
            "the manifest must record the published file's own length, not the feed's unknown 0"
        )
        // One download is one file: the scratch remux must not survive beside it.
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(video.id) },
            ["\(video.id).m4a"]
        )
    }

    @MainActor
    func testARemuxThatFailsStillPublishesTheAudioThatWasDownloaded() async throws {
        let downloaded = try audioFixture(seconds: 1.6)
        let session = fixtureSession(body: downloaded, ignoreRanges: false, truncateRanges: false)
        defer { session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AudioDownloadStore(root: root)
        let manager = AudioDownloads(
            store: store,
            extractor: StubAudioExtractor(url: URL(string: "https://audio.test/file")!),
            downloader: AudioFileDownloader(session: session),
            normalizer: StubContainerNormalizer(needsWork: true, fails: true, output: Data())
        )
        let video = youTubeVideo()
        manager.download(video)
        try await waitForSubmission(manager, id: video.id)

        // A fragmented file plays; it merely plays silence after its real end.
        // Keeping it beats losing the download, so a failed remux is not an error.
        XCTAssertNil(manager.errors[video.id])
        let item = try XCTUnwrap(manager.item(for: video.id))
        XCTAssertEqual(try Data(contentsOf: store.fileURL(for: item)), downloaded)
        XCTAssertEqual(item.fileSize, Int64(downloaded.count))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(video.id) },
            ["\(video.id).m4a"],
            "a failed remux must leave no scratch file behind"
        )
    }

    // MARK: - Fixtures for the manager

    /// Real, playable AAC of `seconds` length.
    ///
    /// Real audio rather than bytes that merely start like it: the manager
    /// checks `isPlayable` and a non-empty audio track on whatever it publishes,
    /// so a fake container would fail the very step under test.
    private func audioFixture(seconds: Double) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            let frames = AVAudioFrameCount(44_100 * seconds)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            try file.write(from: buffer)
        }
        return try Data(contentsOf: url)
    }

    private func youTubeVideo(id: String = "k9VvSaQC53Y") -> LibraryVideo {
        LibraryVideo(id: id, title: "A talk", channel: "Channel",
                     url: "https://www.youtube.com/watch?v=\(id)")
    }

    /// Waits for the manager's background task to file either an item or an error.
    @MainActor
    private func waitForSubmission(_ manager: AudioDownloads, id: String, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if manager.item(for: id) != nil || manager.errors[id] != nil { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("the download neither finished nor failed within \(timeout)s")
    }
}

private struct StubAudioExtractor: AudioStreamExtracting {
    let url: URL
    func extractAudio(videoId: String) async throws -> ExtractedAudio {
        ExtractedAudio(url: url, fileExtension: "m4a", mimeType: "audio/mp4", bitrate: 128_000, contentLength: nil)
    }
}

private struct StubContainerNormalizer: AudioContainerNormalizing {
    let needsWork: Bool
    let fails: Bool
    let output: Data
    func needsNormalizing(_ url: URL) -> Bool { needsWork }
    func normalize(_ url: URL, to output: URL) async throws {
        if fails { throw AudioDownloadError.invalidResponse }
        try self.output.write(to: output)
    }
}

// MARK: - The download's own vocabulary

extension MediaAudioDownloadTests {

    /// The size a reader sees, in the exact wording Android's `formatBytes` produces:
    /// each unit switch happens at its own power of two, one decimal is shown, and a
    /// whole value loses it ("14 MB", never "14.0 MB").
    func testByteSizesAreWordedLikeAndroid() {
        XCTAssertEqual(AudioDownloadFormat.bytes(0), "0 B")
        XCTAssertEqual(AudioDownloadFormat.bytes(500), "500 B")
        XCTAssertEqual(AudioDownloadFormat.bytes(1023), "1023 B")
        XCTAssertEqual(AudioDownloadFormat.bytes(1024), "1 KB")
        XCTAssertEqual(AudioDownloadFormat.bytes(14 * 1024), "14 KB")
        XCTAssertEqual(AudioDownloadFormat.bytes(14 * 1024 * 1024), "14 MB")
        XCTAssertEqual(AudioDownloadFormat.bytes(286_720_000), "273.4 MB")
        XCTAssertEqual(AudioDownloadFormat.bytes(1_500_000_000), "1.4 GB")
        // A negative can only come from a broken report; "-5 B" would be worse than "0 B".
        XCTAssertEqual(AudioDownloadFormat.bytes(-5), "0 B")
    }

    /// "~2m 30s left" — and silence while the estimate would be noise.
    ///
    /// The sub-2-second case is deliberate in Android and kept here: an estimate that
    /// reads "~0s left" for the last second of every download is less useful than no
    /// estimate at all, and nil (nothing measured yet) is the same answer.
    func testEtaIsWordedLikeAndroidAndStaysQuietWhenItWouldBeNoise() {
        XCTAssertEqual(AudioDownloadFormat.eta(seconds: nil), "")
        XCTAssertEqual(AudioDownloadFormat.eta(seconds: -1), "")
        XCTAssertEqual(AudioDownloadFormat.eta(seconds: 0), "")
        XCTAssertEqual(AudioDownloadFormat.eta(seconds: 1), "")
        XCTAssertEqual(AudioDownloadFormat.eta(seconds: 45), "~45s left")
        XCTAssertEqual(AudioDownloadFormat.eta(seconds: 150), "~2m 30s left")
        XCTAssertEqual(AudioDownloadFormat.eta(seconds: 3600), "~1h 0m left")
        XCTAssertEqual(AudioDownloadFormat.eta(seconds: 5400), "~1h 30m left")
    }

    /// YouTube's fragmented MP4 makes AVFoundation measure a stream at twice its real
    /// length — measured, not assumed: a file whose own boxes declared 715.128 s had
    /// `AVPlayerItem.duration` answering 1430.208 s.
    ///
    /// Audio mode hands that container straight to `AVPlayer`, so the number is
    /// corrected against the length the source already knows. This is the correction,
    /// and it is deliberately narrow.
    func testADoubledContainerDurationIsCorrectedToTheSourcesOwnLength() {
        XCTAssertEqual(AudioPlaybackController.trustedDuration(reported: 1430.208, expected: 715.128), 715.128)
        XCTAssertEqual(AudioPlaybackController.trustedDuration(reported: 9128.5, expected: 4564.25), 4564.25)
    }

    /// Anything that is not a near-exact doubling is believed as it stands: a stream
    /// whose length legitimately differs from the feed's record (a re-upload, an
    /// edited cut) must not be silently rewritten to the older number.
    func testANonDoubledDurationIsLeftAlone() {
        // Right length.
        XCTAssertEqual(AudioPlaybackController.trustedDuration(reported: 715.0, expected: 715.128), 715.0)
        // Legitimately longer than the feed record, but not by a doubling.
        XCTAssertEqual(AudioPlaybackController.trustedDuration(reported: 900, expected: 715.128), 900)
        // More than a doubling — three times is a different fault, not this one.
        XCTAssertEqual(AudioPlaybackController.trustedDuration(reported: 2145, expected: 715.128), 2145)
        // Nothing known to check against, and nothing finite to report.
        XCTAssertEqual(AudioPlaybackController.trustedDuration(reported: 715.0, expected: 0), 715.0)
        XCTAssertEqual(AudioPlaybackController.trustedDuration(reported: .nan, expected: 715.128), 0)
        XCTAssertEqual(AudioPlaybackController.trustedDuration(reported: -3, expected: 715.128), 0)
    }
}

private final class DownloadFixtureProtocol: URLProtocol {
    static var response: ((URLRequest) -> (Int, [String: String], Data))!
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "audio.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, headers, data) = Self.response(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

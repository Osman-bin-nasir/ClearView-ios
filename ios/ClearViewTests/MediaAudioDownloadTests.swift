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

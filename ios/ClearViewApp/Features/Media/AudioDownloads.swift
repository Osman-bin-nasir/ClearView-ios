import Foundation
import AVFoundation
import Observation

/// Live progress for one in-flight download.
struct AudioDownloadProgress: Equatable {
    enum Phase: Equatable {
        /// Asking YouTube for the audio URL.
        case resolving
        /// Transferring bytes.
        case downloading
        case processing
    }

    var phase: Phase = .resolving
    /// 0…1 when the total size is known, or -1 while it is not (indeterminate) —
    /// the same convention as Android's `Downloader.Progress`.
    var fraction: Double = -1
    var bytesWritten: Int64 = 0
    var totalBytes: Int64?
    var etaSeconds: Int64?
}

/// A failure while fetching audio bytes.
enum AudioDownloadError: LocalizedError {
    case http(Int)
    case invalidResponse
    case rangeIgnored
    case empty
    case incomplete

    var errorDescription: String? {
        switch self {
        case .http(let status) where status == 429 || status >= 500:
            return "The media server refused the download (HTTP \(status)). Try again in a moment."
        case .http(let status):
            return "The media server refused the download (HTTP \(status))."
        case .invalidResponse:
            return "The download server sent a response this app could not read."
        case .rangeIgnored:
            return "The download server ignored a partial-range request."
        case .empty:
            return "The download finished but produced no audio."
        case .incomplete:
            return "The audio download was interrupted before all bytes arrived. Try again."
        }
    }
}

/// Transfers one resolved audio stream to disk.
///
/// Two strategies, chosen the way Android's downloader chooses them:
///
/// - **Parallel ranges** when the server honours `Range` requests and the file
///   is worth splitting. YouTube's media servers do honour them, so this is the
///   normal path, and it is usually several times faster than one sequential
///   stream. Each chunk is written at its own offset through its own file
///   handle, so no two writers touch the same bytes.
/// - **A single stream** otherwise. This still streams into the file through a
///   bounded buffer rather than holding the whole download in memory, so a long
///   recording cannot exhaust the app's memory.
///
/// Bytes always land in a `.part` file that is renamed only on success, so an
/// interrupted download can never be mistaken for a finished one.
struct AudioFileDownloader {

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Above this, several concurrent ranged responses would be buffered in
    /// memory faster than they are written, and one disk-backed stream is the
    /// better trade. Audio that reaches this size is measured in hours, where
    /// the transfer is bandwidth-bound anyway.
    static let maxParallelTotalBytes: Int64 = 64 * 1024 * 1024

    /// A desktop-class UA, matching what the extractor's URLs were minted for.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// Downloads `url` into a `.part` file, then renames it to `destination`.
    /// Returns the finished file's size in bytes.
    @discardableResult
    func download(
        url: URL,
        partURL: URL,
        destination: URL,
        expectedTotal: Int64?,
        onProgress: @escaping (AudioDownloadProgress) -> Void
    ) async throws -> Int64 {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fileManager.removeItem(at: partURL)
        try? fileManager.removeItem(at: destination)
        defer { try? fileManager.removeItem(at: partURL) }

        let startedAt = Date()
        let probe = try? await probeTotal(url: url)
        try Task.checkCancellation()
        let total = probe?.total ?? expectedTotal

        /// Serialises every progress read so concurrent chunks cannot report a
        /// stale count, and throttles writes to the UI.
        let reporter = ProgressReporter(
            total: total, startedAt: startedAt,
            onProgress: { written in
                onProgress(AudioDownloadProgress(
                    phase: .downloading,
                    fraction: total.flatMap { $0 > 0 ? min(1, Double(written) / Double($0)) : -1 } ?? -1,
                    bytesWritten: written,
                    totalBytes: total,
                    etaSeconds: total.flatMap {
                        AudioDownloadChunking.estimateETASeconds(total: $0, written: written, startedAt: startedAt)
                    }
                ))
            }
        )

        // Announce the size before the transfer so the UI can show "≈ X MB".
        if let total {
            onProgress(AudioDownloadProgress(phase: .downloading, fraction: 0,
                                             bytesWritten: 0, totalBytes: total, etaSeconds: nil))
        }

        if let probe, probe.supportsRanges, let total, total > 0, total <= Self.maxParallelTotalBytes {
            let ranges = AudioDownloadChunking.chunkRanges(total: total)
            if ranges.count > 1 {
                do {
                    try await downloadParallel(url: url, ranges: ranges, total: total, partURL: partURL, reporter: reporter)
                } catch AudioDownloadError.rangeIgnored {
                    try Task.checkCancellation()
                    reporter.reset()
                    try await downloadSingle(url: url, partURL: partURL, reporter: reporter)
                }
            } else {
                try await downloadSingle(url: url, partURL: partURL, reporter: reporter)
            }
        } else {
            try await downloadSingle(url: url, partURL: partURL, reporter: reporter)
        }

        let size = (try? fileManager.attributesOfItem(atPath: partURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw AudioDownloadError.empty }
        guard size == reporter.bytesWritten, total.map({ size == $0 }) ?? true else { throw AudioDownloadError.incomplete }
        try Task.checkCancellation()
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: partURL, to: destination)
        return size
    }

    // MARK: - Strategies

    /// One sequential GET streamed into the part file through a bounded buffer.
    private func downloadSingle(
        url: URL,
        partURL: URL,
        reporter: ProgressReporter
    ) async throws {
        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("audio/*,*/*;q=0.9", forHTTPHeaderField: "Accept")
        try await stream(request, into: partURL, at: 0) { delta in reporter.add(delta) }
    }

    /// Concurrent ranged GETs, each written at its own offset.
    private func downloadParallel(
        url: URL,
        ranges: [ClosedRange<Int64>],
        total: Int64,
        partURL: URL,
        reporter: ProgressReporter
    ) async throws {
        // Pre-size the file so every chunk has somewhere to write. Each chunk
        // opens its own handle, so the positional writes never interleave.
        FileManager.default.createFile(atPath: partURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partURL)
        try handle.truncate(atOffset: UInt64(total))
        try handle.close()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for range in ranges {
                group.addTask {
                    var request = URLRequest(url: url)
                    request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
                    request.setValue("audio/*,*/*;q=0.9", forHTTPHeaderField: "Accept")
                    try await self.stream(request, into: partURL, at: range.lowerBound) { delta in
                        reporter.add(delta)
                    }
                }
            }
            try await group.waitForAll()
        }
    }

    /// Streams a request's body into `partURL` at `offset`, flushing through a
    /// bounded buffer so memory stays flat regardless of file size.
    private func stream(
        _ request: URLRequest,
        into partURL: URL,
        at offset: Int64,
        onBytes: (Int64) -> Void
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AudioDownloadError.invalidResponse }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            throw AudioDownloadError.http(http.statusCode)
        }
        if let type = http.mimeType, type.contains("html") || type.contains("json") {
            throw AudioDownloadError.invalidResponse
        }
        var expectedBytes: Int64? = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        if let rangeHeader = request.value(forHTTPHeaderField: "Range") {
            guard http.statusCode == 206 else { throw AudioDownloadError.rangeIgnored }
            let wanted = rangeHeader.replacingOccurrences(of: "bytes=", with: "").split(separator: "-")
            guard wanted.count == 2, let start = Int64(wanted[0]), let end = Int64(wanted[1]),
                  let actual = http.value(forHTTPHeaderField: "Content-Range"),
                  actual.lowercased().hasPrefix("bytes \(start)-\(end)/") else { throw AudioDownloadError.rangeIgnored }
            expectedBytes = end - start + 1
        } else if http.statusCode == 206 {
            throw AudioDownloadError.invalidResponse
        }

        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }
        if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }

        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(Self.bufferSize)
        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            received += 1
            if let expectedBytes, received > expectedBytes { throw AudioDownloadError.incomplete }
            if buffer.count >= Self.bufferSize {
                try handle.write(contentsOf: buffer)
                onBytes(Int64(buffer.count))
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            onBytes(Int64(buffer.count))
        }
        if let expectedBytes, received != expectedBytes { throw AudioDownloadError.incomplete }
    }

    private static let bufferSize = 256 * 1024

    // MARK: - Probing

    /// Asks for a single byte to learn the total size and whether the server
    /// honours ranges — Android's probe, and the reason the downloader can pick
    /// a strategy instead of guessing.
    private func probeTotal(url: URL) async throws -> (total: Int64?, supportsRanges: Bool) {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AudioDownloadError.invalidResponse }
        guard http.statusCode == 200 || http.statusCode == 206 else { throw AudioDownloadError.http(http.statusCode) }
        if http.statusCode == 206 {
            let total = AudioDownloadChunking.parseContentRangeTotal(http.value(forHTTPHeaderField: "Content-Range"))
            if let total { return (total, true) }
        }
        let length = http.expectedContentLength
        return (length > 0 ? Int64(length) : nil, false)
    }
}

/// Aggregates byte counts from concurrent chunks into one throttled progress
/// stream.
///
/// A final class with a lock rather than an actor: the callers are synchronous
/// per-write callbacks inside the download loops, and awaiting an actor on every
/// 256 KB would put a hop in the hot path for no benefit.
private final class ProgressReporter {
    private let lock = NSLock()
    private var written: Int64 = 0
    private var lastReported: Int64 = 0
    private let total: Int64?
    private let startedAt: Date
    private let onProgress: (Int64) -> Void

    /// Report at most every this many new bytes — Android's
    /// `PROGRESS_REPORT_BYTES`, so the UI is not rebuilt on every buffer.
    private static let reportBytes: Int64 = 512 * 1024

    init(total: Int64?, startedAt: Date, onProgress: @escaping (Int64) -> Void) {
        self.total = total
        self.startedAt = startedAt
        self.onProgress = onProgress
    }

    var bytesWritten: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    func reset() {
        lock.lock()
        written = 0
        lastReported = 0
        lock.unlock()
        onProgress(0)
    }

    func add(_ delta: Int64) {
        lock.lock()
        written += delta
        let current = written
        let shouldReport = current - lastReported >= Self.reportBytes
            || (total.map { current >= $0 } ?? false)
        if shouldReport { lastReported = current }
        lock.unlock()
        if shouldReport { onProgress(current) }
    }
}

/// The app's offline audio: the downloads manifest, in-flight transfers, and the
/// operations the Downloads screen and the player call.
///
/// A single shared instance, like Android's `AudioDownloads` object: the
/// downloads list, the feed's "downloaded" badges and the player all have to
/// agree about what is on disk, and two instances of this would disagree the
/// moment one of them refreshed.
@MainActor
@Observable
final class AudioDownloads {

    static let shared = AudioDownloads()

    private(set) var items: [AudioDownloadItem] = []
    /// In-flight progress, keyed by video id.
    private(set) var progress: [String: AudioDownloadProgress] = [:]
    /// The last failure per video id, so a row can say what went wrong.
    private(set) var errors: [String: String] = [:]
    /// Titles for downloads that are still in flight.
    ///
    /// The manifest only gains an item once the file is on disk, so without this
    /// an in-progress row could only label itself with the raw video id.
    private(set) var pendingTitles: [String: String] = [:]

    @ObservationIgnored let store: AudioDownloadStore
    @ObservationIgnored private let extractor: AudioStreamExtracting
    @ObservationIgnored private let downloader: AudioFileDownloader
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    init(
        store: AudioDownloadStore = AudioDownloadStore(),
        extractor: AudioStreamExtracting = YouTubeAudioExtractor(),
        downloader: AudioFileDownloader = AudioFileDownloader()
    ) {
        self.store = store
        self.extractor = extractor
        self.downloader = downloader
        try? store.ensureDirectory()
        items = store.load().filter { FileManager.default.fileExists(atPath: store.fileURL(for: $0).path) }
            .sorted { $0.downloadedAt > $1.downloadedAt }
    }

    // MARK: - Queries

    func item(for videoId: String) -> AudioDownloadItem? {
        items.first { $0.videoId == videoId }
    }

    func isDownloaded(_ videoId: String) -> Bool {
        fileURL(for: videoId) != nil
    }

    func isDownloading(_ videoId: String) -> Bool {
        tasks[videoId] != nil
    }

    func fileURL(for videoId: String) -> URL? {
        guard let item = item(for: videoId) else { return nil }
        let url = store.fileURL(for: item)
        // The manifest can outlive the file if the container was restored from a
        // backup that did not include Application Support; a row for a missing
        // file is a row that plays silence.
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Mutations

    /// Resolves and downloads the audio for `video`.
    ///
    /// `video` supplies only the metadata recorded alongside the audio; the URL
    /// that is actually fetched comes from the extractor, never from the video.
    func download(_ video: LibraryVideo, source: String = AudioDownloadItem.sourceRSS) {
        let videoId = video.id
        guard tasks[videoId] == nil, fileURL(for: videoId) == nil else { return }
        errors[videoId] = nil
        pendingTitles[videoId] = video.title
        progress[videoId] = AudioDownloadProgress(phase: .resolving)
        MediaLog.downloads.info("download \(videoId, privacy: .public): started (\(video.title, privacy: .public))")

        tasks[videoId] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.progress[videoId] = nil
                self.tasks[videoId] = nil
                self.pendingTitles[videoId] = nil
            }
            do {
                let extracted: ExtractedAudio
                if video.isYouTube {
                    extracted = try await self.extractor.extractAudio(videoId: videoId)
                } else {
                    let url = try await SocialMediaStreamResolver.shared.resolve(video)
                    guard url.pathExtension.lowercased() != "m3u8" else { throw AudioExtractionError.noAudioStream }
                    extracted = ExtractedAudio(url: url, fileExtension: "mp4", mimeType: "video/mp4", bitrate: 0, contentLength: nil)
                }
                try Task.checkCancellation()
                var destination = self.store.audioDirectory
                    .appendingPathComponent("\(videoId).\(extracted.fileExtension)")
                var size = try await self.downloader.download(
                    url: extracted.url,
                    partURL: self.store.partURL(videoId: videoId),
                    destination: destination,
                    expectedTotal: extracted.contentLength
                ) { update in
                    Task { @MainActor [weak self] in self?.progress[videoId] = update }
                }
                if extracted.mimeType.hasPrefix("video/") {
                    self.progress[videoId] = AudioDownloadProgress(phase: .processing)
                    let original = destination
                    defer { try? FileManager.default.removeItem(at: original) }
                    destination = self.store.audioDirectory.appendingPathComponent("\(videoId).m4a")
                    let temporary = self.store.audioDirectory.appendingPathComponent("\(videoId).audio.part.m4a")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try? FileManager.default.removeItem(at: temporary)
                    guard let export = AVAssetExportSession(asset: AVURLAsset(url: original), presetName: AVAssetExportPresetAppleM4A) else {
                        throw AudioExtractionError.noAudioStream
                    }
                    try await export.export(to: temporary, as: .m4a)
                    try Task.checkCancellation()
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
                    guard size > 0 else { throw AudioDownloadError.empty }
                }
                let asset = AVURLAsset(url: destination)
                guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
                    try? FileManager.default.removeItem(at: destination)
                    throw AudioExtractionError.noAudioStream
                }
                try Task.checkCancellation()
                self.finish(video: video, extracted: extracted, destination: destination, size: size, source: source)
            } catch is CancellationError {
                // Cancelling is an outcome the reader asked for, not an error.
                MediaLog.downloads.info("download \(videoId, privacy: .public): cancelled")
            } catch {
                MediaLog.downloads.error("download \(videoId, privacy: .public): failed — \(error.localizedDescription, privacy: .public)")
                self.errors[videoId] = error.localizedDescription
            }
        }
    }

    private func finish(
        video: LibraryVideo,
        extracted: ExtractedAudio,
        destination: URL,
        size: Int64,
        source: String
    ) {
        let item = AudioDownloadItem(
            videoId: video.id,
            title: video.title,
            channelName: video.channel,
            source: source,
            fileName: destination.lastPathComponent,
            fileSize: size,
            downloadedAt: Int64(Date().timeIntervalSince1970 * 1000),
            lastPlayed: 0,
            expiresAt: 0,
            // iOS has no local thumbnail cache keyed by file name, so this holds
            // the source's image URL, which the downloads list loads directly.
            thumbnailPath: video.thumbnail ?? "",
            durationSeconds: video.durationSeconds ?? 0,
            channelId: video.channelID ?? ""
        )
        items.removeAll { $0.videoId == item.videoId }
        items.insert(item, at: 0)
        persist()
        MediaLog.downloads.info("download \(item.videoId, privacy: .public): saved \(item.fileName, privacy: .public), \(size, privacy: .public) bytes as \(extracted.fileExtension, privacy: .public)")
    }

    /// Stops an in-flight download for `videoId`.
    func cancel(_ videoId: String) {
        tasks[videoId]?.cancel()
    }

    /// Deletes a downloaded file and its manifest entry.
    func remove(_ item: AudioDownloadItem) {
        tasks[item.videoId]?.cancel()
        items = store.remove(item, from: items)
        persist()
    }

    /// Records that a downloaded track was played, so the list can sort or
    /// filter by recency the way Android's does.
    func markPlayed(_ videoId: String) {
        guard let index = items.firstIndex(where: { $0.videoId == videoId }) else { return }
        items[index].lastPlayed = Int64(Date().timeIntervalSince1970 * 1000)
        persist()
    }

    /// Re-reads the manifest from disk. The screen calls this on appear so a
    /// download that finished while the app was elsewhere shows up.
    func reload() {
        items = store.load().filter { FileManager.default.fileExists(atPath: store.fileURL(for: $0).path) }
            .sorted { $0.downloadedAt > $1.downloadedAt }
    }

    private func persist() {
        do {
            try store.save(items)
        } catch {
            errors["__manifest"] = "Couldn't save the downloads list. (\(error.localizedDescription))"
        }
    }
}

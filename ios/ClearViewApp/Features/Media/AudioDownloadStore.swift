import Foundation

/// One offline audio download, persisted as `metadata.json` beside the audio.
///
/// The Swift shape of the Android `DownloadItem`, field for field, because the
/// metadata is the record of what is on disk and the two apps should not
/// disagree about what a download *is*.
///
/// Names rather than absolute paths are stored: iOS moves an app's container
/// between installs (and between the simulator and a device), so a stored
/// absolute path is a promise the OS does not keep. The file is resolved
/// against the *current* audio directory at read time.
struct AudioDownloadItem: Codable, Identifiable, Hashable, Sendable {
    let videoId: String
    var title: String
    var channelName: String
    /// Where the video came from: a saved channel's feed, a pasted URL, or the
    /// device's own storage.
    var source: String
    /// The audio file's name inside the audio directory (`<videoId>.m4a`).
    var fileName: String
    var fileSize: Int64
    var downloadedAt: Int64
    var lastPlayed: Int64
    /// Always 0. Downloads are never auto-deleted; the field exists so metadata
    /// written by the Android builds that had a 15-day expiry rule still decodes.
    var expiresAt: Int64
    var thumbnailPath: String
    var durationSeconds: Int64
    /// The video's channel id (empty when unknown). Drives per-channel filtering.
    var channelId: String

    var id: String { videoId }

    static let sourceRSS = "rss"
    static let sourceURL = "url"
    static let sourceDevice = "device"
}

/// Where downloads live on disk, and how their metadata is read and written.
///
/// A `struct` of paths rather than a class with state: every method here is a
/// pure function of the file system, so the downloader and the UI can both ask
/// the same questions without sharing a cache that could go stale.
struct AudioDownloadStore {

    /// The audio files and their `metadata.json` live under Application Support,
    /// not Caches: the system may purge Caches under disk pressure, and a
    /// download the reader explicitly asked to keep must not be that.
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.root = base.appendingPathComponent("ClearView/Audio", isDirectory: true)
        }
    }

    /// Directory holding the finished audio files.
    var audioDirectory: URL { root }

    /// The temporary file a download writes into before it is renamed.
    ///
    /// The intermediate lives beside the destination so the final `moveItem` is
    /// a rename within one volume. An interrupted download therefore never
    /// leaves a file that looks complete — the same rule as Android's `.part` file.
    func partURL(videoId: String) -> URL {
        root.appendingPathComponent("\(videoId).part")
    }

    /// The finished file for `item`, with the name its metadata recorded.
    func fileURL(for item: AudioDownloadItem) -> URL {
        root.appendingPathComponent(item.fileName)
    }

    /// The finished file for a video id, whatever extension it was saved with.
    func existingFileURL(videoId: String) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        return contents.first { $0.deletingPathExtension().lastPathComponent == videoId && $0.pathExtension != "part" }
    }

    private var metadataURL: URL { root.appendingPathComponent("metadata.json") }

    func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Reads the manifest; empty on a missing or corrupt file.
    ///
    /// Corrupt metadata must not be fatal: it is a cache of what is on disk, and
    /// refusing to open the Downloads screen because one record is unreadable
    /// would strand the audio files that are perfectly fine.
    func load() -> [AudioDownloadItem] {
        guard let data = try? Data(contentsOf: metadataURL) else { return [] }
        return (try? JSONDecoder().decode([AudioDownloadItem].self, from: data)) ?? []
    }

    func save(_ items: [AudioDownloadItem]) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(items).write(to: metadataURL, options: .atomic)
    }

    /// Deletes an item's audio and its thumbnail record, returning the manifest
    /// with the item removed.
    func remove(_ item: AudioDownloadItem, from items: [AudioDownloadItem]) -> [AudioDownloadItem] {
        try? FileManager.default.removeItem(at: fileURL(for: item))
        return items.filter { $0.videoId != item.videoId }
    }
}

/// The parallel-download split, ported from Android's `AudioDownloader.chunkRanges`.
///
/// YouTube's media servers honour range requests, so a large audio file is
/// fetched as several concurrent ranged GETs — usually several times faster than
/// one sequential stream. The chunk count scales with size on purpose: a 3-way
/// split of a 1 MB file would spend more time on connection setup than it saves,
/// while a 10 MB file benefits from the full fan-out.
///
/// Pure and static so the thresholds are unit-testable without a network.
enum AudioDownloadChunking {
    static let maxParallelChunks = 4
    static let minParallelBytes: Int64 = 1024 * 1024
    static let fullParallelBytes: Int64 = 3 * 1024 * 1024
    static let veryLargeBytes: Int64 = 10 * 1024 * 1024

    /// Splits `total` bytes into inclusive ranges, in order.
    static func chunkRanges(total: Int64) -> [ClosedRange<Int64>] {
        guard total > 0 else { return [] }
        let count: Int
        switch total {
        case let value where value >= veryLargeBytes: count = maxParallelChunks
        case let value where value >= fullParallelBytes: count = 3
        case let value where value >= minParallelBytes: count = 2
        default: count = 1
        }
        guard count > 1 else { return [0...(total - 1)] }
        let chunk = total / Int64(count)
        var ranges: [ClosedRange<Int64>] = []
        var start: Int64 = 0
        for index in 0..<count {
            let end = index == count - 1 ? total - 1 : start + chunk - 1
            ranges.append(start...end)
            start = end + 1
        }
        return ranges
    }

    /// `bytes 0-0/123456` → `123456`; nil when absent or unparseable.
    static func parseContentRangeTotal(_ header: String?) -> Int64? {
        guard let header else { return nil }
        let pattern = #"bytes\s+\d+-\d+/(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
              let range = Range(match.range(at: 1), in: header) else { return nil }
        return Int64(header[range])
    }

    /// Remaining seconds at the average speed so far, or nil while the estimate
    /// would be noise (nothing downloaded, or under a second elapsed).
    static func estimateETASeconds(total: Int64, written: Int64, startedAt: Date, now: Date = Date()) -> Int64? {
        guard total > 0, written > 0 else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= 1 else { return nil }
        let speed = Double(written) / elapsed
        guard speed > 0 else { return nil }
        return Int64(max(0, (Double(total - written) / speed).rounded(.down)))
    }
}

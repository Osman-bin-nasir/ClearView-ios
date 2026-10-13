import Foundation

/// The on-disk cache of raw downloaded edition JSON.
///
/// Kept as the *raw body*, not as parsed verses, for the reason the Android
/// store gives: the file is written once, the app then works fully offline, and
/// re-parsing is cheap enough to do on demand. Parsing is what validates the
/// cache, so a truncated file is re-downloaded rather than trusted.
///
/// The directory is `Application Support/QuranEditions`, and it is flagged as
/// excluded from backup: the contents are re-downloadable, and iCloud would
/// otherwise be asked to sync a multi-megabyte copy of a text it can fetch.
struct QuranCache {

    let directory: URL

    private let fileManager = FileManager.default

    /// The cache the app uses.
    static let applicationSupport = QuranCache(directory: defaultDirectory)

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("QuranEditions", isDirectory: true)
    }

    func fileURL(for edition: QuranEdition) -> URL {
        directory.appendingPathComponent(edition.cacheFileName)
    }

    /// True when a non-empty file is present. Existence is not enough: a
    /// half-written file from a killed process has the right path and no
    /// content, and treating it as a valid cache is how a reader ends up
    /// permanently empty.
    func isCached(_ edition: QuranEdition) -> Bool {
        guard let size = try? fileURL(for: edition).resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return false
        }
        return size > 0
    }

    func read(_ edition: QuranEdition) throws -> String {
        try String(contentsOf: fileURL(for: edition), encoding: .utf8)
    }

    /// Writes atomically, so an interrupted write cannot leave a partial file
    /// that a later build would read as a valid cache.
    func write(_ edition: QuranEdition, json: String) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = fileURL(for: edition)
        try Data(json.utf8).write(to: destination, options: [.atomic])

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = destination
        try? url.setResourceValues(values)
    }

    func remove(_ edition: QuranEdition) throws {
        let url = fileURL(for: edition)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}

import Foundation
import CryptoKit

/// A disk cache for the videos Good Post plays.
///
/// The requirement is Android's, and it is a data-cost requirement rather than a
/// performance one: without this, every open of a clip re-downloads it from the bucket, and a
/// channel update is a file somebody sent to a phone — so "re-watching the same clip twice
/// costs the data twice" is the difference between a cheap product and an expensive one. With
/// it, the second play is silent: no request, no bytes, no waiting for a stream to start.
///
/// ## The key is the object, never the URL
///
/// A Good Post media URL is **signed**: the credential and its expiry are query parameters that
/// change on every read. A cache keyed on the whole URL would miss every single time — the clip
/// would be downloaded again on every visit, and the directory would fill with copies of one
/// video that nothing can find again. The bytes are therefore keyed by the object's own identity
/// (host and path, no query), which is also the value the app can compute later, and it is the
/// same rule the image cache follows and Android's `GoodPostVideoCache.cacheKeyFor` enforces.
///
/// ## Why there is no index file
///
/// Android's cache needs one because ExoPlayer's `SimpleCache` journals the *spans* it has
/// written and has to be able to name them later — which is why it also has to prune entries
/// keyed by a whole URL from before the key rule was fixed. A whole-file cache has no such
/// state: a file's name is the digest of its key, so every file in the directory is by
/// definition reachable, and a file's own modification date is its last use. That is what makes
/// the eviction rule here size-based LRU with nothing to keep in step.
///
/// ## What it deliberately does not do
///
/// It does not cache a *partly* watched clip incrementally the way a streaming cache does, and
/// it does not touch the reader's playback: the bytes are stored while the clip plays and the
/// second open begins at the first frame. It also never fails a playback — every path in here
/// falls back to the remote URL, because a video that streams without a cache is still a
/// working product and a cache that insists on itself is not.
@MainActor
final class GoodPostVideoCache {

    static let shared = GoodPostVideoCache()

    private let store: GoodPostVideoDiskStore
    private let session: URLSession
    /// Downloads in flight, so two views showing one clip store it once.
    private var inFlight: [String: Task<Void, Never>] = [:]

    /// Configurable for tests: a temporary directory and a small limit are what make the
    /// eviction rule checkable without writing a megabyte of video.
    init(store: GoodPostVideoDiskStore = GoodPostVideoDiskStore(), session: URLSession? = nil) {
        self.store = store
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            // The bytes are the point, so nothing here leans on `URLCache`: a video response is
            // cached by this class, by object key, and a second copy under `URLCache`'s
            // whole-URL key would be the same bytes twice.
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 30 * 60
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Playback

    /// The URL a player should open for `remote`: the stored copy when there is one, otherwise
    /// the remote URL itself.
    ///
    /// Synchronous on purpose. The caller is a view that is building a player, and the two
    /// answers it can act on are "these bytes are on this device" and "stream it" — an `async`
    /// lookup would only add a frame where nothing is drawn.
    func playbackURL(for remote: String) -> URL? {
        guard let url = Self.parse(remote) else { return nil }
        if let file = store.touch(key: store.key(for: url)) { return file }
        return url
    }

    /// Stores the clip's bytes in the background, if they are not stored already.
    ///
    /// Called when playback actually starts — not when a post scrolls into view. The reader
    /// tapped play, which is the moment Android's player starts filling its cache too, and
    /// downloading a clip nobody watched would be spending data on a guess.
    func prepare(_ remote: String) {
        guard let url = Self.parse(remote) else { return }
        let key = store.key(for: url)
        if store.bytes(key: key) > 0 { return }
        guard inFlight[key] == nil else { return }

        let store = self.store
        let session = self.session
        let limit = store.limitBytes
        inFlight[key] = Task.detached(priority: .utility) {
            defer { Task { @MainActor in GoodPostVideoCache.shared.finished(key) } }
            let data = await Self.fetch(url, session: session)
            guard let data, !data.isEmpty else { return }
            guard store.write(key: key, data: data) else { return }
            store.trim(to: limit)
        }
    }

    // MARK: - The reader's own storage

    /// How much of the disk cache one URL occupies — 0 when it is not stored.
    func bytes(for remote: String) -> Int64 {
        guard let url = Self.parse(remote) else { return 0 }
        return store.bytes(key: store.key(for: url))
    }

    /// Bytes currently held on disk.
    func bytesCached() -> Int64 { store.totalBytes() }

    /// Drops one clip's local copy, and reports what that freed.
    ///
    /// The copy on the server is untouched: a reader who opens the clip again streams it once
    /// more rather than being told it is gone.
    @discardableResult
    func evict(_ remotes: [String]) -> Int64 {
        var freed: Int64 = 0
        for remote in remotes {
            guard let url = Self.parse(remote) else { continue }
            freed += store.remove(key: store.key(for: url))
        }
        return freed
    }

    /// Drops everything.
    func clear() { store.clear() }

    // MARK: - Internals

    private func finished(_ key: String) {
        inFlight[key] = nil
    }

    /// Fetches the bytes, refusing only what a video player could not use.
    ///
    /// A `4xx` from an expired signature is the case that matters: the caller is playing the
    /// remote URL in that situation, and the next open will carry a fresh URL and store the
    /// bytes then.
    nonisolated private static func fetch(_ url: URL, session: URLSession) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            MediaLog.video.error("cache: HTTP \(http.statusCode, privacy: .public) for \(url.host() ?? "-", privacy: .public)")
            return nil
        }
        return data
    }

    /// Only an `http(s)` URL can be fetched — a `file:` preview or an empty string is not a
    /// video this cache can answer for.
    nonisolated static func parse(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}

/// The on-disk half of the video cache.
///
/// Its own type, and outside the main actor, because the downloads that write it run off the
/// main actor: hashing and moving a hundred megabytes on the thread that draws is exactly the
/// stall this pair exists to avoid.
struct GoodPostVideoDiskStore {

    /// What the directory may occupy before the least recently used entries go. Small, because
    /// this is a cache and a phone has a camera roll on it — and the same number Android uses,
    /// so both apps free the same space under pressure.
    static let defaultLimitBytes: Int64 = 160 * 1024 * 1024

    var limitBytes: Int64 = GoodPostVideoDiskStore.defaultLimitBytes

    var directory: URL = GoodPostVideoDiskStore.defaultDirectory()

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("goodpost-video", isDirectory: true)
    }

    /// The cache key for a media URL: the object's identity, never the query.
    ///
    /// The host is included where Android keys on the path alone, so two buckets cannot
    /// collide on `/clips/1.mp4`. What matters is the property both share: a re-signed URL —
    /// new signature, new expiry, same object — is the same key.
    func key(for url: URL) -> String {
        "\((url.host() ?? "").lowercased())\(url.path)"
    }

    /// The file for a cache key: a digest of the key, so no URL can escape the directory or
    /// collide with another URL's name.
    func fileURL(key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest)
    }

    /// Bytes stored for a key, or 0.
    func bytes(key: String) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL(key: key).path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    /// Marks a key as used now and returns its file, or nil when it is not stored.
    ///
    /// The modification date **is** the last-used stamp: eviction reads it, so a clip the
    /// reader just watched is never the thing that goes next.
    func touch(key: String, now: Date = Date()) -> URL? {
        let file = fileURL(key: key)
        guard bytes(key: key) > 0 else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        return file
    }

    /// Writes a clip's bytes, atomically, creating the directory if it is not there.
    @discardableResult
    func write(key: String, data: Data) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(key: key), options: .atomic)
            return true
        } catch {
            MediaLog.video.error("cache: could not store \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Drops one key, returning what it freed.
    @discardableResult
    func remove(key: String) -> Int64 {
        let size = bytes(key: key)
        try? FileManager.default.removeItem(at: fileURL(key: key))
        return size
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Bytes stored in the directory.
    func totalBytes() -> Int64 {
        entries().reduce(0) { $0 + $1.size }
    }

    /// Every stored clip, least recently used first.
    func entries() -> [(url: URL, used: Date, size: Int64)] {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return [] }
        var found: [(url: URL, used: Date, size: Int64)] = []
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            found.append((file, values.contentModificationDate ?? .distantPast, Int64(values.fileSize ?? 0)))
        }
        return found.sorted { $0.used < $1.used }
    }

    /// Brings the directory back inside `limitBytes`, least recently used first.
    ///
    /// Size-based rather than count-based, which is Android's rule and the right one: one
    /// 50 MB clip and fifty 1 MB clips should occupy the same budget, and a count would let the
    /// first one evict the other fifty.
    func trim(to limit: Int64) {
        var total = totalBytes()
        guard total > limit else { return }
        for entry in entries() where total > limit {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}

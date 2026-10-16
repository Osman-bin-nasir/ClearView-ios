import SwiftUI
import CryptoKit
import ImageIO

/// The app's image loader: a memory cache, a **disk** cache, dedupe and downsampling.
///
/// Android has had all four in `GoodPostImages` since the Good Post tab was built, and its
/// reasoning is worth repeating because every line here answers the same requirement rather
/// than a preference:
///
///  * **Nothing is decoded at full resolution.** A 4000px photo drawn into a 240pt bubble
///    allocates tens of megabytes for a few hundred pixels on screen, and a feed that does
///    that drops frames and then gets killed. The bytes are read through `ImageIO`, which
///    decodes straight to a size a screen can show.
///  * **Nothing is fetched twice in a session.** One memory cache keyed by URL, so scrolling
///    back up a channel reuses the decoded image instead of downloading it again.
///  * **Nothing is fetched twice ACROSS sessions.** That was the missing half on iOS: the
///    memory cache dies with the process, and `AsyncImage` leans on `URLCache`, whose keys
///    are whole URLs. Good Post media URLs are **signed** — the credential and the expiry are
///    query parameters that change on every read — so a cache keyed on the whole URL missed
///    every time, and a channel re-downloaded every picture on every cold open. Bytes now
///    land in `Caches` keyed by the object's own identity, which is what makes re-opening a
///    channel instant and what makes the tab open with pictures and no network.
///
/// The disk key is the URL's **host and path**, never the query. The query is a credential;
/// the path is the object key. Keying on the whole URL would mean a cache that never hits
/// after the first minute and a directory holding the same photo forty times.
///
/// Access is on the main actor because the callers are views; the decode, the disk read and
/// the disk write all happen off it, so nothing here blocks a frame.
@MainActor
final class RemoteImageCache {

    static let shared = RemoteImageCache()

    /// A decoded image this large is a full-screen photograph held with room to spare.
    static let maxPixelSize = 1_400

    /// Bounds the memory cache by decoded size, not by count: 200 small avatars and 200
    /// photographs are not the same amount of memory.
    private static let memoryLimitBytes = 48 * 1024 * 1024

    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = memoryLimitBytes
        return cache
    }()

    /// Loads already in flight, so ten avatar rows asking for one picture make one request.
    private var loading: [String: Task<UIImage?, Never>] = [:]
    private var didTrim = false
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    // MARK: - Reading

    /// What is already on this device, with no request at all.
    ///
    /// The synchronous half of the cache, for a view that would rather draw a picture it has
    /// than a placeholder while it asks. The memory cache only: a disk read on the main actor
    /// is exactly the stall this class exists to avoid.
    func peek(_ url: String?) -> UIImage? {
        guard let parsed = Self.parse(url) else { return nil }
        return memory.object(forKey: Self.key(for: parsed) as NSString)
    }

    /// The image for a URL: memory, then disk, then the network.
    func image(for url: String?) async -> UIImage? {
        guard let parsed = Self.parse(url) else { return nil }
        let key = Self.key(for: parsed)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let existing = loading[key] { return await existing.value }

        let session = self.session
        let task = Task<UIImage?, Never>.detached(priority: .utility) {
            if let disk = Self.readDisk(key: key) {
                await RemoteImageCache.shared.store(disk, key: key)
                return disk
            }
            guard let data = await Self.download(parsed, session: session),
                  let image = Self.decode(data) else { return nil }
            Self.writeDisk(key: key, data: data)
            await RemoteImageCache.shared.store(image, key: key)
            return image
        }
        loading[key] = task
        let image = await task.value
        loading[key] = nil
        return image
    }

    /// Fetches a bounded list of images into the caches, a few at a time.
    ///
    /// The caller is a screen that is about to show these pictures, so the point is that the
    /// reader scrolls into images that are already decoded rather than watching them arrive.
    /// The bound matters as much as the fetch: a prefetch that opens thirty connections to
    /// the bucket competes with the images the reader is actually looking at, and — because
    /// these URLs are signed and share a bucket — it is a burst the bucket can throttle.
    func prefetch(_ urls: [String], maxPixelSize: Int = 1_400, limit: Int = 24, concurrency: Int = 4) async {
        var wanted: [URL] = []
        for raw in urls.prefix(limit * 2) {
            guard let parsed = Self.parse(raw) else { continue }
            let key = Self.key(for: parsed)
            if memory.object(forKey: key as NSString) != nil { continue }
            if loading[key] != nil { continue }
            if wanted.contains(parsed) { continue }
            wanted.append(parsed)
            if wanted.count >= limit { break }
        }
        guard !wanted.isEmpty else { return }

        let session = self.session
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            for _ in 0..<min(concurrency, wanted.count) {
                let url = wanted[next]
                next += 1
                group.addTask { await Self.warm(url, session: session, maxPixelSize: maxPixelSize) }
            }
            while await group.next() != nil {
                guard next < wanted.count else { continue }
                let url = wanted[next]
                next += 1
                group.addTask { await Self.warm(url, session: session, maxPixelSize: maxPixelSize) }
            }
        }
        trimIfNeeded()
    }

    /// One prefetch unit: reuse the disk, fetch and store what is missing.
    nonisolated private static func warm(_ url: URL, session: URLSession, maxPixelSize: Int) async {
        let key = key(for: url)
        if readDisk(key: key) != nil { return }
        guard let data = await download(url, session: session),
              let image = decode(data, maxPixelSize: maxPixelSize) else { return }
        writeDisk(key: key, data: data)
        await RemoteImageCache.shared.store(image, key: key)
    }

    /// How much of the disk cache one URL occupies — 0 when it is not stored.
    ///
    /// The Media menu asks this to tell "Downloaded" from "Download", so it has to answer for
    /// a URL without touching the network.
    nonisolated func diskBytes(for url: String?) -> Int64 {
        guard let parsed = RemoteImageCache.parse(url) else { return 0 }
        let file = ImageDiskStore.fileURL(key: RemoteImageCache.key(for: parsed))
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    /// Forgets one URL's bytes — the reader asked for the picture to go.
    func forget(_ urls: [String]) {
        for raw in urls {
            guard let parsed = Self.parse(raw) else { continue }
            let key = Self.key(for: parsed)
            memory.removeObject(forKey: key as NSString)
            try? FileManager.default.removeItem(at: ImageDiskStore.fileURL(key: key))
        }
    }

    // MARK: - Internals

    fileprivate func store(_ image: UIImage, key: String) {
        memory.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
    }

    /// Reads a cached file, honouring the TTL.
    ///
    /// An expired file is deleted rather than returned: the caller then fetches, which is what
    /// "expired" is supposed to mean, and the directory does not keep bytes nothing will ever
    /// read again.
    nonisolated static func readDisk(key: String) -> UIImage? {
        let file = ImageDiskStore.fileURL(key: key)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        if Date().timeIntervalSince(modified) > ImageDiskStore.ttl {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        return decode(data)
    }

    nonisolated static func writeDisk(key: String, data: Data) {
        try? FileManager.default.createDirectory(at: ImageDiskStore.directory(), withIntermediateDirectories: true)
        try? data.write(to: ImageDiskStore.fileURL(key: key), options: .atomic)
    }

    /// The bytes for a URL, refusing only what can never be a picture.
    ///
    /// `video` and `audio` are refused rather than "only `image` is accepted": a bucket that
    /// serves a photograph as `application/octet-stream` is serving a photograph, and a missing
    /// or parameterised type means "try it" — which is what this did before it could tell. The
    /// check only rejects what the decoder has no answer for at all, and the cost of asking is
    /// the whole file.
    nonisolated private static func download(_ url: URL, session: URLSession) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            MediaLog.feeds.error("image: HTTP \(http.statusCode, privacy: .public) for \(url.host() ?? "-", privacy: .public)")
            return nil
        }
        let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        let family = type?.split(separator: ";").first?.split(separator: "/").first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        if family == "video" || family == "audio" { return nil }
        return data
    }

    /// Decodes straight to a size a screen can use.
    ///
    /// `ImageIO` is asked for a thumbnail rather than decoding the file and shrinking it
    /// afterwards, which is the difference between allocating the full photograph and
    /// allocating the pixels that are drawn.
    nonisolated private static func decode(_ data: Data, maxPixelSize: Int = 1_400) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Trims the directory once per launch, expired files first and then the oldest.
    ///
    /// Once per process rather than before every write: the check is a directory walk, and
    /// paying for it on each downloaded picture would cost more than the bytes it saves.
    func trimIfNeeded() {
        guard !didTrim else { return }
        didTrim = true
        let limit = ImageDiskStore.limitBytes
        let ttl = ImageDiskStore.ttl
        let directory = ImageDiskStore.directory()
        Task.detached(priority: .utility) {
            let manager = FileManager.default
            guard let entries = try? manager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { return }
            var files: [(url: URL, date: Date, size: Int64)] = []
            var total: Int64 = 0
            for entry in entries {
                guard let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
                let size = Int64(values.fileSize ?? 0)
                total += size
                files.append((entry, values.contentModificationDate ?? .distantPast, size))
            }
            guard total > limit else { return }
            let cutoff = Date().addingTimeInterval(-ttl)
            for file in files where file.date < cutoff {
                try? manager.removeItem(at: file.url)
                total -= file.size
            }
            for file in files.sorted(by: { $0.date < $1.date }) where total > limit {
                try? manager.removeItem(at: file.url)
                total -= file.size
            }
        }
    }

    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// The cache key for a URL: the host and the path, never the query.
    nonisolated static func key(for url: URL) -> String {
        "\((url.host() ?? "").lowercased())\(url.path)"
    }

    /// Only an `http(s)` URL can be fetched — a `file:` preview or an empty string is simply
    /// not an image this cache can answer for.
    nonisolated static func parse(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty, let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Gives the whole app a disk cache worth the name.
    ///
    /// `URLCache.shared` starts at a few megabytes on disk, which is a cache that evicts the
    /// pictures of the screen the reader just left. Anything that goes through `URLSession` —
    /// this loader's own responses and every other GET in the app — shares this budget.
    static func installSharedCache() {
        URLCache.shared = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024,
            directory: nil
        )
    }
}

/// The on-disk half of the image cache.
///
/// Its own type, and outside the main actor, because the loaders that read and write it run off
/// the main actor: a disk read and an `ImageIO` decode on the thread that draws would be the
/// stall this whole file exists to avoid.
enum ImageDiskStore {

    /// How long a downloaded image may be reused before it is fetched again.
    static let ttl: TimeInterval = 7 * 24 * 60 * 60

    /// What the directory may occupy before the oldest entries go.
    static let limitBytes: Int64 = 80 * 1024 * 1024

    static func directory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("clearview-images", isDirectory: true)
    }

    /// The file for a cache key: a digest of the key, so no URL can escape the directory or
    /// collide with another URL's name.
    static func fileURL(key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory().appendingPathComponent(digest)
    }
}

/// An image from a URL, drawn from the disk cache when it is there.
///
/// The replacement for `AsyncImage` in this app: the same shape, but a picture that was
/// fetched once is still there on the next launch, and showing it involves no network at all.
struct RemoteImage: View {
    let url: String?
    var contentMode: ContentMode
    var maxPixelSize: Int
    /// Drawn while there is nothing to draw yet. A row that has a colour, initials or a symbol
    /// to show passes one; a row that has nothing shows nothing rather than a spinner per cell.
    private let placeholder: AnyView?

    @State private var image: UIImage?

    init(url: String?, contentMode: ContentMode = .fill, maxPixelSize: Int = 1_400, placeholder: AnyView? = nil) {
        self.url = url
        self.contentMode = contentMode
        self.maxPixelSize = maxPixelSize
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder ?? AnyView(Color.clear)
            }
        }
        .task(id: url) {
            if image == nil { image = RemoteImageCache.shared.peek(url) }
            guard image == nil else { return }
            image = await RemoteImageCache.shared.image(for: url)
        }
    }
}

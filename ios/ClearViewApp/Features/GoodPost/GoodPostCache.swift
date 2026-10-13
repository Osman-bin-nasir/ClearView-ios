import Foundation

/// A cached list plus the time it was stored.
///
/// The timestamp is kept so the UI can label saved content as saved rather than live. Age is
/// deliberately **not** used to expire anything: previously fetched channels and posts staying
/// readable offline is the requirement, and a channel name does not become wrong by being a day
/// old.
struct CachedChannels: Equatable {
    let channels: [GoodPostChannel]
    let savedAtMs: Int64
}

/// A cached post list for one channel.
struct CachedPosts: Equatable {
    let posts: [GoodPostPost]
    let savedAtMs: Int64
}

/// A cached advertisement list for one placement.
struct CachedAds: Equatable {
    let ads: [GoodPostAd]
    let savedAtMs: Int64
}

/// The cached external channel directory, and when it was stored.
struct CachedDirectory: Equatable {
    let snapshot: DirectorySnapshot
    let savedAtMs: Int64
}

/// Offline cache for Good Post.
///
/// `UserDefaults` + JSON strings, matching how the rest of the iOS app persists things — no
/// database, no per-feature store, no dependency.
///
/// What is cached is what a reader needs to see the tab open instantly: the channel list, the
/// categories, the advertisement cards, and the posts of channels they have already opened.
/// Signed media URLs are **not** cached — see `GoodPostCodec.encodePosts` — so a cached post
/// renders its text and an honest placeholder rather than a broken image.
///
/// Sizes are capped because these entries are written from server-provided text: without a cap,
/// paging would append forever, and an unbounded defaults value is read into memory on every
/// access.
///
/// Every key this type writes shares the `goodpost.` prefix, and `clear()` removes exactly those
/// keys. That is a deliberate improvement on the Android store, which clears two whole preference
/// files: here a sign-out cannot take the hidden posts, the stars or the counted views with it,
/// because those are a reader's own records rather than the administrator's working set.
struct GoodPostCache {

    /// Enough to browse offline; small enough to stay off the heap.
    static let maxChannels = 200
    static let maxPostsPerChannel = 60
    static let maxAds = 10
    /// The manager list is small and worth keeping whole.
    static let maxAdminAds = 60

    /// How long a saved channel list is trusted before the tab refetches it.
    ///
    /// This is the fix for "every time I open Good Post it fetches the channels": a re-open within
    /// the window renders from disk and makes **no** request at all. It is a freshness window, not
    /// an expiry — a list older than this is still shown, and is still shown offline; it is only
    /// refetched in the background.
    static let channelsTtlMs: Int64 = 15 * 60 * 1000

    /// A long-lived window for the reader's own channel list.
    ///
    /// Follows and their ids are pure device state — the ids change only when the reader follows
    /// or unfollows something, which the repository is told about directly — so the identity of the
    /// list does not go stale the way its contents do.
    static let followedTtlMs: Int64 = 24 * 60 * 60 * 1000

    enum Key {
        static let prefix = "goodpost."
        static let channels = prefix + "channels"
        static let followedChannels = prefix + "followed_channels"
        static let followedIds = prefix + "followed_ids"
        static let categories = prefix + "categories"
        static let directory = prefix + "directory"
        static let adminAds = prefix + "admin_ads"
        static let savedAtSuffix = ".saved_at"
        static let postsPrefix = prefix + "posts."
        static let adsPrefix = prefix + "ads."
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Channels

    func saveChannels(_ channels: [GoodPostChannel], nowMs: Int64) {
        defaults.set(GoodPostCodec.encodeChannels(Array(channels.prefix(Self.maxChannels))), forKey: Key.channels)
        defaults.set(nowMs, forKey: Key.channels + Key.savedAtSuffix)
    }

    func loadChannels() -> CachedChannels? {
        let decoded = GoodPostCodec.decodeChannels(defaults.string(forKey: Key.channels))
        guard !decoded.isEmpty else { return nil }
        return CachedChannels(channels: decoded, savedAtMs: savedAt(defaults, Key.channels))
    }

    /// True while the saved channel list is fresh enough to skip a refetch.
    func channelsAreFresh(nowMs: Int64) -> Bool {
        isFresh(defaults, Key.channels, nowMs: nowMs, ttl: Self.channelsTtlMs)
    }

    // MARK: - The reader's own channel list (follows)
    //
    // Kept under its own key on purpose. `loadChannels` is the PUBLIC catalogue — the fallback
    // list, cached only on an unfiltered first page — and it is saved by a different call. Writing
    // the reader's follows over it is what left a cold start showing the wrong list.

    func saveFollowedChannels(_ channels: [GoodPostChannel], nowMs: Int64) {
        defaults.set(
            GoodPostCodec.encodeChannels(Array(channels.prefix(Self.maxChannels))),
            forKey: Key.followedChannels
        )
        defaults.set(nowMs, forKey: Key.followedChannels + Key.savedAtSuffix)
    }

    func loadFollowedChannels() -> CachedChannels? {
        let decoded = GoodPostCodec.decodeChannels(defaults.string(forKey: Key.followedChannels))
        guard !decoded.isEmpty else { return nil }
        return CachedChannels(channels: decoded, savedAtMs: savedAt(defaults, Key.followedChannels))
    }

    func followedChannelsAreFresh(nowMs: Int64) -> Bool {
        isFresh(defaults, Key.followedChannels, nowMs: nowMs, ttl: Self.followedTtlMs)
    }

    /// Remembers which channels this reader follows, so a cold start can restore the follow
    /// switches before the server answers.
    func saveFollowedIds(_ ids: Set<String>) {
        defaults.set(Array(ids), forKey: Key.followedIds)
    }

    func loadFollowedIds() -> Set<String> {
        Set(defaults.stringArray(forKey: Key.followedIds) ?? [])
    }

    // MARK: - Posts

    func savePosts(channelId: String, posts: [GoodPostPost], nowMs: Int64) {
        let key = Key.postsPrefix + channelId
        defaults.set(GoodPostCodec.encodePosts(Array(posts.prefix(Self.maxPostsPerChannel))), forKey: key)
        defaults.set(nowMs, forKey: key + Key.savedAtSuffix)
    }

    func loadPosts(channelId: String) -> CachedPosts? {
        let key = Key.postsPrefix + channelId
        let decoded = GoodPostCodec.decodePosts(defaults.string(forKey: key))
        guard !decoded.isEmpty else { return nil }
        return CachedPosts(posts: decoded, savedAtMs: saved(defaults, key))
    }

    // MARK: - Advertisements

    /// Caches the active cards for one placement.
    ///
    /// Keyed by placement, not shared: a card can run on Channels, on Explore, or on both, and one
    /// entry would show a reader the other surface's card.
    func saveAds(_ placement: GoodPostAdPlacement, ads: [GoodPostAd], nowMs: Int64) {
        let key = Key.adsPrefix + placement.wire
        defaults.set(GoodPostCodec.encodeAds(Array(ads.prefix(Self.maxAds))), forKey: key)
        defaults.set(nowMs, forKey: key + Key.savedAtSuffix)
    }

    /// The cached cards for one placement, already filtered by the clock.
    ///
    /// Filtered **here** rather than by the caller because a cached card is the one kind of content
    /// whose validity can end while it sits on disk. The server applies this rule to a live read; a
    /// card that expired since it was saved would otherwise outlive its own campaign.
    func loadAds(_ placement: GoodPostAdPlacement, nowMs: Int64) -> CachedAds? {
        let key = Key.adsPrefix + placement.wire
        let decoded = GoodPostCodec.decodeAds(defaults.string(forKey: key))
        guard !decoded.isEmpty else { return nil }
        let active = decoded.filter { $0.isActive(at: nowMs) }
        guard !active.isEmpty else { return nil }
        return CachedAds(ads: active, savedAtMs: saved(defaults, key))
    }

    /// Caches the administrator's whole card list, active or not.
    ///
    /// The manager screen was the one place that waited on the network every time it opened, which
    /// is what made it feel slow: the cards are the same few rows on every visit, and a list that
    /// has not changed should not be re-fetched to be drawn.
    func saveAdminAds(_ ads: [GoodPostAd], nowMs: Int64) {
        defaults.set(GoodPostCodec.encodeAds(Array(ads.prefix(Self.maxAdminAds))), forKey: Key.adminAds)
        defaults.set(nowMs, forKey: Key.adminAds + Key.savedAtSuffix)
    }

    /// The cached card list, unfiltered by the clock.
    func loadAdminAds() -> CachedAds? {
        let decoded = GoodPostCodec.decodeAds(defaults.string(forKey: Key.adminAds))
        guard !decoded.isEmpty else { return nil }
        return CachedAds(ads: decoded, savedAtMs: saved(defaults, Key.adminAds))
    }

    // MARK: - The external channel directory

    /// Caches the whole directory.
    ///
    /// Written on every successful read, including a reader-triggered refresh, so the next open is
    /// instant and the screen works offline. Age is not used to expire it — the server list changes
    /// rarely, and stale-but-readable beats an empty screen.
    func saveDirectory(_ snapshot: DirectorySnapshot, nowMs: Int64) {
        defaults.set(DirectoryCodec.encode(snapshot), forKey: Key.directory)
        defaults.set(nowMs, forKey: Key.directory + Key.savedAtSuffix)
    }

    func loadDirectory() -> CachedDirectory? {
        guard let snapshot = DirectoryCodec.decode(defaults.string(forKey: Key.directory)),
              !snapshot.isEmpty else {
            return nil
        }
        return CachedDirectory(snapshot: snapshot, savedAtMs: saved(defaults, Key.directory))
    }

    // MARK: - Categories

    func saveCategories(_ categories: [GoodPostCategory]) {
        defaults.set(GoodPostCodec.encodeCategories(categories), forKey: Key.categories)
    }

    func loadCategories() -> [GoodPostCategory] {
        GoodPostCodec.decodeCategories(defaults.string(forKey: Key.categories))
    }

    // MARK: - Forgetting

    /// Forgets everything **this cache** wrote, and nothing else.
    ///
    /// Called when an administrator signs out: the cached list is also the administrator's working
    /// set, and a fresh sign-in should not start from someone else's screen. The hidden posts, the
    /// stars and the counted views are a reader's own records and are deliberately left alone, as is
    /// the reader's identity.
    func clear() {
        let keys = defaults.dictionaryRepresentation().keys
        for key in keys where key.hasPrefix(Key.prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Internals

    private func saved(_ defaults: UserDefaults, _ key: String) -> Int64 {
        Int64(defaults.object(forKey: key + Key.savedAtSuffix) as? NSNumber ?? 0)
    }

    private func isFresh(_ defaults: UserDefaults, _ key: String, nowMs: Int64, ttl: Int64) -> Bool {
        let savedAt = saved(defaults, key)
        guard savedAt > 0 else { return false }
        return nowMs - savedAt < ttl
    }
}

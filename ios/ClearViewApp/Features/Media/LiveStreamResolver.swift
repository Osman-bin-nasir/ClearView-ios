import Foundation

/// Persists each stream's LAST successfully resolved live video id, separately
/// per official channel, so the resolver's last-known fallback survives app
/// restarts and the reader never needs an app update when a new broadcast
/// starts.
///
/// Values are keyed by the OFFICIAL CHANNEL ID — Makkah and Madinah can never
/// share an id. The id is only ever written from that channel's own successful
/// resolution, and the resolver ALWAYS re-validates the stored id (still live,
/// correct channel, playable) before playing it — never blindly.
///
/// Uses its own `UserDefaults` suite, matching Android's separate
/// `live_stream_cache` preferences file, so clearing another feature's cache can
/// never drop the last-known broadcast. Ported from Android's
/// `LiveStreamCacheStore`.
final class LiveStreamCacheStore {

    /// The app-wide store, on its own suite.
    static let standard = LiveStreamCacheStore()

    private static let suiteName = "live_stream_cache"
    private static let videoKeyPrefix = "last_video_"
    private static let atKeyPrefix = "last_at_"
    private static let videoIdLength = 11

    private let defaults: UserDefaults

    /// - Parameter defaults: injectable so tests can use their own suite.
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.suiteName) ?? .standard
    }

    /// Last successfully resolved live video id for `channelId`, or nil.
    func lastVideoId(channelId: String) -> String? {
        guard let stored = defaults.string(forKey: Self.videoKeyPrefix + channelId),
              stored.count == Self.videoIdLength else { return nil }
        return stored
    }

    /// When that resolution happened, or nil when nothing is stored.
    func lastResolvedAt(channelId: String) -> Date? {
        let millis = defaults.double(forKey: Self.atKeyPrefix + channelId)
        return millis > 0 ? Date(timeIntervalSince1970: millis / 1000) : nil
    }

    /// Records a successful resolution (replacing any older id).
    func rememberResolved(channelId: String, videoId: String, now: Date = Date()) {
        defaults.set(videoId, forKey: Self.videoKeyPrefix + channelId)
        defaults.set(now.timeIntervalSince1970 * 1000, forKey: Self.atKeyPrefix + channelId)
    }
}

/// Result of a resolution attempt.
///
/// `videoId` is non-nil ONLY when a candidate passed full validation. When it is
/// nil and `blockedByFilter` is true, the page YouTube served matched the
/// Restricted-Mode / DNS-filter signature — retrying will not help until the
/// filter exempts YouTube.
struct LiveResolveResult: Equatable {
    let videoId: String?
    let blockedByFilter: Bool

    static let unavailable = LiveResolveResult(videoId: nil, blockedByFilter: false)
    static let filterBlocked = LiveResolveResult(videoId: nil, blockedByFilter: true)
}

/// Resolves a live-stream SOURCE's (Makkah / Madinah) CURRENT live broadcast
/// video id, so Haramayn Live can play it with the same in-app YouTube embed as
/// regular videos. Discovery is kept strictly separate from playback: this type
/// only ever produces a validated video id; the player never scrapes.
///
/// The OFFICIAL YouTube channel is the stable identity. The airing broadcast's
/// video id changes over time, but the channel id never does, so
/// ``LiveStreamConfig`` stores ONLY channel identifiers and the current
/// broadcast is DISCOVERED here at runtime. No video id is hardcoded — a new
/// broadcast never requires an app update.
///
/// Ported from Android's `LiveStreamResolver`, tier for tier, so both platforms
/// accept and reject exactly the same pages.
///
/// DISCOVERY (per source, strongest first):
///
///  1. The channel's `/live` page — player-response LIVE MARKERS
///     (`isLive` / `isLiveNow` / `liveStreamability`). Fastest path.
///  2. The same page's `<link rel="canonical">`. On a `/live` URL the canonical
///     always names the broadcast (`…/watch?v=<id>`); on a channel page it names
///     the channel (no id → not live). This SEO tag survives the reduced page
///     variants that strip the player response.
///  3. The FIRST videoId anywhere in the `/live` document. Reduced variants embed
///     the airing broadcast's id as the page's first videoId even when the player
///     response is an empty stub and there is no canonical. Gated on the page
///     presenting a player response so a channel-home redirect (no broadcast) can
///     never feed a featured VOD in here.
///  4. The channel's `/streams` page: the first video id it presents. That page
///     only lists the channel's own videos, so channel ownership is implied;
///     liveness is still validated on the `/watch` page.
///  5. LAST KNOWN: the per-channel persisted id from ``LiveStreamCacheStore``,
///     only when every method above failed. NEVER played blind: it is
///     re-validated on its `/watch` page first. When a new broadcast starts, a
///     successful resolution replaces the stored id automatically.
///
/// VALIDATION (mandatory for every accepted candidate, including the cached
/// one): the candidate's `/watch` page must confirm it is CURRENTLY LIVE (live
/// markers in the player response), the candidate IS that page's own video, it
/// belongs to the EXPECTED OFFICIAL channel (Makkah can never accept a Madinah id
/// or vice versa; no cross-channel substitution, ever), and it is PLAYABLE
/// (`playabilityStatus` OK).
///
/// PAGE VARIANTS & RESTRICTED MODE: YouTube serves different HTML for the same
/// URL depending on network/IP/region/cookies. DNS filters such as CleanBrowsing
/// Family Filter additionally force YouTube Restricted Mode by mapping
/// www.youtube.com to Google's restricted-mode IPs — Restricted Mode suppresses
/// live streams SERVER-SIDE (the `/live` page returns a player response whose
/// `playabilityStatus` is ERROR, with no live markers and no canonical).
/// ``looksRestrictedMode(_:)`` detects that signature and reports
/// ``LiveResolveResult/blockedByFilter`` so the UI can explain the real cause. It
/// cannot be fixed purely in code (the embed player cannot bypass system DNS),
/// but detection makes the failure obvious and actionable.
///
/// A DESKTOP user agent is required: a mobile UA makes YouTube serve a reduced
/// page without the live player response, which would be misread as "not live".
/// Those patterns live in ``LiveStreamPage``, which holds all the page reading so
/// the whole accept/reject policy is unit-testable without a network.
@MainActor
final class LiveStreamResolver {

    /// Shared resolver, so the short-lived resolution cache is app-wide.
    static let shared = LiveStreamResolver()

    /// How long a successful resolution is reused before the pages are read
    /// again. Short on purpose: a broadcast can end at any moment, and the UI
    /// re-resolves on every retry (`force: true`).
    static let cacheTTL: TimeInterval = 60

    private static let desktopUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

    private var cache: [String: (videoId: String, at: Date)] = [:]
    private let store: LiveStreamCacheStore
    private let session: URLSession

    init(store: LiveStreamCacheStore = .standard, session: URLSession? = nil) {
        self.store = store
        self.session = session ?? Self.makeSession()
    }

    /// An ephemeral session with NO cookies and no on-disk cache: the resolver
    /// reads public pages and must never inherit (or write) the reader's YouTube
    /// session, and a cached page would hide a broadcast that has just started.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpAdditionalHeaders = [
            "Accept": "text/html",
            "Accept-Language": "en-US,en;q=0.9",
            // Ask only for encodings URLSession decodes itself: letting YouTube
            // answer with brotli is how a page arrives as undecodable bytes.
            "Accept-Encoding": "gzip, deflate",
            "User-Agent": desktopUserAgent,
        ]
        return URLSession(configuration: configuration)
    }

    // MARK: - Resolution

    /// Resolves `source`'s current live broadcast video id (validated), or an
    /// unavailable/filter-blocked result when no broadcast is airing or the pages
    /// cannot be read. `force` bypasses the short-lived cache (used by retry).
    func resolve(_ source: LiveStreamSource, force: Bool = false) async -> LiveResolveResult {
        let channelId = source.channelId
        if !force, let cached = cache[channelId], Date().timeIntervalSince(cached.at) < Self.cacheTTL {
            MediaLog.live.debug("LIVE_CACHE_HIT channelId=\(channelId, privacy: .public) videoId=\(cached.videoId, privacy: .public)")
            return LiveResolveResult(videoId: cached.videoId, blockedByFilter: false)
        }

        guard let liveHtml = await fetch("https://www.youtube.com/channel/\(channelId)/live") else {
            MediaLog.live.warning("LIVE_FETCH_NULL channelId=\(channelId, privacy: .public)")
            return .unavailable
        }

        // The Restricted-Mode / DNS-filter signature is computed on the page
        // already fetched: tiers 1–2 can still succeed on an odd-but-unfiltered
        // page, and once they fail this decides "explain, don't retry".
        let filtered = LiveStreamPage.looksRestrictedMode(liveHtml)

        // Tier 1: player-response live markers.
        if let candidate = LiveStreamPage.extractLiveVideoId(liveHtml), await confirm(candidate, channelId: channelId) {
            return accept(channelId: channelId, videoId: candidate, tag: "LIVE_RESOLVED")
        }

        // Tier 2: canonical watch link.
        if let candidate = LiveStreamPage.canonicalVideoId(liveHtml), await confirm(candidate, channelId: channelId) {
            return accept(channelId: channelId, videoId: candidate, tag: "LIVE_RESOLVED_VIA_CANONICAL")
        }

        if filtered {
            MediaLog.live.warning("LIVE_BLOCKED_BY_FILTER channelId=\(channelId, privacy: .public) (Restricted Mode signature)")
            return .filterBlocked
        }

        // Tier 3: first videoId in the whole document (reduced variants).
        if liveHtml.contains("ytInitialPlayerResponse"),
           let candidate = LiveStreamPage.firstVideoIdInDocument(liveHtml),
           await confirm(candidate, channelId: channelId) {
            return accept(channelId: channelId, videoId: candidate, tag: "LIVE_RESOLVED_VIA_PAGE_ID")
        }

        // Tier 4: the channel's /streams page.
        if let streamsHtml = await fetch("https://www.youtube.com/channel/\(channelId)/streams"),
           let candidate = LiveStreamPage.firstVideoIdInDocument(streamsHtml),
           await confirm(candidate, channelId: channelId) {
            return accept(channelId: channelId, videoId: candidate, tag: "LIVE_RESOLVED_VIA_STREAMS")
        }

        // Tier 5: the persisted last-known id, re-validated — never played blind.
        if let known = store.lastVideoId(channelId: channelId) {
            if await confirm(known, channelId: channelId) {
                return accept(channelId: channelId, videoId: known, tag: "LIVE_RESOLVED_VIA_CACHED")
            }
            MediaLog.live.warning("LIVE_CACHED_STALE channelId=\(channelId, privacy: .public) videoId=\(known, privacy: .public)")
        }

        MediaLog.live.warning("LIVE_NOT_ACTIVE channelId=\(channelId, privacy: .public) (no validated live broadcast)")
        return .unavailable
    }

    /// Reads the candidate's `/watch` page and runs full validation.
    private func confirm(_ candidate: String, channelId: String) async -> Bool {
        guard let watchHtml = await fetch("https://www.youtube.com/watch?v=\(candidate)") else { return false }
        return LiveStreamPage.validateWatchPage(watchHtml, videoId: candidate, expectedChannelId: channelId)
    }

    /// Persists a validated resolution (per channel) and caches it in memory.
    private func accept(channelId: String, videoId: String, tag: String) -> LiveResolveResult {
        store.rememberResolved(channelId: channelId, videoId: videoId)
        cache[channelId] = (videoId, Date())
        MediaLog.live.debug("\(tag, privacy: .public) channelId=\(channelId, privacy: .public) videoId=\(videoId, privacy: .public)")
        return LiveResolveResult(videoId: videoId, blockedByFilter: false)
    }

    private func fetch(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let started = Date()
        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                MediaLog.live.warning("LIVE_FETCH_STATUS url=\(urlString, privacy: .public) status=\(status, privacy: .public)")
                return nil
            }
            // YouTube serves UTF-8; the latin-1 fallback keeps a mis-declared page
            // readable rather than throwing the whole fetch away.
            guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                MediaLog.live.warning("LIVE_FETCH_UNDECODABLE url=\(urlString, privacy: .public) bytes=\(data.count, privacy: .public)")
                return nil
            }
            MediaLog.live.debug("LIVE_FETCH_OK url=\(urlString, privacy: .public) bytes=\(data.count, privacy: .public) ms=\(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)")
            return html
        } catch {
            MediaLog.live.warning("LIVE_FETCH_FAILED url=\(urlString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Reading YouTube's live pages: every rule that decides whether a candidate is
/// the right broadcast, as pure functions of page text.
///
/// This is deliberately a separate, actor-free namespace — the same "parsing is
/// separate from fetching" split Android uses, so the whole accept/reject policy
/// can be unit-tested against captured pages with no network and no player.
enum LiveStreamPage {

    // MARK: - Patterns

    private static let videoIdPattern = "\"videoId\"\\s*:\\s*\"([0-9A-Za-z_-]{11})\""
    private static let isLivePattern = "\"isLive\"\\s*:\\s*true|\"isLiveNow\"\\s*:\\s*true"

    /// Structural live markers accepted inside the player response block.
    /// `liveStreamability` is the live-playback config YouTube MUST emit to start a
    /// live stream — it survives reduced variants that drop the `isLive` flag.
    /// `isLiveNow:true` rejects upcoming broadcasts (they carry
    /// `liveBroadcastDetails` with `isLiveNow:false`).
    private static let liveMarkerPatterns = [
        "\"isLive\"\\s*:\\s*true",
        "\"isLiveNow\"\\s*:\\s*true",
        "\"liveStreamability\"",
    ]

    /// The page's canonical link — plain HTML in the `<head>`, so it survives the
    /// reduced variants. `www.` and `m.` subdomains are both possible, and the tag
    /// appears with the slashes escaped in some server-rendered variants.
    private static let canonicalWatchPattern =
        "<link[^>]*rel=\"canonical\"[^>]*href=\"https://(?:www\\.|m\\.)?youtube\\.com/watch\\?v=([0-9A-Za-z_-]{11})\""
    private static let canonicalWatchEscapedPattern =
        "rel=\"canonical\"[^>]*href=\"https:\\\\/\\\\/(?:www\\.|m\\.)?youtube\\.com\\\\/watch\\?v=([0-9A-Za-z_-]{11})\""

    /// `playabilityStatus.status` inside the player response: `"OK"` is playable;
    /// any other value is blocked/unavailable — the Restricted-Mode signature.
    private static let playabilityStatusPattern =
        "\"playabilityStatus\"\\s*:\\s*\\{[^}]*?\"status\"\\s*:\\s*\"([A-Z_]+)\""

    /// Ownership signals inside the player response block. `ownerChannelId`
    /// (microformat) is the explicit uploader; the block's first `channelId`
    /// (`videoDetails.channelId`) is the same channel.
    private static let ownerChannelPattern = "\"ownerChannelId\"\\s*:\\s*\"(UC[0-9A-Za-z_-]{22})\""
    private static let channelIdPattern = "\"channelId\"\\s*:\\s*\"(UC[0-9A-Za-z_-]{22})\""

    // MARK: - Validation

    /// MANDATORY validation for a candidate, run on its `/watch` page:
    ///
    ///  1. CURRENTLY LIVE — the player response carries live markers AND its own
    ///     videoId names the candidate (a watch page's player response always names
    ///     the video itself; a VOD never carries live markers).
    ///  2. PLAYABLE — `playabilityStatus`, when present, must be `"OK"` (a non-OK
    ///     status is exactly what Restricted Mode / geo-blocks serve).
    ///  3. OWNERSHIP — the owner channelId, when determinable, must be the EXPECTED
    ///     official channel. This is what makes cross-channel substitution
    ///     impossible: Makkah can never accept a Madinah id and vice versa.
    static func validateWatchPage(_ watchHtml: String, videoId: String, expectedChannelId: String) -> Bool {
        guard extractLiveVideoId(watchHtml) == videoId else { return false }
        if let status = playabilityStatus(watchHtml), status != "OK" { return false }
        guard let owner = ownerChannelId(watchHtml) else { return true }
        return owner == expectedChannelId
    }

    /// True when the page matches the Restricted-Mode / DNS-filter signature: a
    /// player response IS present, the video is NOT playable (the EXACT
    /// `playabilityStatus.status` `"ERROR"` that Restricted Mode serves), there are
    /// no live markers, and there is no canonical watch link. Restricting to the
    /// exact ERROR status keeps other non-playable states (LOGIN_REQUIRED, age/geo
    /// blocks) from being misreported as a DNS-filter block.
    static func looksRestrictedMode(_ html: String) -> Bool {
        guard html.contains("ytInitialPlayerResponse") else { return false }
        if matches(isLivePattern, in: html) || html.contains("liveStreamability") { return false }
        if canonicalVideoId(html) != nil { return false }
        return playabilityStatus(html) == "ERROR"
    }

    // MARK: - Extraction

    /// The `playabilityStatus` value inside the player response, or nil.
    static func playabilityStatus(_ html: String) -> String? {
        firstGroup(playabilityStatusPattern, in: playerResponseBlock(html))
    }

    /// The uploader channel id from the player response block, or nil.
    static func ownerChannelId(_ html: String) -> String? {
        let block = playerResponseBlock(html)
        return firstGroup(ownerChannelPattern, in: block) ?? firstGroup(channelIdPattern, in: block)
    }

    /// The live video id named by the page's canonical link, or nil.
    static func canonicalVideoId(_ html: String) -> String? {
        firstGroup(canonicalWatchPattern, in: html) ?? firstGroup(canonicalWatchEscapedPattern, in: html)
    }

    /// The first `videoId` anywhere in the document, or nil.
    static func firstVideoIdInDocument(_ html: String) -> String? {
        firstGroup(videoIdPattern, in: html)
    }

    /// The live video id from the player response block, but ONLY when the block
    /// carries a live marker (`isLive`/`isLiveNow` true, or `liveStreamability`).
    /// Those fields only exist in a LIVE player response; an upcoming broadcast has
    /// `isLiveNow:false` and never matches. The block's FIRST `videoId` is always
    /// `videoDetails.videoId` — the main video, never a related one.
    static func extractLiveVideoId(_ html: String) -> String? {
        let block = playerResponseBlock(html)
        guard liveMarkerPatterns.contains(where: { matches($0, in: block) }) else { return nil }
        return firstGroup(videoIdPattern, in: block)
    }

    /// The player-response slice of a page: from the `ytInitialPlayerResponse`
    /// marker to the end of that script block.
    ///
    /// With no marker the block is empty, which is the safe outcome — callers gate
    /// on live markers before trusting an id found in it.
    static func playerResponseBlock(_ html: String) -> String {
        guard let start = html.range(of: "ytInitialPlayerResponse") else { return "" }
        let rest = html[start.lowerBound...]
        guard let end = rest.range(of: "</script>") else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    // MARK: - Regex helpers

    /// Every capture group of the first match, or nil when there is no match.
    /// Matching is line-insensitive and dotall-free: a page's JSON is one
    /// enormous line, so `.` is never needed here.
    private static func groups(of pattern: String, in text: String) -> [String]? {
        guard !text.isEmpty, let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        guard let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<result.numberOfRanges).compactMap { index in
            Range(result.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    /// The first capture group of the first match, or nil.
    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        groups(of: pattern, in: text)?.first
    }

    /// True when the pattern matches anywhere — used for the marker patterns,
    /// which carry no capture group.
    private static func matches(_ pattern: String, in text: String) -> Bool {
        groups(of: pattern, in: text) != nil
    }
}

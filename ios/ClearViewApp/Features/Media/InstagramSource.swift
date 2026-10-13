import Foundation

/// What a profile fetch produced.
struct MediaFeedResult: Equatable {
    var username: String
    var displayName: String?
    var avatarURL: String?
    var items: [MediaVideo]
}

/// Why a profile fetch produced nothing.
///
/// Thrown rather than returned as an empty list on purpose: an empty Instagram
/// feed is otherwise indistinguishable from a profile that has posted nothing,
/// and the Media tab has to be able to say which one happened — the same reason
/// Android has a `MediaSourceStatusStore` at all.
enum MediaFeedError: LocalizedError, Equatable {
    case invalidHandle
    /// The service throttled this device's address.
    ///
    /// Deliberately NAMED FOR WHAT HAPPENED, NOT WHICH SERVICE. Both the
    /// Instagram and X sources raise this, and an earlier version hardcoded
    /// "Instagram is rate-limiting this device" — so an X profile that was
    /// throttled told the reader to blame Instagram. The platform is added by
    /// whoever knows it, when the message is shown.
    case rateLimited
    case http(Int)
    case noData
    /// The service answered, but the payload carried nothing usable.
    case unusablePayload

    var errorDescription: String? {
        switch self {
        case .invalidHandle:
            return "That doesn't look like a profile handle."
        case .rateLimited:
            return "This service is rate-limiting your device. Try again in a few minutes."
        case .http(let status):
            return "The feed returned HTTP \(status)."
        case .noData:
            return "No profile data was found for that handle."
        case .unusablePayload:
            return "The feed answered but its format could not be read."
        }
    }
}

/// Instagram's own `/<username>/embed/` page, read as JSON.
///
/// The login-free endpoint Instagram renders for profile iframes, and the only
/// Instagram provider still answering: `web_profile_info` returns 429, the public
/// RSS-Bridge Instagram bridge returns an empty feed, and the backend proxy points
/// at a retired tunnel (all measured on Android; the same endpoints are shared).
/// The embed page still carries the profile and its latest posts as embedded
/// JSON, which is exactly what the feed needs.
///
/// It exposes the newest handful of posts — the same rolling window the other
/// providers give.
struct InstagramSource {

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Instagram's profile-embed page is rendered for mobile Safari, so it is
    /// asked for as mobile Safari.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"

    /// A 429 here is per IP and applies to every profile, so once Instagram
    /// throttles the install the source stands down for a while instead of
    /// spending a request on every channel of every refresh.
    ///
    /// Static because it is a property of the *device's* address, not of any one
    /// source instance.
    private static var backoffUntil: Date = .distantPast
    private static let backoffInterval: TimeInterval = 10 * 60

    static func isRateLimited(now: Date = Date()) -> Bool { now < backoffUntil }

    func fetchProfile(_ handleOrURL: String) async throws -> MediaFeedResult {
        let username = handleOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
        guard !username.lowercased().hasPrefix("http"),
              InstagramProfileEmbedParser.isProfileName(username) else {
            throw MediaFeedError.invalidHandle
        }
        guard !Self.isRateLimited() else { throw MediaFeedError.rateLimited }

        var request = URLRequest(url: URL(string: "https://www.instagram.com/\(username)/embed/")!)
        request.timeoutInterval = 15
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            MediaLog.feeds.error("instagram: no HTTP response for '\(username, privacy: .public)'")
            throw MediaFeedError.noData
        }
        if http.statusCode == 429 {
            Self.backoffUntil = Date().addingTimeInterval(Self.backoffInterval)
            MediaLog.feeds.error("instagram: 429 rate-limited; backing off \(Self.backoffInterval, privacy: .public)s")
            throw MediaFeedError.rateLimited
        }
        guard http.statusCode == 200 else {
            MediaLog.feeds.error("instagram: HTTP \(http.statusCode, privacy: .public) for '\(username, privacy: .public)'")
            throw MediaFeedError.http(http.statusCode)
        }
        let html = String(decoding: data, as: UTF8.self)
        guard let parsed = InstagramProfileEmbedParser.parse(html: html, fallbackUsername: username) else {
            MediaLog.feeds.error("instagram: embed for '\(username, privacy: .public)' carried no profile payload (\(data.count, privacy: .public) bytes)")
            throw MediaFeedError.unusablePayload
        }
        MediaLog.feeds.info("instagram: '\(username, privacy: .public)' -> \(parsed.items.count, privacy: .public) posts")
        return parsed
    }
}

/// Reads the profile-embed payload. Pure, so it is unit-testable against a
/// captured page instead of only against the live site.
///
/// The page nests the useful JSON as a JSON-**encoded string** inside a larger
/// JSON blob, so it is unwrapped one level (`"…"` → its decoded text) and only
/// then parsed: this markup is not HTML to scrape, it is JSON to read.
enum InstagramProfileEmbedParser {

    /// A plausible Instagram handle — handles, never URLs.
    static func isProfileName(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9._]{1,30}$"#, options: .regularExpression) != nil
    }

    private static let contextKey = "\"contextJSON\":\""

    /// Parses the embed page; nil when it carries no profile payload at all.
    static func parse(html: String, fallbackUsername: String) -> MediaFeedResult? {
        guard let raw = embeddedContextJSON(html) else { return nil }
        // Re-quote and decode so the escapes inside the value resolve exactly as
        // the page's own JSON encoder wrote them.
        let quoted = "\"\(raw)\""
        guard let innerData = quoted.data(using: .utf8),
              let inner = (try? JSONDecoder().decode(String.self, from: innerData)),
              !inner.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: Data(inner.utf8)) as? [String: Any],
              let context = root["context"] as? [String: Any] else {
            return nil
        }

        let username = (context["username"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (fallbackUsername.isEmpty ? nil : fallbackUsername)
        guard let username else { return nil }
        let fullName = (context["full_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? username
        let avatar = (context["profile_pic_url"] as? String).flatMap { isRealAvatarURL($0) ? $0 : nil }

        let media = context["graphql_media"] as? [[String: Any]] ?? []
        let items = media.enumerated().compactMap { index, entry -> MediaVideo? in
            guard let mediaNode = entry["shortcode_media"] as? [String: Any] else { return nil }
            return post(mediaNode, username: username, channelName: fullName, index: index)
        }
        return MediaFeedResult(username: username, displayName: fullName, avatarURL: avatar, items: items)
    }

    /// The raw `contextJSON` value exactly as it appears: the scan stops at the
    /// first UNESCAPED quote, so the escaped quotes and slashes inside the value
    /// survive for the JSON decoder to resolve.
    private static func embeddedContextJSON(_ html: String) -> String? {
        guard let start = html.range(of: contextKey) else { return nil }
        var result = ""
        var index = start.upperBound
        while index < html.endIndex {
            let character = html[index]
            if character == "\\" {
                let next = html.index(after: index)
                guard next < html.endIndex else { break }
                result.append(character)
                result.append(html[next])
                index = html.index(after: next)
                continue
            }
            if character == "\"" { break }
            result.append(character)
            index = html.index(after: index)
        }
        return result.isEmpty ? nil : result
    }

    private static func post(
        _ media: [String: Any],
        username: String,
        channelName: String,
        index: Int
    ) -> MediaVideo? {
        guard let shortcode = (media["shortcode"] as? String), !shortcode.isEmpty else { return nil }
        let isVideo = (media["is_video"] as? Bool) ?? false
        let typename = (media["__typename"] as? String) ?? ""
        let type: InstagramMediaType = typename.caseInsensitiveCompare("GraphSidecar") == .orderedSame
            ? .carousel
            : (isVideo ? .reel : .image)

        // The embed omits `video_url`; playback resolves the stream from the
        // permalink on demand. The poster is the post's own still.
        let poster = (media["display_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (media["display_resources"] as? [[String: Any]])?.first?["src"] as? String

        let caption = (((media["edge_media_to_caption"] as? [String: Any])?["edges"] as? [[String: Any]])?.first?["node"] as? [String: Any])?["text"] as? String ?? ""
        let title = caption
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map { String($0.prefix(120)) }
            ?? "\(channelName) \(isVideo ? "Reel" : "Post")"

        let published = publishedAt(media["taken_at_timestamp"] as? Int64 ?? 0, index: index)
        let likes = (media["edge_liked_by"] as? [String: Any])?["count"] as? Int64 ?? 0

        return MediaVideo(
            videoId: "ig_\(shortcode)",
            title: title,
            channelId: "ig_\(username.lowercased())",
            channelName: channelName,
            publishedAtEpochMillis: published,
            thumbnailUrl: thumbnailURL(shortcode: shortcode, poster: poster),
            viewCount: likes,
            isShort: isVideo,
            isLive: false,
            durationSeconds: 0,
            platform: .instagram,
            instagramType: type,
            mediaUrl: (media["video_url"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            instagramUrl: "https://www.instagram.com/p/\(shortcode)/",
            bodyText: caption.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// `taken_at_timestamp` is seconds; a value already in milliseconds is kept.
    ///
    /// A post with no timestamp is staggered backwards by an hour per position so
    /// the newest-first order of the embed is preserved instead of collapsing
    /// into a tie.
    private static func publishedAt(_ timestamp: Int64, index: Int) -> Int64 {
        switch timestamp {
        case ...0:
            return Int64(Date().timeIntervalSince1970 * 1000) - Int64(index) * 3_600_000
        case let value where value > 10_000_000_000:
            return value
        default:
            return timestamp * 1000
        }
    }

    /// The poster to show, preferring one that will not expire.
    ///
    /// Meta's CDN hands out signed, time-limited image URLs (`oh=`/`oe=`/
    /// `_nc_ohc`), which answer 403 once the signature lapses — a post can then
    /// show a blank tile days after it was cached even though nothing changed.
    /// Instagram's own `/p/<code>/media/?size=l` endpoint mints a fresh signature
    /// on every request, so it is preferred whenever the embed's URL is one of the
    /// expiring kind. Null-safe and cheap, so it is applied on every read.
    static func thumbnailURL(shortcode: String, poster: String?) -> String {
        if let poster, isRealImageURL(poster), !isExpiringImageURL(poster) { return poster }
        return "https://www.instagram.com/p/\(shortcode)/media/?size=l"
    }

    /// True for a URL that is plausibly a decodable image.
    static func isRealImageURL(_ url: String) -> Bool {
        guard url.lowercased().hasPrefix("http") else { return false }
        let lower = url.lowercased()
        if lower.contains(".mp4") || lower.contains(".webm") { return false }
        return lower.contains(".jpg") || lower.contains(".jpeg") || lower.contains(".png")
            || lower.contains(".webp") || lower.contains(".heic")
    }

    /// True for a Meta CDN URL carrying a signed, time-limited grant.
    static func isExpiringImageURL(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        guard host.contains("cdninstagram") || host.contains("fbcdn") else { return false }
        let lower = url.lowercased()
        return lower.contains("oh=") || lower.contains("oe=") || lower.contains("_nc_ohc")
    }

    /// A real profile picture — never a placeholder.
    static func isRealAvatarURL(_ url: String) -> Bool {
        guard url.lowercased().hasPrefix("http") else { return false }
        let lower = url.lowercased()
        guard lower.contains("cdninstagram") || lower.contains("fbcdn") else { return false }
        return !lower.contains("default_profile") && !lower.contains("anonymoususer")
    }
}

import Foundation

/// Public X/Twitter feed source. No X login and no API key is required.
///
/// A port of Android's `XSource`, including why it reads what it reads: X shut
/// the community mirrors down, so Nitter and Xcancel no longer answer and the
/// Twitter bridge was removed from the public RSS-Bridge instances. What is left
/// is the endpoint X itself renders into its embedded timeline widget — an HTML
/// page whose posts are embedded as escaped JSON, not an XML feed.
///
/// Because the body is HTML rather than a feed, this scans for post ids and
/// reads each post's own span, instead of parsing XML. That is deliberately the
/// same shape-agnostic approach as Android's: it survives the page's markup
/// changing, which an XML parser would not.
struct XSource {

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// A realistic browser UA — the endpoint serves the timeline to it.
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"

    /// Paths that are pages, never handles.
    static let reservedPaths: Set<String> = [
        "home", "explore", "notifications", "messages", "search", "settings",
        "i", "intent", "hashtag", "hashtags", "login", "signup", "compose"
    ]

    /// The endpoint rate-limits per IP and answers `429 Rate limit exceeded`,
    /// which is what a refresh storm of every profile produces, so the whole
    /// source backs off after one instead of hammering it again on the next
    /// refresh — Android's `RATE_LIMIT_BACKOFF_MS`.
    private static var backoffUntil: Date = .distantPast
    private static let backoffInterval: TimeInterval = 10 * 60

    static func isRateLimited(now: Date = Date()) -> Bool { now < backoffUntil }

    /// One handle's posts, or a thrown reason there are none.
    func fetchProfile(_ handleOrURL: String) async throws -> MediaFeedResult {
        let (username, body) = try await fetchTimelineBody(handleOrURL)
        let items = XFeedParser.parse(body: body, username: username)
        guard !items.isEmpty else {
            // The distinction that actually matters when debugging: a 200 with an
            // empty result means either the account posted nothing or the page's
            // markup moved out from under the scanner. Logging the shape of the
            // body tells the two apart instead of leaving "empty feed" as the
            // only evidence.
            MediaLog.feeds.error("""
                x: parsed 0 posts from '\(username, privacy: .public)' \
                (\(body.utf8.count, privacy: .public) bytes, nextData: \(body.contains("__NEXT_DATA__"), privacy: .public), \
                hasFullText: \(body.contains("full_text"), privacy: .public), \
                hasTweetIdMarker: \(body.contains("data-tweet-id") || body.contains("tweet_id"), privacy: .public))
                """)
            throw MediaFeedError.unusablePayload
        }
        MediaLog.feeds.info("x: '\(username, privacy: .public)' -> \(items.count, privacy: .public) posts")
        let profile = XFeedParser.profile(body: body, username: username)
        var avatar = profile.avatarURL
        if avatar == nil { avatar = try? await fetchAvatar(username) }
        return MediaFeedResult(username: username, displayName: profile.displayName ?? "@\(username)", avatarURL: avatar, items: items)
    }

    /// The raw syndication body for a handle, plus the resolved username.
    ///
    /// Split out from `fetchProfile` so the body itself can be inspected: the
    /// live test asserts on what the endpoint actually returned, which is the
    /// only way to catch the page's markup changing shape — something no fixture
    /// can tell you.
    func fetchTimelineBody(_ handleOrURL: String) async throws -> (username: String, body: String) {
        guard let username = Self.extractUsername(handleOrURL) else { throw MediaFeedError.invalidHandle }
        guard !Self.isRateLimited() else { throw MediaFeedError.rateLimited }

        var request = URLRequest(url: URL(string:
            "https://syndication.twitter.com/srv/timeline-profile/screen-name/\(username)")!)
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            MediaLog.feeds.error("x: no HTTP response for '@\(username, privacy: .public)'")
            throw MediaFeedError.noData
        }
        if http.statusCode == 429 {
            Self.backoffUntil = Date().addingTimeInterval(Self.backoffInterval)
            MediaLog.feeds.error("x: 429 rate-limited for '@\(username, privacy: .public)'; backing off \(Self.backoffInterval, privacy: .public)s")
            throw MediaFeedError.rateLimited
        }
        guard http.statusCode == 200 else {
            MediaLog.feeds.error("x: HTTP \(http.statusCode, privacy: .public) for '@\(username, privacy: .public)'")
            throw MediaFeedError.http(http.statusCode)
        }

        return (username, String(decoding: data, as: UTF8.self))
    }

    /// The profile's avatar URL (`pbs.twimg.com`), or nil.
    ///
    /// The syndication timeline page carries `profile_image_url_https`, but it is
    /// also the endpoint that rate-limits hardest, so the public FxTwitter
    /// profile API is asked instead — it answers with the same CDN URL and stays
    /// reachable when the timeline does not.
    func fetchAvatar(_ handleOrURL: String) async throws -> String? {
        guard let username = Self.extractUsername(handleOrURL) else { return nil }
        var request = URLRequest(url: URL(string: "https://api.fxtwitter.com/\(username)")!)
        request.timeoutInterval = 15
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return Self.avatarURL(fromProfileResponse: data, username: username)
    }

    /// The avatar URL inside an FxTwitter profile response. Pure, so it is
    /// testable against a captured payload.
    static func avatarURL(fromProfileResponse data: Data, username: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let user = (root["user"] as? [String: Any]) ?? root
        let candidate = (user["avatar_url"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (user["profile_image_url"] as? String)
        guard let candidate, isRealAvatarURL(candidate, username: username) else { return nil }
        return candidate
    }

    /// A real `twimg` avatar — never a placeholder.
    ///
    /// The profile image path embeds the numeric id rather than the handle, so
    /// the handle cannot be checked against the URL; the host and the absence of
    /// a default marker are the usable signals.
    static func isRealAvatarURL(_ url: String, username: String) -> Bool {
        guard url.lowercased().hasPrefix("http") else { return false }
        let lower = url.lowercased()
        guard lower.contains("twimg.com") else { return false }
        if lower.contains("default_profile") || lower.contains("sticky/default") { return false }
        return !username.isEmpty
    }

    /// The handle inside a handle, an `@handle`, or an `x.com` / `twitter.com`
    /// URL. Rejects the reserved page paths that look like handles.
    static func extractUsername(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw: String
        if let range = value.range(of: "x.com/", options: .caseInsensitive) {
            raw = String(value[range.upperBound...])
        } else if let range = value.range(of: "twitter.com/", options: .caseInsensitive) {
            raw = String(value[range.upperBound...])
        } else {
            raw = value.hasPrefix("@") ? String(value.dropFirst()) : value
        }
        let username = raw
            .prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard username.range(of: #"^[A-Za-z0-9_]{1,15}$"#, options: .regularExpression) != nil,
              !reservedPaths.contains(username.lowercased()) else { return nil }
        return username
    }
}

/// Parses X's public syndication timeline response.
///
/// The body arrives with its strings escaped, so [`unescape`] runs first and one
/// set of patterns then reads both the JSON-escaped page and plain server-rendered
/// markup. Post ids are located first, and each post is then read from its OWN
/// span — from its id up to the next one.
enum XFeedParser {

    /// How far past a post id its own JSON is scanned (text and media live there).
    private static let postWindow = 8_000
    /// How far past a post id to look for evidence that it really is a post.
    private static let evidenceWindow = 3_000

    /// Markers that only appear on post objects.
    private static let postMarkers = [
        "full_text", "tweet_id", "data-tweet-id", "conversation_id",
        "favorite_count", "timeline-Tweet-text", "tweet\":{"
    ]

    /// Post ids, in the order they appear.
    ///
    /// The profile's own user object carries an `id_str` too, so a candidate is
    /// rejected when its neighbourhood looks like a user rather than a post.
    /// `rest_id` and bare `/status/<id>` links only count when the id is in the
    /// post (snowflake) length range — user ids are much shorter, so this cannot
    /// mistake a profile for a post.
    private static let idPatterns = [
        #"\bid_str\b["']?\s*[:=]\s*["']?(\d{10,25})"#,
        #"\bdata-tweet-id\b["']?\s*[:=]\s*["']?(\d{10,25})"#,
        #"\b(?:tweet_id|tweetId|status_id|statusId)\b["']?\s*[:=]\s*["']?(\d{10,25})"#,
        #"\brest_id\b["']?\s*[:=]\s*["']?(\d{15,25})"#,
        #"/status(?:es)?/(\d{15,25})"#
    ]

    /// Post text: the JSON field first, then the server-rendered paragraph.
    private static let textPatterns = [
        #"\bfull_text\b["']?\s*[:=]\s*["']([^"]{1,1000})"#,
        #"timeline-Tweet-text[^>]*>([^<]{1,1000})"#,
        #"\btext\b["']?\s*[:=]\s*["']([^"]{1,1000})"#
    ]

    /// Media URLs point at the `pbs.twimg.com/media` (images) and
    /// `video.twimg.com` (playable mp4) hosts.
    private static let mediaImage = #"https?://pbs\.twimg\.com/(?:media|ext_tw_video_thumb|amplify_video_thumb|tweet_video_thumb)/[^\s"'\\<>]+"#
    private static let anyImage = #"https?://[^\s"'\\<>]+\.(?:jpg|jpeg|png|webp|gif)[^\s"'\\<>]*"#
    private static let videoURL = #"https?://[^\s"'\\<>]+\.(?:mp4|m3u8)[^\s"'\\<>]*"#

    /// The clip's own length, in milliseconds, published inside the media's
    /// `video_info` immediately before the variant list — so the value belonging
    /// to the chosen URL is the last one seen before it.
    private static let durationMillis = #""duration_millis"\s*:\s*(\d{2,9})"#

    /// Parses a syndication body into posts.
    ///
    /// The modern endpoint serves a **Next.js page**, so the posts are JSON in an
    /// `__NEXT_DATA__` script tag — `props.pageProps.timeline.entries[].content.tweet`.
    /// That is read first, and the older server-rendered markup is only a
    /// fallback.
    ///
    /// The JSON path exists because the id-scanning approach below genuinely
    /// breaks on this payload: measured against the live page it produced **135
    /// "posts" from a 101-entry timeline** with empty thumbnails. Nested objects
    /// — retweets, quoted posts, the author — each carry their own `id_str`, so
    /// ids are dense rather than one-per-post, and a window that runs "to the next
    /// id" collapses into a sliver that never reaches the media. Scanning was
    /// written for the old sparse HTML where one id meant one post; it is kept only
    /// for that case.
    static func parse(body: String, username: String) -> [MediaVideo] {
        let fromJSON = parseNextData(body: body, username: username)
        if !fromJSON.isEmpty { return fromJSON }
        MediaLog.feeds.debug("x: no __NEXT_DATA__ posts; falling back to markup scan")
        return parseSyndication(body: body, username: username)
    }

    /// Posts from the Next.js payload, in page order.
    static func parseNextData(body: String, username: String) -> [MediaVideo] {
        guard let json = nextDataJSON(body),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let pageProps = (root["props"] as? [String: Any])?["pageProps"] as? [String: Any],
              let timeline = pageProps["timeline"] as? [String: Any],
              let entries = timeline["entries"] as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let tweet = (entry["content"] as? [String: Any])?["tweet"] as? [String: Any] else { return nil }
            return post(fromTweet: tweet, username: username)
        }
    }

    /// Read the requested profile's own user object, not a quoted/reposted author.
    static func profile(body: String, username: String) -> (displayName: String?, avatarURL: String?) {
        guard let json = nextDataJSON(body),
              let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let props = (root["props"] as? [String: Any])?["pageProps"] as? [String: Any] else { return (nil, nil) }
        var users: [[String: Any]] = []
        if let user = props["user"] as? [String: Any] { users.append(user) }
        if let entries = (props["timeline"] as? [String: Any])?["entries"] as? [[String: Any]] {
            for entry in entries {
                if let tweet = (entry["content"] as? [String: Any])?["tweet"] as? [String: Any],
                   let user = tweet["user"] as? [String: Any] { users.append(user) }
            }
        }
        guard let user = users.first(where: { ($0["screen_name"] as? String)?.lowercased() == username.lowercased() }) else {
            return (nil, nil)
        }
        let candidate = (user["profile_image_url_https"] as? String) ?? (user["profile_image_url"] as? String)
        let avatar = candidate.flatMap { XSource.isRealAvatarURL($0, username: username) ? $0 : nil }
        return (user["name"] as? String, avatar)
    }

    /// The `__NEXT_DATA__` JSON, pulled out of its script element.
    private static func nextDataJSON(_ body: String) -> String? {
        guard let marker = body.range(of: "__NEXT_DATA__"),
              let open = body.range(of: ">", range: marker.upperBound..<body.endIndex),
              let close = body.range(of: "</script>", range: open.upperBound..<body.endIndex) else { return nil }
        let json = String(body[open.upperBound..<close.lowerBound])
        return json.isEmpty ? nil : json
    }

    /// One parsed tweet.
    ///
    /// Media is read from `entities.media[]` first and `extended_entities`
    /// second, because the syndication payload was measured to carry `entities`
    /// and NOT `extended_entities` — the reverse of the usual API shape, so
    /// checking only the documented one silently yields posts with no media.
    private static func post(fromTweet tweet: [String: Any], username: String) -> MediaVideo? {
        let id = (tweet["id_str"] as? String) ?? (tweet["id"] as? NSNumber)?.stringValue
        guard let id, !id.isEmpty else { return nil }
        let text = (tweet["full_text"] as? String) ?? (tweet["text"] as? String) ?? ""
        let attachments = ((tweet["extended_entities"] as? [String: Any])?["media"] as? [[String: Any]])
            ?? ((tweet["entities"] as? [String: Any])?["media"] as? [[String: Any]]) ?? []
        let media = attachments.first(where: { $0["video_info"] != nil }) ?? attachments.first
        let image = (media?["media_url_https"] as? String) ?? (media?["media_url"] as? String)
        let videoInfo = media?["video_info"] as? [String: Any]
        let durationMillis = Int64(intValue(videoInfo?["duration_millis"]))
        let handle = ((tweet["user"] as? [String: Any])?["screen_name"] as? String) ?? username
        let link = (tweet["permalink"] as? String) ?? "https://x.com/\(handle)/status/\(id)"
        let published = (tweet["created_at"] as? String).flatMap(parseCreatedAt)
            ?? snowflakeTime(id)
            ?? nowMillis()
        return item(
            username: handle,
            stableId: id,
            title: text.isEmpty ? "@\(handle) post" : text,
            link: link,
            published: published,
            imageURL: image,
            mediaURL: progressiveVideoURL(videoInfo),
            durationSeconds: durationMillis / 1000,
            bodyText: text
        )
    }

    /// The playable MP4 among a media object's `video_info.variants`.
    ///
    /// PROGRESSIVE FIRST, for the same reason the markup scanner prefers it: a
    /// post's variant list carries both an HLS playlist and MP4s, X lists the
    /// playlist first, and `AVPlayer` cannot seek or download the playlist the way
    /// this app needs. The highest-bitrate MP4 wins, with the playlist kept only
    /// for a post that offers nothing else.
    static func progressiveVideoURL(_ videoInfo: [String: Any]?) -> String? {
        guard let variants = videoInfo?["variants"] as? [[String: Any]], !variants.isEmpty else { return nil }
        let candidates = variants.compactMap { variant -> (url: String, bitrate: Int, isMP4: Bool)? in
            guard let url = variant["url"] as? String, !url.isEmpty else { return nil }
            let isMP4 = ((variant["content_type"] as? String) ?? "").lowercased().contains("mp4")
            return (url, intValue(variant["bitrate"]), isMP4)
        }
        let mp4s = candidates.filter(\.isMP4)
        if let best = mp4s.max(by: { $0.bitrate < $1.bitrate }) { return best.url }
        return candidates.first?.url
    }

    /// Reads an integer out of a JSON value.
    ///
    /// JSON numbers do not arrive as one Swift type: `JSONSerialization` yields
    /// `NSNumber`, dictionaries built in code (and in tests) hold `Int`/`Double`,
    /// and some payloads quote numbers as strings. A bare `as? NSNumber` bridge
    /// covers most of that — but when it yields nil the caller silently sees `0`,
    /// and for the bitrate comparison that means every variant ties and the FIRST
    /// mp4 (the lowest quality) wins without anything failing. Nothing here is
    /// subtle; it just refuses to let a representation difference become an
    /// invisible quality downgrade.
    static func intValue(_ value: Any?) -> Int {
        switch value {
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text) ?? 0
        default: return 0
        }
    }

    /// `created_at` is `"Wed Oct 10 20:19:24 +0000 2018"`.
    static func parseCreatedAt(_ value: String) -> Int64? {
        createdAtFormatter.date(from: value).map { Int64($0.timeIntervalSince1970 * 1000) }
    }

    private static let createdAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // POSIX so the month/day names are parsed in English regardless of the
        // device's region — a Swedish locale would otherwise fail every date and
        // silently fall back to the snowflake.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter
    }()

    /// Parses the older server-rendered syndication markup into posts.
    static func parseSyndication(body: String, username: String) -> [MediaVideo] {
        let source = unescape(body)
        let ids = postIDs(source)
        guard !ids.isEmpty else { return [] }
        return ids.enumerated().compactMap { index, entry in
            let (id, position) = entry
            let window = substring(source, position, postWindow)
            // The full window can run past the end of THIS post into the next,
            // and a text-only post that borrows the following post's mp4 renders
            // as a video card playing someone else's clip. So media is read from
            // the post's OWN span only — never from the wider window. Text keeps
            // the wide fallback, because taking the FIRST match is already this
            // post's own text.
            let nextPosition = ids.indices.contains(index + 1) ? ids[index + 1].position : nil
            let ownSpan: String
            if let nextPosition, nextPosition > position {
                ownSpan = substring(window, 0, nextPosition - position)
            } else {
                ownSpan = window
            }
            let text = postText(ownSpan).isEmpty ? postText(window) : postText(ownSpan)
            let media = firstMediaVideo(ownSpan)
            return item(
                username: username,
                stableId: id,
                title: text.isEmpty ? "@\(username) post" : text,
                link: "https://x.com/\(username)/status/\(id)",
                published: snowflakeTime(id) ?? (nowMillis() - Int64(index) * 3_600_000),
                imageURL: firstMediaImage(ownSpan),
                mediaURL: media,
                durationSeconds: duration(for: ownSpan, mediaURL: media),
                bodyText: text
            )
        }
    }

    /// Candidate post ids and the offset of each one's first occurrence, in page
    /// order.
    private static func postIDs(_ source: String) -> [(id: String, position: Int)] {
        var positions: [String: Int] = [:]
        for pattern in idPatterns {
            for match in matches(pattern, in: source) {
                guard let id = group(match, 1, in: source) else { continue }
                if positions[id] == nil { positions[id] = match.range.location }
            }
        }
        return positions
            .sorted { $0.value < $1.value }
            .map { (id: $0.key, position: $0.value) }
            .filter { isPost(source, position: $0.position) }
    }

    /// Whether the neighbourhood of `position` looks like a post rather than the
    /// profile's own user object (whose `id_str` also appears on the page).
    private static func isPost(_ source: String, position: Int) -> Bool {
        let window = substring(source, position, evidenceWindow)
        let lower = window.lowercased()
        if postMarkers.contains(where: { lower.contains($0.lowercased()) }) { return true }
        let looksLikeUser = lower.contains("screen_name")
            || lower.contains("followers_count")
            || lower.contains("profile_image_url")
        return !looksLikeUser
    }

    /// The post's text, or "" when the window carries none.
    private static func postText(_ window: String) -> String {
        for pattern in textPatterns {
            guard let match = matches(pattern, in: window).first,
                  let raw = group(match, 1, in: window), !raw.isEmpty else { continue }
            let clean = cleanText(unescape(raw))
            if !clean.isEmpty { return clean }
        }
        return ""
    }

    /// How long the clip runs, from X's own `duration_millis`.
    ///
    /// Without this every X card showed no length at all: YouTube resolves
    /// durations from the watch page and Instagram from the container, so X was
    /// the one source that could never say how long its clips were — even though
    /// the number is in the very payload the media URL is read from.
    private static func duration(for window: String, mediaURL: String?) -> Int64 {
        guard let mediaURL, !mediaURL.isEmpty,
              let at = window.range(of: mediaURL) else { return 0 }
        let before = String(window[window.startIndex..<at.lowerBound])
        let millis = matches(durationMillis, in: before).last
            .flatMap { group($0, 1, in: before) }
            .flatMap { Int64($0) }
        return (millis ?? 0) / 1000
    }

    private static func item(
        username: String,
        stableId: String,
        title: String,
        link: String,
        published: Int64,
        imageURL: String?,
        mediaURL: String?,
        durationSeconds: Int64,
        bodyText: String
    ) -> MediaVideo {
        MediaVideo(
            videoId: "x_\(stableId)",
            // The card shows a short label; the FULL post text rides along in
            // bodyText so the post viewer can show all of it.
            title: String(title.prefix(160)),
            channelId: "x_\(username.lowercased())",
            channelName: "@\(username)",
            publishedAtEpochMillis: published,
            thumbnailUrl: imageURL ?? "",
            isShort: false,
            durationSeconds: durationSeconds,
            platform: .x,
            mediaUrl: mediaURL,
            sourceUrl: link,
            bodyText: bodyText
        )
    }

    /// A post id is a snowflake: the timestamp is the top 42 bits, offset by
    /// X's epoch. Gives a real posting time without parsing any date format.
    static func snowflakeTime(_ id: String) -> Int64? {
        guard let value = Int64(id) else { return nil }
        let millis = (value >> 22) + 1_288_834_974_657
        return millis > 0 ? millis : nil
    }

    /// Normalises the escaped payloads so one set of patterns reads both the
    /// JSON-escaped syndication page and plain HTML: escaped slashes and quotes
    /// become literal, `\u0026` / `&amp;` become `&` (media URLs carry query
    /// separators) and escaped whitespace becomes a space.
    static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\u002f", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\u003C", with: "<")
            .replacingOccurrences(of: "\\u003c", with: "<")
            .replacingOccurrences(of: "\\u003E", with: ">")
            .replacingOccurrences(of: "\\u003e", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\r", with: " ")
            .replacingOccurrences(of: "\\t", with: " ")
    }

    /// Post image: the `pbs.twimg.com` media host first, any other image after —
    /// excluding profile pictures and banners, which are the profile's, not the
    /// post's.
    private static func firstMediaImage(_ window: String) -> String? {
        if let match = matches(mediaImage, in: window).first {
            return substring(window, match.range.location, match.range.length)
        }
        return matches(anyImage, in: window)
            .compactMap { substring(window, $0.range.location, $0.range.length) }
            .first { !$0.contains("profile_images") && !$0.contains("profile_banner") }
    }

    /// The post's video URL, PROGRESSIVE FIRST.
    ///
    /// A post's media list carries both an HLS playlist (`…/playlist.m3u8`) and
    /// progressive variants (`.mp4`), and X lists the playlist first. `AVPlayer`
    /// needs the progressive file to be useful offline and to download; the
    /// playlist stays as the last resort for a post that offers no mp4.
    private static func firstMediaVideo(_ window: String) -> String? {
        let all = matches(videoURL, in: window)
            .compactMap { substring(window, $0.range.location, $0.range.length) }
        if let mp4 = all.first(where: { $0.lowercased().contains(".mp4") }) { return mp4 }
        return all.first
    }

    private static func cleanText(_ html: String) -> String {
        html.replacingOccurrences(of: #"<[^>]*>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Regex plumbing

    private static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard match.numberOfRanges > index, let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }

    /// A substring by offset and length, clamped to the string's bounds.
    ///
    /// The offsets here come from `NSRegularExpression`, which counts UTF-16 code
    /// units — NOT `Character`s. Indexing a `String` with them quietly returns the
    /// wrong slice as soon as the text contains an emoji, an Arabic caption or any
    /// other multi-unit character, and the windows would then read another post's
    /// media. Going through `NSString` keeps one unit system throughout, and
    /// `prefix`/`suffix`-style `String` slicing is used only for offsets this file
    /// computed itself.
    private static func substring(_ text: String, _ offset: Int, _ length: Int) -> String {
        let ns = text as NSString
        guard offset >= 0, offset < ns.length else { return "" }
        return ns.substring(with: NSRange(location: offset, length: min(length, ns.length - offset)))
    }

    private static func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

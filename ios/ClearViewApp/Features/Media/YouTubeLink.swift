import Foundation

/// What a parsed YouTube URL points at.
///
/// The *kind* matters beyond the id, and that is why it is carried: a `/shorts/`
/// link is a vertical Short and the player has to treat it as one, while `/live/`
/// is a broadcast. A parser that returned only an id marks every pasted link as a
/// long video, which is exactly the bug this type exists to prevent.
enum YouTubeUrlKind: String {
    /// `/watch?v=ID`, `music.youtube.com/watch?v=ID`, `?v=ID`.
    case watch = "WATCH"
    /// `/shorts/ID` — a vertical Short.
    case short = "SHORT"
    /// `/live/ID` — a live broadcast, or its VOD after the stream ends.
    case live = "LIVE"
    /// `/embed/ID`, `/v/ID`.
    case embed = "EMBED"
    /// `youtu.be/ID`.
    case shortLink = "SHORT_LINK"
    /// The bare 11-character id, pasted on its own.
    case bareId = "BARE_ID"
}

/// A YouTube video reference: the id, what kind of link it came from, and the
/// `t=` / `start=` offset when the link carried one.
struct YouTubeRef: Equatable {
    let videoId: String
    let kind: YouTubeUrlKind
    /// Start offset in seconds, or 0 when the link carried none.
    let startSeconds: Int

    init(videoId: String, kind: YouTubeUrlKind, startSeconds: Int = 0) {
        self.videoId = videoId
        self.kind = kind
        self.startSeconds = startSeconds
    }

    /// True for a `/shorts/` link.
    var isShort: Bool { kind == .short }

    /// True for a `/live/` link.
    var isLive: Bool { kind == .live }
}

/// The app's single YouTube link parser.
///
/// Written as one parser rather than the four independent regexes it replaced,
/// because the interesting failures were all about *context*: matching `?v=` on any
/// host made `https://example.com/page?v=xxxxxxxxxxx` look like a video, and not
/// knowing `/live/` rejected the exact link YouTube's own Share sheet produces for a
/// broadcast. It understands every form YouTube hands out:
///
///  - `youtube.com/watch?v=ID` (also `m.`, `music.`, `www.`, parameters in any order,
///    and `youtu.be/ID`)
///  - `youtube.com/shorts/ID`, `youtube.com/live/ID`
///  - `youtube.com/embed/ID`, `youtube.com/v/ID`, `youtube-nocookie.com/embed/ID`
///  - a bare 11-character id
///  - a paragraph containing a link ("Watch this: <url>") — the first YouTube URL
///    inside it is used
///
/// Query parameters YouTube adds (`?si=`, `&feature=share`, `&list=`, …) are ignored;
/// `t=` / `start=` are decoded, including the `1h2m3s` form. Pure string logic, so it
/// is testable without a network or a device.
enum YouTubeLink {

    /// Hosts YouTube serves video pages from.
    private static let youTubeHosts = [
        "youtube.com",
        "youtu.be",
        "youtube-nocookie.com",
        "youtubekids.com",
    ]

    private static let videoIdLength = 11
    private static let bareIdCharacters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"

    /// The app's entry point: anything a user can paste, in or out of a link.
    static func parse(_ input: String?) -> YouTubeRef? {
        let text = input?.trimmed ?? ""
        if text.isEmpty { return nil }
        // A bare id is a valid input on its own ("dQw4w9WgXcQ").
        if isVideoId(text) { return YouTubeRef(videoId: text, kind: .bareId) }
        if let parsed = parseUrl(text) { return parsed }
        // Pasted share text ("Watch this: https://youtu.be/ID") — parse the first URL
        // inside it rather than rejecting the whole field, which is what a user
        // copying from another app actually hands over.
        if let url = firstUrl(in: text) { return parseUrl(url) }
        return nil
    }

    /// The id alone, for the callers that only need one. Still the same parser —
    /// never a second regex.
    static func videoId(from input: String) -> String? {
        parse(input)?.videoId
    }

    /// True when `text` is a real video id.
    static func isVideoId(_ text: String) -> Bool {
        text.count == videoIdLength && text.allSatisfy { bareIdCharacters.contains($0) }
    }

    // MARK: - The URL itself

    private static func parseUrl(_ raw: String) -> YouTubeRef? {
        // Drop the scheme when there is one: "youtube.com/watch?v=…" is accepted
        // without it, which is how some apps copy links.
        let withoutScheme = raw.contains("://")
            ? String(raw[raw.range(of: "://")!.upperBound...])
            : raw
        let hostEnd = withoutScheme.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" }
        let hostRaw = hostEnd.map { String(withoutScheme[..<$0]) } ?? withoutScheme
        let rest = hostEnd.map { String(withoutScheme[$0...]) } ?? ""

        // A host has to look like one. When the input carries a host it **must** be a
        // YouTube domain (so example.com/watch?v=… is rejected); when it doesn't, the
        // whole string is treated as path + query ("watch?v=ID").
        let hasHost = hostRaw.contains(".")
        if hasHost && !isYouTubeHost(hostRaw) { return nil }
        let target = hasHost ? rest : withoutScheme

        let path = target.firstSplit(separator: "?").firstSplit(separator: "#")
        let query = target.contains("?")
            ? String(target[target.range(of: "?")!.upperBound...]).firstSplit(separator: "#")
            : ""
        let segments = path.split(separator: "/").map(String.init)

        // youtu.be/<id> — the id is the first path segment.
        let lowerHost = hostRaw.lowercased()
        if hasHost && (lowerHost == "youtu.be" || lowerHost.hasSuffix(".youtu.be")) {
            guard let id = segments.first else { return nil }
            return reference(id, kind: .shortLink, query: query)
        }

        let match: (id: String, kind: YouTubeUrlKind)?
        switch segments.first?.lowercased() {
        case "watch":
            match = queryParam(query, "v").map { ($0, .watch) }
        case "shorts":
            match = segments.count > 1 ? (segments[1], .short) : nil
        case "live":
            match = segments.count > 1 ? (segments[1], .live) : nil
        case "embed":
            match = segments.count > 1 ? (segments[1], .embed) : nil
        case "v", "e":
            match = segments.count > 1 ? (segments[1], .embed) : nil
        default:
            // No recognised path: a video id in the query is still a watch link
            // (youtube.com/?v=ID). Anything else — a channel, a playlist, a handle —
            // has no video id and is rejected.
            match = queryParam(query, "v").map { ($0, .watch) }
        }
        guard let match else { return nil }
        return reference(match.id, kind: match.kind, query: query)
    }

    /// Builds the reference, rejecting anything that is not a real video id.
    private static func reference(_ candidate: String?, kind: YouTubeUrlKind, query: String) -> YouTubeRef? {
        let id = candidate?.trimmed ?? ""
        guard isVideoId(id) else { return nil }
        return YouTubeRef(videoId: id, kind: kind, startSeconds: startSeconds(in: query))
    }

    private static func isYouTubeHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return youTubeHosts.contains { lower == $0 || lower.hasSuffix(".\($0)") }
    }

    /// The first value of `name` in an already-split `a=1&b=2` query string.
    private static func queryParam(_ query: String, _ name: String) -> String? {
        guard !query.isEmpty else { return nil }
        for pair in query.split(separator: "&") {
            let key = pair.contains("=")
                ? String(pair[..<pair.range(of: "=")!.lowerBound])
                : String(pair)
            guard key.lowercased() == name.lowercased() else { continue }
            let value = pair.contains("=")
                ? String(pair[pair.range(of: "=")!.upperBound...])
                : ""
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// `t` / `start` as seconds: `t=90`, `t=90s`, `t=1m30s`, `t=1h2m3s`, `start=90`.
    ///
    /// Anything unparseable means "no offset" (0) rather than a rejected link: the
    /// video is still the video, and losing the whole link over a malformed timestamp
    /// would be the worse failure.
    private static func startSeconds(in query: String) -> Int {
        guard let raw = queryParam(query, "t") ?? queryParam(query, "start") else { return 0 }
        if raw.allSatisfy(\.isNumber) { return max(Int(raw) ?? 0, 0) }
        var total = 0
        var current = 0
        var sawUnit = false
        for character in raw {
            switch character {
            case "0"..."9":
                current = current * 10 + (Int(String(character)) ?? 0)
            case "h":
                total += current * 3600
                current = 0
                sawUnit = true
            case "m":
                total += current * 60
                current = 0
                sawUnit = true
            case "s":
                total += current
                current = 0
                sawUnit = true
            default:
                return 0
            }
        }
        return sawUnit ? total : 0
    }

    /// The first `http(s)://…` token inside a larger string.
    private static func firstUrl(in text: String) -> String? {
        guard let start = text.range(of: "http://") ?? text.range(of: "https://") else { return nil }
        let rest = text[start.lowerBound...]
        let terminators = CharacterSet(charactersIn: " \t\n\r\"'<>")
        let end = rest.unicodeScalars.firstIndex { terminators.contains($0) }
            .map { rest.unicodeScalars.index(after: $0) } ?? rest.endIndex
        return String(rest[rest.startIndex..<end])
    }
}

/// YouTube playlist links, read for their `list=` parameter.
///
/// Playlist ids come in several shapes — `PL` + 32 characters, the `UC` / `FL` / `WL`
/// uploads lists, `OLAK5uy_` album lists — so the bare-id rule accepts a 13–43
/// character id-ish token and deliberately never matches an 11-character *video* id,
/// which would otherwise turn a pasted video into an empty playlist.
enum YouTubePlaylistLink {

    /// YouTube's special two-letter list ids (no long `PL` prefix).
    static let shortSystemListIds: Set<String> = ["WL", "LL", "FL", "WD"]

    /// The playlist id in `input`, whether it is a URL or a bare id; nil when there
    /// is none.
    static func parse(_ input: String) -> String? {
        let text = input.trimmed
        guard !text.isEmpty else { return nil }
        // `list=ID` anywhere in the URL: /playlist?list=, watch?v=&list=, youtu.be,
        // music.youtube.com… Stops at the next & or #.
        if let match = firstMatch(in: text, pattern: "[?&]list=([A-Za-z0-9_-]+)") { return match }
        // The /playlist/ID path form (rare, but supported).
        if let match = firstMatch(in: text, pattern: "youtube\\.com/playlist/([A-Za-z0-9_-]+)") {
            return match
        }
        if shortSystemListIds.contains(text) { return text }
        // A bare playlist id pasted on its own, with no URL shape at all.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        if text.count >= 13, text.count <= 43,
           text.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
            return text
        }
        return nil
    }

    /// True when the input is a playlist link (rather than a video or a channel), which
    /// is what routes a pasted URL to the playlist screen.
    static func isPlaylistLink(_ input: String) -> Bool {
        parse(input) != nil
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        guard let capture = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capture])
    }
}

/// A tiny string helper the link parser leans on.
///
/// `substringBefore` has no direct Foundation equivalent that keeps the same
/// semantics for an empty separator ("a?b" before "?" is "a", but a string with no
/// separator is itself), and the parser is full of "split here, keep the rest" steps.
private extension String {
    /// This string up to the first occurrence of `separator`, or the whole string when
    /// it does not occur.
    func firstSplit(separator: Character) -> String {
        guard let index = firstIndex(of: separator) else { return self }
        return String(self[..<index])
    }
}

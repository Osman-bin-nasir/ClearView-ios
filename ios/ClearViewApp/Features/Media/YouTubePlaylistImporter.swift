import Foundation

/// A YouTube playlist the reader imported by URL.
///
/// Android's `SavedPlaylist`, and the same three fields. Kept beside the local
/// playlists rather than merged into them: a local playlist is a list the reader
/// owns and edits, while an imported one is a view onto YouTube's, whose order and
/// contents are YouTube's to change — so it can be opened and removed, but not
/// reordered or added to.
struct ImportedPlaylist: Codable, Identifiable, Hashable {
    var playlistId: String
    var title: String
    /// The raw URL or id the reader pasted, kept for reference.
    var sourceRef: String

    var id: String { playlistId }
}

/// Fetches and parses a public YouTube playlist page.
///
/// The port of Android's `PlaylistPageParser` + the repository's playlist fetch,
/// with one deliberate difference in *which* JSON it reads. Android walks the
/// classic `playlistVideoRenderer` / `playlistPanelVideoRenderer` entries and,
/// when a page has neither (which is now the normal case), falls back to a
/// `youtubei/v1/next` panel request. The page that YouTube serves today instead
/// carries the whole playlist as `lockupViewModel` entries — 100 of them on a
/// page measured while writing this — so those are read directly and the
/// `/next` fallback is not needed.
///
/// Pure except for one `URLSession` call, so the parse can be tested against a
/// captured page and the network path stays the only thing that can fail.
enum YouTubePlaylistImporter {

    /// A parsed playlist, ready to save.
    struct Imported {
        let playlistId: String
        let title: String
        let videos: [LibraryVideo]
    }

    enum ImportError: LocalizedError {
        case notAPlaylist
        case unreadable
        case empty

        var errorDescription: String? {
            switch self {
            case .notAPlaylist:
                return "That does not look like a YouTube playlist link. Paste a link with a list= parameter."
            case .unreadable:
                return "YouTube did not return a readable playlist page. It may be private, or the request was blocked."
            case .empty:
                return "That playlist has no videos the app can read."
            }
        }
    }

    /// A desktop browser's user agent.
    ///
    /// The playlist page is served to it in full; a bare client gets a consent
    /// wall with no `ytInitialData` at all, which would read as "unreadable
    /// playlist" for a playlist that is perfectly public.
    static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    static func playlistURL(_ playlistId: String) -> URL {
        URL(string: "https://www.youtube.com/playlist?list=\(playlistId)")!
    }

    /// Resolves `input` (a link or a bare id) and reads the playlist.
    static func fetch(input: String) async throws -> Imported {
        guard let playlistId = YouTubePlaylistLink.parse(input) else { throw ImportError.notAPlaylist }
        var request = URLRequest(url: playlistURL(playlistId))
        request.timeoutInterval = 25
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ImportError.unreadable }
        guard let imported = parse(html: String(decoding: data, as: UTF8.self), playlistId: playlistId) else {
            throw ImportError.unreadable
        }
        guard !imported.videos.isEmpty else { throw ImportError.empty }
        return imported
    }

    /// Reads `ytInitialData` out of a playlist page and returns the title plus the
    /// videos, in playlist order. Nil when the page carries no readable JSON.
    static func parse(html: String, playlistId: String) -> Imported? {
        guard let json = initialData(in: html) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return nil
        }
        let title = playlistTitle(in: root) ?? "YouTube playlist"
        return Imported(playlistId: playlistId, title: title, videos: videos(in: root, json: json))
    }

    // MARK: - The page

    /// The page's `ytInitialData` assignment, as raw JSON text.
    ///
    /// Matched rather than scanned so the same call serves both the parse and the
    /// document-order sort below — the videos' positions are offsets into this
    /// exact string.
    ///
    /// The closing punctuation is matched loosely on purpose: a captured page ends
    /// the script with `};</script>`, but the same assignment also appears as
    /// `};\n</script>` and, on some renderings, with no semicolon at all. Requiring
    /// one exact spelling meant a supported page read as "unreadable playlist" —
    /// which is what the unit tests caught.
    private static func initialData(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"ytInitialData\s*=\s*(\{.*?\})\s*;?\s*</script>"#,
            options: [.dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range), match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[capture])
    }

    private static func playlistTitle(in root: [String: Any]) -> String? {
        let metadata = root["metadata"] as? [String: Any]
        let renderer = metadata?["playlistMetadataRenderer"] as? [String: Any]
        let title = (renderer?["title"] as? String)?.trimmed ?? ""
        return title.isEmpty ? nil : title
    }

    // MARK: - The videos

    /// Every video on the page, in the order YouTube lists them.
    ///
    /// Document order is the playlist's own order, and it has to be recovered
    /// rather than assumed: `JSONSerialization` hands back dictionaries whose key
    /// order is not preserved, so a plain tree walk can visit two containers in
    /// either order. Sorting by each entry's offset in the JSON text is what makes
    /// the result the playlist's order rather than "the order the walk happened to
    /// take".
    private static func videos(in root: [String: Any], json: String) -> [LibraryVideo] {
        var entries: [[String: Any]] = []
        collect(root, into: &entries)

        var positioned: [(offset: String.Index?, video: LibraryVideo)] = []
        for entry in entries {
            guard let candidate = video(from: entry) else { continue }
            positioned.append((json.range(of: "\"\(candidate.id)\"")?.lowerBound, candidate))
        }

        return positioned
            .sorted { first, second in
                switch (first.offset, second.offset) {
                case let (a?, b?): return a < b
                // An id the page did not spell out (a bare id, or a title that
                // repeated it) is ordered last rather than dropped: the video is
                // real, and losing it over a sort key would be worse.
                case (nil, _?): return false
                case (_?, nil): return true
                default: return false
                }
            }
            .map(\.video)
    }

    /// Depth-first walk, collecting every node that holds a video entry.
    ///
    /// Three renderers, because YouTube's page formats have churned: the classic
    /// `playlistVideoRenderer` and `playlistPanelVideoRenderer` (which carry the
    /// same fields), and the modern `lockupViewModel`. Reading all three means a
    /// page is parsed whichever shape it arrives in, rather than the reader being
    /// told their public playlist is unreadable.
    private static func collect(_ node: Any, into out: inout [[String: Any]]) {
        if let dictionary = node as? [String: Any] {
            for key in ["playlistVideoRenderer", "playlistPanelVideoRenderer", "lockupViewModel"] {
                if let entry = dictionary[key] as? [String: Any] { out.append(entry) }
            }
            for value in dictionary.values { collect(value, into: &out) }
        } else if let array = node as? [Any] {
            for value in array { collect(value, into: &out) }
        }
    }

    /// One entry → a `LibraryVideo`; nil when it is not playable (a private or
    /// deleted video has no id).
    private static func video(from entry: [String: Any]) -> LibraryVideo? {
        // `lockupViewModel` names the id `contentId`; the older renderers `videoId`.
        let videoId = (entry["videoId"] as? String ?? entry["contentId"] as? String)?.trimmed ?? ""
        guard !videoId.isEmpty else { return nil }
        // A lockup that is not a video (a channel, a shelf) has an id too, so the
        // kind is only trustworthy as a filter when the page states one.
        if let type = entry["contentType"] as? String, type != "LOCKUP_CONTENT_TYPE_VIDEO" { return nil }
        guard entry["isPlayable"] as? Bool ?? true else { return nil }

        let title = title(of: entry)
        let channel = channel(of: entry)
        var video = LibraryVideo(
            id: videoId,
            title: title.isEmpty ? "YouTube video" : title,
            channel: channel.isEmpty ? "YouTube" : channel,
            url: "https://www.youtube.com/watch?v=\(videoId)",
            thumbnail: thumbnail(of: entry)
        )
        video.durationSeconds = duration(of: entry)
        return video
    }

    /// The title, from either generation: `title.runs[0].text` / `simpleText`, or
    /// a lockup's `metadata.lockupMetadataViewModel.title.content`.
    private static func title(of entry: [String: Any]) -> String {
        let modern = entry["metadata"] as? [String: Any]
        let lockup = modern?["lockupMetadataViewModel"] as? [String: Any]
        let content = (lockup?["title"] as? [String: Any])?["content"] as? String
        return (content ?? text(of: entry["title"]) ?? "").trimmed
    }

    /// The channel, from either generation: the byline, or a lockup's avatar
    /// accessibility label ("Go to channel X").
    private static func channel(of entry: [String: Any]) -> String {
        let byline = text(of: entry["shortBylineText"]) ?? text(of: entry["longBylineText"])
        if let byline, !byline.trimmed.isEmpty { return byline.trimmed }
        let modern = entry["metadata"] as? [String: Any]
        let lockup = modern?["lockupMetadataViewModel"] as? [String: Any]
        let avatar = lockup?["image"] as? [String: Any]
        let decorated = avatar?["decoratedAvatarViewModel"] as? [String: Any]
        let label = (decorated?["a11yLabel"] as? String)?.trimmed ?? ""
        return label.replacingOccurrences(of: "Go to channel ", with: "").trimmed
    }

    /// The largest thumbnail the page offers.
    private static func thumbnail(of entry: [String: Any]) -> String? {
        let modern = entry["contentImage"] as? [String: Any]
        let viewModel = modern?["thumbnailViewModel"] as? [String: Any]
        let image = viewModel?["image"] as? [String: Any]
        if let sources = image?["sources"] as? [[String: Any]] {
            let urls = sources.compactMap { $0["url"] as? String }.filter { !$0.isEmpty }
            // `sources` ascends in size, so the last is the sharpest.
            if let best = urls.last { return best }
        }
        let classic = entry["thumbnail"] as? [String: Any]
        let thumbnails = classic?["thumbnails"] as? [[String: Any]]
        return thumbnails?.compactMap { $0["url"] as? String }.last
    }

    /// The clip's length in seconds: a classic `lengthText`, or a lockup's badge
    /// text (which is where a modern page states it).
    private static func duration(of entry: [String: Any]) -> Int64 {
        if let text = text(of: entry["lengthText"]), let seconds = clock(text) { return seconds }
        let modern = entry["contentImage"] as? [String: Any]
        let viewModel = modern?["thumbnailViewModel"] as? [String: Any]
        let overlays = viewModel?["overlays"] as? [[String: Any]] ?? []
        for overlay in overlays {
            let bottom = overlay["thumbnailBottomOverlayViewModel"] as? [String: Any]
            let badges = bottom?["badges"] as? [[String: Any]] ?? []
            for badge in badges {
                let model = badge["thumbnailBadgeViewModel"] as? [String: Any]
                if let text = model?["text"] as? String, let seconds = clock(text) { return seconds }
            }
        }
        return 0
    }

    /// `run`/`simpleText` text out of a YouTube text object.
    private static func text(of value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        if let simple = object["simpleText"] as? String { return simple }
        if let runs = object["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        if let content = object["content"] as? String { return content }
        return nil
    }

    /// `3:55` / `1:02:03` → seconds.
    private static func clock(_ raw: String) -> Int64? {
        let parts = raw.trimmed.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total: Int64 = 0
        for part in parts {
            guard let value = Int64(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }
}


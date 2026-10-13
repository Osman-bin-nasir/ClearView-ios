import Foundation

/// Parses YouTube's per-channel RSS feed
/// (`https://www.youtube.com/feeds/videos.xml?channel_id=UC…`) into a flat list of
/// `MediaVideo`.
///
/// The port of the Android parser, and a pure function of the XML — no network, no
/// cache, no screen — so the feed's shape can be tested against a captured document
/// instead of against YouTube.
///
/// Parsing is defensive in the same two ways: a malformed *entry* is skipped rather
/// than failing the feed, and an unparseable *body* returns an empty list. A channel
/// whose feed the app cannot read shows as a channel with nothing new, never as an
/// error the user has to clear.
enum YouTubeRssParser {

    /// The thumbnail to use when the feed omits `media:thumbnail`.
    static func fallbackThumbnail(videoId: String) -> String {
        "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"
    }

    /// Live broadcasts use a distinct thumbnail (`…/hqdefault_live.jpg`,
    /// `…/maxresdefault_live.jpg`). The feed carries no duration or live flag, so this
    /// is the signal.
    static let liveThumbnailMarker = "_live."

    /// Parses `rssXml` into videos, in feed order.
    ///
    /// Shorts classification, in priority order — Android's, and the order matters:
    ///
    ///  1. The entry's `<link rel="alternate">` href, which is YouTube's **own** label.
    ///     Shorts are canonicalised to `https://www.youtube.com/shorts/{id}`; every other
    ///     upload — long videos *and* live broadcasts — is `/watch?v={id}`. Because it is
    ///     authoritative, a live stream's id can never be mistaken for a Short even when
    ///     it leaks into the `/shorts` scrape (a channel's Shorts page carries the
    ///     currently-live broadcast in its shelf data).
    ///  2. Only when the feed omits the link: the `#shorts` hashtag in the title, or the
    ///     id appearing in `shortsIds` — but never for a live broadcast.
    static func parse(_ rssXml: String, shortsIds: Set<String> = []) -> [MediaVideo] {
        guard let data = rssXml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        // Raw input from the network: never resolve an external entity, whoever wrote it.
        parser.shouldResolveExternalEntities = false
        let delegate = EntryCollector()
        parser.delegate = delegate
        guard parser.parse() else { return [] }

        return delegate.entries.compactMap { entry -> MediaVideo? in
            let videoId = entry.videoId.trimmed
            // An entry without an id is not a video: nothing could open it.
            guard !videoId.isEmpty else { return nil }

            let thumbnail = entry.thumbnail.trimmed.isEmpty
                ? fallbackThumbnail(videoId: videoId)
                : entry.thumbnail.trimmed
            let isLive = thumbnail.lowercased().contains(liveThumbnailMarker)
            let alternateLink = entry.alternateLink.trimmed
            let title = entry.title.trimmed

            let isShort: Bool
            if alternateLink.lowercased().contains("/shorts/") {
                isShort = true
            } else if !alternateLink.isEmpty {
                isShort = false
            } else if isLive {
                isShort = false
            } else {
                isShort = MediaVideo.isShortsTitle(title) || shortsIds.contains(videoId)
            }

            return MediaVideo(
                videoId: videoId,
                title: title,
                channelId: entry.channelId.trimmed,
                channelName: entry.channelName.trimmed,
                publishedAtEpochMillis: parsePublished(entry.published.trimmed),
                thumbnailUrl: thumbnail,
                viewCount: max(entry.views, 0),
                isShort: isShort,
                isLive: isLive
            )
        }
    }

    /// YouTube's ISO-8601 `published` stamp (`2024-01-01T12:00:00+00:00`), or 0 when it
    /// is missing or unreadable.
    ///
    /// 0 rather than nil because a video with no known date is still a video: it sorts as
    /// the oldest thing in the feed, which is the honest place for it.
    static func parsePublished(_ raw: String) -> Int64 {
        guard !raw.isEmpty else { return 0 }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: raw) else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1000)
    }
}

/// Collects the first occurrence of each field of interest inside every `<entry>`.
///
/// `XMLParser` is a streaming parser, so "the first descendant named X" is done by
/// tracking which element is open: the first value seen for a name inside an entry wins,
/// which is exactly what the Android DOM walk does (`getElementsByTagName` returns the
/// document order). That matters for `<title>`: the plain one comes before
/// `<media:title>`, and either would read the same here, but for a feed where they
/// disagreed the entry's own title is the right answer.
private final class EntryCollector: NSObject, XMLParserDelegate {

    struct Entry {
        var videoId = ""
        var title = ""
        var channelId = ""
        var channelName = ""
        var published = ""
        var thumbnail = ""
        var views: Int64 = 0
        var alternateLink = ""
    }

    private(set) var entries: [Entry] = []
    private var current: Entry?
    /// The element whose text we are currently inside, or nil when the text is not
    /// wanted.
    private var capturing: String?
    private var buffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = localName(elementName, qName: qName)
        switch name {
        case "entry":
            current = Entry()
        case "videoId", "title", "channelId", "name", "published":
            // Only the entry's own fields: the feed has a <title> and a <name> for the
            // channel itself, before any <entry>.
            if current != nil {
                capturing = name
                buffer = ""
            }
        case "link":
            if current != nil,
               let rel = attributeDict["rel"], rel.lowercased().contains("alternate"),
               current?.alternateLink.isEmpty == true,
               let href = attributeDict["href"]?.trimmed, !href.isEmpty {
                current?.alternateLink = href
            }
        case "thumbnail":
            if current != nil, current?.thumbnail.isEmpty == true,
               let url = attributeDict["url"]?.trimmed, !url.isEmpty {
                current?.thumbnail = url
            }
        case "statistics":
            if current != nil, current?.views == 0,
               let views = attributeDict["views"], let value = Int64(views.trimmed) {
                current?.views = value
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capturing != nil else { return }
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName, qName: qName)
        if name == "entry" {
            if let entry = current { entries.append(entry) }
            current = nil
            capturing = nil
            buffer = ""
            return
        }
        guard let capturing, capturing == name, var entry = current else { return }
        switch name {
        case "videoId": if entry.videoId.isEmpty { entry.videoId = buffer }
        case "title": if entry.title.isEmpty { entry.title = buffer }
        case "channelId": if entry.channelId.isEmpty { entry.channelId = buffer }
        case "name": if entry.channelName.isEmpty { entry.channelName = buffer }
        case "published": if entry.published.isEmpty { entry.published = buffer }
        default: break
        }
        current = entry
        self.capturing = nil
        buffer = ""
    }

    /// The element's local name. `XMLParser` hands over the qualified name for a
    /// namespaced document, and the feed uses prefixes (`yt:videoId`, `media:thumbnail`);
    /// Android matched on the local name, so this does too.
    private func localName(_ elementName: String, qName: String?) -> String {
        let name = qName ?? elementName
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }
}

import Foundation

/// Where a media item came from.
enum MediaPlatform: String, CaseIterable, Codable {
    case youTube = "YOUTUBE"
    case instagram = "INSTAGRAM"
    case x = "X"

    var label: String {
        switch self {
        case .youTube: return "YouTube"
        case .instagram: return "Instagram"
        case .x: return "X"
        }
    }
}

/// The kind of an Instagram item, when the source said.
///
/// Kept as an optional on the item rather than folded into a single "is a video"
/// flag, because the caller has to tell a Reel from a *post that contains a video
/// clip*: an image carousel with one video slide is still a post, and treating it as
/// a Reel is what put photos in the Reels row.
enum InstagramMediaType: String, CaseIterable, Codable {
    case reel = "REEL"
    case image = "IMAGE"
    case video = "VIDEO"
    case carousel = "CAROUSEL"
}

/// One item in the Media feed: a YouTube upload from a channel's RSS feed, an
/// Instagram item, or an X post.
///
/// The Swift shape of the Android `MediaVideo`, field for field, because the parsers,
/// the filters and the cache JSON all have to agree with it.
struct MediaVideo: Identifiable, Equatable {

    let videoId: String
    let title: String
    let channelId: String
    let channelName: String
    let publishedAtEpochMillis: Int64
    let thumbnailUrl: String
    let viewCount: Int64
    /// True when the upload is a Short: set by the parser from the `#shorts` hashtag
    /// or from the channel's `/shorts` tab, and persisted in the cache.
    let isShort: Bool
    /// True when the upload is a live broadcast. The RSS feed carries no duration, so
    /// the parser keys off the live thumbnail. Live broadcasts are never Shorts and are
    /// excluded from watch-progress tracking — a live stream has no finite length to
    /// mark watched.
    let isLive: Bool
    /// Length in seconds, or 0 when unknown. The RSS feed omits durations, so this is
    /// resolved per video from the watch page and cached; the feed card shows it as a
    /// badge.
    let durationSeconds: Int64
    /// True when this entry is the *downloaded audio* of the video, added to a user
    /// playlist, rather than the video itself. It keeps the same `videoId`, so a
    /// playlist can hold both side by side and tapping one opens the player while the
    /// other plays the local file.
    let isOfflineAudio: Bool
    let platform: MediaPlatform
    let instagramType: InstagramMediaType?
    let mediaUrl: String?
    let instagramUrl: String?
    /// Original permalink for non-YouTube sources such as X.
    let sourceUrl: String?
    /// The post's **full** text — the whole tweet body or caption, never truncated.
    /// `title` is only the short label a feed card shows, so a post used to be
    /// readable up to that label and no further. Empty for videos, which have a title
    /// instead.
    let bodyText: String

    init(
        videoId: String,
        title: String,
        channelId: String,
        channelName: String,
        publishedAtEpochMillis: Int64,
        thumbnailUrl: String,
        viewCount: Int64 = 0,
        isShort: Bool = false,
        isLive: Bool = false,
        durationSeconds: Int64 = 0,
        isOfflineAudio: Bool = false,
        platform: MediaPlatform = .youTube,
        instagramType: InstagramMediaType? = nil,
        mediaUrl: String? = nil,
        instagramUrl: String? = nil,
        sourceUrl: String? = nil,
        bodyText: String = ""
    ) {
        self.videoId = videoId
        self.title = title
        self.channelId = channelId
        self.channelName = channelName
        self.publishedAtEpochMillis = publishedAtEpochMillis
        self.thumbnailUrl = thumbnailUrl
        self.viewCount = viewCount
        self.isShort = isShort
        self.isLive = isLive
        self.durationSeconds = durationSeconds
        self.isOfflineAudio = isOfflineAudio
        self.platform = platform
        self.instagramType = instagramType
        self.mediaUrl = mediaUrl
        self.instagramUrl = instagramUrl
        self.sourceUrl = sourceUrl
        self.bodyText = bodyText
    }

    /// The identity used for `Identifiable` and for de-duplicating rows.
    ///
    /// Not the bare `videoId`: a user playlist may deliberately hold a video *and* its
    /// offline audio, which share one id, and identifying both by the id would collapse
    /// the pair into a single row.
    var id: String { isOfflineAudio ? "\(videoId)#audio" : videoId }

    // MARK: - Platform and content type

    /// True for any Instagram item. The legacy `ig_` id prefix is accepted as well as
    /// the platform tag, because older caches and manually added posts carry only the id.
    var isInstagram: Bool {
        platform == .instagram || videoId.hasPrefix("ig_")
    }

    /// True for an Instagram item that carries moving pictures — a Reel or a video
    /// post. These play in the native player exactly like a YouTube video; only
    /// image/carousel posts render as stills.
    ///
    /// The **type** decides, and it decides both ways: a post that merely *contains* a
    /// video clip is still a post, because the Videos section is for Reels and videos
    /// only. Only when the source gave no type at all is a progressive video URL
    /// accepted as evidence.
    var isInstagramVideo: Bool {
        guard isInstagram else { return false }
        switch instagramType {
        case .reel, .video: return true
        case .image, .carousel: return false
        case nil: return mediaUrl?.contains(".mp4") == true
        }
    }

    /// A still Instagram post — shown as a tile rather than played.
    var isInstagramImage: Bool { isInstagram && !isInstagramVideo }

    /// True when `mediaUrl` is a directly playable stream.
    var hasPlayableVideo: Bool {
        guard let url = mediaUrl?.lowercased() else { return false }
        return url.contains(".mp4") || url.contains(".m3u8")
            || url.contains(".webm") || url.contains(".m4v")
    }

    /// A text or photo **post** rather than playable media: an X tweet with no video
    /// attached, or an Instagram photo/carousel.
    ///
    /// Posts render as post cards and open the full-post viewer; everything else opens
    /// a player. Rendering every non-YouTube item as a video card is what made X and
    /// Instagram posts look like videos with a broken thumbnail.
    var isPost: Bool {
        if isInstagramImage { return true }
        if platform == .x { return !hasPlayableVideo }
        return false
    }

    /// True when this item belongs in the Shorts row and viewer.
    ///
    /// Shorts are a YouTube concept: an Instagram Reel is an ordinary video here (it
    /// gets resume and Continue Watching like any long video). Older caches stored
    /// `isShort = true` for Reels, hence the platform guard.
    var isShortsEntry: Bool { isShort && !isInstagram }

    /// The `#shorts` hashtag signal, from a title alone.
    ///
    /// Word-bounded so `#shortsy` or `#shortsfortruth` do not match, and `#short` alone
    /// (a common word in long-video titles) never does. Written as plain string
    /// scanning rather than a regex on purpose, matching Android: a word-boundary
    /// pattern has to be escaped correctly at every layer that touches it, and getting
    /// that wrong is a silent behavioural difference between the two apps.
    static func isShortsTitle(_ title: String) -> Bool {
        let tag = "#shorts"
        let lowerTitle = title.lowercased()
        var searchStart = lowerTitle.startIndex
        while let found = lowerTitle.range(of: tag, range: searchStart..<lowerTitle.endIndex) {
            let after = found.upperBound
            if after == lowerTitle.endIndex {
                return true
            }
            let next = lowerTitle[after]
            if !next.isLetter && !next.isNumber && next != "_" {
                return true
            }
            searchStart = lowerTitle.index(after: found.lowerBound)
        }
        return false
    }
}

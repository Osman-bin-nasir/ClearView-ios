import Foundation

/// Date presets for the All Feed (`custom` uses the picked range).
enum FeedDateFilter: String, CaseIterable {
    case allTime = "ALL_TIME"
    case today = "TODAY"
    case last3Days = "LAST_3_DAYS"
    case last7Days = "LAST_7_DAYS"
    case last30Days = "LAST_30_DAYS"
    case custom = "CUSTOM"

    var label: String {
        switch self {
        case .allTime: return "All time"
        case .today: return "Today"
        case .last3Days: return "Last 3 days"
        case .last7Days: return "Last 7 days"
        case .last30Days: return "Last 30 days"
        case .custom: return "Custom date range"
        }
    }
}

/// Content-type filter for the All Feed.
///
/// `downloads` switches the feed body to the offline Downloads section: the filter
/// sheet handles that, and `applyFeedFilter` treats it as matching nothing because the
/// feed list is bypassed entirely.
enum FeedContentFilter: String, CaseIterable {
    case all = "ALL"
    case videos = "VIDEOS"
    case shorts = "SHORTS"
    case live = "LIVE"
    case downloads = "DOWNLOADS"
    case reels = "REELS"
    case imagePosts = "IMAGE_POSTS"

    var label: String {
        switch self {
        case .all: return "All"
        case .videos: return "Videos"
        case .shorts: return "Shorts"
        case .live: return "Live"
        case .downloads: return "Downloads"
        case .reels: return "Reels"
        case .imagePosts: return "Image Posts"
        }
    }
}

enum FeedPlatformFilter: String, CaseIterable {
    case all = "ALL"
    case youTube = "YOUTUBE"
    case instagram = "INSTAGRAM"
    case x = "X"

    var label: String {
        switch self {
        case .all: return "All"
        case .youTube: return "YouTube"
        case .instagram: return "Instagram"
        case .x: return "X"
        }
    }

    var platform: MediaPlatform? {
        switch self {
        case .all: return nil
        case .youTube: return .youTube
        case .instagram: return .instagram
        case .x: return .x
        }
    }
}

/// Sort order for the All Feed.
enum FeedSortOrder: String, CaseIterable {
    case newestFirst = "NEWEST_FIRST"
    case oldestFirst = "OLDEST_FIRST"

    var label: String {
        switch self {
        case .newestFirst: return "Newest first"
        case .oldestFirst: return "Oldest first"
        }
    }
}

/// Where each item came from.
///
/// `byUrl` is what the user added by hand; `system` is what the app pulled from the
/// saved channels. `byRss` is the playlist-only wording of exactly those channel-feed
/// items, and inside a user playlist `system` is presented as "From device" — the audio
/// files the user imported.
enum FeedSourceFilter: String, CaseIterable {
    case all = "ALL"
    case byUrl = "BY_URL"
    case byRss = "BY_RSS"
    case system = "SYSTEM"

    var label: String {
        switch self {
        case .all: return "All"
        case .byUrl: return "By URL"
        case .byRss: return "By RSS"
        case .system: return "From channels"
        }
    }
}

/// Media-type filter used **inside user playlists**: a playlist can hold both YouTube
/// videos and audio imported from the device.
enum PlaylistTypeFilter: String, CaseIterable {
    case all = "ALL"
    case video = "VIDEO"
    case audio = "AUDIO"

    var label: String {
        switch self {
        case .all: return "All"
        case .video: return "Video"
        case .audio: return "Audio"
        }
    }
}

/// Watch-status filter for the All Feed, combinable with the date filter.
enum FeedWatchStatus: String, CaseIterable {
    case all = "ALL"
    case watched = "WATCHED"
    case unwatched = "UNWATCHED"
    case partiallyWatched = "PARTIALLY_WATCHED"

    var label: String {
        switch self {
        case .all: return "All"
        case .watched: return "Watched"
        case .unwatched: return "Unwatched"
        case .partiallyWatched: return "Partially watched"
        }
    }
}

/// The Media tab's All Feed filters.
///
/// Defaults match Android: Last 3 days, all platforms, all content, newest first, and
/// **unwatched** watch status — the feed leads with what the user has not seen rather
/// than everything mixed together.
///
/// `customStartEpochMillis` / `customEndEpochMillis` apply only when `date` is
/// `.custom`, and both are *local* start-of-day instants.
struct FeedFilter: Equatable {
    var date: FeedDateFilter = .last3Days
    var platform: FeedPlatformFilter = .all
    var content: FeedContentFilter = .all
    var sort: FeedSortOrder = .newestFirst
    var watchStatus: FeedWatchStatus = .unwatched
    var source: FeedSourceFilter = .all
    var playlistType: PlaylistTypeFilter = .all
    var customStartEpochMillis: Int64?
    var customEndEpochMillis: Int64?

    /// True when anything differs from the defaults — what drives the "filters are
    /// active" indicator on the feed.
    ///
    /// The custom range is deliberately *not* part of this: it only means anything when
    /// the date is `.custom`, which already differs from the default.
    var isActive: Bool {
        date != .last3Days
            || platform != .all
            || content != .all
            || sort != .newestFirst
            || watchStatus != .unwatched
            || source != .all
            || playlistType != .all
    }

    /// True when the user narrowed the feed to a date range of their own choosing.
    var hasCustomRange: Bool {
        date == .custom && customStartEpochMillis != nil && customEndEpochMillis != nil
    }
}

/// The feed filter's rules: matching, ordering, persistence and the one-line summary.
///
/// The port of Android's `media/util/FeedFilters.kt`, kept pure so the whole feed can be
/// tested without a network, a DB or a screen — which matters more here than anywhere
/// else in the Media tab, because "why is this video missing?" is almost always a filter
/// question.
enum FeedFilters {

    /// The fraction at or above which a video counts as fully watched. Must match
    /// `WatchProgressStore.watchedThreshold`.
    static let watchedFractionThreshold: Float = 0.9
    /// The minimum fraction for a video to count as meaningfully started.
    static let startedFractionThreshold: Float = 0.02
    /// How the UI words `system` inside a user playlist.
    static let deviceSourceLabel = "From device"

    private static let dayMillis: Int64 = 24 * 60 * 60 * 1000

    /// Applies `filter` to `videos` **purely locally** — never a refetch, only the
    /// already-loaded list — using `now` as the reference for the relative presets.
    ///
    /// Filtering uses each item's real publication time. `progressOf` reports the watched
    /// fraction (0…1, nil = never started) and `isManual` whether an item was added by
    /// URL; both are closures so the caller can supply them from its own stores, and both
    /// default to "unknown", which is the state the filter treats as *unstarted* and
    /// *not manual*.
    static func apply(
        _ videos: [MediaVideo],
        filter: FeedFilter,
        now: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        progressOf: (String) -> Float? = { _ in nil },
        isManual: (String) -> Bool = { _ in false }
    ) -> [MediaVideo] {
        let start: Int64?
        switch filter.date {
        case .allTime: start = nil
        case .today: start = startOfDayEpochMillis(now)
        case .last3Days: start = now - dayMillis * 3
        case .last7Days: start = now - dayMillis * 7
        case .last30Days: start = now - dayMillis * 30
        case .custom: start = filter.customStartEpochMillis
        }
        let end = filter.date == .custom ? filter.customEndEpochMillis : nil

        let filtered = videos.filter { video in
            if let start, video.publishedAtEpochMillis < start { return false }
            if let end, video.publishedAtEpochMillis > end { return false }
            guard matchesContent(video, filter: filter) else { return false }
            guard matchesWatchStatus(video, filter: filter, progressOf: progressOf) else { return false }
            return matchesSource(video, filter: filter, isManual: isManual)
        }

        // Sorted with the input position as the tie-break: Swift's sort is not stable,
        // and two videos published in the same second would otherwise swap places
        // between redraws (Android's `sortedBy` is stable, so this also keeps the two
        // platforms showing the same order for the same list).
        return filtered.enumerated()
            .sorted { first, second in
                let a = first.element.publishedAtEpochMillis
                let b = second.element.publishedAtEpochMillis
                if a == b { return first.offset < second.offset }
                return filter.sort == .newestFirst ? a > b : a < b
            }
            .map(\.element)
    }

    /// Platform **and** content type. The two are checked together because most content
    /// types are platform-specific: "Shorts" means YouTube Shorts, not an Instagram Reel
    /// that happens to be short.
    private static func matchesContent(_ video: MediaVideo, filter: FeedFilter) -> Bool {
        if let platform = filter.platform.platform, video.platform != platform { return false }
        switch filter.content {
        case .all:
            return true
        case .videos:
            return !video.isShort && video.platform == .youTube
        case .shorts:
            return video.isShort && video.platform == .youTube
        case .live:
            return video.isLive
        case .reels:
            // Reels are Instagram *video* items; posts are everything else Instagram —
            // photo posts and carousels, even one with a video slide. Both go through
            // the same rule the feed itself uses rather than re-deriving it from
            // `isShort`, which the parsers set for any video-ish post and which is what
            // let posts appear under Reels.
            return video.isInstagramVideo
        case .imagePosts:
            return video.isInstagramImage
        case .downloads:
            // Handled by the screen, which swaps the feed body for the Downloads
            // section; a Downloads *filter* matches nothing in the feed list itself.
            return false
        }
    }

    private static func matchesWatchStatus(
        _ video: MediaVideo,
        filter: FeedFilter,
        progressOf: (String) -> Float?
    ) -> Bool {
        let progress = progressOf(video.videoId)
        switch filter.watchStatus {
        case .all:
            return true
        case .watched:
            return (progress ?? 0) >= watchedFractionThreshold
        case .unwatched:
            return progress == nil || progress! < startedFractionThreshold
        case .partiallyWatched:
            guard let progress else { return false }
            return progress >= startedFractionThreshold && progress < watchedFractionThreshold
        }
    }

    private static func matchesSource(
        _ video: MediaVideo,
        filter: FeedFilter,
        isManual: (String) -> Bool
    ) -> Bool {
        switch filter.source {
        case .all:
            return true
        case .byUrl:
            return isManual(video.videoId)
        case .system, .byRss:
            // "By RSS" is offered inside user playlists; in the All Feed it means the
            // same channel-feed items as "From channels".
            return !isManual(video.videoId)
        }
    }

    // MARK: - Relative dates

    /// Local midnight of the day `epochMillis` falls on.
    ///
    /// "Today" has to mean the user's today, not the last 24 hours: a feed that says
    /// "Today" and hides a video posted at 11 pm last night is a feed that lies.
    static func startOfDayEpochMillis(_ epochMillis: Int64) -> Int64 {
        let calendar = Calendar.current
        let date = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000)
        let start = calendar.startOfDay(for: date)
        return Int64(start.timeIntervalSince1970 * 1000)
    }

    /// Converts a date picker's UTC-midnight instant into the **local** start of the
    /// same day, so a picked range covers the whole local day.
    ///
    /// SwiftUI's date pickers report a date rather than an instant, and the bridges to
    /// and from `Date` run through UTC midnight on several platforms — Android's
    /// Material picker does exactly this, and the conversion exists here for the same
    /// reason it exists there: without it, a range ends an offset's worth of hours early
    /// and clips the last posts of the day.
    static func datePickerMillisToLocalStart(_ utcMidnightMillis: Int64) -> Int64 {
        let offset = TimeZone.current.secondsFromGMT(
            for: Date(timeIntervalSince1970: TimeInterval(utcMidnightMillis) / 1000)
        ) * 1000
        return startOfDayEpochMillis(utcMidnightMillis + Int64(offset))
    }

    // MARK: - Persistence

    /// JSON for the filter, so the choice survives a relaunch.
    static func encode(_ filter: FeedFilter) -> String {
        let dictionary: [String: Any] = [
            "date": filter.date.rawValue,
            "platform": filter.platform.rawValue,
            "content": filter.content.rawValue,
            "sort": filter.sort.rawValue,
            "watchStatus": filter.watchStatus.rawValue,
            "source": filter.source.rawValue,
            "playlistType": filter.playlistType.rawValue,
            "customStart": filter.customStartEpochMillis.map { $0 as Any } ?? NSNull(),
            "customEnd": filter.customEndEpochMillis.map { $0 as Any } ?? NSNull(),
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    /// Decodes a stored filter, or nil when it is missing or unusable so the caller
    /// falls back to the default.
    ///
    /// The migrations are the interesting part, and they are Android's:
    ///  - the `date` and `content` enums must be recognised, or the filter is rejected
    ///    outright (an unreadable filter is a filter the user cannot see or clear);
    ///  - a stored `live` content filter is migrated to `all`, because Live was removed
    ///    from the sheet and an unreachable filter would silently lock the feed;
    ///  - `allTime` is deliberately **not** migrated: it is still a first-class option,
    ///    so a stored value is as likely to be the user's own choice as an old default;
    ///  - everything newer (watch status, source, playlist type) falls back to its
    ///    default when absent, so a value written by an older build still loads.
    static func decode(_ json: String?) -> FeedFilter? {
        guard let json, !json.trimmed.isEmpty, let data = json.data(using: .utf8) else { return nil }
        guard let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let date = FeedDateFilter(rawValue: dictionary["date"] as? String ?? "") else {
            return nil
        }
        let platform = FeedPlatformFilter(rawValue: dictionary["platform"] as? String ?? "") ?? .all
        guard var content = FeedContentFilter(rawValue: dictionary["content"] as? String ?? "") else {
            return nil
        }
        if content == .live { content = .all }
        guard let sort = FeedSortOrder(rawValue: dictionary["sort"] as? String ?? "") else {
            return nil
        }
        let watchStatus = FeedWatchStatus(rawValue: dictionary["watchStatus"] as? String ?? "") ?? .unwatched
        let source = FeedSourceFilter(rawValue: dictionary["source"] as? String ?? "") ?? .all
        let playlistType = PlaylistTypeFilter(rawValue: dictionary["playlistType"] as? String ?? "") ?? .all

        return FeedFilter(
            date: date,
            platform: platform,
            content: content,
            sort: sort,
            watchStatus: watchStatus,
            source: source,
            playlistType: playlistType,
            customStartEpochMillis: int64(dictionary["customStart"]),
            customEndEpochMillis: int64(dictionary["customEnd"])
        )
    }

    // MARK: - What each platform offers

    /// The content types `platform` offers, in the order the sheet shows them.
    ///
    /// A single source of truth rather than a decision inlined in the sheet, because
    /// switching platform has to reset a selection the new platform does not offer —
    /// Instagram → YouTube used to leave "Reels" selected, which is a filter with no chip
    /// to show it and a feed that matched nothing.
    static func contentOptions(for platform: FeedPlatformFilter) -> [FeedContentFilter] {
        switch platform {
        case .youTube:
            return [.all, .videos, .shorts, .downloads]
        case .instagram:
            return [.all, .reels, .imagePosts]
        case .x:
            return [.all]
        case .all:
            return FeedContentFilter.allCases.filter { $0 != .live }
        }
    }

    /// The filter with any content type the current platform does not offer reset to
    /// `all`.
    static func normalizedForPlatform(_ filter: FeedFilter) -> FeedFilter {
        guard !contentOptions(for: filter.platform).contains(filter.content) else { return filter }
        var normalized = filter
        normalized.content = .all
        return normalized
    }

    // MARK: - Human-readable summary

    /// The date in words: the preset's label, or the picked range when custom.
    static func dateLabel(_ filter: FeedFilter) -> String {
        guard filter.date == .custom else { return filter.date.label }
        guard let start = filter.customStartEpochMillis, let end = filter.customEndEpochMillis else {
            return "Custom"
        }
        return "\(shortDate(start)) – \(shortDate(end))"
    }

    /// The filter's active settings, in the order the sheet lists them, as one line:
    /// only the sections that differ from the defaults are named, so the line is empty
    /// at the defaults.
    ///
    /// `includeDefaultDate` forces the date in even when it is still the default: the
    /// feed header always states the window it is showing, because that context is
    /// worth a word; the sheet does not, since it shows the date as a row of its own.
    static func summary(
        _ filter: FeedFilter,
        playlistContext: Bool = false,
        includeDefaultDate: Bool = false,
        deviceSourceLabel: String = FeedFilters.deviceSourceLabel
    ) -> String {
        var parts: [String] = []
        if playlistContext {
            if filter.playlistType != .all { parts.append(filter.playlistType.label) }
            if filter.source != .all {
                parts.append(filter.source == .system ? deviceSourceLabel : filter.source.label)
            }
            return parts.joined(separator: " · ")
        }
        if includeDefaultDate || filter.date != .last3Days { parts.append(dateLabel(filter)) }
        if filter.platform != .all { parts.append(filter.platform.label) }
        if filter.content != .all { parts.append(filter.content.label) }
        if filter.source != .all { parts.append(filter.source.label) }
        if filter.watchStatus != .unwatched { parts.append(filter.watchStatus.label) }
        if filter.sort != .newestFirst { parts.append(filter.sort.label) }
        return parts.joined(separator: " · ")
    }

    /// The line under the feed heading: "Last 7 days · 24 videos".
    static func feedSummary(_ filter: FeedFilter, resultCount: Int) -> String {
        let parts = summary(filter, includeDefaultDate: true)
        let count = resultCount == 1 ? "1 video" : "\(resultCount) videos"
        return parts.isEmpty ? count : "\(parts) · \(count)"
    }

    private static func shortDate(_ millis: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(millis) / 1000))
    }

    private static func int64(_ value: Any?) -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.int64Value }
        return nil
    }
}

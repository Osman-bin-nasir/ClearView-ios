import Foundation
import Observation

struct LibraryVideo: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var channel: String
    var url: String
    var thumbnail: String?
    var isShort = false
    var publishedAt: Int64 = 0
    var channelID: String?
    var viewCount: Int64?
    var durationSeconds: Int64?
    var live: Bool?

    /// The source platform (`YOUTUBE`, `INSTAGRAM`, `X`).
    ///
    /// Optional so that libraries written before the Instagram and X feeds
    /// existed still decode; a missing value falls back to the URL's host, which
    /// is what the old code did for every item. It has to be *stored* rather than
    /// re-derived, because a non-YouTube item's `url` is its permalink and an
    /// Instagram permalink is indistinguishable from a saved link otherwise.
    var platform: String?
    /// The original permalink for Instagram and X items.
    var sourceURL: String?
    /// `InstagramMediaType` raw value, when the source said.
    var instagramType: String?
    /// The direct media URL (an Instagram or X mp4), when known.
    var mediaURL: String?
    /// The post's full text — the whole caption or tweet body.
    var bodyText: String?

    init(_ video: MediaVideo) {
        id = video.videoId
        title = video.title
        channel = video.channelName
        platform = video.platform.rawValue
        sourceURL = video.sourceUrl ?? video.instagramUrl
        instagramType = video.instagramType?.rawValue
        mediaURL = video.mediaUrl
        bodyText = video.bodyText
        // Only a YouTube item gets a watch URL synthesised from its id; any
        // other platform's id is not a YouTube id and minting one would make the
        // player try to play a video that does not exist.
        url = video.platform == .youTube
            ? "https://www.youtube.com/watch?v=\(video.videoId)"
            : (video.sourceUrl ?? video.instagramUrl ?? video.mediaUrl ?? "")
        thumbnail = video.thumbnailUrl.isEmpty ? nil : video.thumbnailUrl
        isShort = video.isShort
        publishedAt = video.publishedAtEpochMillis
        channelID = video.channelId
        viewCount = video.viewCount
        durationSeconds = video.durationSeconds
        live = video.isLive
    }

    init(id: String = UUID().uuidString, title: String, channel: String = "Saved link", url: String, thumbnail: String? = nil) {
        self.id = id
        self.title = title
        self.channel = channel
        self.url = url
        self.thumbnail = thumbnail
    }

    /// True when this item came from YouTube.
    var isYouTube: Bool { (platform ?? MediaPlatform.youTube.rawValue).uppercased() == MediaPlatform.youTube.rawValue }

    var mediaVideo: MediaVideo {
        let host = URL(string: url)?.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? ""
        let resolved: MediaPlatform = platform.flatMap(MediaPlatform.init(rawValue:))
            ?? (host == "instagram.com" ? .instagram : host == "x.com" || host == "twitter.com" ? .x : .youTube)
        return MediaVideo(videoId: id, title: title, channelId: channelID ?? "", channelName: channel,
            publishedAtEpochMillis: publishedAt, thumbnailUrl: thumbnail ?? "", viewCount: viewCount ?? 0,
            isShort: isShort, isLive: live ?? false, durationSeconds: durationSeconds ?? 0, platform: resolved,
            instagramType: instagramType.flatMap(InstagramMediaType.init(rawValue:)),
            mediaUrl: mediaURL,
            instagramUrl: resolved == .instagram ? sourceURL : nil,
            sourceUrl: sourceURL ?? url,
            bodyText: bodyText ?? "")
    }
}

struct MediaWatchProgress: Codable, Equatable {
    var position: Double
    var duration: Double
    var updatedAt: Date
    var dismissedFromContinue: Bool?

    var fraction: Float { duration > 0 ? Float(min(1, max(0, position / duration))) : 0 }
}

struct MediaPlaylist: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var videos: [LibraryVideo] = []
    var sourceURL: String?
}

struct MediaLibraryState: Codable {
    var channels: [DirectoryChannel] = []
    var playlists: [MediaPlaylist] = []
    var recent: [LibraryVideo] = []
    var saved: [LibraryVideo] = []
    var feed: [LibraryVideo] = []
    var hiddenVideoIDs: [String]?
    var hiddenChannelIDs: [String]?
    var watchProgress: [String: MediaWatchProgress]?
}

@MainActor
@Observable
final class MediaLibrary {
    var state: MediaLibraryState
    var directory = DirectorySnapshot()
    var loading = false
    var error: String?
    private let defaults: UserDefaults
    private let repository = GoodPostRepository()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let restored = defaults.data(forKey: "media.library.v1").flatMap({ try? JSONDecoder().decode(MediaLibraryState.self, from: $0) }) {
            state = restored
        } else {
            state = MediaLibraryState()
            state.channels = [DirectoryChannel(id: "UC2cX3SmsdWsrRS8t_5zvzEw", platform: "youtube", handle: "SafinaSociety",
                name: "Safina Society", iconUrl: nil, url: "https://www.youtube.com/channel/UC2cX3SmsdWsrRS8t_5zvzEw",
                categoryId: nil, subcategoryId: nil, sort: 0)]
            persist()
        }
    }

    func persist() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: "media.library.v1") }
    }

    func filteredVideos(_ filter: FeedFilter, channelID: String? = nil, query: String = "") -> [LibraryVideo] {
        guard filter.content != .downloads else { return [] }
        var seen = Set<String>()
        let combined = (state.feed + state.saved).filter { seen.insert($0.id).inserted }
        let hiddenVideos = Set(state.hiddenVideoIDs ?? [])
        let hiddenChannels = Set(state.hiddenChannelIDs ?? [])
        let visible = combined.filter { video in
            !hiddenVideos.contains(video.id) && (channelID != nil || !hiddenChannels.contains(video.channelID ?? ""))
                && (channelID == nil || video.channelID == channelID)
                && (query.isEmpty || video.title.localizedCaseInsensitiveContains(query) || video.channel.localizedCaseInsensitiveContains(query))
        }
        let filtered = FeedFilters.apply(visible.map(\.mediaVideo), filter: filter,
            progressOf: { self.state.watchProgress?[$0]?.fraction },
            isManual: { identifier in self.state.saved.contains { $0.id == identifier } && !self.state.feed.contains { $0.id == identifier } })
        let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        return filtered.compactMap { byID[$0.id] }
    }

    func hide(_ video: LibraryVideo) {
        if !(state.hiddenVideoIDs ?? []).contains(video.id) { state.hiddenVideoIDs = (state.hiddenVideoIDs ?? []) + [video.id] }
        persist()
    }

    func toggleChannelHidden(_ channel: DirectoryChannel) {
        var hidden = state.hiddenChannelIDs ?? []
        if hidden.contains(channel.id) { hidden.removeAll { $0 == channel.id } }
        else { hidden.append(channel.id) }
        state.hiddenChannelIDs = hidden
        persist()
    }

    func loadDirectory() async {
        if let cached = await repository.cachedDirectory() { directory = cached.snapshot }
        let response = await repository.directory()
        if let value = response.value { directory = value }
        else { error = response.userMessage }
        updateChannelMetadata()
    }

    private func updateChannelMetadata() {
        for index in state.channels.indices {
            let saved = state.channels[index]
            guard let resolved = directory.allChannels.first(where: {
                $0.platform.lowercased() == saved.platform.lowercased() && $0.handle.lowercased() == saved.handle.lowercased()
            }) else { continue }
            state.channels[index] = DirectoryChannel(id: saved.id, platform: saved.platform, handle: saved.handle,
                name: resolved.name ?? saved.name, iconUrl: resolved.iconUrl ?? saved.iconUrl, url: saved.url,
                categoryId: resolved.categoryId, subcategoryId: resolved.subcategoryId, sort: saved.sort)
        }
        persist()
    }

    var activeChannels: [DirectoryChannel] {
        var latest: [String: Int64] = [:]
        var counts: [String: Int] = [:]
        for video in state.feed {
            guard let channel = video.channelID else { continue }
            latest[channel] = max(latest[channel] ?? 0, video.publishedAt)
            counts[channel, default: 0] += 1
        }
        return state.channels.enumerated().sorted { first, second in
            let firstTime = latest[first.element.id] ?? 0
            let secondTime = latest[second.element.id] ?? 0
            if firstTime != secondTime { return firstTime > secondTime }
            let firstCount = counts[first.element.id] ?? 0
            let secondCount = counts[second.element.id] ?? 0
            if firstCount != secondCount { return firstCount > secondCount }
            return first.offset > second.offset
        }.map(\.element)
    }

    func refresh() async {
        if ProcessInfo.processInfo.arguments.contains("--uitesting"), ProcessInfo.processInfo.environment["CLEARVIEW_MEDIA_FIXTURE"] != nil { return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        error = nil
        await loadDirectory()
        let sources = state.channels
        guard !sources.isEmpty else {
            state.feed = []
            persist()
            return
        }
        var videos: [LibraryVideo] = []
        var failed = 0

        // YouTube concurrently: an RSS feed per channel, and the endpoints do
        // not mind a burst.
        let youtube = sources.filter { $0.platform == "youtube" }
        if !youtube.isEmpty {
            let results = await withTaskGroup(of: (String, [LibraryVideo]?).self) { group in
                for channel in youtube {
                    group.addTask { (channel.id, await Self.fetch(channel)) }
                }
                var collected: [(String, [LibraryVideo]?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (_, result) in results {
                if let result { videos += result } else { failed += 1 }
            }
        }

        // Instagram and X SEQUENTIALLY, deliberately. Both endpoints rate-limit
        // per IP and answer 429 to a burst, which is exactly what a profile per
        // channel fired at once produces — Android learned the same lesson and
        // made these sources sequential and memoised for the same reason. One
        // 429 also stands the whole source down for a few minutes, so a retry
        // here would only spend the request to be told the same thing.
        var fetchedOthers: [LibraryVideo] = []
        var firstFailure: String?
        for channel in sources where channel.platform != "youtube" {
            do {
                fetchedOthers += try await Self.fetchSource(channel)
            } catch {
                failed += 1
                // Keep the FIRST concrete reason. "1 channel feed couldn't
                // refresh" is not actionable on its own — the reader cannot tell
                // a typo'd handle from a throttled service from a video that was
                // deleted, and neither can whoever they ask for help.
                if firstFailure == nil {
                    firstFailure = "\(channel.displayName): \(error.localizedDescription)"
                }
            }
        }

        // YouTube is REPLACED (its feed is the channel's current uploads), while
        // Instagram and X ACCUMULATE: both hand back only the newest few posts,
        // so replacing would throw away everything older on every refresh. Keeping
        // the older items is how the feed grows past the embed's rolling window.
        let existingOthers = state.feed.filter { !$0.isYouTube }
        var seen = Set<String>()
        let merged = (videos + fetchedOthers + existingOthers).filter { seen.insert($0.id).inserted }
        if failed == 0 || !merged.isEmpty {
            state.feed = merged.sorted { $0.publishedAt > $1.publishedAt }
            persist()
        }
        if failed > 0 {
            error = "\(failed) channel feed\(failed == 1 ? "" : "s") couldn't refresh. "
                + (firstFailure ?? "You can still open channels directly.")
        }
    }

    /// Fetches a channel from whichever platform it belongs to, throwing the
    /// reason so the caller can report it rather than only counting it.
    nonisolated private static func fetchSource(_ channel: DirectoryChannel) async throws -> [LibraryVideo] {
        switch channel.platform.lowercased() {
        case "instagram":
            return try await InstagramSource().fetchProfile(channel.handle).items.map { LibraryVideo($0) }
        case "x", "twitter":
            return try await XSource().fetchProfile(channel.handle).items.map { LibraryVideo($0) }
        default:
            guard let videos = await fetch(channel) else { throw MediaFeedError.unusablePayload }
            return videos
        }
    }

    nonisolated private static func fetch(_ channel: DirectoryChannel) async -> [LibraryVideo]? {
        do {
            guard let pageURL = URL(string: channel.url), pageURL.host == "www.youtube.com" || pageURL.host == "youtube.com" else { return nil }
            var request = URLRequest(url: pageURL)
            request.timeoutInterval = 20
            let channelID: String
            if pageURL.path.hasPrefix("/channel/"), pageURL.lastPathComponent.hasPrefix("UC") {
                channelID = pageURL.lastPathComponent
            } else {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                let html = String(decoding: data, as: UTF8.self)
                let pattern = #"(?:channel_id=|/channel/|\"channelId\":\"|\"externalId\":\")(UC[A-Za-z0-9_-]{22})"#
                let regex = try NSRegularExpression(pattern: pattern)
                guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                      let range = Range(match.range(at: 1), in: html) else { return nil }
                channelID = String(html[range])
            }
            let feedURL = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)")!
            var feedRequest = URLRequest(url: feedURL)
            feedRequest.timeoutInterval = 20
            let (feed, feedResponse) = try await URLSession.shared.data(for: feedRequest)
            guard (feedResponse as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return YouTubeRssParser.parse(String(decoding: feed, as: UTF8.self)).map { source in
                var video = LibraryVideo(source)
                video.channelID = channel.id
                return video
            }
        } catch { return nil }
    }

    func subscribe(_ channel: DirectoryChannel) {
        if state.channels.contains(where: { $0.id == channel.id }) {
            state.channels.removeAll { $0.id == channel.id }
            state.hiddenChannelIDs?.removeAll { $0 == channel.id }
        }
        else { state.channels.append(channel) }
        persist()
    }

    func addChannel(url raw: String) -> Bool {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased().replacingOccurrences(of: "www.", with: "") else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let first = parts.first, !first.isEmpty else { return false }
        let platform: String
        switch host {
        case "youtube.com":
            guard first.hasPrefix("@") || (first == "channel" && parts.count == 2 && parts[1].hasPrefix("UC")) else { return false }
            platform = "youtube"
        case "instagram.com":
            guard parts.count == 1, !["p", "reel", "explore"].contains(first) else { return false }
            platform = "instagram"
        case "x.com", "twitter.com":
            guard parts.count == 1, !["home", "explore", "search"].contains(first) else { return false }
            platform = "x"
        default: return false
        }
        let handle = first == "channel" ? parts[1] : first.replacingOccurrences(of: "@", with: "")
        guard !state.channels.contains(where: { $0.platform == platform && $0.handle.lowercased() == handle.lowercased() }) else { return true }
        state.channels.append(DirectoryChannel(id: UUID().uuidString, platform: platform, handle: handle, name: handle,
            iconUrl: nil, url: url.absoluteString, categoryId: nil, subcategoryId: nil, sort: 0))
        persist()
        return true
    }

    func open(_ video: LibraryVideo) {
        state.recent.removeAll { $0.id == video.id }
        state.recent.insert(video, at: 0)
        state.recent = Array(state.recent.prefix(30))
        persist()
    }

    func recordProgress(_ video: LibraryVideo, position: Double, duration: Double) {
        guard video.live != true, position.isFinite, duration.isFinite, duration > 0, position > 0 else { return }
        if state.watchProgress == nil { state.watchProgress = [:] }
        state.watchProgress?[video.id] = MediaWatchProgress(position: min(position, duration), duration: duration, updatedAt: Date(), dismissedFromContinue: false)
        persist()
    }

    func add(_ video: LibraryVideo, to playlistID: String) {
        guard let index = state.playlists.firstIndex(where: { $0.id == playlistID }),
              !state.playlists[index].videos.contains(where: { $0.id == video.id }) else { return }
        state.playlists[index].videos.append(video)
        persist()
    }

    func toggleSave(_ video: LibraryVideo) {
        if state.saved.contains(where: { $0.id == video.id }) { state.saved.removeAll { $0.id == video.id } }
        else { state.saved.append(video) }
        persist()
    }

    func addLink(title: String, url: String) -> Bool {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else { return false }
        let videoID = YouTubeLink.videoId(from: url)
        let video = LibraryVideo(id: videoID ?? UUID().uuidString, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? parsed.host! : title,
            url: parsed.absoluteString, thumbnail: videoID.map { "https://i.ytimg.com/vi/\($0)/hqdefault.jpg" })
        if !state.saved.contains(where: { $0.url == video.url }) { state.saved.append(video) }
        persist()
        return true
    }
}

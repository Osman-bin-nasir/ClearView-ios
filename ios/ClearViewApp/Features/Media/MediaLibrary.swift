import Foundation
import Observation

struct LibraryVideo: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var channel: String
    var url: String
    var thumbnail: String?
    var isShort = false
    var publishedAt: Int64 = 0

    init(_ video: MediaVideo) {
        id = video.videoId
        title = video.title
        channel = video.channelName
        url = "https://www.youtube.com/watch?v=\(video.videoId)"
        thumbnail = video.thumbnailUrl
        isShort = video.isShort
        publishedAt = video.publishedAtEpochMillis
    }

    init(id: String = UUID().uuidString, title: String, channel: String = "Saved link", url: String, thumbnail: String? = nil) {
        self.id = id
        self.title = title
        self.channel = channel
        self.url = url
        self.thumbnail = thumbnail
    }
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
        state = defaults.data(forKey: "media.library.v1").flatMap { try? JSONDecoder().decode(MediaLibraryState.self, from: $0) } ?? MediaLibraryState()
    }

    func persist() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: "media.library.v1") }
    }

    func loadDirectory() async {
        if let cached = await repository.cachedDirectory() { directory = cached.snapshot }
        let response = await repository.directory()
        if let value = response.value { directory = value }
        else { error = response.userMessage }
    }

    func refresh() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        error = nil
        await loadDirectory()
        let sources = state.channels.filter { $0.platform == "youtube" }
        guard !sources.isEmpty else {
            state.feed = []
            persist()
            return
        }
        let results = await withTaskGroup(of: (String, [LibraryVideo]?).self) { group in
            for channel in sources {
                group.addTask { (channel.id, await Self.fetch(channel)) }
            }
            var collected: [(String, [LibraryVideo]?)] = []
            for await result in group { collected.append(result) }
            return collected
        }
        var videos: [LibraryVideo] = []
        var failed = 0
        for (_, result) in results {
            if let result { videos += result } else { failed += 1 }
        }
        if failed == 0 || !videos.isEmpty {
            var seen = Set<String>()
            state.feed = videos.filter { seen.insert($0.id).inserted }.sorted { $0.publishedAt > $1.publishedAt }
            persist()
        }
        if failed > 0 { error = "\(failed) channel feed\(failed == 1 ? "" : "s") couldn't refresh. You can still open channels directly." }
    }

    nonisolated private static func fetch(_ channel: DirectoryChannel) async -> [LibraryVideo]? {
        do {
            guard let pageURL = URL(string: channel.url), pageURL.host == "www.youtube.com" || pageURL.host == "youtube.com" else { return nil }
            var request = URLRequest(url: pageURL)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let html = String(decoding: data, as: UTF8.self)
            let pattern = #"(?:channel_id=|/channel/|\"channelId\":\"|\"externalId\":\")(UC[A-Za-z0-9_-]{22})"#
            let regex = try NSRegularExpression(pattern: pattern)
            guard let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            let channelID = String(html[range])
            let feedURL = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)")!
            var feedRequest = URLRequest(url: feedURL)
            feedRequest.timeoutInterval = 20
            let (feed, feedResponse) = try await URLSession.shared.data(for: feedRequest)
            guard (feedResponse as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return YouTubeRssParser.parse(String(decoding: feed, as: UTF8.self)).map(LibraryVideo.init)
        } catch { return nil }
    }

    func subscribe(_ channel: DirectoryChannel) {
        if state.channels.contains(where: { $0.id == channel.id }) { state.channels.removeAll { $0.id == channel.id } }
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

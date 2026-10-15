import XCTest
@testable import ClearView

@MainActor
final class MediaProfileRoutingTests: XCTestCase {
    func testExistingInstagramAndXItemsMigrateIntoTheirSubscribedProfiles() throws {
        let suite = "media-profile-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let instagram = channel(id: "directory-instagram-123", platform: "instagram", handle: "Example")
        let x = channel(id: "custom-uuid", platform: "twitter", handle: "Example")
        let reel = LibraryVideo(item(id: "ig_one", owner: "ig_example", platform: .instagram, type: .reel))
        let tweet = LibraryVideo(item(id: "x_one", owner: "x_example", platform: .x))
        var state = MediaLibraryState()
        state.channels = [instagram, x]
        state.feed = [reel, tweet]
        state.saved = [reel]
        state.recent = [tweet]
        state.playlists = [MediaPlaylist(name: "Saved", videos: [reel, tweet])]
        state.hiddenChannelIDs = ["ig_example"]
        defaults.set(try JSONEncoder().encode(state), forKey: "media.library.v1")
        let library = MediaLibrary(defaults: defaults)
        XCTAssertEqual(library.state.feed.map(\.channelID), [instagram.id, x.id])
        XCTAssertEqual(library.state.saved.first?.channelID, instagram.id)
        XCTAssertEqual(library.state.recent.first?.channelID, x.id)
        XCTAssertEqual(library.state.playlists.first?.videos.map(\.channelID), [instagram.id, x.id])
        XCTAssertEqual(library.state.hiddenChannelIDs, [instagram.id])
        let all = FeedFilter(date: .allTime, watchStatus: .all)
        XCTAssertEqual(library.filteredVideos(all, channelID: instagram.id).map(\.id), ["ig_one"])
        XCTAssertEqual(library.filteredVideos(all, channelID: x.id).map(\.id), ["x_one"])
    }

    func testRefreshRetainsTheSubscriptionIDAndStoresProfileNameAndAvatar() async throws {
        let suite = "media-profile-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = channel(id: "random-subscription-id", platform: "instagram", handle: "Example")
        let source = item(id: "ig_one", owner: "ig_example", platform: .instagram, type: .reel)
        let result = MediaFeedResult(username: "example", displayName: "Example Profile",
                                     avatarURL: "https://scontent.cdninstagram.com/avatar.jpg", items: [source])
        let library = MediaLibrary(defaults: defaults, profileFetcher: { _ in result })
        library.state.channels = [owner]
        let fetched = try await library.refreshProfile(owner)
        XCTAssertEqual(fetched.first?.channelID, owner.id)
        XCTAssertEqual(library.state.channels.first?.name, "Example Profile")
        XCTAssertEqual(library.state.channels.first?.iconUrl, result.avatarURL)
        XCTAssertEqual(MediaLibrary(defaults: defaults).state.channels.first?.iconUrl, result.avatarURL)
    }

    func testSectionsRouteReelsLongVideosAndPostsAcrossPlatforms() {
        let reel = item(id: "ig_reel", owner: "ig_a", platform: .instagram, type: .reel)
        let video = item(id: "ig_video", owner: "ig_a", platform: .instagram, type: .video)
        let carousel = item(id: "ig_album", owner: "ig_a", platform: .instagram, type: .carousel, media: "https://cdn.example/slide.mp4")
        let xVideo = item(id: "x_video", owner: "x_a", platform: .x, media: "https://video.twimg.com/movie.mp4")
        let tweet = item(id: "x_text", owner: "x_a", platform: .x)
        let items = [reel, video, carousel, xVideo, tweet]
        XCTAssertEqual(items.filter(\.isShortsEntry).map(\.videoId), ["ig_reel"])
        XCTAssertEqual(items.filter { !$0.isShortsEntry && !$0.isPost }.map(\.videoId), ["ig_video", "x_video"])
        XCTAssertEqual(items.filter(\.isPost).map(\.videoId), ["ig_album", "x_text"])
    }

    func testXAvatarComesFromTheRequestedProfileRatherThanAQuotedAuthor() throws {
        let root: [String: Any] = ["props": ["pageProps": ["timeline": ["entries": [
            ["content": ["tweet": ["user": ["screen_name": "other", "name": "Other", "profile_image_url_https": "https://pbs.twimg.com/profile_images/other.jpg"]]]],
            ["content": ["tweet": ["user": ["screen_name": "Example", "name": "Example Profile", "profile_image_url_https": "https://pbs.twimg.com/profile_images/example.jpg"]]]]
        ]]]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
        let profile = XFeedParser.profile(body: "<script id=\"__NEXT_DATA__\">\(json)</script>", username: "example")
        XCTAssertEqual(profile.displayName, "Example Profile")
        XCTAssertEqual(profile.avatarURL, "https://pbs.twimg.com/profile_images/example.jpg")
    }

    func testInstagramProductTypesKeepLongVideosAndCarouselsOutOfShorts() throws {
        let nodes: [[String: Any]] = [
            ["shortcode": "Reel", "__typename": "GraphVideo", "is_video": true, "product_type": "clips", "video_duration": 300],
            ["shortcode": "Long", "__typename": "GraphVideo", "is_video": true, "product_type": "igtv", "video_duration": 600],
            ["shortcode": "Album", "__typename": "GraphSidecar", "is_video": true, "product_type": "clips"],
            ["shortcode": "Photo", "__typename": "GraphImage", "is_video": false]
        ]
        let context: [String: Any] = ["context": ["username": "example", "full_name": "Example",
            "profile_pic_url": "https://scontent.cdninstagram.com/avatar.jpg",
            "graphql_media": nodes.map { ["shortcode_media": $0] }]]
        let inner = String(decoding: try JSONSerialization.data(withJSONObject: context), as: UTF8.self)
        let html = String(decoding: try JSONSerialization.data(withJSONObject: ["contextJSON": inner]), as: UTF8.self)
        let profile = try XCTUnwrap(InstagramProfileEmbedParser.parse(html: html, fallbackUsername: "example"))
        XCTAssertEqual(profile.items.map(\.instagramType), [.reel, .video, .carousel, .image])
        XCTAssertEqual(profile.items.filter(\.isShortsEntry).map(\.videoId), ["ig_Reel"])
        XCTAssertEqual(profile.items[1].durationSeconds, 600)
        XCTAssertEqual(profile.items.filter(\.isPost).count, 2)
        XCTAssertNotNil(profile.avatarURL)
    }

    private func channel(id: String, platform: String, handle: String) -> DirectoryChannel {
        DirectoryChannel(id: id, platform: platform, handle: handle, name: nil, iconUrl: nil,
                         url: "https://example.com/\(handle)", categoryId: nil, subcategoryId: nil, sort: 0)
    }

    private func item(id: String, owner: String, platform: MediaPlatform, type: InstagramMediaType? = nil, media: String? = nil) -> MediaVideo {
        MediaVideo(videoId: id, title: "Content", channelId: owner, channelName: "Example", publishedAtEpochMillis: 1,
                   thumbnailUrl: "", platform: platform, instagramType: type, mediaUrl: media)
    }
}

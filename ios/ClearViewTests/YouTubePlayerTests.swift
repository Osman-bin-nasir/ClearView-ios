import XCTest
import WebKit
@testable import ClearView

@MainActor
final class YouTubePlayerTests: XCTestCase {
    func testPlayerHTMLUsesAppIdentityAndVideoOffset() {
        let reference = YouTubeLink.parse("https://youtu.be/M7lc1UVf-VE?t=42")!
        let html = YouTubePlayer.html(reference: reference, start: Double(reference.startSeconds), origin: "https://com.muddassir.clearview")
        XCTAssertTrue(html.contains("M7lc1UVf-VE"))
        XCTAssertTrue(html.contains("\"start\":42"))
        XCTAssertTrue(html.contains("widget_referrer:config.origin"))
        XCTAssertTrue(html.contains("strict-origin-when-cross-origin"))
        XCTAssertTrue(html.contains("https://www.youtube.com/iframe_api"))
        XCTAssertTrue(html.contains("onStateChange:snapshot"))
        XCTAssertTrue(html.contains("onPlaybackRateChange:snapshot"))
    }

    func testStateReflectsPlayerEventsInsteadOfOptimisticToggles() {
        let player = YouTubePlayer()
        player.receive(["event": "ready"])
        player.receive(["event": "snapshot", "position": 20.0, "duration": 90.0, "state": 1, "muted": true, "rate": 1.5, "rates": [1.0, 1.5, 2.0]])
        XCTAssertTrue(player.ready)
        XCTAssertTrue(player.playing)
        XCTAssertTrue(player.muted)
        XCTAssertEqual(player.position, 20)
        XCTAssertEqual(player.rate, 1.5)
        player.togglePlay()
        XCTAssertTrue(player.playing)
        player.receive(["event": "snapshot", "state": 2])
        XCTAssertFalse(player.playing)
        player.receive(["event": "blocked"])
        player.receive(["event": "snapshot", "state": -1])
        XCTAssertEqual(player.status, "Tap Play inside the YouTube player to start")
        player.receive(["event": "error", "code": 150])
        XCTAssertFalse(player.canSeek)
        XCTAssertTrue(player.error!.contains("does not allow"))
    }

    func testPlaybackCommandsReachJavaScriptAndClampSeeks() async throws {
        let player = YouTubePlayer()
        let webView = WKWebView()
        player.webView = webView
        webView.loadHTMLString("<html><body>Player command test</body></html>", baseURL: nil)
        for _ in 0..<100 {
            if !webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(webView.isLoading)
        _ = try await webView.evaluateJavaScript("""
        var calls = [];
        var player = {pauseVideo:()=>calls.push('pause'), playVideo:()=>{calls.push('play'); return window;},
          mute:()=>calls.push('mute'), unMute:()=>calls.push('unmute'),
          seekTo:(value)=>calls.push('seek:'+value), setPlaybackRate:(value)=>calls.push('rate:'+value)};
        function snapshot() {}
        true;
        """)
        player.receive(["event": "ready"])
        player.receive(["event": "snapshot", "position": 5.0, "duration": 90.0, "state": 2, "muted": false, "rates": [1.0, 1.5]])
        player.togglePlay()
        player.skip(-10)
        player.seek(to: 150)
        player.toggleMute()
        player.setRate(1.5)
        player.setRate(5)
        let calls = try await webView.evaluateJavaScript("calls") as? [String]
        XCTAssertEqual(calls, ["play", "seek:0", "seek:90", "mute", "rate:1.5"])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(player.error)
    }

    func testProgressAndPlaylistPersistWithoutDuplicates() {
        let suite = "player-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MediaLibrary(defaults: defaults)
        var video = LibraryVideo(id: "M7lc1UVf-VE", title: "Test video", url: "https://youtu.be/M7lc1UVf-VE")
        let playlist = MediaPlaylist(name: "Test playlist")
        library.state.playlists.append(playlist)
        library.add(video, to: playlist.id)
        library.add(video, to: playlist.id)
        library.recordProgress(video, position: 42, duration: 180)
        library.recordProgress(video, position: .nan, duration: 180)
        let restored = MediaLibrary(defaults: defaults)
        XCTAssertEqual(restored.state.playlists.first?.videos.count, 1)
        XCTAssertEqual(restored.state.watchProgress?[video.id]?.position, 42)
        video.live = true
        library.recordProgress(video, position: 100, duration: 180)
        XCTAssertEqual(library.state.watchProgress?[video.id]?.position, 42)
        XCTAssertEqual(MediaVideoPlayerView.time(3661), "1:01:01")
    }
}

import SwiftUI
import WebKit
import Observation

@MainActor
@Observable
final class YouTubePlayer: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private(set) var ready = false
    private(set) var playing = false
    private(set) var buffering = false
    private(set) var muted = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Double = 1
    private(set) var rates: [Double] = []
    private(set) var error: String?
    private(set) var status = "Loading YouTube player…"
    private var requiresDirectPlay = false
    @ObservationIgnored weak var webView: WKWebView?

    var canSeek: Bool { ready && duration > 0 && error == nil }

    func command(_ script: String) {
        guard ready, error == nil else { return }
        webView?.evaluateJavaScript("if (player) { \(script) }") { [weak self] _, failure in
            if failure != nil { self?.error = "The player could not receive this action. Try reloading the video." }
        }
    }

    func togglePlay() { command(playing ? "player.pauseVideo();" : "player.playVideo();") }
    func toggleMute() { command(muted ? "player.unMute(); snapshot();" : "player.mute(); snapshot();") }
    func seek(to seconds: Double) {
        guard canSeek, seconds.isFinite else { return }
        command("player.seekTo(\(min(duration, max(0, seconds))), true); snapshot();")
    }
    func skip(_ seconds: Double) { seek(to: position + seconds) }
    func setRate(_ value: Double) {
        guard rates.contains(value) else { return }
        command("player.setPlaybackRate(\(value));")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "clearview", message.frameInfo.isMainFrame,
              let data = message.body as? [String: Any] else { return }
        receive(data)
    }

    func receive(_ data: [String: Any]) {
        switch data["event"] as? String {
        case "ready":
            ready = true
            error = nil
            requiresDirectPlay = false
            status = "Tap Play to start"
        case "snapshot":
            if let value = data["position"] as? Double, value.isFinite { position = max(0, value) }
            if let value = data["duration"] as? Double, value.isFinite { duration = max(0, value) }
            if let value = data["muted"] as? Bool { muted = value }
            if let value = data["rate"] as? Double, value.isFinite { rate = value }
            if let values = data["rates"] as? [Double] { rates = values.filter { $0.isFinite && $0 > 0 }.sorted() }
            if let state = data["state"] as? Int {
                playing = state == 1
                buffering = state == 3
                switch state {
                case 1: requiresDirectPlay = false; status = "Playing"
                case 2: status = "Paused"
                case 3: status = "Buffering…"
                case 0: status = "Finished"
                default: status = requiresDirectPlay ? "Tap Play inside the YouTube player to start" : "Tap Play to start"
                }
            }
        case "blocked":
            requiresDirectPlay = true
            status = "Tap Play inside the YouTube player to start"
        case "error":
            playing = false
            buffering = false
            let code = data["code"] as? Int ?? 0
            switch code {
            case 100: error = "This video is unavailable or private."
            case 101, 150: error = "This video's owner does not allow embedded playback."
            case 153: error = "YouTube could not verify the embedded player's app identity (153)."
            default: error = "YouTube could not play this video (\(code)). Try reloading."
            }
        default: break
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = "Unable to load YouTube. Check your connection and retry."
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        playing = false
        error = "The player stopped unexpectedly. Reload to continue."
    }

    func reload() {
        ready = false
        playing = false
        buffering = false
        error = nil
        status = "Loading YouTube player…"
        webView?.reload()
    }

    static func html(reference: YouTubeRef, start: Double, origin: String) -> String {
        let configuration: [String: Any] = ["videoId": reference.videoId, "start": max(0, Int(start)), "origin": origin]
        let json = String(data: try! JSONSerialization.data(withJSONObject: configuration), encoding: .utf8)!
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>html,body,#player{margin:0;width:100%;height:100%;background:#000;overflow:hidden}</style>
        </head><body><div id="player"></div><script>
        const config = \(json);
        let player;
        function send(event, values = {}) { window.webkit.messageHandlers.clearview.postMessage({event, ...values}); }
        function snapshot() {
          if (!player || !player.getCurrentTime) return;
          send('snapshot', {position:player.getCurrentTime(), duration:player.getDuration(),
            state:player.getPlayerState(), muted:player.isMuted(), rate:player.getPlaybackRate(),
            rates:player.getAvailablePlaybackRates()});
        }
        function onYouTubeIframeAPIReady() {
          player = new YT.Player('player', {width:'100%',height:'100%',videoId:config.videoId,
            playerVars:{playsinline:1,controls:1,autoplay:1,start:config.start,
              origin:config.origin,widget_referrer:config.origin},
            events:{onReady:()=>{send('ready');snapshot();},onStateChange:snapshot,
              onPlaybackRateChange:snapshot,onAutoplayBlocked:()=>send('blocked'),
              onError:(event)=>send('error',{code:event.data})}});
        }
        setInterval(snapshot, 1000);
        </script><script src="https://www.youtube.com/iframe_api" onerror="send('error',{code:0})"></script></body></html>
        """
    }
}

struct EmbeddedYouTubePlayer: UIViewRepresentable {
    let player: YouTubePlayer
    let reference: YouTubeRef
    let start: Double

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(player, name: "clearview")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.navigationDelegate = player
        webView.accessibilityIdentifier = "media.player.embed"
        player.webView = webView
        let origin = "https://\((Bundle.main.bundleIdentifier ?? "com.muddassir.clearview").lowercased())"
        webView.loadHTMLString(YouTubePlayer.html(reference: reference, start: start, origin: origin), baseURL: URL(string: origin))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        uiView.evaluateJavaScript("if (player) { player.destroy(); }")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "clearview")
        uiView.navigationDelegate = nil
        uiView.stopLoading()
    }
}

import Foundation
import WebKit

/// Resolve the same public Instagram embed Android renders. The web view only
/// discovers the media URL; AVPlayer owns playback after it is torn down.
@MainActor
final class SocialMediaStreamResolver {
    static let shared = SocialMediaStreamResolver()
    private var cache: [String: (url: URL, at: Date)] = [:]

    func resolve(_ video: LibraryVideo, fresh: Bool = false) async throws -> URL {
        guard !video.isPost else { throw AudioExtractionError.noAudioStream }
        if (!fresh || !video.mediaVideo.isInstagram), let raw = video.mediaURL, let direct = URL(string: raw),
           direct.scheme == "https", Self.isUsable(direct) { return direct }
        guard video.mediaVideo.isInstagram else { throw AudioExtractionError.noAudioStream }
        let parts = URL(string: video.sourceURL ?? video.url)?.pathComponents.filter { $0 != "/" } ?? []
        let code = parts.count > 1 ? parts[1] : video.id.replacingOccurrences(of: "ig_", with: "")
        guard code.range(of: #"^[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil else {
            throw MediaFeedError.invalidHandle
        }
        if !fresh, let cached = cache[code], Date().timeIntervalSince(cached.at) < 20 * 60,
           Self.isUsable(cached.url) { return cached.url }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        web.customUserAgent = InstagramSource.userAgent
        defer { web.stopLoading(); web.loadHTMLString("", baseURL: nil) }
        let script = """
        (() => {
          const v = document.querySelector('video');
          if (!v) return '';
          v.muted = true;
          const source = v.querySelector('source');
          return [v.getAttribute('src'), source && source.getAttribute('src'), v.currentSrc]
            .find(s => s && s.startsWith('https://')) || '';
        })()
        """
        for path in ["reel", "p"] {
            let embed = URL(string: "https://www.instagram.com/\(path)/\(code)/embed/captioned/")!
            web.load(URLRequest(url: embed, timeoutInterval: 8))
            for _ in 0..<24 {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                if let raw = try? await web.evaluateJavaScript(script) as? String,
                   let url = URL(string: raw), url.scheme == "https", Self.isUsable(url) {
                    cache[code] = (url, Date())
                    return url
                }
            }
        }
        throw AudioExtractionError.videoUnavailable("This post did not expose a playable public video. Try again or open it on Instagram.")
    }

    static func isUsable(_ url: URL, now: Date = Date()) -> Bool {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for entry in query {
            if entry.name == "expire", let value = entry.value.flatMap(Double.init) {
                return value > now.timeIntervalSince1970 + 60
            }
            if entry.name == "oe", let value = entry.value.flatMap({ UInt64($0, radix: 16) }) {
                return Double(value) > now.timeIntervalSince1970 + 60
            }
        }
        return true
    }
}

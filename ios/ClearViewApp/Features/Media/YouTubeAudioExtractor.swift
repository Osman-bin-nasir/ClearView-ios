import Foundation
import YouTubeKit

/// Why an audio stream could not be resolved.
///
/// Every case carries a sentence the UI can show as-is: the reader tapped
/// "Listen" or "Download Audio" and needs to know whether to retry, pick another
/// video, or wait. The Android extractor draws the same line between a captcha
/// challenge (`ReCaptchaException`), a video that is genuinely unavailable
/// (`ContentNotAvailableException`) and a plain extraction failure.
enum AudioExtractionError: LocalizedError, Equatable {
    /// YouTube answered, but will not serve this video to us right now.
    case loginRequired
    case videoUnavailable(String?)
    case liveBroadcast
    case noAudioStream
    /// The stream exists but is only offered ciphered, which this build does not
    /// unscramble. See the note on ``YouTubeAudioExtractor`` for why the clients
    /// used here are chosen to avoid this.
    case cipheredStream
    case network(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .loginRequired:
            return "YouTube is asking to verify you're not a robot right now. Try again in a few minutes."
        case .videoUnavailable(let reason):
            return reason ?? "This video isn't available for download."
        case .liveBroadcast:
            return "Live broadcasts don't have a finished audio track to save. Try again after the stream ends."
        case .noAudioStream:
            return "No audio track is available for this video."
        case .cipheredStream:
            return "YouTube only offered a protected audio stream for this video. Try another video."
        case .network(let detail):
            return "Network error while preparing the audio. Check your connection. (\(detail))"
        case .malformedResponse:
            return "Couldn't read this video's audio details. Try another video."
        }
    }
}

/// One resolved audio-only stream: the direct URL plus what the caller needs to
/// name and store the file.
struct ExtractedAudio: Equatable, Sendable {
    let url: URL
    /// File extension for the saved audio (`m4a`, `webm`, …).
    let fileExtension: String
    let mimeType: String
    let bitrate: Int
    /// Total byte size when YouTube reported one (it usually does for audio),
    /// so the UI can show "≈ X MB" before the transfer starts — the same reason
    /// Android's downloader reports the size from the response headers.
    let contentLength: Int64?
}

/// Native, on-device extraction through YouTubeKit, followed by direct player
/// clients when needed. Both playback and downloads use this same resolver.
struct YouTubeAudioExtractor: AudioStreamExtracting {

    /// The clients tried in order. All are keyless: a client that needs an API
    /// key answers `FAILED_PRECONDITION` without one, which is why the `IOS` and
    /// `ANDROID` clients are absent (verified: both returned `Precondition check
    /// failed` when asked without a key).
    ///
    /// The VR client is first because it is the one verified to return direct
    /// URLs. The embedded-player clients follow it because they answer from a
    /// different quota bucket, so a video the VR client is throttled on can still
    /// resolve — the same multi-client hedging NewPipe does, for the same reason.
    static let clients: [InnertubeClient] = [
        InnertubeClient(
            name: "ANDROID_VR",
            version: "1.62.27",
            headerName: "28",
            userAgent: "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12; GB) gzip",
            extraContext: ["androidSdkVersion": "32", "osName": "Android", "osVersion": "12",
                           "deviceMake": "Oculus", "deviceModel": "Quest 3"]
        ),
        InnertubeClient(
            name: "WEB_EMBEDDED_PLAYER",
            version: "1.20260101.00.00",
            headerName: "56",
            userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            extraContext: [:]
        ),
        InnertubeClient(
            name: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
            version: "2.0",
            headerName: "85",
            userAgent: "Mozilla/5.0 (PlayStation; PlayStation 4/12.00) AppleWebKit/605.1.15 (KHTML, like Gecko)",
            extraContext: [:]
        )
    ]

    private let session: URLSession
    private let clients: [InnertubeClient]
    private let useNativeExtractor: Bool

    init(session: URLSession = .shared, clients: [InnertubeClient] = YouTubeAudioExtractor.clients,
         useNativeExtractor: Bool = true) {
        self.session = session
        self.clients = clients
        self.useNativeExtractor = useNativeExtractor
    }

    func extractAudio(videoId: String) async throws -> ExtractedAudio {
        guard let id = Self.normalizedVideoId(videoId) else {
            throw AudioExtractionError.malformedResponse
        }
        if useNativeExtractor {
            do { return try await nativeAudio(videoId: id) }
            catch is CancellationError { throw CancellationError() }
            catch { MediaLog.audio.notice("Native extraction failed; trying direct player clients: \(error.localizedDescription, privacy: .public)") }
        }
        var lastError: AudioExtractionError?
        for client in clients {
            try Task.checkCancellation()
            do {
                MediaLog.audio.debug("extract \(id, privacy: .public): trying client \(client.name, privacy: .public)/\(client.version, privacy: .public)")
                let response = try await playerResponse(videoId: id, client: client)
                let status = response.playabilityStatus?.status
                MediaLog.audio.debug("extract \(id, privacy: .public): \(client.name, privacy: .public) status=\(status ?? "<none>", privacy: .public) reason=\(response.playabilityStatus?.reason ?? "<none>", privacy: .public)")
                switch status {
                case "OK":
                    break
                case "LOGIN_REQUIRED":
                    // Seen both for genuinely age-restricted videos and for
                    // datacenter IPs YouTube distrusts. Worth trying the next
                    // client, but if every client says this, it is the answer.
                    lastError = .loginRequired
                    continue
                case "LIVE_STREAM_OFFLINE", "ERROR":
                    lastError = .videoUnavailable(response.playabilityStatus?.reason)
                    continue
                default:
                    lastError = .videoUnavailable(response.playabilityStatus?.reason)
                    continue
                }
                if response.videoDetails?.isLive == true {
                    throw AudioExtractionError.liveBroadcast
                }
                let formats = (response.streamingData?.adaptiveFormats ?? []).compactMap { $0.audioFormat }
                if !formats.isEmpty && formats.allSatisfy({ $0.url == nil }) {
                    lastError = .cipheredStream
                    continue
                }
                guard let best = Self.selectBestAudio(formats) else {
                    MediaLog.audio.error("extract \(id, privacy: .public): \(client.name, privacy: .public) offered no audio formats (advertised \(response.streamingData?.adaptiveFormats?.count ?? 0, privacy: .public))")
                    lastError = .noAudioStream
                    continue
                }
                guard let direct = best.url, let url = URL(string: direct) else {
                    // The format exists but carries no plain URL — it is behind
                    // a signatureCipher. Another client may hand back a usable
                    // one, so try the rest before giving up.
                    MediaLog.audio.error("extract \(id, privacy: .public): \(client.name, privacy: .public) itag=\(best.itag, privacy: .public) is ciphered (no direct url)")
                    lastError = .cipheredStream
                    continue
                }
                MediaLog.audio.info("extract \(id, privacy: .public): resolved via \(client.name, privacy: .public) itag=\(best.itag, privacy: .public) \(best.mimeType, privacy: .public) \(best.bitrate, privacy: .public)bps host=\(url.host() ?? "?", privacy: .public)")
                return ExtractedAudio(
                    url: url,
                    fileExtension: Self.fileExtension(forMimeType: best.mimeType),
                    mimeType: best.mimeType,
                    bitrate: best.bitrate,
                    contentLength: best.contentLength
                )
            } catch let error as AudioExtractionError {
                MediaLog.audio.error("extract \(id, privacy: .public): \(client.name, privacy: .public) failed — \(error.localizedDescription, privacy: .public)")
                lastError = error
            } catch let error as URLError {
                MediaLog.audio.error("extract \(id, privacy: .public): \(client.name, privacy: .public) network — \(error.localizedDescription, privacy: .public)")
                lastError = .network(error.localizedDescription)
            } catch {
                MediaLog.audio.error("extract \(id, privacy: .public): \(client.name, privacy: .public) malformed — \(String(describing: error), privacy: .public)")
                lastError = .malformedResponse
            }
        }
        MediaLog.audio.error("extract \(id, privacy: .public): every client failed; last reason = \((lastError ?? .noAudioStream).localizedDescription, privacy: .public)")
        throw lastError ?? .noAudioStream
    }

    /// Like Android's NewPipe integration, use a maintained on-device extractor
    /// for signature and throttling transforms. Remote extraction is disabled.
    private func nativeAudio(videoId: String) async throws -> ExtractedAudio {
        let streams = try await YouTube(videoID: videoId, methods: [.local]).streams
        let audio = streams.filterAudioOnly().filter {
            $0.isNativelyPlayable && ($0.fileExtension == .m4a || $0.fileExtension == .mp4)
        }
        guard let best = audio.max(by: { ($0.averageBitrate ?? $0.bitrate ?? 0) < ($1.averageBitrate ?? $1.bitrate ?? 0) }) else {
            throw AudioExtractionError.noAudioStream
        }
        return ExtractedAudio(url: best.url, fileExtension: "m4a", mimeType: "audio/mp4",
                              bitrate: best.averageBitrate ?? best.bitrate ?? 0, contentLength: nil)
    }

    /// The parsed innertube player response, reduced to the fields this app reads.
    private func playerResponse(videoId: String, client: InnertubeClient) async throws -> PlayerResponse {
        var request = URLRequest(url: Self.playerEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(client.headerName, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(client.version, forHTTPHeaderField: "X-Youtube-Client-Version")
        request.httpBody = client.playerRequestBody(videoId: videoId)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            // innertube reports its own failures in the body, so a body that
            // parses is more informative than the status code alone.
            if let parsed = try? JSONDecoder().decode(PlayerResponse.self, from: data) {
                return parsed
            }
            throw AudioExtractionError.network("HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(PlayerResponse.self, from: data)
        } catch {
            throw AudioExtractionError.malformedResponse
        }
    }

    // MARK: - Stream selection

    /// Picks the best audio stream. Pure, so the preference order is unit-testable
    /// without hitting the network — the same reason Android keeps
    /// `selectBestAudio` internal for `OnDeviceStreamExtractorTest`.
    ///
    /// The order matters and is not simply "highest bitrate":
    ///
    /// 1. **Original-language track first.** A video with dubs tags every stream
    ///    with an `audioTrack`; dubs are frequently *higher*-bitrate than the
    ///    original, so choosing by bitrate alone is what produced Android's
    ///    "downloads came out in Arabic" bug. Streams flagged
    ///    `audioIsDefault` win, then untagged streams (single-track videos,
    ///    where the only track is by definition the original), and only then
    ///    anything else.
    /// 2. Only direct AAC/MP4 streams that AVFoundation can decode are eligible.
    ///    Protected URLs are handled by YouTubeKit; unsupported WebM is never
    ///    recorded as a successful but unplayable download.
    /// 3. Then the highest bitrate within the chosen language wins.
    static func selectBestAudio(_ formats: [InnertubeAudioFormat]) -> InnertubeAudioFormat? {
        guard !formats.isEmpty else { return nil }
        let defaults = formats.filter { $0.audioIsDefault == true }
        let untagged = formats.filter { !$0.hasAudioTrack }
        let languagePool = !defaults.isEmpty ? defaults : (!untagged.isEmpty ? untagged : formats)
        let pool = languagePool.filter {
            $0.isPlayableOnIOS && $0.url.flatMap(URL.init(string:))?.scheme?.lowercased() == "https"
        }
        return pool.max { first, second in first.bitrate < second.bitrate }
    }

    /// `m4a`/`webm`/`ogg` from the MIME type, falling back to `m4a` — Android's
    /// `DEFAULT_EXTENSION`.
    static func fileExtension(forMimeType mimeType: String) -> String {
        let lower = mimeType.lowercased()
        if lower.contains("mp4") { return "m4a" }
        if lower.contains("webm") { return "webm" }
        if lower.contains("ogg") || lower.contains("opus") { return "ogg" }
        return "m4a"
    }

    /// A bare 11-character id, or an id pulled out of a watch/short/embed URL.
    ///
    /// Accepts the forms the feed, the saved-links list and a pasted URL can
    /// produce, so a caller never has to normalise first.
    static func normalizedVideoId(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let idPattern = #"^[A-Za-z0-9_-]{11}$"#
        if trimmed.range(of: idPattern, options: .regularExpression) != nil { return trimmed }
        guard let url = URL(string: trimmed), let host = url.host?.lowercased(),
              host == "youtube.com" || host == "www.youtube.com" || host == "youtu.be" || host == "m.youtube.com" else {
            return nil
        }
        if host == "youtu.be" {
            let candidate = url.pathComponents.filter { $0 != "/" }.first ?? ""
            return candidate.range(of: idPattern, options: .regularExpression) != nil ? candidate : nil
        }
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let value = query.first(where: { $0.name == "v" })?.value,
           value.range(of: idPattern, options: .regularExpression) != nil {
            return value
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 2, ["shorts", "embed", "live", "v"].contains(parts[0]),
           parts[1].range(of: idPattern, options: .regularExpression) != nil {
            return parts[1]
        }
        return nil
    }

    static let playerEndpoint = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
}

/// One keyless innertube client identity.
struct InnertubeClient: Equatable, Sendable {
    let name: String
    let version: String
    /// The `X-Youtube-Client-Name` header value (the numeric client id).
    let headerName: String
    let userAgent: String
    /// Client-specific context keys (Android SDK level, device model, …).
    let extraContext: [String: String]

    func playerRequestBody(videoId: String) -> Data {
        var client: [String: Any] = [
            "clientName": name,
            "clientVersion": version,
            "hl": "en",
            "gl": "US"
        ]
        for (key, value) in extraContext { client[key] = value }
        let body: [String: Any] = [
            "context": ["client": client],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }
}

// MARK: - innertube response shape

/// The subset of the innertube player response this app reads.
///
/// Decoded with `JSONDecoder` rather than `JSONSerialization` so a missing or
/// retyped field is a decode failure the caller handles, not a crash — the same
/// defensive posture as the Android parser, which reads every field with a
/// defaulted `opt*` accessor.
struct PlayerResponse: Decodable {
    let playabilityStatus: PlayabilityStatus?
    let videoDetails: VideoDetails?
    let streamingData: StreamingData?

    struct PlayabilityStatus: Decodable {
        let status: String?
        let reason: String?
    }

    struct VideoDetails: Decodable {
        let title: String?
        let isLive: Bool?
    }

    struct StreamingData: Decodable {
        let adaptiveFormats: [RawFormat]?
    }

    struct RawFormat: Decodable {
        let itag: Int?
        let mimeType: String?
        let bitrate: Int?
        let url: String?
        let contentLength: String?
        let audioTrack: AudioTrack?

        struct AudioTrack: Decodable {
            let displayName: String?
            let audioIsDefault: Bool?
        }

        /// The audio-only view of this format, or nil when it carries video.
        ///
        /// An audio format is identified by its MIME type rather than by itag,
        /// because the itag set changes as YouTube adds codecs — the same reason
        /// Android filters on the extractor's parsed `MediaFormat`.
        var audioFormat: InnertubeAudioFormat? {
            guard let mimeType, mimeType.lowercased().hasPrefix("audio/") else { return nil }
            return InnertubeAudioFormat(
                itag: itag ?? 0,
                mimeType: mimeType,
                bitrate: bitrate ?? 0,
                url: url,
                // A formality: YT reports it as a JSON *string*.
                contentLength: contentLength.flatMap(Int64.init),
                audioIsDefault: audioTrack?.audioIsDefault,
                hasAudioTrack: audioTrack != nil
            )
        }
    }
}

/// An audio-only format, flattened for selection.
struct InnertubeAudioFormat: Equatable, Sendable {
    let itag: Int
    let mimeType: String
    let bitrate: Int
    let url: String?
    let contentLength: Int64?
    /// `audioTrack.audioIsDefault` — true for the video's own language when the
    /// video ships more than one audio track.
    let audioIsDefault: Bool?
    /// Whether the format was tagged with an audio track at all. A single-track
    /// video has none, and its only track is the original.
    let hasAudioTrack: Bool

    /// True for a container `AVPlayer` can decode without extra help.
    var isPlayableOnIOS: Bool {
        let lower = mimeType.lowercased()
        return lower.contains("mp4a") || lower.contains("audio/mp4")
    }
}

/// Resolves direct audio-stream URLs. A protocol so the downloader and the
/// playback controller can be driven by a stub in tests — the network is not
/// part of what they are supposed to guarantee.
protocol AudioStreamExtracting: Sendable {
    func extractAudio(videoId: String) async throws -> ExtractedAudio
}

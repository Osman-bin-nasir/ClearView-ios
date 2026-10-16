import SwiftUI

/// Haramayn Live: Makkah and Madinah live broadcasts played INSIDE the app.
///
/// Each official channel's CURRENT live broadcast video id is discovered at
/// runtime by ``LiveStreamResolver``, validated, and played with the same in-app
/// YouTube embed as regular videos — no HLS/CDN, no YouTube app, no browser. Only
/// ONE stream is loaded at a time. Ported from Android's `LiveTab`.
///
/// STATES: an explicit state machine — CONNECTING (spinner, "Connecting to live
/// stream…"), RETRYING (auto-retry with exponential backoff after a transient
/// failure), PLAYING, and UNAVAILABLE (manual Retry). When the resolver detects
/// the Restricted-Mode signature a network DNS filter (e.g. CleanBrowsing Family
/// Filter) produces, the screen explains the cause instead of a generic error —
/// retrying cannot help while the filter keeps mapping www.youtube.com to
/// Restricted Mode.
///
/// BACKUP CHANNEL: Makkah has a backup source (AlQuran4k). When the primary
/// channel has no valid live broadcast — and the page was not filtered — the
/// backup is resolved and played, and the caption says which channel is on air.
@MainActor
@Observable
final class HaramaynModel {

    enum Phase: Equatable {
        /// First attempt: resolving (and waiting for the embed to start).
        case connecting
        /// Auto-retry after a transient failure, with backoff.
        case retrying
        case playing
        /// No stream. `filtered` marks a network DNS filter (Restricted Mode)
        /// block, which retrying cannot fix.
        case unavailable(filtered: Bool)
    }

    /// If a resolved stream never starts within this window, retry / surface the card.
    static let loadTimeout: TimeInterval = 25
    /// Automatic resolution retries (after the first attempt), then manual Retry.
    static let maxAutoAttempts = 4
    /// Exponential backoff base (5 s → 10 s → 20 s → 40 s, capped).
    static let retryBase: TimeInterval = 5
    static let maxBackoffShift = 3

    let player = YouTubePlayer()

    private(set) var phase: Phase = .connecting
    /// The selected location (Makkah / Madinah).
    private(set) var location: LiveStreamSource = LiveStreamConfig.makkah
    /// The channel actually producing the current broadcast — the location's own
    /// channel, or its backup when the primary had nothing on air.
    private(set) var airingSource: LiveStreamSource?
    /// The resolved broadcast, or nil while there is nothing to play.
    private(set) var reference: YouTubeRef?
    /// Bumped every time a stream is applied, so the embed is rebuilt even when
    /// the same video id is resolved again (a retry must re-attempt playback).
    private(set) var embedToken = 0

    private let resolver: LiveStreamResolver
    private var task: Task<Void, Never>?

    init(resolver: LiveStreamResolver = .shared) {
        self.resolver = resolver
    }

    var isConnecting: Bool { phase == .connecting || phase == .retrying }
    var isPlaying: Bool { phase == .playing }
    /// True while the backup channel is the one on air.
    var isUsingBackup: Bool { airingSource.map { $0.id != location.id } ?? false }

    /// Starts the resolution loop, once, when the screen appears.
    func start() {
        guard task == nil else { return }
        run()
    }

    /// Cancels any in-flight resolution (screen dismissed).
    func stop() {
        task?.cancel()
        task = nil
    }

    /// Switches location and resolves that channel's current broadcast.
    func select(_ source: LiveStreamSource) {
        guard source.id != location.id else { return }
        location = source
        run()
    }

    /// Manual retry: a fresh loop, so a broadcast that has just started is found.
    func retry() {
        run()
    }

    /// The broadcast ended or the embed reported it cannot play it: surface the
    /// unavailable card instead of a frozen "Live · playing" caption.
    func streamEnded() {
        guard isPlaying else { return }
        task?.cancel()
        task = nil
        reference = nil
        phase = .unavailable(filtered: false)
    }

    private func run() {
        task?.cancel()
        player.reset()
        reference = nil
        airingSource = nil
        embedToken += 1
        phase = .connecting
        let location = self.location
        task = Task { [weak self] in
            await self?.resolveLoop(for: location)
        }
    }

    /// Discover → validate → play, with BOUNDED automatic retries so YouTube is
    /// never hammered: 5 s → 10 s → 20 s → 40 s, then the manual Retry card. A
    /// DNS-filter block stops retrying and explains itself.
    private func resolveLoop(for location: LiveStreamSource) async {
        var attempt = 0
        while !Task.isCancelled {
            phase = attempt == 0 ? .connecting : .retrying

            var result = await resolver.resolve(location, force: attempt > 0)
            var airing = location

            // Graceful fallback: the primary channel has nothing on air → try the
            // documented backup channel, exactly as Android does. Never attempted
            // when the page was filtered: the filter would block the backup too.
            if result.videoId == nil, !result.blockedByFilter,
               let backup = LiveStreamConfig.backupStreams[location.id] {
                let fallback = await resolver.resolve(backup, force: attempt > 0)
                if fallback.videoId != nil {
                    result = fallback
                    airing = backup
                }
            }
            if Task.isCancelled { return }

            if let videoId = result.videoId {
                airingSource = airing
                reference = YouTubeRef(videoId: videoId, kind: .live)
                embedToken += 1

                // Wait for the embed to actually start playing. If it never does,
                // fall through to a retry with a fresh resolution — a new broadcast
                // may have started.
                let deadline = Date().addingTimeInterval(Self.loadTimeout)
                while Date() < deadline, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    if player.playing {
                        phase = .playing
                        return
                    }
                    if player.finished || player.error != nil { break }
                }
                guard !Task.isCancelled else { return }
                reference = nil
                player.reset()
            } else if result.blockedByFilter {
                phase = .unavailable(filtered: true)
                return
            }

            attempt += 1
            if attempt > Self.maxAutoAttempts {
                phase = .unavailable(filtered: false)
                return
            }
            try? await Task.sleep(for: .seconds(Self.retryBase * pow(2, Double(min(attempt, Self.maxBackoffShift)))))
        }
    }
}

struct HaramaynView: View {
    @State private var model = HaramaynModel()

    var body: some View {
        VStack(spacing: 0) {
            locations
            playerSlot
            if model.reference != nil { transport }
            caption
            Spacer(minLength: 0)
        }
        .background(Color.cvBackground)
        .navigationTitle("Haramayn")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.start() }
        .onDisappear { model.stop() }
        .onChange(of: model.player.finished) { _, ended in
            if ended { model.streamEnded() }
        }
    }

    // MARK: - Location selector

    /// Its OWN row, ABOVE the player, so the chips can never overlap YouTube's
    /// native player controls — the same no-overlap rule the Android tab uses.
    private var locations: some View {
        HStack(spacing: 10) {
            ForEach(LiveStreamConfig.streams) { source in
                CVChip(title: source.title, selected: model.location.id == source.id) {
                    model.select(source)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("haramayn.location.\(source.id)")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: - Player

    private var playerSlot: some View {
        ZStack {
            Color.black
            if let reference = model.reference {
                EmbeddedYouTubePlayer(player: model.player, reference: reference, start: 0)
                    .id(model.embedToken)
            }
            // The connecting / unavailable backdrop: the slot never reads as a
            // dead black screen while the embed spins up or after it fails.
            if model.isConnecting || isUnavailable {
                LinearGradient(
                    colors: [Color.cvPrimaryContainer, Color.cvSecondaryContainer, Color.cvTertiaryContainer],
                    startPoint: .top, endPoint: .bottom
                )
                Color.black.opacity(0.25)
            }
            if model.isConnecting {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(model.phase == .retrying
                         ? "Live stream temporarily unavailable. Retrying…"
                         : "Connecting to live stream…")
                        .font(.subheadline).foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                }.padding(20)
            }
            if isUnavailable { unavailableCard }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .accessibilityIdentifier("haramayn.player")
    }

    private var isUnavailable: Bool {
        if case .unavailable = model.phase { return true }
        return false
    }

    private var unavailableCard: some View {
        let filtered: Bool
        if case .unavailable(let blocked) = model.phase { filtered = blocked } else { filtered = false }
        return VStack(spacing: 14) {
            Text(filtered
                 ? "Live streams may be blocked by your network's DNS filter (YouTube Restricted Mode). Allowlist YouTube or disable Restricted Mode in your DNS filter, then retry."
                 : "Live stream currently unavailable. Please try again later.")
                .font(.subheadline).foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Button("Retry") { model.retry() }
                .font(.subheadline.bold())
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(Color.cvPrimary, in: Capsule())
                .foregroundStyle(Color.cvOnPrimary)
                .accessibilityIdentifier("haramayn.retry")
        }
        .padding(24)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 16))
        .padding(20)
    }

    /// The embed keeps YouTube's own controls (tap the video for play / pause and
    /// volume), so this row only carries what the reader cannot reach in a
    /// broadcast: play/pause, mute, and a reload for a stalled player.
    private var transport: some View {
        HStack(spacing: 0) {
            transportButton(model.player.playing ? "Pause" : "Play",
                            symbol: model.player.playing ? "pause.fill" : "play.fill",
                            enabled: model.player.ready && model.player.error == nil) { model.player.togglePlay() }
            transportButton(model.player.muted ? "Unmute" : "Mute",
                            symbol: model.player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            enabled: model.player.ready && model.player.error == nil) { model.player.toggleMute() }
            transportButton("Reload stream", symbol: "arrow.clockwise", enabled: true) { model.player.reload() }
        }
        .padding(.vertical, 4)
    }

    private func transportButton(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 25))
                .foregroundStyle(enabled ? Color.cvPrimary : Color.cvOnSurfaceVariant.opacity(0.45))
                .frame(maxWidth: .infinity).frame(height: 48)
        }
        .buttonStyle(.plain).disabled(!enabled).accessibilityLabel(title)
    }

    // MARK: - Caption

    private var caption: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(airingSubtitle).font(.subheadline.bold()).foregroundStyle(Color.cvOnSurface)
            Text(statusLine)
                .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                .accessibilityIdentifier("haramayn.status")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color.cvSurfaceContainer)
    }

    /// The location's own subtitle, or the backup channel's when it is on air.
    private var airingSubtitle: String {
        guard let airing = model.airingSource, model.isUsingBackup else { return model.location.subtitle }
        return "\(airing.name) · Backup"
    }

    private var statusLine: String {
        switch model.phase {
        case .connecting: return "Connecting to live stream…"
        case .retrying: return "Live stream temporarily unavailable. Retrying…"
        case .playing: return "Live · playing inside the app"
        case .unavailable: return "Live broadcast · unavailable"
        }
    }
}

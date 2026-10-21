import AVFoundation
import SwiftUI

/// Shorts, one per screen, the next a swipe up and the previous a swipe down.
///
/// This is the shape a vertical clip is watched in — YouTube's Shorts and
/// Instagram's Reels are the same surface, and the feed's horizontal shelf is
/// only the way in. What the pager has that a shelf cannot is the next clip
/// arriving under the thumb.
///
/// **One player, on the page that is showing.** A `WKWebView` and a YouTube
/// iframe per Short in the list would be dozens of players for one screenful of
/// watching, so `isActive` gates the player as well as playback: an off-screen
/// page draws its thumbnail, and the player is dismantled when the page leaves
/// (`EmbeddedYouTubePlayer.dismantleUIView` destroys the iframe), which is also
/// what stops a Short playing on past the page it belongs to.
///
/// ## The transport
///
/// Each page carries a scrubber and a play/pause button of its own, for BOTH
/// kinds of Short. A clip with no visible way to move through it reads as a
/// still that happens to have sound, and the two sources are drawn by completely
/// different machinery underneath — an iframe player for YouTube, an `AVPlayer`
/// for a Reel — so the controls exist once, over both, rather than one source
/// getting them and the other leaving the reader to the embed's own chrome.
struct ShortsPagerView: View {
    let shorts: [LibraryVideo]
    let startAt: LibraryVideo
    let library: MediaLibrary

    @Environment(\.dismiss) private var dismiss
    /// The id of the Short at the top of the page.
    ///
    /// Seeded with the one that was tapped, because `scrollPosition(id:)` scrolls
    /// to a non-nil initial value: the reader tapped the fifth Short and must land
    /// on the fifth, not on the first one with the rest queued behind it.
    @State private var currentID: String?

    init(shorts: [LibraryVideo], startAt: LibraryVideo, library: MediaLibrary) {
        self.shorts = shorts
        self.startAt = startAt
        self.library = library
        _currentID = State(initialValue: startAt.id)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(shorts) { short in
                        ShortPage(
                            short: short,
                            library: library,
                            // The gate for "this is the page in front of the
                            // reader". `currentID` is what paging writes; nil
                            // means nothing has settled yet, which is not the same
                            // as the first page being current.
                            isActive: short.id == currentID,
                            onClose: { dismiss() }
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .id(short.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentID)
            .scrollIndicators(.hidden)
        }
        // Outside the GeometryReader so the measured height is the whole screen:
        // page height and viewport height have to be the same number or paging
        // stops on the seam between two Shorts.
        .ignoresSafeArea()
        .background(.black)
        .statusBarHidden()
        .accessibilityIdentifier("shorts.pager")
    }
}

/// One Short, its player, and the controls that belong over it.
private struct ShortPage: View {
    let short: LibraryVideo
    let library: MediaLibrary
    /// True for the page at the top of the screen — the only one that plays.
    let isActive: Bool
    let onClose: () -> Void

    /// The embedded YouTube player, for a Short. Created per page and dismantled
    /// with the page: the iframe is what holds the stream, so there is nothing
    /// here to pause — leaving the page is what stops it.
    @State private var player = YouTubePlayer()
    /// The native player, for a Reel or an X clip, whose stream is an mp4 rather
    /// than an embeddable YouTube video.
    @State private var playback: ShortPlayback?
    @State private var error: String?
    /// The "Add to playlist" picker, opened from this page's ⋮ menu.
    @State private var showAddToPlaylist = false

    private var youtubeReference: YouTubeRef? { YouTubeLink.parse(short.url) }
    private var downloads: AudioDownloads { .shared }

    var body: some View {
        ZStack {
            Color.black
            media
            overlay
        }
        .clipped()
        .accessibilityIdentifier("shorts.page.\(short.id)")
        // Resolved only when the page is in front of the reader: a stream URL for
        // every Short in the list would be a request per clip nobody has reached.
        .task(id: isActive) {
            guard isActive, youtubeReference == nil, playback == nil else { return }
            do {
                let url = try await SocialMediaStreamResolver.shared.resolve(short)
                guard !Task.isCancelled else { return }
                let resolved = ShortPlayback(url: url)
                playback = resolved
                resolved.play()
            } catch is CancellationError {
            } catch {
                // The reader is looking at a black page: say why rather than
                // leaving them to guess.
                self.error = error.localizedDescription
            }
        }
        // Resumed on the way back IN, not only the first time in. A page whose
        // native player was already built returns early from the `.task` above,
        // so that task cannot be what starts it again — and without this, leaving
        // a Reel for a YouTube Short and coming back found it still paused. The
        // YouTube path never showed the bug because its web view is rebuilt from
        // nothing whenever the page becomes active.
        .onChange(of: isActive) { _, active in
            if active { playback?.play() } else { playback?.pause() }
        }
        .onDisappear { playback?.pause() }
    }

    @ViewBuilder
    private var media: some View {
        if let reference = youtubeReference {
            if isActive {
                EmbeddedYouTubePlayer(player: player, reference: reference, start: 0)
                    .accessibilityIdentifier("shorts.player.\(short.id)")
            } else {
                cover
            }
        } else if let playback {
            // The player layer alone, with no chrome of its own: the transport
            // below is the only one on the page, so a Reel and a Short are driven
            // the same way.
            NativeVideoLayer(player: playback.player)
        } else {
            cover
        }
    }

    /// What an off-screen page (or a stream that has not resolved yet) shows: the
    /// clip's own frame, so a swipe is a move between two known things rather than
    /// through black.
    private var cover: some View {
        ZStack {
            Color.cvSurfaceContainer
            if let thumbnail = short.thumbnail, !thumbnail.isEmpty {
                RemoteImage(url: thumbnail, placeholder: AnyView(ProgressView()))
            } else {
                Image(systemName: "play.rectangle").font(.system(size: 40))
                    .foregroundStyle(Color.cvOnSurfaceVariant)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    // MARK: - Transport state, whichever player is underneath

    private var isYouTube: Bool { youtubeReference != nil }
    private var timelinePosition: Double { isYouTube ? player.position : (playback?.position ?? 0) }
    private var timelineDuration: Double { isYouTube ? player.duration : (playback?.duration ?? 0) }
    private var isPlaying: Bool { isYouTube ? player.playing : (playback?.playing ?? false) }
    private var canSeek: Bool { isYouTube ? player.canSeek : (playback?.canSeek ?? false) }

    private func togglePlay() {
        if isYouTube { player.togglePlay() } else { playback?.togglePlay() }
    }

    private func seek(to seconds: Double) {
        if isYouTube { player.seek(to: seconds) } else { playback?.seek(to: seconds) }
    }

    private var overlay: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left").font(.system(size: 20, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close Shorts")
                .accessibilityIdentifier("shorts.close")
                Spacer(minLength: 0)
                if youtubeReference != nil {
                    Button {
                        player.toggleMute()
                    } label: {
                        Image(systemName: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 17)).frame(width: 44, height: 44)
                    }
                    .disabled(!player.ready)
                    .accessibilityLabel(player.muted ? "Unmute" : "Mute")
                    .accessibilityIdentifier("shorts.mute")
                }
                // The same five things a card's ⋮ carries in the feed — Add to
                // playlist, Hide video, Hide channel, Download audio, Share — because
                // a Short watched here is the same video the shelf was offering, and
                // two menus for one video is how they drift apart.
                Menu {
                    Button("Add to playlist…", systemImage: "text.badge.plus") { showAddToPlaylist = true }
                    Button("Hide video", systemImage: "eye.slash") { library.hide(short) }
                    if !(short.channelID ?? "").isEmpty {
                        Button("Hide channel", systemImage: "person.crop.circle.badge.xmark") {
                            library.hideChannel(short.channelID ?? "")
                        }
                    }
                    if downloads.isDownloaded(short.id) {
                        Button("Delete download", systemImage: "trash", role: .destructive) {
                            if let item = downloads.item(for: short.id) { downloads.remove(item) }
                        }
                    } else if downloads.isDownloading(short.id) {
                        Button("Cancel download", systemImage: "xmark.circle") { downloads.cancel(short.id) }
                    } else if !short.isPost && short.live != true {
                        Button("Download audio", systemImage: "arrow.down.to.line") { downloads.download(short) }
                    }
                    ShareLink(item: short.url)
                } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Options for \(short.title)")
                .accessibilityIdentifier("shorts.menu")
            }
            .padding(.horizontal, 6).padding(.top, 4)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if let channel = library.state.channels.first(where: { $0.id == short.channelID }) {
                        CVAvatar(name: channel.displayName, url: channel.iconUrl, size: 32)
                    }
                    Text(short.channel).font(.subheadline.bold()).lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(short.title).font(.subheadline).lineLimit(2)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Color.cvError)
                } else if let playerError = player.error, youtubeReference != nil {
                    Text(playerError).font(.footnote).foregroundStyle(Color.cvError)
                } else if player.buffering, youtubeReference != nil {
                    Text("Buffering…").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }
                ShortTransport(
                    position: timelinePosition,
                    duration: timelineDuration,
                    playing: isPlaying,
                    canSeek: canSeek,
                    canToggle: isYouTube ? (player.ready && player.error == nil) : (playback != nil),
                    onTogglePlay: togglePlay,
                    onSeek: { seek(to: $0) }
                )
            }
            .padding(.horizontal, 16).padding(.bottom, 20)
        }
        // The overlay is text and buttons over a video: a shadow keeps them
        // legible on a white frame without a scrim dimming the clip.
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
        )
        .foregroundStyle(.white)
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(video: short, library: library)
        }
    }
}

/// The clips's own timeline, over the clip: play/pause, how far in, a scrubber
/// to move through it, and its length.
///
/// Deliberately two controls and not the embed's full chrome — a vertical clip
/// has no room for a row of buttons, and the one thing a reader reaches for is
/// "stop this" and "go back a bit".
private struct ShortTransport: View {
    let position: Double
    let duration: Double
    let playing: Bool
    let canSeek: Bool
    let canToggle: Bool
    let onTogglePlay: () -> Void
    let onSeek: (Double) -> Void

    /// While the thumb is held the clip keeps playing underneath, so the slider
    /// is bound to this instead of to `position` — otherwise the thumb is dragged
    /// back out from under the finger by every progress update.
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    private var upper: Double { max(1, duration) }

    var body: some View {
        HStack(spacing: 8) {
            // Sized to the 44-point minimum touch target rather than to the 34 it
            // used to be: this is the control a thumb aims at over a moving clip,
            // without looking, and the old circle was smaller than the space a
            // finger actually covers.
            Button(action: onTogglePlay) {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canToggle)
            .accessibilityLabel(playing ? "Pause" : "Play")
            .accessibilityIdentifier("shorts.playPause")

            Text(Self.clock(scrubbing ? scrubValue : position))
                .font(.caption2.monospacedDigit()).frame(width: 38, alignment: .leading)

            Slider(
                value: Binding(
                    get: { min(max(0, scrubbing ? scrubValue : position), upper) },
                    set: { scrubValue = $0 }
                ),
                in: 0...upper,
                onEditingChanged: { editing in
                    if editing {
                        scrubValue = position
                        scrubbing = true
                    } else {
                        onSeek(scrubValue)
                        scrubbing = false
                    }
                }
            )
            .tint(.white)
            .disabled(!canSeek)
            .accessibilityLabel("Seek")
            .accessibilityIdentifier("shorts.timeline")

            Text(canSeek ? Self.clock(duration) : "--:--")
                .font(.caption2.monospacedDigit()).frame(width: 38, alignment: .trailing)
        }
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// A native Short's video, drawn with no chrome of its own.
///
/// `VideoPlayer` would bring AVKit's control bar — a second transport, with a
/// second play button, one tap away from the one this page draws. An
/// `AVPlayerLayer` is the picture and nothing else.
private struct NativeVideoLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// A Reel's or X clip's `AVPlayer`, plus the position, length and playing state a
/// transport needs to read.
///
/// `AVPlayer` publishes none of those, and `VideoPlayer` used to hide the fact:
/// with AVKit's own controls on screen nothing else had to know where playback
/// was. Drawing our own bar over the picture moves that responsibility here, so
/// the pager can show one transport over both sources.
@MainActor
@Observable
final class ShortPlayback {
    let player: AVPlayer
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var playing = false

    /// True once the item reports a duration, which is what makes the timeline
    /// meaningful — seeking a stream whose length is not known yet would jump to
    /// an arbitrary point.
    var canSeek: Bool { duration > 0 }

    @ObservationIgnored private var timeObserver: Any?

    init(url: URL, interval: Double = 0.25) {
        player = AVPlayer(url: url)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: interval, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // The observer is registered on the main queue, so this is the main
            // actor by construction; `assumeIsolated` states it to the compiler
            // rather than hopping and arriving late.
            MainActor.assumeIsolated { self?.refresh(at: time) }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    func play() { player.play() }

    func pause() { player.pause() }

    func togglePlay() { playing ? pause() : play() }

    func seek(to seconds: Double) {
        guard canSeek, seconds.isFinite else { return }
        player.seek(to: CMTime(seconds: min(duration, max(0, seconds)), preferredTimescale: 600))
    }

    private func refresh(at time: CMTime) {
        if time.seconds.isFinite { position = max(0, time.seconds) }
        if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
            duration = itemDuration
        }
        playing = player.timeControlStatus == .playing
    }
}

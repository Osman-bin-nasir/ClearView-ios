import AVFoundation
import AVKit
import SwiftUI

/// Shorts, one per screen, the next a swipe up and the previous a swipe down.
///
/// This is the shape a vertical clip is watched in — YouTube's Shorts and
/// Instagram's Reels are the same surface, and the feed's horizontal shelf is
/// only the way in. A Short is not a video with a timeline, so this screen has
/// no scrubber, no speed control and no progress bar; what it has instead is the
/// thing a shelf cannot give it: the next clip arriving under the thumb.
///
/// **One player, on the page that is showing.** A `WKWebView` and a YouTube
/// iframe per Short in the list would be dozens of players for one screenful of
/// watching, so `isActive` gates the player as well as playback: an off-screen
/// page draws its thumbnail, and the player is dismantled when the page leaves
/// (`EmbeddedYouTubePlayer.dismantleUIView` destroys the iframe), which is also
/// what stops a Short playing on past the page it belongs to.
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
    @State private var nativePlayer: AVPlayer?
    @State private var error: String?

    private var youtubeReference: YouTubeRef? { YouTubeLink.parse(short.url) }

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
            guard isActive, youtubeReference == nil, nativePlayer == nil else { return }
            do {
                let url = try await SocialMediaStreamResolver.shared.resolve(short)
                guard !Task.isCancelled else { return }
                let resolved = AVPlayer(url: url)
                nativePlayer = resolved
                resolved.play()
            } catch is CancellationError {
            } catch {
                // The reader is looking at a black page: say why rather than
                // leaving them to guess.
                self.error = error.localizedDescription
            }
        }
        .onChange(of: isActive) { _, active in
            if !active { nativePlayer?.pause() }
        }
        .onDisappear { nativePlayer?.pause() }
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
        } else if let nativePlayer {
            VideoPlayer(player: nativePlayer)
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
                Menu {
                    Button(library.state.saved.contains(short) ? "Unsave" : "Save", systemImage: "bookmark") {
                        library.toggleSave(short)
                    }
                    Button("Hide", systemImage: "eye.slash") { library.hide(short) }
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
            }
            .padding(.horizontal, 16).padding(.bottom, 28)
        }
        // The overlay is text and buttons over a video: a shadow keeps them
        // legible on a white frame without a scrim dimming the clip.
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.65)],
                           startPoint: .top, endPoint: .bottom)
        )
        .foregroundStyle(.white)
    }
}

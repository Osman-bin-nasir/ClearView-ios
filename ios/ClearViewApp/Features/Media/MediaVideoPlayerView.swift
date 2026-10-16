import SwiftUI

struct MediaVideoPlayerView: View {
    let video: LibraryVideo
    let reference: YouTubeRef
    let library: MediaLibrary
    @State private var player = YouTubePlayer()
    @State private var showSpeed = false
    /// The "Add to playlist" picker, opened from the ⋮ menu and the Playlist button.
    @State private var showAddToPlaylist = false
    /// "Reset Continue Watching" asks before it clears anything: this menu is one
    /// careless tap away from the picture, and it throws away every resume position.
    @State private var showResetContinue = false
    /// What to say after a reset, in words — the row simply disappears otherwise.
    @State private var message: String?
    @State private var limitation: String?
    @State private var downloads = AudioDownloads.shared
    @State private var audioPreparing = false
    @State private var audioError: String?
    @State private var showAudioPlayer = false
    @State private var scrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var lastSaved = Date.distantPast
    @State private var hasPlayed = false
    @Environment(\.scenePhase) private var scenePhase

    private var start: Double {
        if reference.startSeconds > 0 { return Double(reference.startSeconds) }
        guard video.live != true, let progress = library.state.watchProgress?[video.id], progress.fraction < FeedFilters.watchedFractionThreshold else { return 0 }
        return progress.position
    }

    var body: some View {
        GeometryReader { geometry in
          ScrollView {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    EmbeddedYouTubePlayer(player: player, reference: reference, start: start)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }.frame(height: max(211, geometry.size.width * 9 / 16))
                VStack(alignment: .leading, spacing: 18) {
                    Text(video.title).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        Text(video.channel)
                        if video.publishedAt > 0 {
                            Text("·")
                            Text(Date(timeIntervalSince1970: Double(video.publishedAt) / 1000), style: .relative)
                        }
                        if video.live == true { Text("· LIVE") }
                        else if player.duration > 0 { Text("· \(Self.time(player.duration))") }
                    }.font(.caption.bold()).foregroundStyle(Color.cvOnSurfaceVariant)
                    Divider()
                    actions
                    if showSpeed { speedControls }
                    timeline
                    transport
                    if video.live != true {
                        downloadAudioButton
                        if let downloadError = downloads.errors[video.id] {
                            Text(downloadError).font(.footnote).foregroundStyle(Color.cvError)
                        }
                        if let audioError {
                            Text(audioError).font(.footnote).foregroundStyle(Color.cvError)
                        }
                    }
                    if let error = player.error {
                        Text(error).font(.footnote).foregroundStyle(Color.cvError)
                        Button("Reload player") { player.reload() }.buttonStyle(.bordered)
                    } else {
                        Text(player.status).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                            .accessibilityIdentifier("media.player.status")
                    }
                }.padding(16)
            }
          }
        }.background(Color.cvBackground).tint(.cvPrimary)
            .navigationTitle(video.title).navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar(.hidden, for: .tabBar)
            .sheet(isPresented: $showAddToPlaylist) { AddToPlaylistSheet(video: video, library: library) }
            .sheet(isPresented: $showAudioPlayer) { AudioPlayerView() }
            .alert("YouTube playback limitation", isPresented: Binding(get: { limitation != nil }, set: { if !$0 { limitation = nil } })) {
                Button("OK", role: .cancel) { limitation = nil }
            } message: { Text(limitation ?? "") }
            .alert("Reset Continue Watching?", isPresented: $showResetContinue) {
                Button("Reset", role: .destructive) {
                    message = MediaLibrary.resetContinueWatchingMessage(cleared: library.resetContinueWatching())
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This clears the resume position of every unfinished video, so Continue Watching starts over. Videos you finished keep their watched progress.")
            }
            .alert("Continue Watching", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
            .onChange(of: player.position) { _, _ in saveProgress() }
            .onChange(of: player.playing) { _, playing in
                if playing { hasPlayed = true }
                else { saveProgress(force: true) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { saveProgress(force: true); player.command("player.pauseVideo();") }
            }
            .onDisappear { saveProgress(force: true); player.command("player.pauseVideo();") }
    }

    /// The action row, and the ⋮ menu that carries what will not fit in it.
    ///
    /// The menu is Android's `VideoPlayerScreen` overflow: add to a playlist,
    /// hide the video, mark it watched, and the two Continue Watching controls —
    /// including the row-wide reset, which lives HERE rather than on the feed's
    /// own ⋮ because it is a decision about what you were watching.
    private var actions: some View {
        HStack(alignment: .top, spacing: 0) {
            Menu {
                Button("Add to playlist…", systemImage: "text.badge.plus") { showAddToPlaylist = true }
                Button(library.state.saved.contains { $0.id == video.id } ? "Remove from saved videos" : "Save video", systemImage: "bookmark") { library.toggleSave(video) }
                Button("Hide video", systemImage: "eye.slash") { library.hide(video) }
                // A live broadcast has no finite length to finish, so "watched"
                // would have nothing to mean.
                if video.live != true {
                    Button("Mark as watched", systemImage: "checkmark.circle") {
                        library.markWatched(video, duration: player.duration > 0 ? player.duration : Double(video.durationSeconds ?? 0))
                    }
                }
                Divider()
                Button("Reset Continue Watching", systemImage: "arrow.counterclockwise") { showResetContinue = true }
                Button("Reload player", systemImage: "arrow.clockwise") { player.reload() }
            } label: { actionLabel("More", symbol: "ellipsis", vertical: true) }.accessibilityIdentifier("media.player.more")
            ShareLink(item: video.url) { actionLabel("Share", symbol: "square.and.arrow.up") }.accessibilityIdentifier("media.player.share")
            Button { showSpeed.toggle() } label: { actionLabel("Speed", symbol: "speedometer") }.accessibilityIdentifier("media.player.speed")
            Button { showAddToPlaylist = true } label: { actionLabel("Playlist", symbol: "text.badge.plus") }.accessibilityLabel("Add to Playlist").accessibilityIdentifier("media.player.playlist")
        }.buttonStyle(.plain)
    }

    private func actionLabel(_ title: String, symbol: String, vertical: Bool = false) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).rotationEffect(.degrees(vertical ? 90 : 0)).font(.system(size: 23)).foregroundStyle(Color.cvPrimary).frame(height: 26)
            Text(title).font(.caption.bold()).foregroundStyle(Color.cvOnSurfaceVariant)
        }.frame(maxWidth: .infinity).frame(minHeight: 55)
    }

    private var speedControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Playback speed · \(player.rate.formatted())×").font(.subheadline.bold())
                Spacer()
                Button("Reset") { player.setRate(1) }.disabled(!player.rates.contains(1))
            }
            if player.rates.count > 1 {
                Slider(value: Binding(get: { Double(player.rates.firstIndex(of: player.rate) ?? 0) }, set: { player.setRate(player.rates[min(player.rates.count - 1, max(0, Int($0.rounded())))]) }), in: 0...Double(player.rates.count - 1), step: 1)
                    .accessibilityLabel("Playback speed")
                HStack { Text("\(player.rates.first!.formatted())×"); Spacer(); Text("\(player.rates.last!.formatted())×") }.font(.caption)
            } else { Text("Speed choices become available when YouTube reports support for this video.").font(.caption) }
        }.padding(12).background(Color.cvSurfaceVariant, in: RoundedRectangle(cornerRadius: 14))
    }

    private var timeline: some View {
        HStack(spacing: 8) {
            Text(Self.time(scrubbing ? scrubPosition : player.position)).monospacedDigit()
            Slider(value: Binding(get: { min(max(0, scrubbing ? scrubPosition : player.position), max(1, player.duration)) }, set: { scrubPosition = $0 }), in: 0...max(1, player.duration), onEditingChanged: { editing in
                if editing { scrubPosition = player.position; scrubbing = true }
                else { player.seek(to: scrubPosition); scrubbing = false }
            }).disabled(!player.canSeek || video.live == true).accessibilityLabel("Playback timeline").accessibilityIdentifier("media.player.timeline")
            Text(video.live == true ? "LIVE" : player.duration > 0 ? Self.time(player.duration) : "--:--").monospacedDigit()
        }.font(.caption.bold()).foregroundStyle(Color.cvOnSurfaceVariant)
    }

    private var transport: some View {
        HStack(spacing: 0) {
            transportButton("Back 10 seconds", symbol: "gobackward.10", enabled: player.canSeek && video.live != true) { player.skip(-10) }
            transportButton(player.playing ? "Pause" : "Play", symbol: player.playing ? "pause.fill" : "play.fill", enabled: player.ready && player.error == nil) { player.togglePlay() }
                .accessibilityIdentifier("media.player.playPause")
            transportButton("Forward 10 seconds", symbol: "goforward.10", enabled: player.canSeek && video.live != true) { player.skip(10) }
            transportButton(player.muted ? "Unmute" : "Mute", symbol: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", enabled: player.ready && player.error == nil) { player.toggleMute() }
                .accessibilityIdentifier("media.player.mute")
            transportButton(audioPreparing ? "Preparing audio" : "Audio mode", symbol: "headphones", enabled: !audioPreparing) {
                Task { await startAudioMode() }
            }.accessibilityIdentifier("media.player.audioMode")
        }.padding(.vertical, 4)
    }

    private func transportButton(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 27)).foregroundStyle(enabled ? Color.cvPrimary : Color.cvOnSurfaceVariant.opacity(0.45)).frame(maxWidth: .infinity).frame(height: 48) }
            .buttonStyle(.plain).disabled(!enabled).accessibilityLabel(title)
    }

    private func saveProgress(force: Bool = false) {
        guard hasPlayed, video.live != true, player.ready, player.duration > 0, player.position > 0,
              force || Date().timeIntervalSince(lastSaved) >= 5 else { return }
        library.recordProgress(video, position: player.position, duration: player.duration)
        lastSaved = Date()
    }

    // MARK: - Audio

    /// Starts background playback for this video: the downloaded file when there
    /// is one, otherwise a freshly resolved audio-only stream.
    ///
    /// The saved file is preferred deliberately — it is guaranteed playable and
    /// costs no network — and it is also why "Audio mode" works on a plane for a
    /// video that was downloaded.
    private func startAudioMode() async {
        guard !audioPreparing else { return }
        audioError = nil
        saveProgress(force: true)
        let audioStart = player.position > 0 ? player.position : start
        player.command("player.pauseVideo();")
        let controller = AudioPlaybackController.shared

        if let fileURL = downloads.fileURL(for: video.id) {
            controller.playLocal(videoId: video.id, title: video.title, channel: video.channel,
                                 artworkURL: video.thumbnail, fileURL: fileURL, startAt: audioStart)
            showAudioPlayer = true
            return
        }

        audioPreparing = true
        defer { audioPreparing = false }
        do {
            let extracted = try await YouTubeAudioExtractor().extractAudio(videoId: video.id)
            controller.playStream(videoId: video.id, title: video.title, channel: video.channel,
                                  artworkURL: video.thumbnail, streamURL: extracted.url, startAt: audioStart,
                                  resolver: { try await YouTubeAudioExtractor().extractAudio(videoId: video.id).url })
            showAudioPlayer = true
        } catch {
            audioError = error.localizedDescription
        }
    }

    /// The Download Audio control, in whichever of its four states applies:
    /// not downloaded, resolving, downloading with progress, already saved.
    ///
    /// The saved state offers **Play offline** rather than reporting
    /// "Downloaded": the reader who tapped Download asked to listen without a
    /// network, and that is now one tap on this screen instead of a trip to the
    /// Downloads list.
    @ViewBuilder
    private var downloadAudioButton: some View {
        let item = downloads.isDownloaded(video.id) ? downloads.item(for: video.id) : nil
        let update = downloads.progress[video.id]
        if let item {
            // Play only. Deleting a download is a decision about the library, not
            // about this video, and the Downloads list already offers it on the
            // row's own menu — a destructive button parked under the thumb that
            // reaches for play is an accident waiting to happen.
            Button { playOffline(item) } label: {
                Label("Play offline", systemImage: "play.circle.fill")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(Color.cvSurfaceVariant, in: Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("media.player.playOffline")
        } else if let update {
            VStack(spacing: 8) {
                if update.fraction < 0 {
                    ProgressView()
                } else {
                    ProgressView(value: update.fraction)
                }
                HStack {
                    Text(update.phase == .resolving ? "Finding the audio…" : update.phase == .processing ? "Preparing audio file…" : "Downloading…")
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    Spacer(minLength: 8)
                    Button("Cancel", role: .destructive) { downloads.cancel(video.id) }.font(.caption.bold())
                }
            }
            .padding(14)
            .background(Color.cvSurfaceVariant, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityIdentifier("media.player.downloading")
        } else {
            Button { downloads.download(video) } label: {
                Label("Download Audio", systemImage: "arrow.down.to.line")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(Color.cvSurfaceVariant, in: Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("media.player.downloadAudio")
        }
    }

    /// Plays the saved file, from the screen the reader downloaded it on.
    ///
    /// Same hand-off as Audio mode with one difference: there is nothing to
    /// resolve and nothing that can expire, which is the point of the download.
    /// The position is not carried over from the embedded player deliberately —
    /// this button is for starting the downloaded track, and Audio mode is the
    /// control for continuing where the video player is.
    private func playOffline(_ item: AudioDownloadItem) {
        guard let fileURL = downloads.fileURL(for: video.id) else {
            // The manifest outlived its file: drop the row rather than offer a
            // button that plays nothing.
            downloads.remove(item)
            return
        }
        saveProgress(force: true)
        player.command("player.pauseVideo();")
        AudioPlaybackController.shared.playLocal(
            videoId: video.id, title: video.title, channel: video.channel,
            artworkURL: video.thumbnail, fileURL: fileURL
        )
        downloads.markPlayed(video.id)
        showAudioPlayer = true
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = Int(max(0, seconds))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

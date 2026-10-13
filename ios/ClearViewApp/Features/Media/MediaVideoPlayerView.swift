import SwiftUI

struct MediaVideoPlayerView: View {
    let video: LibraryVideo
    let reference: YouTubeRef
    let library: MediaLibrary
    @State private var player = YouTubePlayer()
    @State private var showSpeed = false
    @State private var showPlaylists = false
    @State private var limitation: String?
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
                        Button {
                            limitation = "YouTube's embedded player does not provide audio downloads. Audio extraction and offline playback are not available in this iOS build."
                        } label: {
                            Label("Download Audio", systemImage: "arrow.down.to.line")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
                                .background(Color.cvSurfaceVariant, in: Capsule())
                        }.buttonStyle(.plain).accessibilityIdentifier("media.player.downloadAudio")
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
            .sheet(isPresented: $showPlaylists) { MediaPlaylistPicker(video: video, library: library) }
            .alert("YouTube playback limitation", isPresented: Binding(get: { limitation != nil }, set: { if !$0 { limitation = nil } })) {
                Button("OK", role: .cancel) { limitation = nil }
            } message: { Text(limitation ?? "") }
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

    private var actions: some View {
        HStack(alignment: .top, spacing: 0) {
            Menu {
                Button(library.state.saved.contains { $0.id == video.id } ? "Remove from saved videos" : "Save video", systemImage: "bookmark") { library.toggleSave(video) }
                Button("Hide video", systemImage: "eye.slash") { library.hide(video) }
                Button("Reload player", systemImage: "arrow.clockwise") { player.reload() }
            } label: { actionLabel("More", symbol: "ellipsis", vertical: true) }.accessibilityIdentifier("media.player.more")
            ShareLink(item: video.url) { actionLabel("Share", symbol: "square.and.arrow.up") }.accessibilityIdentifier("media.player.share")
            Button { showSpeed.toggle() } label: { actionLabel("Speed", symbol: "speedometer") }.accessibilityIdentifier("media.player.speed")
            Button { showPlaylists = true } label: { actionLabel("Playlist", symbol: "text.badge.plus") }.accessibilityLabel("Add to Playlist").accessibilityIdentifier("media.player.playlist")
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
            transportButton("Audio mode", symbol: "headphones", enabled: true) {
                limitation = "You can listen while the video remains visible here. Background or audio-only YouTube playback is not supported by the embedded player; leaving this screen pauses playback."
            }
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

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "00:00" }
        let total = Int(max(0, seconds))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct MediaPlaylistPicker: View {
    let video: LibraryVideo
    @Bindable var library: MediaLibrary
    @State private var showCreate = false
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button("Create playlist", systemImage: "plus") { showCreate = true }
                if library.state.playlists.isEmpty { Text("Create a playlist to keep your videos together.").foregroundStyle(Color.cvOnSurfaceVariant) }
                ForEach(library.state.playlists) { playlist in
                    Button {
                        library.add(video, to: playlist.id)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "play.rectangle.on.rectangle").foregroundStyle(Color.cvPrimary)
                            VStack(alignment: .leading) { Text(playlist.name); Text("\(playlist.videos.count) videos").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant) }
                            Spacer()
                            if playlist.videos.contains(where: { $0.id == video.id }) { Image(systemName: "checkmark") }
                        }
                    }.buttonStyle(.plain)
                }
            }.navigationTitle("Add to Playlist").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .alert("New playlist", isPresented: $showCreate) {
                    TextField("Playlist name", text: $name)
                    Button("Create and add") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        let playlist = MediaPlaylist(name: trimmed)
                        library.state.playlists.append(playlist)
                        library.add(video, to: playlist.id)
                        dismiss()
                    }
                    Button("Cancel", role: .cancel) {}
                }
        }.tint(.cvPrimary)
    }
}

import SwiftUI
import AVKit

struct SocialMediaPlayerView: View {
    let video: LibraryVideo
    let library: MediaLibrary
    @State private var player: AVPlayer?
    @State private var stream: URL?
    @State private var loading = false
    @State private var error: String?
    @State private var showAudio = false
    @State private var downloads = AudioDownloads.shared
    @State private var requestID = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let player {
                    VideoPlayer(player: player)
                        .frame(height: video.isShortsEntry ? 420 : 240)
                } else if loading { ProgressView().frame(maxWidth: .infinity, minHeight: 240) }
                Text(video.title).font(.title3.bold())
                Text(video.channel).font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                if let error { Text(error).font(.footnote).foregroundStyle(Color.cvError) }
                if stream != nil || downloads.fileURL(for: video.id) != nil {
                    Button {
                        player?.pause()
                        let controller = AudioPlaybackController.shared
                        if let file = downloads.fileURL(for: video.id) {
                            controller.playLocal(videoId: video.id, title: video.title, channel: video.channel,
                                artworkURL: video.thumbnail, fileURL: file, startAt: player?.currentTime().seconds ?? 0)
                        } else if let stream {
                            controller.playStream(videoId: video.id, title: video.title, channel: video.channel,
                                artworkURL: video.thumbnail, streamURL: stream, startAt: player?.currentTime().seconds ?? 0,
                                resolver: { try await SocialMediaStreamResolver.shared.resolve(video, fresh: true) })
                        }
                        showAudio = true
                    } label: { Label("Audio mode", systemImage: "headphones") }
                    .buttonStyle(.bordered).accessibilityIdentifier("media.social.audioMode")
                }
                if let item = downloads.item(for: video.id), downloads.isDownloaded(video.id) {
                    // Play only, for the same reason as the video player: removing a
                    // download belongs to the Downloads list, not under the play
                    // button.
                    Button { playOffline(item) } label: { Label("Play offline", systemImage: "play.circle.fill") }
                        .buttonStyle(.bordered).accessibilityIdentifier("media.social.playOffline")
                } else if let update = downloads.progress[video.id] {
                    ProgressView(value: update.fraction >= 0 ? update.fraction : nil)
                    Text(update.phase == .processing ? "Preparing audio file…" : "Downloading audio…").font(.caption)
                    Button("Cancel download", role: .destructive) { downloads.cancel(video.id) }
                } else {
                    Button { downloads.download(video) } label: { Label("Download Audio", systemImage: "arrow.down.to.line") }
                        .buttonStyle(.bordered).accessibilityIdentifier("media.social.downloadAudio")
                }
                if let error = downloads.errors[video.id] { Text(error).font(.footnote).foregroundStyle(Color.cvError) }
                Button("Retry video") { requestID += 1 }.buttonStyle(.bordered)
                ShareLink(item: video.url) { Label("Share post", systemImage: "square.and.arrow.up") }
                if let url = URL(string: video.url) { Link("Open on \(video.mediaVideo.platform.label)", destination: url) }
            }.padding(16)
        }
        .background(Color.cvBackground).tint(Color.cvPrimary)
        .navigationTitle(video.channel).navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showAudio) { AudioPlayerView() }
        .task(id: requestID) { await load() }
        .onDisappear {
            if let player, player.currentTime().seconds.isFinite {
                library.recordProgress(video, position: player.currentTime().seconds,
                                       duration: player.currentItem?.duration.seconds ?? 0)
            }
            player?.pause()
        }
    }

    /// Plays the downloaded audio for this post — the reason the Download button
    /// became a play button once the file exists.
    private func playOffline(_ item: AudioDownloadItem) {
        guard let file = downloads.fileURL(for: video.id) else {
            downloads.remove(item)
            return
        }
        player?.pause()
        AudioPlaybackController.shared.playLocal(
            videoId: video.id, title: video.title, channel: video.channel,
            artworkURL: video.thumbnail, fileURL: file
        )
        downloads.markPlayed(video.id)
        showAudio = true
    }

    private func load() async {
        loading = true
        error = nil
        player?.pause()
        defer { loading = false }
        do {
            let url = try await SocialMediaStreamResolver.shared.resolve(video, fresh: requestID > 0)
            try Task.checkCancellation()
            stream = url
            let native = AVPlayer(url: url)
            player = native
            native.play()
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

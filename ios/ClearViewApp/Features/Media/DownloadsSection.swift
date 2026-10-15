import SwiftUI

/// The offline Downloads list — the counterpart of Android's `DownloadsUi`.
///
/// Two kinds of row in one list: what is already on disk, and what is arriving.
/// A download in flight is shown in place rather than in a separate queue, so
/// the reader sees the item they asked for appear exactly once and watch it fill
/// rather than watching it move between two sections.
struct DownloadsSection: View {
    @State private var downloads = AudioDownloads.shared
    @State private var showPlayer = false

    var body: some View {
        VStack(spacing: 12) {
            // A failed download leaves no row behind (its progress entry is gone),
            // so the reason has to be surfaced separately or the audio would
            // simply never appear with no explanation.
            ForEach(failureMessages, id: \.self) { message in
                CVErrorBanner(message: message)
            }
            if downloads.items.isEmpty && downloads.progress.isEmpty && failureMessages.isEmpty {
                CVEmptyState(
                    title: "No audio downloaded yet",
                    message: "Open a video and choose Download Audio to keep its audio on this device for offline listening.",
                    symbol: "arrow.down.circle"
                )
            }
            LazyVStack(spacing: 12) {
                ForEach(downloads.progress.keys.sorted(), id: \.self) { videoId in
                    progressRow(videoId)
                }
                ForEach(downloads.items) { item in
                    row(item)
                }
            }
        }
        .onAppear { downloads.reload() }
        .sheet(isPresented: $showPlayer) { AudioPlayerView() }
    }

    private func progressRow(_ videoId: String) -> some View {
        let update = downloads.progress[videoId] ?? AudioDownloadProgress()
        return CVCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(title(for: videoId)).font(.subheadline.weight(.semibold)).lineLimit(1)
                if update.phase == .resolving || update.phase == .processing {
                    Text(update.phase == .processing ? "Preparing audio file…" : "Finding the audio…").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    ProgressView().progressViewStyle(.linear)
                } else if update.fraction < 0 {
                    Text("Downloading…").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    ProgressView().progressViewStyle(.linear)
                } else {
                    Text("\(Int(update.fraction * 100))% downloaded").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    ProgressView(value: update.fraction).progressViewStyle(.linear)
                }
                Button("Cancel", role: .destructive) { downloads.cancel(videoId) }.font(.caption.bold())
            }
        }.accessibilityIdentifier("downloads.progress.\(videoId)")
    }

    private func row(_ item: AudioDownloadItem) -> some View {
        CVCard {
            HStack(spacing: 12) {
                Button { play(item) } label: {
                    ZStack {
                        AsyncImage(url: item.thumbnailPath.isEmpty ? nil : URL(string: item.thumbnailPath)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            ZStack { Color.cvSurfaceContainerHigh; Image(systemName: "headphones").foregroundStyle(Color.cvOnSurfaceVariant) }
                        }
                        .frame(width: 64, height: 48).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                        Image(systemName: "play.circle.fill").font(.system(size: 22)).foregroundStyle(.white)
                    }
                }.buttonStyle(.plain).accessibilityLabel("Play \(item.title)")
                    .accessibilityIdentifier("downloads.play.\(item.videoId)")

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(item.channelName).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant).lineLimit(1)
                    Text(Self.fileSizeLabel(item.fileSize)).font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                }
                Spacer(minLength: 0)
                Menu {
                    Button("Play", systemImage: "play.fill") { play(item) }
                    Button("Remove download", systemImage: "trash", role: .destructive) { downloads.remove(item) }
                } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(width: 44, height: 44)
                }.accessibilityLabel("Options for \(item.title)")
            }
        }
    }

    private func play(_ item: AudioDownloadItem) {
        guard let url = downloads.fileURL(for: item.videoId) else {
            downloads.remove(item)
            return
        }
        let controller = AudioPlaybackController.shared
        controller.playLocal(
            videoId: item.videoId,
            title: item.title,
            channel: item.channelName,
            artworkURL: item.thumbnailPath.isEmpty ? nil : item.thumbnailPath,
            fileURL: url
        )
        downloads.markPlayed(item.videoId)
        showPlayer = true
    }

    /// The title to show for an in-flight download. The manifest does not have
    /// the item yet, so the manager hands the title over until it finishes.
    private func title(for videoId: String) -> String {
        downloads.pendingTitles[videoId]
            ?? downloads.items.first { $0.videoId == videoId }?.title
            ?? "Downloading…"
    }

    /// Why each failed download failed, newest first and deduplicated. The
    /// `__manifest` key is the manager's own save failure rather than a video's.
    private var failureMessages: [String] {
        var seen = Set<String>()
        return downloads.errors
            .sorted { $0.key < $1.key }
            .map(\.value)
            .filter { seen.insert($0).inserted }
    }

    private static func fileSizeLabel(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

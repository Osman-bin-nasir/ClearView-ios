import SwiftUI
import AVFoundation
import UIKit

/// Still frames for a channel's clips, extracted on this device.
///
/// The same reason Android has one: a clip's bytes are not a picture, so asking the image loader
/// for one downloads the entire file to fail decoding it. A grid of clips drawn that way is a
/// grid of empty tiles, and each tile that tried is a wasted download.
///
/// Kept in memory only, and bounded: a poster is a view of a file that is still on the server, so
/// it is cheap to make again and never worth a disk format of its own.
@MainActor
@Observable
final class VideoPosterCache {
    static let shared = VideoPosterCache()

    private var posters: [String: UIImage] = [:]
    private var inFlight: Set<String> = []
    /// A grid draws a bounded number of tiles at once; holding more than a few screens of them
    /// is memory spent on pictures nobody is looking at.
    private let limit = 60

    func poster(for url: URL) -> UIImage? { posters[url.absoluteString] }

    func load(_ url: URL) async {
        let key = url.absoluteString
        guard posters[key] == nil, !inFlight.contains(key) else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        // The stored copy when the reader has watched this clip: extracting a frame from the
        // file on the device costs nothing, where the remote URL costs the whole download again.
        let source = GoodPostVideoCache.shared.playbackURL(for: url.absoluteString) ?? url
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        // A clip shot in portrait carries a rotation, and a poster that ignores it is sideways.
        generator.appliesPreferredTrackTransform = true
        // Twice the tile, so it is sharp on a 3x screen without decoding a full frame to fill
        // 104 points.
        generator.maximumSize = CGSize(width: 300, height: 300)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        guard let (image, _) = try? await generator.image(at: .zero) else { return }
        if posters.count >= limit { posters.removeAll() }
        posters[key] = UIImage(cgImage: image)
    }
}

/// Everything a channel has posted as media.
///
/// A screen rather than an expansion of the strip on the information page: the strip is a
/// preview, and walking back through a channel's history needs the whole screen.
struct ChannelMediaGalleryView: View {
    let channel: GoodPostChannel
    let repository: GoodPostRepository
    @State private var items: [GoodPostMediaItem] = []
    @State private var nextCursor: String?
    @State private var loading = false
    @State private var message: String?
    @State private var viewing: GoodPostMediaItem?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        ScrollView {
            if !items.isEmpty {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(items) { item in
                        Button { viewing = item } label: { ChannelMediaCell(item: item) }
                            .buttonStyle(.plain)
                            .disabled((item.url ?? "").trimmed.isEmpty)
                    }
                }.padding(.horizontal, 16).padding(.top, 12)
            }
            if loading { ProgressView().frame(maxWidth: .infinity).padding(24) }
            if let message {
                CVErrorBanner(message: message) { Task { await load() } }.padding(.horizontal, 16)
            }
            if !loading && items.isEmpty && message == nil {
                CVEmptyState(
                    title: "Nothing here yet",
                    message: "This channel hasn't posted a photo or a clip.",
                    symbol: "photo.on.rectangle"
                ).padding(24)
            }
            if nextCursor != nil {
                Button("Load more") { Task { await load(more: true) } }
                    .frame(maxWidth: .infinity).padding(20).disabled(loading)
            }
            Spacer(minLength: 24)
        }
        .background(Color.cvBackground)
        .navigationTitle("Media and links")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $viewing) { ChannelMediaViewer(item: $0) }
    }

    private func load(more: Bool = false) async {
        if more && (loading || nextCursor == nil) { return }
        loading = true
        defer { loading = false }
        if !more { items = [] }
        let result = await repository.channelMedia(channelId: channel.id, cursor: more ? nextCursor : nil)
        if let page = result.value {
            let existing = Set(items.map(\.id))
            items = more ? items + page.items.filter { !existing.contains($0.id) } : page.items
            nextCursor = page.nextCursor
            message = nil
        } else {
            message = result.userMessage
        }
    }
}

/// One tile.
private struct ChannelMediaCell: View {
    let item: GoodPostMediaItem
    @State private var poster: UIImage?

    var body: some View {
        ZStack {
            Color.cvSurfaceContainer
            if item.isVideo {
                if let poster {
                    Image(uiImage: poster).resizable().scaledToFill()
                }
                Image(systemName: "play.fill")
                    .font(.caption).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(.black.opacity(0.45), in: Circle())
            } else if let raw = item.url {
                RemoteImage(url: raw, maxPixelSize: 720, placeholder: AnyView(ProgressView()))
            }
        }
        .frame(height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Keyed on the URL: a signed URL is refreshed on a re-read, and a poster from the old one
        // is the same frame — but a tile that was a photo before must not keep a stale poster if
        // it is reused for a different item.
        .task(id: item.url) {
            guard item.isVideo, let raw = item.url, let url = URL(string: raw) else { return }
            poster = VideoPosterCache.shared.poster(for: url)
            await VideoPosterCache.shared.load(url)
            poster = VideoPosterCache.shared.poster(for: url)
        }
    }
}

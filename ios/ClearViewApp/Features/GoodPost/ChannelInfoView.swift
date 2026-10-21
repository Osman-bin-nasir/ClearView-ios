import SwiftUI
import AVKit

/// The state behind a channel's information page.
///
/// The page reads the channel itself rather than trusting the row it was opened from: the row
/// is a list's copy, and a list's copy is the one that was read with the list — a channel whose
/// description or picture changed since would draw the old one here, which is the place most
/// likely to be looked at for exactly that.
@MainActor
@Observable
final class ChannelInfoModel {
    let repository: GoodPostRepository
    private(set) var channel: GoodPostChannel
    var media: [GoodPostMediaItem] = []
    var mediaLoading = false
    /// The reader's notification choice for this channel. Seeded from the row and then owned
    /// by the server, which is where a mute lives — so a reader who reinstalls keeps it.
    var muted: Bool
    /// How many messages this device has starred from this channel. Local, and costs no
    /// request to draw: the stars are on this phone.
    var starredCount = 0
    var loading = false
    var busy = false
    var message: String?
    var descriptionExpanded = false

    init(channel: GoodPostChannel, repository: GoodPostRepository) {
        self.channel = channel
        self.repository = repository
        self.muted = channel.notificationsMuted
    }

    /// The line under the name: what this is, and the one number that belongs beside it.
    ///
    /// "Public channel" rather than a follower count alone, and the count only when there is
    /// one — a channel nobody follows yet saying "0 followers" is a scoreboard for a game
    /// nobody has joined.
    var followerLine: String {
        guard channel.followerCount > 0 else { return "No followers yet" }
        return "\(channel.followerCount) \(channel.followerCount == 1 ? "follower" : "followers")"
    }

    /// When the channel started, or nil when the payload's instant is unreadable.
    ///
    /// `03/10/26` — day first, fixed width, month as a number. Deliberately NOT the locale's
    /// own ordering: this line sits on a public page beside a channel's own words, and a
    /// profile that renders as `10/3/26` for one reader and `3/10/26` for the next is two
    /// different dates for one fact. Numeric rather than "3 Oct 2026" because it is a
    /// timestamp on a page, not a sentence.
    var createdOn: String? {
        guard let milliseconds = parseIsoMillis(channel.createdAt) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "dd/MM/yy"
        return formatter.string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    /// Whether there is enough description for "Read more" to be worth offering.
    ///
    /// Collapsed by line count and expanded by a count that is only a threshold — what has to
    /// fit is the screen, and a character budget that looks right on one device is two lines on
    /// another.
    var descriptionCanExpand: Bool { (channel.description ?? "").count > 80 }

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let result = await repository.channel(idOrSlug: channel.id)
        if let value = result.value {
            channel = value
            muted = value.notificationsMuted
            message = nil
        } else {
            message = result.userMessage
        }
        starredCount = GoodPostStarredStore().forChannel(channel.id).count
        await loadMedia()
    }

    func loadMedia() async {
        mediaLoading = true
        defer { mediaLoading = false }
        if let page = await repository.channelMedia(channelId: channel.id).value { media = page.items }
    }

    func setMuted(_ wanted: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let result = await repository.setChannelMuted(idOrSlug: channel.id, muted: wanted)
        if let follow = result.value {
            muted = follow.notificationsMuted
            message = nil
        } else {
            message = result.userMessage
        }
    }

    /// Take the channel the server just saved.
    ///
    /// Handed over rather than re-read: the page behind the edit form draws its own copy, and a
    /// reload of a list does not touch it — so without this the new picture only appeared when
    /// the channel was closed and opened again, which reads as "my change did not save".
    func apply(_ updated: GoodPostChannel) {
        channel = updated
        muted = updated.notificationsMuted
    }
}

/// A channel's information page.
///
/// The shape a channel profile has: the picture, the name, what this is, the three things a
/// reader can do with it, the description, when it started, what it has published, and its
/// notification switch. It is the screen the edit form is reached from, which is what makes a
/// channel's picture changeable at all.
struct ChannelInfoView: View {
    @Bindable var model: GoodPostScreenModel
    /// The channel as the screen that opened this page holds it, so an edit here is visible
    /// there without a reload.
    let onUpdated: (GoodPostChannel) -> Void
    @State private var info: ChannelInfoModel
    @State private var editing = false
    @State private var searching = false
    @State private var viewing: GoodPostMediaItem?

    init(
        channel: GoodPostChannel,
        model: GoodPostScreenModel,
        onUpdated: @escaping (GoodPostChannel) -> Void
    ) {
        self.model = model
        self.onUpdated = onUpdated
        _info = State(initialValue: ChannelInfoModel(channel: channel, repository: model.repository))
    }

    private var following: Bool { model.followedIDs.contains(info.channel.id) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                avatar
                Text(info.channel.name)
                    .font(.title2.bold()).multilineTextAlignment(.center)
                    .padding(.horizontal, 24).padding(.top, 18)
                Text("Public channel · \(info.followerLine)")
                    .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                    .multilineTextAlignment(.center).padding(.horizontal, 24).padding(.top, 6)
                actions.padding(.top, 24)
                if let message = info.message {
                    CVErrorBanner(message: message) { Task { await info.load() } }
                        .padding(.horizontal, 16).padding(.top, 20)
                }
                description.padding(.top, 24)
                createdLine.padding(.top, 16)
                mediaStrip.padding(.top, 24)
                notifications.padding(.top, 24)
                starred.padding(.top, 16)
                Spacer(minLength: 40)
            }
        }
        .background(Color.cvBackground)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: info.channel.shareLink) { Image(systemName: "square.and.arrow.up") }
                Menu {
                    ShareLink(item: info.channel.shareLink) { Label("Share link", systemImage: "square.and.arrow.up") }
                    // Only where the account may actually change it. Deleting is deliberately
                    // not here: an irreversible action does not belong a slip away from Share.
                    if model.canManage(info.channel.id) {
                        Button("Edit channel", systemImage: "pencil") { editing = true }
                    }
                } label: {
                    Image(systemName: "ellipsis").rotationEffect(.degrees(90))
                }
                .accessibilityLabel("Channel options")
            }
        }
        .task { await info.load() }
        .refreshable { await info.load() }
        .sheet(isPresented: $editing, onDismiss: { Task { await info.load() } }) {
            ChannelFormView(
                channel: info.channel,
                isSuperAdmin: model.session?.isSuperAdmin == true,
                repository: model.repository
            ) { updated in
                info.apply(updated)
                model.applyUpdatedChannel(updated)
                onUpdated(updated)
            }
        }
        .sheet(isPresented: $searching) {
            ChannelSearchSheet(channel: info.channel, repository: model.repository)
        }
        .sheet(item: $viewing) { ChannelMediaViewer(item: $0) }
    }

    private var avatar: some View {
        CVAvatar(name: info.channel.name, url: info.channel.iconUrl, size: 116)
            .padding(.top, 20)
    }

    private var actions: some View {
        HStack(spacing: 0) {
            ChannelInfoAction(
                symbol: following ? "checkmark" : "plus",
                label: following ? "Following" : "Follow",
                tint: following ? Color.cvPrimary : Color.cvOnSurface,
                busy: model.pendingFollows.contains(info.channel.id)
            ) {
                Task { await model.toggleFollow(info.channel) }
            }
            ShareLink(item: info.channel.shareLink) {
                ChannelInfoActionLabel(symbol: "square.and.arrow.up", label: "Share link")
            }.buttonStyle(.plain)
            ChannelInfoAction(symbol: "magnifyingglass", label: "Search") { searching = true }
        }
    }

    private var description: some View {
        CVCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Channel description").font(.subheadline.bold())
                Text(info.channel.description?.trimmed.isEmpty == false ? info.channel.description! : "No description yet")
                    .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                    .lineLimit(info.descriptionExpanded ? nil : 3)
                if !info.descriptionExpanded && info.descriptionCanExpand {
                    Button("Read more") { info.descriptionExpanded = true }
                        .font(.subheadline.bold()).padding(.top, 2)
                }
            }
        }.padding(.horizontal, 16)
    }

    @ViewBuilder
    private var createdLine: some View {
        if let createdOn = info.createdOn {
            HStack {
                Text("Created on \(createdOn)")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                Spacer(minLength: 0)
            }.padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private var mediaStrip: some View {
        // Drawn only when there is something to draw: an empty strip on a brand-new channel is
        // a heading over nothing.
        if !info.media.isEmpty || info.mediaLoading {
            VStack(alignment: .leading, spacing: 10) {
                // This row is the way into the gallery. A heading with a count beside it that
                // does not react to a tap reads as a screen that has stopped working — which is
                // what this was before the gallery existed.
                NavigationLink {
                    ChannelMediaGalleryView(channel: info.channel, repository: model.repository)
                } label: {
                    HStack {
                        Text("Media and links").font(.subheadline.bold()).foregroundStyle(Color.cvOnSurface)
                        Spacer(minLength: 0)
                        if !info.media.isEmpty {
                            Text("\(info.media.count)")
                                .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                        }
                    }.padding(.horizontal, 20).contentShape(Rectangle())
                }.buttonStyle(.plain)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(info.media) { item in
                            Button { viewing = item } label: { ChannelMediaThumbnail(item: item) }
                                .buttonStyle(.plain)
                                .disabled((item.url ?? "").trimmed.isEmpty)
                        }
                    }.padding(.horizontal, 20)
                }
            }
        }
    }

    private var notifications: some View {
        CVCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Notifications").font(.subheadline.bold())
                Text(!following
                    ? "Follow this channel to turn notifications on."
                    : (info.muted ? "New posts are not announced." : "New posts are announced."))
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                if following {
                    Toggle("Notify me about new posts", isOn: Binding(
                        get: { !info.muted },
                        set: { wanted in Task { await info.setMuted(!wanted) } }
                    ))
                    .labelsHidden()
                    .disabled(info.busy)
                    .padding(.top, 4)
                }
            }
        }.padding(.horizontal, 16)
    }

    private var starred: some View {
        NavigationLink {
            GoodPostStarredView(channelId: info.channel.id, repository: model.repository)
        } label: {
            CVCard {
                HStack(spacing: 12) {
                    Image(systemName: "star.fill").foregroundStyle(Color.cvPrimary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Starred messages").font(.subheadline.bold()).foregroundStyle(Color.cvOnSurface)
                        Text(info.starredCount == 0
                            ? "Nothing starred in this channel yet."
                            : "\(info.starredCount) saved on this iPhone.")
                            .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }
            }.padding(.horizontal, 16)
        }.buttonStyle(.plain)
    }
}

/// One of the three channel actions: a round control with its label underneath.
private struct ChannelInfoAction: View {
    let symbol: String
    let label: String
    var tint: Color = .cvOnSurface
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.cvSurfaceContainer).frame(width: 60, height: 60)
                    if busy {
                        ProgressView().tint(.cvPrimary)
                    } else {
                        Image(systemName: symbol).font(.title3).foregroundStyle(tint)
                    }
                }
                Text(label).font(.footnote.weight(.medium)).foregroundStyle(busy ? Color.cvOnSurfaceVariant : tint)
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
    }
}

/// The same shape for the share control, which is a `ShareLink` rather than a button.
private struct ChannelInfoActionLabel: View {
    let symbol: String
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.cvSurfaceContainer).frame(width: 60, height: 60)
                Image(systemName: symbol).font(.title3).foregroundStyle(Color.cvOnSurface)
            }
            Text(label).font(.footnote.weight(.medium)).foregroundStyle(Color.cvOnSurface)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(label)
    }
}

/// One square thumbnail in the channel's strip.
private struct ChannelMediaThumbnail: View {
    let item: GoodPostMediaItem

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let raw = item.url {
                RemoteImage(url: raw, placeholder: AnyView(Color.cvSurfaceContainer))
            } else {
                Color.cvSurfaceContainer
            }
            if item.isVideo {
                Label("Video", systemImage: "video.fill")
                    .labelStyle(.iconOnly)
                    .font(.caption2).foregroundStyle(.white)
                    .padding(5).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }
        }
        .frame(width: 100, height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// A channel's file, opened in the app.
///
/// Deliberately not the browser: a signed URL is a capability for one client, not a page, and a
/// browser answers a bare GET with a refusal. The same reason Android stopped handing these out.
struct ChannelMediaViewer: View {
    let item: GoodPostMediaItem
    @Environment(\.dismiss) private var dismiss

    private var url: URL? { item.url.flatMap(URL.init(string:)) }

    var body: some View {
        NavigationStack {
            Group {
                if let url, item.isVideo {
                    // Opened through the same cache as the inline player: a clip watched in the
                    // gallery is on this device afterwards, so watching it again costs nothing.
                    GoodPostVideoPlayer(url: url)
                } else if let url {
                    // The full-size viewer: the cache answers this from disk when the picture
                    // has been seen once, which is what makes the gallery work offline.
                    RemoteImage(url: url.absoluteString, contentMode: .fit, maxPixelSize: 2_400,
                                placeholder: AnyView(ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)))
                } else {
                    CVEmptyState(title: "Not available", message: "This file cannot be opened right now.", symbol: "photo")
                }
            }
            .navigationTitle(item.fileName ?? (item.isVideo ? "Video" : "Photo"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .tint(.cvPrimary)
    }
}

/// Search the messages in ONE channel.
///
/// Its own screen rather than a mode of the feed, because the results are not the channel's
/// history — which is also why the repository keeps them out of the post cache.
struct ChannelSearchSheet: View {
    let channel: GoodPostChannel
    let repository: GoodPostRepository
    @Environment(\.dismiss) private var dismiss
    @State private var term = ""
    @State private var results: [GoodPostPost] = []
    @State private var loading = false
    @State private var message: String?
    @State private var searched = false

    var body: some View {
        NavigationStack {
            List {
                if let message { CVErrorBanner(message: message) }
                ForEach(results) { post in
                    VStack(alignment: .leading, spacing: 6) {
                        if let body = post.body, !body.isEmpty {
                            Text(body).lineLimit(4)
                        } else {
                            Text("Media post").foregroundStyle(Color.cvOnSurfaceVariant)
                        }
                        Text(String(post.createdAt.prefix(10)))
                            .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                }
                if loading { ProgressView() }
                if searched && !loading && results.isEmpty && message == nil {
                    Text("Nothing in this channel matches that.").foregroundStyle(Color.cvOnSurfaceVariant)
                }
            }
            .navigationTitle("Search \(channel.name)")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $term, prompt: "Search this channel")
            .onSubmit(of: .search) { Task { await search() } }
            .onChange(of: term) { _, value in
                if value.trimmed.isEmpty { results = []; searched = false }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .tint(.cvPrimary)
    }

    private func search() async {
        let query = term.trimmed
        guard !query.isEmpty else { return }
        loading = true
        defer { loading = false }
        let result = await repository.searchChannelPosts(channelId: channel.id, term: query)
        if let page = result.value {
            results = page.items
            message = nil
        } else {
            message = result.userMessage
        }
        searched = true
    }
}

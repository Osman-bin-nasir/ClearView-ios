import SwiftUI
import AVKit

struct GoodPostView: View {
    @State private var model = GoodPostScreenModel()
    @State private var search = ""
    @State private var savedOnly = false
    @State private var followingOnly = false
    @State private var showPublisher = false
    @State private var linkedChannel: GoodPostChannel?
    @Environment(Router.self) private var router

    private var channels: [GoodPostChannel] {
        model.channels.filter { (!savedOnly || model.savedIDs.contains($0.id)) && (!followingOnly || model.followedIDs.contains($0.id)) &&
            (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top) {
                        CVSectionHeader(title: "Good words. Good company.", subtitle: "Updates from the voices you choose.")
                        Image(systemName: "sparkles").font(.title2).foregroundStyle(Color.cvPrimary)
                    }.padding(.top, 8)
                    HStack {
                        CVChip(title: "All", selected: !savedOnly && !followingOnly) { savedOnly = false; followingOnly = false }
                        CVChip(title: "Following", selected: followingOnly) { savedOnly = false; followingOnly = true }
                        CVChip(title: "Saved", selected: savedOnly) { savedOnly = true; followingOnly = false }
                    }
                    if let message = model.message { CVErrorBanner(message: message) { Task { await model.load() } } }
                    HStack {
                        CVSectionHeader(title: savedOnly ? "Saved channels" : "Channels")
                        NavigationLink("Explore") { ChannelExploreView(model: model) }.font(.subheadline.bold())
                    }
                    if savedOnly { Text("Saved on this iPhone.").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant) }
                    if model.loading && model.channels.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(40) }
                    ForEach(channels) { channel in
                        NavigationLink { ChannelFeedView(channel: channel, model: model) } label: { ChannelRow(channel: channel) }
                            .buttonStyle(.plain)
                    }
                    if !model.loading && channels.isEmpty {
                        CVEmptyState(title: savedOnly ? "Keep good voices close" : "No channels found",
                            message: savedOnly ? "Open a channel and save it to find it here." : "Try another search or pull to refresh.", symbol: "megaphone")
                    }
                    if model.nextCursor != nil { Button("Load more channels") { Task { await model.load(more: true) } }.disabled(model.loading) }
                    Button { showPublisher = true } label: {
                        Label("Publisher studio", systemImage: "plus.circle").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.bordered)
                }.padding(20)
            }.background(Color.cvBackground).navigationTitle("Good Post")
                .searchable(text: $search, prompt: "Search channels")
                .toolbar {
                    Menu {
                        Button("Publisher studio", systemImage: "square.and.pencil") { showPublisher = true }
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Good Post options")
                }
                .task { await model.load() }
                .task(id: router.channelSlug) {
                    if let slug = router.channelSlug {
                        let result = await model.repository.channel(idOrSlug: slug)
                        if let channel = result.value { linkedChannel = channel }
                        else { model.message = result.userMessage }
                        router.channelSlug = nil
                    }
                }
                .refreshable { await model.load() }
                .sheet(isPresented: $showPublisher) { PublisherStudioView(repository: model.repository) }
                .navigationDestination(item: $linkedChannel) { ChannelFeedView(channel: $0, model: model) }
        }
    }
}

extension GoodPostChannel: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ChannelRow: View {
    let channel: GoodPostChannel

    var body: some View {
        CVCard {
            HStack(alignment: .top, spacing: 14) {
                CVAvatar(name: channel.name, url: channel.iconUrl, size: 52)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Text(channel.name).font(.headline)
                        if channel.verified { Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(Color.cvPrimary) }
                    }
                    Text(channel.lastPostPreview ?? channel.description ?? "A new voice on ClearView")
                        .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant).lineLimit(2)
                    Text("\(channel.followerCount) followers").font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant).padding(.top, 6)
            }
        }
    }
}

struct ChannelExploreView: View {
    @Bindable var model: GoodPostScreenModel
    @State private var category: String?
    @State private var search = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if let channel = model.channels.first {
                    NavigationLink { ChannelFeedView(channel: channel, model: model) } label: {
                        VStack(spacing: 16) {
                            Text("IN THE SPOTLIGHT").font(.caption2.bold()).tracking(2)
                            CVAvatar(name: channel.name, url: channel.iconUrl, size: 100)
                            Text(channel.name).font(.title2.bold())
                            Text(channel.description ?? "Discover something good.").font(.subheadline).lineLimit(3).multilineTextAlignment(.center)
                        }.padding(28).frame(maxWidth: .infinity)
                            .background(LinearGradient(colors: [.cvPrimaryContainer, .cvSurfaceContainer], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
                    }.buttonStyle(.plain)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        CVChip(title: "All", selected: category == nil) { category = nil }
                        ForEach(model.categories) { item in CVChip(title: item.label, selected: category == item.slug) { category = item.slug } }
                    }
                }
                CVSectionHeader(title: "Discover channels")
                let channels = model.channels.filter { (category == nil || $0.categorySlug == category) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
                ForEach(channels.sorted { $0.followerCount > $1.followerCount }) { channel in
                    NavigationLink { ChannelFeedView(channel: channel, model: model) } label: { ChannelRow(channel: channel) }.buttonStyle(.plain)
                }
                if channels.isEmpty { CVEmptyState(title: "Nothing here yet", message: "Try another category.", symbol: "person.2") }
                if model.nextCursor != nil { Button("Load more") { Task { await model.load(more: true) } }.disabled(model.loading) }
            }.padding(20)
        }.background(Color.cvBackground).navigationTitle("Channels").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search).refreshable { await model.load() }
    }
}

struct ChannelFeedView: View {
    let channel: GoodPostChannel
    @Bindable var model: GoodPostScreenModel
    @State private var feed: ChannelFeedModel
    @State private var browser: BrowserDestination?
    @State private var search = ""

    init(channel: GoodPostChannel, model: GoodPostScreenModel) {
        self.channel = channel
        self.model = model
        _feed = State(initialValue: ChannelFeedModel(channel: channel, repository: model.repository))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 12) {
                    CVAvatar(name: channel.name, url: channel.iconUrl, size: 80)
                    Text(channel.name).font(.title2.bold())
                    if let description = channel.description { Text(description).font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant).multilineTextAlignment(.center) }
                    Text("\(channel.followerCount) followers").font(.caption).foregroundStyle(Color.cvPrimary)
                    HStack {
                        Button(model.followedIDs.contains(channel.id) ? "Following" : "Follow") {
                            Task { await model.toggleFollow(channel) }
                        }.buttonStyle(.borderedProminent).disabled(model.pendingFollows.contains(channel.id))
                        Button { model.toggleSaved(channel) } label: {
                            Image(systemName: model.savedIDs.contains(channel.id) ? "bookmark.fill" : "bookmark")
                        }.buttonStyle(.bordered).accessibilityLabel(model.savedIDs.contains(channel.id) ? "Unsave channel" : "Save channel on this iPhone")
                    }
                }.padding(.vertical, 16).frame(maxWidth: .infinity)
                if let message = model.message { CVErrorBanner(message: message) }
                if let message = feed.message { CVErrorBanner(message: message) { Task { await feed.load() } } }
                if feed.loading && feed.posts.isEmpty { ProgressView().frame(maxWidth: .infinity).padding() }
                ForEach(feed.posts.filter { search.isEmpty || ($0.body ?? "").localizedCaseInsensitiveContains(search) }) { post in
                    postCard(post)
                }
                if !feed.loading && feed.posts.isEmpty { CVEmptyState(title: "The start of something good", message: "This channel hasn't posted yet.", symbol: "text.bubble") }
                if feed.nextCursor != nil { Button("Earlier posts") { Task { await feed.load(more: true) } }.disabled(feed.loading).frame(maxWidth: .infinity) }
            }.padding(20)
        }.background(Color.cvBackground).navigationTitle(channel.name).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search loaded posts")
            .toolbar { ShareLink(item: channel.shareLink) }
            .task { await feed.load() }.refreshable { await feed.load() }
            .sheet(item: $browser) { BrowserSheet(url: $0.url) }
    }

    private func postCard(_ post: GoodPostPost) -> some View {
        CVCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    CVAvatar(name: channel.name, url: channel.iconUrl, size: 28)
                    Text(channel.name).font(.caption.bold())
                    Spacer()
                    Text(String(post.createdAt.prefix(10))).font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                }
                if let body = post.body, !body.isEmpty { Text(body).font(.body).lineSpacing(5).textSelection(.enabled) }
                ForEach(post.media) { media in
                    if let raw = media.url, let url = URL(string: raw) {
                        if media.isImage {
                            Button { browser = BrowserDestination(raw) } label: {
                                AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView().frame(height: 160) }
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).accessibilityLabel("Open image")
                        } else if media.isVideo {
                            InlinePostVideo(url: url)
                        } else {
                            Button { browser = BrowserDestination(raw) } label: { Label(media.fileName ?? "Open attachment", systemImage: "doc") }
                        }
                    }
                }
                if let link = post.linkUrl {
                    Button { browser = BrowserDestination(link) } label: {
                        Label(post.linkTitle ?? link, systemImage: "arrow.up.right.square").font(.subheadline).lineLimit(2)
                    }
                }
                HStack(spacing: 12) {
                    ForEach(post.reactions, id: \.emoji) { reaction in
                        Button { Task { await feed.react(to: post, emoji: reaction.emoji) } } label: {
                            Text("\(reaction.emoji) \(reaction.count)").font(.caption)
                                .padding(5).background(feed.myReactions[post.id] == reaction.emoji ? Color.cvPrimaryContainer : .clear, in: Capsule())
                        }.disabled(feed.reacting.contains(post.id))
                    }
                    if !feed.emojiOptions.isEmpty {
                        Menu {
                            ForEach(feed.emojiOptions, id: \.self) { emoji in Button(emoji) { Task { await feed.react(to: post, emoji: emoji) } } }
                        } label: { Image(systemName: "face.smiling").font(.caption) }.disabled(feed.reacting.contains(post.id))
                    }
                    Spacer()
                    Label("\(post.views)", systemImage: "eye").font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                    ShareLink(item: post.body ?? post.linkUrl ?? channel.shareLink) { Image(systemName: "square.and.arrow.up").font(.caption) }
                }
            }
        }
    }
}

struct InlinePostVideo: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 12))
            .onAppear { player = AVPlayer(url: url) }
            .onDisappear { player?.pause(); player = nil }
    }
}

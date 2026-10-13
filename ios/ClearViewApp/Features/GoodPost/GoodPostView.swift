import SwiftUI
import AVKit

struct GoodPostView: View {
    @State private var model = GoodPostScreenModel()
    @State private var search = ""
    @State private var showSearch = false
    @State private var showPublisher = false
    @State private var linkedChannel: GoodPostChannel?
    @Environment(Router.self) private var router

    private var channels: [GoodPostChannel] {
        model.homeChannels.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showSearch {
                        CVSearchField(text: $search, prompt: "Search your channels")
                            .padding(.horizontal, 16).padding(.top, 12)
                    }
                    HStack {
                        Text("Channels").font(.title2.bold())
                        Spacer()
                        NavigationLink { ChannelExploreView(model: model) } label: {
                            Text("Explore").font(.subheadline.bold())
                                .padding(.horizontal, 20).padding(.vertical, 12)
                                .background(Color.cvSurfaceContainer, in: Capsule())
                        }.buttonStyle(.plain)
                    }.padding(.horizontal, 16).padding(.vertical, 24)
                    if !model.channelAds.isEmpty {
                        GoodPostAdCarousel(ads: model.channelAds).padding(.bottom, 16)
                    }
                    if let message = model.message {
                        GoodPostNotice(message: message) { Task { await model.load() } }
                    }
                    if model.loading && channels.isEmpty {
                        ProgressView().frame(maxWidth: .infinity).padding(32)
                    }
                    ForEach(channels) { channel in
                        NavigationLink { ChannelFeedView(channel: channel, model: model) } label: {
                            ChannelRow(channel: channel)
                        }.buttonStyle(.plain)
                    }
                    if !model.loading && channels.isEmpty {
                        CVEmptyState(title: search.isEmpty ? "Follow your favourite channels" : "No channels found",
                            message: search.isEmpty ? "Explore channels to find voices you want to hear from." : "Try another channel name.",
                            symbol: "megaphone").padding(24)
                    }
                    if model.canCreateChannel {
                        Divider()
                        Button { showPublisher = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus").foregroundStyle(Color.cvPrimary)
                                    .frame(width: 28, height: 28)
                                    .background(Color.cvSurfaceContainer, in: Circle())
                                Text("Create a channel").font(.subheadline.bold())
                            }.frame(maxWidth: .infinity).padding(.vertical, 20)
                        }.buttonStyle(.plain)
                    }
                }.padding(.bottom, 24)
            }.background(Color.cvBackground)
                .navigationTitle("Good Post").navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showSearch.toggle()
                            if !showSearch { search = "" }
                        } label: { Image(systemName: "magnifyingglass") }
                            .accessibilityLabel("Search channels")
                        Menu {
                            if model.canCreateChannel {
                                Button("Create a channel", systemImage: "plus") { showPublisher = true }
                            }
                            if model.ownedChannels.count == 1, let channel = model.ownedChannels.first {
                                Button("My Channel", systemImage: "megaphone") { linkedChannel = channel }
                            }
                            NavigationLink { GoodPostSavedChannelsView(model: model) } label: {
                                Label("Saved channels", systemImage: "bookmark")
                            }
                            Button("Publisher studio", systemImage: "square.and.pencil") { showPublisher = true }
                            if model.session?.isSuperAdmin == true {
                                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
                            }
                            if model.session != nil {
                                Button(role: .destructive) {
                                    Task { await model.signOut() }
                                } label: { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
                            }
                        } label: {
                            Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(width: 24, height: 32)
                        }.accessibilityLabel("Good Post options")
                    }
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
                .sheet(isPresented: $showPublisher, onDismiss: { Task { await model.load() } }) {
                    PublisherStudioView(repository: model.repository)
                }
                .navigationDestination(item: $linkedChannel) { ChannelFeedView(channel: $0, model: model) }
        }
    }
}

extension GoodPostChannel: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ChannelRow: View {
    let channel: GoodPostChannel

    private var preview: String {
        if channel.status == "suspended" { return "Channel suspended" }
        if let text = channel.lastPostPreview, !text.trimmed.isEmpty { return text }
        if channel.lastPostAt != nil {
            switch channel.lastPostType {
            case "image": return "Photo"
            case "video": return "Video"
            case "link": return "Link"
            case "document": return "Document"
            default: return "New post"
            }
        }
        return channel.description ?? "No posts yet"
    }

    private var timestamp: String? {
        guard let milliseconds = parseIsoMillis(channel.lastPostAt) else { return nil }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                CVAvatar(name: channel.name, url: channel.iconUrl, size: 49)
                VStack(alignment: .leading, spacing: 7) {
                    GoodPostChannelName(channel: channel)
                    HStack(spacing: 5) {
                        if let symbol = previewSymbol {
                            Image(systemName: symbol).font(.caption)
                        }
                        Text(preview).lineLimit(1)
                    }.font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 8) {
                    if let timestamp {
                        Text(timestamp).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                    if channel.unreadCount > 0 {
                        Text(channel.unreadCount > 99 ? "99+" : "\(channel.unreadCount)")
                            .font(.caption2.bold()).foregroundStyle(Color.cvOnPrimary)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(Color.cvPrimary, in: Capsule())
                    }
                }
            }.padding(.horizontal, 16).padding(.vertical, 14)
            Divider().padding(.leading, 79)
        }.contentShape(Rectangle())
    }

    private var previewSymbol: String? {
        switch channel.lastPostType {
        case "image": return "photo"
        case "video": return "video"
        case "link": return "link"
        case "document": return "doc"
        default: return nil
        }
    }
}

struct ChannelExploreView: View {
    @Bindable var model: GoodPostScreenModel
    @State private var discovery = GoodPostDiscoveryModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !discovery.ads.isEmpty {
                    GoodPostAdCarousel(ads: discovery.ads).padding(.top, 16).padding(.bottom, 12)
                }
                if discovery.loading && discovery.sections.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(32)
                }
                if let message = model.message {
                    GoodPostNotice(message: message) { Task { await model.load() } }
                }
                ForEach(ChannelSection.allCases, id: \.self) { section in
                    HStack {
                        Text(section == .explore ? "Trending channels" : section.title).font(.title3.bold())
                        Spacer(minLength: 12)
                        NavigationLink {
                            GoodPostChannelDirectoryView(model: model, section: section)
                        } label: {
                            Text("See all").font(.subheadline.bold())
                                .padding(.horizontal, 18).padding(.vertical, 11)
                                .background(Color.cvSurfaceContainer, in: Capsule())
                        }.buttonStyle(.plain)
                    }.padding(.horizontal, 16).padding(.top, 26).padding(.bottom, 12)
                    if let message = discovery.errors[section] {
                        GoodPostNotice(message: message) { Task { await discovery.load(repository: model.repository) } }
                    } else if !discovery.loading && discovery.sections[section, default: []].isEmpty {
                        Text("Nothing here yet").font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                            .padding(.horizontal, 16).padding(.vertical, 16)
                    }
                    ForEach(discovery.sections[section, default: []]) { channel in
                        GoodPostDiscoverRow(channel: channel, model: model)
                    }
                }
            }.padding(.bottom, 32)
        }.background(Color.cvBackground)
            .navigationTitle("Channels").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { GoodPostChannelDirectoryView(model: model) } label: {
                        Image(systemName: "magnifyingglass")
                    }.accessibilityLabel("Search channels")
                }
            }
            .task { await discovery.load(repository: model.repository) }
            .refreshable { await discovery.load(repository: model.repository) }
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

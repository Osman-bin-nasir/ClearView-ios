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
                .navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbarBackground(Color.cvBackground, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Text("Good Post").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    }
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
                            NavigationLink {
                                GoodPostStarredView(channelId: nil, repository: model.repository)
                            } label: {
                                Label("Starred messages", systemImage: "star")
                            }
                            NavigationLink {
                                GoodPostDirectoryView(repository: model.repository)
                            } label: {
                                Label("Channel directory", systemImage: "list.bullet.rectangle")
                            }
                            Button("Publisher studio", systemImage: "square.and.pencil") { showPublisher = true }
                            if model.session?.isSuperAdmin == true {
                                NavigationLink {
                                    GoodPostAdsView(repository: model.repository)
                                } label: {
                                    Label("Advertisements", systemImage: "rectangle.on.rectangle")
                                }
                            }
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
                    }.padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 6)
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
    /// Held as state rather than taken as a constant, because the information page behind this
    /// screen can change the channel — a new picture, a new name — and a constant would keep
    /// drawing the copy this screen was opened with until it was closed and reopened.
    @State private var channel: GoodPostChannel
    @Bindable var model: GoodPostScreenModel
    @State private var feed: ChannelFeedModel
    @State private var browser: BrowserDestination?
    @State private var search = ""
    @State private var composing = false
    /// The line the compose strip is holding, handed to the posting page so the pencil does not
    /// throw away what has already been typed.
    @State private var draft = ""
    /// The stars on this device, read once when the feed opens.
    ///
    /// Held in memory rather than asked per row: the store decodes its whole list on every read,
    /// and a feed of thirty messages asking thirty times is thirty decodes of the same file.
    @State private var starredIDs: Set<String> = []

    private var visiblePosts: [GoodPostPost] {
        feed.posts.reversed().filter { search.isEmpty || ($0.body ?? "").localizedCaseInsensitiveContains(search) }
    }

    init(channel: GoodPostChannel, model: GoodPostScreenModel) {
        _channel = State(initialValue: channel)
        self.model = model
        _feed = State(initialValue: ChannelFeedModel(channel: channel, repository: model.repository))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let message = model.message { GoodPostNotice(message: message) { Task { await model.load() } } }
                if let message = feed.message { GoodPostNotice(message: message) { Task { await feed.load() } } }
                if feed.nextCursor != nil {
                    Button("Earlier posts") { Task { await feed.load(more: true) } }
                        .font(.subheadline.bold()).padding(12).background(Color.cvSurfaceContainer, in: Capsule())
                        .disabled(feed.loading).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                if feed.loading && feed.posts.isEmpty { ProgressView().frame(maxWidth: .infinity).padding() }
                ForEach(Array(visiblePosts.enumerated()), id: \.element.id) { index, post in
                    if index == 0 || postDay(post) != postDay(visiblePosts[index - 1]) {
                        Text(dayLabel(post)).font(.caption.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Color.cvSurfaceContainerHigh, in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    postCard(post).padding(.horizontal, 10)
                }
                if !feed.loading && feed.posts.isEmpty {
                    CVEmptyState(
                        title: "The start of something good",
                        message: model.canManage(channel.id) ? "Write the first update to this channel." : "This channel hasn't posted yet.",
                        symbol: "text.bubble"
                    )
                }
            }.padding(.vertical, 12)
        }.defaultScrollAnchor(.bottom)
            .background {
                GeometryReader { geometry in
                    Image("GoodPostChatBackground").resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbarBackground(Color.cvBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .searchable(text: $search, prompt: "Search loaded posts")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    NavigationLink {
                        ChannelInfoView(channel: channel, model: model) { updated in channel = updated }
                    } label: {
                        HStack(spacing: 10) {
                            CVAvatar(name: channel.name, url: channel.iconUrl, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(channel.name).font(.headline).lineLimit(1)
                                Text("Public channel").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                            }
                        }
                    }.buttonStyle(.plain).accessibilityLabel("Channel info for \(channel.name)")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: channel.shareLink) { Image(systemName: "link") }
                    Menu {
                        NavigationLink { ChannelInfoView(channel: channel, model: model) { updated in channel = updated } } label: {
                            Label("Channel info", systemImage: "info.circle")
                        }
                        NavigationLink { GoodPostSavedChannelsView(model: model) } label: {
                            Label("Saved channels", systemImage: "bookmark")
                        }
                        Button(model.followedIDs.contains(channel.id) ? "Unfollow channel" : "Follow channel") {
                            Task { await model.toggleFollow(channel) }
                        }.disabled(model.pendingFollows.contains(channel.id))
                        Button(model.savedIDs.contains(channel.id) ? "Unsave channel" : "Save channel") {
                            model.toggleSaved(channel)
                        }
                        ShareLink(item: channel.shareLink) { Label("Share", systemImage: "square.and.arrow.up") }
                    } label: {
                        Image(systemName: "ellipsis").rotationEffect(.degrees(90))
                    }.accessibilityLabel("Channel options")
                }
            }
            // The composer's way in, for an account that may post to THIS channel.
            // A safe-area inset rather than an overlay so the feed scrolls under it
            // and its last post stays reachable — the same reason Android gives the
            // list a bottom content padding when it is editable.
            .safeAreaInset(edge: .bottom) {
                if model.canManage(channel.id) {
                    ChannelComposeBar(channelName: channel.name, draft: $draft) { composing = true }
                }
            }
            .sheet(isPresented: $composing, onDismiss: { Task { await feed.load() } }) {
                PostComposerView(
                    channel: channel,
                    repository: model.repository,
                    initialText: draft,
                    // The draft belongs to the strip, so a posted line clears it — and a
                    // cancelled one does not, because the reader did not send it.
                    onPublished: { draft = "" }
                )
            }
            .task {
                await feed.load()
                await loadStarred()
            }
            .refreshable { await feed.load() }
            .sheet(item: $browser) { BrowserSheet(url: $0.url) }
    }

    private func loadStarred() async {
        starredIDs = Set(GoodPostStarredStore().all.map(\.postId))
    }

    private func toggleStar(_ post: GoodPostPost) {
        let store = GoodPostStarredStore()
        if starredIDs.contains(post.id) {
            store.remove(postId: post.id)
            starredIDs.remove(post.id)
        } else {
            store.toggle(post.starredEntry(channel: channel))
            starredIDs.insert(post.id)
        }
    }

    private func postDay(_ post: GoodPostPost) -> Date? {
        guard let milliseconds = parseIsoMillis(post.createdAt) else { return nil }
        return Calendar.current.startOfDay(for: Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    private func dayLabel(_ post: GoodPostPost) -> String {
        guard let date = postDay(post) else { return "Updates" }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func timeLabel(_ post: GoodPostPost) -> String {
        guard let milliseconds = parseIsoMillis(post.createdAt) else { return "" }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000).formatted(date: .omitted, time: .shortened)
    }

    private func postCard(_ post: GoodPostPost) -> some View {
            VStack(alignment: .leading, spacing: 12) {
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
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
                    }
                }
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    // A bookmark is private to this device, so it costs no request and writes
                    // nothing for anybody else.
                    Button { toggleStar(post) } label: {
                        Image(systemName: starredIDs.contains(post.id) ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundStyle(starredIDs.contains(post.id) ? Color.white : GoodPostFeedPalette.timestamp)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(starredIDs.contains(post.id) ? "Remove star" : "Star this message")
                    Label("\(post.views)", systemImage: "eye").font(.caption2)
                    Text(timeLabel(post)).font(.caption2)
                    ShareLink(item: post.body ?? post.linkUrl ?? channel.shareLink) { Image(systemName: "square.and.arrow.up").font(.caption) }
                }.foregroundStyle(GoodPostFeedPalette.timestamp)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(Color.white).tint(.white)
            .background(GoodPostFeedPalette.bubble, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// The way into the composer from inside a channel.
///
/// A channel's feed is otherwise read-only: it shows the channel's posts, and a reader's only
/// actions are follow, save, react and share. That left publishing reachable only through the
/// ellipsis menu's Publisher studio — which is not where somebody who has just created a channel
/// is looking, so the channel they opened had no way to post in it at all.
///
/// Drawn only when the account may publish here, so a reader is never offered a control that
/// would be refused.
///
/// The field is **editable**, and the pencil is not a way in from nothing — it is the draft the
/// field already holds, given the whole screen. An update is a paragraph with a picture rather
/// than a chat reply, so the posting page is where it is written; but a strip that were only a
/// button would make the reader discover the posting page before they could type a word into it.
struct ChannelComposeBar: View {
    let channelName: String
    @Binding var draft: String
    let onExpand: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 12) {
                TextField("Write an update", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .submitLabel(.return)
                .accessibilityIdentifier("goodpost.channel.compose")
                Button(action: onExpand) { Image(systemName: "paperclip").font(.title3) }
                    .buttonStyle(.plain).accessibilityLabel("Attach media to an update")
            }.padding(.horizontal, 16).padding(.vertical, 13)
                .background(Color.cvSurfaceContainerHigh, in: RoundedRectangle(cornerRadius: 26))
            Button(action: onExpand) {
                Image(systemName: "pencil").font(.title3.bold()).foregroundStyle(Color.cvOnPrimary)
                    .frame(width: 48, height: 48).background(Color.cvPrimary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the posting page for \(channelName)")
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
        .background(Color.cvBackground)
    }
}

private enum GoodPostFeedPalette {
    static let bubble = Color(red: 51 / 255.0, green: 75 / 255.0, blue: 25 / 255.0)
    static let timestamp = Color(red: 164 / 255.0, green: 184 / 255.0, blue: 152 / 255.0)
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

import SwiftUI
import AVKit

struct GoodPostView: View {
    @State private var model = GoodPostScreenModel()
    @State private var search = ""
    @State private var showSearch = false
    @State private var showOptions = false
    @State private var showPublisher = false
    @State private var destination: HomeDestination?
    @State private var linkedChannel: GoodPostChannel?
    @Environment(Router.self) private var router

    private enum HomeDestination: String, Hashable, Identifiable {
        case saved, starred, directory, sharedBlocklist, advertisements
        var id: String { rawValue }
    }

    private var channels: [GoodPostChannel] {
        model.homeChannels.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                homeHeader
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if showSearch {
                            CVSearchField(text: $search, prompt: "Search your channels")
                                .padding(.horizontal, 16).padding(.top, 8)
                        }
                        HStack {
                            Text("Channels").font(.system(size: 22, weight: .bold))
                            Spacer()
                            NavigationLink { ChannelExploreView(model: model) } label: {
                                Text("Explore").font(.system(size: 14, weight: .semibold))
                                    .padding(.horizontal, 20).padding(.vertical, 10)
                                    .background(Color.cvSurfaceContainerHigh, in: Capsule())
                            }.buttonStyle(.plain)
                        }.padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 8)
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
                            Divider().padding(.top, 8)
                            Button { showPublisher = true } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "plus").foregroundStyle(GoodPostPalette.accent)
                                        .frame(width: 28, height: 28)
                                        .background(Color.cvSurfaceContainerHigh, in: Circle())
                                    Text("Create a channel").font(.system(size: 15, weight: .semibold))
                                }.frame(maxWidth: .infinity).padding(.vertical, 18)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .refreshable { await model.load() }
            }
            .background(Color.cvBackground)
            .foregroundStyle(Color.cvOnSurface)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(.visible, for: .tabBar)
            .accessibilityHidden(showOptions)
            .overlay(alignment: .topTrailing) {
                if showOptions {
                    ZStack(alignment: .topTrailing) {
                        Color.black.opacity(0.001).ignoresSafeArea()
                            .onTapGesture { showOptions = false }
                        ViewThatFits(in: .vertical) {
                            homeOptions
                            ScrollView { homeOptions }.frame(width: 224)
                        }
                        .padding(.top, 54).padding(.trailing, 8)
                        .accessibilityAction(.escape) { showOptions = false }
                    }
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
            .sheet(isPresented: $showPublisher, onDismiss: { Task { await model.load() } }) {
                PublisherStudioView(repository: model.repository)
            }
            .navigationDestination(item: $linkedChannel) { ChannelFeedView(channel: $0, model: model) }
            .navigationDestination(item: $destination) { destination in
                Group {
                    switch destination {
                    case .saved: GoodPostSavedChannelsView(model: model)
                    case .starred: GoodPostStarredView(channelId: nil, repository: model.repository)
                    case .directory: GoodPostDirectoryView(repository: model.repository)
                    case .advertisements: GoodPostAdsView(repository: model.repository)
                    case .sharedBlocklist:
                        ScrollView { ProtectionSharedListSheet(model: .shared).padding(16) }
                            .background(Color.cvBackground)
                            .navigationTitle("Shared blocklist")
                            .task { await ProtectionModel.shared.syncGlobalRules() }
                    }
                }.toolbar(.visible, for: .navigationBar)
            }
        }
    }

    private var homeHeader: some View {
        HStack(spacing: 0) {
            Text("Good Post").font(.system(size: 22, weight: .bold))
                .accessibilityAddTraits(.isHeader).padding(.leading, 20)
            Spacer(minLength: 8)
            Button {
                showSearch.toggle()
                if !showSearch { search = "" }
            } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 21))
                    .frame(width: 48, height: 48)
            }.accessibilityLabel("Search channels")
            Button { showOptions.toggle() } label: {
                GoodPostOverflowIcon().frame(width: 44, height: 44)
                    .background(showOptions ? Color.cvSurfaceContainerHigh : .clear, in: Circle())
            }.accessibilityLabel("Good Post options")
        }
        .buttonStyle(.plain)
        .padding(.trailing, 8).frame(minHeight: 60)
        .background(Color.cvBackground)
    }

    private var homeOptions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.canCreateChannel {
                option("Create a channel") { showPublisher = true }
            }
            if model.ownedChannels.count == 1, let channel = model.ownedChannels.first {
                option("My Channel") { linkedChannel = channel }
            }
            if model.session?.isSuperAdmin == true {
                option("Advertisements") { destination = .advertisements }
            }
            option("Shared blocklist") { destination = .sharedBlocklist }
            option("Channel directory") { destination = .directory }
            option("Refresh") { Task { await model.load() } }
            Menu {
                Button("Saved channels", systemImage: "bookmark") { open(.saved) }
                Button("Starred messages", systemImage: "star") { open(.starred) }
                Button("Publisher studio", systemImage: "square.and.pencil") {
                    showOptions = false
                    showPublisher = true
                }
            } label: {
                Text("More options").frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            if model.session != nil {
                option("Sign out", destructive: true) { Task { await model.signOut() } }
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Color.cvOnSurface)
        .buttonStyle(.plain)
        .padding(.vertical, 8).frame(width: 224)
        .fixedSize(horizontal: false, vertical: true)
        .background(GoodPostPalette.menu, in: RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }

    private func option(_ title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil) {
            showOptions = false
            action()
        } label: {
            Text(title).foregroundStyle(destructive ? Color.cvError : Color.cvOnSurface)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 16)
        }
    }

    private func open(_ target: HomeDestination) {
        showOptions = false
        destination = target
    }
}

/// Three vertical dots, without the platform navigation bar's button capsule.
private struct GoodPostOverflowIcon: View {
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3) { _ in Circle().frame(width: 3, height: 3) }
        }.frame(width: 24, height: 24)
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
                    }.font(channel.lastPostPreview?.trimmed.isEmpty == false
                        ? .custom("JetBrainsMono-Regular", size: 14, relativeTo: .subheadline)
                        : .system(size: 14))
                        .foregroundStyle(Color.cvOnSurfaceVariant)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 8) {
                    if let timestamp {
                        Text(timestamp).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                    if channel.following && channel.unreadCount > 0 {
                        Text(channel.unreadCount > 99 ? "99+" : "\(channel.unreadCount)")
                            .font(.caption2.bold()).foregroundStyle(Color.cvOnPrimary)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(GoodPostPalette.accent, in: Capsule())
                    }
                }
            }.padding(.horizontal, 16).padding(.vertical, 12)
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
            }
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
    @State private var showSearch = false
    @Environment(\.dismiss) private var dismiss
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
        VStack(spacing: 0) {
            channelHeader
            if showSearch {
                CVSearchField(text: $search, prompt: "Search loaded posts")
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.cvBackground)
            }
            // A connection notice stays below the header while the updates scroll.
            if let message = feed.message ?? model.message {
                GoodPostNotice(message: message) {
                    Task {
                        await model.load()
                        await feed.load()
                    }
                }
            }
            postsScrollView
        }
        .background(Color.cvBackground)
        .foregroundStyle(Color.cvOnSurface)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        // The inset owns the composer's height. There is no second spacer or
        // reserved tab-bar area beneath it, including when the keyboard opens.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.canManage(channel.id) {
                ChannelComposeBar(channelName: channel.name, draft: $draft) { composing = true }
            }
        }
        .sheet(isPresented: $composing, onDismiss: { Task { await feed.load() } }) {
            PostComposerView(
                channel: channel,
                repository: model.repository,
                initialText: draft,
                onPublished: { draft = "" }
            )
        }
        .task {
            await feed.load()
            await loadStarred()
        }
        .sheet(item: $browser) { BrowserSheet(url: $0.url) }
    }

    private var channelHeader: some View {
        HStack(spacing: 0) {
            Button { dismiss() } label: {
                Image(systemName: "arrow.left").font(.system(size: 21))
                    .frame(width: 48, height: 48)
            }.accessibilityLabel("Back")
            NavigationLink {
                ChannelInfoView(channel: channel, model: model) { updated in channel = updated }
                    .toolbar(.visible, for: .navigationBar)
            } label: {
                HStack(spacing: 12) {
                    CVAvatar(name: channel.name, url: channel.iconUrl, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
                        Text("Public channel").font(.system(size: 12))
                            .foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                    Spacer(minLength: 4)
                }
            }.accessibilityLabel("Channel info for \(channel.name)")
            ShareLink(item: channel.shareLink) {
                Image(systemName: "link").font(.system(size: 21)).frame(width: 44, height: 48)
            }.accessibilityLabel("Share channel link")
            Menu {
                NavigationLink {
                    ChannelInfoView(channel: channel, model: model) { updated in channel = updated }
                        .toolbar(.visible, for: .navigationBar)
                } label: { Label("Channel info", systemImage: "info.circle") }
                Button("Search posts", systemImage: "magnifyingglass") {
                    showSearch.toggle()
                    if !showSearch { search = "" }
                }
                NavigationLink {
                    GoodPostSavedChannelsView(model: model).toolbar(.visible, for: .navigationBar)
                } label: { Label("Saved channels", systemImage: "bookmark") }
                Button(model.followedIDs.contains(channel.id) ? "Unfollow channel" : "Follow channel") {
                    Task { await model.toggleFollow(channel) }
                }.disabled(model.pendingFollows.contains(channel.id))
                Button(model.savedIDs.contains(channel.id) ? "Unsave channel" : "Save channel") {
                    model.toggleSaved(channel)
                }
                ShareLink(item: channel.shareLink) { Label("Share", systemImage: "square.and.arrow.up") }
            } label: {
                GoodPostOverflowIcon().frame(width: 44, height: 48)
            }.accessibilityLabel("Channel options")
        }
        .buttonStyle(.plain).tint(Color.cvOnSurface)
        .padding(.trailing, 4).frame(minHeight: 60)
        .background(Color.cvBackground)
    }

    private var postsScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if feed.nextCursor != nil {
                    Button("Earlier posts") { Task { await feed.load(more: true) } }
                        .font(.subheadline.bold()).padding(12).background(Color.cvSurfaceContainer, in: Capsule())
                        .disabled(feed.loading).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                if feed.loading && feed.posts.isEmpty { ProgressView().frame(maxWidth: .infinity).padding() }
                ForEach(Array(visiblePosts.enumerated()), id: \.element.id) { index, post in
                    if index == 0 || postDay(post) != postDay(visiblePosts[index - 1]) {
                        Text(dayLabel(post)).font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.cvOnSurfaceVariant)
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .background(Color.cvSurfaceContainerHigh, in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
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
            }.padding(.top, 6)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .background {
            GeometryReader { geometry in
                Image("GoodPostChatBackground").resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .refreshable { await feed.load() }
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
        return Date(timeIntervalSince1970: Double(milliseconds) / 1000).formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute()).lowercased()
    }

    private func postCard(_ post: GoodPostPost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let body = post.body, !body.isEmpty {
                Text(body).font(.custom("JetBrainsMono-Regular", size: 14, relativeTo: .body))
                    .lineSpacing(4)
            }
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
            if !post.reactions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(post.reactions, id: \.emoji) { reaction in
                            Button { Task { await feed.react(to: post, emoji: reaction.emoji) } } label: {
                                Text("\(reaction.emoji) \(reaction.count)").font(.caption)
                                    .padding(5)
                                    .background(feed.myReactions[post.id] == reaction.emoji ? Color.cvPrimaryContainer : .clear, in: Capsule())
                            }.disabled(feed.reacting.contains(post.id))
                        }
                    }
                }
            }
            HStack(spacing: 6) {
                if starredIDs.contains(post.id) {
                    Image(systemName: "star.fill").font(.system(size: 11))
                        .accessibilityLabel("Starred message")
                }
                Spacer(minLength: 0)
                if post.views > 0 {
                    Label("\(post.views)", systemImage: "eye").font(.system(size: 11))
                }
                Text(timeLabel(post)).font(.system(size: 11.5))
            }.foregroundStyle(GoodPostPalette.timestamp)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Color.white).tint(.white)
        .background(GoodPostPalette.bubble, in: RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            if let body = post.body, !body.isEmpty {
                Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = body }
            }
            Button(starredIDs.contains(post.id) ? "Remove star" : "Star this message", systemImage: "star") {
                toggleStar(post)
            }
            ShareLink(item: post.body ?? post.linkUrl ?? channel.shareLink) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            ForEach(feed.emojiOptions, id: \.self) { emoji in
                Button(emoji) { Task { await feed.react(to: post, emoji: emoji) } }
                    .disabled(feed.reacting.contains(post.id))
            }
        }
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
                    .font(.custom("JetBrainsMono-Regular", size: 16, relativeTo: .body))
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .submitLabel(.return)
                    .accessibilityIdentifier("goodpost.channel.compose")
                Button(action: onExpand) { Image(systemName: "paperclip").font(.title3) }
                    .buttonStyle(.plain).accessibilityLabel("Attach media to an update")
            }.padding(.horizontal, 16).padding(.vertical, 12)
                .frame(minHeight: 48)
                .background(GoodPostPalette.bar, in: RoundedRectangle(cornerRadius: 26))
            Button(action: onExpand) {
                Image(systemName: "pencil").font(.title3.bold()).foregroundStyle(Color.cvOnPrimary)
                    .frame(width: 48, height: 48).background(GoodPostPalette.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the posting page for \(channelName)")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .foregroundStyle(Color.cvOnSurfaceVariant)
        .background(Color.cvBackground)
    }
}

enum GoodPostPalette {
    // The supplied Android reference uses this brighter teal for its controls.
    static let accent = Color(UIColor { traits in
        UIColor(cvRGB: traits.userInterfaceStyle == .dark ? 0x00CFCD : 0x00695C)
    })
    static let menu = Color(UIColor { traits in
        UIColor(cvRGB: traits.userInterfaceStyle == .dark ? 0x1C2322 : 0xEEF3F1)
    })
    static let bar = Color(UIColor { traits in
        UIColor(cvRGB: traits.userInterfaceStyle == .dark ? 0x252B2B : 0xE0E9E6)
    })
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

import SwiftUI

struct MediaView: View {
    @State private var library = MediaLibrary()
    @State private var selectedChannel: String?
    @State private var search = ""
    @State private var searchOpen = false
    @State private var browser: BrowserDestination?
    @State private var playingVideo: LibraryVideo?
    /// The Short the reader tapped, which opens the pager at that one. A Short is
    /// watched in the pager rather than in `MediaVideoPlayerView`: one clip per
    /// screen, the next a swipe away, and none of the timeline furniture a
    /// vertical clip has no use for.
    @State private var shortsPager: LibraryVideo?
    @State private var showAdd = false
    @State private var showChannels = false
    @State private var showAddChannel = false
    @State private var showPlaylists = false
    /// The video whose "Add to playlist…" was tapped. A sheet rather than a
    /// nested `Menu`: the picker shows each playlist's count and offers creating
    /// one with this video, and a menu can carry neither.
    @State private var addToPlaylistVideo: LibraryVideo?
    @State private var showFilters = false
    @State private var showHiddenVideos = false
    @State private var showHiddenChannels = false
    @State private var unavailable: String?
    @State private var pendingRemoval: DirectoryChannel?
    @State private var allFeedFilter = FeedFilter()
    @State private var profileFilter = FeedFilter(date: .allTime, watchStatus: .all)

    private var filter: FeedFilter {
        get { selectedChannel == nil ? allFeedFilter : profileFilter }
        nonmutating set {
            if selectedChannel == nil { allFeedFilter = newValue }
            else { profileFilter = newValue }
        }
    }

    /// The app's Protection model: the Block tab's rules, shared with the feed.
    ///
    /// The same instance the Protection tab edits, so a keyword added there hides the
    /// next feed this view draws. This is the half of the Android product iOS can
    /// reproduce — the app's own surfaces — and it is why the tab's switches mean
    /// something here rather than describing a service that is not running.
    private var protection: ProtectionModel { .shared }

    private var videos: [LibraryVideo] {
        protectedVideos(library.filteredVideos(filter, channelID: selectedChannel, query: search))
    }
    private var currentChannel: DirectoryChannel? { library.state.channels.first { $0.id == selectedChannel } }
    private var continuing: [LibraryVideo] {
        protectedVideos((library.state.recent + library.state.feed).reduce(into: [LibraryVideo]()) { collected, video in
            guard !collected.contains(where: { $0.id == video.id }), !video.isShortsEntry, !video.isPost, video.live != true,
                  (selectedChannel == nil || video.channelID == selectedChannel),
                  (selectedChannel != nil || !(library.state.hiddenChannelIDs ?? []).contains(video.channelID ?? "")),
                  !(library.state.hiddenVideoIDs ?? []).contains(video.id),
                  let progress = library.state.watchProgress?[video.id], progress.fraction >= FeedFilters.startedFractionThreshold,
                  progress.dismissedFromContinue != true,
                  progress.fraction < FeedFilters.watchedFractionThreshold else { return }
            collected.append(video)
        }.sorted { (library.state.watchProgress?[$0.id]?.updatedAt ?? .distantPast) > (library.state.watchProgress?[$1.id]?.updatedAt ?? .distantPast) })
    }

    // ── Protection ─────────────────────────────────────────────────

    /// The list after Protection has had its say.
    ///
    /// A filter over the model rather than a second copy of it: the feed keeps every video
    /// it loaded, and this decides which of them are drawn. Turning Protection off brings
    /// them all straight back, which a destructive filter could not do.
    private func protectedVideos(_ videos: [LibraryVideo]) -> [LibraryVideo] {
        let options = protection.enforcementOptions
        guard options.protectionEnabled else { return videos }
        let kept = ProtectionEnforcer.keptIDs(
            videos.map(subject(for:)),
            rules: protection.rules(),
            options: options
        )
        return videos.filter { kept.contains($0.id) }
    }

    /// One library video in the terms the rules are written in.
    ///
    /// The channel handle comes from the subscription when it is known, because a channel
    /// block is stored by handle — the display name is only what the feed shows.
    private func subject(for video: LibraryVideo) -> ProtectionSubject {
        let platform = (video.platform ?? "").uppercased()
        let isYouTube = platform == "YOUTUBE"
            || video.url.contains("youtube.com")
            || video.url.contains("youtu.be")
        return ProtectionSubject(
            id: video.id,
            title: video.title,
            description: video.bodyText,
            channelName: video.channel,
            channelHandle: library.state.channels.first { $0.id == video.channelID }?.handle,
            url: video.sourceURL ?? video.url,
            isYouTube: isYouTube,
            isShort: video.isShort
        )
    }

    /// How many items Protection is hiding from the current feed.
    private var hiddenByProtection: Int {
        let options = protection.enforcementOptions
        guard options.protectionEnabled else { return 0 }
        let all = library.filteredVideos(filter, channelID: selectedChannel, query: search)
        return protection.enforcement(for: all.map(subject(for:))).hiddenCount
    }

    /// A value that changes exactly when Protection could hide something different.
    ///
    /// Used as a task's id so the activity log is written when the rules or the feed
    /// change — and never while a frame is being drawn.
    private var protectionStamp: String {
        let options = protection.enforcementOptions
        return [
            options.protectionEnabled ? "on" : "off",
            options.youTubeProtection ? "yt" : "-",
            options.blockShorts ? "shorts" : "-",
            options.strictMode ? "strict" : "-",
            "\(protection.userKeywords.count)",
            "\(protection.youTubeKeywords.count)",
            "\(protection.blockedChannels.count)",
            "\(protection.blockedDomains.count)",
            protection.store.globalRules.version,
            "\(library.state.feed.count)",
        ].joined(separator: "|")
    }

    /// Write the blocks this feed produced into the Protection activity.
    private func noteProtectionBlocks() {
        guard protection.enforcementOptions.protectionEnabled else { return }
        let all = library.filteredVideos(filter, channelID: selectedChannel, query: search)
        protection.noteHidden(protection.enforcement(for: all.map(subject(for:))).hidden)
    }

    private var protectionNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.fill").font(.system(size: 13)).foregroundStyle(Color.cvPrimary)
            Text(hiddenByProtection == 1
                 ? "1 item hidden by Protection"
                 : "\(hiddenByProtection) items hidden by Protection")
                .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cvSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("media.protection-note")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    channels
                    feedHeader
                    if hiddenByProtection > 0 { protectionNote }
                    if searchOpen {
                        CVSearchField(text: $search, prompt: "Search channels and videos", identifier: "media.search.field")
                        if !search.isEmpty { matchingChannels }
                    }
                    if library.loading { ProgressView().frame(maxWidth: .infinity) }
                    if let error = selectedChannel.flatMap({ library.channelErrors[$0] }) ?? (selectedChannel == nil ? library.error : nil) { CVErrorBanner(message: error) { Task { await library.refresh() } } }
                    if !continuing.isEmpty && !searchOpen && filter.content != .downloads {
                        sectionTitle("Continue Watching")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(continuing) { video in
                                    continueCard(video)
                                }
                            }
                        }
                    }
                    if !videos.filter(\.isShortsEntry).isEmpty {
                        sectionTitle("Shorts")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(videos.filter(\.isShortsEntry)) { video in
                                    shortCard(video)
                                }
                            }
                        }
                    }
                    if filter.content == .downloads || videos.contains(where: { !$0.isShortsEntry && !$0.isPost }) {
                        sectionTitle(filter.content == .downloads ? "Downloads" : "Videos")
                    }
                    if filter.content == .downloads {
                        DownloadsSection()
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(videos.filter { !$0.isShortsEntry && !$0.isPost }) { video in videoRow(video) }
                        }
                        if !videos.filter(\.isPost).isEmpty {
                            sectionTitle("Posts")
                            LazyVStack(spacing: 12) {
                                ForEach(videos.filter(\.isPost)) { post in postCard(post) }
                            }
                        }
                        if videos.isEmpty && !library.loading {
                            CVEmptyState(title: search.isEmpty ? "No videos to show" : "No results", message: emptyMessage, symbol: "play.rectangle")
                        }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }.background(Color.cvBackground).navigationTitle("Media")
                .toolbar(.visible, for: .tabBar)
                .refreshable { await library.refresh() }
                .task {
                    // Wire background-audio watch progress into THIS library. The
                    // controller outlives any one view, so it writes progress
                    // through a sink rather than holding the library itself —
                    // hence the weak capture, which keeps the singleton from
                    // keeping a torn-down tab's library alive.
                    AudioPlaybackController.shared.progressSink = { [weak library] videoId, position, duration in
                        guard let library,
                              let video = (library.state.feed + library.state.saved).first(where: { $0.id == videoId })
                        else { return }
                        library.recordProgress(video, position: position, duration: duration)
                    }
                    await library.refresh()
                }
                // The activity log is written when the rules or the feed change, from a
                // task rather than a view body — see `protectionStamp`.
                .task(id: protectionStamp) { noteProtectionBlocks() }
                .sheet(item: $browser) { BrowserSheet(url: $0.url) }
                .sheet(isPresented: $showAdd) { AddMediaLinkView(library: library) }
                .sheet(isPresented: $showAddChannel) { AddMediaChannelView(library: library) }
                .sheet(isPresented: $showPlaylists) { MediaPlaylistsSheet(library: library) }
                .sheet(item: $addToPlaylistVideo) { video in AddToPlaylistSheet(video: video, library: library) }
                .sheet(isPresented: $showChannels) { channelManager }
                .sheet(isPresented: $showFilters) { MediaFilterSheet(filter: filter) { filter = $0 } }
                .sheet(isPresented: $showHiddenVideos) { videoCollection("Hidden videos", videos: (library.state.feed + library.state.saved).filter { (library.state.hiddenVideoIDs ?? []).contains($0.id) && (selectedChannel == nil || $0.channelID == selectedChannel) }, hidden: true) }
                .sheet(isPresented: $showHiddenChannels) { hiddenChannels }
                .navigationDestination(item: $playingVideo) { video in
                    if let reference = YouTubeLink.parse(video.url) { MediaVideoPlayerView(video: video, reference: reference, library: library) }
                    else { SocialMediaPlayerView(video: video, library: library) }
                }
                // Full screen, not a push: the pager is a place to keep swiping,
                // and the tab bar under it would be an invitation to leave.
                // The list is the shelf's own order, so swiping up in the pager
                // walks the Shorts in the order they were listed on the shelf.
                .fullScreenCover(item: $shortsPager) { start in
                    ShortsPagerView(shorts: videos.filter(\.isShortsEntry), startAt: start, library: library)
                }
                .alert("Not available yet", isPresented: Binding(get: { unavailable != nil }, set: { if !$0 { unavailable = nil } })) {
                    Button("OK", role: .cancel) { unavailable = nil }
                } message: { Text(unavailable ?? "") }
                .alert("Remove channel?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
                    Button("Remove", role: .destructive) {
                        if let channel = pendingRemoval {
                            library.subscribe(channel)
                            if selectedChannel == channel.id { selectedChannel = nil }
                            Task { await library.refresh() }
                        }
                        pendingRemoval = nil
                    }
                    Button("Cancel", role: .cancel) { pendingRemoval = nil }
                } message: { Text("Remove \(pendingRemoval?.displayName ?? "this channel") from your subscriptions? Saved videos and playlists are kept.") }
        }
    }

    private var feedHeader: some View {
        HStack(spacing: 4) {
            sectionTitle(currentChannel?.displayName ?? "All Feed")
            Spacer(minLength: 0)
            Button { searchOpen.toggle(); if !searchOpen { search = "" } } label: { Image(systemName: "magnifyingglass").frame(width: 44, height: 44) }.accessibilityLabel("Search media").accessibilityIdentifier("media.search")
            Menu {
                Button("Hidden Videos", systemImage: "eye.slash") { showHiddenVideos = true }
                Button("Hidden Channels", systemImage: "person.crop.circle.badge.xmark") { showHiddenChannels = true }
                Button("Add Video by URL", systemImage: "link") { showAdd = true }
                Button("Add Video from Device", systemImage: "folder") { unavailable = "Device video import is not connected yet. You can add web videos by URL." }
            } label: { Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(width: 44, height: 44) }.accessibilityLabel("Feed options")
            Button { showFilters = true } label: {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(filter.isActive ? Color.cvPrimary : Color.cvOnSurfaceVariant).frame(width: 44, height: 44)
            }.accessibilityLabel("Filter feed").accessibilityIdentifier("media.filters")
        }.foregroundStyle(Color.cvOnSurfaceVariant)
    }

    private var channels: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Channels").font(.headline)
                Spacer()
                Button("View all") { showChannels = true }.font(.subheadline.bold())
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    avatar("All", symbol: "square.grid.2x2", color: .cvSecondaryContainer, selected: selectedChannel == nil) { selectedChannel = nil }
                    avatar("Playlists", symbol: "text.line.first.and.arrowtriangle.forward", color: .purple) { showPlaylists = true }
                    NavigationLink { HaramaynView() } label: { avatarLabel("Haramayn", symbol: "tv", color: .green) }.buttonStyle(.plain)
                    NavigationLink { MediaDirectoryView(library: library) } label: { avatarLabel("Directory", symbol: "photo.on.rectangle", color: .blue) }.buttonStyle(.plain)
                    ForEach(library.activeChannels) { channel in
                        // The ✕ is the item's own sibling in a ZStack, NOT an overlay on
                        // its button. Both arrangements were built; only this one works.
                        // An overlay's button loses every tap to the button underneath
                        // it — a UI test caught the avatar being selected and the feed
                        // filtered instead of the confirmation appearing — whereas a
                        // sibling drawn last is the view the tap lands on. The avatar's
                        // own tap is a gesture rather than a Button for the same reason.
                        //
                        // The ✕ asks before it removes (`pendingRemoval`): it is a small
                        // target in the corner of an avatar, which is exactly where a
                        // thumb lands while scrolling the strip.
                        ZStack(alignment: .topTrailing) {
                            VStack(spacing: 7) {
                                CVAvatar(name: channel.displayName, url: channel.iconUrl, size: 50).padding(3)
                                    .overlay(Circle().stroke(selectedChannel == channel.id ? Color.cvPrimary : Color.clear, lineWidth: 2))
                                Text(channel.displayName).font(.caption.weight(.semibold)).lineLimit(1).frame(width: 68)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selectedChannel = selectedChannel == channel.id ? nil : channel.id }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(channel.displayName)
                            .contextMenu {
                                Button("Open channel") { browser = BrowserDestination(channel.url) }
                                Button("Hide from All Feed") { library.toggleChannelHidden(channel) }
                                Button("Remove channel", role: .destructive) { pendingRemoval = channel }
                            }
                            Button { pendingRemoval = channel } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.cvOnSurfaceVariant)
                                    .frame(width: 20, height: 20)
                                    .background(Color.cvSurface, in: Circle())
                                    .overlay(Circle().stroke(Color.cvOutlineVariant, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 1).padding(.trailing, 6)
                            .accessibilityLabel("Remove \(channel.displayName)")
                            .accessibilityIdentifier("media.channel.remove")
                        }
                    }
                    avatar("Add", symbol: "plus", color: .cvPrimaryContainer) { showAddChannel = true }.accessibilityLabel("Add channel")
                }
            }.accessibilityIdentifier("media.channels.strip")
        }
    }

    private var matchingChannels: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(library.state.channels.filter { $0.displayName.localizedCaseInsensitiveContains(search) || $0.handle.localizedCaseInsensitiveContains(search) }) { channel in
                    Button { selectedChannel = channel.id; search = "" } label: {
                        HStack { CVAvatar(name: channel.displayName, url: channel.iconUrl, size: 28); Text(channel.displayName).font(.caption) }
                            .padding(8).background(Color.cvSurfaceContainer, in: Capsule())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func avatar(_ title: String, symbol: String, color: Color, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { avatarLabel(title, symbol: symbol, color: color, selected: selected) }.buttonStyle(.plain).accessibilityLabel(title)
    }

    private func avatarLabel(_ title: String, symbol: String, color: Color, selected: Bool = false) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 23, weight: .semibold)).foregroundStyle(title == "All" || title == "Add" ? Color.cvPrimary : .white)
                .frame(width: 50, height: 50).background(color.opacity(0.65), in: Circle()).padding(3)
                .overlay(Circle().stroke(selected ? Color.cvPrimary : Color.clear, lineWidth: 2))
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(selected ? Color.cvPrimary : Color.cvOnSurfaceVariant).frame(width: 68)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        HStack(spacing: 8) { RoundedRectangle(cornerRadius: 2).fill(Color.cvPrimary).frame(width: 3, height: 19); Text(title).font(.headline).foregroundStyle(Color.cvOnSurface) }
    }

    private func thumbnail(_ video: LibraryVideo, showDuration: Bool = true) -> some View {
        GeometryReader { geometry in
            RemoteImage(url: video.thumbnail, placeholder: AnyView(
                ZStack { Color.cvSurfaceContainer; Image(systemName: "play.rectangle").foregroundStyle(Color.cvOnSurfaceVariant) }
            ))
                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                .overlay(alignment: .bottomTrailing) {
                    if let duration = video.durationSeconds, duration > 0, showDuration {
                        Text(String(format: "%d:%02d", duration / 60, duration % 60)).font(.caption2.bold()).padding(4).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4)).padding(6).foregroundStyle(.white)
                    } else if video.live == true { Text("LIVE").font(.caption2.bold()).padding(4).background(.red).padding(6).foregroundStyle(.white) }
                }
        }.clipped()
    }

    private func metadata(_ video: LibraryVideo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(video.channel).lineLimit(1)
            if let views = video.viewCount, views > 0 { Text("\(views.formatted(.number.notation(.compactName))) views").lineLimit(1) }
            else if video.publishedAt > 0 { Text(Date(timeIntervalSince1970: Double(video.publishedAt) / 1000), style: .relative).lineLimit(1) }
        }.font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
    }

    private func continueCard(_ video: LibraryVideo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Button { open(video) } label: {
                    thumbnail(video, showDuration: false).frame(width: 196, height: 110)
                        .overlay(alignment: .bottom) { ProgressView(value: Double(library.state.watchProgress?[video.id]?.fraction ?? 0)).tint(.cvPrimary) }
                        .overlay(alignment: .bottomTrailing) {
                            if let progress = library.state.watchProgress?[video.id] {
                                Text("\(clock(progress.position)) / \(clock(progress.duration))").font(.caption2.bold()).foregroundStyle(.white)
                                    .padding(4).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4)).padding(7)
                            }
                        }
                }.buttonStyle(.plain)
                Menu {
                    Button("Remove from Continue Watching") { library.dismissFromContinue(video) }
                } label: { Image(systemName: "ellipsis").rotationEffect(.degrees(90)).foregroundStyle(.white).frame(width: 44, height: 44) }
                    .accessibilityLabel("Continue Watching options")
            }
            Button { open(video) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(video.title).font(.subheadline.bold()).lineLimit(2)
                    Text(video.channel).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }.buttonStyle(.plain)
        }.frame(width: 196).background(Color.cvSurfaceVariant.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func shortCard(_ video: LibraryVideo) -> some View {
        ZStack(alignment: .topTrailing) {
            Button { library.open(video); shortsPager = video } label: {
                thumbnail(video, showDuration: false).frame(width: 136, height: 242)
                    .overlay(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom))
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(video.title).font(.subheadline.bold()).lineLimit(2)
                            Text(video.channel).font(.caption2).lineLimit(1)
                        }.foregroundStyle(.white).padding(10)
                    }
            }.buttonStyle(.plain)
            videoMenu(video).foregroundStyle(.white)
        }.frame(width: 136, height: 242).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func clock(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private func videoRow(_ video: LibraryVideo) -> some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Button { open(video) } label: { thumbnail(video).frame(width: 155, height: 102) }.buttonStyle(.plain)
                videoMenu(video).foregroundStyle(.white)
            }.frame(width: 155, height: 102)
            Button { open(video) } label: {
                VStack(alignment: .leading, spacing: 8) { Text(video.title).font(.subheadline.bold()).lineLimit(2); metadata(video) }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.buttonStyle(.plain)
        }.background(Color.cvSurfaceVariant.opacity(0.6), in: RoundedRectangle(cornerRadius: 14)).clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func postCard(_ post: LibraryVideo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let channel = library.state.channels.first(where: { $0.id == post.channelID }) {
                    CVAvatar(name: channel.displayName, url: channel.iconUrl, size: 32)
                }
                Text(post.channel).font(.subheadline.bold())
                Spacer()
                videoMenu(post)
            }
            if let thumbnail = post.thumbnail, !thumbnail.isEmpty {
                RemoteImage(url: thumbnail, contentMode: .fit, maxPixelSize: 1_200,
                            placeholder: AnyView(Color.cvSurfaceContainer.frame(height: 160)))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            // No "Open post" row: a post is read here, in the app, and the row's
            // only job was to hand the reader back to Instagram or X — leaving the
            // app to read what the app already shows. The ⋯ menu keeps Share for a
            // reader who does want the original.
            Text(post.bodyText?.isEmpty == false ? post.bodyText! : post.title)
                .font(.body).textSelection(.enabled)
        }
        .padding(14).background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 14))
    }

    /// A video's ⋮ menu, the same four things on every card in the tab —
    /// Android's `VideoCardMenu`.
    ///
    /// "Add to playlist…" opens the picker sheet rather than nesting a submenu,
    /// which is what it replaced: a `Menu` cannot show a playlist's video count
    /// and has nowhere to put "New playlist with this video".
    private func videoMenu(_ video: LibraryVideo) -> some View {
        Menu {
            Button("Add to playlist…", systemImage: "text.badge.plus") { addToPlaylistVideo = video }
            Button(library.state.saved.contains(video) ? "Unsave video" : "Save video", systemImage: "bookmark") {
                library.toggleSave(video)
            }
            Button("Hide video", systemImage: "eye.slash") { library.hide(video) }
            ShareLink(item: video.url)
        } label: { Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(width: 44, height: 44).background(.black.opacity(0.25), in: Circle()) }
            .accessibilityLabel("Options for \(video.title)")
    }

    private func open(_ video: LibraryVideo) {
        library.open(video)
        if YouTubeLink.parse(video.url) != nil || (!video.isYouTube && !video.isPost) { playingVideo = video }
        else { browser = BrowserDestination(video.url) }
    }

    private var emptyMessage: String {
        if search.isEmpty { return "Try changing the filters or add a channel using +." }
        return "Try a different channel name or video title."
    }

    private func uniqueVideos(_ videos: [LibraryVideo]) -> [LibraryVideo] {
        var seen = Set<String>()
        return videos.filter { seen.insert($0.id).inserted }
    }

    private var channelManager: some View {
        NavigationStack {
            List(library.state.channels) { channel in
                HStack { CVAvatar(name: channel.displayName, url: channel.iconUrl); VStack(alignment: .leading) { Text(channel.displayName); Text(channel.platformLabel).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant) }; Spacer(); Button("Open") { showChannels = false; selectedChannel = channel.id } }
            }.navigationTitle("All channels").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showChannels = false } } }
        }
    }

    private var hiddenChannels: some View {
        NavigationStack {
            List {
                ForEach(library.state.channels.filter { (library.state.hiddenChannelIDs ?? []).contains($0.id) }) { channel in
                    HStack { Text(channel.displayName); Spacer(); Button("Unhide") { library.toggleChannelHidden(channel) } }
                }
                if (library.state.hiddenChannelIDs ?? []).isEmpty { Text("No hidden channels").foregroundStyle(Color.cvOnSurfaceVariant) }
            }.navigationTitle("Hidden channels").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showHiddenChannels = false } } }
        }
    }

    private func videoCollection(_ title: String, videos: [LibraryVideo], hidden: Bool = false) -> some View {
        NavigationStack {
            List {
                ForEach(uniqueVideos(videos)) { video in
                    if hidden {
                        HStack { Text(video.title).lineLimit(2); Spacer(); Button("Unhide") { library.state.hiddenVideoIDs?.removeAll { $0 == video.id }; library.persist() } }
                    } else { Button { open(video) } label: { Label(video.title, systemImage: "play.circle") } }
                }
                if videos.isEmpty { Text("No \(title.lowercased())").foregroundStyle(Color.cvOnSurfaceVariant) }
            }.navigationTitle(title).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showHiddenVideos = false } } }
                .sheet(item: $browser) { BrowserSheet(url: $0.url) }
        }
    }
}
struct MediaDirectoryView: View {
    @Bindable var library: MediaLibrary
    @State private var search = ""
    @State private var browser: BrowserDestination?
    @State private var showAdd = false
    @State private var channelURL = ""
    @State private var invalidChannel = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                CVSectionHeader(title: "Find your next good watch", subtitle: "Curated channels, chosen with intention.")
                if let error = library.error { CVErrorBanner(message: error) { Task { await library.loadDirectory() } } }
                ForEach(library.directory.categories) { category in
                    let channels = (category.channels + category.subcategories.flatMap(\.channels)).filter {
                        search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search)
                    }
                    if !channels.isEmpty {
                        CVSectionHeader(title: category.name)
                        ForEach(channels) { channel in row(channel) }
                    }
                }
                ForEach(library.directory.unfiled.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }) { row($0) }
                if library.directory.allChannels.isEmpty { CVEmptyState(title: "No channels yet", message: "Pull to refresh the directory.", symbol: "person.2") }
            }.padding(20)
        }.background(Color.cvBackground).navigationTitle("Channel directory").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button { showAdd = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add channel by URL") }
            .alert("Add a channel", isPresented: $showAdd) {
                TextField("Channel profile URL", text: $channelURL).textInputAutocapitalization(.never)
                Button("Add") {
                    if library.addChannel(url: channelURL) { channelURL = "" }
                    else { invalidChannel = true }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text("Paste a YouTube, Instagram, or X profile link. YouTube uploads appear in your feed; Instagram and X posts appear in their channel feeds.") }
            .alert("Check the channel link", isPresented: $invalidChannel) {
                Button("OK", role: .cancel) {}
            } message: { Text("Use a channel profile link, such as https://www.youtube.com/@safinasociety.") }
            .searchable(text: $search).task { await library.loadDirectory() }
            .refreshable { await library.loadDirectory() }
            .sheet(item: $browser) { BrowserSheet(url: $0.url) }
            .onDisappear { Task { await library.refresh() } }
    }

    private func row(_ channel: DirectoryChannel) -> some View {
        CVCard {
            HStack {
                Button { browser = BrowserDestination(channel.url) } label: {
                    HStack {
                        CVAvatar(name: channel.displayName, url: channel.iconUrl)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(channel.displayName).font(.subheadline.bold()).lineLimit(2)
                            Text(channel.platformLabel).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                Button(library.state.channels.contains { $0.id == channel.id } ? "Added" : "Add") { library.subscribe(channel) }
                    .buttonStyle(.bordered).font(.caption.bold())
            }
        }
    }
}

struct AddMediaLinkView: View {
    let library: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var url = ""
    @State private var invalid = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Video URL") {
                    TextField("Title (optional)", text: $title)
                    TextField("https://…", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Text("YouTube videos play inside ClearView. Other web links open in the in-app browser.").font(.footnote)
                if invalid { Text("Enter a valid http or https link.").foregroundStyle(Color.cvError) }
            }.navigationTitle("Add video by URL").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { if library.addLink(title: title, url: url) { dismiss() } else { invalid = true } }.disabled(url.isEmpty)
                    }
                }
        }.tint(.cvPrimary)
    }
}

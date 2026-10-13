import SwiftUI

struct MediaView: View {
    @State private var library = MediaLibrary()
    @State private var selectedChannel: String?
    @State private var search = ""
    @State private var searchOpen = false
    @State private var browser: BrowserDestination?
    @State private var showAdd = false
    @State private var showChannels = false
    @State private var showAddChannel = false
    @State private var showPlaylists = false
    @State private var showFilters = false
    @State private var showHiddenVideos = false
    @State private var showHiddenChannels = false
    @State private var showSaved = false
    @State private var showRecent = false
    @State private var unavailable: String?
    @State private var filter = FeedFilter()

    private var videos: [LibraryVideo] { library.filteredVideos(filter, channelID: selectedChannel, query: search) }
    private var currentChannel: DirectoryChannel? { library.state.channels.first { $0.id == selectedChannel } }
    private var continuing: [LibraryVideo] {
        (library.state.recent + library.state.feed).reduce(into: [LibraryVideo]()) { collected, video in
            guard !collected.contains(where: { $0.id == video.id }), !video.isShort, video.live != true,
                  (selectedChannel == nil || video.channelID == selectedChannel),
                  (selectedChannel != nil || !(library.state.hiddenChannelIDs ?? []).contains(video.channelID ?? "")),
                  !(library.state.hiddenVideoIDs ?? []).contains(video.id),
                  let progress = library.state.watchProgress?[video.id], progress.fraction >= FeedFilters.startedFractionThreshold,
                  progress.fraction < FeedFilters.watchedFractionThreshold else { return }
            collected.append(video)
        }.sorted { (library.state.watchProgress?[$0.id]?.updatedAt ?? .distantPast) > (library.state.watchProgress?[$1.id]?.updatedAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    channels
                    feedHeader
                    if searchOpen {
                        CVSearchField(text: $search, prompt: "Search channels and videos", identifier: "media.search.field")
                        if !search.isEmpty { matchingChannels }
                    }
                    if library.loading { ProgressView().frame(maxWidth: .infinity) }
                    if let error = library.error { CVErrorBanner(message: error) { Task { await library.refresh() } } }
                    if let currentChannel, currentChannel.platform != "youtube" {
                        CVCard {
                            Text("\(currentChannel.platformLabel) feed integration is not available in this iOS build.").font(.footnote).foregroundStyle(Color.cvOnSurfaceVariant)
                            Button("Open channel") { browser = BrowserDestination(currentChannel.url) }.buttonStyle(.bordered)
                        }
                    }
                    if !continuing.isEmpty && !searchOpen {
                        sectionTitle("Continue Watching")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(continuing) { video in
                                    Button { open(video) } label: {
                                        VStack(alignment: .leading, spacing: 7) {
                                            thumbnail(video).aspectRatio(16 / 9, contentMode: .fit)
                                            ProgressView(value: Double(library.state.watchProgress?[video.id]?.fraction ?? 0)).tint(.cvPrimary)
                                            Text(video.title).font(.subheadline.bold()).lineLimit(2)
                                            metadata(video)
                                        }.frame(width: 230)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    if !videos.filter(\.isShort).isEmpty {
                        sectionTitle("Shorts")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(videos.filter(\.isShort)) { video in
                                    Button { open(video) } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            thumbnail(video).frame(width: 146, height: 226).clipped().clipShape(RoundedRectangle(cornerRadius: 14))
                                            Text(video.title).font(.subheadline.bold()).lineLimit(2)
                                            metadata(video)
                                        }.frame(width: 146)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    sectionTitle("Videos")
                    LazyVStack(spacing: 12) {
                        ForEach(videos.filter { !$0.isShort }) { video in videoRow(video) }
                    }
                    if videos.isEmpty && !library.loading {
                        CVEmptyState(title: search.isEmpty ? "No videos to show" : "No results", message: search.isEmpty ? "Try changing the filters or add a channel using +." : "Try a different channel name or video title.", symbol: "play.rectangle")
                    }
                }.padding(.horizontal, 16).padding(.vertical, 12)
            }.background(Color.cvBackground).navigationTitle("Media")
                .refreshable { await library.refresh() }
                .task { await library.refresh() }
                .sheet(item: $browser) { BrowserSheet(url: $0.url) }
                .sheet(isPresented: $showAdd) { AddMediaLinkView(library: library) }
                .sheet(isPresented: $showAddChannel) { AddMediaChannelView(library: library) }
                .sheet(isPresented: $showPlaylists) { MediaPlaylistsView(library: library) }
                .sheet(isPresented: $showChannels) { channelManager }
                .sheet(isPresented: $showFilters) { MediaFilterSheet(filter: filter) { filter = $0 } }
                .sheet(isPresented: $showHiddenVideos) { videoCollection("Hidden videos", videos: (library.state.feed + library.state.saved).filter { (library.state.hiddenVideoIDs ?? []).contains($0.id) }, hidden: true) }
                .sheet(isPresented: $showHiddenChannels) { hiddenChannels }
                .sheet(isPresented: $showSaved) { videoCollection("Saved videos", videos: library.state.saved) }
                .sheet(isPresented: $showRecent) { videoCollection("Recently opened", videos: library.state.recent) }
                .alert("Not available yet", isPresented: Binding(get: { unavailable != nil }, set: { if !$0 { unavailable = nil } })) {
                    Button("OK", role: .cancel) { unavailable = nil }
                } message: { Text(unavailable ?? "") }
        }
    }

    private var feedHeader: some View {
        HStack(spacing: 4) {
            sectionTitle(currentChannel?.displayName ?? "All Feed")
            Spacer(minLength: 0)
            Button { searchOpen.toggle(); if !searchOpen { search = "" } } label: { Image(systemName: "magnifyingglass").frame(width: 44, height: 44) }.accessibilityLabel("Search media").accessibilityIdentifier("media.search")
            Menu {
                Button("Hidden videos", systemImage: "eye.slash") { showHiddenVideos = true }
                Button("Hidden channels", systemImage: "person.crop.circle.badge.xmark") { showHiddenChannels = true }
                Button("Add video by URL", systemImage: "link") { showAdd = true }
                Button("Add video from device", systemImage: "folder") { unavailable = "Device video import is not connected yet. You can add web videos by URL." }
                Divider()
                Button("Saved videos", systemImage: "bookmark") { showSaved = true }
                Button("Recently opened", systemImage: "clock") { showRecent = true }
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
                    ForEach(library.state.channels) { channel in
                        Button { selectedChannel = selectedChannel == channel.id ? nil : channel.id } label: {
                            VStack(spacing: 7) {
                                CVAvatar(name: channel.displayName, url: channel.iconUrl, size: 50).padding(3)
                                    .overlay(Circle().stroke(selectedChannel == channel.id ? Color.cvPrimary : Color.clear, lineWidth: 2))
                                Text(channel.displayName).font(.caption.weight(.semibold)).lineLimit(1).frame(width: 68)
                            }
                        }.buttonStyle(.plain).contextMenu {
                            Button("Open channel") { browser = BrowserDestination(channel.url) }
                            Button("Hide from All Feed") { library.toggleChannelHidden(channel) }
                            Button("Remove channel", role: .destructive) { library.subscribe(channel); if selectedChannel == channel.id { selectedChannel = nil }; Task { await library.refresh() } }
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

    private func thumbnail(_ video: LibraryVideo) -> some View {
        GeometryReader { geometry in
            AsyncImage(url: video.thumbnail.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: { ZStack { Color.cvSurfaceContainer; Image(systemName: "play.rectangle").foregroundStyle(Color.cvOnSurfaceVariant) } }
                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                .overlay(alignment: .bottomTrailing) {
                    if let duration = video.durationSeconds, duration > 0 {
                        Text(String(format: "%d:%02d", duration / 60, duration % 60)).font(.caption2.bold()).padding(4).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4)).padding(6).foregroundStyle(.white)
                    } else if video.live == true { Text("LIVE").font(.caption2.bold()).padding(4).background(.red).padding(6).foregroundStyle(.white) }
                }
        }.clipped()
    }

    private func metadata(_ video: LibraryVideo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(video.channel).lineLimit(1)
            if video.publishedAt > 0 { Text(Date(timeIntervalSince1970: Double(video.publishedAt) / 1000), style: .relative).lineLimit(1) }
        }.font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
    }

    private func videoRow(_ video: LibraryVideo) -> some View {
        HStack(spacing: 0) {
            Button { open(video) } label: {
                HStack(spacing: 0) {
                    thumbnail(video).frame(width: 155, height: 102)
                    VStack(alignment: .leading, spacing: 8) { Text(video.title).font(.subheadline.bold()).lineLimit(2); metadata(video) }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
            }.buttonStyle(.plain)
            Menu {
                Button(library.state.saved.contains(video) ? "Unsave video" : "Save video") { library.toggleSave(video) }
                Button("Hide video", systemImage: "eye.slash") { library.hide(video) }
                if !library.state.playlists.isEmpty {
                    Menu("Add to playlist") {
                        ForEach(library.state.playlists) { playlist in
                            Button(playlist.name) {
                                if let index = library.state.playlists.firstIndex(where: { $0.id == playlist.id }), !library.state.playlists[index].videos.contains(where: { $0.id == video.id }) { library.state.playlists[index].videos.append(video); library.persist() }
                            }
                        }
                    }
                }
                ShareLink(item: video.url)
            } label: { Image(systemName: "ellipsis").rotationEffect(.degrees(90)).frame(width: 32, height: 44) }.accessibilityLabel("Options for \(video.title)")
        }.background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 14)).clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func open(_ video: LibraryVideo) { library.open(video); browser = BrowserDestination(video.url) }

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
                ForEach(Array(Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values).sorted { $0.publishedAt > $1.publishedAt }) { video in
                    if hidden {
                        HStack { Text(video.title).lineLimit(2); Spacer(); Button("Unhide") { library.state.hiddenVideoIDs?.removeAll { $0 == video.id }; library.persist() } }
                    } else { Button { open(video) } label: { Label(video.title, systemImage: "play.circle") } }
                }
                if videos.isEmpty { Text("No \(title.lowercased())").foregroundStyle(Color.cvOnSurfaceVariant) }
            }.navigationTitle(title).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showHiddenVideos = false; showSaved = false; showRecent = false } } }
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
            } message: { Text("Paste a YouTube, Instagram, or X profile link. YouTube uploads appear in your feed; other profiles open directly.") }
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
                Section("Save something worth watching") {
                    TextField("Title (optional)", text: $title)
                    TextField("https://…", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Text("YouTube, Instagram, X, and other web links open in the in-app browser.").font(.footnote)
                if invalid { Text("Enter a valid http or https link.").foregroundStyle(Color.cvError) }
            }.navigationTitle("Add a link").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { if library.addLink(title: title, url: url) { dismiss() } else { invalid = true } }.disabled(url.isEmpty)
                    }
                }
        }.tint(.cvPrimary)
    }
}

struct MediaPlaylistsView: View {
    @Bindable var library: MediaLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var showCreate = false
    @State private var name = ""
    @State private var browser: BrowserDestination?

    var body: some View {
        NavigationStack {
            List {
                if library.state.playlists.isEmpty {
                    CVEmptyState(title: "Your own little collections", message: "Create a playlist, then add videos from the feed menu.", symbol: "rectangle.stack")
                        .listRowBackground(Color.clear)
                }
                ForEach(library.state.playlists) { playlist in
                    NavigationLink {
                        List(playlist.videos) { video in
                            Button { library.open(video); browser = BrowserDestination(video.url) } label: {
                                Label(video.title, systemImage: "play.circle")
                            }.contextMenu {
                                Button("Remove from playlist", role: .destructive) {
                                    if let index = library.state.playlists.firstIndex(where: { $0.id == playlist.id }) {
                                        library.state.playlists[index].videos.removeAll { $0.id == video.id }; library.persist()
                                    }
                                }
                            }
                        }.navigationTitle(playlist.name)
                    } label: {
                        Label { VStack(alignment: .leading) {
                            Text(playlist.name)
                            Text("\(playlist.videos.count) videos").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                        } } icon: { Image(systemName: "play.rectangle.on.rectangle").foregroundStyle(Color.cvPrimary) }
                    }
                }.onDelete { library.state.playlists.remove(atOffsets: $0); library.persist() }
            }.scrollContentBackground(.hidden).background(Color.cvBackground).navigationTitle("Playlists")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button { showCreate = true } label: { Image(systemName: "plus") }.accessibilityLabel("New playlist") }
                }
                .alert("New playlist", isPresented: $showCreate) {
                    TextField("Playlist name", text: $name)
                    Button("Create") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { library.state.playlists.append(MediaPlaylist(name: trimmed)); library.persist(); name = "" }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                .sheet(item: $browser) { BrowserSheet(url: $0.url) }
        }.tint(.cvPrimary)
    }
}

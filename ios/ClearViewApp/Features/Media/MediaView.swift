import SwiftUI

struct MediaView: View {
    @State private var library = MediaLibrary()
    @State private var selection = "All Feed"
    @State private var search = ""
    @State private var browser: BrowserDestination?
    @State private var showAdd = false
    @State private var showPlaylists = false

    private var videos: [LibraryVideo] {
        let source = selection == "Saved" ? library.state.saved : selection == "Recently opened" ? library.state.recent : library.state.feed
        return source.filter { (selection != "Shorts" || $0.isShort) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.channel.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    channels
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(["All Feed", "Shorts", "Saved", "Recently opened"], id: \.self) { filter in
                                CVChip(title: filter, selected: selection == filter) { selection = filter }
                            }
                        }
                    }
                    if let error = library.error { CVErrorBanner(message: error) { Task { await library.refresh() } } }
                    if selection == "All Feed", search.isEmpty, !library.state.recent.isEmpty {
                        CVSectionHeader(title: "Recently opened")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(library.state.recent.prefix(8)) { video in videoCard(video).frame(width: 240) }
                            }
                        }
                    }
                    HStack {
                        CVSectionHeader(title: selection, subtitle: selection == "All Feed" ? "A feed you choose. A little less noise." : nil)
                        if library.loading { ProgressView() }
                    }
                    if videos.isEmpty && !library.loading {
                        CVEmptyState(title: search.isEmpty ? "Make room for what matters" : "Nothing found",
                            message: selection == "Saved" ? "Save videos from your feed, or add a YouTube, Instagram, or X link." : "Explore channels to build your feed, or add a link to your library.", symbol: "play.rectangle")
                        Button("Add a link") { showAdd = true }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 20) {
                        ForEach(videos) { video in videoCard(video) }
                    }
                }.padding(20)
            }.background(Color.cvBackground).navigationTitle("Media")
                .searchable(text: $search, prompt: "Search your feed")
                .toolbar {
                    Button { showPlaylists = true } label: { Image(systemName: "rectangle.stack") }.accessibilityLabel("Playlists")
                    Button { showAdd = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add media link")
                }
                .refreshable { await library.refresh() }
                .task { await library.refresh() }
                .sheet(item: $browser) { BrowserSheet(url: $0.url) }
                .sheet(isPresented: $showAdd) { AddMediaLinkView(library: library) }
                .sheet(isPresented: $showPlaylists) { MediaPlaylistsView(library: library) }
        }
    }

    private var channels: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                CVSectionHeader(title: "Channels")
                NavigationLink("Explore") { MediaDirectoryView(library: library) }.font(.subheadline.weight(.semibold))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(library.state.channels.isEmpty ? Array(library.directory.allChannels.prefix(6)) : library.state.channels) { channel in
                        Button { browser = BrowserDestination(channel.url) } label: {
                            VStack(spacing: 8) {
                                CVAvatar(name: channel.displayName, url: channel.iconUrl, size: 58)
                                    .padding(3).overlay(Circle().stroke(Color.cvPrimary.opacity(0.5), lineWidth: 1))
                                Text(channel.displayName).font(.caption2).lineLimit(1).frame(width: 72)
                            }
                        }.buttonStyle(.plain)
                    }
                    NavigationLink { MediaDirectoryView(library: library) } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus").font(.title2).frame(width: 64, height: 64)
                                .background(Color.cvSurfaceContainerHigh, in: Circle())
                            Text("Discover").font(.caption2)
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private func videoCard(_ video: LibraryVideo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { library.open(video); browser = BrowserDestination(video.url) } label: {
                ZStack {
                    AsyncImage(url: video.thumbnail.flatMap(URL.init(string:))) { image in image.resizable().scaledToFill() } placeholder: {
                        Rectangle().fill(Color.cvSurfaceContainerHigh)
                    }
                    Image(systemName: "play.fill").font(.title2).foregroundStyle(.white)
                        .frame(width: 48, height: 48).background(.black.opacity(0.5), in: Circle())
                }.frame(height: 165).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(.plain).accessibilityLabel("Play \(video.title)")
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(video.channel).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }
                Spacer(minLength: 0)
                Menu {
                    Button(library.state.saved.contains { $0.id == video.id } ? "Remove from saved" : "Save for later", systemImage: "bookmark") { library.toggleSave(video) }
                    ForEach(library.state.playlists) { playlist in
                        Button("Add to \(playlist.name)") {
                            if let index = library.state.playlists.firstIndex(where: { $0.id == playlist.id }),
                               !library.state.playlists[index].videos.contains(where: { $0.id == video.id }) {
                                library.state.playlists[index].videos.append(video)
                                library.persist()
                            }
                        }
                    }
                    ShareLink(item: video.url)
                } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
            }
        }
    }
}

struct MediaDirectoryView: View {
    @Bindable var library: MediaLibrary
    @State private var search = ""
    @State private var browser: BrowserDestination?

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

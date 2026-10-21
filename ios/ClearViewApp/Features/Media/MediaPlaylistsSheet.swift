import SwiftUI

/// Playlists — opened from the Playlists avatar beside "All".
///
/// Android's `PlaylistsSheet`, and the same four things in the same order: make a
/// local playlist, import a YouTube one by URL, the ones already imported, then
/// the reader's own. Both kinds live in one place because they are the same object
/// to a reader — a list of videos with a name — and the difference only matters in
/// what can be done to them afterwards.
struct MediaPlaylistsSheet: View {
    @Bindable var library: MediaLibrary

    @Environment(\.dismiss) private var dismiss
    @State private var createName = ""
    @State private var showCreate = false
    @State private var renameTarget: MediaPlaylist?
    @State private var renameName = ""
    @State private var importURL = ""
    @State private var showImport = false
    @State private var importing = false
    @State private var importError: String?
    @State private var playingVideo: LibraryVideo?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showCreate = true } label: { Label("New playlist", systemImage: "plus") }
                        .accessibilityIdentifier("playlists.new")
                    Button { showImport = true } label: {
                        Label("Add playlist by URL", systemImage: "text.badge.plus")
                    }
                    .accessibilityIdentifier("playlists.import")
                }

                if !library.importedPlaylists.isEmpty {
                    Section("Imported from YouTube") {
                        ForEach(library.importedPlaylists) { playlist in
                            NavigationLink {
                                ImportedPlaylistView(playlist: playlist, library: library)
                            } label: {
                                PlaylistRow(
                                    title: playlist.title,
                                    count: library.cachedPlaylistVideos(playlist.playlistId).count,
                                    symbol: "arrow.down.circle"
                                )
                            }
                            .swipeActions {
                                Button("Remove", role: .destructive) {
                                    library.removeImportedPlaylist(playlist.playlistId)
                                }
                            }
                        }
                    }
                }

                Section("My playlists") {
                    if library.state.playlists.isEmpty {
                        Text("No playlists yet. Create one to curate your own video list.")
                            .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                    ForEach(library.state.playlists) { playlist in
                        NavigationLink {
                            PlaylistVideosView(playlist: playlist, library: library)
                        } label: {
                            PlaylistRow(
                                title: playlist.name,
                                count: playlist.videos.count,
                                symbol: "play.rectangle.on.rectangle"
                            )
                        }
                        .contextMenu {
                            Button("Rename") { renameTarget = playlist; renameName = playlist.name }
                            Button("Delete", role: .destructive) { delete(playlist) }
                        }
                    }
                    .onDelete { library.state.playlists.remove(atOffsets: $0); library.persist() }
                }
            }
            .scrollContentBackground(.hidden).background(Color.cvBackground)
            .navigationTitle("Playlists").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .alert("New playlist", isPresented: $showCreate) {
                TextField("Playlist name", text: $createName)
                Button("Create") { create() }
                Button("Cancel", role: .cancel) { createName = "" }
            }
            .alert("Rename playlist", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("Playlist name", text: $renameName)
                Button("Save") { rename() }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .alert("Add playlist by URL", isPresented: $showImport) {
                TextField("https://www.youtube.com/playlist?list=…", text: $importURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Import") { Task { await importPlaylist() } }
                Button("Cancel", role: .cancel) { importURL = "" }
            } message: {
                Text("Paste a YouTube playlist link — or just its id. The app reads the public page, so a private playlist cannot be imported.")
            }
            .overlay { if importing { ProgressView("Importing…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
            .alert("Couldn't import that playlist", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { importError = nil }
            } message: { Text(importError ?? "") }
            .navigationDestination(item: $playingVideo) { video in
                if let reference = YouTubeLink.parse(video.url) {
                    MediaVideoPlayerView(video: video, reference: reference, library: library)
                } else {
                    SocialMediaPlayerView(video: video, library: library)
                }
            }
        }
        .tint(.cvPrimary)
    }

    private func create() {
        let trimmed = createName.trimmingCharacters(in: .whitespacesAndNewlines)
        createName = ""
        guard !trimmed.isEmpty else { return }
        library.state.playlists.append(MediaPlaylist(name: trimmed))
        library.persist()
    }

    private func rename() {
        guard let target = renameTarget else { return }
        let trimmed = renameName.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !trimmed.isEmpty, let index = library.state.playlists.firstIndex(where: { $0.id == target.id }) else { return }
        library.state.playlists[index].name = trimmed
        library.persist()
    }

    private func delete(_ playlist: MediaPlaylist) {
        library.state.playlists.removeAll { $0.id == playlist.id }
        library.persist()
    }

    private func importPlaylist() async {
        let input = importURL
        importURL = ""
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        importing = true
        defer { importing = false }
        do {
            _ = try await library.importPlaylist(input: input)
        } catch {
            importError = error.localizedDescription
        }
    }
}

/// One row in the manager: a playlist's name, how many videos it holds, and its kind.
private struct PlaylistRow: View {
    let title: String
    let count: Int
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Color.cvPrimary).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text("\(count) video\(count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            }
        }
    }
}

/// A local playlist's videos, in the reader's own order.
private struct PlaylistVideosView: View {
    let playlist: MediaPlaylist
    @Bindable var library: MediaLibrary
    @State private var playingVideo: LibraryVideo?

    var body: some View {
        List {
            if playlist.videos.isEmpty {
                Text("Nothing in this playlist yet. Use a video's ⋮ menu to add one.")
                    .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
            }
            ForEach(playlist.videos) { video in
                Button { library.open(video); playingVideo = video } label: {
                    PlaylistVideoRow(video: video)
                }
                .contextMenu {
                    Button("Remove from playlist", role: .destructive) {
                        guard let index = library.state.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
                        library.state.playlists[index].videos.removeAll { $0.id == video.id }
                        library.persist()
                    }
                }
            }
            .onDelete { offsets in
                guard let index = library.state.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
                library.state.playlists[index].videos.remove(atOffsets: offsets)
                library.persist()
            }
        }
        .scrollContentBackground(.hidden).background(Color.cvBackground)
        .navigationTitle(playlist.name).navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $playingVideo) { video in
            if let reference = YouTubeLink.parse(video.url) {
                MediaVideoPlayerView(video: video, reference: reference, library: library)
            } else {
                SocialMediaPlayerView(video: video, library: library)
            }
        }
    }
}

/// An imported YouTube playlist, read from its cached copy on first open.
private struct ImportedPlaylistView: View {
    let playlist: ImportedPlaylist
    @Bindable var library: MediaLibrary
    @State private var videos: [LibraryVideo] = []
    @State private var loading = false
    @State private var error: String?
    @State private var playingVideo: LibraryVideo?

    var body: some View {
        List {
            if loading { HStack { ProgressView(); Text("Reading the playlist…").font(.subheadline) } }
            if let error { Text(error).font(.subheadline).foregroundStyle(Color.cvError) }
            if videos.isEmpty && !loading && error == nil {
                Text("This playlist has no videos the app can read.")
                    .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
            }
            ForEach(videos) { video in
                Button { library.open(video); playingVideo = video } label: { PlaylistVideoRow(video: video) }
            }
        }
        .scrollContentBackground(.hidden).background(Color.cvBackground)
        .navigationTitle(playlist.title).navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load(fresh: true) }
        .navigationDestination(item: $playingVideo) { video in
            if let reference = YouTubeLink.parse(video.url) {
                MediaVideoPlayerView(video: video, reference: reference, library: library)
            } else {
                SocialMediaPlayerView(video: video, library: library)
            }
        }
    }

    private func load(fresh: Bool = false) async {
        if !fresh, let cached = library.state.importedPlaylistVideos?[playlist.playlistId], !cached.isEmpty {
            videos = cached
            return
        }
        loading = true
        error = nil
        defer { loading = false }
        do {
            videos = try await library.loadImportedPlaylist(playlist)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One playlist entry: the still, the name, and the channel.
private struct PlaylistVideoRow: View {
    let video: LibraryVideo

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: video.thumbnail, placeholder: AnyView(
                ZStack { Color.cvSurfaceContainer; Image(systemName: "play.rectangle").foregroundStyle(Color.cvOnSurfaceVariant) }
            ))
            .frame(width: 92, height: 52).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title).font(.subheadline.bold()).lineLimit(2)
                Text(video.channel).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant).lineLimit(1)
            }
        }
    }
}

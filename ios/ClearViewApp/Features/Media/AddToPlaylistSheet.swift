import SwiftUI

/// "Add to playlist" — the picker behind a video card's ⋮ menu, a Short's ⋮ menu,
/// and the player's Playlist button.
///
/// Android's `AddToPlaylistSheet`, and the same three things in the same order:
/// the video being added, every playlist the reader has (a plus on each row —
/// tapping adds this video to that one, and a playlist that already holds it says
/// so rather than holding it twice), and one button at the bottom that makes a new
/// playlist out of this video.
///
/// A sheet rather than a submenu, which is what iOS had. A `Menu` can only nest
/// one level of choices and cannot carry the count or the created-with button, so
/// "which playlist?" and "make one for this" have to be asked on a surface with
/// room for both.
struct AddToPlaylistSheet: View {
    let video: LibraryVideo
    @Bindable var library: MediaLibrary

    /// What the sheet is adding, for the two callers that add offline audio
    /// instead of a video (the Downloads list). Kept as the button's own label so
    /// the sheet never claims to be adding something it is not.
    var createsWithLabel = "New playlist with this video"

    @Environment(\.dismiss) private var dismiss
    @State private var showCreate = false
    @State private var name = ""
    /// The playlist just added to, so the row can show it landed without the
    /// sheet closing on the reader — a tap that dismissed the sheet would make
    /// adding to two playlists two full trips.
    @State private var justAdded: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if library.state.playlists.isEmpty {
                        Text("No playlists yet.")
                            .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        LazyVStack(spacing: 6) {
                            ForEach(library.state.playlists) { playlist in
                                row(playlist)
                            }
                        }
                    }
                    Button { showCreate = true } label: {
                        Label(createsWithLabel, systemImage: "text.badge.plus")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("playlist.newWithVideo")
                }
                .padding(20)
            }
            .background(Color.cvBackground)
            .navigationTitle("Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .alert("New playlist", isPresented: $showCreate) {
                TextField("Playlist name", text: $name)
                Button("Create and add") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let playlist = MediaPlaylist(name: trimmed)
                    library.state.playlists.append(playlist)
                    library.add(video, to: playlist.id)
                    name = ""
                    dismiss()
                }
                Button("Cancel", role: .cancel) { name = "" }
            } message: {
                Text(createsWithLabel + ".")
            }
        }
        .tint(.cvPrimary)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(video.title).font(.subheadline.bold()).lineLimit(2)
            Text(video.channel).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ playlist: MediaPlaylist) -> some View {
        let holds = playlist.videos.contains { $0.id == video.id }
        let marked = holds || justAdded == playlist.id
        return Button {
            library.add(video, to: playlist.id)
            justAdded = playlist.id
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .font(.system(size: 19)).foregroundStyle(Color.cvPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).font(.subheadline.bold()).lineLimit(1)
                    Text("\(playlist.videos.count) video\(playlist.videos.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }
                Spacer(minLength: 8)
                Image(systemName: marked ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 19))
                    .foregroundStyle(marked ? Color.cvPrimary : Color.cvOnSurfaceVariant)
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        // Already in it: the row reports the fact instead of offering a second
        // copy, which is the same rule `MediaLibrary.add` enforces.
        .disabled(holds)
        .accessibilityLabel("\(playlist.name), \(playlist.videos.count) videos")
        .accessibilityIdentifier("playlist.add.\(playlist.id)")
    }
}

import SwiftUI

/// The Media tab.
///
/// Placeholder. The Android tab is the largest single feature in the app —
/// YouTube/Instagram/X feeds, playlists, Shorts, the live broadcast tab, offline
/// audio downloads and the background audio player — so it is scheduled after
/// the Quran slice, and its shared parsers and filter model are ported first.
struct MediaView: View {
    var body: some View {
        NavigationStack {
            ComingSoonView(
                systemImage: "play.rectangle.on.rectangle",
                title: "Media",
                note: "Your YouTube, Instagram and X feeds, playlists, Shorts and "
                    + "Live will appear here. Not migrated yet."
            )
            .navigationTitle("Media")
        }
    }
}

#Preview {
    MediaView()
}

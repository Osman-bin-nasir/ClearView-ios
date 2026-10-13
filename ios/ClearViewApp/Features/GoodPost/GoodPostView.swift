import SwiftUI

/// The Good Post tab.
///
/// Placeholder. This is the publishing product, and it is the one feature whose
/// backend is reused unchanged — so on iOS it is pure client work: the channel
/// list, the feed, following, and later the composer and admin surfaces.
struct GoodPostView: View {
    var body: some View {
        NavigationStack {
            ComingSoonView(
                systemImage: "megaphone",
                title: "Good Post",
                note: "Channels you follow, and their updates. The ClearView "
                    + "backend is reused as-is; the iOS client is not built yet."
            )
            .navigationTitle("Good Post")
        }
    }
}

#Preview {
    GoodPostView()
}

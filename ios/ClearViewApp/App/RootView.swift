import SwiftUI

/// The four-tab shell.
///
/// The tabs mirror the Android app exactly — Quran, Media, Good Post, More — with
/// the same order and the same labels taken from its string resources
/// (`quran_tab`, the Media tab, `goodpost_tab`, `more_tab`). Each tab is a
/// `NavigationStack` so a feature can push screens without the shell knowing what
/// they are.
struct RootView: View {
    @State private var router = Router()

    var body: some View {
        TabView(selection: $router.selectedTab) {
            QuranView()
                .tabItem { Label("Quran", systemImage: "book.closed") }
                .tag(Router.Tab.quran)

            MediaView()
                .tabItem { Label("Media", systemImage: "play.rectangle.on.rectangle") }
                .tag(Router.Tab.media)

            GoodPostView()
                .tabItem { Label("Good Post", systemImage: "megaphone") }
                .tag(Router.Tab.goodPost)

            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis") }
                .tag(Router.Tab.more)
        }
        .tint(.cvPrimary)
        .environment(router)
    }
}

#Preview {
    RootView()
}

import SwiftUI

/// The four-tab shell.
///
/// The tabs mirror the Android app exactly — Quran, Media, Good Post, More, in
/// that order — with its own labels (`quran_tab`, `media_tab`, `goodpost_tab`,
/// `more_tab`) and marks of the same weight: an open book, a screen with a play
/// triangle, a megaphone and an ellipsis. Android's comment on the first two is
/// the reason for the pairing: the row reads as one set of marks only if each has
/// the same silhouette.
///
/// The bar is styled as Android builds it — `surface` at 62% opacity over a
/// transparent background, the selected item in the accent with its label, the
/// rest in `onSurfaceVariant`. UIKit owns the bar's appearance, so the styling
/// happens through `UITabBarAppearance` in `init` rather than in the view body.
///
/// Each tab is a `NavigationStack` so a feature can push screens without the shell
/// knowing what they are.
struct RootView: View {
    @State private var router = Router()
    @State private var controls = DeviceControlsController.shared
    @State private var showFocusGate = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "dark"

    init() {
        Self.styleTabBar()
    }

    var body: some View {
        TabView(selection: $router.selectedTab) {
            QuranView()
                .tabItem { Label("Quran", systemImage: "book.pages") }
                .tag(Router.Tab.quran)

            MediaView()
                .tabItem { Label("Media", systemImage: "play.rectangle.fill") }
                .tag(Router.Tab.media)

            GoodPostView()
                .tabItem { Label("Good Post", systemImage: "megaphone.fill") }
                .tag(Router.Tab.goodPost)

            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis") }
                .tag(Router.Tab.more)
        }
        .tint(.cvPrimary)
        .environment(router)
        .preferredColorScheme(appearance == "system" ? nil : appearance == "light" ? .light : .dark)
        .onOpenURL { url in router.open(url) }
        .fullScreenCover(isPresented: $showFocusGate) { FocusExpiredView() }
        .task(id: controls.expired) {
            if !controls.expired { showFocusGate = false; return }
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled && controls.expired { showFocusGate = true }
        }
        .task {
            controls.refresh()
            let protection = ProtectionModel.shared
            controls.syncProtection(enabled: protection.protectionEnabled, domains: protection.store.blockedDomains)
            await SafariProtectionController.shared.sync(enabled: protection.protectionEnabled, domains: protection.rules().domains)
            await TodoReminderScheduler.shared.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                controls.refreshExpiry()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                controls.refresh()
                Task { await TodoReminderScheduler.shared.refresh() }
            }
        }
    }

    /// The bar's own colours, in Android's terms.
    ///
    /// `configureWithTransparentBackground()` rather than an opaque fill, plus the
    /// 62%-alpha surface as the background colour: that pair is what makes the
    /// page visible *through* the bar instead of the bar sitting on top of the
    /// page as a band.
    private static func styleTabBar() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .cvBarContainer
        appearance.shadowColor = .clear

        let item = UITabBarItemAppearance()
        item.normal.iconColor = .cvBarUnselected
        item.normal.titleTextAttributes = [.foregroundColor: UIColor.cvBarUnselected]
        item.selected.iconColor = .cvBarSelected
        item.selected.titleTextAttributes = [.foregroundColor: UIColor.cvBarSelected]

        appearance.stackedLayoutAppearance = item
        appearance.inlineLayoutAppearance = item
        appearance.compactInlineLayoutAppearance = item

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
}

#Preview {
    RootView()
}

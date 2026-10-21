import SwiftUI
import UIKit

/// The five-tab shell, with the in-app websites beside the curated Media feed.
///
/// Quran, Media, Apps, Good Post and More share the Android palette and native
/// navigation. Apps adds persistent, filtered website sessions to the iOS shell.
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

            AppsHubView()
                .tabItem {
                    Label {
                        Text("Apps")
                    } icon: {
                        Image(uiImage: router.selectedTab == .apps ? Self.selectedAppsIcon : Self.unselectedAppsIcon)
                            .renderingMode(.original)
                    }
                }
                .tag(Router.Tab.apps)

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

    private static let selectedAppsIcon = appsIcon(selected: true)
    private static let unselectedAppsIcon = appsIcon(selected: false)

    private static func appsIcon(selected: Bool) -> UIImage {
        let colors: [UIColor] = selected ? [
            UIColor(red: 0.15, green: 0.76, blue: 0.57, alpha: 1), .white,
            UIColor(red: 0.97, green: 0.76, blue: 0.29, alpha: 1),
            UIColor(red: 0.95, green: 0.45, blue: 0.46, alpha: 1)
        ] : Array(repeating: .white, count: 4)
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in
            for index in 0..<4 {
                colors[index].setFill()
                let rect = CGRect(x: 2.5 + Double(index % 2) * 10.5,
                                  y: 2.5 + Double(index / 2) * 10.5, width: 8.5, height: 8.5)
                UIBezierPath(roundedRect: rect, cornerRadius: 1.8).fill()
            }
        }.withRenderingMode(.alwaysOriginal)
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

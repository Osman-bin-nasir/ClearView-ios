import Observation
import Foundation

/// The app's top-level navigation state.
///
/// Android's equivalent is `MainActivity`'s `MainTab` enum plus the
/// `ContentHubState` returned by `rememberContentHubState()` — one activity, four
/// tabs, and a set of overlay flags. This is that state, in Swift.
///
/// It is deliberately small. The point of adding it now is that deep links
/// (a shared channel link, a notification tap, "open what is playing") all have
/// one place to land, which is what the Android side's ten separate
/// `LaunchedEffect` blocks are doing today. Those destinations are added here as
/// each feature is built, not invented up front.
@Observable
final class Router {

    /// Apps sits beside Media; Protection remains inside More.
    enum Tab: Hashable {
        case quran
        case media
        case apps
        case goodPost
        case more
    }

    var selectedTab: Tab = .quran
    var channelSlug: String?

    func open(_ url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.scheme == "clearview", url.host == "goodpost", parts.first == "channel", parts.count == 2 {
            selectedTab = .goodPost
            channelSlug = parts[1]
        } else if url.host == "clearview-1neb.onrender.com", parts.first == "c", parts.count == 2 {
            selectedTab = .goodPost
            channelSlug = parts[1]
        }
    }
}

import Observation

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

    /// The four bottom-bar destinations, in the Android app's order.
    ///
    /// Android names them `MainTab.QURAN / MEDIA / GOODPOST / MORE`; the More tab
    /// holds a nested "Protection" page, which lives inside `MoreView` rather
    /// than being a fifth tab — exactly as it does on Android.
    enum Tab: Hashable {
        case quran
        case media
        case goodPost
        case more
    }

    var selectedTab: Tab = .quran
}

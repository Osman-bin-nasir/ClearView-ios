import Foundation
import Observation

enum AppDestination: String, Identifiable {
    case home, subscriptions, shortVideos, explore, account
    var id: String { rawValue }

    func title(for site: AppSite) -> String {
        switch self {
        case .home: return "Home"
        case .subscriptions: return "Subscriptions"
        case .shortVideos: return site.shortVideoName
        case .explore: return "Search"
        case .account: return site == .youtube ? "You" : "Profile"
        }
    }

    func symbol(selected: Bool) -> String {
        switch self {
        case .home: return selected ? "house.fill" : "house"
        case .subscriptions: return selected ? "play.rectangle.on.rectangle.fill" : "play.rectangle.on.rectangle"
        case .shortVideos: return selected ? "play.rectangle.fill" : "play.rectangle"
        case .explore: return "magnifyingglass"
        case .account: return selected ? "person.crop.circle.fill" : "person.crop.circle"
        }
    }
}

enum AppSite: String, CaseIterable, Codable, Identifiable {
    case youtube, instagram

    var id: String { rawValue }
    var name: String { self == .youtube ? "YouTube" : "Instagram" }
    var shortVideoName: String { self == .youtube ? "Shorts" : "Reels" }
    var subtitle: String {
        self == .youtube ? "Your channels. Your kind of watching." : "Keep up with people, on your terms."
    }
    var home: URL {
        URL(string: self == .youtube ? "https://m.youtube.com/" : "https://www.instagram.com/")!
    }
    var search: URL {
        URL(string: self == .youtube ? "https://m.youtube.com/results?search_query=" : "https://www.instagram.com/explore/search/")!
    }

    var destinations: [AppDestination] {
        self == .youtube ? [.home, .shortVideos, .subscriptions, .account] : [.home, .explore, .shortVideos, .account]
    }

    func destinationURL(_ destination: AppDestination) -> URL {
        let path: String
        switch (self, destination) {
        case (_, .home): return home
        case (.youtube, .subscriptions): path = "feed/subscriptions"
        case (.youtube, .account): path = "feed/library"
        case (.youtube, .shortVideos): path = "shorts"
        case (.instagram, .shortVideos): path = "reels/"
        case (.instagram, .explore): path = "explore/"
        case (.instagram, .account): path = "accounts/login/"
        default: return home
        }
        return home.appendingPathComponent(path)
    }

    func searchURL(_ query: String) -> URL {
        let path = self == .youtube ? "results" : "explore/search/keyword/"
        var parts = URLComponents(url: home.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: self == .youtube ? "search_query" : "q", value: query)]
        return parts.url!
    }

    func isAuthenticationPage(_ url: URL) -> Bool {
        if allowsAuthentication(url) { return true }
        let path = url.path.lowercased()
        return owns(url) && ["/accounts/", "/signin", "/login", "/challenge/", "/consent", "/checkpoint/"].contains(where: path.hasPrefix)
    }

    func owns(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        let domain = self == .youtube ? "youtube.com" : "instagram.com"
        return host == domain || host.hasSuffix("." + domain) || (self == .youtube && host == "youtu.be")
    }

    func allowsAuthentication(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        switch self {
        case .youtube:
            return ["accounts.google.com", "consent.google.com", "myaccount.google.com"].contains(host)
        case .instagram:
            // Facebook Login may redirect through either mobile or desktop endpoints.
            return ["www.facebook.com", "m.facebook.com", "accountscenter.facebook.com"].contains(host)
        }
    }

    func isShortVideo(_ url: URL) -> Bool {
        guard owns(url) else { return false }
        let path = url.path.lowercased()
        return self == .youtube
            ? path == "/shorts" || path.hasPrefix("/shorts/")
            : ["/reel", "/reels"].contains(path) || path.hasPrefix("/reel/") || path.hasPrefix("/reels/")
    }

    /// Website deep links stay in the embedded app instead of launching the installed app.
    func webEquivalent(of url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        if self == .youtube, ["youtube", "vnd.youtube"].contains(parts.scheme?.lowercased() ?? "") {
            let videoID = parts.queryItems?.first(where: { $0.name == "v" })?.value
                ?? (parts.host == "watch" ? nil : parts.host)
            guard let videoID, videoID.range(of: #"^[a-zA-Z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
            parts = URLComponents(url: home.appendingPathComponent("watch"), resolvingAgainstBaseURL: false)!
            parts.queryItems = [URLQueryItem(name: "v", value: videoID)]
            return parts.url
        }
        if self == .instagram, url.scheme?.lowercased() == "instagram", parts.host == "user",
           let handle = parts.queryItems?.first(where: { $0.name == "username" })?.value,
           handle.range(of: #"^[a-zA-Z0-9_.]{1,30}$"#, options: .regularExpression) != nil {
            return home.appendingPathComponent(handle)
        }
        return nil
    }
}

struct AppBrowsingPreferences: Codable, Equatable {
    var blockShortVideos = false
    var keywords: [String] = []
}

/// Preferences and browser instances live above the presented reader. Closing an app
/// pauses it; reopening keeps its page, history, cookies and local storage.
@MainActor
@Observable
final class AppsLibrary {
    private(set) var preferences: [String: AppBrowsingPreferences]
    @ObservationIgnored private var sessions: [AppSite: AppBrowserSession] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "apps.browsing.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: AppBrowsingPreferences].self, from: $0) } ?? [:]
    }

    func preferences(for site: AppSite) -> AppBrowsingPreferences {
        preferences[site.rawValue] ?? AppBrowsingPreferences()
    }

    func protectionBlocksShortVideos(for site: AppSite) -> Bool {
        let global = ProtectionModel.shared.enforcementOptions
        return site == .youtube && global.protectionEnabled && global.youTubeProtection && global.blockShorts
    }

    func blocksShortVideos(for site: AppSite) -> Bool {
        preferences(for: site).blockShortVideos || protectionBlocksShortVideos(for: site)
    }

    func update(_ site: AppSite, _ change: (inout AppBrowsingPreferences) -> Void) {
        var value = preferences(for: site)
        change(&value)
        preferences[site.rawValue] = value
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.key) }
        sessions[site]?.applyPreferences()
    }

    func session(for site: AppSite) -> AppBrowserSession {
        if let existing = sessions[site] { return existing }
        let created = AppBrowserSession(site: site, library: self)
        sessions[site] = created
        return created
    }
}

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
        case .explore: return site == .snapchat ? "Discover" : "Search"
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
    case google, youtube, instagram, snapchat, facebook, web

    var id: String { rawValue }
    var name: String {
        switch self {
        case .google: return "Google"
        case .youtube: return "YouTube"
        case .instagram: return "Instagram"
        case .snapchat: return "Snapchat"
        case .facebook: return "Facebook"
        case .web: return "Browser"
        }
    }
    /// YouTube, Instagram, Snapchat and Facebook are presented as apps with a native
    /// header and bottom navigation. Google and custom websites keep the browser chrome.
    var usesAppShell: Bool { self != .google && self != .web }

    /// Apps whose header shows the brand mark and app name without a website address.
    var usesBrandedHeader: Bool { self == .snapchat || self == .facebook }

    /// The site's short-form video surface, or an empty string when it has none.
    ///
    /// Snapchat calls its vertical feed Spotlight; Facebook and Instagram both call
    /// theirs Reels. Keeping the name beside the site is what lets one settings row,
    /// one route cover and one URL check speak each app's language.
    var shortVideoName: String {
        switch self {
        case .youtube: return "Shorts"
        case .instagram, .facebook: return "Reels"
        case .snapchat: return "Spotlight"
        case .google, .web: return ""
        }
    }

    /// Whether this site has a short-form surface ClearView can hide.
    var supportsShortVideoBlocking: Bool { !shortVideoName.isEmpty }

    var subtitle: String {
        switch self {
        case .youtube: return "Your channels. Your kind of watching."
        case .instagram, .snapchat, .facebook: return "Keep up with people, on your terms."
        case .google, .web: return "Search the web, with a little more intention."
        }
    }
    var home: URL {
        let value: String
        switch self {
        case .youtube: value = "https://m.youtube.com/"
        case .instagram: value = "https://www.instagram.com/"
        case .snapchat: value = "https://www.snapchat.com/discover"
        case .facebook: value = "https://m.facebook.com/"
        case .google, .web: value = "https://www.google.com/"
        }
        return URL(string: value)!
    }
    var search: URL {
        searchURL("")
    }

    var destinations: [AppDestination] {
        switch self {
        case .youtube: return [.home, .shortVideos, .subscriptions, .account]
        case .instagram: return [.home, .explore, .shortVideos, .account]
        case .snapchat: return [.home, .shortVideos, .account]
        case .facebook: return [.home, .shortVideos, .explore, .account]
        case .google, .web: return [.home]
        }
    }

    func destinationURL(_ destination: AppDestination) -> URL {
        // Snapchat's home is Discover, while Spotlight lives at the site root's
        // sibling path; its Profile tab is the account site.
        if self == .snapchat {
            switch destination {
            case .home: return home
            case .shortVideos: return URL(string: "https://www.snapchat.com/spotlight")!
            case .account: return URL(string: "https://accounts.snapchat.com/accounts/login")!
            default: return home
            }
        }
        let path: String
        switch (self, destination) {
        case (_, .home): return home
        case (.youtube, .subscriptions): path = "feed/subscriptions"
        case (.youtube, .account): path = "feed/library"
        case (.youtube, .shortVideos): path = "shorts"
        case (.instagram, .shortVideos): path = "reels/"
        case (.instagram, .explore): path = "explore/"
        case (.instagram, .account): path = "accounts/login/"
        case (.facebook, .shortVideos): path = "reels/"
        case (.facebook, .explore): path = "search/top/"
        case (.facebook, .account): path = "me"
        default: return home
        }
        return home.appendingPathComponent(path)
    }

    func searchURL(_ query: String) -> URL {
        let (path, parameter): (String, String)
        switch self {
        case .youtube: (path, parameter) = ("results", "search_query")
        case .instagram: (path, parameter) = ("explore/search/keyword/", "q")
        case .facebook: (path, parameter) = ("search/top/", "q")
        case .snapchat: (path, parameter) = ("search", "q")
        case .google, .web: (path, parameter) = ("search", "q")
        }
        var parts = URLComponents(url: home.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: parameter, value: query)]
        return parts.url!
    }

    func isAuthenticationPage(_ url: URL) -> Bool {
        if allowsAuthentication(url) { return true }
        let path = url.path.lowercased()
        return owns(url) && ["/accounts/", "/signin", "/login", "/challenge/", "/consent", "/checkpoint/"].contains(where: path.hasPrefix)
    }

    /// The domain an app belongs to. Google and the shared browser deliberately have
    /// none: they keep every HTTPS link inside their own session.
    var domain: String? {
        switch self {
        case .youtube: return "youtube.com"
        case .instagram: return "instagram.com"
        case .snapchat: return "snapchat.com"
        case .facebook: return "facebook.com"
        case .google, .web: return nil
        }
    }

    func owns(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        guard let domain else { return true }
        return host == domain || host.hasSuffix("." + domain) || (self == .youtube && host == "youtu.be")
    }

    func allowsAuthentication(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        switch self {
        case .youtube:
            return ["accounts.google.com", "consent.google.com", "myaccount.google.com"].contains(host)
        case .google, .web:
            return ["accounts.google.com", "consent.google.com", "myaccount.google.com"].contains(host)
        case .instagram:
            // Facebook Login may redirect through either mobile or desktop endpoints.
            return ["www.facebook.com", "m.facebook.com", "accountscenter.facebook.com"].contains(host)
        case .snapchat:
            // Snapchat for Web can hand sign-in to Google or Apple.
            return ["accounts.google.com", "consent.google.com", "appleid.apple.com"].contains(host)
        case .facebook:
            return ["accounts.google.com", "consent.google.com"].contains(host)
        }
    }

    /// Which app a host belongs to, for the short-video check. A browser session can be
    /// pointed at any of the four, and the block that applies is the one for the host in
    /// the address bar rather than the one the session was opened for.
    static func shortVideoSite(for host: String?) -> AppSite? {
        guard let host = host?.lowercased() else { return nil }
        if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be" { return .youtube }
        if host == "instagram.com" || host.hasSuffix(".instagram.com") { return .instagram }
        if host == "snapchat.com" || host.hasSuffix(".snapchat.com") { return .snapchat }
        if host == "facebook.com" || host.hasSuffix(".facebook.com") { return .facebook }
        return nil
    }

    func isShortVideo(_ url: URL) -> Bool {
        guard let host = url.host, AppSite.shortVideoSite(for: host) == self else { return false }
        let path = url.path.lowercased()
        switch self {
        case .youtube:
            return path == "/shorts" || path.hasPrefix("/shorts/")
        case .instagram:
            return ["/reel", "/reels"].contains(path) || path.hasPrefix("/reel/") || path.hasPrefix("/reels/")
        case .snapchat:
            // The public Spotlight page is /spotlight; Snapchat for Web keeps the
            // same feed under /web/spotlight/.
            return ["/spotlight", "/web/spotlight"].contains(path)
                || path.hasPrefix("/spotlight/") || path.hasPrefix("/web/spotlight/")
        case .facebook:
            // Facebook uses /reel/<id> and /reels, and its Share sheet produces
            // /share/reel/<id> and /share/r/<id> links that land on the same player.
            return ["/reel", "/reels"].contains(path) || path.hasPrefix("/reel/") || path.hasPrefix("/reels/")
                || path.hasPrefix("/share/reel/") || path.hasPrefix("/share/r/")
        case .google, .web:
            return false
        }
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

struct BrowserProtectionPreferences: Codable, Equatable {
    var hideGoogleCategories = true
    var removeBlockedCards = true
    var blockYouTubeAds = false
}

struct BrowserShortcut: Codable, Identifiable {
    var id = UUID()
    let name: String
    let url: URL
}

/// Preferences and browser instances live above the presented reader. Closing an app
/// pauses it; reopening keeps its page, history, cookies and local storage.
@MainActor
@Observable
final class AppsLibrary {
    private(set) var preferences: [String: AppBrowsingPreferences]
    private(set) var browserPreferences: BrowserProtectionPreferences
    private(set) var shortcuts: [BrowserShortcut]
    @ObservationIgnored private var sessions: [AppSite: AppBrowserSession] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "apps.browsing.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        browserPreferences = defaults.data(forKey: "apps.browser-protection.v1")
            .flatMap { try? JSONDecoder().decode(BrowserProtectionPreferences.self, from: $0) } ?? BrowserProtectionPreferences()
        shortcuts = defaults.data(forKey: "apps.shortcuts.v1")
            .flatMap { try? JSONDecoder().decode([BrowserShortcut].self, from: $0) } ?? []
        preferences = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: AppBrowsingPreferences].self, from: $0) } ?? [:]
    }

    func preferences(for site: AppSite) -> AppBrowsingPreferences {
        preferences[site.rawValue] ?? AppBrowsingPreferences()
    }

    func keywords(for site: AppSite, at url: URL? = nil) -> [String] {
        var values = preferences(for: .web).keywords
        if site.usesAppShell { values += preferences(for: site).keywords }
        else if let host = url?.host, let owner = AppSite.shortVideoSite(for: host) {
            values += preferences(for: owner).keywords
        }
        return Array(Set(values)).sorted()
    }

    func protectionBlocksShortVideos(for site: AppSite) -> Bool {
        let global = ProtectionModel.shared.enforcementOptions
        return site == .youtube && global.protectionEnabled && global.youTubeProtection && global.blockShorts
    }

    func blocksShortVideos(for site: AppSite) -> Bool {
        guard site.supportsShortVideoBlocking else { return false }
        return preferences(for: site).blockShortVideos || protectionBlocksShortVideos(for: site)
    }

    func update(_ site: AppSite, _ change: (inout AppBrowsingPreferences) -> Void) {
        var value = preferences(for: site)
        change(&value)
        preferences[site.rawValue] = value
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: Self.key) }
        sessions.values.forEach { $0.applyPreferences() }
    }

    func updateBrowser(_ change: (inout BrowserProtectionPreferences) -> Void) {
        var value = browserPreferences
        change(&value)
        browserPreferences = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "apps.browser-protection.v1") }
        sessions.values.forEach { $0.applyPreferences() }
    }

    func addShortcut(name: String, url: URL) {
        guard shortcuts.count < 24, !shortcuts.contains(where: { $0.url == url }) else { return }
        shortcuts.append(BrowserShortcut(name: name, url: url))
        saveShortcuts()
    }

    func removeShortcut(_ id: UUID) { shortcuts.removeAll { $0.id == id }; saveShortcuts() }
    private func saveShortcuts() {
        if let data = try? JSONEncoder().encode(shortcuts) { defaults.set(data, forKey: "apps.shortcuts.v1") }
    }

    static func browserURL(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil { return url }
        if !value.contains(where: \.isWhitespace), !value.contains("://"), value.contains("."),
           let url = URL(string: "https://" + value), url.host != nil { return url }
        return AppSite.google.searchURL(value)
    }

    func allGoogleResultsURL(_ url: URL) -> URL? {
        guard browserPreferences.hideGoogleCategories, let host = url.host,
              host.range(of: #"^(www\.|m\.)?google\.[a-z]{2,}(\.[a-z]{2,})?$"#, options: .regularExpression) != nil,
              url.path == "/search", var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.queryItems?.contains(where: { ["tbm", "udm"].contains($0.name) }) == true else { return nil }
        parts.queryItems?.removeAll { ["tbm", "udm"].contains($0.name) }
        return parts.url
    }

    func blocksShortVideos(at url: URL) -> Bool {
        guard let site = AppSite.shortVideoSite(for: url.host) else { return false }
        return blocksShortVideos(for: site) && site.isShortVideo(url)
    }

    func session(for site: AppSite) -> AppBrowserSession {
        if let existing = sessions[site] { return existing }
        let created = AppBrowserSession(site: site, library: self)
        sessions[site] = created
        return created
    }
}

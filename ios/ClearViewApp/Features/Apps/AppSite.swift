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
    case google, youtube, instagram, web

    var id: String { rawValue }
    var name: String {
        switch self {
        case .google: return "Google"
        case .youtube: return "YouTube"
        case .instagram: return "Instagram"
        case .web: return "Browser"
        }
    }
    var usesAppShell: Bool { self == .youtube || self == .instagram }
    var shortVideoName: String { self == .youtube ? "Shorts" : "Reels" }
    var subtitle: String {
        self == .youtube ? "Your channels. Your kind of watching." : "Keep up with people, on your terms."
    }
    var home: URL {
        URL(string: self == .youtube ? "https://m.youtube.com/"
            : self == .instagram ? "https://www.instagram.com/" : "https://www.google.com/")!
    }
    var search: URL {
        searchURL("")
    }

    var destinations: [AppDestination] {
        self == .youtube ? [.home, .shortVideos, .subscriptions, .account] : self == .instagram ? [.home, .explore, .shortVideos, .account] : [.home]
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
        let path = self == .youtube ? "results" : self == .instagram ? "explore/search/keyword/" : "search"
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
        if !usesAppShell { return true }
        let domain = self == .youtube ? "youtube.com" : "instagram.com"
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
        }
    }

    func isShortVideo(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        let isYouTube = host == "youtube.com" || host.hasSuffix(".youtube.com")
        let isInstagram = host == "instagram.com" || host.hasSuffix(".instagram.com")
        guard isYouTube || isInstagram else { return false }
        let path = url.path.lowercased()
        return isYouTube
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
        else if let host = url?.host {
            if host == "youtube.com" || host.hasSuffix(".youtube.com") { values += preferences(for: .youtube).keywords }
            if host == "instagram.com" || host.hasSuffix(".instagram.com") { values += preferences(for: .instagram).keywords }
        }
        return Array(Set(values)).sorted()
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
        guard let host = url.host else { return false }
        if host == "youtube.com" || host.hasSuffix(".youtube.com") { return blocksShortVideos(for: .youtube) && AppSite.youtube.isShortVideo(url) }
        if host == "instagram.com" || host.hasSuffix(".instagram.com") { return blocksShortVideos(for: .instagram) && AppSite.instagram.isShortVideo(url) }
        return false
    }

    func session(for site: AppSite) -> AppBrowserSession {
        if let existing = sessions[site] { return existing }
        let created = AppBrowserSession(site: site, library: self)
        sessions[site] = created
        return created
    }
}

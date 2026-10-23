import Foundation
import Observation
import UIKit
import WebKit

@MainActor
@Observable
final class AppBrowserSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    let site: AppSite
    var progress = 0.0
    var isLoading = true
    var canGoBack = false
    var canGoForward = false
    var currentURL: URL?
    var errorMessage: String?
    var blockedPage: String?
    var hiddenCount = 0
    var externalURL: URL?
    var unsupportedLink = false
    var showsIntentHome = false
    var navigationHidden = false
    var protectionNotice: String?

    @ObservationIgnored private weak var library: AppsLibrary?
    @ObservationIgnored private(set) var webView: WKWebView!
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var active = false
    @ObservationIgnored private var reported = Set<String>()
    @ObservationIgnored private var keywordSignature: [String] = []
    @ObservationIgnored private var compiledKeywords: [ProtectionKeywordEntry] = []
    @ObservationIgnored private var currentDocument = ""
    @ObservationIgnored private var scriptAvailable = false
    @ObservationIgnored private var filterSource = ""
    @ObservationIgnored private var blockedForShortVideos = false
    @ObservationIgnored private var rejectedURL: URL?
    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var loadRevision = 0
    @ObservationIgnored private var adRuleList: WKContentRuleList?

    init(site: AppSite, library: AppsLibrary) {
        self.site = site
        self.library = library
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        // The isolated world can inspect feed DOM, but page scripts cannot invoke
        // the native bridge or read the filter's JavaScript state.
        let controller = config.userContentController
        controller.add(AppsMessageBridge(self), contentWorld: .defaultClient, name: "appsFilter")
        if let url = Bundle.main.url(forResource: "ClearViewApps", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            scriptAvailable = true
            filterSource = source
            let bootstrap = "const clearViewInitial = \(json(configuration));\n" + source
            controller.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true, in: .defaultClient))
        }
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .cvBackground
        webView.scrollView.backgroundColor = .cvBackground
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .interactive
        webView.accessibilityIdentifier = "apps.browser.\(site.rawValue)"
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] view, _ in
                let value = view.estimatedProgress
                Task { @MainActor in self?.progress = value }
            },
            webView.observe(\.canGoBack) { [weak self] view, _ in
                let value = view.canGoBack
                Task { @MainActor in self?.canGoBack = value }
            },
            webView.observe(\.canGoForward) { [weak self] view, _ in
                let value = view.canGoForward
                Task { @MainActor in self?.canGoForward = value }
            },
            webView.observe(\.url) { [weak self] view, _ in
                let value = view.url
                Task { @MainActor in self?.currentURL = value }
            },
        ]
    }

    var blocksShortVideos: Bool {
        library?.blocksShortVideos(for: site) ?? false
    }

    var showsAppNavigation: Bool {
        guard let url = currentURL else { return true }
        return site.owns(url) && !site.isAuthenticationPage(url)
    }

    var selectedDestination: AppDestination {
        let path = currentURL?.path.lowercased() ?? "/"
        if let url = currentURL, site.isShortVideo(url) { return .shortVideos }
        if path.hasPrefix("/feed/subscriptions") { return .subscriptions }
        if path.hasPrefix("/explore") || path == "/results" { return .explore }
        if path.hasPrefix("/feed/you") || path.hasPrefix("/feed/library") || path.hasPrefix("/accounts") { return .account }
        if site == .instagram && path != "/" && !["/p/", "/reel/", "/direct/"].contains(where: path.hasPrefix) { return .account }
        return .home
    }

    /// The SwiftUI task tracks these observed settings, including edits in More.
    var filterSignature: String {
        let protection = ProtectionModel.shared
        let prefs = library?.preferences(for: site) ?? AppBrowsingPreferences()
        return json(configuration) + prefs.keywords.joined(separator: "\n")
            + String(describing: protection.rules()) + String(describing: protection.enforcementOptions)
    }

    private var configuration: [String: Any] {
        ["site": site.rawValue, "blockShorts": library?.blocksShortVideos(for: .youtube) ?? false,
         "blockReels": library?.blocksShortVideos(for: .instagram) ?? false,
         "hideGoogleCategories": library?.browserPreferences.hideGoogleCategories ?? true,
         "removeBlockedCards": library?.browserPreferences.removeBlockedCards ?? true,
         "blockAds": library?.browserPreferences.blockYouTubeAds ?? false,
         "active": active, "appShell": site.usesAppShell,
         "dark": webView?.traitCollection.userInterfaceStyle != .light]
    }

    func resume(dark: Bool) {
        active = true
        webView.overrideUserInterfaceStyle = dark ? .dark : .light
        guard scriptAvailable else {
            errorMessage = "The app browser could not load its filters. Reinstall this build to continue."
            isLoading = false
            return
        }
        if webView.url == nil && pendingURL == nil && rejectedURL == nil { goHome() }
        applyPreferences()
    }

    func pause() {
        active = false
        finishDialog(nil)
        invoke("window.__clearviewApps?.pause()")
        // Also pauses videos on authentication/interstitial pages without the filter.
        webView.pauseAllMediaPlayback(completionHandler: nil)
    }

    func applyPreferences() {
        // Future documents start with current settings before their first paint.
        if scriptAvailable {
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            let bootstrap = "const clearViewInitial = \(json(configuration));\n" + filterSource
            controller.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: .defaultClient))
        }
        invoke("window.__clearviewApps?.update(config)", arguments: ["config": configuration])
        Task { await updateRequestRules() }
        if let url = rejectedURL, !isBlockedShortURL(url), navigationDecision(for: url) == nil {
            rejectedURL = nil
            load(url)
        } else if let url = webView.url {
            if let allResults = library?.allGoogleResultsURL(url) { load(allResults); return }
            if isBlockedShortURL(url) {
                blockCurrentPage("Short videos are hidden by your settings.", shortVideo: true)
            } else if let decision = navigationDecision(for: url) {
                rejectedURL = url
                blockCurrentPage("This page is hidden by your browser protection (\(decision.matched)).")
            } else if blockedForShortVideos {
                blockedForShortVideos = false
                blockedPage = nil
            }
        }
    }

    func open(_ url: URL) { load(url) }

    private func isBlockedShortURL(_ url: URL) -> Bool { library?.blocksShortVideos(at: url) ?? false }

    private func navigationDecision(for url: URL) -> BlockDecision? {
        let model = ProtectionModel.shared
        let shared = model.rules()
        let keywords = library?.keywords(for: site, at: url) ?? []
        var rules = ProtectionRules(alwaysBlock: shared.alwaysBlock,
            userKeywords: ProtectionMatcher.compile(keywords) + (model.protectionEnabled ? shared.userKeywords : []))
        rules.domains = model.protectionEnabled ? shared.domains : ProtectionPresets.adultDomains.compactMap(ProtectionMatcher.normalizeDomain)
        // Authentication query strings can contain tokens, not search terms.
        if site.isAuthenticationPage(url) {
            var domainRules = ProtectionRules()
            domainRules.domains = rules.domains
            return ProtectionMatcher.decision(forURL: url.host ?? "", rules: domainRules)
        }
        if let decision = ProtectionMatcher.decision(forURL: url.absoluteString.removingPercentEncoding ?? url.absoluteString, rules: rules) { return decision }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if ["/search", "/results"].contains(url.path) || url.path.hasPrefix("/explore/search") {
            for item in parts?.queryItems ?? [] where ["q", "search_query"].contains(item.name) {
                if let value = item.value, let decision = ProtectionMatcher.decision(forText: value.replacingOccurrences(of: "+", with: " "), rules: rules) { return decision }
            }
        }
        return nil
    }

    private func updateRequestRules() async {
        guard library?.browserPreferences.blockYouTubeAds == true else {
            if let adRuleList { webView.configuration.userContentController.remove(adRuleList); self.adRuleList = nil }
            protectionNotice = nil
            return
        }
        guard adRuleList == nil else { return }
        do {
            let rules = try await BrowserAdBlocker.rules()
            guard library?.browserPreferences.blockYouTubeAds == true, adRuleList == nil else { return }
            webView.configuration.userContentController.add(rules)
            adRuleList = rules
            protectionNotice = nil
        } catch {
            NSLog("ClearView ad rule compilation: %@", error.localizedDescription)
            protectionNotice = "Ad request blocking couldn’t start. Reload to try again."
        }
    }

    func goHome() { load(site.home) }
    func search(_ query: String) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if site.usesAppShell { load(site.searchURL(value)) }
        else if let url = AppsLibrary.browserURL(value) { load(url) }
    }

    func navigate(_ destination: AppDestination) {
        guard destination != .shortVideos || !blocksShortVideos else { return }
        if site == .youtube {
            // Hidden website controls can ignore synthetic clicks while still
            // reporting success. Native tabs load their actual route directly.
            load(site.destinationURL(destination))
        } else if site == .instagram && destination == .account, let url = webView.url, site.owns(url) {
            webView.callAsyncJavaScript("return window.__clearviewApps?.openProfile() ?? false", arguments: [:],
                in: nil, in: .defaultClient) { [weak self] result in
                    guard let self, self.active else { return }
                    if case .success(let value) = result, value as? Bool == true { return }
                    self.load(self.site.destinationURL(destination))
                }
        } else {
            load(site.destinationURL(destination))
        }
    }

    func openInbox() { load(site.home.appendingPathComponent("direct/inbox/")) }
    func goSearch() {
        guard let url = webView.url, site.owns(url) else { load(site.search); return }
        webView.callAsyncJavaScript("return window.__clearviewApps?.search() ?? false", arguments: [:],
            in: nil, in: .defaultClient) { [weak self] result in
                guard let self, self.active else { return }
                if case .success(let value) = result, value as? Bool == true { return }
                self.load(self.site.search)
            }
    }
    func goBack() { rejectedURL = nil; blockedPage = nil; errorMessage = nil; navigationHidden = false; webView.goBack() }
    func goForward() { rejectedURL = nil; blockedPage = nil; errorMessage = nil; navigationHidden = false; webView.goForward() }
    func reload() {
        guard scriptAvailable else { return }
        errorMessage = nil
        blockedPage = nil
        if webView.url == nil { goHome() } else { webView.reload() }
    }

    private func load(_ requestedURL: URL) {
        guard scriptAvailable else { return }
        let url = library?.allGoogleResultsURL(requestedURL) ?? requestedURL
        errorMessage = nil
        blockedPage = nil
        rejectedURL = nil
        pendingURL = nil
        showsIntentHome = false
        navigationHidden = false
        loadRevision += 1
        let revision = loadRevision
        guard !isBlockedShortURL(url) else {
            rejectedURL = url
            blockCurrentPage("Short videos are hidden by your settings.", shortVideo: true)
            return
        }
        if let decision = navigationDecision(for: url) {
            rejectedURL = url
            blockCurrentPage("This page is hidden by your browser protection (\(decision.matched)).")
            return
        }
        pendingURL = url
        isLoading = true
        // Install request blocking before this navigation starts.
        Task {
            await updateRequestRules()
            guard revision == loadRevision else { return }
            pendingURL = nil
            webView.load(URLRequest(url: url))
        }
    }

    private func blockCurrentPage(_ reason: String, shortVideo: Bool = false) {
        blockedForShortVideos = shortVideo
        blockedPage = reason
        isLoading = false
        webView.pauseAllMediaPlayback(completionHandler: nil)
    }

    private func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }

    private func invoke(_ body: String, arguments: [String: Any] = [:]) {
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .defaultClient, completionHandler: nil)
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard active, message.frameInfo.isMainFrame,
              let url = message.frameInfo.request.url, site.owns(url),
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        if kind == "whitespaceTap" {
            guard body["url"] as? String == webView.url?.absoluteString,
                  !site.isAuthenticationPage(webView.url ?? site.home), blockedPage == nil else { return }
            navigationHidden.toggle()
            return
        }
        if kind == "route" || kind == "ready" {
            applyPreferences()
            return
        }
        if kind == "pageState" {
            guard let rawURL = body["url"] as? String, rawURL == webView.url?.absoluteString else { return }
            showsIntentHome = body["emptyHome"] as? Bool ?? false
            return
        }
        guard kind == "scan", let document = body["document"] as? String, document.count < 100,
              let rows = body["items"] as? [[String: Any]], rows.count <= 80 else { return }
        if document != currentDocument {
            currentDocument = document
            reported.removeAll()
        }
        let protection = ProtectionModel.shared
        let keywords = library?.keywords(for: site, at: webView.url) ?? []
        if keywordSignature != keywords {
            keywordSignature = keywords
            compiledKeywords = ProtectionMatcher.compile(keywords)
        }
        // Apps' explicit keywords and the adult tier work immediately. Additional
        // shared/YouTube/channel rules follow the existing Protection switches.
        let globalRules = protection.rules()
        let localRules = ProtectionRules(alwaysBlock: globalRules.alwaysBlock, userKeywords: compiledKeywords)
        var replies: [[String: Any]] = []
        var activity: [(subject: ProtectionSubject, decision: BlockDecision)] = []
        for row in rows {
            guard let id = row["id"] as? String, id.count < 80,
                  let revision = row["revision"] as? Int else { continue }
            let text = String((row["text"] as? String ?? "").prefix(5000))
            let creator = String((row["creator"] as? String ?? "").prefix(200))
            let rawURL = String((row["url"] as? String ?? "").prefix(2048))
            let identity = rawURL.isEmpty ? String(text.prefix(160)) : rawURL
            let subject = ProtectionSubject(id: "apps:\(site.rawValue):\(identity)",
                title: text, channelName: creator, channelHandle: creator,
                url: rawURL, isYouTube: AppSite.youtube.owns(webView.url ?? site.home), isShort: row["short"] as? Bool ?? false)
            var decision = ProtectionMatcher.decision(forText: text + " " + creator, rules: localRules)
            if decision == nil { decision = ProtectionEnforcer.verdict(for: subject, rules: globalRules, options: protection.enforcementOptions) }
            let shortBlocked = subject.isShort && (webView.url.map { current in
                AppSite.youtube.owns(current) ? library?.blocksShortVideos(for: .youtube) == true
                    : (AppSite.instagram.owns(current) && library?.blocksShortVideos(for: .instagram) == true)
            } ?? false)
            let isBlocked = decision != nil || shortBlocked
            replies.append(["id": id, "revision": revision, "blocked": isBlocked])
            if isBlocked, reported.insert(subject.id).inserted {
                hiddenCount += 1
                if let decision { activity.append((subject, decision)) }
            }
        }
        if !activity.isEmpty { protection.noteHidden(activity) }
        invoke("window.__clearviewApps?.resolve(items, document)", arguments: ["items": replies, "document": document])
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        // Subframes include video/CDN resources and federated login widgets.
        if action.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        if let allResults = library?.allGoogleResultsURL(url) {
            decisionHandler(.cancel)
            load(allResults)
            return
        }
        if isBlockedShortURL(url) {
            decisionHandler(.cancel)
            rejectedURL = url
            blockCurrentPage("Short videos are hidden by your settings.", shortVideo: true)
            return
        }
        if let equivalent = site.webEquivalent(of: url) {
            decisionHandler(.cancel)
            load(equivalent)
            return
        }
        if site.owns(url) || site.allowsAuthentication(url) {
            if let decision = navigationDecision(for: url) {
                decisionHandler(.cancel)
                rejectedURL = url
                blockCurrentPage("This page is hidden by your browser protection (\(decision.matched)).")
                return
            }
            decisionHandler(.allow)
        } else if url.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            // A page's automatic redirect cannot send the person to another app.
            if action.navigationType == .linkActivated {
                if ["https", "http", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "") { externalURL = url }
                else { unsupportedLink = true }
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        navigationHidden = false
        showsIntentHome = false
        errorMessage = nil
        blockedPage = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        errorMessage = nil
        applyPreferences()
        if !active { webView.pauseAllMediaPlayback(completionHandler: nil) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        isLoading = false
        errorMessage = "\(site.name) couldn’t load. Check your connection and try again."
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        errorMessage = "\(site.name) needs to reload. Your saved login is still on this device."
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, site.owns(url) || site.allowsAuthentication(url) {
            webView.load(action.request)
        } else if action.navigationType == .linkActivated, let url = action.request.url, url.scheme == "https" {
            externalURL = url
        }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        var parts = URLComponents()
        parts.scheme = origin.protocol
        parts.host = origin.host
        guard active, let url = parts.url, site.owns(url) else { decisionHandler(.deny); return }
        decisionHandler(.prompt)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        finishDialog(nil)
        websiteDialog = WebsiteDialog(message: message, kind: .notice, defaultText: "", complete: { _ in completionHandler() })
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        finishDialog(nil)
        websiteDialog = WebsiteDialog(message: message, kind: .confirmation, defaultText: "", complete: { value in completionHandler(value != nil) })
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        finishDialog(nil)
        websiteDialog = WebsiteDialog(message: prompt, kind: .input, defaultText: defaultText ?? "", complete: completionHandler)
    }

    var websiteDialog: WebsiteDialog?
    func finishDialog(_ response: String?) {
        guard let dialog = websiteDialog else { return }
        websiteDialog = nil
        dialog.complete(response)
    }

    struct WebsiteDialog: Identifiable {
        enum Kind: Equatable { case notice, confirmation, input }
        let id = UUID()
        let message: String
        let kind: Kind
        let defaultText: String
        let complete: (String?) -> Void
    }
}

@MainActor
private final class AppsMessageBridge: NSObject, WKScriptMessageHandler {
    private weak var target: AppBrowserSession?
    init(_ target: AppBrowserSession) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message)
    }
}

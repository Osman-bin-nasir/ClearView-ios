import SwiftUI
import WebKit

struct AppBrowserView: View {
    @Bindable var session: AppBrowserSession
    let library: AppsLibrary
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @State private var showFilters = false
    @State private var showSignInHelp = false
    @State private var dialogEntry = ""
    @State private var showSearch = false

    var body: some View {
        browserWithAlerts
            .alert(session.site.name, isPresented: Binding(
                get: { session.websiteDialog != nil }, set: { _ in }
            ), presenting: session.websiteDialog) { dialog in
                if dialog.kind == .input { TextField("Response", text: $dialogEntry) }
                Button(dialog.kind == .notice ? "OK" : "Continue") { session.finishDialog(dialog.kind == .input ? dialogEntry : "true") }
                if dialog.kind != .notice { Button("Cancel", role: .cancel) { session.finishDialog(nil) } }
            } message: { dialog in Text(dialog.message) }
    }

    private var browserLayout: some View {
        VStack(spacing: 0) {
            if !session.navigationHidden { header }
            if let notice = session.protectionNotice {
                Text(notice).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant).padding(8)
            }
            ZStack(alignment: .leading) {
                Color.cvOutlineVariant.opacity(0.3)
                GeometryReader { geometry in
                    Rectangle().fill(Color.cvPrimary).frame(width: geometry.size.width * session.progress)
                }.opacity(session.isLoading ? 1 : 0)
            }.frame(height: 2).accessibilityHidden(true)
            ZStack {
                AppWebsiteView(session: session)
                    .accessibilityHidden(session.blockedPage != nil || session.errorMessage != nil || session.showsIntentHome)
                if let blocked = session.blockedPage {
                    browserState(symbol: "eye.slash", title: "A little less noise", message: blocked, action: "Back to home") { session.goHome() }
                } else if let error = session.errorMessage {
                    browserState(symbol: "wifi.exclamationmark", title: "Let’s try that again", message: error, action: "Reload") { session.reload() }
                } else if session.showsIntentHome {
                    intentHome
                } else if session.isLoading && session.progress < 0.15 && session.currentURL == nil {
                    VStack(spacing: 18) {
                        AppBrandMark(site: session.site, size: 64)
                        ProgressView().tint(.cvPrimary)
                        Text("Opening \(session.site.name)…").font(.footnote).foregroundStyle(Color.cvOnSurfaceVariant)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.cvBackground)
                }
            }
            if session.showsAppNavigation && !session.navigationHidden {
                if session.site.usesAppShell { navigationBar } else { browserToolbar }
            }
        }.overlay(alignment: .bottomTrailing) {
            if session.navigationHidden {
                Button { withAnimation(.easeInOut(duration: 0.18)) { session.navigationHidden = false } } label: {
                    Image(systemName: "chevron.up").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.cvPrimary).frame(width: 44, height: 34)
                        .background(Color.cvSurfaceContainerHigh, in: Capsule())
                }.padding(12).accessibilityLabel("Show navigation").accessibilityIdentifier("browser.show-navigation")
            }
        }
        .animation(.easeInOut(duration: 0.18), value: session.navigationHidden)
    }

    private var configuredBrowser: some View {
        browserLayout
        .background(Color.cvBackground).tint(.cvPrimary)
        .task { session.resume(dark: colorScheme == .dark) }
        .task(id: session.filterSignature) { session.applyPreferences() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session.resume(dark: colorScheme == .dark) } else { session.pause() }
        }
        .onChange(of: colorScheme) { _, scheme in session.resume(dark: scheme == .dark) }
        .onChange(of: session.websiteDialog?.id) { _, _ in dialogEntry = session.websiteDialog?.defaultText ?? "" }
        .onChange(of: DeviceControlsController.shared.expired) { _, expired in
            if expired { session.pause(); dismiss() }
        }
        .onDisappear { session.pause() }
        .sheet(isPresented: $showFilters, onDismiss: { session.applyPreferences() }) {
            BrowserProtectionSettingsView(library: library)
        }
        .sheet(isPresented: $showSearch) {
            AppSearchSheet(site: session.site) { session.search($0) }
        }
    }

    private var browserWithAlerts: some View {
        configuredBrowser
        .confirmationDialog("Open outside ClearView?", isPresented: Binding(
            get: { session.externalURL != nil }, set: { if !$0 { session.externalURL = nil } }
        ), titleVisibility: .visible, presenting: session.externalURL) { url in
            Button("Open \(url.host ?? "link")") { openURL(url); session.externalURL = nil }
            Button("Cancel", role: .cancel) { session.externalURL = nil }
        } message: { _ in Text("ClearView’s filters apply inside Apps. This link opens in another app.") }
        .alert("This link needs another app", isPresented: $session.unsupportedLink) {
            Button("OK", role: .cancel) { }
        } message: { Text("Stay here to use the website, or choose Open in Safari from the menu.") }
        .alert("Signing in", isPresented: $showSignInHelp) {
            Button("Keep browsing", role: .cancel) { }
            Button("Open in Safari") { if let url = session.currentURL { openURL(url) } }
        } message: {
            Text("Sign in using \(session.site.name)’s own page. Some providers, including Google, restrict embedded browser sign-in. If the provider refuses, you can browse publicly here or use Safari. Safari’s login session won’t transfer into ClearView.")
        }
    }

    private var header: some View {
        HStack(spacing: 2) {
            Button {
                if showsBackButton { session.goBack() } else { session.pause(); dismiss() }
            } label: {
                Image(systemName: showsBackButton ? "chevron.left" : "xmark")
                    .font(.system(size: 17, weight: .medium)).frame(width: 40, height: 44)
            }.accessibilityLabel(showsBackButton ? "Back" : "Back to Apps")
            appTitle.frame(maxWidth: .infinity, alignment: .leading)
            if session.showsAppNavigation {
                // Snapchat's site has no query-based search route; the native
                // Discover tab is its discovery surface instead.
                if session.site != .snapchat {
                    Button { showSearch = true } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 21)).frame(width: 40, height: 44)
                    }.accessibilityLabel(session.site.usesAppShell ? "Search \(session.site.name)" : "Search the web")
                }
                if session.site == .instagram {
                    Button { session.openInbox() } label: {
                        Image(systemName: "paperplane").font(.system(size: 20)).frame(width: 40, height: 44)
                    }.accessibilityLabel("Messages")
                }
            }
            Button { showFilters = true } label: {
                Image(systemName: session.blocksShortVideos ? "shield.lefthalf.filled" : "checkmark.shield")
                    .font(.system(size: 21)).foregroundStyle(Color.cvPrimary).frame(width: 40, height: 44)
            }.accessibilityLabel("Filters, \(session.hiddenCount) items hidden this session").accessibilityIdentifier("apps.filters")
            Menu {
                if session.canGoBack { Button("Back", systemImage: "chevron.left") { session.goBack() } }
                Button("Reload", systemImage: "arrow.clockwise") { session.reload() }
                Button("Protection settings", systemImage: "slider.horizontal.3") { showFilters = true }
                Button("Back to Apps", systemImage: "square.grid.2x2") { session.pause(); dismiss() }
                Button("Sign-in help", systemImage: "person.crop.circle.badge.questionmark") { showSignInHelp = true }
                if let url = session.currentURL {
                    if session.site.owns(url) {
                        ShareLink(item: url) { Label("Share page", systemImage: "square.and.arrow.up") }
                    }
                    Button("Open in Safari", systemImage: "safari") { session.pause(); openURL(url) }
                }
            } label: { Image(systemName: "ellipsis").font(.system(size: 19, weight: .semibold)).frame(width: 36, height: 44) }
                .accessibilityLabel("App menu")
        }.padding(.horizontal, 6).padding(.vertical, 2).foregroundStyle(Color.cvOnSurface)
    }

    private var showsBackButton: Bool {
        guard session.canGoBack else { return false }
        // YouTube and Instagram use their native tabs for top-level movement. The
        // branded web apps keep ordinary page history, so Back stays available
        // wherever they have somewhere to go back to.
        if session.site.usesBrandedHeader { return true }
        let path = session.currentURL?.path ?? "/"
        return !session.showsAppNavigation || path == "/watch" || path == "/results" || path.hasPrefix("/p/")
    }

    private var intentHome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 20)
            Image(systemName: "play.rectangle").font(.system(size: 37)).foregroundStyle(Color.cvPrimary)
                .frame(width: 76, height: 76).background(Color.cvPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 24))
            Text("What’s worth\nyour time today?").font(.system(size: 31, weight: .bold, design: .rounded)).tracking(-0.7)
                .fixedSize(horizontal: false, vertical: true)
            Text("Pick something you want to watch. A little intention goes a long way.")
                .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant).lineSpacing(3)
            Button { showSearch = true } label: {
                Label("Search YouTube", systemImage: "magnifyingglass").font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(Color.cvPrimary, in: Capsule()).foregroundStyle(Color.cvOnPrimary)
            }.buttonStyle(.plain)
            Button { session.navigate(.subscriptions) } label: {
                Label("Go to subscriptions", systemImage: "play.rectangle.on.rectangle")
                    .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(Color.cvSurfaceContainerLow, in: Capsule()).foregroundStyle(Color.cvOnSurface)
            }.buttonStyle(.plain)
            Spacer(minLength: 30)
            Label(session.blocksShortVideos ? "Shorts are hidden" : "Your filters are active", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant).frame(maxWidth: .infinity)
        }.padding(.horizontal, 28).padding(.vertical, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.cvBackground)
    }

    private var appTitle: some View {
        HStack(spacing: 7) {
            if session.showsAppNavigation {
                switch session.site {
                case .youtube:
                    Image(systemName: "play.rectangle.fill").font(.system(size: 25)).foregroundStyle(.red)
                case .snapchat, .facebook:
                    AppBrandMark(site: session.site, size: 25)
                case .google, .instagram, .web:
                    EmptyView()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.showsAppNavigation ? (session.site.usesAppShell ? session.site.name : "ClearView") : "Sign in")
                    .font(.system(size: 21, weight: .bold, design: .rounded)).tracking(-0.7)
                    .accessibilityIdentifier("browser.title")
                // A branded app never shows its website address. Google and custom
                // websites keep the host so the person knows where they are.
                if !session.site.usesBrandedHeader && (!session.showsAppNavigation || !session.site.usesAppShell) {
                    Text(session.currentURL?.host ?? "Search the web").font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                        .accessibilityIdentifier("browser.host")
                }
            }
        }
    }

    private var browserToolbar: some View {
        HStack {
            Button { session.goBack() } label: { Image(systemName: "chevron.left").frame(maxWidth: .infinity, minHeight: 48) }
                .disabled(!session.canGoBack).accessibilityLabel("Back")
            Button { session.goForward() } label: { Image(systemName: "chevron.right").frame(maxWidth: .infinity, minHeight: 48) }
                .disabled(!session.canGoForward).accessibilityLabel("Forward")
            Button { session.goHome() } label: { Image(systemName: "house").frame(maxWidth: .infinity, minHeight: 48) }.accessibilityLabel("Google home")
            Button { showSearch = true } label: { Image(systemName: "magnifyingglass").frame(maxWidth: .infinity, minHeight: 48) }.accessibilityLabel("Search the web")
            Button { session.reload() } label: { Image(systemName: "arrow.clockwise").frame(maxWidth: .infinity, minHeight: 48) }.accessibilityLabel("Reload page")
        }.font(.system(size: 20)).buttonStyle(.plain).foregroundStyle(Color.cvOnSurface)
            .background(Color.cvSurfaceContainerLow)
            .overlay(alignment: .top) { Color.cvOutlineVariant.opacity(0.3).frame(height: 0.5) }
    }

    private var visibleDestinations: [AppDestination] {
        session.site.destinations.filter { $0 != .shortVideos || !session.blocksShortVideos }
    }

    private var navigationBar: some View {
        HStack(spacing: 0) {
            ForEach(visibleDestinations) { destination in
                let selected = session.selectedDestination == destination
                Button { session.navigate(destination) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: destination.symbol(selected: selected)).font(.system(size: 21))
                        Text(destination.title(for: session.site)).font(.system(size: 10, weight: selected ? .semibold : .regular))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }.frame(maxWidth: .infinity, minHeight: 52).contentShape(Rectangle())
                        .foregroundStyle(selected ? Color.cvPrimary : Color.cvOnSurfaceVariant)
                }.buttonStyle(.plain).accessibilityLabel(destination.title(for: session.site))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("apps.navigation.\(destination.rawValue)")
            }
        }.padding(.top, 4).background(Color.cvSurfaceContainerLow)
            .overlay(alignment: .top) { Color.cvOutlineVariant.opacity(0.3).frame(height: 0.5) }
    }

    private func browserState(symbol: String, title: String, message: String, action: String, perform: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(Color.cvPrimary)
                .frame(width: 82, height: 82).background(Color.cvPrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 25))
            Text(title).font(.title2.weight(.bold))
            Text(message).font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant).multilineTextAlignment(.center)
            Button(action, action: perform).buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                .tint(.cvPrimary).foregroundStyle(Color.cvOnPrimary).padding(.top, 4)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.cvBackground)
    }
}

private struct AppSearchSheet: View {
    let site: AppSite
    let search: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.cvPrimary)
                    TextField(site.usesAppShell ? "What do you want to find?" : "Search or enter website address", text: $query)
                        .focused($focused).submitLabel(.search).onSubmit(submit)
                        .accessibilityIdentifier("apps.search.query")
                }.padding(16).background(Color.cvSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 16))
                Text(site.usesAppShell ? "Find something worth your time." : "ClearView protection applies to your searches and websites.").font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                Button("Search", action: submit).buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer(minLength: 0)
            }.padding(20).background(Color.cvBackground)
                .navigationTitle(site.usesAppShell ? "Search \(site.name)" : "Search the web").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
                .task { focused = true }
        }.tint(.cvPrimary).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private func submit() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        search(value)
        dismiss()
    }
}

private struct AppWebsiteView: UIViewRepresentable {
    let session: AppBrowserSession
    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) {
        uiView.pauseAllMediaPlayback(completionHandler: nil)
    }
}

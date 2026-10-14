import SwiftUI

/// The Protection tab — the iOS face of Android's Block tab (`ui/BlockTab.kt`).
///
/// Card for card, in the same order, with the same words wherever the platform allows:
/// the hero switch, **YouTube Protection**, **My blocked items**, the **shared
/// blocklist**, **Protection activity**, then the setup-once settings under
/// **Advanced** and the privacy line. Someone moving between the two apps should not
/// have to relearn the page.
///
/// **Where the platforms genuinely differ, this screen says so instead of pretending.**
/// Android's blocking is an Accessibility Service that reads Chrome and the Google app.
/// iOS gives an app no way to read another app's screen, so that mechanism has no
/// equivalent — inventing a switch that looks identical and does nothing would be the
/// worst of the options. What iOS *can* do is enforced for real here: ClearView hides
/// what its own feeds and player show you, and the Activity dashboard counts it. The
/// capabilities card states the boundary in one place, in the app, which the migration
/// plan asks for as a deliverable in its own right.
struct ProtectionView: View {

    let model: ProtectionModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var sheet: ProtectionSheet?
    @State private var showCapabilities = false
    @State private var showsNewPassword = false
    @State private var passwordEntry = ""
    @State private var confirmation = ""
    @State private var gateError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.isLocked {
                    ProtectionLockView(
                        model: model,
                        entry: $passwordEntry,
                        confirmation: $confirmation,
                        error: $gateError
                    )
                } else {
                    content
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color.cvBackground)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Protection")
        .navigationBarTitleDisplayMode(.inline)
        // The tab locks when the app leaves the screen, exactly as Android's does: the
        // password protects the dashboard from whoever picks the phone up next, which
        // only means anything if it re-locks.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.lock() }
        }
        .sheet(item: $sheet) { destination in
            ProtectionSheetView(sheet: destination, model: model)
        }
        .sheet(isPresented: Binding(get: { showsNewPassword }, set: { showsNewPassword = $0 })) {
            ProtectionSetPasswordSheet(model: model) { showsNewPassword = false }
        }
    }

    // MARK: - The page

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProtectionHeader(model: model) { sheet = .notifications }

            ProtectionHeroCard(model: model, showCapabilities: $showCapabilities)

            ProtectionSectionHeading("YOUTUBE PROTECTION")
            if !model.protectionEnabled { ProtectionLockedHint() }
            ProtectionFeatureCard(
                symbol: "brain.head.profile",
                title: "Brain Rot Protection",
                summary: "Block unwanted content with keywords, channels and the shared blocklist.",
                isOn: Binding(get: { model.youTubeProtection }, set: { model.youTubeProtection = $0 }),
                locked: !model.protectionEnabled,
                identifier: "protection.youtube-switch",
                details: [
                    "Hides YouTube content in ClearView that matches your keywords or your blocked channels.",
                    "The video's real title and description are both checked — not just the row on screen.",
                    "Short-form videos are covered too, using the same rules.",
                    "Allowed videos are untouched: no badge, no banner, no change to how they play.",
                ]
            )
            ProtectionFeatureCard(
                symbol: "play.rectangle",
                title: "Block Shorts",
                summary: "Hides YouTube Shorts in ClearView without blocking the word \"shorts\".",
                isOn: Binding(get: { model.blockShorts }, set: { model.blockShorts = $0 }),
                locked: !model.protectionEnabled,
                identifier: "protection.shorts-switch",
                details: [
                    "A blocked Short is hidden from the Shorts shelf — no need to add \"shorts\" as a keyword, which would also block words like \"shortstop\".",
                    "It does not touch long videos or your other feeds.",
                    "Works together with the always-on adult filter and your own keywords.",
                ]
            )
            ProtectionManagerCard(
                symbol: "flask",
                title: "Blocked keywords",
                subtitle: model.youTubeKeywords.isEmpty
                    ? "No keywords yet — tap to add"
                    : "\(model.youTubeKeywords.count) keyword\(model.youTubeKeywords.count == 1 ? "" : "s")",
                identifier: "protection.keywords-card"
            ) { sheet = .keywords }

            ProtectionManagerCard(
                symbol: "nosign",
                title: "Blocked channels",
                subtitle: model.blockedChannels.isEmpty
                    ? "No channels yet — tap to add"
                    : "\(model.blockedChannels.count) channel\(model.blockedChannels.count == 1 ? "" : "s")",
                identifier: "protection.channels-card"
            ) { sheet = .channels }

            ProtectionSectionHeading("MY BLOCKED ITEMS")
            if !model.protectionEnabled { ProtectionLockedHint() }
            ProtectionFeatureCard(
                symbol: "exclamationmark.triangle",
                title: "Strict Mode",
                summary: "Also blocks discovery words like bikini, lingerie or cleavage.",
                isOn: Binding(get: { model.strictMode }, set: { model.strictMode = $0 }),
                locked: !model.protectionEnabled,
                identifier: "protection.strict-mode-switch",
                details: [
                    "Adds a curated list of risky-but-innocent discovery terms (bikini, lingerie, cleavage, beach, hot, ...) on top of the always-on adult filter.",
                    "Gender and family words — women, girl, mom, wife — are never blocked alone; they only block combined with a risky term.",
                    "With Strict Mode off, only the always-on adult terms apply; the discovery terms are ignored.",
                ]
            )
            ProtectionBlockedItemsCard(model: model) { sheet = .blockedItems }

            ProtectionSectionHeading("SHARED BLOCKLIST")
            ProtectionManagerCard(
                symbol: "globe",
                title: "Shared blocklist",
                subtitle: model.sharedListAvailable
                    ? model.sharedSummary
                    : "This build has no server configured, so the shared blocklist is unavailable. Your own rules still apply.",
                identifier: "protection.shared-card"
            ) { sheet = .shared }
            ProtectionManagerCard(
                symbol: "arrow.up.circle",
                title: "My requests",
                subtitle: "\(model.submissions.count) submitted",
                identifier: "protection.requests-card"
            ) { sheet = .requests }

            ProtectionSectionHeading("RECENT ACTIVITY")
            ProtectionManagerCard(
                symbol: "chart.line.uptrend.xyaxis",
                title: "Protection activity",
                subtitle: activityLine,
                identifier: "protection.activity-card"
            ) { sheet = .activity }

            ProtectionSectionHeading("ADVANCED")
            ProtectionPasswordCard(model: model) { showsNewPassword = true }
            ProtectionWebFilterCard()
            ProtectionLimitsCard()

            ProtectionPrivacyCard()

            Spacer(minLength: 8)
        }
    }

    /// The activity card's one line: what happened **today**, then the arrow.
    private var activityLine: String {
        let summary = model.activitySummary
        if summary.totalBlocks == 0 { return "Nothing blocked yet" }
        if summary.todayBlocks == 1 { return "1 blocked today" }
        if summary.todayBlocks > 1 { return "\(summary.todayBlocks) blocked today" }
        return "\(summary.totalBlocks) blocked in total"
    }
}

/// Which manager screen is open. One optional state, so two sheets can never race.
enum ProtectionSheet: String, Identifiable {
    case keywords
    case channels
    case blockedItems
    case shared
    case requests
    case activity
    case notifications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keywords: return "Blocked keywords"
        case .channels: return "Blocked channels"
        case .blockedItems: return "Blocked items"
        case .shared: return "Shared blocklist"
        case .requests: return "My requests"
        case .activity: return "Protection activity"
        case .notifications: return "Notifications"
        }
    }
}

/// The screens the cards open — each a full page with room to breathe, as on Android,
/// rather than everything crammed under its one-line card.
private struct ProtectionSheetView: View {
    let sheet: ProtectionSheet
    let model: ProtectionModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch sheet {
                    case .keywords: ProtectionKeywordsSheet(model: model)
                    case .channels: ProtectionChannelsSheet(model: model)
                    case .blockedItems: ProtectionBlockedItemsSheet(model: model)
                    case .shared: ProtectionSharedListSheet(model: model)
                    case .requests: ProtectionRequestsSheet(model: model)
                    case .activity: ProtectionActivitySheet(model: model)
                    case .notifications: ProtectionNotificationsSheet(model: model)
                    }
                }
                .padding(16)
            }
            .background(Color.cvBackground)
            .navigationTitle(sheet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
}

// ── The page's opening line, and the notification bell ────────────────

struct ProtectionHeader: View {
    let model: ProtectionModel
    var openNotifications: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("Protect your browsing from unwanted and distracting content.")
                    .font(.subheadline)
                    .foregroundStyle(Color.cvOnSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: openNotifications) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "bell")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.cvOnSurfaceVariant)
                            .padding(6)
                        if model.unreadNotificationCount > 0 {
                            Text(model.unreadNotificationCount > 9 ? "9+" : "\(model.unreadNotificationCount)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.cvOnPrimary)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Color.cvPrimary, in: Capsule())
                        }
                    }
                }
                .accessibilityLabel("Notifications")
                .accessibilityIdentifier("protection.notifications")
            }
            // What is protected, and where. Stated once, up front, so the page explains
            // itself before a reader meets a single switch.
            Text("Protection applies to the content ClearView shows you — its feeds and its player. iOS does not let one app read another app's screen, so Chrome and the Google app cannot be filtered here.")
                .font(.caption)
                .foregroundStyle(Color.cvOnSurfaceVariant)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }
}

// ── The hero: one switch, one status line, the (i) for the whole story ─

struct ProtectionHeroCard: View {
    let model: ProtectionModel
    @Binding var showCapabilities: Bool

    var body: some View {
        let active = model.protectionEnabled
        let green = Color(red: 0.18, green: 0.49, blue: 0.20)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "shield.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(active ? Color.white : Color.cvOnSurfaceVariant)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Protection")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(active ? Color.white : Color.cvOnSurface)
                    Text(active ? "Active — filtering inside ClearView" : "Off — turn on to filter")
                        .font(.caption)
                        .foregroundStyle(active ? Color(red: 0.91, green: 0.96, blue: 0.91) : Color.cvOnSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: Binding(
                    get: { model.protectionEnabled },
                    set: { model.protectionEnabled = $0 }
                ))
                .labelsHidden()
                .tint(active ? Color(red: 0.11, green: 0.37, blue: 0.13) : nil)
                .accessibilityIdentifier("protection.protection-switch")
                Button { showCapabilities.toggle() } label: {
                    Image(systemName: showCapabilities ? "info.circle.fill" : "info.circle")
                        .foregroundStyle(active ? Color.white : Color.cvOnSurfaceVariant)
                }
                .accessibilityLabel(showCapabilities ? "Hide details" : "Show full context")
            }

            if showCapabilities {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(ProtectionCapabilities.bullets, id: \.self) { bullet in
                        Text("• " + bullet)
                            .font(.caption)
                            .foregroundStyle(active ? Color.white.opacity(0.92) : Color.cvOnSurfaceVariant)
                    }
                }
                .padding(.top, 12)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (active ? Color.black.opacity(0.18) : Color.cvBackground.opacity(0.5)),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(active ? green : Color.cvSurfaceVariant, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// What the hero switch actually covers, in the app, in the same voice as Android's
/// expander — with the platform's limits stated rather than glossed.
enum ProtectionCapabilities {
    static let bullets: [String] = [
        "Always-on adult filter — explicit terms and known adult websites are hidden from everything ClearView shows you.",
        "Pattern blocking — innocent words like women, girl, hot or beach only match when combined with an adult term (\"women bikini\"), so everyday browsing is never blocked.",
        "YouTube Protection — your keywords and blocked channels apply to the videos and Shorts ClearView lists and plays.",
        "Custom keywords & websites — everything under My blocked items is enforced here, and the same rules are ready for the Safari blocker.",
        "100% on-device — nothing is read from another app, and nothing you block is sent anywhere.",
        "Not on iOS: reading Chrome or the Google app, closing Incognito, and locking other apps. The Advanced section explains each.",
    ]
}

// ── Shared: section headings, cards, list rows ─────────────────────────

struct ProtectionSectionHeading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.cvPrimary)
                .frame(width: 3, height: 14)
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(Color.cvOnSurface)
        }
        .padding(.top, 10)
        .padding(.leading, 2)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Shown once above a locked group: the features below are enforced by protection, so
/// while it is off their switches are disabled, and one shared line says why.
struct ProtectionLockedHint: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13))
            Text("Protection is off — the switches below unlock once it is on.")
                .font(.caption)
        }
        .foregroundStyle(Color.cvOnSurfaceVariant)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cvSurfaceVariant.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The header every feature card shares: a tinted badge, a title, one summary line, the
/// switch and the (i) that carries the full context. One shape across the tab is what
/// keeps the page from reading as a pile of differently-built boxes.
struct ProtectionFeatureCard: View {
    let symbol: String
    let title: String
    let summary: String
    @Binding var isOn: Bool
    var locked: Bool
    var identifier: String
    let details: [String]
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(isOn ? Color.cvError : Color.cvOnSurfaceVariant)
                    .frame(width: 36, height: 36)
                    .background(Color.cvPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(summary).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .disabled(locked)
                    .accessibilityIdentifier(identifier)
                    .accessibilityLabel(title)
                Button { showDetails.toggle() } label: {
                    Image(systemName: showDetails ? "info.circle.fill" : "info.circle")
                        .foregroundStyle(Color.cvOnSurfaceVariant)
                }
                .accessibilityLabel(showDetails ? "Hide details" : "Show full context")
            }
            if showDetails {
                ProtectionDetailBlock(bullets: details)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isOn ? Color.cvErrorContainer.opacity(0.7) : Color.cvSurfaceVariant,
            in: RoundedRectangle(cornerRadius: 16)
        )
    }
}

struct ProtectionDetailBlock: View {
    let bullets: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(bullets, id: \.self) { bullet in
                Text("• " + bullet)
                    .font(.caption)
                    .foregroundStyle(Color.cvOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cvBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .padding(.top, 12)
    }
}

/// A compact card that says "this opens a screen": an exact count, and an arrow.
struct ProtectionManagerCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    var identifier: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.cvPrimary)
                    .frame(width: 36, height: 36)
                    .background(Color.cvPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.cvOnSurfaceVariant)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cvSurfaceVariant, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

/// "My blocked items" — keywords and websites in one card, drawn with the dashed border
/// Android uses to say "this one you edit".
struct ProtectionBlockedItemsCard: View {
    let model: ProtectionModel
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.cvPrimary)
                        .frame(width: 36, height: 36)
                        .background(Color.cvPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Blocked items").font(.subheadline.weight(.semibold))
                        Text("Your own keywords and websites.")
                            .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.cvOnSurfaceVariant)
                }
                Text("\(model.userKeywords.count) keyword\(model.userKeywords.count == 1 ? "" : "s") · \(model.blockedDomains.count) website\(model.blockedDomains.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Color.cvOnSurfaceVariant)
                Text("These apply to everything ClearView shows you, and to the Safari blocker once it is added.")
                    .font(.caption2)
                    .foregroundStyle(Color.cvOnSurfaceVariant)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cvSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.cvOutlineVariant, style: StrokeStyle(lineWidth: 2, dash: [10, 10]))
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("protection.blocked-items-card")
    }
}

// ── Advanced: the password, iOS web filtering, and the honest limits ───

struct ProtectionPasswordCard: View {
    let model: ProtectionModel
    var setPassword: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.hasPassword ? "lock.fill" : "lock.open")
                .font(.system(size: 18))
                .foregroundStyle(model.hasPassword ? Color.cvPrimary : Color.cvOnSurfaceVariant)
                .frame(width: 36, height: 36)
                .background(Color.cvPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text("Block tab password").font(.subheadline.weight(.medium))
                Text(model.hasPassword
                     ? "Password set — the tab locks when ClearView goes to the background"
                     : "No password — the tab is open to anyone")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if model.hasPassword {
                Button("Remove") { model.removePassword() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.cvError)
                    .accessibilityIdentifier("protection.remove-password")
            } else {
                Button("Set", action: setPassword)
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("protection.set-password")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cvSurfaceVariant, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("protection.password-card")
    }
}

/// iOS's own network-level filter, which is the honest equivalent of Android's DNS card.
///
/// Android sets a Private DNS hostname through Device Owner policy, so it can also lock
/// the setting. iOS has no such API: web filtering lives in Screen Time, the person
/// chooses it in Settings, and no third-party app may switch it on. So this card does the
/// one thing an app can honestly do — names the feature, says who controls it, and opens
/// the right Settings screen.
struct ProtectionWebFilterCard: View {
    @Environment(\.openURL) private var openURL
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "network")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.cvPrimary)
                    .frame(width: 36, height: 36)
                    .background(Color.cvPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Web filtering (Screen Time)").font(.subheadline.weight(.medium))
                    Text("Network-level adult filtering is iOS's own setting, not ClearView's.")
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { showDetails.toggle() } label: {
                    Image(systemName: showDetails ? "info.circle.fill" : "info.circle")
                        .foregroundStyle(Color.cvOnSurfaceVariant)
                }
                .accessibilityLabel(showDetails ? "Hide details" : "Show full context")
            }
            if showDetails {
                ProtectionDetailBlock(bullets: [
                    "Android enforces DNS filtering itself through Device Owner policy. iOS reserves that control: only the person, in Settings, can turn web filtering on.",
                    "Settings → Screen Time → Content & Privacy Restrictions → Web Content → Limit Adult Websites filters Safari and apps that use the system browser.",
                    "Open that screen from here with the button below, then come back — ClearView does not need to be told it is on.",
                    "It works alongside everything in this tab, and it keeps working when ClearView is closed.",
                ])
            }
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: {
                Text("Open Settings")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cvOutline, lineWidth: 1))
            }
            .padding(.top, 12)
            .accessibilityIdentifier("protection.open-settings")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cvSurfaceVariant, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// What the Android app does that iOS cannot, named one by one.
///
/// A deliverable rather than an apology: a person who has used the Android app will look
/// for these, and "it is not here" is only trustworthy when it is said out loud and with
/// the reason.
struct ProtectionLimitsCard: View {
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.cvOnSurfaceVariant)
                    .frame(width: 36, height: 36)
                    .background(Color.cvPrimary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("What iOS does not allow").font(.subheadline.weight(.medium))
                    Text("Why this tab's reach stops at ClearView.")
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { showDetails.toggle() } label: {
                    Image(systemName: showDetails ? "info.circle.fill" : "info.circle")
                        .foregroundStyle(Color.cvOnSurfaceVariant)
                }
                .accessibilityLabel(showDetails ? "Hide details" : "Show full context")
            }
            if showDetails {
                ProtectionDetailBlock(bullets: ProtectionLimits.bullets)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cvSurfaceVariant.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
    }
}

enum ProtectionLimits {
    static let bullets: [String] = [
        "Reading Chrome or the Google app: Android does this with an Accessibility Service. iOS apps cannot read another app's screen at all.",
        "Closing Incognito automatically: that needs the same screen access, so it has no iOS equivalent.",
        "Closing other apps or locking them: iOS apps cannot close or lock another app.",
        "Uninstall protection and device administration: iOS apps cannot make themselves undeletable. Screen Time's App Limits are the nearest thing, and the person controls them.",
        "Blocking a site in Safari needs the Safari content-blocker extension. The rules it would compile are already here; the extension itself is a separate target that still has to be built and signed.",
    ]
}

struct ProtectionPrivacyCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock")
                .font(.system(size: 15))
                .foregroundStyle(Color.cvOnSurfaceVariant)
            VStack(alignment: .leading, spacing: 3) {
                Text("PRIVACY")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.cvOnSurfaceVariant)
                Text("Nothing here is linked to who you are. No account or sign-up is needed.")
                    .font(.caption)
                    .foregroundStyle(Color.cvOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cvSurfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

// ── The password gate ────────────────────────────────────────────────

/// What the tab shows while it is locked, and the two things it can do: set a password
/// when there is none, or ask for the one that exists.
///
/// The two states share one screen because they are the same decision seen from either
/// side, and a person who has just been asked for a password should not also be able to
/// read the lists behind it.
struct ProtectionLockView: View {
    let model: ProtectionModel
    @Binding var entry: String
    @Binding var confirmation: String
    @Binding var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.cvPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.hasPassword ? "Block tab locked" : "Set a block password")
                        .font(.headline)
                    Text(model.hasPassword
                         ? "Enter your password to open the Block settings."
                         : "Protect the Block tab so nobody else can change what you block.")
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.hasPassword {
                SecureField("Password", text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("protection.password-field")
                Button("Unlock") {
                    if model.unlock(with: entry) {
                        entry = ""
                        error = nil
                    } else {
                        error = "Incorrect password"
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.cvPrimary, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(Color.cvOnPrimary)
                .accessibilityIdentifier("protection.unlock")
            } else {
                SecureField("New password", text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("protection.new-password")
                SecureField("Confirm password", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("protection.confirm-password")
                Button("Set password") {
                    error = model.setPassword(entry, confirmation: confirmation)
                    if error == nil {
                        entry = ""
                        confirmation = ""
                    }
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.cvPrimary, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(Color.cvOnPrimary)
                .accessibilityIdentifier("protection.set-password-confirm")
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.cvError)
                    .accessibilityIdentifier("protection.password-error")
            }

            Text("The password protects this tab's settings. It is stored on this device only, and cannot be recovered if it is forgotten.")
                .font(.caption)
                .foregroundStyle(Color.cvOnSurfaceVariant)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cvSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 20))
    }
}

/// Changing the password from the Advanced card: the same two fields, with the current
/// password asked for first, so a person who finds an unlocked phone cannot swap the lock.
struct ProtectionSetPasswordSheet: View {
    let model: ProtectionModel
    var done: () -> Void

    @State private var current = ""
    @State private var fresh = ""
    @State private var confirmation = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.hasPassword {
                        SecureField("Current password", text: $current)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("protection.current-password")
                    }
                    SecureField("New password", text: $fresh)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("protection.change-new-password")
                    SecureField("Confirm password", text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("protection.change-confirm-password")
                    if let error {
                        Text(error).font(.caption).foregroundStyle(Color.cvError)
                    }
                    Button("Save password") {
                        if model.hasPassword, !model.store.verifyPassword(current) {
                            error = "Incorrect password"
                            return
                        }
                        error = model.setPassword(fresh, confirmation: confirmation)
                        if error == nil { done() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.cvPrimary, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(Color.cvOnPrimary)
                    .accessibilityIdentifier("protection.save-password")
                    Text("Stored on this device only. There is no recovery — clearing the app's data removes it.")
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }
                .padding(16)
            }
            .background(Color.cvBackground)
            .navigationTitle("Block tab password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done() } }
            }
        }
    }
}

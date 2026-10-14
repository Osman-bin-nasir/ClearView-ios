import Foundation
import Observation

/// The Protection tab's state and its actions.
///
/// One `@Observable` model rather than a handful of stores read straight from the views,
/// because the tab is a set of screens whose parts have to agree: the hero switch, the
/// per-feature switches, the three list managers, the Activity dashboard and the shared
/// blocklist all describe the same rule set, and a screen that held its own copy would
/// show a list one edit behind.
///
/// It is `@MainActor` because every surface it drives is: the tab, the media feed's
/// filter and the app's own notification list. The network calls hop off the main actor
/// inside the client, so nothing here blocks a frame.
///
/// ## Every property here must stay observable
///
/// `@Observable` instruments a plain `var` and **not** a `private(set) var`. An
/// uninstrumented property is one SwiftUI never hears about: the tap runs, the value
/// lands on disk, and the screen keeps showing the old value. That is not a theory — this
/// model was written with `private(set) var store` and `private(set) var isUnlocked`, and
/// the tab looked frozen: the hero switch never moved, the keyword list never grew, and
/// the gate never opened after the password was accepted, while the store was correct the
/// whole time.
///
/// So the setters stay open and every write goes through `mutateStore`, which assigns the
/// whole settings value rather than mutating a field in place. `ProtectionModelTests`
/// pins both halves of that: that a change notifies observation, and that the value is
/// the one that was asked for.
@MainActor
@Observable
final class ProtectionModel {

    /// The persisted settings.
    ///
    /// Plain `var` on purpose — see the type's own note. Reads are what the screens do;
    /// writes go through `mutateStore` or one of the methods below, so nothing outside
    /// this type needs to assign it.
    var store: ProtectionStore

    private let client: GlobalBlocklistClient
    private let anonymousId: AnonymousIdStore

    /// Whether the Block tab is unlocked for this session.
    ///
    /// In memory and nowhere else: a lock whose state is written to disk is a lock that a
    /// relaunch opens. The Android tab behaves the same way — it locks when the app goes
    /// to the background rather than on a timer, so it can be set up and used in one
    /// sitting without re-entering the password.
    ///
    /// It starts **locked even with no password set**, which is Android's own gate: the
    /// Block tab is set up behind its password (`isSetupMode = !hasPassword` in
    /// `MainActivity`), so the first visit asks for one instead of showing a dashboard
    /// that nothing protects. A block list is exactly the thing somebody else should not
    /// be able to switch off on an unlocked phone.
    var isUnlocked = false

    var isSyncing = false
    var isLoadingSubmissions = false
    /// Set after a failed suggestion, so the screen can say nothing changed rather than
    /// implying a request went through.
    var lastSuggestionFailed = false

    init(
        store: ProtectionStore = ProtectionStore(),
        client: GlobalBlocklistClient = GlobalBlocklistClient(),
        anonymousId: AnonymousIdStore = AnonymousIdStore()
    ) {
        self.store = store
        self.client = client
        self.anonymousId = anonymousId
    }

    /// The app's one model.
    ///
    /// One instance, shared by the Protection tab and by the media surfaces whose rules it
    /// holds: a block added in the tab has to be in force for the next feed that draws,
    /// and two models over one store would let a screen keep showing content the other
    /// screen had just blocked. Views observe the model, so an edit redraws the surfaces
    /// that care.
    static let shared = ProtectionModel()

    /// Whether the tab is showing its gate rather than the dashboard.
    var isLocked: Bool { !isUnlocked }

    /// True while the gate is asking for a *new* password rather than for the existing one.
    var isSettingUpPassword: Bool { !store.hasPassword }

    // MARK: - The rule set

    /// The compiled rules every matching surface uses.
    ///
    /// Compiled once per rule change and handed back unchanged in between. Compiling is
    /// normalising ~800 preset keywords, and the matching surfaces run in a view body — a
    /// feed of fifty rows would otherwise pay that cost fifty times per frame. The
    /// signature is what makes "once per change" true rather than "once per launch": an
    /// edit is visible to the next match, not to the next launch.
    func rules() -> ProtectionRules {
        let signature = ruleSignature
        if let cachedRules, cachedSignature == signature { return cachedRules }
        let built = store.rules()
        cachedRules = built
        cachedSignature = signature
        return built
    }

    // Deliberately invisible to observation: `rules()` is called while a view is being
    // built, and a cache that published would be a state change during a render.
    @ObservationIgnored private var cachedRules: ProtectionRules?
    @ObservationIgnored private var cachedSignature = ""

    /// Everything a compiled rule set depends on, as a cheap comparable value.
    private var ruleSignature: String {
        let rules = store.globalRules
        return [
            store.strictMode ? "S" : "-",
            store.userKeywords.joined(separator: ","),
            store.youTubeKeywords.joined(separator: ","),
            store.blockedDomains.joined(separator: ","),
            store.blockedChannels.map(\.handle).joined(separator: ","),
            rules.version,
            String(rules.keywords.count),
            String(rules.channels.count),
        ].joined(separator: "|")
    }

    var activeRuleCount: Int {
        let rules = rules()
        return rules.alwaysBlock.count + rules.userKeywords.count + rules.youTubeKeywords.count
            + rules.domains.count + rules.channels.count
    }

    // MARK: - Enforcement

    /// The switches, as the enforcer reads them.
    var enforcementOptions: ProtectionEnforcementOptions { .current(store) }

    /// Subject ids already written to the activity log this session.
    ///
    /// A view recomputes its list whenever it redraws, so without this a single blocked
    /// video would be counted once per frame. In memory and nowhere else: the log is a
    /// record of what happened, not of what is on screen, and a relaunch starting the
    /// count afresh is the honest reading of a filter that runs as you browse.
    @ObservationIgnored private var reportedSubjects: Set<String> = []

    /// Split a list into what stays and what is blocked.
    func enforcement(for subjects: [ProtectionSubject]) -> ProtectionEnforcement {
        ProtectionEnforcer.partition(subjects, rules: rules(), options: enforcementOptions)
    }

    /// Record the blocks a rendered list produced, once per subject.
    ///
    /// Called from a task rather than from a view body: this writes to the store, and a
    /// write during rendering is how a view becomes a state machine nobody can reason
    /// about.
    func noteHidden(_ hidden: [(subject: ProtectionSubject, decision: BlockDecision)]) {
        for (subject, decision) in hidden {
            guard reportedSubjects.insert(subject.id).inserted else { continue }
            recordBlock(decision, channel: subject.channelName, title: subject.title)
        }
    }

    // MARK: - Switches

    var strictMode: Bool {
        get { store.strictMode }
        set { mutateStore { $0.strictMode = newValue } }
    }

    var blockShorts: Bool {
        get { store.blockShorts }
        set { mutateStore { $0.blockShorts = newValue } }
    }

    var youTubeProtection: Bool {
        get { store.youTubeProtection }
        set { mutateStore { $0.youTubeProtection = newValue } }
    }

    /// The hero switch: whether ClearView filters what it shows on this device.
    ///
    /// On Android this reflects an Accessibility Service that outlives the app; on iOS
    /// there is no such service to point at, so the switch is honest about the reach it
    /// has — it turns ClearView's own filtering on and off — and the card says so in the
    /// same breath. Everything the user can check here (the feed, the player, the activity
    /// it produces) is real, and nothing here claims to watch other apps.
    var protectionEnabled: Bool {
        get { store.hasBeenEnabled }
        set {
            mutateStore { $0.hasBeenEnabled = newValue }
            if newValue { lastSuggestionFailed = false }
        }
    }

    // MARK: - Lists

    var userKeywords: [String] { store.userKeywords }
    var youTubeKeywords: [String] { store.youTubeKeywords }
    var blockedDomains: [String] { store.blockedDomains }
    var blockedChannels: [BlockedChannel] { store.blockedChannels }

    func filteredChannels(search: String) -> [BlockedChannel] {
        store.filteredChannels(search: search)
    }

    @discardableResult
    func addUserKeyword(_ keyword: String) -> Bool {
        var added = false
        mutateStore { added = $0.addUserKeyword(keyword) }
        return added
    }

    func removeUserKeyword(_ keyword: String) {
        mutateStore { $0.removeUserKeyword(keyword) }
    }

    @discardableResult
    func addYouTubeKeyword(_ keyword: String) -> Bool {
        var added = false
        mutateStore { added = $0.addYouTubeKeyword(keyword) }
        return added
    }

    func removeYouTubeKeyword(_ keyword: String) {
        mutateStore { $0.removeYouTubeKeyword(keyword) }
    }

    @discardableResult
    func addBlockedDomain(_ domain: String) -> Bool {
        var added = false
        mutateStore { added = $0.addBlockedDomain(domain) }
        return added
    }

    func removeBlockedDomain(_ domain: String) {
        mutateStore { $0.removeBlockedDomain(domain) }
    }

    @discardableResult
    func addBlockedChannel(_ handle: String, name: String? = nil) -> Bool {
        var added = false
        mutateStore { added = $0.addBlockedChannel(handle: handle, name: name) }
        return added
    }

    func removeBlockedChannel(_ handle: String) {
        mutateStore { $0.removeBlockedChannel(handle) }
    }

    // MARK: - The password

    var hasPassword: Bool { store.hasPassword }

    /// Set the password and unlock this session with it.
    ///
    /// Setting a password is what turns the lock on, so leaving the session locked
    /// straight after would be asking for the password twice for one decision.
    func setPassword(_ password: String, confirmation: String) -> String? {
        if password.count < ProtectionStore.minimumPasswordLength {
            return "Password must be at least \(ProtectionStore.minimumPasswordLength) characters"
        }
        guard password == confirmation else { return "Passwords do not match" }

        var failure: String?
        mutateStore { failure = $0.setPassword(password) }
        guard failure == nil else { return failure }
        isUnlocked = true
        return nil
    }

    /// Try to unlock. Returns false for a wrong password.
    @discardableResult
    func unlock(with password: String) -> Bool {
        guard store.verifyPassword(password) else { return false }
        isUnlocked = true
        return true
    }

    func removePassword() {
        mutateStore { $0.clearPassword() }
        isUnlocked = true
    }

    /// Re-lock the tab, so the next look at it wants the password again.
    func lock() {
        guard store.hasPassword else { return }
        isUnlocked = false
    }

    // MARK: - Activity

    var activitySummary: BlockActivitySummary { store.activitySummary() }

    func clearActivity() {
        mutateStore { $0.clearEvents() }
    }

    /// Record a block that ClearView made, and write the receipt for it.
    ///
    /// Both halves matter and they are separate: the event is what the dashboard counts,
    /// and the notification is what tells a person that something they asked for
    /// happened. A block with no receipt is a block nobody can see.
    func recordBlock(_ decision: BlockDecision, channel: String? = nil, title: String? = nil) {
        let label = title?.trimmed.nilWhenBlank ?? decision.matched
        let channel = channel ?? decision.channel
        mutateStore { store in
            store.recordBlock(category: decision.category, keyword: decision.matched, channel: channel)
            store.addNotification(
                id: "blocked:\(decision.category):\(decision.matched):\(channel ?? ""):\(label)",
                kind: ProtectionNotification.Kind.blocked,
                value: decision.matched,
                displayName: channel,
                message: "\"\(label)\" was blocked — it matched \(decision.matched)."
            )
        }
    }

    // MARK: - The notification centre

    var notifications: [ProtectionNotification] { store.notifications }
    var unreadNotificationCount: Int { store.unreadNotificationCount }

    func markNotificationRead(_ id: String) {
        mutateStore { $0.markNotificationRead(id: id) }
    }

    func markAllNotificationsRead() {
        mutateStore { $0.markAllNotificationsRead() }
    }

    func clearNotifications() {
        mutateStore { $0.clearNotifications() }
    }

    // MARK: - The shared blocklist

    var globalKeywords: [String] { store.globalKeywords }
    var globalChannels: [String] { store.globalChannels }
    var hasGlobalSnapshot: Bool { store.hasGlobalSnapshot }
    var submissions: [ProtectionSubmission] { store.submissions }

    /// The shared blocklist as a card's one-line summary.
    var sharedSummary: String {
        guard hasGlobalSnapshot else { return "Not loaded yet" }
        return "\(globalKeywords.count) keywords · \(globalChannels.count) channels blocked for everyone"
    }

    /// Fetch the shared rules, leaving the previous snapshot in place on any failure.
    func syncGlobalRules(force: Bool = true) async {
        guard client.isConfigured, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        if let snapshot = await client.fetchRules() {
            mutateStore { $0.globalRules = snapshot }
        }
    }

    /// Read this device's own requests and their current status.
    ///
    /// The live rules are read **before** the statuses are published, because whether an
    /// approved request still counts as global is a comparison between the two: it is only
    /// honest when the rules are at least as fresh as the statuses.
    func refreshSubmissions(notifyOnChange: Bool = true) async {
        guard client.isConfigured else { return }
        isLoadingSubmissions = true
        defer { isLoadingSubmissions = false }

        guard let fetched = await client.fetchSubmissions(anonymousId: anonymousId.current) else { return }
        let snapshot = await client.fetchRules()

        let previous = Dictionary(uniqueKeysWithValues: store.submissions.map { ($0.id, $0.status) })
        mutateStore { store in
            store.submissions = fetched
            if let snapshot { store.globalRules = snapshot }
        }

        guard notifyOnChange else { return }
        for submission in fetched {
            // Only a CHANGE is news, and only a final decision: a request seen as pending
            // the first time is not news, because the person was there when they sent it.
            guard let before = previous[submission.id], before != submission.status else { continue }
            switch submission.status {
            case SubmissionStatus.approved:
                mutateStore { store in
                    store.addNotification(
                        id: "approved:\(submission.id)",
                        kind: ProtectionNotification.Kind.approved,
                        value: submission.value,
                        displayName: submission.displayName,
                        message: "Block request approved — \(submission.value) was added to the shared blocklist."
                    )
                }
            case SubmissionStatus.rejected:
                mutateStore { store in
                    store.addNotification(
                        id: "rejected:\(submission.id)",
                        kind: ProtectionNotification.Kind.rejected,
                        value: submission.value,
                        displayName: submission.displayName,
                        message: "Block request rejected — your request to block \(submission.value) for everyone was not added."
                    )
                }
            default:
                break
            }
        }
    }

    /// Whether the shared blocklist can be contributed to at all.
    var sharedListAvailable: Bool { client.isConfigured }

    /// Where one of this device's requests stands.
    func submissionStatus(kind: String, value: String) -> String? {
        store.submissionStatus(kind: kind, value: value)
    }

    func isQueuedForReview(kind: String, value: String) -> Bool {
        store.isQueuedForReview(kind: kind, value: value)
    }

    func isApprovedGlobally(kind: String, value: String) -> Bool {
        store.isApprovedGlobally(kind: kind, value: value)
    }

    func isRemovedGlobally(kind: String, value: String) -> Bool {
        store.isRemovedGlobally(kind: kind, value: value)
    }

    func displayStatus(of submission: ProtectionSubmission) -> String {
        store.displayStatus(of: submission)
    }

    /// Suggest a keyword for the shared list, and record the receipt.
    @discardableResult
    func submitKeywordToGlobal(_ keyword: String) async -> Bool {
        await submit(kind: "keyword", value: keyword, displayName: nil)
    }

    @discardableResult
    func submitChannelToGlobal(_ handle: String, name: String?) async -> Bool {
        await submit(kind: "channel", value: handle, displayName: name)
    }

    private func submit(kind: String, value: String, displayName: String?) async -> Bool {
        let ok = await client.suggest(
            kind: kind,
            value: value,
            displayName: displayName,
            anonymousId: anonymousId.current
        )
        lastSuggestionFailed = !ok
        guard ok else { return false }

        let label = displayName?.trimmed.nilWhenBlank ?? value
        mutateStore { store in
            store.addNotification(
                id: "submitted:\(kind):\(value)",
                kind: ProtectionNotification.Kind.submitted,
                value: value,
                displayName: displayName,
                message: "\"\(label)\" was submitted to the shared blocklist and is waiting for review."
            )
        }
        await refreshSubmissions(notifyOnChange: false)
        return true
    }

    // MARK: - Plumbing

    /// Change the settings and publish the change.
    ///
    /// The **whole value is assigned** rather than a field mutated in place. Observation
    /// fires on the property, so a nested mutation that never reaches the property's own
    /// setter is a change no view would hear about — which is exactly how this tab managed
    /// to look frozen while its store was correct. Every write in this type goes through
    /// here so there is one place to be right.
    private func mutateStore(_ change: (inout ProtectionStore) -> Void) {
        var updated = store
        change(&updated)
        store = updated
    }
}

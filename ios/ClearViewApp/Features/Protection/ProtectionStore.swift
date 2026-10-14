import CryptoKit
import Foundation

/// One YouTube channel on the user's block list.
///
/// Stored by `@handle`, because the handle is the channel's identity: a channel can
/// rename its title at any time and the block has to survive that. The display name is
/// kept only to show a person what they blocked.
struct BlockedChannel: Codable, Equatable, Identifiable {
    let handle: String
    var name: String? = nil
    var reason: String? = nil
    var addedAtMs: Int64

    var id: String { handle }

    /// What to show in a list: the display name when there is one, else the handle.
    var label: String {
        if let name, !name.isBlank { return name }
        return handle
    }
}

/// One of this device's requests to the shared blocklist, and where it got to.
///
/// Anonymous, like everything else here: the request is filed under the device's own
/// generated id, and there is no account behind it.
struct ProtectionSubmission: Codable, Equatable, Identifiable {
    let id: String
    let kind: String
    let value: String
    var displayName: String? = nil
    var status: String
    var atMs: Int64
}

/// A line in the notification centre: a block that happened, or the fate of a request.
struct ProtectionNotification: Codable, Equatable, Identifiable {
    let id: String
    let kind: String
    let value: String
    var displayName: String? = nil
    var message: String
    var atMs: Int64
    var read: Bool

    /// The four kinds Android writes, kept as wire strings so an old notification keeps
    /// its meaning when a new kind is added.
    enum Kind {
        static let blocked = "blocked"
        static let approved = "global_approved"
        static let rejected = "global_rejected"
        static let submitted = "global_submitted"
    }
}

/// The global rule set this device last read from the backend.
struct GlobalRuleSnapshot: Codable, Equatable {
    var version: String = ""
    var keywords: [String] = []
    var channels: [String] = []
    var keywordReports: [String: Int] = [:]
    var lastSyncMs: Int64 = 0

    /// A rule set that has only ever been compared to a *fetched* snapshot.
    ///
    /// Whether an approved request is still in force is a comparison against the live
    /// rules, and that comparison is only honest when we actually have a snapshot. With
    /// none, a rule counts as live, so a slow network can never relabel a real rule.
    var isSynced: Bool { lastSyncMs > 0 }
}

/// Everything the Protection tab reads and writes, on this device.
///
/// The Android app splits this across four stores (`BlockRepository`,
/// `BrainRotRepository`, `GlobalRulesStore`, `NotificationStore`); one store is right
/// here because on iOS they share a single backing store anyway, and the tab's whole
/// subject is one thing — what is blocked, why, and what happened.
///
/// **Everything here is local and stays local.** The only values that ever leave the
/// device are the ones the Shared blocklist needs — the terms this person chose to
/// suggest, and an anonymous id generated on this phone. Nothing in this file can name
/// a person.
struct ProtectionStore {

    /// Where each setting lives. Android's own key names, so the two platforms can be
    /// diffed when a value changes.
    enum Key {
        static let strictMode = "strict_mode"
        static let blockShorts = "block_shorts"
        static let youTubeProtection = "yt_chrome_test"
        static let userKeywords = "user_keywords"
        static let youTubeKeywords = "youtube_keywords"
        static let blockedDomains = "blocked_domains"
        static let blockedChannels = "blocked_channels"
        static let passwordHash = "app_password"
        static let events = "events_json"
        static let globalRules = "global_rules_json"
        static let submissions = "submissions_json"
        static let notifications = "notifications_json"
        static let protectedOnce = "protection_enabled_once"
    }

    /// How many notifications are kept. An unbounded log is not a feed.
    static let maxNotifications = 200

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Switches

    /// Strict Mode: adds the curated discovery terms on top of the always-on filter.
    var strictMode: Bool {
        get { defaults.bool(forKey: Key.strictMode) }
        nonmutating set { defaults.set(newValue, forKey: Key.strictMode) }
    }

    /// Block YouTube Shorts, without making "shorts" a keyword.
    var blockShorts: Bool {
        get { defaults.bool(forKey: Key.blockShorts) }
        nonmutating set { defaults.set(newValue, forKey: Key.blockShorts) }
    }

    /// YouTube Protection: the user's keywords and blocked channels, applied to the
    /// YouTube content ClearView shows.
    var youTubeProtection: Bool {
        get { defaults.bool(forKey: Key.youTubeProtection) }
        nonmutating set { defaults.set(newValue, forKey: Key.youTubeProtection) }
    }

    /// Whether protection has ever been switched on.
    ///
    /// The hero card's switch describes *this device*, not a service: iOS has no
    /// always-on screen reader to point at, so the switch turns ClearView's own
    /// filtering of what it shows on and off. The flag lets the app tell "nobody has ever
    /// turned this on" from "somebody turned it off" — the two want different wording,
    /// and only one of them is a choice.
    var hasBeenEnabled: Bool {
        get { defaults.bool(forKey: Key.protectedOnce) }
        nonmutating set { defaults.set(newValue, forKey: Key.protectedOnce) }
    }

    // MARK: - Blocked keywords

    /// The user's own everywhere-keywords: "My blocked items".
    ///
    /// This is deliberately **only** what the person added. The list a screen may edit
    /// must never include the shared rules: showing a global rule as if it were the
    /// user's own entry makes its Remove button a lie — the write goes to the local
    /// list, and the next read merges the global rule straight back in.
    var userKeywords: [String] {
        get { stringList(Key.userKeywords) }
        nonmutating set { setStringList(newValue, Key.userKeywords) }
    }

    /// The user's YouTube-only keywords, managed under YouTube Protection.
    ///
    /// Separate from the everywhere list on purpose: a term added here applies to YouTube
    /// content and never to a website, which is the promise the section heading makes.
    var youTubeKeywords: [String] {
        get { stringList(Key.youTubeKeywords) }
        nonmutating set { setStringList(newValue, Key.youTubeKeywords) }
    }

    /// Add a keyword (trimmed, lowercased). Returns false when there is nothing to add.
    @discardableResult
    nonmutating func addUserKeyword(_ keyword: String) -> Bool {
        var current = userKeywords
        guard let value = ProtectionStore.normalizeKeyword(keyword), !current.contains(value) else {
            return false
        }
        current.append(value)
        userKeywords = current
        return true
    }

    nonmutating func removeUserKeyword(_ keyword: String) {
        userKeywords = userKeywords.filter { $0 != keyword.trimmed.lowercased() }
    }

    @discardableResult
    nonmutating func addYouTubeKeyword(_ keyword: String) -> Bool {
        var current = youTubeKeywords
        guard let value = ProtectionStore.normalizeKeyword(keyword), !current.contains(value) else {
            return false
        }
        current.append(value)
        youTubeKeywords = current
        return true
    }

    nonmutating func removeYouTubeKeyword(_ keyword: String) {
        youTubeKeywords = youTubeKeywords.filter { $0 != keyword.trimmed.lowercased() }
    }

    /// What every keyword comparison uses: trimmed, lowercased, non-empty.
    static func normalizeKeyword(_ keyword: String) -> String? {
        let value = keyword.trimmed.lowercased()
        return value.isEmpty ? nil : value
    }

    // MARK: - Blocked websites

    var blockedDomains: [String] {
        get { stringList(Key.blockedDomains) }
        nonmutating set { setStringList(newValue, Key.blockedDomains) }
    }

    /// Add a website. Accepts "example.com", "https://www.example.com/path" and
    /// "reddit.com" alike, and refuses anything that is not a hostname, so the list can
    /// never hold an entry the matcher would silently ignore.
    @discardableResult
    nonmutating func addBlockedDomain(_ domain: String) -> Bool {
        guard let host = ProtectionMatcher.normalizeDomain(domain) else { return false }
        var current = blockedDomains
        guard !current.contains(host) else { return false }
        current.append(host)
        blockedDomains = current
        return true
    }

    nonmutating func removeBlockedDomain(_ domain: String) {
        let target = ProtectionMatcher.normalizeDomain(domain) ?? domain.trimmed.lowercased()
        blockedDomains = blockedDomains.filter { $0 != target }
    }

    // MARK: - Blocked channels

    var blockedChannels: [BlockedChannel] {
        get { decode([BlockedChannel].self, Key.blockedChannels) ?? [] }
        nonmutating set { encode(newValue, Key.blockedChannels) }
    }

    /// Block a channel by handle. Returns false when the input carries no usable handle,
    /// which is what the add field reports instead of storing something unmatched.
    @discardableResult
    nonmutating func addBlockedChannel(handle: String, name: String? = nil) -> Bool {
        guard let normalized = ProtectionMatcher.normalizeHandle(handle) else { return false }
        var current = blockedChannels
        if let index = current.firstIndex(where: { $0.handle == normalized }) {
            // Re-blocking a renamed channel updates the label rather than duplicating it.
            if let name, !name.isBlank { current[index].name = name }
            blockedChannels = current
            return true
        }
        current.insert(
            BlockedChannel(
                handle: normalized,
                name: name?.trimmed.isEmpty == false ? name?.trimmed : nil,
                reason: nil,
                addedAtMs: ProtectionStore.nowMs()
            ),
            at: 0
        )
        blockedChannels = current
        return true
    }

    nonmutating func removeBlockedChannel(_ handle: String) {
        let target = ProtectionMatcher.normalizeHandle(handle) ?? handle.trimmed.lowercased()
        blockedChannels = blockedChannels.filter { $0.handle != target }
    }

    func isChannelBlocked(_ handle: String?) -> Bool {
        guard let normalized = ProtectionMatcher.normalizeHandle(handle ?? "") else { return false }
        return blockedChannels.contains { $0.handle == normalized }
    }

    /// The blocked channels matching a search term, for the manager screen's filter.
    func filteredChannels(search: String) -> [BlockedChannel] {
        let needle = search.trimmed.lowercased()
        guard !needle.isEmpty else { return blockedChannels }
        return blockedChannels.filter {
            $0.handle.lowercased().contains(needle)
                || ($0.name?.lowercased().contains(needle) ?? false)
        }
    }

    // MARK: - The password

    /// The stored password's SHA-256, or nil when no password is set.
    ///
    /// A hash rather than the password: the value's whole job is to be compared, and a
    /// store that holds the plaintext of a lock is a lock that leaks.
    var passwordHash: String? {
        defaults.string(forKey: Key.passwordHash)
    }

    var hasPassword: Bool { passwordHash != nil }

    /// Whether a password attempt is long enough to be set.
    static let minimumPasswordLength = 4

    @discardableResult
    nonmutating func setPassword(_ password: String) -> String? {
        if password.count < ProtectionStore.minimumPasswordLength {
            return "Password must be at least \(ProtectionStore.minimumPasswordLength) characters"
        }
        defaults.set(ProtectionStore.hash(password), forKey: Key.passwordHash)
        return nil
    }

    /// Whether the attempt matches the stored password.
    ///
    /// Compared case-insensitively on the hex, as Android does, so the comparison can
    /// never fail over the spelling of a hash rather than the password.
    func verifyPassword(_ password: String) -> Bool {
        guard let stored = passwordHash else { return false }
        return stored.caseInsensitiveCompare(ProtectionStore.hash(password)) == .orderedSame
    }

    nonmutating func clearPassword() {
        defaults.removeObject(forKey: Key.passwordHash)
    }

    static func hash(_ password: String) -> String {
        SHA256.hash(data: Data(password.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Protection activity

    /// The recorded blocks, oldest first, bounded to the newest 500.
    var events: [BlockEvent] {
        get { decode([BlockEvent].self, Key.events) ?? [] }
        nonmutating set { encode(Array(newValue.suffix(BlockActivityStats.maxEvents)), Key.events) }
    }

    /// Record one block. The trim rule is `BlockActivityStats.append`, so the cap is
    /// tested as a rule rather than as a side effect of this method.
    nonmutating func recordBlock(category: String, keyword: String? = nil, channel: String? = nil) {
        let event = BlockEvent(
            atMs: ProtectionStore.nowMs(),
            category: category,
            keyword: keyword,
            channel: channel
        )
        events = BlockActivityStats.append(events, event)
    }

    nonmutating func clearEvents() {
        defaults.removeObject(forKey: Key.events)
    }

    /// The dashboard's numbers, as of now.
    func activitySummary(nowMs: Int64 = ProtectionStore.nowMs(), timeZone: TimeZone = .current) -> BlockActivitySummary {
        BlockActivityStats.summarise(events, nowMs: nowMs, timeZone: timeZone)
    }

    // MARK: - The shared blocklist

    var globalRules: GlobalRuleSnapshot {
        get { decode(GlobalRuleSnapshot.self, Key.globalRules) ?? GlobalRuleSnapshot() }
        nonmutating set { encode(newValue, Key.globalRules) }
    }

    var submissions: [ProtectionSubmission] {
        get { decode([ProtectionSubmission].self, Key.submissions) ?? [] }
        nonmutating set { encode(newValue, Key.submissions) }
    }

    /// True when the global rule set can be shown at all: at least one successful read.
    var hasGlobalSnapshot: Bool { globalRules.isSynced }

    /// Whether a rule for this value is **still** global.
    ///
    /// A submission's status records a decision, not a claim about right now: a rule an
    /// administrator approved and later removed keeps reporting "approved" from the
    /// server forever. The only honest source for "is this blocking anyone" is the live
    /// rule set, and an unsynced cache counts as live so a slow network can never
    /// relabel a rule that really is in force.
    func isLiveGlobally(kind: String, value: String) -> Bool {
        let snapshot = globalRules
        guard snapshot.isSynced else { return true }
        if kind == "channel" {
            let handle = ProtectionMatcher.normalizeHandle(value) ?? value
            return snapshot.channels.contains { $0.caseInsensitiveCompare(handle) == .orderedSame }
        }
        return snapshot.keywords.contains(value.trimmed.lowercased())
    }

    /// The raw status the server reported for this value, before any local correction.
    func rawSubmissionStatus(kind: String, value: String) -> String? {
        submissions
            .first { $0.kind == kind && $0.value.caseInsensitiveCompare(value.trimmed) == .orderedSame }?
            .status
    }

    /// Where this device's request for one value stands, or nil when it was never sent —
    /// or was sent, approved, and has since been removed.
    ///
    /// This is what stops the Send action being offered twice: once a value is queued it
    /// shows as queued, and once approved it shows as approved, so the button is not
    /// drawn again. A rejected request returns nil deliberately — a rejection is not a
    /// reason to stop someone asking again — and so does a removed one.
    func submissionStatus(kind: String, value: String) -> String? {
        guard let status = rawSubmissionStatus(kind: kind, value: value) else { return nil }
        return SubmissionStatus.effective(status: status, liveGlobally: isLiveGlobally(kind: kind, value: value))
    }

    func isQueuedForReview(kind: String, value: String) -> Bool {
        let status = submissionStatus(kind: kind, value: value)
        return status == SubmissionStatus.pending || status == "under_review"
    }

    func isApprovedGlobally(kind: String, value: String) -> Bool {
        submissionStatus(kind: kind, value: value) == SubmissionStatus.approved
    }

    func isRemovedGlobally(kind: String, value: String) -> Bool {
        guard let status = rawSubmissionStatus(kind: kind, value: value) else { return false }
        return SubmissionStatus.isRemoved(status: status, liveGlobally: isLiveGlobally(kind: kind, value: value))
    }

    /// The status to display for a request row, correcting a stale "approved".
    func displayStatus(of submission: ProtectionSubmission) -> String {
        SubmissionStatus.display(
            status: submission.status,
            liveGlobally: isLiveGlobally(kind: submission.kind, value: submission.value)
        )
    }

    func pendingSubmissions(kind: String) -> [ProtectionSubmission] {
        submissions.filter {
            $0.kind == kind && ($0.status == SubmissionStatus.pending || $0.status == "under_review")
        }
    }

    /// Approved requests for one kind that are **still** global — a rule since pulled is
    /// left out, because this group says what is in force for everyone right now.
    func approvedSubmissions(kind: String) -> [ProtectionSubmission] {
        submissions.filter {
            $0.kind == kind && $0.status == SubmissionStatus.approved && isLiveGlobally(kind: kind, value: $0.value)
        }
    }

    /// The global keywords and channels that apply in addition to the user's own list.
    var globalKeywords: [String] { globalRules.keywords }
    var globalChannels: [String] { globalRules.channels }

    // MARK: - The notification centre

    var notifications: [ProtectionNotification] {
        get { decode([ProtectionNotification].self, Key.notifications) ?? [] }
        nonmutating set { encode(Array(newValue.prefix(ProtectionStore.maxNotifications)), Key.notifications) }
    }

    var unreadNotificationCount: Int { notifications.filter { !$0.read }.count }

    /// Add a line, newest first and idempotent on the id.
    ///
    /// Idempotent because the same news arrives repeatedly — a poll that re-reads an
    /// unchanged "approved" must not become a second notification.
    nonmutating func addNotification(
        id: String,
        kind: String,
        value: String,
        displayName: String? = nil,
        message: String
    ) {
        var current = notifications
        guard !current.contains(where: { $0.id == id }) else { return }
        current.insert(
            ProtectionNotification(
                id: id,
                kind: kind,
                value: value,
                displayName: displayName,
                message: message,
                atMs: ProtectionStore.nowMs(),
                read: false
            ),
            at: 0
        )
        notifications = current
    }

    nonmutating func markNotificationRead(id: String) {
        var current = notifications
        guard let index = current.firstIndex(where: { $0.id == id }), !current[index].read else { return }
        current[index].read = true
        notifications = current
    }

    nonmutating func markAllNotificationsRead() {
        notifications = notifications.map { item in
            var copy = item
            copy.read = true
            return copy
        }
    }

    nonmutating func clearNotifications() {
        defaults.removeObject(forKey: Key.notifications)
    }

    // MARK: - The active rule set

    /// Compile everything that applies, ready to match.
    ///
    /// The shared keywords are merged in here, in the one place every matching path
    /// reads, exactly as Android merges them in `BlockRepository.getUserKeywords`: that
    /// is what makes a global rule apply everywhere the user's own list applies, without
    /// one call site that could be forgotten.
    ///
    /// The built-in adult tier is always on — it is not a setting, it is the product —
    /// and Strict Mode adds to it, never replaces it.
    func rules() -> ProtectionRules {
        var rules = ProtectionRules()
        rules.alwaysBlock = ProtectionMatcher.compile(ProtectionMatcher.builtInKeywords(strictMode: strictMode))
        // Everywhere keywords: the user's own list plus the shared rules. The YouTube-only
        // list is deliberately NOT merged in here — it is its own tier, applied only to
        // YouTube content.
        rules.userKeywords = ProtectionMatcher.compile(
            (userKeywords + globalKeywords).map { $0.trimmed.lowercased() }
        )
        rules.youTubeKeywords = ProtectionMatcher.compile(youTubeKeywords.map { $0.trimmed.lowercased() })
        rules.domains = (blockedDomains + ProtectionPresets.adultDomains)
            .compactMap { ProtectionMatcher.normalizeDomain($0) }
        rules.combinationGeneric = ProtectionMatcher.compile(ProtectionPresets.combinationGenericTerms)
        rules.combinationRisky = ProtectionMatcher.compile(ProtectionPresets.combinationRiskyTerms)
        rules.channels = (blockedChannels.map(\.handle) + globalChannels)
            .compactMap { ProtectionMatcher.normalizeHandle($0) ?? ($0.trimmed.isEmpty ? nil : $0.trimmed) }
        return rules
    }

    // MARK: - Reset

    /// Forget everything this tab owns. Used by the tests and by a fresh install's reset;
    /// never wired to an in-app button, because losing a block list by accident is not a
    /// recoverable mistake for someone who needs it.
    nonmutating func clearAll() {
        for key in [
            Key.strictMode, Key.blockShorts, Key.youTubeProtection, Key.userKeywords,
            Key.youTubeKeywords, Key.blockedDomains, Key.blockedChannels, Key.passwordHash,
            Key.events, Key.globalRules, Key.submissions, Key.notifications, Key.protectedOnce,
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Plumbing

    static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func stringList(_ key: String) -> [String] {
        (defaults.array(forKey: key) as? [String]) ?? []
    }

    private func setStringList(_ value: [String], _ key: String) {
        defaults.set(value, forKey: key)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

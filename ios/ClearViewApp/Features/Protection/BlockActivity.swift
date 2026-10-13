import Foundation

/// One recorded protection event: something was blocked, and why.
///
/// Kept deliberately small and dumb — it is written on the block path, and it is the only
/// thing the Activity dashboard reads. `category` is a short label ("Adult", "Brain Rot",
/// "Strict Mode", "Custom Website", "Search"); `keyword` and `channel` are the
/// explanation shown back to the user ("This content was blocked because it matched: X").
struct BlockEvent: Equatable, Codable {
    let atMs: Int64
    let category: String
    let keyword: String?
    let channel: String?

    init(atMs: Int64, category: String, keyword: String? = nil, channel: String? = nil) {
        self.atMs = atMs
        self.category = category
        self.keyword = keyword
        self.channel = channel
    }
}

/// What the Activity section shows.
///
/// Every field is derived from the recorded events plus the current time — **nothing here
/// is stored**, so the numbers can never drift out of sync with the events they summarise.
struct BlockActivitySummary: Equatable {
    var totalBlocks: Int = 0
    var todayBlocks: Int = 0
    var weekBlocks: Int = 0
    var topKeywords: [(keyword: String, count: Int)] = []
    var topChannels: [(channel: String, count: Int)] = []
    var blocksByCategory: [(category: String, count: Int)] = []
    /// Consecutive days, ending today or yesterday, with at least one block.
    var streakDays: Int = 0

    static func == (lhs: BlockActivitySummary, rhs: BlockActivitySummary) -> Bool {
        lhs.totalBlocks == rhs.totalBlocks
            && lhs.todayBlocks == rhs.todayBlocks
            && lhs.weekBlocks == rhs.weekBlocks
            && lhs.streakDays == rhs.streakDays
            && lhs.topKeywords.map(\.keyword) == rhs.topKeywords.map(\.keyword)
            && lhs.topKeywords.map(\.count) == rhs.topKeywords.map(\.count)
            && lhs.topChannels.map(\.channel) == rhs.topChannels.map(\.channel)
            && lhs.topChannels.map(\.count) == rhs.topChannels.map(\.count)
            && lhs.blocksByCategory.map(\.category) == rhs.blocksByCategory.map(\.category)
            && lhs.blocksByCategory.map(\.count) == rhs.blocksByCategory.map(\.count)
    }
}

/// Pure aggregation for the Activity dashboard.
///
/// Everything is a function of (events, now, day boundaries) with no clock of its own, so
/// the numbers the user sees can be tested directly instead of only being trusted because
/// they looked right on one phone. The day boundary is a parameter because "today" is a
/// local-time concept and a test cannot rely on the machine's time zone.
enum BlockActivityStats {

    /// How many events are kept — enough for the dashboard, bounded on disk.
    static let maxEvents = 500
    /// Top-N lists shown in the dashboard.
    static let topCount = 5
    private static let dayMillis: Int64 = 24 * 60 * 60 * 1000

    /// Start-of-day for `atMs` in `timeZone`.
    ///
    /// Two timestamps share a day index exactly when they fall on the same local calendar
    /// day, which is what makes "today" and the streak correct across a daylight-saving
    /// change — a 23- or 25-hour day still has one index.
    static func dayIndex(_ atMs: Int64, timeZone: TimeZone = .current) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(atMs) / 1000))
        return Int64(start.timeIntervalSince1970 * 1000)
    }

    /// Summarises `events` as of `nowMs`.
    ///
    ///  - **today** = events on the same local day as now.
    ///  - **week** = events within the last seven local days, today included.
    ///  - **streak** = consecutive local days with at least one block, counted backwards
    ///    from today. A day with no blocks *yet* does not break the streak — someone who
    ///    has not browsed since yesterday is still on it, and telling them otherwise on
    ///    the morning of day two would be wrong.
    ///
    /// Keywords and channels are counted case-insensitively (the same term typed with a
    /// different capital is the same term); categories are not, because they are the app's
    /// own labels.
    static func summarise(
        _ events: [BlockEvent],
        nowMs: Int64,
        timeZone: TimeZone = .current
    ) -> BlockActivitySummary {
        guard !events.isEmpty else { return BlockActivitySummary() }

        let today = dayIndex(nowMs, timeZone: timeZone)
        let weekStart = today - 6 * dayMillis

        var todayCount = 0
        var weekCount = 0
        var keywordCounts: [String: Int] = [:]
        var channelCounts: [String: Int] = [:]
        var categoryCounts: [String: Int] = [:]
        var activeDays: Set<Int64> = []

        for event in events {
            let day = dayIndex(event.atMs, timeZone: timeZone)
            if day == today { todayCount += 1 }
            if day >= weekStart { weekCount += 1 }
            activeDays.insert(day)

            if let keyword = event.keyword, !keyword.trimmed.isEmpty {
                let key = keyword.lowercased()
                keywordCounts[key, default: 0] += 1
            }
            if let channel = event.channel, !channel.trimmed.isEmpty {
                let key = channel.lowercased()
                channelCounts[key, default: 0] += 1
            }
            if !event.category.trimmed.isEmpty {
                categoryCounts[event.category, default: 0] += 1
            }
        }

        // The streak walks back from today. Today not counting yet is allowed: the first
        // missing day ends the run only if it is not today.
        var streak = 0
        var cursor = today
        var first = true
        while true {
            if activeDays.contains(cursor) {
                streak += 1
            } else if !first {
                break
            }
            first = false
            cursor -= dayMillis
            // Hard stop: no event can predate the oldest one we keep.
            if streak > maxEvents { break }
        }

        return BlockActivitySummary(
            totalBlocks: events.count,
            todayBlocks: todayCount,
            weekBlocks: weekCount,
            topKeywords: topN(keywordCounts).map { (keyword: $0.key, count: $0.value) },
            topChannels: topN(channelCounts).map { (channel: $0.key, count: $0.value) },
            blocksByCategory: topN(categoryCounts).map { (category: $0.key, count: $0.value) },
            streakDays: streak
        )
    }

    /// Appends `event` to `events`, keeping only the newest `maxEvents`.
    ///
    /// Pure so the trim rule is testable; the store just saves the result. The cap exists
    /// because the events file is written on every block and read on every dashboard open.
    static func append(_ events: [BlockEvent], _ event: BlockEvent) -> [BlockEvent] {
        var updated = events
        updated.append(event)
        guard updated.count > maxEvents else { return updated }
        return Array(updated.suffix(maxEvents))
    }

    /// Highest count first, ties broken alphabetically so the dashboard never reshuffles
    /// between two identical scans of the same events.
    private static func topN(_ counts: [String: Int]) -> [(key: String, value: Int)] {
        counts.sorted { first, second in
            if first.value != second.value { return first.value > second.value }
            return first.key < second.key
        }
        .prefix(topCount)
        .map { (key: $0.key, value: $0.value) }
    }
}

/// How one of this device's requests to the global blocklist should be read.
///
/// A submission's status is a record of the decision an administrator made; it is **not** a
/// claim about what is blocking anyone right now. A rule that was approved and later
/// removed keeps reporting "approved" from the server forever, so the only way to tell
/// "still in force" from "since removed" is to compare the status against the live rule set
/// — which arrives separately and can be behind.
///
/// That comparison is deliberately pure functions rather than a branch buried in a view
/// model: the rule is "approved but no longer global reads as removed", it is easy to get
/// subtly wrong, and a plain function can be tested exhaustively without a device.
///
/// `liveGlobally` must be false **only when we are sure**: a request is live unless we have
/// a synced rules snapshot that does not contain it. The caller decides that (an unsynced
/// cache reports live), so a missed sync can never relabel a real rule — at worst it shows
/// a removed one as approved for a moment longer.
enum SubmissionStatus {

    /// The status a request gets once its rule is gone.
    static let removed = "removed"
    static let approved = "approved"
    static let rejected = "rejected"
    static let pending = "pending"

    /// The status to **display** for a request row: an approved request whose rule is no
    /// longer global reads "removed" instead of the stale "approved", so the screen never
    /// claims something is blocked for everyone when it is not.
    static func display(status: String, liveGlobally: Bool) -> String {
        isRemoved(status: status, liveGlobally: liveGlobally) ? removed : status
    }

    /// The status to **reason about** — where a request stands for the purpose of offering
    /// the Send action again.
    ///
    /// Nil (treated as "never sent") for a removed request, alongside the rule that a
    /// rejected one is not a reason to stop asking: a term pulled from the blocklist is
    /// exactly the kind of thing worth re-requesting.
    static func effective(status: String, liveGlobally: Bool) -> String? {
        isRemoved(status: status, liveGlobally: liveGlobally) ? nil : status
    }

    /// True when a request was approved and has since been removed.
    static func isRemoved(status: String, liveGlobally: Bool) -> Bool {
        status == approved && !liveGlobally
    }

    /// Whether the Send action should be offered for a request in this state.
    static func canResend(status: String, liveGlobally: Bool) -> Bool {
        switch effective(status: status, liveGlobally: liveGlobally) {
        case nil, rejected: return true
        default: return false
        }
    }

    /// The sentence a row shows, worded for what actually happened rather than for the
    /// server's field.
    static func label(status: String, liveGlobally: Bool) -> String {
        switch display(status: status, liveGlobally: liveGlobally) {
        case approved: return "Blocked for everyone"
        case rejected: return "Not added"
        case removed: return "Was blocked, since removed"
        case pending: return "Waiting for review"
        default: return "Unknown"
        }
    }
}

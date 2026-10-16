import SwiftUI

/// The three decisions a suggestion can be given, as the wire spells them.
///
/// An enum rather than string literals at the call sites: a decision that was mistyped would be
/// refused by the server as invalid input, which reads as "the queue is broken" rather than as what
/// it is.
enum GoodPostBrainRotDecision: String {
    case approve = "approved"
    case reject = "rejected"
    case underReview = "under_review"
}

/// The two answers a falsely-blocked target can be given.
enum GoodPostBrainRotResolution: String {
    /// The block was right: the rule stays in force.
    case keep = "kept"
    /// The block was wrong: the rule is switched OFF, not deleted, so it can be turned back on.
    case stop = "removed"
}

/// What a reported target is offered, given whether a global rule matches it.
///
/// A term no rule matches has no block to stop, so it gets the one honest action rather than a
/// button that would quietly do nothing — and "stop blocking" is deliberately not offered there,
/// because there is nothing to switch off.
func brainRotReportAnswers(hasRule: Bool) -> [GoodPostBrainRotResolution] {
    hasRule ? [.keep, .stop] : [.keep]
}

/// What each answer is called on the button that gives it (§ the false-report queue).
///
/// The words say what happens to the block rather than "approve" and "reject", because the block is
/// the only thing either answer changes — and where there is no rule to switch off, the single
/// answer is "Dismiss", which is what it honestly does: the report is cleared and nothing changes
/// for anybody.
func brainRotAnswerLabel(_ resolution: GoodPostBrainRotResolution, hasRule: Bool) -> String {
    switch resolution {
    case .keep: return hasRule ? "Keep blocking" : "Dismiss"
    case .stop: return "Stop blocking"
    }
}

/// The global blocklist, as an administrator reviews it (§ brain-rot repository).
///
/// Two halves under one bar, because they are one job: the **queue** is what the community has asked
/// for, and the **rules** are what everyone is currently protected by. A reviewer moves a suggestion
/// from one to the other, so separate screens would put the one thing the operator is actually doing
/// — deciding whether this becomes a rule — between two screens.
///
/// ## Approving is the only path from a suggestion to a rule
///
/// There is deliberately no "add from the queue" shortcut: an approval writes the rule and marks the
/// suggestion in one transaction on the server, so a rule can never exist whose suggestion still
/// looks unreviewed. A direct add exists too, but it is a separate act with its own fields — the
/// operator typing a rule is not the same decision as ratifying somebody else's.
///
/// ## A false report is not a suggestion
///
/// A submission says something SHOULD be blocked; a report says a block was WRONG. The same term can
/// appear in both and the two answers are opposites, which is why they get a list each rather than
/// one queue with a sign on it.
@MainActor
@Observable
final class BrainRotAdminModel {
    let repository: GoodPostRepository

    /// Which of the four pages is in front. Held here rather than in the view so a reload — which
    /// happens on every decision — cannot reset it.
    var tab = 0
    var queueStatus = "pending"

    private(set) var dashboard = GoodPostBrainRotDashboard()
    private(set) var submissions: [GoodPostBrainRotSubmission] = []
    private(set) var keywords: [GoodPostBrainRotRule] = []
    private(set) var channels: [GoodPostBrainRotRule] = []
    private(set) var reports: [GoodPostBrainRotReport] = []

    private(set) var dashboardLoading = false
    private(set) var queueLoading = false
    private(set) var rulesLoading = false
    private(set) var reportsLoading = false
    /// True while a write is in flight, so no row offers a second one.
    private(set) var busy = false
    var message: String?

    var newKeyword = ""
    var newChannel = ""

    init(repository: GoodPostRepository) {
        self.repository = repository
    }

    func loadDashboard() async {
        guard !dashboardLoading else { return }
        dashboardLoading = true
        defer { dashboardLoading = false }
        let result = await repository.adminBrainRotDashboard()
        if let value = result.value {
            dashboard = value
            message = nil
        } else {
            message = result.userMessage
        }
    }

    func loadQueue() async {
        guard !queueLoading else { return }
        queueLoading = true
        defer { queueLoading = false }
        let result = await repository.adminBrainRotSubmissions(status: queueStatus)
        if let value = result.value {
            submissions = value
            message = nil
        } else {
            message = result.userMessage
        }
    }

    func loadRules() async {
        guard !rulesLoading else { return }
        rulesLoading = true
        defer { rulesLoading = false }
        let keywordsResult = await repository.adminBrainRotKeywords()
        let channelsResult = await repository.adminBrainRotChannels()
        if let value = keywordsResult.value { keywords = value } else { message = keywordsResult.userMessage }
        if let value = channelsResult.value { channels = value } else { message = channelsResult.userMessage }
    }

    func loadReports() async {
        guard !reportsLoading else { return }
        reportsLoading = true
        defer { reportsLoading = false }
        let result = await repository.adminBrainRotReports()
        if let value = result.value {
            reports = value
            message = nil
        } else {
            message = result.userMessage
        }
    }

    /// Everything, once, when the screen opens.
    ///
    /// All four are read rather than only the page in front: the counts on the dashboard are what
    /// tell an operator which page is worth opening, and a tab that fetched itself would show a zero
    /// first.
    func loadAll() async {
        async let dashboard: Void = loadDashboard()
        async let queue: Void = loadQueue()
        async let rules: Void = loadRules()
        async let reports: Void = loadReports()
        _ = await (dashboard, queue, rules, reports)
    }

    /// Which queue, as a re-read.
    ///
    /// The status is part of the request rather than a filter over what is on screen: a rejected
    /// suggestion is not in the pending response at all, so filtering locally would show an empty
    /// list and call it a queue.
    func selectQueueStatus(_ status: String) async {
        queueStatus = status
        await loadQueue()
    }

    func review(_ submission: GoodPostBrainRotSubmission, decision: GoodPostBrainRotDecision) async {
        await write { await self.repository.adminReviewBrainRotSubmission(submissionId: submission.id, decision: decision.rawValue) }
        await loadQueue()
        // The counts move with every decision, and an approval is what puts a rule on the rules page.
        await loadDashboard()
        if decision == .approve { await loadRules() }
    }

    func addKeyword() async {
        let value = newKeyword.trimmed
        guard !value.isEmpty else { return }
        let result = await repository.adminAddBrainRotKeyword(keyword: value, reason: nil)
        if result.value != nil {
            newKeyword = ""
            message = nil
            await loadRules()
            await loadDashboard()
        } else {
            message = result.userMessage
        }
    }

    func addChannel() async {
        let value = newChannel.trimmed
        guard !value.isEmpty else { return }
        let result = await repository.adminAddBrainRotChannel(handle: value, displayName: nil, reason: nil)
        if result.value != nil {
            newChannel = ""
            message = nil
            await loadRules()
            await loadDashboard()
        } else {
            message = result.userMessage
        }
    }

    /// Enable or disable a rule, without deleting it.
    ///
    /// The decision belongs on the row it lives in: a rule switched off because it was too broad can
    /// be switched back on once it is narrowed, and delete-and-recreate would lose the reports that
    /// were counted against it.
    func setEnabled(_ rule: GoodPostBrainRotRule, enabled: Bool) async {
        let result = await repository.adminSetBrainRotRuleEnabled(kind: rule.kind, ruleId: rule.id, enabled: enabled)
        if result.isOk {
            message = nil
            await loadRules()
            await notifyReadersIfNeeded()
        } else {
            message = result.userMessage
        }
    }

    func delete(_ rule: GoodPostBrainRotRule) async {
        let result = await repository.adminDeleteBrainRotRule(kind: rule.kind, ruleId: rule.id)
        if result.isOk {
            message = nil
            await loadRules()
            await loadDashboard()
            await notifyReadersIfNeeded()
        } else {
            message = result.userMessage
        }
    }

    /// Answer every open report for one target.
    ///
    /// The two answers differ in more than wording: `stop` switches the rule OFF, which every
    /// device enforcing it has to hear about — so that is the one that tells the reader-facing
    /// blocklist the rules moved.
    func answer(_ report: GoodPostBrainRotReport, with resolution: GoodPostBrainRotResolution) async {
        await write {
            await self.repository.adminResolveBrainRotReport(
                kind: report.kind,
                value: report.value,
                resolution: resolution.rawValue
            )
        }
        await loadReports()
        guard resolution == .stop else { return }
        await loadRules()
        await notifyReadersIfNeeded()
    }

    /// Runs one write, reporting its refusal when it has one.
    private func write(_ action: () async -> ApiResult<Void>) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let result = await action()
        message = result.isOk ? nil : result.userMessage
    }

    /// Tells the reader-facing blocklist that the shared rules moved.
    ///
    /// The tab's own blocking is applied from a stored copy of these rules, so a change that was not
    /// announced would leave every device enforcing yesterday's list. Only the writes that can change
    /// what readers enforce call it.
    private func notifyReadersIfNeeded() async {
        await ProtectionModel.shared.syncGlobalRules()
    }
}

/// The Shared blocklist's four pages.
struct GoodPostBrainRotView: View {
    let repository: GoodPostRepository
    @State private var model: BrainRotAdminModel
    @State private var deletingRule: GoodPostBrainRotRule?
    @State private var openDemand: DemandKind?

    private enum DemandKind: String, Identifiable {
        case channel, keyword
        var id: String { rawValue }
    }

    init(repository: GoodPostRepository) {
        self.repository = repository
        _model = State(initialValue: BrainRotAdminModel(repository: repository))
    }

    var body: some View {
        VStack(spacing: 0) {
            // The four surfaces as TABS, not as filters.
            //
            // Drawn as filter pills they would read as four options among the rows rather than as
            // the structure of the screen, and an operator would have no way to tell which page they
            // were on without reading a chip's background. An underlined strip says "this screen has
            // four pages" at a glance.
            tabStrip

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let message = model.message {
                        CVErrorBanner(message: message) { Task { await model.loadAll() } }
                            .padding(.horizontal, 16)
                    }
                    switch model.tab {
                    case 0: dashboard
                    case 1: queue
                    case 2: rules
                    default: reports
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .refreshable { await model.loadAll() }
        }
        .background(Color.cvBackground)
        .navigationTitle("Shared blocklist")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadAll() }
        .sheet(item: $openDemand) { kind in
            DemandListSheet(
                title: kind == .channel ? "Most requested channels" : "Most requested keywords",
                rows: kind == .channel ? model.dashboard.topChannels : model.dashboard.topKeywords
            )
        }
        .confirmationDialog(
            "Delete this rule?",
            isPresented: Binding(get: { deletingRule != nil }, set: { if !$0 { deletingRule = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let rule = deletingRule { Task { await model.delete(rule) } }
                deletingRule = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stops applying to everyone. Disabling it instead keeps it here so it can be turned back on.")
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(brainRotTabs.enumerated()), id: \.offset) { index, label in
                    Button {
                        model.tab = index
                    } label: {
                        VStack(spacing: 8) {
                            Text(label)
                                .font(.system(size: 14, weight: model.tab == index ? .semibold : .regular))
                                .foregroundStyle(model.tab == index ? Color.cvOnSurface : Color.cvOnSurfaceVariant)
                                .lineLimit(1)
                            Rectangle()
                                .fill(model.tab == index ? GoodPostPalette.accent : Color.clear)
                                .frame(height: 2)
                        }
                        .padding(.horizontal, 16).padding(.top, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - Dashboard

    /// What is waiting, and what people are asking for.
    ///
    /// The counts come first because they are the question the page exists to answer — "how much is
    /// in my queue" — and the two demand cards follow, because they are the other half of a decision:
    /// which of those requests many people are making.
    @ViewBuilder
    private var dashboard: some View {
        Text("Dashboard")
            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.cvOnSurfaceVariant)
            .padding(.horizontal, 16)

        CVCard {
            VStack(spacing: 14) {
                HStack(spacing: 0) {
                    DashboardStat(label: "Pending", value: model.dashboard.pending)
                    DashboardStat(label: "Under review", value: model.dashboard.underReview)
                }
                // Two rows of two rather than four in a line: four labels across a phone leaves each
                // one about nine characters wide, so "Under review" is already clipped and the
                // numbers lose the labels that explain them.
                HStack(spacing: 0) {
                    DashboardStat(label: "Approved", value: model.dashboard.approved)
                    DashboardStat(label: "Rejected", value: model.dashboard.rejected)
                }
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total requests").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    Text("\(model.dashboard.total)").font(.title3.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)

        DemandCard(
            symbol: "play.circle",
            title: "MOST REQUESTED CHANNELS",
            rows: model.dashboard.topChannels
        ) { openDemand = .channel }
        DemandCard(
            symbol: "hand.raised.slash",
            title: "MOST REQUESTED KEYWORDS",
            rows: model.dashboard.topKeywords
        ) { openDemand = .keyword }

        if model.dashboardLoading && model.dashboard.total == 0 {
            ProgressView().frame(maxWidth: .infinity).padding(24)
        }
    }

    // MARK: - Review queue

    @ViewBuilder
    private var queue: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(brainRotQueueStatuses, id: \.wire) { status in
                    CVChip(title: status.label, selected: model.queueStatus == status.wire) {
                        Task { await model.selectQueueStatus(status.wire) }
                    }
                }
            }.padding(.horizontal, 16)
        }

        ForEach(model.submissions) { submission in
            SubmissionCard(submission: submission, busy: model.busy) { decision in
                Task { await model.review(submission, decision: decision) }
            }
            .padding(.horizontal, 16)
        }

        if model.submissions.isEmpty && !model.queueLoading {
            CVEmptyState(
                title: "Nothing to review",
                message: "Requests from the community appear here, oldest first.",
                symbol: "checkmark.circle"
            ).padding(.top, 24)
        }
    }

    // MARK: - Rules

    @ViewBuilder
    private var rules: some View {
        RulesSection(model: model, onDelete: { deletingRule = $0 })
    }

    // MARK: - False reports

    @ViewBuilder
    private var reports: some View {
        ForEach(model.reports, id: \.rowIdentity) { report in
            ReportCard(report: report, busy: model.busy) { resolution in
                Task { await model.answer(report, with: resolution) }
            }
            .padding(.horizontal, 16)
        }

        if model.reports.isEmpty && !model.reportsLoading {
            CVEmptyState(
                title: "Nothing reported",
                message: "When someone says a block was wrong, it appears here so you can keep the rule or remove it.",
                symbol: "exclamationmark.bubble"
            ).padding(.top, 24)
        }
    }
}

// MARK: - Pieces of the screen

private let brainRotTabs = ["Dashboard", "Review queue", "Rules", "False reports"]

/// What a row IS, for a list that has no id of its own.
///
/// A report and a demand are grouped by TARGET, so two rows can share a value only by being the
/// same target — which makes `kind` and `value` together the identity, and is also why neither type
/// carries an id the server never sends.
private extension GoodPostBrainRotReport {
    var rowIdentity: String { kind + ":" + value }
}

private extension GoodPostBrainRotDemand {
    var rowIdentity: String { kind + ":" + value }
}

/// Which queue a pill selects, and the words it shows.
private let brainRotQueueStatuses: [(wire: String, label: String)] = [
    ("pending", "Pending"),
    ("under_review", "Under review"),
    ("approved", "Approved"),
    ("rejected", "Rejected"),
    ("all", "All"),
]

/// One headline number with its label, centred in its tile.
private struct DashboardStat: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title3.weight(.semibold))
            Text(label).font(.system(size: 11)).foregroundStyle(Color.cvOnSurfaceVariant).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// One demand category, as a card that opens the whole list.
///
/// The card is deliberately one line: the category and how many targets are in it. The full list
/// deserves the whole screen rather than being squeezed under a header, and the chevron says "this
/// opens a screen".
private struct DemandCard: View {
    let symbol: String
    let title: String
    let rows: [GoodPostBrainRotDemand]
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            CVCard {
                HStack(spacing: 12) {
                    Image(systemName: symbol).font(.system(size: 17))
                        .foregroundStyle(GoodPostPalette.accent)
                        .frame(width: 36, height: 36)
                        .background(GoodPostPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(rows.isEmpty ? "No requests yet." : "\(rows.count) requested")
                            .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption)
                        .foregroundStyle(Color.cvOnSurfaceVariant)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }
}

/// Every target behind one demand card.
private struct DemandListSheet: View {
    let title: String
    let rows: [GoodPostBrainRotDemand]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if rows.isEmpty {
                        CVEmptyState(title: title, message: "No requests yet.", symbol: "tray")
                            .padding(.top, 24)
                    }
                    ForEach(rows, id: \.rowIdentity) { row in
                        CVCard {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 10) {
                                    Image(systemName: row.isChannel ? "play.circle" : "hand.raised.slash")
                                        .foregroundStyle(GoodPostPalette.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.displayName ?? row.value)
                                            .font(.system(size: 15, weight: .medium)).lineLimit(1)
                                        // The handle under a channel's name, so the identity is never
                                        // hidden by the display name.
                                        Text(row.isChannel && row.displayName != nil ? row.value : "Keyword")
                                            .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                                    }
                                    Spacer(minLength: 0)
                                    StatusPill(text: "\(row.reports) reports", tint: GoodPostPalette.accent)
                                }
                                // Two numbers, deliberately different: how many devices reported the
                                // target, and how many asked for it to be blocked for everyone.
                                Text("\(row.globalRequests) requests")
                                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 12)
            }
            .background(Color.cvBackground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(.cvPrimary)
    }
}

/// One suggestion: what it is, how many asked, and the three decisions.
private struct SubmissionCard: View {
    let submission: GoodPostBrainRotSubmission
    let busy: Bool
    let onDecide: (GoodPostBrainRotDecision) -> Void

    private var tint: Color {
        switch submission.status {
        case "approved": return GoodPostPalette.accent
        case "rejected": return Color.cvError
        case "under_review": return .orange
        default: return Color.cvOnSurfaceVariant
        }
    }

    private var statusLabel: String {
        switch submission.status {
        case "approved": return "Approved"
        case "rejected": return "Rejected"
        case "under_review": return "Under review"
        default: return "Pending"
        }
    }

    private var sourceLabel: String {
        switch submission.source {
        case "youtube_not_interested": return "From YouTube “Not interested”"
        case "app": return "Added in the app"
        default: return "Source not recorded"
        }
    }

    var body: some View {
        CVCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: submission.isChannel ? "play.circle" : "hand.raised.slash")
                        .foregroundStyle(GoodPostPalette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(submission.displayName ?? submission.value)
                            .font(.system(size: 15, weight: .medium)).lineLimit(1)
                        Text(submission.isChannel && submission.displayName != nil
                            ? submission.value
                            : sourceLabel)
                            .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    StatusPill(text: statusLabel, tint: tint)
                }

                // The two demand numbers, on the row they decide. One person asking and two hundred
                // devices asking are very different cases, and a reviewer should not have to leave
                // the screen to tell them apart.
                if submission.reports > 0 || submission.requesters > 0 {
                    Text("\(submission.reports) reports  ·  \(submission.requesters) requests")
                        .font(.caption).foregroundStyle(GoodPostPalette.accent)
                }

                if let note = submission.note?.trimmed, !note.isEmpty {
                    Text(note).font(.system(size: 13)).foregroundStyle(Color.cvOnSurfaceVariant)
                }

                if submission.isOpen {
                    HStack(spacing: 4) {
                        TextAction(title: "Approve", enabled: !busy) { onDecide(.approve) }
                        TextAction(title: "Reject", destructive: true, enabled: !busy) { onDecide(.reject) }
                        TextAction(
                            title: "Mark under review",
                            enabled: !busy && submission.status == "pending"
                        ) { onDecide(.underReview) }
                    }
                } else {
                    // An already-decided row says so rather than offering the buttons again: the
                    // server refuses a second review, and a button that can only fail is worse than
                    // a label.
                    Text(statusLabel).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }
            }
        }
    }
}

/// The rules, and the way to add one.
private struct RulesSection: View {
    let model: BrainRotAdminModel
    let onDelete: (GoodPostBrainRotRule) -> Void
    /// Purely a disclosure, so it is screen state: nothing outside this page can see it, and nothing
    /// has to survive a reload to keep the rules correct.
    @State private var addOpen = false

    var body: some View {
        // Adding is behind ONE action, closed by default: two always-open text fields above the lists
        // they add to open the page on a form rather than on the rules, and a form nobody came to
        // fill in is two fields of noise in front of the thing they did come for.
        Button {
            addOpen.toggle()
        } label: {
            Text(addOpen ? "Hide" : "Add a rule")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(model.busy)

        if addOpen {
            AddRuleCard(
                label: "Add a keyword",
                hint: "e.g. brainrot",
                text: Binding(get: { model.newKeyword }, set: { model.newKeyword = $0 }),
                busy: model.busy
            ) { Task { await model.addKeyword() } }

            AddRuleCard(
                label: "Add a channel",
                hint: "@examplechannel",
                text: Binding(get: { model.newChannel }, set: { model.newChannel = $0 }),
                busy: model.busy
            ) { Task { await model.addChannel() } }
        }

        SectionHeading("KEYWORDS")
        ForEach(model.keywords) { rule in
            RuleCard(rule: rule, busy: model.busy) { enabled in
                Task { await model.setEnabled(rule, enabled: enabled) }
            } onDelete: {
                onDelete(rule)
            }
        }

        SectionHeading("CHANNELS")
        ForEach(model.channels) { rule in
            RuleCard(rule: rule, busy: model.busy) { enabled in
                Task { await model.setEnabled(rule, enabled: enabled) }
            } onDelete: {
                onDelete(rule)
            }
        }

        if model.keywords.isEmpty && model.channels.isEmpty && !model.rulesLoading {
            CVEmptyState(
                title: "No shared rules",
                message: "Add a keyword or a channel to protect everyone.",
                symbol: "shield"
            ).padding(.top, 24)
        }
    }
}

/// One rule: its value, whether it is in force, and how to remove it.
private struct RuleCard: View {
    let rule: GoodPostBrainRotRule
    let busy: Bool
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    var body: some View {
        CVCard {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.slash").foregroundStyle(GoodPostPalette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.value).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Text(rule.reason?.trimmed.isEmpty == false
                        ? rule.reason!.trimmed
                        : (rule.enabled ? "Enforced for everyone" : "Switched off — not enforced"))
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant).lineLimit(2)
                    if rule.reports > 0 {
                        Text("\(rule.reports) reports")
                            .font(.caption).foregroundStyle(GoodPostPalette.accent)
                    }
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { rule.enabled }, set: { onToggle($0) }))
                    .labelsHidden()
                    .disabled(busy)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityLabel("Delete \(rule.value)")
            }
        }
        .padding(.horizontal, 16)
    }
}

/// A field and an Add button, for adding a rule directly.
private struct AddRuleCard: View {
    let label: String
    let hint: String
    @Binding var text: String
    let busy: Bool
    let onAdd: () -> Void

    var body: some View {
        CVCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(label).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                TextField(hint, text: $text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(busy)
                    .padding(12)
                    .background(Color.cvBackground, in: RoundedRectangle(cornerRadius: 12))
                Button("Add", action: onAdd)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || text.trimmed.isEmpty)
            }
        }
        .padding(.horizontal, 16)
    }
}

/// One reported target, with the answers an operator can give.
private struct ReportCard: View {
    let report: GoodPostBrainRotReport
    let busy: Bool
    let onAnswer: (GoodPostBrainRotResolution) -> Void

    var body: some View {
        CVCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: report.isChannel ? "play.circle" : "hand.raised.slash")
                        .foregroundStyle(GoodPostPalette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.displayName ?? report.value)
                            .font(.system(size: 15, weight: .medium)).lineLimit(1)
                        Text(report.isChannel && report.displayName != nil ? report.value : "Keyword")
                            .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                    Spacer(minLength: 0)
                    StatusPill(text: "\(report.reports) reports", tint: GoodPostPalette.accent)
                }

                // Which rule the decision is about, said before the buttons rather than after it:
                // the two answers do opposite things, and only one of them is available when nothing
                // matches.
                Text(report.hasRule
                    ? "This term matches a global rule. Keeping it leaves the rule enforcing; stopping it switches the rule off for everyone."
                    : "No global rule matches this term — it came from someone's own keyword or a strict-mode match. Dismissing only clears the report.")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)

                if let detail = report.detail?.trimmed, !detail.isEmpty {
                    // Free text, so it is quoted rather than presented as fact.
                    Text("“\(detail)”").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }

                HStack(spacing: 4) {
                    // Spelled out rather than an "Approve"/"Reject" pair: the words say what happens
                    // to the block, which is the only thing either answer changes. Which of them is
                    // offered comes from the one rule that decides it, so a term with no rule can
                    // never present a button that would quietly do nothing.
                    ForEach(brainRotReportAnswers(hasRule: report.hasRule), id: \.self) { answer in
                        TextAction(
                            title: brainRotAnswerLabel(answer, hasRule: report.hasRule),
                            destructive: answer == .stop,
                            enabled: !busy
                        ) { onAnswer(answer) }
                    }
                }
            }
        }
    }
}

/// A small label saying whether a decision is open or settled.
private struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
            .lineLimit(1)
    }
}

/// A word that acts, with no button chrome.
private struct TextAction: View {
    let title: String
    var destructive = false
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(destructive ? Color.cvError : GoodPostPalette.accent)
                .padding(.horizontal, 10).frame(minHeight: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct SectionHeading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.cvOnSurfaceVariant)
            .padding(.horizontal, 16).padding(.top, 6)
    }
}

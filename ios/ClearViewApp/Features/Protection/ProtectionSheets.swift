import SwiftUI

/// The manager screens the Protection cards open.
///
/// Each one is the whole screen for one list: the add field at the top, then the entries,
/// then — where the shared blocklist is involved — the two groups that are *not* the
/// user's own blocks (what is waiting for review, and what is live for everyone).
///
/// Keeping those apart is what makes the list honest. A pending request sitting among
/// real blocks reads as a rule already in force; a global rule sitting in the user's own
/// list makes its Remove button a lie. The user's list holds only what the user put
/// there.

// ── YouTube Protection: keywords ─────────────────────────────────────

struct ProtectionKeywordsSheet: View {
    let model: ProtectionModel
    @State private var draft = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProtectionQueuedGroup(
                items: model.store.pendingSubmissions(kind: "keyword"),
                symbol: "flask"
            )
            ProtectionApprovedGroup(
                items: model.store.approvedSubmissions(kind: "keyword"),
                symbol: "flask"
            )
            ProtectionAddField(
                text: $draft,
                placeholder: "e.g. a phrase you keep seeing",
                identifier: "protection.add-keyword",
                addIdentifier: "protection.add-keyword-button"
            ) {
                guard model.addYouTubeKeyword(draft) else { return }
                draft = ""
                message = nil
            }

            if model.youTubeKeywords.isEmpty {
                Text("No keywords yet. Add one above.")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            } else {
                ForEach(model.youTubeKeywords, id: \.self) { keyword in
                    ProtectionListRow(
                        label: keyword,
                        symbol: "flask",
                        subtitle: subtitle(for: keyword),
                        onSend: canSend(keyword) ? { send(keyword) } : nil,
                        onRemove: { model.removeYouTubeKeyword(keyword) }
                    )
                }
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    .accessibilityIdentifier("protection.keyword-message")
            }

            Text("These keywords apply to YouTube content only — a word added here never blocks a website.")
                .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
        }
    }

    private func subtitle(for keyword: String) -> String? {
        if model.isQueuedForReview(kind: "keyword", value: keyword) { return "Queued for review" }
        if model.isApprovedGlobally(kind: "keyword", value: keyword) { return "Approved globally" }
        if model.isRemovedGlobally(kind: "keyword", value: keyword) { return "Removed" }
        return nil
    }

    /// The Send action disappears once a value is queued or approved, so the same request
    /// cannot be sent twice from the list it came from.
    private func canSend(_ keyword: String) -> Bool {
        model.sharedListAvailable && model.submissionStatus(kind: "keyword", value: keyword) == nil
    }

    private func send(_ keyword: String) {
        Task {
            let ok = await model.submitKeywordToGlobal(keyword)
            message = ok ? "Sent for review" : "Could not reach the server. Nothing changed."
        }
    }
}

// ── YouTube Protection: channels ─────────────────────────────────────

struct ProtectionChannelsSheet: View {
    let model: ProtectionModel
    @State private var draft = ""
    @State private var search = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProtectionQueuedGroup(items: model.store.pendingSubmissions(kind: "channel"), symbol: "play.rectangle")
            ProtectionApprovedGroup(items: model.store.approvedSubmissions(kind: "channel"), symbol: "play.rectangle")
            ProtectionAddField(
                text: $draft,
                placeholder: "@channelhandle",
                identifier: "protection.add-channel",
                addIdentifier: "protection.add-channel-button"
            ) {
                if model.addBlockedChannel(draft) {
                    draft = ""
                    message = nil
                } else {
                    message = "Enter a channel handle like @examplechannel."
                }
            }

            // A search field only once the list is long enough to need one, as on Android.
            if model.blockedChannels.count > 5 {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.cvOnSurfaceVariant)
                    TextField("Search blocked channels", text: $search)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("protection.channel-search")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(10)
                .background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 12))
            }

            let visible = model.filteredChannels(search: search)
            if visible.isEmpty {
                Text(model.blockedChannels.isEmpty
                     ? "No channels blocked yet. Add one below."
                     : "No channel matches that search.")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            } else {
                ForEach(visible) { channel in
                    ProtectionListRow(
                        label: channel.handle,
                        symbol: "play.rectangle",
                        subtitle: subtitle(for: channel),
                        onSend: canSend(channel) ? { send(channel) } : nil,
                        onRemove: { model.removeBlockedChannel(channel.handle) }
                    )
                }
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    .accessibilityIdentifier("protection.channel-message")
            }

            Text("Channels are stored by their @handle, so a rename of the channel name never loses the block.")
                .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
        }
    }

    private func subtitle(for channel: BlockedChannel) -> String? {
        if model.isQueuedForReview(kind: "channel", value: channel.handle) { return "Queued for review" }
        if model.isApprovedGlobally(kind: "channel", value: channel.handle) { return "Approved globally" }
        if model.isRemovedGlobally(kind: "channel", value: channel.handle) { return "Removed" }
        return channel.name?.nilWhenBlank ?? "My block"
    }

    private func canSend(_ channel: BlockedChannel) -> Bool {
        model.sharedListAvailable && model.submissionStatus(kind: "channel", value: channel.handle) == nil
    }

    private func send(_ channel: BlockedChannel) {
        Task {
            let ok = await model.submitChannelToGlobal(channel.handle, name: channel.name)
            message = ok ? "Sent for review" : "Could not reach the server. Nothing changed."
        }
    }
}

// ── My blocked items: keywords and websites ──────────────────────────

struct ProtectionBlockedItemsSheet: View {
    let model: ProtectionModel
    @State private var keyword = ""
    @State private var website = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your own keywords and websites. These apply to everything ClearView shows you.")
                .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)

            ProtectionAddField(
                text: $keyword,
                placeholder: "e.g. instagram, tiktok",
                identifier: "protection.add-item-keyword",
                addIdentifier: "protection.add-item-keyword-button"
            ) {
                _ = model.addUserKeyword(keyword)
                keyword = ""
            }
            if model.userKeywords.isEmpty {
                Text("No keywords yet.")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            } else {
                ForEach(model.userKeywords, id: \.self) { entry in
                    ProtectionListRow(
                        label: entry,
                        symbol: "text.badge.xmark",
                        subtitle: nil,
                        onSend: nil,
                        onRemove: { model.removeUserKeyword(entry) }
                    )
                }
            }

            ProtectionSectionHeading("Websites")
            ProtectionAddField(
                text: $website,
                placeholder: "e.g. youtube.com, reddit.com",
                identifier: "protection.add-website",
                addIdentifier: "protection.add-website-button"
            ) {
                if model.addBlockedDomain(website) {
                    website = ""
                    message = nil
                } else {
                    message = "Enter a website like example.com."
                }
            }
            if model.blockedDomains.isEmpty {
                Text("No websites yet.")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            } else {
                ForEach(model.blockedDomains, id: \.self) { domain in
                    ProtectionListRow(
                        label: domain,
                        symbol: "network.slash",
                        subtitle: nil,
                        onSend: nil,
                        onRemove: { model.removeBlockedDomain(domain) }
                    )
                }
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    .accessibilityIdentifier("protection.website-message")
            }

            Text("The adult website preset is always on and cannot be edited here; it is listed for transparency only.")
                .font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
        }
    }
}

// ── The shared blocklist ─────────────────────────────────────────────

struct ProtectionSharedListSheet: View {
    let model: ProtectionModel
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.sharedListAvailable {
                Text("This build has no server configured, so the shared blocklist is unavailable. Your own rules still apply.")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            } else {
                Button {
                    Task {
                        await model.syncGlobalRules()
                        message = model.hasGlobalSnapshot
                            ? "Shared blocklist up to date"
                            : "Could not reach the server. Your own rules still apply."
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 13))
                        Text(model.isSyncing ? "Checking…" : "Check for updates")
                            .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cvOutline, lineWidth: 1))
                }
                .disabled(model.isSyncing)
                .accessibilityIdentifier("protection.sync-shared")

                if let message {
                    Text(message).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }

                Text("Approved keywords")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.cvOnSurfaceVariant)
                if model.globalKeywords.isEmpty {
                    Text("No shared keywords yet.").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                } else {
                    ForEach(model.globalKeywords, id: \.self) { keyword in
                        ProtectionReadOnlyRow(label: keyword, symbol: "nosign")
                    }
                }

                Text("Approved channels")
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.cvOnSurfaceVariant)
                    .padding(.top, 6)
                if model.globalChannels.isEmpty {
                    Text("No shared channels yet.").font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                } else {
                    ForEach(model.globalChannels, id: \.self) { handle in
                        ProtectionReadOnlyRow(label: handle, symbol: "play.rectangle")
                    }
                }

                Text("ClearView keeps these, and they apply to everyone automatically — alongside your own rules.")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    .padding(.top, 6)
            }
        }
    }
}

struct ProtectionRequestsSheet: View {
    let model: ProtectionModel
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                Task {
                    await model.refreshSubmissions()
                    message = "Requests refreshed from the server."
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13))
                    Text("Refresh").font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cvOutline, lineWidth: 1))
            }
            .disabled(model.isLoadingSubmissions || !model.sharedListAvailable)
            .accessibilityIdentifier("protection.refresh-requests")

            if let message {
                Text(message).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            }

            if model.submissions.isEmpty {
                Text("You have not submitted anything for review yet. Use the send button on a keyword or channel to ask for it to be blocked for everyone.")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.submissions) { submission in
                    ProtectionSubmissionRow(
                        submission: submission,
                        status: model.displayStatus(of: submission)
                    )
                }
            }

            Text("Requests you sent to block something for everyone. An administrator reviews each one before it applies.")
                .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
        }
    }
}

// ── Activity ─────────────────────────────────────────────────────────

struct ProtectionActivitySheet: View {
    let model: ProtectionModel
    @State private var typedToConfirm = ""
    @State private var confirmingClear = false

    var body: some View {
        let summary = model.activitySummary
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProtectionStatCell(label: "Today", value: "\(summary.todayBlocks)")
                ProtectionStatCell(label: "This week", value: "\(summary.weekBlocks)")
                ProtectionStatCell(label: "Content blocked", value: "\(summary.totalBlocks)")
            }

            if summary.streakDays > 0 {
                Text(summary.streakDays == 1 ? "1 day protected" : "\(summary.streakDays) days protected")
                    .font(.caption)
                    .foregroundStyle(Color.cvPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.cvPrimary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            }

            if !summary.topKeywords.isEmpty {
                Text("Most blocked").font(.caption.weight(.semibold)).foregroundStyle(Color.cvPrimary)
                ForEach(summary.topKeywords, id: \.keyword) { entry in
                    ProtectionActivityRow(label: entry.keyword, count: "\(entry.count)")
                }
            }

            if !summary.topChannels.isEmpty {
                Text("Top blocked channel").font(.caption.weight(.semibold)).foregroundStyle(Color.cvPrimary)
                    .padding(.top, 4)
                ForEach(summary.topChannels, id: \.channel) { entry in
                    ProtectionActivityRow(label: entry.channel, count: "\(entry.count)")
                }
            }

            if summary.totalBlocks == 0 {
                Text("Nothing blocked yet. Protection is watching.")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            }

            Divider().padding(.top, 4)

            if confirmingClear {
                Text("This erases your whole protection history: the counters, the streak and the most-triggered lists. It cannot be undone.")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Type clear to confirm", text: $typedToConfirm)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("protection.clear-confirm-field")
                HStack(spacing: 10) {
                    Button("Reset") {
                        model.clearActivity()
                        typedToConfirm = ""
                        confirmingClear = false
                    }
                    .foregroundStyle(Color.cvError)
                    .disabled(typedToConfirm.trimmed.lowercased() != "clear")
                    .accessibilityIdentifier("protection.clear-confirm")
                    Button("Cancel") {
                        confirmingClear = false
                        typedToConfirm = ""
                    }
                    .foregroundStyle(Color.cvOnSurfaceVariant)
                }
            } else {
                Button("Reset activity") { confirmingClear = true }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.cvError)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cvOutline, lineWidth: 1))
                    .accessibilityIdentifier("protection.clear-activity")
            }
        }
    }
}

// ── Notifications ────────────────────────────────────────────────────

struct ProtectionNotificationsSheet: View {
    let model: ProtectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Mark all read") { model.markAllNotificationsRead() }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("protection.mark-all-read")
                Button("Clear all") { model.clearNotifications() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.cvError)
                    .accessibilityIdentifier("protection.clear-notifications")
                Spacer()
            }

            if model.notifications.isEmpty {
                Text("Nothing yet. Blocking something will show up here.")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
            } else {
                ForEach(model.notifications) { item in
                    Button {
                        model.markNotificationRead(item.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.message)
                                .font(.caption)
                                .foregroundStyle(item.read ? Color.cvOnSurfaceVariant : Color.cvOnSurface)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                            Text(relativeTime(item.atMs))
                                .font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            item.read ? Color.cvSurfaceContainerLow : Color.cvPrimary.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// A short "how long ago" for a row. Plain arithmetic on the two instants, so a test
    /// can pin the wording without a clock.
    private func relativeTime(_ atMs: Int64) -> String {
        let seconds = max(0, (ProtectionStore.nowMs() - atMs) / 1000)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

// ── Shared pieces ────────────────────────────────────────────────────

/// One value in a list: a glyph, the value on a single line, then its actions.
///
/// The text is always one ellipsised line and the actions are fixed-size buttons, so a
/// long value can never wrap one character per line or sit on top of its own buttons.
struct ProtectionListRow: View {
    let label: String
    let symbol: String
    var subtitle: String?
    var onSend: (() -> Void)?
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Color.cvOnSurfaceVariant)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle, !subtitle.isBlank {
                    Text(subtitle).font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let onSend {
                Button(action: onSend) { Image(systemName: "paperplane") }
                    .foregroundStyle(Color.cvPrimary)
                    .accessibilityLabel("Ask to block \(label) for everyone")
            }
            Button(action: onRemove) { Image(systemName: "xmark") }
                .foregroundStyle(Color.cvOnSurfaceVariant)
                .accessibilityLabel("Remove \(label)")
                .accessibilityIdentifier("protection.remove-\(label)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.cvSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A rule the user cannot edit — the shared blocklist's own entries.
struct ProtectionReadOnlyRow: View {
    let label: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 14))
                .foregroundStyle(Color.cvOnSurfaceVariant)
            Text(label).font(.subheadline.weight(.medium)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.cvSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// The two groups a manager screen shows above the user's own list: waiting on a
/// decision, and live for everyone. Both are read-only, and neither is a block of the
/// user's own — which is exactly why they are drawn separately.
struct ProtectionQueuedGroup: View {
    let items: [ProtectionSubmission]
    let symbol: String

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Queued for review")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.08, green: 0.40, blue: 0.75))
                Text("Waiting on an administrator. Not blocking anyone yet.")
                    .font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                ForEach(items) { submission in
                    HStack(spacing: 10) {
                        Image(systemName: symbol).font(.system(size: 13))
                            .foregroundStyle(Color(red: 0.08, green: 0.40, blue: 0.75))
                        Text(submission.displayName ?? submission.value)
                            .font(.subheadline.weight(.medium)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ProtectionStatusPill(status: submission.status)
                    }
                    .padding(.vertical, 3)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.08, green: 0.40, blue: 0.75).opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct ProtectionApprovedGroup: View {
    let items: [ProtectionSubmission]
    let symbol: String

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Approved globally")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(red: 0.18, green: 0.49, blue: 0.20))
                Text("Live for every ClearView user. You do not need to send it again.")
                    .font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                ForEach(items) { submission in
                    HStack(spacing: 10) {
                        Image(systemName: symbol).font(.system(size: 13))
                            .foregroundStyle(Color(red: 0.18, green: 0.49, blue: 0.20))
                        Text(submission.displayName ?? submission.value)
                            .font(.subheadline.weight(.medium)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ProtectionStatusPill(status: "approved")
                    }
                    .padding(.vertical, 3)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.18, green: 0.49, blue: 0.20).opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

struct ProtectionSubmissionRow: View {
    let submission: ProtectionSubmission
    let status: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: submission.kind == "channel" ? "play.rectangle" : "nosign")
                .font(.system(size: 15)).foregroundStyle(Color.cvOnSurfaceVariant)
            Text(submission.displayName ?? submission.value)
                .font(.subheadline.weight(.medium)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            ProtectionStatusPill(status: status)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.cvSurfaceContainerLow, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ProtectionStatusPill: View {
    let status: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(colour)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(colour.opacity(0.14), in: Capsule())
    }

    private var label: String {
        switch status {
        case SubmissionStatus.approved: return "Approved — blocked for everyone"
        case SubmissionStatus.rejected: return "Rejected"
        case "under_review": return "Under review"
        case SubmissionStatus.removed: return "Removed"
        default: return "Pending review"
        }
    }

    private var colour: Color {
        switch status {
        case SubmissionStatus.approved: return Color(red: 0.18, green: 0.49, blue: 0.20)
        case SubmissionStatus.rejected: return Color.cvError
        case "under_review": return Color(red: 0.08, green: 0.40, blue: 0.75)
        default: return Color.cvOnSurfaceVariant
        }
    }
}

/// One rounded row holding an input and its add button.
struct ProtectionAddField: View {
    @Binding var text: String
    let placeholder: String
    var identifier: String
    var addIdentifier: String
    var onAdd: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { if !text.isBlank { onAdd() } }
                .accessibilityIdentifier(identifier)
                .padding(.vertical, 10)
            Button(action: onAdd) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.cvOnPrimary)
                    .frame(width: 34, height: 34)
                    .background(text.isBlank ? Color.cvSurfaceVariant : Color.cvPrimary, in: Circle())
            }
            .disabled(text.isBlank)
            .accessibilityLabel("Add")
            .accessibilityIdentifier(addIdentifier)
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ProtectionStatCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold))
            Text(label).font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ProtectionActivityRow: View {
    let label: String
    let count: String

    var body: some View {
        HStack {
            Text(label).font(.subheadline).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(count)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.cvOnSurfaceVariant)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Color.cvSurfaceContainer, in: Capsule())
        }
        .padding(.vertical, 3)
    }
}

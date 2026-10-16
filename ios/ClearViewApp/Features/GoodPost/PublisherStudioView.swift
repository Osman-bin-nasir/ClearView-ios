import SwiftUI
import UniformTypeIdentifiers

/// The publishing surface: the way in (§16), and what an account that is already signed in runs.
///
/// It is one sheet with three states rather than three screens, because the tab behind it is where
/// the channels live — an administrator who signs in is not taken somewhere else, the list under
/// this sheet simply becomes theirs. `startCreating` is what makes "Create a channel" mean the same
/// thing whether the account is signed in or not: signed out it is the sign-in, signed in it is the
/// form.
struct PublisherStudioView: View {
    let repository: GoodPostRepository
    /// True when the tab's "Create a channel" opened this, so a session lands on the form rather
    /// than on a list of channels the account already runs.
    var startCreating = false
    /// Told the session that landed and, when the account was already here, its address.
    var onLanded: (AdminSession, String?) -> Void = { _, _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var session: AdminSession?
    @State private var channels: [GoodPostChannel] = []
    @State private var message: String?
    @State private var busy = false
    @State private var creating = false
    @State private var restoring = true

    var body: some View {
        NavigationStack {
            Group {
                if restoring {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let session {
                    dashboard(session)
                } else {
                    // The sign-in screen owns the whole sheet: it is the only place in the tab that
                    // asks anybody who they are, and a chrome of its own around it would say this is
                    // one step of a larger thing, which to a reader it is not.
                    AdminSignInView(repository: repository) { landed, welcome in
                        session = landed
                        onLanded(landed, welcome)
                        if startCreating { creating = true }
                    }
                }
            }
            .background(Color.cvBackground)
            .navigationTitle(session == nil ? "Create a channel" : "Publisher studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(session == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .task {
                session = await repository.adminSession()
                if session != nil {
                    if startCreating { creating = true }
                    await loadChannels()
                }
                restoring = false
            }
            .sheet(isPresented: $creating, onDismiss: { Task { await loadChannels() } }) {
                ChannelFormView(channel: nil, isSuperAdmin: true, repository: repository) { created in
                    if !channels.contains(where: { $0.id == created.id }) { channels.append(created) }
                }
            }
        }
        .tint(.cvPrimary)
    }

    private func dashboard(_ session: AdminSession) -> some View {
        List {
            Section { LabeledContent("Signed in", value: session.email) }
            if let message { Section { CVErrorBanner(message: message) { Task { await loadChannels() } } } }
            Section("Your channels") {
                ForEach(channels) { channel in
                    NavigationLink { PublisherChannelView(channel: channel, repository: repository) } label: {
                        HStack { CVAvatar(name: channel.name, url: channel.iconUrl); Text(channel.name).font(.headline) }
                    }
                }
                if busy { ProgressView() }
                if channels.isEmpty && !busy { Text("No channels are assigned to this account.") }
                if session.isSuperAdmin { Button("Create a channel", systemImage: "plus") { creating = true } }
            }
            Section {
                Button("Sign out", role: .destructive) {
                    Task {
                        await repository.revokeAdminSession(refreshToken: session.refreshToken)
                        await repository.forgetAdminSession()
                        self.session = nil
                        channels = []
                    }
                }
            }
        }.scrollContentBackground(.hidden).refreshable { await loadChannels() }
    }

    private func loadChannels() async {
        busy = true
        let result = await repository.adminChannels()
        if let value = result.value { channels = value; message = nil }
        else { message = result.userMessage }
        busy = false
    }
}

struct PublisherChannelView: View {
    let channel: GoodPostChannel
    let repository: GoodPostRepository
    @State private var posts: [GoodPostPost] = []
    @State private var composing = false
    @State private var deleting: GoodPostPost?
    @State private var message: String?

    var body: some View {
        List {
            if let message { CVErrorBanner(message: message) }
            Section {
                Button("Write an update", systemImage: "square.and.pencil") { composing = true }
            }
            Section("Recent posts") {
                ForEach(posts) { post in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(post.body ?? post.linkTitle ?? "Media post").lineLimit(4)
                        Text(String(post.createdAt.prefix(10))).font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    }.swipeActions {
                        Button("Delete", role: .destructive) { deleting = post }
                    }
                }
            }
        }.navigationTitle(channel.name).task { await load() }.refreshable { await load() }
            .sheet(isPresented: $composing, onDismiss: { Task { await load() } }) { PostComposerView(channel: channel, repository: repository) }
            .confirmationDialog("Delete this post for everyone?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete post", role: .destructive) {
                    if let post = deleting {
                        Task {
                            let result = await repository.adminDeletePost(postId: post.id)
                            if result.isOk { await load() } else { message = result.userMessage }
                        }
                    }
                    deleting = nil
                }
            }
    }

    private func load() async {
        let result = await repository.channelPosts(channelId: channel.id)
        if let page = result.value { posts = page.items; message = nil }
        else { message = result.userMessage }
    }
}

struct PostComposerView: View {
    let channel: GoodPostChannel
    let repository: GoodPostRepository
    /// The draft the channel feed's strip already holds, when this was opened from it.
    ///
    /// The strip is an editable field, so the pencil beside it is not a way in from nothing — it is
    /// the same draft given the whole screen. Starting a new post here would have deleted the line
    /// the reader had just typed.
    let initialText: String
    /// Told when a post actually published, so the strip can clear the draft it was holding.
    let onPublished: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var link = ""
    @State private var attachments: [GoodPostMedia] = []
    @State private var showFiles = false
    @State private var busy = false
    @State private var message: String?
    @State private var confirmPublish = false

    init(
        channel: GoodPostChannel,
        repository: GoodPostRepository,
        initialText: String = "",
        onPublished: (() -> Void)? = nil
    ) {
        self.channel = channel
        self.repository = repository
        self.initialText = initialText
        self.onPublished = onPublished
        _text = State(initialValue: initialText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Posting to \(channel.name)") {
                    TextField("Share something good…", text: $text, axis: .vertical).lineLimit(8...16)
                    Text("\(text.count) / 4000").font(.caption).foregroundStyle(text.count > 4000 ? Color.cvError : Color.cvOnSurfaceVariant)
                    TextField("Link (optional)", text: $link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("Attachments") {
                    ForEach(attachments) { media in
                        HStack {
                            Label(media.fileName ?? media.kind.capitalized, systemImage: media.isImage ? "photo" : "doc")
                            Spacer()
                            Button(role: .destructive) { attachments.removeAll { $0.id == media.id } } label: { Image(systemName: "xmark.circle") }
                        }
                    }
                    Button("Attach a file", systemImage: "paperclip") { showFiles = true }.disabled(busy || attachments.count >= 4)
                    if busy { ProgressView("Please wait…") }
                }
                if let message { Section { Text(message).foregroundStyle(Color.cvError) } }
            }.navigationTitle("New post").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Publish") { confirmPublish = true }.disabled(busy || text.count > 4000 || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && link.isEmpty && attachments.isEmpty))
                    }
                }
                .interactiveDismissDisabled(busy)
                .confirmationDialog("Publish to \(channel.name)?", isPresented: $confirmPublish, titleVisibility: .visible) {
                    Button("Publish post") { Task { await publish() } }
                }
                .fileImporter(isPresented: $showFiles, allowedContentTypes: [.jpeg, .png, .gif, .mpeg4Movie, .pdf], allowsMultipleSelection: false) { result in
                    if case .success(let urls) = result, let url = urls.first { Task { await upload(url) } }
                    else if case .failure = result { message = "Couldn't open that file." }
                }
        }.tint(.cvPrimary)
    }

    private func publish() async {
        guard link.isEmpty || BrowserDestination(link) != nil else { message = "Enter a valid http or https link."; return }
        busy = true
        var body: [String: Any] = ["body": text, "mediaIds": attachments.map(\.id)]
        if !link.isEmpty { body["linkUrl"] = link }
        let result = await repository.adminCreatePost(channelId: channel.id, body: body)
        busy = false
        if result.isOk {
            onPublished?()
            dismiss()
        } else {
            message = result.userMessage
        }
    }

    private func upload(_ url: URL) async {
        busy = true
        defer { busy = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            guard (values.fileSize ?? 0) <= 104_857_600 else { message = "Choose a file smaller than 100 MB."; return }
            guard let attachment = await readGoodPostAttachment(at: url, declaredContentType: values.contentType?.preferredMIMEType) else {
                message = "This file is empty or its format isn't supported."
                return
            }
            let result = await repository.adminUploadMedia(attachment: attachment)
            if let media = result.value { attachments.append(media); message = nil }
            else { message = result.userMessage }
        } catch { message = "Couldn't read this file. Please select it again." }
    }
}

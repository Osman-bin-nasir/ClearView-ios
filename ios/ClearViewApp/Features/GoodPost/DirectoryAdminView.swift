import SwiftUI

/// The external channel directory, as a super administrator maintains it.
///
/// # Three levels, walked one at a time
///
/// Categories, then the subcategories inside one, then the channels inside one. A single page
/// holding all of it at once was the wrong shape for two reasons: a list of five categories with
/// four channels each is thirty rows deep on a phone, and adding a channel meant picking its filing
/// out of a scrolling strip of every category and subcategory in the product. Drilled down, WHERE
/// the channel goes is the page you are standing on — so the form no longer has to ask.
///
/// # One control per row
///
/// Every row carries exactly one `⋮`. The destructive and the rare live behind it; the one action
/// worth keeping on the surface is that level's own "add", which is the `+` in the bar so it is
/// reachable without scrolling to the bottom of a list.
///
/// # It re-reads after every write
///
/// Nothing reconstructs the list from what it sent: a successful change is followed by a fresh
/// read, so the screen cannot disagree with the server about what is filed where.
///
/// # The authority is the server's
///
/// Only a super administrator is offered the way in, but that is a convenience. Every route behind
/// this screen is refused to anybody else on the server.
@MainActor
@Observable
final class DirectoryAdminModel {
    let repository: GoodPostRepository
    private(set) var snapshot = DirectorySnapshot()
    private(set) var loading = false
    private(set) var busy = false
    var message: String?

    init(repository: GoodPostRepository) {
        self.repository = repository
    }

    /// The whole directory, from the administrator's own read.
    ///
    /// The stored copy is drawn first when there is one, so opening the manager offline shows the
    /// list it was last left in rather than an empty screen — and the live read replaces it.
    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        if snapshot.isEmpty, let cached = await repository.cachedDirectory() {
            snapshot = cached.snapshot
        }
        let result = await repository.adminDirectory()
        if let fresh = result.value {
            snapshot = fresh
            message = nil
        } else {
            message = result.userMessage
        }
    }

    func createCategory(_ name: String) async {
        await write { await self.repository.adminCreateDirectoryCategory(name: name) }
    }

    func rename(categoryId: String, name: String) async {
        await write { await self.repository.adminUpdateDirectoryCategory(categoryId: categoryId, name: name) }
    }

    func delete(categoryId: String) async {
        await write { await self.repository.adminDeleteDirectoryCategory(categoryId: categoryId) }
    }

    func createSubcategory(categoryId: String, name: String) async {
        await write {
            await self.repository.adminCreateDirectorySubcategory(categoryId: categoryId, name: name)
        }
    }

    func rename(subcategoryId: String, name: String) async {
        await write { await self.repository.adminUpdateDirectorySubcategory(subcategoryId: subcategoryId, name: name) }
    }

    func delete(subcategoryId: String) async {
        await write { await self.repository.adminDeleteDirectorySubcategory(subcategoryId: subcategoryId) }
    }

    func addChannel(platform: String, handle: String, categoryId: String?, subcategoryId: String?) async {
        await write {
            await self.repository.adminCreateDirectoryChannel(
                platform: platform,
                handle: handle,
                categoryId: categoryId,
                subcategoryId: subcategoryId
            )
        }
    }

    func updateChannel(channelId: String, name: String?, categoryId: String?, subcategoryId: String?) async {
        await write {
            await self.repository.adminUpdateDirectoryChannel(
                channelId: channelId,
                name: name,
                categoryId: categoryId,
                subcategoryId: subcategoryId
            )
        }
    }

    /// Ask the server to copy the platform's own name and picture for one row.
    func fetchNameAndIcon(channelId: String) async {
        await write { await self.repository.adminRefreshDirectoryChannel(channelId: channelId) }
    }

    func delete(channelId: String) async {
        await write { await self.repository.adminDeleteDirectoryChannel(channelId: channelId) }
    }

    /// One write, then the list again.
    ///
    /// The re-read happens on success only: a write that was refused changed nothing, so a second
    /// round trip would be spent confirming what the refusal already said.
    private func write(_ action: () async -> ApiResult<Void>) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let result = await action()
        guard result.isOk else {
            message = result.userMessage
            return
        }
        message = nil
        let fresh = await repository.adminDirectory()
        if let value = fresh.value {
            snapshot = value
        } else {
            message = fresh.userMessage
        }
    }

    /// The words for where a channel will be filed, for the form's own subtitle.
    func filingLabel(categoryId: String?, subcategoryId: String?) -> String {
        let subcategory = subcategoryId.flatMap { id in
            snapshot.categories.flatMap(\.subcategories).first { $0.id == id }
        }
        let category = categoryId.flatMap { id in snapshot.categories.first { $0.id == id } }
        switch (category, subcategory) {
        case let (category?, subcategory?): return "\(category.name) › \(subcategory.name)"
        case let (category?, nil): return category.name
        default: return "Uncategorised"
        }
    }

    func subcategory(id: String) -> DirectorySubcategory? {
        snapshot.categories.flatMap(\.subcategories).first { $0.id == id }
    }

    func category(id: String) -> DirectoryCategory? {
        snapshot.categories.first { $0.id == id }
    }
}

/// The manager's first level: the categories, and what has not been filed.
struct DirectoryAdminView: View {
    let repository: GoodPostRepository
    @State private var model: DirectoryAdminModel
    @State private var newCategoryName = ""
    @State private var addingCategory = false

    init(repository: GoodPostRepository) {
        self.repository = repository
        _model = State(initialValue: DirectoryAdminModel(repository: repository))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let message = model.message {
                    CVErrorBanner(message: message) { Task { await model.load() } }
                }

                if model.loading && model.snapshot.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(32)
                } else if model.snapshot.isEmpty {
                    CVEmptyState(
                        title: "Nothing here yet",
                        message: "The directory is empty. Add a category, then add channels to it.",
                        symbol: "list.bullet.rectangle"
                    )
                } else {
                    ForEach(model.snapshot.categories) { category in
                        DirectoryGroupCard(
                            name: category.name,
                            count: category.channelCount,
                            busy: model.busy,
                            menu: [
                                .init(label: "Rename") { renameCategory = category },
                                .init(label: "Delete", destructive: true) { deleteCategory = category },
                            ]
                        ) {
                            DirectoryCategoryAdminView(model: model, categoryId: category.id)
                        }
                    }

                    // Channels whose category was never chosen, or was deleted afterwards. Not an
                    // error: they are still in the directory, they just have no group of their own.
                    if !model.snapshot.unfiled.isEmpty {
                        DirectoryGroupCard(
                            name: "Uncategorised",
                            count: model.snapshot.unfiled.count,
                            busy: model.busy,
                            menu: []
                        ) {
                            DirectoryChannelLevelView(
                                model: model,
                                title: "Uncategorised",
                                channels: model.snapshot.unfiled,
                                categoryId: nil,
                                subcategoryId: nil
                            )
                        }
                    }

                    Button {
                        newCategoryName = ""
                        addingCategory = true
                    } label: {
                        Label("Add category", systemImage: "plus.circle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy)
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Color.cvBackground)
        .navigationTitle("Channel directory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newCategoryName = ""
                    addingCategory = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add category")
                .disabled(model.busy)
            }
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .directoryNamePrompt(
            title: "Add category",
            label: "Category name",
            placeholder: "Categories",
            isPresented: $addingCategory,
            text: $newCategoryName
        ) { name in
            Task { await model.createCategory(name) }
        }
        .directoryNamePrompt(
            title: "Rename",
            label: "Category name",
            placeholder: "Categories",
            isPresented: Binding(
                get: { renameCategory != nil },
                set: { if !$0 { renameCategory = nil } }
            ),
            text: $renameText
        ) { name in
            guard let target = renameCategory else { return }
            renameCategory = nil
            Task { await model.rename(categoryId: target.id, name: name) }
        }
        .directoryDeleteConfirmation(
            title: "Delete category?",
            message: "The category goes, and every channel filed under it becomes uncategorised.",
            isPresented: Binding(
                get: { deleteCategory != nil },
                set: { if !$0 { deleteCategory = nil } }
            )
        ) {
            guard let target = deleteCategory else { return }
            deleteCategory = nil
            Task { await model.delete(categoryId: target.id) }
        }
    }

    @State private var renameCategory: DirectoryCategory?
    @State private var deleteCategory: DirectoryCategory?
    @State private var renameText = ""
}

/// The manager's second level: the subcategories inside one category, and the channels filed on
/// the category itself.
struct DirectoryCategoryAdminView: View {
    let model: DirectoryAdminModel
    let categoryId: String
    @State private var newSubcategoryName = ""
    @State private var addingSubcategory = false
    @State private var renameText = ""
    @State private var renameSubcategory: DirectorySubcategory?
    @State private var deleteSubcategory: DirectorySubcategory?
    @State private var deleteChannel: DirectoryChannel?
    @State private var channelForm: DirectoryChannelFormRequest?

    private var category: DirectoryCategory? { model.category(id: categoryId) }

    var body: some View {
        Group {
            if let category {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let message = model.message {
                            CVErrorBanner(message: message) { Task { await model.load() } }
                        }

                        Text("Subcategories")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.cvOnSurfaceVariant)

                        if category.subcategories.isEmpty {
                            Text("No subcategories yet.")
                                .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                        }

                        ForEach(category.subcategories) { sub in
                            DirectoryGroupCard(
                                name: sub.name,
                                count: sub.channels.count,
                                busy: model.busy,
                                menu: [
                                    .init(label: "Rename") { renameSubcategory = sub },
                                    .init(label: "Remove", destructive: true) { deleteSubcategory = sub },
                                ]
                            ) {
                                DirectoryChannelLevelView(
                                    model: model,
                                    title: sub.name,
                                    channels: sub.channels,
                                    categoryId: category.id,
                                    subcategoryId: sub.id
                                )
                            }
                        }

                        Button {
                            newSubcategoryName = ""
                            addingSubcategory = true
                        } label: {
                            Label("Add subcategory", systemImage: "plus.circle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.busy)

                        // Channels filed on the category itself, with no subcategory. Below the
                        // subcategories because that is the exception, and under their own heading
                        // so they are never mistaken for one of them.
                        if !category.channels.isEmpty {
                            Text("Channels")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.cvOnSurfaceVariant)
                                .padding(.top, 6)
                            ForEach(category.channels) { channel in
                                DirectoryChannelCard(
                                    channel: channel,
                                    busy: model.busy,
                                    onEdit: {
                                        channelForm = .init(
                                            channel: channel,
                                            categoryId: channel.categoryId,
                                            subcategoryId: channel.subcategoryId
                                        )
                                    },
                                    onFetch: { Task { await model.fetchNameAndIcon(channelId: channel.id) } },
                                    onDelete: { deleteChannel = channel }
                                )
                            }
                        }

                        Button {
                            channelForm = .init(channel: nil, categoryId: category.id, subcategoryId: nil)
                        } label: {
                            Label("Add channel", systemImage: "plus.circle")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.busy)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
            } else {
                // A category deleted underneath this screen. Nothing to draw, so it says so
                // rather than rendering a bar over an empty page.
                CVEmptyState(
                    title: "This category is gone",
                    message: "It was deleted. Go back to the directory to see what is left.",
                    symbol: "questionmark.folder"
                )
            }
        }
        .background(Color.cvBackground)
        .navigationTitle(category?.name ?? "Channel directory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newSubcategoryName = ""
                    addingSubcategory = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add subcategory")
                .disabled(model.busy || category == nil)
            }
        }
        .directoryNamePrompt(
            title: "Add subcategory",
            label: "Subcategory name",
            placeholder: category?.name ?? "Subcategories",
            isPresented: $addingSubcategory,
            text: $newSubcategoryName
        ) { name in
            Task { await model.createSubcategory(categoryId: categoryId, name: name) }
        }
        .directoryNamePrompt(
            title: "Rename",
            label: "Subcategory name",
            placeholder: "Subcategories",
            isPresented: Binding(
                get: { renameSubcategory != nil },
                set: { if !$0 { renameSubcategory = nil } }
            ),
            text: $renameText,
            initial: renameSubcategory?.name
        ) { name in
            guard let target = renameSubcategory else { return }
            renameSubcategory = nil
            Task { await model.rename(subcategoryId: target.id, name: name) }
        }
        .directoryDeleteConfirmation(
            title: "Remove subcategory?",
            message: "The subcategory goes, and its channels move up to the category.",
            isPresented: Binding(
                get: { deleteSubcategory != nil },
                set: { if !$0 { deleteSubcategory = nil } }
            )
        ) {
            guard let target = deleteSubcategory else { return }
            deleteSubcategory = nil
            Task { await model.delete(subcategoryId: target.id) }
        }
        .directoryDeleteConfirmation(
            title: "Remove this channel?",
            message: "It is taken out of the directory. Readers stop seeing it.",
            isPresented: Binding(
                get: { deleteChannel != nil },
                set: { if !$0 { deleteChannel = nil } }
            ),
            confirmLabel: "Remove"
        ) {
            guard let target = deleteChannel else { return }
            deleteChannel = nil
            Task { await model.delete(channelId: target.id) }
        }
        .sheet(item: $channelForm) { request in
            DirectoryChannelFormView(model: model, request: request)
        }
    }
}

/// The manager's third level: the channels inside one subcategory (or in the unfiled list).
struct DirectoryChannelLevelView: View {
    let model: DirectoryAdminModel
    let title: String
    let channels: [DirectoryChannel]
    let categoryId: String?
    let subcategoryId: String?
    @State private var deleteChannel: DirectoryChannel?
    @State private var channelForm: DirectoryChannelFormRequest?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let message = model.message {
                    CVErrorBanner(message: message) { Task { await model.load() } }
                }

                if channels.isEmpty {
                    Text("No channels here yet.")
                        .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                }

                ForEach(channels) { channel in
                    DirectoryChannelCard(
                        channel: channel,
                        busy: model.busy,
                        onEdit: {
                            channelForm = .init(
                                channel: channel,
                                categoryId: channel.categoryId,
                                subcategoryId: channel.subcategoryId
                            )
                        },
                        onFetch: { Task { await model.fetchNameAndIcon(channelId: channel.id) } },
                        onDelete: { deleteChannel = channel }
                    )
                }

                Button {
                    channelForm = .init(channel: nil, categoryId: categoryId, subcategoryId: subcategoryId)
                } label: {
                    Label("Add channel", systemImage: "plus.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Color.cvBackground)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    channelForm = .init(channel: nil, categoryId: categoryId, subcategoryId: subcategoryId)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add channel")
                .disabled(model.busy)
            }
        }
        .directoryDeleteConfirmation(
            title: "Remove this channel?",
            message: "It is taken out of the directory. Readers stop seeing it.",
            isPresented: Binding(
                get: { deleteChannel != nil },
                set: { if !$0 { deleteChannel = nil } }
            ),
            confirmLabel: "Remove"
        ) {
            guard let target = deleteChannel else { return }
            deleteChannel = nil
            Task { await model.delete(channelId: target.id) }
        }
        .sheet(item: $channelForm) { request in
            DirectoryChannelFormView(model: model, request: request)
        }
    }
}

// MARK: - Rows

/// One row of the manager's menus: a word and what it does.
struct DirectoryMenuItem {
    let label: String
    let destructive: Bool
    let action: () -> Void

    init(label: String, destructive: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.destructive = destructive
        self.action = action
    }
}

/// A tappable card: a tinted badge, a name, a count, and one `⋮`.
///
/// Used for both a category and a subcategory, so the two levels read the same way and the only
/// difference between them is how deep you are.
private struct DirectoryGroupCard<Destination: View>: View {
    let name: String
    let count: Int
    let busy: Bool
    let menu: [DirectoryMenuItem]
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        HStack(spacing: 8) {
            NavigationLink {
                destination()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.cvPrimary)
                        .frame(width: 36, height: 36)
                        .background(Color.cvPrimary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        Text("\(count) \(count == 1 ? "channel" : "channels")")
                            .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(busy)

            if !menu.isEmpty {
                Menu {
                    ForEach(Array(menu.enumerated()), id: \.offset) { _, item in
                        Button(item.label, role: item.destructive ? .destructive : nil, action: item.action)
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17))
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .accessibilityLabel("Options for \(name)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.cvOutlineVariant.opacity(0.3)))
    }
}

/// One channel: avatar, name, handle with its platform, and one `⋮`.
///
/// Tapping the row opens the editor, because that is the common intent; the rarer and the
/// destructive sit behind the menu.
private struct DirectoryChannelCard: View {
    let channel: DirectoryChannel
    let busy: Bool
    let onEdit: () -> Void
    let onFetch: () -> Void
    let onDelete: () -> Void

    var body: some View {
        CVCard {
            HStack(spacing: 12) {
                Button(action: onEdit) {
                    HStack(spacing: 12) {
                        CVAvatar(name: channel.displayName, url: channel.iconUrl, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.displayName)
                                .font(.system(size: 15, weight: .medium)).lineLimit(1)
                            Text("\(channel.displayHandle)  ·  \(channel.platformLabel)")
                                .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(busy)

                Menu {
                    Button("Fetch name & icon", action: onFetch)
                    Button("Rename", action: onEdit)
                    Button("Remove", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17))
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .accessibilityLabel("Options for \(channel.displayName)")
            }
        }
    }
}

// MARK: - The channel form

/// Which channel form is open: a new row, or one being edited.
///
/// The filing is carried rather than asked for: the page the administrator tapped "Add channel" on
/// IS the answer, and its name is shown under the bar so there is no doubt where the row lands.
struct DirectoryChannelFormRequest: Identifiable {
    let id = UUID()
    let channel: DirectoryChannel?
    let categoryId: String?
    let subcategoryId: String?
}

/// The three platforms a directory channel can live on.
private let directoryPlatforms = ["youtube", "instagram", "x"]

/// Add or edit one channel.
private struct DirectoryChannelFormView: View {
    let model: DirectoryAdminModel
    let request: DirectoryChannelFormRequest
    @Environment(\.dismiss) private var dismiss
    @State private var platform: String
    @State private var handle: String
    @State private var name: String

    init(model: DirectoryAdminModel, request: DirectoryChannelFormRequest) {
        self.model = model
        self.request = request
        _platform = State(initialValue: request.channel?.platform ?? "youtube")
        _handle = State(initialValue: request.channel?.handle ?? "")
        _name = State(initialValue: request.channel?.name ?? "")
    }

    private var editing: DirectoryChannel? { request.channel }
    private var canSave: Bool { editing != nil || !handle.trimmed.isEmpty }

    /// The handle as the platform's own page would spell it, so the person adding a row can see
    /// the `@` they typed is the one the app will store.
    private var previewHandle: String {
        let trimmed = handle.trimmed.trimmingPrefix("@")
        return trimmed.isEmpty ? "@…" : "@\(trimmed)"
    }

    var body: some View {
        NavigationStack {
            Form {
                if let editing {
                    Section {
                        Text("\(editing.displayHandle)  ·  \(editing.platformLabel)")
                            .font(.subheadline).foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                } else {
                    Section("Platform") {
                        Picker("Platform", selection: $platform) {
                            ForEach(directoryPlatforms, id: \.self) { option in
                                Text(platformLabel(option)).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)

                        TextField("@handle", text: $handle)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("On \(platformLabel(platform)) this opens \(previewHandle)")
                            .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    }
                }

                Section("Name") {
                    TextField("Optional", text: $name)
                    Text("Left empty, the platform's own name is used — and “Fetch name & icon” fills it in later.")
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                }

                if let message = model.message {
                    Section { Text(message).foregroundStyle(Color.cvError) }
                }
            }
            .navigationTitle(editing == nil ? "Add channel" : "Edit channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.disabled(model.busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editing == nil ? "Add" : "Save") { Task { await save() } }
                        .disabled(model.busy || !canSave)
                }
            }
            .interactiveDismissDisabled(model.busy)
            // The filing, said plainly under the title's own bar, because it is the one thing the
            // form does not ask and the reason the drill-down exists.
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(model.filingLabel(categoryId: request.categoryId, subcategoryId: request.subcategoryId))
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.cvSurfaceContainer)
            }
        }
        .tint(.cvPrimary)
    }

    private func platformLabel(_ value: String) -> String {
        switch value {
        case "youtube": return "YouTube"
        case "instagram": return "Instagram"
        case "x": return "X"
        default: return value
        }
    }

    private func save() async {
        let cleanHandle = String(handle.trimmed.trimmingPrefix("@"))
        let trimmedName = name.trimmed
        if let editing {
            await model.updateChannel(
                channelId: editing.id,
                name: trimmedName.isEmpty ? nil : trimmedName,
                categoryId: request.categoryId,
                subcategoryId: request.subcategoryId
            )
        } else {
            guard !cleanHandle.isEmpty else { return }
            await model.addChannel(
                platform: platform,
                handle: cleanHandle,
                categoryId: request.categoryId,
                subcategoryId: request.subcategoryId
            )
        }
        // Closed only when the write landed. A refused add keeps the form and its sentence on
        // screen, so the handle does not have to be typed a second time.
        if model.message == nil { dismiss() }
    }
}

// MARK: - Shared prompts

private extension View {
    /// A single-field form, shared by every rename and every new group.
    ///
    /// `initial` fills the field on open for a rename, and is empty for an add — the one difference
    /// between the two uses, which is why they are one modifier rather than two alerts.
    func directoryNamePrompt(
        title: String,
        label: String,
        placeholder: String,
        isPresented: Binding<Bool>,
        text: Binding<String>,
        initial: String? = nil,
        onConfirm: @escaping (String) -> Void
    ) -> some View {
        alert(title, isPresented: isPresented) {
            TextField(label, text: text)
            Button("Save") { onConfirm(text.wrappedValue.trimmed) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(placeholder)
        }
        .onChange(of: isPresented.wrappedValue) { _, open in
            if open { text.wrappedValue = initial ?? "" }
        }
    }

    func directoryDeleteConfirmation(
        title: String,
        message: String,
        isPresented: Binding<Bool>,
        confirmLabel: String = "Delete",
        onConfirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button(confirmLabel, role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(message)
        }
    }
}

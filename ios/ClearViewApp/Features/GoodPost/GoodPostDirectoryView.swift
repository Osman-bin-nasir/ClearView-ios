import SwiftUI

/// The curated directory of **external** channels — YouTube, Instagram and X pages worth
/// following.
///
/// A directory row is deliberately not a ClearView channel: it cannot post, it has no followers,
/// and nothing about it is stored here beyond a copy of the list. It is a platform, a handle and
/// the two things worth drawing — a name and a picture — and a tap opens the platform's own page.
///
/// The whole list arrives as one snapshot rather than one call per category, so the screen wants
/// the list and its shape together and does not flicker as each answer lands. The set is curated,
/// which is what keeps that the cheap design.
@MainActor
@Observable
final class DirectoryModel {
    let repository: GoodPostRepository
    private(set) var snapshot = DirectorySnapshot()
    private(set) var loading = false
    var message: String?
    /// True while the screen is drawing the stored copy rather than a fresh read.
    ///
    /// Shown, not hidden: a directory a reader cannot tell is stale is one they will act on.
    private(set) var fromSavedCopy = false

    init(repository: GoodPostRepository) {
        self.repository = repository
    }

    /// The categories worth a tab — the ones with something to show.
    var categories: [DirectoryCategory] { snapshot.displayableCategories }

    /// Everything drawn under one tab.
    ///
    /// "All" is the whole list in the server's curated order, which is why it is the first tab and
    /// the one the screen opens on: the ordering IS the curation, and a category tab is a slice
    /// of it rather than a separate list.
    func groups(for category: DirectoryCategory?) -> [(title: String?, channels: [DirectoryChannel])] {
        guard let category else { return [(nil, snapshot.allChannels)] }
        var groups: [(String?, [DirectoryChannel])] = []
        for subcategory in category.subcategories where !subcategory.channels.isEmpty {
            groups.append((subcategory.name, subcategory.channels))
        }
        if !category.channels.isEmpty { groups.append((nil, category.channels)) }
        return groups
    }

    func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        // The stored copy is drawn FIRST and the live read replaces it, so the screen opens on
        // content instead of a spinner — and says so while it does.
        if snapshot.isEmpty, let cached = await repository.cachedDirectory() {
            snapshot = cached.snapshot
            fromSavedCopy = true
        }
        let result = await repository.directory()
        if let fresh = result.value {
            snapshot = fresh
            fromSavedCopy = false
            message = nil
        } else {
            // Reported whether or not there is a stored copy behind it. A refresh that failed
            // silently would leave a reader looking at yesterday's list believing it is today's,
            // which is the one thing the "Saved copy" line exists to prevent.
            message = result.userMessage
        }
        // The directory is a wall of avatars, and Android warms exactly this list when the
        // screen shows it. Doing it here is also what puts the faces on the device before the
        // network goes: the saved directory is drawn offline, and it should not be a list of
        // blank circles when it is.
        await RemoteImageCache.shared.prefetch(snapshot.allChannels.compactMap(\.iconUrl))
    }
}

/// The directory screen.
struct GoodPostDirectoryView: View {
    let repository: GoodPostRepository
    @State private var model: DirectoryModel
    @State private var selected: String?
    @Environment(\.openURL) private var openURL

    init(repository: GoodPostRepository) {
        self.repository = repository
        _model = State(initialValue: DirectoryModel(repository: repository))
    }

    private var category: DirectoryCategory? {
        model.categories.first { $0.id == selected }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text(fromSavedCopyLine)
                        .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant)
                    Spacer(minLength: 0)
                    Button {
                        Task { await model.load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise").font(.caption.bold())
                    }.disabled(model.loading)
                }.padding(.horizontal, 16).padding(.top, 12)

                if let message = model.message {
                    CVErrorBanner(message: message) { Task { await model.load() } }
                        .padding(.horizontal, 16).padding(.top, 12)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        CVChip(title: "All", selected: selected == nil) { selected = nil }
                        ForEach(model.categories) { item in
                            CVChip(title: item.name, selected: selected == item.id) { selected = item.id }
                        }
                    }.padding(.horizontal, 16)
                }.padding(.vertical, 14)

                if model.loading && model.snapshot.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(32)
                }

                ForEach(Array(model.groups(for: category).enumerated()), id: \.offset) { _, group in
                    if let title = group.title {
                        Text(title.uppercased())
                            .font(.caption2.bold()).foregroundStyle(Color.cvOnSurfaceVariant)
                            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
                    }
                    ForEach(group.channels) { channel in
                        Button {
                            if let url = URL(string: channel.url),
                               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                                openURL(url)
                            }
                        } label: {
                            DirectoryRow(channel: channel)
                        }.buttonStyle(.plain)
                    }
                }

                if !model.loading && model.snapshot.isEmpty && model.message == nil {
                    CVEmptyState(
                        title: "Nothing here yet",
                        message: "The directory is empty right now.",
                        symbol: "list.bullet.rectangle"
                    ).padding(24)
                }
                Spacer(minLength: 32)
            }
        }
        .background(Color.cvBackground)
        .navigationTitle("Channel directory")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    private var fromSavedCopyLine: String {
        if model.loading { return "Refreshing…" }
        return model.fromSavedCopy ? "Saved copy" : "Curated channels to follow"
    }
}

/// One directory row: a name, a platform and a handle.
private struct DirectoryRow: View {
    let channel: DirectoryChannel

    var body: some View {
        HStack(spacing: 14) {
            CVAvatar(name: channel.displayName, url: channel.iconUrl, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(channel.displayName).font(.subheadline.weight(.semibold)).lineLimit(1)
                // The handle and the platform on one line, which is what identifies the row —
                // the name may be missing entirely, and the handle is then the whole of it.
                Text("\(channel.displayHandle) · \(channel.platformLabel)")
                    .font(.caption).foregroundStyle(Color.cvOnSurfaceVariant).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(Color.cvPrimary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

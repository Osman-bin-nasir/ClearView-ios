import SwiftUI

/// Every message this reader starred, for one channel or for the whole app.
///
/// The information page says how many there are and nothing else; they are read here. That is
/// why this is a screen rather than a section: a reader's private bookmarks under a channel's
/// description gave the page whatever height the list happened to need, and it left no room for
/// the thing a list of bookmarks most needs, which is a way to find one.
@MainActor
@Observable
final class StarredModel {
    let repository: GoodPostRepository
    let store = GoodPostStarredStore()
    private(set) var entries: [GoodPostStarredEntry] = []
    private(set) var thumbs: [String: GoodPostMedia] = [:]
    private var inFlight: Set<String> = []

    init(repository: GoodPostRepository) {
        self.repository = repository
    }

    /// Reloads from this device. `channelId` nil means every star the reader has.
    func load(channelId: String?) {
        entries = channelId.map { store.forChannel($0) } ?? store.all
    }

    func unstar(postId: String, channelId: String?) {
        store.remove(postId: postId)
        load(channelId: channelId)
    }

    /// The picture behind one row.
    ///
    /// Asked for per row rather than in one pass over the list. A bookmark keeps a post's words
    /// and deliberately **not** its URL — a signed URL expires within the hour, so a stored one
    /// is a broken image waiting to be drawn — which means the picture has to be fetched each
    /// time the list is opened. Fetching it only for the rows actually drawn is what keeps a
    /// hundred bookmarks from becoming a hundred requests.
    func loadThumb(for entry: GoodPostStarredEntry) async {
        guard thumbs[entry.postId] == nil, !inFlight.contains(entry.postId) else { return }
        inFlight.insert(entry.postId)
        defer { inFlight.remove(entry.postId) }
        // A document draws no preview, so it is not a thumbnail — the row's own label says what
        // it is instead.
        guard let post = await repository.post(postId: entry.postId).value,
              let media = post.media.first(where: { !$0.isDocument }) else { return }
        thumbs[entry.postId] = media
    }
}

/// The starred list.
struct GoodPostStarredView: View {
    /// The channel to list, or nil for every star on this device.
    let channelId: String?
    let repository: GoodPostRepository
    @State private var model: StarredModel
    @State private var query = ""

    init(channelId: String?, repository: GoodPostRepository) {
        self.channelId = channelId
        self.repository = repository
        _model = State(initialValue: StarredModel(repository: repository))
    }

    private var shown: [GoodPostStarredEntry] {
        let term = query.trimmed
        guard !term.isEmpty else { return model.entries }
        return model.entries.filter { entry in
            (entry.body ?? "").localizedCaseInsensitiveContains(term)
                || entry.channelName.localizedCaseInsensitiveContains(term)
        }
    }

    var body: some View {
        List {
            if model.entries.isEmpty {
                CVEmptyState(
                    title: "Starred messages",
                    message: "Nothing starred here yet. Tap the star on a message to keep it.",
                    symbol: "star"
                )
                .listRowBackground(Color.clear)
            } else if shown.isEmpty {
                CVEmptyState(
                    title: "No matches",
                    message: "Nothing you starred matches that.",
                    symbol: "magnifyingglass"
                )
                .listRowBackground(Color.clear)
            }
            ForEach(shown) { entry in
                StarredRow(
                    entry: entry,
                    media: model.thumbs[entry.postId],
                    highlight: query,
                    // The channel's name is worth a line only in the list that spans every
                    // channel — under one channel's own list it would repeat the page title
                    // on every row.
                    showsChannel: channelId == nil,
                    onUnstar: { model.unstar(postId: entry.postId, channelId: channelId) }
                )
                .task { await model.loadThumb(for: entry) }
            }
        }
        .listStyle(.plain)
        .background(Color.cvBackground)
        .navigationTitle("Starred messages")
        .navigationBarTitleDisplayMode(.inline)
        // A search box over an empty list would be the only thing on screen.
        .searchable(text: $query, prompt: "Search your starred messages")
        .disabled(model.entries.isEmpty)
        .task { model.load(channelId: channelId) }
    }
}

/// One starred message.
///
/// A row rather than a card: it is a message somebody chose to keep, and the channel feed
/// already draws messages as cards — a second, prettier frame for the same words would be the
/// beginning of a second design language.
private struct StarredRow: View {
    let entry: GoodPostStarredEntry
    let media: GoodPostMedia?
    let highlight: String
    let showsChannel: Bool
    let onUnstar: () -> Void

    /// The word a media-only bookmark is described by, because it has no words of its own.
    private var label: String {
        switch entry.kind {
        case "image": return "Photo"
        case "video": return "Video"
        case "link": return "Link"
        case "document": return "Document"
        default: return "Something was posted"
        }
    }

    private var text: String {
        let body = (entry.body ?? "").trimmed
        return body.isEmpty ? label : body
    }

    private var stamp: String {
        guard let milliseconds = parseIsoMillis(entry.createdAt) else { return "" }
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // The row's status: this is a bookmark.
            Image(systemName: "star.fill")
                .font(.caption).foregroundStyle(Color.cvPrimary).padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(highlightedText(text, term: highlight))
                    .font(.subheadline).lineLimit(4)
                if !stamp.isEmpty {
                    Text(stamp).font(.caption2).foregroundStyle(Color.cvOnSurfaceVariant)
                }
                if showsChannel, !entry.channelName.isEmpty {
                    Text(entry.channelName).font(.caption2).foregroundStyle(Color.cvPrimary)
                }
            }

            Spacer(minLength: 0)

            if let media, let raw = media.url {
                ZStack {
                    RemoteImage(url: raw, placeholder: AnyView(Color.cvSurfaceContainer))
                    if media.isVideo {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10)).foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // An icon rather than a menu: there is exactly one thing to do with a bookmark
            // besides open it. Hollow is the state it leads to — which is how every bookmark
            // control says "tap to undo" — and it is deliberately not the filled star the row
            // already carries on its left, which is the status and not a control.
            Button(action: onUnstar) {
                Image(systemName: "star").font(.body).foregroundStyle(Color.cvPrimary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove star")
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.cvBackground)
    }
}

/// The row's words with the search term picked out.
///
/// Every occurrence rather than the first: a term that appears three times in a paragraph is the
/// reason the reader searched for it. A blank term marks nothing, which is the state the list
/// opens in.
private func highlightedText(_ text: String, term: String) -> AttributedString {
    let query = term.trimmed
    guard !query.isEmpty else { return AttributedString(text) }
    var result = AttributedString()
    var index = text.startIndex
    while let range = text.range(of: query, options: [.caseInsensitive], range: index..<text.endIndex) {
        result += AttributedString(text[index..<range.lowerBound])
        var match = AttributedString(text[range])
        match.foregroundColor = .cvPrimary
        match.font = .subheadline.bold()
        result += match
        index = range.upperBound
    }
    result += AttributedString(text[index..<text.endIndex])
    return result
}

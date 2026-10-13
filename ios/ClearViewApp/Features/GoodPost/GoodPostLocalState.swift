import Foundation

/// The updates this reader deleted **for themselves**.
///
/// ## What "delete for me" can mean here
///
/// There is no per-reader copy of a post on the server to delete: a reader has no account,
/// and Good Post's posts are one row that everybody reads. So the honest meaning of
/// "delete for me" is the one WhatsApp gives it — it goes out of **my** view — and the only
/// place that can be true is this device.
///
/// That makes it a set of ids, applied when a list is drawn, and it is stored rather than
/// kept in memory for the case that matters: a feed cache means the post comes back on the
/// next cold start, and a deleted message that reappears tomorrow is worse than not
/// offering the button.
///
/// ## What it deliberately does not do
///
/// It does not touch the server, and it cannot: a reader who hides an update has changed
/// nothing for anybody else, which is exactly the promise the wording makes. Removing it for
/// everyone is the administrator's action — a different button with a different
/// confirmation.
struct GoodPostHiddenStore {

    enum Key {
        static let postIds = "goodpost_hidden_post_ids"
    }

    /// A Preferences file is not a database: the newest ids are kept and the oldest fall
    /// off. An id is 36 bytes, so this bounds the file at a few tens of kilobytes.
    static let limit = 1000

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every hidden post id on this device.
    var ids: Set<String> {
        Set(defaults.stringArray(forKey: Key.postIds) ?? [])
    }

    func isHidden(postId: String) -> Bool { ids.contains(postId) }

    /// Hides these posts, guaranteeing that the ids just hidden survive the cap.
    ///
    /// Newest first, so today's deletion is never the thing that falls off — a message the
    /// reader deleted this morning reappearing tonight is the failure mode worth designing
    /// against, and the cap only ever needs to shed older ids.
    func hide(_ postIds: [String]) {
        guard !postIds.isEmpty else { return }
        var merged = postIds
        merged.append(contentsOf: ids.filter { !postIds.contains($0) })
        save(Array(merged.prefix(GoodPostHiddenStore.limit)))
    }

    /// Un-hides one post. Nothing in the app calls it yet; it is what a "show deleted
    /// messages" toggle would need.
    func unhide(postId: String) {
        save(Array(ids).filter { $0 != postId })
    }

    func clear() {
        defaults.removeObject(forKey: Key.postIds)
    }

    private func save(_ ids: [String]) {
        defaults.set(ids, forKey: Key.postIds)
    }
}

/// The posts this device has already had counted as read.
///
/// ## Why this exists
///
/// Reporting a view is a write (`POST .../posts/views`), and a client that keeps its dedupe
/// set in memory only fails the moment the app is closed: the next cold start has an empty
/// set, every post on the first page looks unseen, and the counter on a post nobody new has
/// opened goes up by one simply because the phone was restarted. A reader watching their own
/// channel sees a view count that climbs on its own.
///
/// A view is a fact about a **reader** rather than about a run, so the record of it belongs
/// somewhere that outlives the process. There is no reader account to hang it from — a Good
/// Post reader has no account at all — so the honest place is this device, exactly as the
/// hidden and starred stores are.
///
/// ## What this deliberately is not
///
/// Not a read receipt, and not a per-reader view table: the server counts views and nothing
/// asks *who* read an update. This is only the client keeping itself from asking the same
/// question twice, and it never reports a retroactive correction — forgetting an id (through
/// the cap) can cost one extra count on a post somebody reads again much later, never a count
/// that was not earned.
struct GoodPostViewedStore {

    enum Key {
        static let postIds = "goodpost_viewed_post_ids"
    }

    static let limit = 1000

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Every post id this device has already had counted.
    var ids: Set<String> {
        Set(defaults.stringArray(forKey: Key.postIds) ?? [])
    }

    func seen(postId: String) -> Bool { ids.contains(postId) }

    /// Records ids as counted, newest first, dropping the oldest past the cap.
    ///
    /// The same ordering rule as the hidden store: the ids just recorded must survive, since
    /// those are the posts most likely to be opened again in this same session.
    func mark(_ postIds: [String]) {
        guard !postIds.isEmpty else { return }
        var merged = postIds
        merged.append(contentsOf: ids.filter { !postIds.contains($0) })
        defaults.set(Array(merged.prefix(GoodPostViewedStore.limit)), forKey: Key.postIds)
    }

    /// Everything is unseen again. Nothing calls it yet; it is here for a reset, and for the
    /// tests.
    func clear() {
        defaults.removeObject(forKey: Key.postIds)
    }
}

/// One starred message, as much of it as a list needs to draw it.
///
/// Kept whole rather than as an id because a starred message is opened from a channel's
/// information page, often days later: a list of ids would have to re-fetch each one to draw
/// — thirty round trips to render a page of bookmarks, most of them 404s once the server's
/// retention window has passed. Keeping the words also makes a star survive the post it
/// points at, which is the behaviour a bookmark is supposed to have.
struct GoodPostStarredEntry: Equatable, Identifiable {
    let postId: String
    let channelId: String
    let channelName: String
    let body: String?
    let kind: String
    let createdAt: String
    let starredAt: Int64

    var id: String { postId }

    init(
        postId: String,
        channelId: String,
        channelName: String,
        body: String?,
        kind: String = "text",
        createdAt: String,
        starredAt: Int64 = 0
    ) {
        self.postId = postId
        self.channelId = channelId
        self.channelName = channelName
        self.body = body
        self.kind = kind
        self.createdAt = createdAt
        self.starredAt = starredAt
    }

    /// What the row shows: the stored words, or an honest placeholder for a post that had
    /// none (a bare image or video).
    var displayBody: String {
        guard let body, !body.trimmed.isEmpty else { return "No text" }
        return body
    }
}

/// The messages this device has starred.
///
/// ## Why this is local, and why it stores a copy
///
/// A star is one reader's private bookmark. The two honest places to keep it are the server,
/// keyed on the reader's identity, or this device. It is here for the reason above: a starred
/// list that held only ids would have to re-fetch each one to draw.
///
/// The URL of an attached image is deliberately **not** kept. A signed URL expires within the
/// hour, so a stored one is a broken image waiting to be drawn; the starred row says what the
/// post was and how to get back to it, and the channel is one tap away.
///
/// Bounded, because a Preferences file is not a database: the newest stars are kept and the
/// oldest fall off.
struct GoodPostStarredStore {

    enum Key {
        static let entries = "goodpost_starred_entries"
    }

    static let limit = 200

    private let defaults: UserDefaults
    private let now: () -> Int64

    init(defaults: UserDefaults = .standard, now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.defaults = defaults
        self.now = now
    }

    /// Everything starred, newest star first.
    var all: [GoodPostStarredEntry] { read() }

    /// The stars that belong to one channel — the channel information page's list.
    func forChannel(_ channelId: String) -> [GoodPostStarredEntry] {
        read().filter { $0.channelId == channelId }
    }

    func isStarred(postId: String) -> Bool {
        read().contains { $0.postId == postId }
    }

    /// Stars the post, or takes the star back. Returns the state afterwards.
    ///
    /// Idempotent in both directions: starring twice replaces the row rather than producing
    /// two, and unstarring something that was never starred is a no-op — so a double tap on a
    /// laggy tap target cannot leave a phantom star behind.
    @discardableResult
    func toggle(_ entry: GoodPostStarredEntry) -> Bool {
        let current = read()
        let existing = current.contains { $0.postId == entry.postId }
        if existing {
            save(current.filter { $0.postId != entry.postId })
            return false
        }
        var stamped = entry
        stamped = GoodPostStarredEntry(
            postId: entry.postId,
            channelId: entry.channelId,
            channelName: entry.channelName,
            body: entry.body,
            kind: entry.kind,
            createdAt: entry.createdAt,
            starredAt: now()
        )
        save(Array(([stamped] + current).prefix(GoodPostStarredStore.limit)))
        return true
    }

    func remove(postId: String) {
        save(read().filter { $0.postId != postId })
    }

    /// Drops every star that came from `channelId`.
    ///
    /// For the one case a post-level removal cannot cover: the channel itself was deleted.
    /// Its rows name a channel that is no longer there, and the words alone are a message
    /// with no way back to where it came from — which is the half of a bookmark that makes it
    /// one.
    func removeChannel(_ channelId: String) {
        guard !channelId.trimmed.isEmpty else { return }
        save(read().filter { $0.channelId != channelId })
    }

    func clear() {
        defaults.removeObject(forKey: Key.entries)
    }

    // MARK: - Storage

    /// Reads the stored rows, skipping anything unusable.
    ///
    /// A file written by an older build, or a partial write, reads as empty: a star list that
    /// cannot be read is not a reason to fail the screen it is on, and the next star rewrites
    /// it.
    private func read() -> [GoodPostStarredEntry] {
        guard let raw = defaults.string(forKey: Key.entries),
              let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return []
        }
        return array.compactMap { element in
            guard let dictionary = element as? [String: Any] else { return nil }
            guard let postId = dictionary["postId"] as? String, !postId.trimmed.isEmpty else {
                return nil
            }
            return GoodPostStarredEntry(
                postId: postId,
                channelId: dictionary["channelId"] as? String ?? "",
                channelName: dictionary["channelName"] as? String ?? "",
                body: body(dictionary["body"]),
                kind: dictionary["kind"] as? String ?? "text",
                createdAt: dictionary["createdAt"] as? String ?? "",
                starredAt: (dictionary["starredAt"] as? NSNumber)?.int64Value ?? 0
            )
        }
    }

    /// A stored body that is blank *or* the four characters `null` reads as no body.
    ///
    /// The `"null"` case is Android's, and it is not paranoia: a JSON `null` that was written
    /// through a string-formatting layer arrives as that literal, and a starred row showing
    /// the word "null" as its text is worse than one that says it had no text.
    private func body(_ value: Any?) -> String? {
        guard let text = value as? String, !text.trimmed.isEmpty, text != "null" else { return nil }
        return text
    }

    private func save(_ entries: [GoodPostStarredEntry]) {
        let array: [[String: Any]] = entries.map { entry in
            [
                "postId": entry.postId,
                "channelId": entry.channelId,
                "channelName": entry.channelName,
                "body": entry.body ?? "",
                "kind": entry.kind,
                "createdAt": entry.createdAt,
                "starredAt": entry.starredAt,
            ]
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: array, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        defaults.set(json, forKey: Key.entries)
    }
}

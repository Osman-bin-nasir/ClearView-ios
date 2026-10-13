import Foundation

/// The public Good Post shapes: what `/api/v1` returns.
///
/// Every field here is one the backend actually sends, and every one of them is public.
/// There is deliberately **no** follower-only count, no reaction list, no `isFollowing` on the
/// admin shapes and no owner field — Good Post is a broadcast system, not a social network,
/// and a field the client never receives cannot be rendered by accident later.
///
/// These are the *viewer's* shapes: there is no `viewerRole` or `hasUnread` because there is no
/// viewer account to hang them on.

/// One stored asset on a post: an image, a video or a document.
struct GoodPostMedia: Identifiable, Equatable {
    let id: String
    /// `image`, `video` or `document`.
    let kind: String
    let contentType: String
    let byteSize: Int64
    let width: Int?
    let height: Int?
    let durationMs: Int64?
    /// The name the sender's file had, for a document. Null for the other kinds: a reader
    /// sees the picture rather than what it was called on disk, and for a document the name
    /// *is* the card, so the server refuses one without it.
    let fileName: String?
    let position: Int
    /// A short-lived signed read URL, or nil when this deployment has no bucket. Nil is a
    /// normal state rather than a failure: a text-only post needs no storage, and one
    /// unservable asset must not break the screen it sits on.
    let url: String?

    var isImage: Bool { kind == "image" }
    var isVideo: Bool { kind == "video" }
    /// A file the app hands to another app rather than drawing: its card is a name and a
    /// size, and a tap opens it in whatever the device has registered for a PDF.
    var isDocument: Bool { kind == "document" }
}

/// One item in a channel's "Media and links" gallery.
struct GoodPostMediaItem: Identifiable, Equatable {
    let id: String
    let postId: String
    let kind: String
    let contentType: String
    let width: Int?
    let height: Int?
    let durationMs: Int64?
    let fileName: String?
    let createdAt: String
    let url: String?

    var isImage: Bool { kind == "image" }
    var isVideo: Bool { kind == "video" }
    var isDocument: Bool { kind == "document" }
}

/// The channel a post came from, as a single-post payload names it.
struct GoodPostChannelRef: Equatable {
    let id: String
    let slug: String
    let name: String
}

/// A channel as it appears in the list, in Explore, and in the feed header.
struct GoodPostChannel: Identifiable, Equatable {
    let id: String
    let slug: String
    let name: String
    let description: String?
    let categorySlug: String?
    let categoryLabel: String?
    let countryCode: String?
    /// A short-lived signed URL for the channel's profile image, or nil.
    ///
    /// Nil is a normal state, not a failure: a channel that never had an image, and equally a
    /// deployment with no bucket. The avatar falls back to the channel's initial, which is why
    /// nothing here needs an error case.
    let iconUrl: String?
    let createdAt: String
    let lastPostAt: String?
    /// The newest post's kind — `text`, `image`, `video`, `link` — or nil.
    let lastPostType: String?
    let lastPostPreview: String?
    /// How many times the newest post has been reported read. Zero rather than nil, so there
    /// is one shape to render rather than two.
    let lastPostViews: Int
    /// Real follows, which is why it is allowed where a social metric is not: every follow is
    /// a decision a person made about this channel.
    let followerCount: Int
    /// The platform's own badge. Set by a super administrator, never earned.
    let verified: Bool
    /// App deep link: `clearview://goodpost/channel/<slug>`.
    let shareLink: String
    /// `active` or `suspended`, and only on a payload an administrator received.
    let status: String?

    // The reader's own state. Present only on a payload from the reader's own follows; defaults
    // rather than optionals so a public row renders with no badge and no toggle.
    let unreadCount: Int
    let following: Bool
    let notificationsMuted: Bool
    /// ISO instant of the follow; nil when not followed.
    let followedAt: String?

    /// What a row shows when there is no icon to draw.
    var initial: String {
        guard let first = name.trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

/// The reader's relationship to one channel, as follow/unfollow/mute/mark-read answer it.
///
/// Returned rather than discarded so the screen can update the one row it acted on from the
/// answer instead of refetching the list it is already showing.
struct GoodPostFollow: Equatable {
    let channelId: String
    let following: Bool
    let notificationsMuted: Bool
    /// Posts published since the reader last read it.
    let unreadCount: Int
}

/// One emoji and how many readers chose it. A total, not a list — the API never says who.
struct GoodPostReaction: Equatable {
    let emoji: String
    let count: Int

    var isEmpty: Bool { count <= 0 }
}

/// A post, as the channel feed renders it.
struct GoodPostPost: Identifiable, Equatable {
    let id: String
    let channelId: String
    /// `text`, `image`, `video` or `link`.
    let type: String
    let body: String?
    let linkUrl: String?
    let linkTitle: String?
    let media: [GoodPostMedia]
    let createdAt: String
    /// When the publisher last changed it, or nil. Kept because an edit changes what the
    /// channel said, and a reader who saw the earlier version should not wonder whether they
    /// misremembered it.
    let editedAt: String?
    /// Present only when the post was fetched on its own.
    let channel: GoodPostChannelRef?
    /// How many readers have reported this post read. A floor rather than a truth, because the
    /// server only knows when it was told.
    let views: Int
    /// What readers have reacted with, commonest first.
    let reactions: [GoodPostReaction]
    /// Which emoji **this** reader picked, if any.
    ///
    /// Not part of the payload — the public read takes no token — so the app fetches the
    /// reader's own reactions for the channel it is showing and merges them in. Nil means
    /// "not asked yet", which is why the chip is drawn as the reader's only when this is set.
    let myReaction: String?

    var hasImage: Bool { media.contains { $0.isImage } }
    var hasVideo: Bool { media.contains { $0.isVideo } }
    var isLink: Bool { !(linkUrl ?? "").trimmed.isEmpty }
    /// A post with no words and no media is not drawable; the feed skips it rather than
    /// showing an empty bubble.
    var isEmpty: Bool {
        (body ?? "").trimmed.isEmpty && media.isEmpty && !isLink
    }

    func reactionCount(_ emoji: String) -> Int {
        reactions.first { $0.emoji == emoji }?.count ?? 0
    }

    /// A copy carrying this reader's own reaction, which arrives in a second, token-scoped read.
    func withMyReaction(_ emoji: String?) -> GoodPostPost {
        GoodPostPost(
            id: id,
            channelId: channelId,
            type: type,
            body: body,
            linkUrl: linkUrl,
            linkTitle: linkTitle,
            media: media,
            createdAt: createdAt,
            editedAt: editedAt,
            channel: channel,
            views: views,
            reactions: reactions,
            myReaction: emoji
        )
    }
}

/// The server's answer to setting or clearing one reaction.
///
/// Carried back rather than discarded because the count it holds is the number of readers
/// currently on that emoji, as the server just saw it — which is what a card should show.
/// Guessing locally ("mine, so +1") is right until somebody else reacts at the same moment.
struct GoodPostReactionResult: Equatable {
    let postId: String
    /// Nil after an un-react.
    let emoji: String?
    let count: Int
}

/// A category an Explore filter can offer.
struct GoodPostCategory: Identifiable, Equatable {
    let slug: String
    let label: String

    var id: String { slug }
}

/// One entry in the global Brain Rot repository, as an administrator sees it.
///
/// Keyword and channel share this type because they are managed identically — the queue, the
/// two lists and the enable/disable action all describe one row. `value` is the keyword or the
/// `@handle`; `kind` says which, so a caller never has to infer it from the leading "@".
struct GoodPostBrainRotRule: Identifiable, Equatable {
    let id: String
    /// `keyword` or `channel`.
    let kind: String
    let value: String
    let displayName: String?
    let reason: String?
    /// Disabled rules stay in the repository but stop being served.
    let enabled: Bool
    /// Distinct devices that reported this.
    let reports: Int
    let createdAt: String?

    var isChannel: Bool { kind == "channel" }
}

/// A community suggestion awaiting review.
struct GoodPostBrainRotSubmission: Identifiable, Equatable {
    let id: String
    /// `keyword` or `channel`.
    let kind: String
    let value: String
    let displayName: String?
    let note: String?
    /// `youtube_not_interested`, `app` or `unknown`.
    let source: String
    /// `pending`, `approved`, `rejected` or `under_review`.
    let status: String
    /// Distinct devices that reported the target.
    let reports: Int
    /// Distinct devices that asked for it globally.
    let requesters: Int
    let createdAt: String?

    var isChannel: Bool { kind == "channel" }

    /// True while a decision is still open. "Under review" counts: it is an operator saying
    /// they are looking at it, not a decision.
    var isOpen: Bool { status == "pending" || status == "under_review" }
}

/// One reported target in the false-positive queue.
///
/// Raised from the block overlay's "Report false positive", so a row is a user saying that a
/// block was wrong — the counterpart to `GoodPostBrainRotSubmission`, which is a user saying
/// something *should* be blocked. Grouped by target: many devices reporting the same term is
/// one row, because it is one decision.
struct GoodPostBrainRotReport: Equatable {
    let kind: String
    let value: String
    let displayName: String?
    /// Distinct devices that reported it.
    let reports: Int
    let detail: String?
    let latestAt: String?
    let firstAt: String?
    /// The global rule this term matches, or nil when it matches none. Nil is distinct from a
    /// disabled rule, which has an id and `ruleEnabled == false`.
    let ruleId: String?
    let ruleEnabled: Bool?

    var isChannel: Bool { kind == "channel" }
    /// True when acting on this report can also stop a rule.
    var hasRule: Bool { ruleId != nil }
}

/// One target's demand, as the dashboard lists it.
///
/// Two numbers, deliberately different: `reports` is how many devices reported the target,
/// `globalRequests` is how many asked for it to be blocked for everyone. `reports` is parsed
/// from the wire's `usersBlocking` key, which is named for a number the server never receives
/// — a device blocking something locally sends nothing — and the key is kept as-is so the
/// deployed backend needs no change.
struct GoodPostBrainRotDemand: Equatable {
    let kind: String
    let value: String
    let displayName: String?
    let reports: Int
    let globalRequests: Int
    let status: String?

    var isChannel: Bool { kind == "channel" }
}

/// The dashboard's totals and its two most-requested lists.
struct GoodPostBrainRotDashboard: Equatable {
    var pending: Int = 0
    var approved: Int = 0
    var rejected: Int = 0
    var underReview: Int = 0
    var total: Int = 0
    var topChannels: [GoodPostBrainRotDemand] = []
    var topKeywords: [GoodPostBrainRotDemand] = []
}

/// An advertisement card.
///
/// Platform-controlled content shown at the top of Channels and Explore. It is **not** a
/// third-party ad SDK: a super administrator writes it, uploads its picture and decides where
/// and when it runs. `text` is what is drawn and `imageUrl` is non-nil only for an image card,
/// so what a card renders is a property of the card rather than of which screen fetched it.
struct GoodPostAd: Identifiable, Equatable {
    let id: String
    /// `image` or `text`.
    let contentType: String
    /// A short-lived signed URL for the card's picture, or nil. Nil for a text card, and nil
    /// for an image card on a deployment with no storage.
    let imageUrl: String?
    let text: String?
    /// Where a tap goes: an `http(s):` page or a `mailto:` address.
    let targetUrl: String?
    let showInChannels: Bool
    let showInExplore: Bool
    /// Admin only in effect — the public read never returns a disabled card.
    let enabled: Bool
    let startsAt: String?
    let expiresAt: String?
    /// Lower sorts first; ties fall back to newest.
    let priority: Int
    let textColor: String
    let backgroundColor: String
    /// Image cards: `cover` or `contain`.
    let imageFit: String
    /// Image cards: the point of the picture to keep when it is cropped, 0..1, chosen by the
    /// person who made the card rather than by a default in the middle.
    let imageFocusX: Double
    let imageFocusY: Double

    var isImage: Bool { contentType == "image" }
    var isText: Bool { contentType == "text" }

    /// Whether the card's own window contains `nowMs` — the rule the server applies.
    ///
    /// Needed on the client only for the cached copy: the server filters a live read by the
    /// clock, but a card saved an hour ago can have expired since, and a cached advertisement
    /// that has run out must not be shown.
    func isActive(at nowMs: Int64) -> Bool {
        if let start = parseIsoMillis(startsAt), start > nowMs { return false }
        if let end = parseIsoMillis(expiresAt), end <= nowMs { return false }
        return true
    }

    /// The card's own text, or an honest placeholder for a text card with nothing in it.
    var displayText: String {
        guard let text, !text.trimmed.isEmpty else { return "" }
        return text
    }
}

/// The ink a text card falls back to when it has no colour of its own.
let adDefaultTextColor = "#E9EDEF"

/// The surface a card falls back to — the app's own bar, as it was drawn before.
let adDefaultBackgroundColor = "#202C33"

/// The surfaces a card can be drawn on.
///
/// Dark-first, because the card sits on a near-black list and a light panel there is a
/// different kind of object rather than a louder one. The last two are the exceptions and are
/// deliberately muted — a card is allowed to stand out, not to glare.
let adBackgroundColors = [
    "#202C33", // the bar colour, for a card that reads as part of the app
    "#103529", // the deep green, for an offer
    "#3B1F2B", // wine, for an announcement
    "#1B2A4A", // navy, for something informational
    "#3A2E12", // bronze, for a deadline
    "#0B141A", // the canvas itself, for a card that is only its words
    "#FFFFFF", // white, for a card that has to be seen from across a room
]

/// The colours the card editor offers for a text card.
///
/// A short, fixed palette rather than a colour wheel: every one of these is legible on the
/// card's dark surface, which is the only property that matters and the one a free picker lets
/// an administrator get wrong.
let adTextColors = [
    "#E9EDEF", // the reader's ordinary ink
    "#25D366", // the green, for a card that reads as an offer
    "#FFD166", // amber, for a warning or a deadline
    "#7FD4FF", // sky, for a link-like card
    "#FF8FA3", // rose, for a card that should stop the scroll
    "#FFFFFF", // plain white, for a picture behind a dark scrim
    "#000000", // black, for a card on a light background
]

/// Where a card can appear. One endpoint serves both surfaces.
enum GoodPostAdPlacement: String, CaseIterable {
    case channels
    case explore

    /// The value the API reads.
    var wire: String { rawValue }
}

/// An ISO instant from the backend as epoch millis, or nil.
///
/// Nil rather than 0 for an unparseable value, because a timestamp of zero renders as 1970 and
/// a wrong date is worse than no date at all. Both spellings the backend has ever sent are
/// accepted: with and without fractional seconds, at any UTC offset.
func parseIsoMillis(_ iso: String?) -> Int64? {
    guard let iso, !iso.trimmed.isEmpty else { return nil }

    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: iso) {
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    if let date = plain.date(from: iso) {
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
    return nil
}

/// One keyset page. `nextCursor` is nil once the end is reached.
struct GoodPostPage<Element>: Equatable where Element: Equatable {
    var items: [Element]
    var nextCursor: String?

    var isEmpty: Bool { items.isEmpty }

    /// True when there is more to fetch.
    var hasMore: Bool { !(nextCursor ?? "").trimmed.isEmpty }
}

/// Parsing backend JSON, and reading/writing the offline cache.
///
/// Pure, like the rest of ClearView's contract boundaries: this is the one place a field rename
/// turns every channel into a blank row, and testing it through a screen would be both slower
/// and weaker.
///
/// An unusable payload yields nil (or an empty page) rather than throwing, so a backend
/// contract break surfaces as a retryable error instead of a wrong row. `id` and `name` are
/// required because a row without them cannot be drawn; everything else degrades to a default,
/// because a missing count is cosmetic while a missing id is a bug.
enum GoodPostCodec {

    // MARK: - Parsing rows

    static func channel(from dictionary: [String: Any]) -> GoodPostChannel? {
        guard let id = JSONScalar.string(dictionary["id"]), !id.isEmpty,
              let name = JSONScalar.string(dictionary["name"]), !name.isEmpty else {
            return nil
        }
        return GoodPostChannel(
            id: id,
            slug: JSONScalar.string(dictionary["slug"]) ?? "",
            name: name,
            description: JSONScalar.nullableString(dictionary["description"]),
            categorySlug: JSONScalar.nullableString(dictionary["categorySlug"]),
            categoryLabel: JSONScalar.nullableString(dictionary["categoryLabel"]),
            countryCode: JSONScalar.nullableString(dictionary["countryCode"]),
            iconUrl: JSONScalar.nullableString(dictionary["iconUrl"]),
            createdAt: JSONScalar.string(dictionary["createdAt"]) ?? "",
            lastPostAt: JSONScalar.nullableString(dictionary["lastPostAt"]),
            lastPostType: JSONScalar.nullableString(dictionary["lastPostType"]),
            lastPostPreview: JSONScalar.nullableString(dictionary["lastPostPreview"]),
            lastPostViews: max(0, JSONScalar.int(dictionary["lastPostViews"]) ?? 0),
            followerCount: max(0, JSONScalar.int(dictionary["followerCount"]) ?? 0),
            verified: JSONScalar.bool(dictionary["verified"]) ?? false,
            shareLink: JSONScalar.string(dictionary["shareLink"]) ?? "",
            status: JSONScalar.nullableString(dictionary["status"]),
            // Absent on every payload except the reader's own follows, where the defaults mean
            // "nothing to show".
            unreadCount: max(0, JSONScalar.int(dictionary["unreadCount"]) ?? 0),
            following: JSONScalar.bool(dictionary["following"]) ?? false,
            notificationsMuted: JSONScalar.bool(dictionary["notificationsMuted"]) ?? false,
            followedAt: JSONScalar.nullableString(dictionary["followedAt"])
        )
    }

    /// Parses a `{ follow: { ... } }` body.
    static func follow(from body: [String: Any]) -> GoodPostFollow? {
        guard let row = body["follow"] as? [String: Any],
              let channelId = JSONScalar.string(row["channelId"]), !channelId.isEmpty else {
            return nil
        }
        return GoodPostFollow(
            channelId: channelId,
            following: JSONScalar.bool(row["following"]) ?? false,
            notificationsMuted: JSONScalar.bool(row["notificationsMuted"]) ?? false,
            unreadCount: max(0, JSONScalar.int(row["unreadCount"]) ?? 0)
        )
    }

    static func channelRef(from dictionary: [String: Any]) -> GoodPostChannelRef? {
        guard let id = JSONScalar.string(dictionary["id"]), !id.isEmpty else { return nil }
        return GoodPostChannelRef(
            id: id,
            slug: JSONScalar.string(dictionary["slug"]) ?? "",
            name: JSONScalar.string(dictionary["name"]) ?? ""
        )
    }

    static func media(from dictionary: [String: Any]) -> GoodPostMedia? {
        guard let id = JSONScalar.string(dictionary["id"]), !id.isEmpty else { return nil }
        return GoodPostMedia(
            id: id,
            kind: JSONScalar.string(dictionary["kind"]) ?? "",
            contentType: JSONScalar.string(dictionary["contentType"]) ?? "",
            byteSize: JSONScalar.int64(dictionary["byteSize"]) ?? 0,
            width: JSONScalar.int(dictionary["width"]),
            height: JSONScalar.int(dictionary["height"]),
            durationMs: JSONScalar.int64(dictionary["durationMs"]),
            fileName: JSONScalar.nullableString(dictionary["fileName"]),
            position: JSONScalar.int(dictionary["position"]) ?? 0,
            url: JSONScalar.nullableString(dictionary["url"])
        )
    }

    static func post(from dictionary: [String: Any]) -> GoodPostPost? {
        guard let id = JSONScalar.string(dictionary["id"]), !id.isEmpty,
              let channelId = JSONScalar.string(dictionary["channelId"]), !channelId.isEmpty else {
            return nil
        }
        let type = JSONScalar.string(dictionary["type"]) ?? ""
        return GoodPostPost(
            id: id,
            channelId: channelId,
            type: type.trimmed.isEmpty ? "text" : type,
            body: JSONScalar.nullableString(dictionary["body"]),
            linkUrl: JSONScalar.nullableString(dictionary["linkUrl"]),
            linkTitle: JSONScalar.nullableString(dictionary["linkTitle"]),
            media: mediaArray(dictionary["media"]),
            createdAt: JSONScalar.string(dictionary["createdAt"]) ?? "",
            editedAt: JSONScalar.nullableString(dictionary["editedAt"]),
            channel: (dictionary["channel"] as? [String: Any]).flatMap(channelRef(from:)),
            views: max(0, JSONScalar.int(dictionary["views"]) ?? 0),
            reactions: reactionArray(dictionary["reactions"]),
            myReaction: nil
        )
    }

    /// The reaction counts on a post.
    ///
    /// A zero count is dropped rather than shown: the server only ever sends emoji somebody
    /// chose, and a card that drew "0" next to an emoji would be describing a reaction that no
    /// longer exists.
    static func reactionArray(_ value: Any?) -> [GoodPostReaction] {
        let rows = value as? [Any] ?? []
        return rows.compactMap { element -> GoodPostReaction? in
            guard let row = element as? [String: Any],
                  let emoji = JSONScalar.string(row["emoji"]), !emoji.isEmpty else { return nil }
            let count = JSONScalar.int(row["count"]) ?? 0
            guard count > 0 else { return nil }
            return GoodPostReaction(emoji: emoji, count: count)
        }
    }

    /// A `{ reactions: { postId: emoji } }` body — the reader's own choices.
    ///
    /// Tolerant of an unknown post id: the map is merged into whatever page is on screen, and a
    /// reaction on a post that has scrolled out of the window is simply not drawn.
    static func readerReactions(from body: [String: Any]) -> [String: String] {
        guard let row = body["reactions"] as? [String: Any] else { return [:] }
        var map: [String: String] = [:]
        for (key, value) in row {
            guard let emoji = JSONScalar.string(value), !emoji.isEmpty else { continue }
            map[key] = emoji
        }
        return map
    }

    /// A `{ reaction: { postId, emoji, count } }` body.
    static func reactionResult(from body: [String: Any]) -> GoodPostReactionResult? {
        guard let row = body["reaction"] as? [String: Any],
              let postId = JSONScalar.string(row["postId"]), !postId.isEmpty else {
            return nil
        }
        return GoodPostReactionResult(
            postId: postId,
            emoji: JSONScalar.nullableString(row["emoji"]),
            count: max(0, JSONScalar.int(row["count"]) ?? 0)
        )
    }

    /// The offered emoji, from `GET /readers/reactions`.
    static func reactionVocabulary(from body: [String: Any]) -> [String] {
        (body["emoji"] as? [Any] ?? []).compactMap { JSONScalar.string($0) }
            .filter { !$0.isEmpty }
    }

    static func mediaItem(from dictionary: [String: Any]) -> GoodPostMediaItem? {
        guard let id = JSONScalar.string(dictionary["id"]), !id.isEmpty else { return nil }
        return GoodPostMediaItem(
            id: id,
            postId: JSONScalar.string(dictionary["postId"]) ?? "",
            kind: JSONScalar.string(dictionary["kind"]) ?? "",
            contentType: JSONScalar.string(dictionary["contentType"]) ?? "",
            width: JSONScalar.int(dictionary["width"]),
            height: JSONScalar.int(dictionary["height"]),
            durationMs: JSONScalar.int64(dictionary["durationMs"]),
            fileName: JSONScalar.nullableString(dictionary["fileName"]),
            createdAt: JSONScalar.string(dictionary["createdAt"]) ?? "",
            url: JSONScalar.nullableString(dictionary["url"])
        )
    }

    // MARK: - Pages

    /// Parses a `{ items, nextCursor }` page with `element` as the row parser.
    static func page<Element>(
        from body: [String: Any],
        element: ([String: Any]) -> Element?
    ) -> GoodPostPage<Element> {
        let rows = body["items"] as? [Any] ?? []
        var parsed: [Element] = []
        for row in rows {
            guard let dictionary = row as? [String: Any] else { continue }
            if let value = element(dictionary) { parsed.append(value) }
        }
        // An empty string handed back as a cursor would be rejected as invalid, turning the end
        // of a list into an error.
        let cursor = JSONScalar.nullableString(body["nextCursor"])
        return GoodPostPage(items: parsed, nextCursor: cursor)
    }

    static func channelPage(from body: [String: Any]) -> GoodPostPage<GoodPostChannel> {
        page(from: body, element: channel(from:))
    }

    static func postPage(from body: [String: Any]) -> GoodPostPage<GoodPostPost> {
        page(from: body, element: post(from:))
    }

    /// A page of a channel's media, for the gallery and the media strip.
    ///
    /// Documents are dropped **here** rather than in the grid that draws them. Both surfaces
    /// are a wall of previews — a tile is the picture, or a poster frame and a play badge — and
    /// a document has neither: it would be a tile with nothing in it, whose tap opened a viewer
    /// for a file it cannot show. Its card on the post it came from is where it is opened. The
    /// server still sends it; this is a decision about a grid, not about what a channel holds.
    static func mediaPage(from body: [String: Any]) -> GoodPostPage<GoodPostMediaItem> {
        let parsed = page(from: body, element: mediaItem(from:))
        return GoodPostPage(
            items: parsed.items.filter { !$0.isDocument },
            nextCursor: parsed.nextCursor
        )
    }

    /// Parses a `{ channel: { ... } }` body.
    static func singleChannel(from body: [String: Any]) -> GoodPostChannel? {
        (body["channel"] as? [String: Any]).flatMap(channel(from:))
    }

    /// Parses a `{ post: { ... } }` body.
    static func singlePost(from body: [String: Any]) -> GoodPostPost? {
        (body["post"] as? [String: Any]).flatMap(post(from:))
    }

    // MARK: - Advertisements

    /// One advertisement.
    ///
    /// `id` and `contentType` are required because a card without them cannot be acted on or
    /// drawn; the rest degrades to a default so a missing schedule is "none" rather than a
    /// blank screen. An unknown content type is dropped at `adList` rather than shown as a card
    /// with no content.
    static func ad(from dictionary: [String: Any]) -> GoodPostAd? {
        guard let id = JSONScalar.string(dictionary["id"]), !id.isEmpty,
              let contentType = JSONScalar.string(dictionary["contentType"]), !contentType.isEmpty else {
            return nil
        }
        return GoodPostAd(
            id: id,
            contentType: contentType,
            imageUrl: JSONScalar.nullableString(dictionary["imageUrl"]),
            text: JSONScalar.nullableString(dictionary["text"]),
            targetUrl: JSONScalar.nullableString(dictionary["targetUrl"]),
            showInChannels: JSONScalar.bool(dictionary["showInChannels"]) ?? false,
            showInExplore: JSONScalar.bool(dictionary["showInExplore"]) ?? false,
            enabled: JSONScalar.bool(dictionary["enabled"]) ?? false,
            startsAt: JSONScalar.nullableString(dictionary["startsAt"]),
            expiresAt: JSONScalar.nullableString(dictionary["expiresAt"]),
            priority: JSONScalar.int(dictionary["priority"]) ?? 100,
            textColor: JSONScalar.nullableString(dictionary["textColor"]) ?? adDefaultTextColor,
            backgroundColor: JSONScalar.nullableString(dictionary["backgroundColor"]) ?? adDefaultBackgroundColor,
            imageFit: JSONScalar.string(dictionary["imageFit"]) == "contain" ? "contain" : "cover",
            imageFocusX: min(max(JSONScalar.double(dictionary["imageFocusX"]) ?? 0.5, 0), 1),
            imageFocusY: min(max(JSONScalar.double(dictionary["imageFocusY"]) ?? 0.5, 0), 1)
        )
    }

    /// Parses a `{ ads: [...] }` body.
    static func adList(from body: [String: Any]) -> [GoodPostAd] {
        (body["ads"] as? [Any] ?? [])
            .compactMap { $0 as? [String: Any] }
            .compactMap(ad(from:))
    }

    /// Parses a `{ ad: { ... } }` body.
    static func singleAd(from body: [String: Any]) -> GoodPostAd? {
        (body["ad"] as? [String: Any]).flatMap(ad(from:))
    }

    /// Parses a `{ categories: [...] }` body.
    static func categories(from body: [String: Any]) -> [GoodPostCategory] {
        (body["categories"] as? [Any] ?? []).compactMap { element -> GoodPostCategory? in
            guard let row = element as? [String: Any],
                  let slug = JSONScalar.string(row["slug"]), !slug.isEmpty else { return nil }
            let label = JSONScalar.nullableString(row["label"]) ?? slug
            return GoodPostCategory(slug: slug, label: label)
        }
    }

    // MARK: - Appending a page

    /// Appends a freshly fetched page to what is already on screen.
    ///
    /// Keyed by id and last-write-wins, because a channel can legitimately appear twice across
    /// pages when it publishes between two requests and moves up the recent-activity ranking.
    /// Deduplicating on append means the list cannot show the same channel twice, and the
    /// fresher copy wins.
    static func merge<Element>(
        existing: [Element],
        incoming: [Element],
        idOf: (Element) -> String
    ) -> [Element] {
        guard !incoming.isEmpty else { return existing }
        var merged: [String: Element] = [:]
        var order: [String] = []
        for element in existing + incoming {
            let key = idOf(element)
            if merged[key] == nil { order.append(key) }
            merged[key] = element
        }
        return order.compactMap { merged[$0] }
    }

    // MARK: - The offline cache

    /// Serialises channels for the cache.
    ///
    /// The channel's **avatar URL is cached**, unlike a post's media URLs, and the difference
    /// is what the URL is for: a post's asset is the point of the post, so a stale URL there is
    /// a hole in the content, while an avatar is a decoration and the list draws the channel's
    /// initial when the signature has expired.
    static func encodeChannels(_ channels: [GoodPostChannel]) -> String {
        let rows: [[String: Any]] = channels.map { channel in
            [
                "id": channel.id,
                "slug": channel.slug,
                "name": channel.name,
                "description": channel.description.map { $0 as Any } ?? NSNull(),
                "categorySlug": channel.categorySlug.map { $0 as Any } ?? NSNull(),
                "categoryLabel": channel.categoryLabel.map { $0 as Any } ?? NSNull(),
                "countryCode": channel.countryCode.map { $0 as Any } ?? NSNull(),
                "iconUrl": channel.iconUrl.map { $0 as Any } ?? NSNull(),
                "createdAt": channel.createdAt,
                "lastPostAt": channel.lastPostAt.map { $0 as Any } ?? NSNull(),
                "lastPostType": channel.lastPostType.map { $0 as Any } ?? NSNull(),
                "lastPostPreview": channel.lastPostPreview.map { $0 as Any } ?? NSNull(),
                "lastPostViews": channel.lastPostViews,
                "followerCount": channel.followerCount,
                "verified": channel.verified,
                "shareLink": channel.shareLink,
                "unreadCount": channel.unreadCount,
                "following": channel.following,
                "notificationsMuted": channel.notificationsMuted,
                "followedAt": channel.followedAt.map { $0 as Any } ?? NSNull(),
            ]
        }
        return jsonString(rows)
    }

    static func decodeChannels(_ raw: String?) -> [GoodPostChannel] {
        guard let rows = jsonArray(raw) else { return [] }
        return rows.compactMap { $0 as? [String: Any] }.compactMap(channel(from:))
    }

    /// Serialises advertisement cards for the cache.
    ///
    /// The card's `imageUrl` is deliberately **not** written, unlike a channel's avatar: it is a
    /// short-lived signed URL and a card *is* its picture, so a cached card drawing an expired
    /// address would be a card with a hole in it. A cached image card therefore renders nothing
    /// until the live read replaces it, which is the state a nil URL already handles.
    static func encodeAds(_ ads: [GoodPostAd]) -> String {
        let rows: [[String: Any]] = ads.map { ad in
            [
                "id": ad.id,
                "contentType": ad.contentType,
                "text": ad.text.map { $0 as Any } ?? NSNull(),
                "targetUrl": ad.targetUrl.map { $0 as Any } ?? NSNull(),
                "showInChannels": ad.showInChannels,
                "showInExplore": ad.showInExplore,
                "enabled": ad.enabled,
                "startsAt": ad.startsAt.map { $0 as Any } ?? NSNull(),
                "expiresAt": ad.expiresAt.map { $0 as Any } ?? NSNull(),
                "priority": ad.priority,
                "textColor": ad.textColor,
                "backgroundColor": ad.backgroundColor,
                "imageFit": ad.imageFit,
                "imageFocusX": ad.imageFocusX,
                "imageFocusY": ad.imageFocusY,
            ]
        }
        return jsonString(rows)
    }

    static func decodeAds(_ raw: String?) -> [GoodPostAd] {
        guard let rows = jsonArray(raw) else { return [] }
        return rows.compactMap { $0 as? [String: Any] }.compactMap(ad(from:))
    }

    /// Serialises posts for the cache.
    ///
    /// Signed media URLs are stripped on the way in: a presigned URL is a short-lived
    /// capability, and writing one to disk presents an expired address as a saved asset — the
    /// image renders as a broken box offline, which is worse than an honest placeholder. Only
    /// the metadata is kept.
    static func encodePosts(_ posts: [GoodPostPost]) -> String {
        let rows: [[String: Any]] = posts.map { post in
            [
                "id": post.id,
                "channelId": post.channelId,
                "type": post.type,
                "body": post.body.map { $0 as Any } ?? NSNull(),
                "linkUrl": post.linkUrl.map { $0 as Any } ?? NSNull(),
                "linkTitle": post.linkTitle.map { $0 as Any } ?? NSNull(),
                "views": post.views,
                "createdAt": post.createdAt,
                "media": post.media.map { asset in
                    [
                        "id": asset.id,
                        "kind": asset.kind,
                        "contentType": asset.contentType,
                        "byteSize": asset.byteSize,
                        "width": asset.width.map { $0 as Any } ?? NSNull(),
                        "height": asset.height.map { $0 as Any } ?? NSNull(),
                        "durationMs": asset.durationMs.map { $0 as Any } ?? NSNull(),
                        "fileName": asset.fileName.map { $0 as Any } ?? NSNull(),
                        "position": asset.position,
                        "url": NSNull(),
                    ] as [String: Any]
                },
            ]
        }
        return jsonString(rows)
    }

    /// Newest first, so a cached list draws in the order the feed would.
    static func decodePosts(_ raw: String?) -> [GoodPostPost] {
        guard let rows = jsonArray(raw) else { return [] }
        return rows.compactMap { $0 as? [String: Any] }
            .compactMap(post(from:))
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Brain Rot repository (admin)

    /// One global rule, keyword or channel.
    ///
    /// The same shape for both, with `value` carrying the keyword or the handle, because the
    /// review queue, the two management lists and the rules endpoint all describe one row and
    /// the only difference is which column holds the string.
    static func brainRotRule(from dictionary: [String: Any]) -> GoodPostBrainRotRule? {
        guard let id = JSONScalar.nullableString(dictionary["id"]) else { return nil }
        let keyword = JSONScalar.nullableString(dictionary["keyword"])
        let handle = JSONScalar.nullableString(dictionary["handle"])
        guard let value = keyword ?? handle else { return nil }
        let isChannel = handle != nil
        return GoodPostBrainRotRule(
            id: id,
            kind: isChannel ? "channel" : "keyword",
            value: value,
            displayName: JSONScalar.nullableString(dictionary["displayName"]),
            reason: JSONScalar.nullableString(dictionary["reason"]),
            enabled: JSONScalar.bool(dictionary["enabled"]) ?? true,
            reports: JSONScalar.int(dictionary["reports"]) ?? 0,
            createdAt: JSONScalar.nullableString(dictionary["createdAt"])
        )
    }

    /// Parses a `{ keywords: [...] }` body.
    static func brainRotKeywords(from body: [String: Any]) -> [GoodPostBrainRotRule] {
        brainRotRuleList(body["keywords"])
    }

    /// Parses a `{ channels: [...] }` body.
    static func brainRotChannels(from body: [String: Any]) -> [GoodPostBrainRotRule] {
        brainRotRuleList(body["channels"])
    }

    /// Parses a `{ submissions: [...] }` body.
    static func brainRotSubmissions(from body: [String: Any]) -> [GoodPostBrainRotSubmission] {
        (body["submissions"] as? [Any] ?? []).compactMap { element -> GoodPostBrainRotSubmission? in
            guard let row = element as? [String: Any],
                  let id = JSONScalar.nullableString(row["id"]),
                  let value = JSONScalar.nullableString(row["value"]) else { return nil }
            return GoodPostBrainRotSubmission(
                id: id,
                kind: JSONScalar.string(row["kind"]) == "channel" ? "channel" : "keyword",
                value: value,
                displayName: JSONScalar.nullableString(row["displayName"]),
                note: JSONScalar.nullableString(row["note"]),
                source: JSONScalar.nullableString(row["source"]) ?? "unknown",
                status: JSONScalar.nullableString(row["status"]) ?? "pending",
                reports: JSONScalar.int(row["reports"]) ?? 0,
                requesters: JSONScalar.int(row["requesters"]) ?? 0,
                createdAt: JSONScalar.nullableString(row["createdAt"])
            )
        }
    }

    /// Parses a `{ totals: {...}, topChannels: [...], topKeywords: [...] }` body.
    static func brainRotDashboard(from body: [String: Any]) -> GoodPostBrainRotDashboard {
        let totals = body["totals"] as? [String: Any]
        return GoodPostBrainRotDashboard(
            pending: totals.flatMap { JSONScalar.int($0["pending"]) } ?? 0,
            approved: totals.flatMap { JSONScalar.int($0["approved"]) } ?? 0,
            rejected: totals.flatMap { JSONScalar.int($0["rejected"]) } ?? 0,
            underReview: totals.flatMap { JSONScalar.int($0["underReview"]) } ?? 0,
            total: totals.flatMap { JSONScalar.int($0["all"]) } ?? 0,
            topChannels: brainRotDemandList(body["topChannels"]),
            topKeywords: brainRotDemandList(body["topKeywords"])
        )
    }

    /// Parses a `{ reports: [...] }` body.
    static func brainRotReports(from body: [String: Any]) -> [GoodPostBrainRotReport] {
        (body["reports"] as? [Any] ?? []).compactMap { element -> GoodPostBrainRotReport? in
            guard let row = element as? [String: Any],
                  let value = JSONScalar.nullableString(row["value"]) else { return nil }
            return GoodPostBrainRotReport(
                kind: JSONScalar.string(row["kind"]) == "channel" ? "channel" : "keyword",
                value: value,
                displayName: JSONScalar.nullableString(row["displayName"]),
                reports: JSONScalar.int(row["reports"]) ?? 0,
                detail: JSONScalar.nullableString(row["detail"]),
                latestAt: JSONScalar.nullableString(row["latestAt"]),
                firstAt: JSONScalar.nullableString(row["firstAt"]),
                // The wire distinguishes "no rule" (absent) from a disabled rule (an id with
                // `ruleEnabled` false), so an absent id stays nil rather than becoming "".
                ruleId: JSONScalar.nullableString(row["ruleId"]),
                ruleEnabled: JSONScalar.boolOrNil(row["ruleEnabled"])
            )
        }
    }

    /// Parses a `{ categories: [...] }`/`{ unfiled: [...] }`-shaped directory body.
    static func encodeCategories(_ categories: [GoodPostCategory]) -> String {
        jsonString(["categories": categories.map { ["slug": $0.slug, "label": $0.label] }])
    }

    static func decodeCategories(_ raw: String?) -> [GoodPostCategory] {
        guard let raw, !raw.trimmed.isEmpty,
              let dictionary = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
            return []
        }
        return categories(from: dictionary)
    }

    // MARK: - Internals

    private static func mediaArray(_ value: Any?) -> [GoodPostMedia] {
        (value as? [Any] ?? [])
            .compactMap { $0 as? [String: Any] }
            .compactMap(media(from:))
            .sorted { $0.position < $1.position }
    }

    private static func brainRotRuleList(_ value: Any?) -> [GoodPostBrainRotRule] {
        (value as? [Any] ?? [])
            .compactMap { $0 as? [String: Any] }
            .compactMap(brainRotRule(from:))
    }

    private static func brainRotDemandList(_ value: Any?) -> [GoodPostBrainRotDemand] {
        (value as? [Any] ?? []).compactMap { element -> GoodPostBrainRotDemand? in
            guard let row = element as? [String: Any],
                  let value = JSONScalar.nullableString(row["value"]) else { return nil }
            return GoodPostBrainRotDemand(
                kind: JSONScalar.string(row["kind"]) == "channel" ? "channel" : "keyword",
                value: value,
                displayName: JSONScalar.nullableString(row["displayName"]),
                // Named `usersBlocking` on the wire, and kept as-is: a device blocking
                // something locally sends nothing, so renaming the key would need a server
                // change for a number the server never receives.
                reports: JSONScalar.int(row["usersBlocking"]) ?? 0,
                globalRequests: JSONScalar.int(row["globalRequests"]) ?? 0,
                status: JSONScalar.nullableString(row["status"])
            )
        }
    }

    /// `{"categories": [...]}`, i.e. an object rather than a bare array, for the
    /// categories encoding only.
    private static func jsonString(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private static func jsonString(_ value: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private static func jsonArray(_ raw: String?) -> [Any]? {
        guard let raw, !raw.trimmed.isEmpty else { return nil }
        // A stored file written by an older build, or a partial write, reads as nothing rather
        // than failing the screen it is on: the next successful read rewrites it.
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [Any]
    }
}

/// Reading one JSON value without the `NSNull` dance at every call site.
///
/// `JSONSerialization` hands back `Any`, with an absent key and a JSON `null` both arriving as
/// something this code has to interpret. Doing that interpretation once, here, is what keeps a
/// missing count cosmetic and a missing id a drop.
enum JSONScalar {

    /// A non-blank string, or nil.
    static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String { return text }
        // A number that arrived where a string was expected is still readable, which matters
        // because ids are strings to this app and numbers are numbers to some backends.
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    /// A string that is present **and** not blank; an empty name is not a name.
    static func nullableString(_ value: Any?) -> String? {
        guard let text = string(value) else { return nil }
        return text.trimmed.isEmpty ? nil : text
    }

    static func int(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    static func int64(_ value: Any?) -> Int64? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// A boolean that is genuinely absent rather than false — the distinction the false-positive
    /// queue's `ruleEnabled` needs.
    static func boolOrNil(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        return bool(value)
    }

    /// Uppercases nothing, trims nothing: what a value *is* is the caller's question.
    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }
}

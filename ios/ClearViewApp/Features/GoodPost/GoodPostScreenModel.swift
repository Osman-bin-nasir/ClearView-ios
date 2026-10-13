import Foundation
import Observation

@MainActor
@Observable
final class GoodPostScreenModel {
    let repository: GoodPostRepository
    var channels: [GoodPostChannel] = []
    var categories: [GoodPostCategory] = []
    var loading = false
    var message: String?
    var nextCursor: String?
    var savedIDs: Set<String>
    var followedIDs: Set<String> = []
    var pendingFollows: Set<String> = []
    var session: AdminSession?
    var ownedChannels: [GoodPostChannel] = []
    var channelAds: [GoodPostAd] = []
    private let defaults: UserDefaults

    var canCreateChannel: Bool { session == nil || session?.isSuperAdmin == true }

    /// Whether this account may publish to — or edit and delete posts in — a channel.
    ///
    /// The same rule the Android app applies: a super administrator manages every
    /// channel, and a channel administrator only the one the server confined them to.
    /// A signed-out reader manages nothing, which is what keeps a reader from being
    /// offered a control that would only be refused.
    func canManage(_ channelId: String) -> Bool {
        guard let session else { return false }
        return session.isSuperAdmin || session.channelId == channelId
    }

    /// This state with `channel` replacing the row it identifies.
    ///
    /// One channel appears in up to three places in the tab — the account's own list, the
    /// reader's followed list, and the screen that is open — and an edit that updated some of
    /// them would leave the tab disagreeing with itself about a name or a picture. Rows that
    /// are not there stay absent: this replaces a channel, it does not add one.
    func applyUpdatedChannel(_ channel: GoodPostChannel) {
        func replaced(_ rows: [GoodPostChannel]) -> [GoodPostChannel] {
            rows.map { $0.id == channel.id ? channel : $0 }
        }
        channels = replaced(channels)
        ownedChannels = replaced(ownedChannels)
    }

    var homeChannels: [GoodPostChannel] {
        let ownedIDs = Set(ownedChannels.map(\.id))
        return ownedChannels + channels.filter { followedIDs.contains($0.id) && !ownedIDs.contains($0.id) }
    }

    init(repository: GoodPostRepository = GoodPostRepository(), defaults: UserDefaults = .standard) {
        self.repository = repository
        self.defaults = defaults
        savedIDs = Set(defaults.stringArray(forKey: "goodpost.savedChannels") ?? [])
    }

    func load(more: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        if channels.isEmpty, let cached = await repository.cachedChannels() { channels = cached.channels }
        followedIDs = await repository.cachedFollowedIds()
        if !more {
            session = await repository.adminSession()
            if session == nil { ownedChannels = [] }
            else if let owned = await repository.adminChannels().value { ownedChannels = owned }
            session = await repository.adminSession()
            if let cached = await repository.cachedAds(placement: .channels) { channelAds = cached.ads }
            if let ads = await repository.ads(placement: .channels).value { channelAds = ads }
        }
        let result = await repository.channels(cursor: more ? nextCursor : nil)
        if let page = result.value {
            if more {
                let existing = Set(channels.map(\.id))
                channels += page.items.filter { !existing.contains($0.id) }
            } else { channels = page.items }
            nextCursor = page.nextCursor
            message = nil
        } else { message = channels.isEmpty ? result.userMessage : "Showing saved data. " + result.userMessage }
        if let result = await repository.categories().value { categories = result }
        if await repository.identifiesReaders, !more {
            var cursor: String?
            var followed: [GoodPostChannel] = []
            var completed = true
            repeat {
                let result = await repository.following(cursor: cursor)
                guard let page = result.value else { completed = false; break }
                followed += page.items
                cursor = page.nextCursor
            } while cursor != nil && !Task.isCancelled
            if completed && !Task.isCancelled { followedIDs = Set(followed.map(\.id)) }
            else { followedIDs.formUnion(followed.map(\.id)) }
            let followedByID = Dictionary(followed.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            channels = channels.map { followedByID[$0.id] ?? $0 }
            let existing = Set(channels.map(\.id))
            channels += followed.filter { !existing.contains($0.id) }
        }
    }

    func toggleSaved(_ channel: GoodPostChannel) {
        if savedIDs.contains(channel.id) { savedIDs.remove(channel.id) }
        else {
            savedIDs.insert(channel.id)
            if !channels.contains(where: { $0.id == channel.id }) { channels.append(channel) }
        }
        defaults.set(Array(savedIDs), forKey: "goodpost.savedChannels")
    }

    func toggleFollow(_ channel: GoodPostChannel) async {
        guard !pendingFollows.contains(channel.id) else { return }
        pendingFollows.insert(channel.id)
        defer { pendingFollows.remove(channel.id) }
        let result = followedIDs.contains(channel.id)
            ? await repository.unfollow(idOrSlug: channel.id)
            : await repository.follow(idOrSlug: channel.id)
        if let follow = result.value {
            if follow.following { followedIDs.insert(channel.id) }
            else { followedIDs.remove(channel.id) }
            if follow.following && !channels.contains(where: { $0.id == channel.id }) { channels.append(channel) }
            message = nil
        } else { message = result.userMessage }
    }

    func signOut() async {
        let previousSession = session
        await repository.forgetAdminSession()
        session = nil
        ownedChannels = []
        await repository.creatorSignOut()
        if let previousSession { await repository.revokeAdminSession(refreshToken: previousSession.refreshToken) }
    }
}

@MainActor
@Observable
final class ChannelFeedModel {
    let repository: GoodPostRepository
    let channel: GoodPostChannel
    var posts: [GoodPostPost] = []
    var nextCursor: String?
    var loading = false
    var message: String?
    var emojiOptions: [String] = []
    var myReactions: [String: String] = [:]
    var reacting: Set<String> = []

    init(channel: GoodPostChannel, repository: GoodPostRepository) {
        self.channel = channel
        self.repository = repository
    }

    func load(more: Bool = false) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        if posts.isEmpty, let cached = await repository.cachedPosts(channelId: channel.id) { posts = cached.posts }
        let result = await repository.channelPosts(channelId: channel.id, cursor: more ? nextCursor : nil)
        if let page = result.value {
            let existing = Set(posts.map(\.id))
            posts = more ? posts + page.items.filter { !existing.contains($0.id) } : page.items
            nextCursor = page.nextCursor
            message = nil
        } else { message = result.userMessage }
        if !more {
            emojiOptions = await repository.reactionEmoji().value ?? []
            if await repository.identifiesReaders {
                myReactions = await repository.myReactions(idOrSlug: channel.id)
            }
        }
    }

    func react(to post: GoodPostPost, emoji: String) async {
        guard !reacting.contains(post.id) else { return }
        reacting.insert(post.id)
        defer { reacting.remove(post.id) }
        let result = myReactions[post.id] == emoji
            ? await repository.unreact(postId: post.id, emoji: emoji)
            : await repository.react(postId: post.id, emoji: emoji)
        if let reaction = result.value {
            myReactions[post.id] = reaction.emoji
            await load()
        } else { message = result.userMessage }
    }
}

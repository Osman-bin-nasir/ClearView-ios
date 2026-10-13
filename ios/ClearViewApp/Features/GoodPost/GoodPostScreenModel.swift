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
    private let defaults: UserDefaults

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
            repeat {
                let result = await repository.following(cursor: cursor)
                guard let page = result.value else { break }
                followed += page.items
                cursor = page.nextCursor
            } while cursor != nil && !Task.isCancelled
            followedIDs.formUnion(followed.map(\.id))
            let existing = Set(channels.map(\.id))
            channels += followed.filter { !existing.contains($0.id) }
        }
    }

    func toggleSaved(_ channel: GoodPostChannel) {
        if savedIDs.contains(channel.id) { savedIDs.remove(channel.id) }
        else { savedIDs.insert(channel.id) }
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
            message = nil
        } else { message = result.userMessage }
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

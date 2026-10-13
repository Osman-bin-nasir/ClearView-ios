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
    }

    func toggleSaved(_ channel: GoodPostChannel) {
        if savedIDs.contains(channel.id) { savedIDs.remove(channel.id) }
        else { savedIDs.insert(channel.id) }
        defaults.set(Array(savedIDs), forKey: "goodpost.savedChannels")
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
    }
}

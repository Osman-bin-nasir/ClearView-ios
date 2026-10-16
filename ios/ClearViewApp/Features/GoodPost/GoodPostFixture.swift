import Foundation

/// The Good Post cache, seeded from outside the app for a UI test.
///
/// The same seam `CLEARVIEW_MEDIA_FIXTURE` gives the Media tab, and for the same reason: a test
/// of what the app shows **with the network gone** has to be able to start from "this device
/// already has these updates saved" without depending on a backend being reachable, or on an
/// earlier run having happened to fetch the rows it wanted to prove.
///
/// It writes through the app's own codec and the app's own cache — never a hand-built
/// preference — so a fixture cannot pass against a shape the real fetch would not produce. And
/// it writes the *reader's* keys the same way a fetch does: the catalogue, the follow list, the
/// follow switches, and each channel's posts.
///
/// Only `ClearViewApp` calls it, and only when `--uitesting` is set and the environment asks
/// for a fixture.
enum GoodPostFixture {

    /// Seeds from `{"channels": {"items": […]}, "posts": {"<channelId>": {"items": […]}}}`.
    ///
    /// - Returns: whether anything was stored, so a caller (or a test) can tell an empty
    ///   fixture from a seeded one.
    @discardableResult
    static func seed(
        from data: Data,
        cache: GoodPostCache = GoodPostCache(),
        nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) -> Bool {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        var seeded = false

        if let channelsBody = body["channels"] as? [String: Any] {
            let page = GoodPostCodec.channelPage(from: channelsBody)
            if !page.items.isEmpty {
                cache.saveChannels(page.items, nowMs: nowMs)
                cache.saveFollowedChannels(page.items, nowMs: nowMs)
                cache.saveFollowedIds(Set(page.items.map(\.id)))
                seeded = true
            }
        }

        if let posts = body["posts"] as? [String: Any] {
            for (channelId, value) in posts {
                guard let pageBody = value as? [String: Any] else { continue }
                let page = GoodPostCodec.postPage(from: pageBody)
                guard !page.items.isEmpty else { continue }
                cache.savePosts(channelId: channelId, posts: page.items, nowMs: nowMs)
                seeded = true
            }
        }

        return seeded
    }
}

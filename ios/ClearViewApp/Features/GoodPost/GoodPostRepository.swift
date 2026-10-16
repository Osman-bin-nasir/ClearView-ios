import Foundation

/// Good Post's data layer.
///
/// Two rules shape it:
///
///  * **Reads never need a session.** Every browsing call goes straight to the anonymous
///    `/api/v1` surface, so a reader who has just installed the app sees channels rather than a
///    sign-in screen. There is no token to acquire, refresh or expire.
///  * **The cache is read first, and the network replaces it.** The screen renders
///    `cachedChannels()` immediately and calls `channels(...)` behind it, which is what makes the
///    tab feel like it opens instantly and what keeps it usable offline. The repository does not
///    merge the two — that decision belongs where the screen is built, so "saved" and "live" can be
///    labelled differently.
///
/// Administrator writes carry a token, and it is the **only** token the app stores.
///
/// An `actor` rather than a class, for one reason that matters: renewing an administrator session
/// must be serialised. The server rotates the refresh token and tolerates the previous one once,
/// for a client whose response was lost, while a second replay of it is treated as a stolen token
/// and revokes the whole session. Two admin calls that lapse together — a dashboard's channels and
/// a channel's posts — would otherwise refresh with the same token at the same moment, which is
/// exactly that shape.
actor GoodPostRepository {

    private let api: GoodPostApi
    private let identity: GoodPostIdentity
    private let cache: GoodPostCache
    private let tokens: GoodPostAdminSessionStoring

    private var renewal: Task<ApiResult<AdminSession>, Never>?

    init(
        api: GoodPostApi = GoodPostApi(),
        identity: GoodPostIdentity = FirebaseRESTIdentity.shared,
        cache: GoodPostCache = GoodPostCache(),
        tokens: GoodPostAdminSessionStoring = KeychainAdminSessionStore()
    ) {
        self.api = api
        self.identity = identity
        self.cache = cache
        self.tokens = tokens
    }

    /// True when a backend URL has been configured for this build.
    var isConfigured: Bool { api.isConfigured }

    /// True when this build can identify a reader at all.
    ///
    /// Read by the home tab to decide what a failed follows fetch means: a reader whose follows
    /// could not be fetched (show what is known, say the rest failed) is a different situation from
    /// a build with no identity provider, which has no list of follows to fetch at all.
    var identifiesReaders: Bool { identity.available }

    // MARK: - Public reads

    /// Cached channels, for the first frame. Nil when nothing is stored.
    func cachedChannels() -> CachedChannels? { cache.loadChannels() }

    /// The saved channel list when it is fresh enough to skip a refetch.
    ///
    /// Both lists are consulted because the tab can legitimately be showing either one: the
    /// reader's follows when there is an identity, the public catalogue otherwise. Returning
    /// whichever was saved most recently is what lets a re-open render from disk with no request.
    func freshChannels(nowMs: Int64 = GoodPostRepository.now()) -> CachedChannels? {
        let followed = cache.loadFollowedChannels().flatMap {
            cache.followedChannelsAreFresh(nowMs: nowMs) ? $0 : nil
        }
        let catalogue = cache.loadChannels().flatMap {
            cache.channelsAreFresh(nowMs: nowMs) ? $0 : nil
        }
        return [followed, catalogue].compactMap { $0 }.max { $0.savedAtMs < $1.savedAtMs }
    }

    /// The reader's own channel list as last saved, for the first frame.
    func cachedFollowedChannels() -> CachedChannels? { cache.loadFollowedChannels() }

    /// Which channels the reader followed as of the last successful read.
    ///
    /// The follow switches are drawn from this before any request, so they do not flash from off to
    /// on while the network answers.
    func cachedFollowedIds() -> Set<String> { cache.loadFollowedIds() }

    func cachedCategories() -> [GoodPostCategory] { cache.loadCategories() }

    func cachedPosts(channelId: String) -> CachedPosts? { cache.loadPosts(channelId: channelId) }

    /// Cached cards for one placement, for the first frame.
    ///
    /// `nowMs` is passed in rather than read here so the expiry rule can be exercised by a test: a
    /// cached card whose window has closed must not be returned, and "has it closed" is a question
    /// about a clock.
    func cachedAds(
        placement: GoodPostAdPlacement,
        nowMs: Int64 = GoodPostRepository.now()
    ) -> CachedAds? {
        cache.loadAds(placement, nowMs: nowMs)
    }

    /// The cached manager list, for the first frame of the ads screen.
    func cachedAdminAds() -> CachedAds? { cache.loadAdminAds() }

    /// The cached external channel directory, for the first frame.
    func cachedDirectory() -> CachedDirectory? { cache.loadDirectory() }

    // MARK: - Offline media

    /// The pictures of everything already saved, back into the image cache.
    ///
    /// Text is the easy half of offline and was already handled by the cache; PICTURES are the
    /// half that makes a saved channel look saved rather than broken. The disk cache holds them
    /// across launches, so this is mostly a second pass over bytes that are already there — it is
    /// what re-fetches the few an eviction or the seven-day TTL took away, and it runs while the
    /// reader is doing something else.
    ///
    /// The list is what this device can actually read without the network: the saved channels, the
    /// followed channels, the saved directory and the posts of the channels it follows. Bounded by
    /// `limit`, because a launch is not the moment to spend a hundred requests.
    func warmSavedImages(limit: Int = 60) async {
        var urls: [String] = []
        urls += (cachedFollowedChannels()?.channels ?? []).compactMap(\.iconUrl)
        urls += (cachedChannels()?.channels ?? []).compactMap(\.iconUrl)
        urls += (cachedDirectory()?.snapshot.allChannels ?? []).compactMap(\.iconUrl)
        for channel in cachedFollowedChannels()?.channels ?? [] {
            urls += (cachedPosts(channelId: channel.id)?.posts ?? []).flatMap { $0.media.compactMap(\.url) }
        }
        await RemoteImageCache.shared.prefetch(urls, limit: limit)
    }

    /// One pass that brings the saved tab up to date, and is meant for the moment a notification
    /// arrives. Returns how many channels it read.
    ///
    /// Android reaches the same place from two directions: a data-only push that carries the name
    /// and the first line, and a fifteen-minute worker that asks one question — "what did my
    /// channels publish" — against the reader's own follows list. This is the client half of that
    /// worker, run when the reader has just been told something happened instead of on a timer:
    /// one follows read, the newest page of each followed channel (which is what stores the posts),
    /// and then the pictures of both. It is bounded on purpose — a notification must not turn into
    /// forty requests — and every read here writes through the same cache the tab opens from.
    @discardableResult
    func refreshSavedContent(limitChannels: Int = 12, postsPerChannel: Int = 12) async -> Int {
        guard let page = await following().value else {
            // No network, or no identity: the saved copy is still the answer, and its pictures are
            // still worth having on disk.
            await warmSavedImages()
            return 0
        }
        var urls: [String] = page.items.compactMap(\.iconUrl)
        var refreshed = 0
        for channel in page.items.prefix(limitChannels) {
            guard let posts = await channelPosts(channelId: channel.id).value else {
                // The channel did not answer — its saved posts are what the reader will see, so
                // their pictures are the ones worth having.
                urls += (cachedPosts(channelId: channel.id)?.posts ?? []).flatMap { $0.media.compactMap(\.url) }
                continue
            }
            refreshed += 1
            urls += posts.items.prefix(postsPerChannel).flatMap { $0.media.compactMap(\.url) }
        }
        await RemoteImageCache.shared.prefetch(urls, limit: 60)
        return refreshed
    }

    /// The channel list, or a search over it.
    ///
    /// Only a **first page** is cached: paging appends to the list on screen, and a cache holding
    /// pages two, three and four as separate entries would be a cache no reader ever sees the rest
    /// of.
    func channels(
        query: String? = nil,
        category: String? = nil,
        sort: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil,
        nowMs: Int64 = GoodPostRepository.now()
    ) async -> ApiResult<GoodPostPage<GoodPostChannel>> {
        let result = await channelsWithSortFallback(
            query: query,
            category: category,
            sort: sort,
            cursor: cursor,
            limit: limit
        )
        if case .ok(let page) = result,
           (cursor ?? "").trimmed.isEmpty,
           (query ?? "").trimmed.isEmpty,
           (category ?? "").trimmed.isEmpty {
            cache.saveChannels(page.items, nowMs: nowMs)
        }
        return result
    }

    /// The channel list, falling back to an order the server is certain to have.
    ///
    /// The discovery screens ask for orders the API grew for them — `active`, `popular`, `new` —
    /// and a deployment still running the previous build refuses those with a 400. That is a real
    /// state, not a hypothetical: the app is installed the moment it is built, while the server is
    /// deployed later, and in between every section of the Channels screen would be an error note
    /// about a parameter the reader never chose.
    ///
    /// The fallback is deliberately **narrow**. Only `invalid_request` on an explicit sort triggers
    /// it, and only for a first page — a rejected cursor is a bug to report, not one to paper over,
    /// and a retry mid-list would restart the feed under the reader. The replacement order is
    /// `name`, which is the one sort the API has always had, so a fallback page is alphabetical
    /// rather than empty.
    private func channelsWithSortFallback(
        query: String?,
        category: String?,
        sort: String?,
        cursor: String?,
        limit: Int?
    ) async -> ApiResult<GoodPostPage<GoodPostChannel>> {
        let first = await api.channels(query: query, category: category, sort: sort, cursor: cursor, limit: limit)
        guard case .failed(_, let code) = first, code == "invalid_request",
              !(sort ?? "").trimmed.isEmpty,
              (cursor ?? "").trimmed.isEmpty else {
            return first
        }
        return await api.channels(query: query, category: category, sort: "name", cursor: nil, limit: limit)
    }

    /// One channel, by id or slug.
    func channel(idOrSlug: String) async -> ApiResult<GoodPostChannel> {
        await api.channel(idOrSlug: idOrSlug)
    }

    // MARK: - A reader's own state
    //
    // Every one of these resolves the identity first, and answers `auth_unavailable` when there is
    // none. That is the same code the backend returns for a deployment that cannot verify anybody,
    // so the screen words "this build has no identity" and "the server cannot check one" the same
    // way — because to the reader they are the same situation: follows are not available right now,
    // and everything public still is.

    /// The channels this reader follows.
    ///
    /// Registered in the channel cache exactly as the public list is: a follower who opens Good Post
    /// offline should see the channels they care about, not an empty tab.
    func following(
        cursor: String? = nil,
        nowMs: Int64 = GoodPostRepository.now()
    ) async -> ApiResult<GoodPostPage<GoodPostChannel>> {
        guard let token = await identity.token() else { return Self.unverified() }
        let result = await api.following(token: token, cursor: cursor)
        if case .ok(let page) = result, (cursor ?? "").trimmed.isEmpty {
            // Saved under the FOLLOWS key, not the public one. The reader's own list and the
            // catalogue are two different lists, and writing one over the other is what made a cold
            // start show the wrong one. An empty result is saved too — "you follow nothing" is an
            // answer, and not caching it would refetch on every open for a reader who follows
            // nobody.
            cache.saveFollowedChannels(page.items, nowMs: nowMs)
            cache.saveFollowedIds(Set(page.items.map(\.id)))
        }
        return result
    }

    /// Follow a channel.
    func follow(idOrSlug: String) async -> ApiResult<GoodPostFollow> {
        guard let token = await identity.token() else { return Self.unverified() }
        return await api.follow(token: token, idOrSlug: idOrSlug)
    }

    /// Stop following a channel.
    func unfollow(idOrSlug: String) async -> ApiResult<GoodPostFollow> {
        guard let token = await identity.token() else { return Self.unverified() }
        return await api.unfollow(token: token, idOrSlug: idOrSlug)
    }

    /// Mute or unmute a followed channel's notifications.
    func setChannelMuted(idOrSlug: String, muted: Bool) async -> ApiResult<GoodPostFollow> {
        guard let token = await identity.token() else { return Self.unverified() }
        return await api.setChannelMuted(token: token, idOrSlug: idOrSlug, muted: muted)
    }

    /// Clear a channel's unread badge.
    func markChannelRead(idOrSlug: String) async -> ApiResult<GoodPostFollow> {
        guard let token = await identity.token() else { return Self.unverified() }
        return await api.markChannelRead(token: token, idOrSlug: idOrSlug)
    }

    /// Where to reach this device, or a refusal that says why.
    ///
    /// Resolves the reader's identity first, like every other reader-scoped call: a push token is
    /// registered against a reader, and there is nobody to register it for until the app has one.
    func registerDevice(deviceToken: String) async -> ApiResult<Void> {
        guard let token = await identity.token() else { return Self.unverified() }
        return await api.registerDevice(token: token, deviceToken: deviceToken)
    }

    /// Stop sending to this device.
    func unregisterDevice(deviceToken: String) async -> ApiResult<Void> {
        guard let token = await identity.token() else { return Self.unverified() }
        return await api.unregisterDevice(token: token, deviceToken: deviceToken)
    }

    // MARK: - Reactions

    /// The emoji the server offers.
    ///
    /// Not reader-scoped and not cached: it is a handful of characters fetched once when the app
    /// first needs them, and caching would be a second copy of the server's own list to keep in
    /// step.
    func reactionEmoji() async -> ApiResult<[String]> {
        await api.reactionEmoji()
    }

    /// This reader's reactions in one channel.
    ///
    /// Merged onto the public posts by the screen, because the two answers cannot come from one
    /// request: the posts are readable with no token at all, and a reader's own choices are only
    /// knowable to somebody who has proved they are that reader.
    ///
    /// A missing identity is **not** an error here — a reader with no token simply has no reactions
    /// to show, and the counts (which are public) still draw.
    func myReactions(idOrSlug: String) async -> [String: String] {
        guard let token = await identity.token() else { return [:] }
        switch await api.myReactions(token: token, idOrSlug: idOrSlug) {
        case .ok(let reactions): return reactions
        default: return [:]
        }
    }

    /// React to a post, or change the reaction.
    func react(postId: String, emoji: String) async -> ApiResult<GoodPostReactionResult> {
        guard let token = await identity.token() else { return Self.unverified() }
        return await api.react(token: token, postId: postId, emoji: emoji)
    }

    /// Take this reader's reaction back off a post.
    func unreact(postId: String, emoji: String?) async -> ApiResult<GoodPostReactionResult> {
        guard let token = await identity.token() else { return Self.unverified() }
        return await api.unreact(token: token, postId: postId, emoji: emoji)
    }

    /// One post, re-read.
    ///
    /// The media viewer's retry: a signed URL is a short-lived capability, so a video that has been
    /// open long enough to outlive its signature fails with the server's own 403 and the only way
    /// forward is a new URL. This asks for exactly the one row that is on screen rather than
    /// re-reading the page — a reader looking at one video should not cost thirty rows.
    func post(postId: String) async -> ApiResult<GoodPostPost> {
        await api.post(postId: postId)
    }

    /// A channel's posts, newest first.
    func channelPosts(
        channelId: String,
        cursor: String? = nil,
        nowMs: Int64 = GoodPostRepository.now()
    ) async -> ApiResult<GoodPostPage<GoodPostPost>> {
        let result = await api.channelPosts(idOrSlug: channelId, cursor: cursor)
        if case .ok(let page) = result, (cursor ?? "").trimmed.isEmpty {
            cache.savePosts(channelId: channelId, posts: page.items, nowMs: nowMs)
        }
        return result
    }

    /// Search inside one channel.
    ///
    /// Deliberately **not** `channelPosts` with a term, and the difference is the cache: a search
    /// result set is not the channel's history, so writing it where the history lives would leave a
    /// reader who searched once opening the channel offline later and seeing their search results as
    /// the feed.
    func searchChannelPosts(
        channelId: String,
        term: String,
        cursor: String? = nil
    ) async -> ApiResult<GoodPostPage<GoodPostPost>> {
        await api.channelPosts(idOrSlug: channelId, cursor: cursor, query: term)
    }

    /// Report that this reader has seen these posts.
    ///
    /// No identity is resolved here, deliberately: the write counts reads, not readers. Requiring a
    /// token would make the number depend on the same identity follows need, so a post would read as
    /// unviewed until somebody signed in to look at it — and it would say nothing about the readers
    /// who never do.
    func reportPostViews(channelId: String, postIds: [String]) async -> ApiResult<Int> {
        await api.reportPostViews(idOrSlug: channelId, postIds: postIds)
    }

    /// A channel's images and videos, for the profile gallery.
    func channelMedia(
        channelId: String,
        cursor: String? = nil
    ) async -> ApiResult<GoodPostPage<GoodPostMediaItem>> {
        await api.channelMedia(idOrSlug: channelId, cursor: cursor)
    }

    /// Categories for the Explore filter.
    func categories() async -> ApiResult<[GoodPostCategory]> {
        let result = await api.categories()
        if case .ok(let categories) = result { cache.saveCategories(categories) }
        return result
    }

    /// The active advertisement cards for one placement.
    ///
    /// Cached, and the cache is what the screen draws first: the cards a reader sees are the same
    /// few on every open, and a request per open made the tab wait on an answer that had not
    /// changed. A failed read leaves the cached cards in place rather than reporting anything — a
    /// missing card is not something a reader can act on, and the screen it sits above still works.
    func ads(
        placement: GoodPostAdPlacement,
        nowMs: Int64 = GoodPostRepository.now()
    ) async -> ApiResult<[GoodPostAd]> {
        let result = await api.ads(placement: placement)
        if case .ok(let ads) = result { cache.saveAds(placement, ads: ads, nowMs: nowMs) }
        return result
    }

    /// The external channel directory, cached on the way through.
    ///
    /// One read for the whole list, and every success replaces the stored copy, so a reader-triggered
    /// refresh is also what updates what they see next time with no network.
    func directory(nowMs: Int64 = GoodPostRepository.now()) async -> ApiResult<DirectorySnapshot> {
        let result = await api.directory()
        if case .ok(let snapshot) = result { cache.saveDirectory(snapshot, nowMs: nowMs) }
        return result
    }

    // MARK: - Administrator session

    /// The stored administrator session, or nil.
    func adminSession() -> AdminSession? { tokens.load() }

    /// Sign in, and keep the session only if the server accepted it.
    func adminLogin(email: String, password: String) async -> ApiResult<AdminSession> {
        let result = await api.adminLogin(email: email, password: password)
        if case .ok(let session) = result { tokens.save(session) }
        return result
    }

    /// The ID token for an email/password creator, or nil.
    ///
    /// Exposed through the repository rather than reached for directly, so the screens keep talking
    /// to one object and a build with no identity provider remains a single substitution rather than
    /// a condition at each call site.
    func creatorToken(email: String, password: String, signUp: Bool) async -> String? {
        await identity.creatorToken(email: email, password: password, signUp: signUp)
    }

    /// Forget the **creator** identity, leaving the reader's alone.
    func creatorSignOut() async {
        await identity.creatorSignOut()
    }

    /// The external sign-in result: a token, a dismissal, or a failure.
    func googleCreatorToken() async -> GoogleSignIn {
        await identity.googleCreatorToken()
    }

    /// Sign in as a creator, keeping the session only if there is one.
    ///
    /// Nothing is stored on a `needsChannel` answer, because there is nothing to store: the account
    /// does not exist until the channel does. The ID token that got this far is held by the caller
    /// for the one call that finishes the job, and never written to disk.
    func creatorLogin(idToken: String) async -> ApiResult<CreatorSignIn> {
        let result = await api.creatorLogin(idToken: idToken)
        if case .ok(.session(let session)) = result { tokens.save(session) }
        return result
    }

    /// A creator's first channel — which also creates the account it belongs to.
    func creatorCreateChannel(idToken: String, name: String) async -> ApiResult<AdminSession> {
        let result = await api.creatorCreateChannel(idToken: idToken, name: name)
        if case .ok(let session) = result { tokens.save(session) }
        return result
    }

    /// Sign out: drop the credentials and everything fetched with them.
    ///
    /// Including the cached public content: a cached list belongs to whoever was last reading, and
    /// leaving it for the next person to open the tab would show them someone else's view without
    /// saying so. A reader's own records — hidden posts, stars, counted views — are untouched.
    func forgetAdminSession() {
        tokens.clear()
        cache.clear()
    }

    /// Revoke the session on the server, so a refresh token does not outlive the device it was
    /// issued to. Best effort: the caller has already forgotten it locally, and a network failure
    /// must not hold anyone on a screen.
    func revokeAdminSession(refreshToken: String) async {
        _ = await api.adminSignOut(refreshToken: refreshToken)
    }

    /// Run an authorized call, renewing the session once if it has lapsed.
    ///
    /// The access token is short on purpose — it can publish and delete on a channel's behalf —
    /// while the session behind it lasts a week, so a request refused with 401 is the ordinary state
    /// of a tab left open rather than an error. Renewing in one place means no call site has to know:
    /// doing it at each of them is how one gets missed, and a missed one reports a refused call as a
    /// fact about the account — which is exactly how an expired token came to be shown as
    /// "No channels. Create one to start publishing."
    ///
    /// A renewal the **server** refused clears the session, so the caller asks for a password instead
    /// of pretending. A renewal that never reached a server does not.
    private func authorized<T>(_ call: (String) async -> ApiResult<T>) async -> ApiResult<T> {
        guard let session = tokens.load() else {
            return .failed(status: 401, code: "unauthorized")
        }

        let first = await call(session.token)
        guard case .failed(let status, _) = first, status == 401 else { return first }

        // Serialised through a single in-flight task. Re-read inside it: another call may have
        // renewed while this one waited, and refreshing again with the token this call started with
        // is the replay the server revokes a session for.
        let renewed = await renewalTask(startedWith: session)
        switch renewed {
        case .ok(let fresh):
            return await call(fresh.token)

        // The server answered and refused the credential: revoked, expired, or the account is
        // disabled. The session is genuinely over, so it is forgotten and the caller asks for a
        // password. Only 401 and 403 qualify — a 5xx is the server having a problem with itself, and
        // discarding the only copy of a session over it would be the same mistake as a dropped
        // connection.
        case .failed(let status, let code):
            if renewalEndsSession(status: status) {
                tokens.clear()
                return first
            }
            return .failed(status: status, code: code)

        // Nothing answered. This is NOT the server ending the session, and treating it as one was a
        // real bug: a dropped connection, a request that timed out, or a host that was cold-starting
        // all arrived here, cleared the stored session — the only copy — and then reported the 401
        // as "Your session ended. Sign in again." The session is kept, and the next call renews
        // again, so a connection that comes back recovers by itself with nobody retyping a password.
        case .unreachable:
            return .unreachable
        }
    }

    /// One renewal at a time, whichever call arrives first.
    private func renewalTask(startedWith session: AdminSession) async -> ApiResult<AdminSession> {
        if let inFlight = renewal {
            let joined = await inFlight.value
            // The waiting caller's token is stale by definition if the renewal produced a different
            // one, which is what makes the retry meaningful rather than a replay.
            if case .ok(let renewed) = joined, renewed.token != session.token { return joined }
            if case .unreachable = joined { return joined }
            return joined
        }

        let task = Task { [api] in await api.adminRefresh(refreshToken: session.refreshToken) }
        renewal = task
        let result = await task.value
        renewal = nil

        // Saved before the retry, not after: the pair is rotated, so a crash between here and the
        // call would leave the stored one already spent.
        if case .ok(let fresh) = result { tokens.save(fresh) }
        return result
    }

    // MARK: - Channels (admin)

    func adminChannels() async -> ApiResult<[GoodPostChannel]> {
        await authorized { token in await self.api.adminChannels(token: token) }
    }

    func adminCreateChannel(body: [String: Any]) async -> ApiResult<GoodPostChannel> {
        await authorized { token in await self.api.adminCreateChannel(token: token, body: body) }
    }

    func adminUpdateChannel(
        channelId: String,
        body: [String: Any]
    ) async -> ApiResult<GoodPostChannel> {
        await authorized { token in
            await self.api.adminUpdateChannel(token: token, channelId: channelId, body: body)
        }
    }

    /// Delete a channel, with everything that belonged to it.
    ///
    /// Hard on the server: the posts, the media rows, the objects in the bucket and the login created
    /// to run the channel go with it. Offered to a super administrator and refused to anyone else by
    /// the server, not by this call.
    func adminDeleteChannel(channelId: String) async -> ApiResult<Void> {
        await authorized { token in await self.api.adminDeleteChannel(token: token, channelId: channelId) }
    }

    // MARK: - Brain Rot repository (admin)

    func adminBrainRotKeywords() async -> ApiResult<[GoodPostBrainRotRule]> {
        await authorized { token in await self.api.adminBrainRotKeywords(token: token) }
    }

    func adminBrainRotChannels() async -> ApiResult<[GoodPostBrainRotRule]> {
        await authorized { token in await self.api.adminBrainRotChannels(token: token) }
    }

    func adminAddBrainRotKeyword(
        keyword: String,
        reason: String?
    ) async -> ApiResult<GoodPostBrainRotRule> {
        await authorized { token in
            await self.api.adminAddBrainRotKeyword(token: token, keyword: keyword, reason: reason)
        }
    }

    func adminAddBrainRotChannel(
        handle: String,
        displayName: String?,
        reason: String?
    ) async -> ApiResult<GoodPostBrainRotRule> {
        await authorized { token in
            await self.api.adminAddBrainRotChannel(
                token: token,
                handle: handle,
                displayName: displayName,
                reason: reason
            )
        }
    }

    func adminSetBrainRotRuleEnabled(
        kind: String,
        ruleId: String,
        enabled: Bool
    ) async -> ApiResult<Void> {
        await authorized { token in
            await self.api.adminSetBrainRotRuleEnabled(
                token: token,
                kind: kind,
                ruleId: ruleId,
                enabled: enabled
            )
        }
    }

    func adminDeleteBrainRotRule(kind: String, ruleId: String) async -> ApiResult<Void> {
        await authorized { token in
            await self.api.adminDeleteBrainRotRule(token: token, kind: kind, ruleId: ruleId)
        }
    }

    func adminBrainRotSubmissions(
        status: String = "pending"
    ) async -> ApiResult<[GoodPostBrainRotSubmission]> {
        await authorized { token in await self.api.adminBrainRotSubmissions(token: token, status: status) }
    }

    func adminReviewBrainRotSubmission(
        submissionId: String,
        decision: String
    ) async -> ApiResult<Void> {
        await authorized { token in
            await self.api.adminReviewBrainRotSubmission(
                token: token,
                submissionId: submissionId,
                decision: decision
            )
        }
    }

    func adminBrainRotDashboard() async -> ApiResult<GoodPostBrainRotDashboard> {
        await authorized { token in await self.api.adminBrainRotDashboard(token: token) }
    }

    /// The false-positive queue: targets users reported as wrongly blocked.
    func adminBrainRotReports() async -> ApiResult<[GoodPostBrainRotReport]> {
        await authorized { token in await self.api.adminBrainRotReports(token: token) }
    }

    /// Answer every open report for one target: keep the rule, or remove it.
    func adminResolveBrainRotReport(
        kind: String,
        value: String,
        resolution: String
    ) async -> ApiResult<Void> {
        await authorized { token in
            await self.api.adminResolveBrainRotReport(
                token: token,
                kind: kind,
                value: value,
                resolution: resolution
            )
        }
    }

    // MARK: - Posts (admin)

    func adminCreatePost(
        channelId: String,
        body: [String: Any]
    ) async -> ApiResult<GoodPostPost> {
        await authorized { token in
            await self.api.adminCreatePost(token: token, channelId: channelId, body: body)
        }
    }

    func adminUpdatePost(postId: String, body: [String: Any]) async -> ApiResult<GoodPostPost> {
        await authorized { token in
            await self.api.adminUpdatePost(token: token, postId: postId, body: body)
        }
    }

    func adminDeletePost(postId: String) async -> ApiResult<Void> {
        await authorized { token in await self.api.adminDeletePost(token: token, postId: postId) }
    }

    /// Remove a selection of posts in one request.
    ///
    /// One call rather than one per post: the server applies the whole selection or none of it, so a
    /// failure cannot leave the list half-emptied with no way to tell which half went.
    func adminDeletePosts(postIds: [String]) async -> ApiResult<Int> {
        await authorized { token in await self.api.adminDeletePosts(token: token, postIds: postIds) }
    }

    // MARK: - Advertisements (admin)

    /// Every card, active or not, for the admin list.
    func adminAds() async -> ApiResult<[GoodPostAd]> {
        let result = await authorized { token in await self.api.adminAds(token: token) }
        // Saved so the manager list draws from disk on the next open: the cards change rarely, and
        // waiting on the network to redraw the same rows is what made the screen feel slow.
        if case .ok(let ads) = result {
            cache.saveAdminAds(ads, nowMs: Self.now())
        }
        return result
    }

    /// One card, for the editor.
    func adminAd(adId: String) async -> ApiResult<GoodPostAd> {
        await authorized { token in await self.api.adminAd(token: token, adId: adId) }
    }

    func adminCreateAd(body: [String: Any]) async -> ApiResult<GoodPostAd> {
        await authorized { token in await self.api.adminCreateAd(token: token, body: body) }
    }

    func adminUpdateAd(adId: String, body: [String: Any]) async -> ApiResult<GoodPostAd> {
        await authorized { token in await self.api.adminUpdateAd(token: token, adId: adId, body: body) }
    }

    func adminDeleteAd(adId: String) async -> ApiResult<Void> {
        await authorized { token in await self.api.adminDeleteAd(token: token, adId: adId) }
    }

    // MARK: - Channel directory (admin)
    //
    // Super administrators only, and the server is where that is enforced. The manager re-reads the
    // whole list after every write, so each mutation here returns nothing the screen has to
    // interpret.

    func adminDirectory() async -> ApiResult<DirectorySnapshot> {
        let result = await authorized { token in await self.api.adminDirectory(token: token) }
        // Saved like every other successful directory read, so an administrator's change is what a
        // reader will see offline next.
        if case .ok(let snapshot) = result {
            cache.saveDirectory(snapshot, nowMs: Self.now())
        }
        return result
    }

    func adminCreateDirectoryCategory(name: String) async -> ApiResult<Void> {
        await authorized { token in
            await self.api.adminCreateDirectoryCategory(token: token, body: ["name": name])
        }
    }

    func adminUpdateDirectoryCategory(categoryId: String, name: String) async -> ApiResult<Void> {
        await authorized { token in
            await self.api.adminUpdateDirectoryCategory(
                token: token,
                categoryId: categoryId,
                body: ["name": name]
            )
        }
    }

    func adminDeleteDirectoryCategory(categoryId: String) async -> ApiResult<Void> {
        await authorized { token in
            await self.api.adminDeleteDirectoryCategory(token: token, categoryId: categoryId)
        }
    }

    func adminCreateDirectorySubcategory(
        categoryId: String,
        name: String
    ) async -> ApiResult<Void> {
        await authorized { token in
            await self.api.adminCreateDirectorySubcategory(
                token: token,
                body: ["categoryId": categoryId, "name": name]
            )
        }
    }

    func adminUpdateDirectorySubcategory(
        subcategoryId: String,
        name: String
    ) async -> ApiResult<Void> {
        await authorized { token in
            await self.api.adminUpdateDirectorySubcategory(
                token: token,
                subcategoryId: subcategoryId,
                body: ["name": name]
            )
        }
    }

    func adminDeleteDirectorySubcategory(subcategoryId: String) async -> ApiResult<Void> {
        await authorized { token in
            await self.api.adminDeleteDirectorySubcategory(token: token, subcategoryId: subcategoryId)
        }
    }

    /// Add a channel by handle.
    ///
    /// The name and the icon are left out so the server copies them from the platform: the point of
    /// adding by handle is that the administrator should not have to look the channel up themselves.
    func adminCreateDirectoryChannel(
        platform: String,
        handle: String,
        categoryId: String?,
        subcategoryId: String?
    ) async -> ApiResult<Void> {
        await authorized { token in
            var body: [String: Any] = ["platform": platform, "handle": handle]
            if let categoryId { body["categoryId"] = categoryId }
            if let subcategoryId { body["subcategoryId"] = subcategoryId }
            return await self.api.adminCreateDirectoryChannel(token: token, body: body)
        }
    }

    func adminUpdateDirectoryChannel(
        channelId: String,
        name: String?,
        categoryId: String?,
        subcategoryId: String?
    ) async -> ApiResult<Void> {
        await authorized { token in
            let body: [String: Any] = [
                "name": name ?? NSNull(),
                "categoryId": categoryId ?? NSNull(),
                "subcategoryId": subcategoryId ?? NSNull(),
            ]
            return await self.api.adminUpdateDirectoryChannel(
                token: token,
                channelId: channelId,
                body: body
            )
        }
    }

    func adminRefreshDirectoryChannel(channelId: String) async -> ApiResult<Void> {
        await authorized { token in
            await self.api.adminRefreshDirectoryChannel(token: token, channelId: channelId)
        }
    }

    func adminDeleteDirectoryChannel(channelId: String) async -> ApiResult<Void> {
        await authorized { token in
            await self.api.adminDeleteDirectoryChannel(token: token, channelId: channelId)
        }
    }

    // MARK: - Media

    /// Upload one picked file, and return it once the server has confirmed it.
    ///
    /// The three steps live here rather than in a screen so the sequencing cannot be got wrong at a
    /// call site: a presign that is never confirmed, or a confirm after a PUT that failed, would both
    /// leave an attachment the composer believes is ready and the server refuses. Every failure exits
    /// the same way — with the code that describes it — and nothing is left half-claimed, because a
    /// media row is only attachable after the server has found its object.
    func adminUploadMedia(attachment: GoodPostAttachment) async -> ApiResult<GoodPostMedia> {
        // The two authenticated steps of the handshake renew independently; the PUT between them goes
        // to the bucket with a presigned URL and needs no session at all, so a retry after renewal
        // cannot double-upload.
        let presign = await authorized { token in
            await self.api.adminRequestUpload(
                token: token,
                contentType: attachment.contentType,
                byteSize: attachment.byteSize,
                width: attachment.width,
                height: attachment.height,
                durationMs: attachment.durationMs,
                // Sent for a document and for nothing else. The name **is** the document's card, so a
                // server that had to guess one would be inventing the only part of it a reader can
                // see — and for an image it is a client string stored for no purpose.
                fileName: attachment.isDocument ? attachment.fileName : nil
            )
        }

        let upload: GoodPostUpload
        switch presign {
        case .ok(let value): upload = value
        // The server's own code, passed straight through: `media_unavailable` is an answer about the
        // deployment and the composer words it differently from a failed transfer.
        case .failed, .unreachable: return presign.map { _ in GoodPostMedia.placeholder }
        }

        let put = await api.putFile(
            uploadUrl: upload.uploadUrl,
            headers: upload.uploadHeaders,
            fileURL: attachment.fileURL
        )
        switch put {
        case .ok: break
        // Nothing was stored, so there is nothing to confirm. Left unclaimed, the pending row is
        // pruned by the server's own sweep.
        case .failed(let status, let code): return .failed(status: status, code: code)
        case .unreachable: return .unreachable
        }

        // The confirmation is what makes it attachable, so it is not optional and its failure is the
        // caller's answer: an upload the server has not verified is an attachment that would fail at
        // publish time instead.
        return await authorized { token in
            await self.api.adminConfirmUpload(token: token, mediaId: upload.mediaId)
        }
    }

    // MARK: - Internals

    /// A reader-scoped call with nobody to make it as.
    ///
    /// 503 and `auth_unavailable`, matching the backend's own answer for the same condition, rather
    /// than 401: the reader is not signed out and has nothing to sign in with — the deployment simply
    /// cannot verify anybody.
    private static func unverified<T>() -> ApiResult<T> {
        .failed(status: 503, code: "auth_unavailable")
    }

    /// The clock, in one place, so a test can pass its own value into the calls that need one.
    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

extension GoodPostMedia {
    /// A stand-in used only where a failed result is mapped into a media-shaped one; it is never
    /// returned as a value.
    fileprivate static let placeholder = GoodPostMedia(
        id: "",
        kind: "",
        contentType: "",
        byteSize: 0,
        width: nil,
        height: nil,
        durationMs: nil,
        fileName: nil,
        position: 0,
        url: nil
    )
}

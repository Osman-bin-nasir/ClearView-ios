import Foundation

/// The outcome of a backend call.
///
/// `failed` and `unreachable` are deliberately distinct. "The server said no" and "we never
/// reached the server" need different words in front of a reader, and a screen must never claim
/// a success it was not told about.
enum ApiResult<Value> {
    case ok(Value)
    /// The server answered with a machine-readable error code.
    case failed(status: Int, code: String)
    /// No usable answer: offline, DNS, TLS, timeout, or an unparseable body.
    case unreachable

    var value: Value? {
        if case .ok(let value) = self { return value }
        return nil
    }

    var isOk: Bool {
        if case .ok = self { return true }
        return false
    }

    /// The error code the UI branches on, when there was one.
    var failureCode: String? {
        if case .failed(_, let code) = self { return code }
        return nil
    }

    var status: Int? {
        if case .failed(let status, _) = self { return status }
        return nil
    }

    func map<Other>(_ transform: (Value) -> Other) -> ApiResult<Other> {
        switch self {
        case .ok(let value): return .ok(transform(value))
        case .failed(let status, let code): return .failed(status: status, code: code)
        case .unreachable: return .unreachable
        }
    }
}

extension ApiResult: Equatable where Value: Equatable {}

/// Maps a non-2xx response to the error code the UI branches on.
///
/// Pure, so it is unit-tested directly. Two rules: a body carrying an `error` code always wins
/// over a guess from the status line, and when there is no body the status is still turned into
/// something meaningful rather than an empty string that would silently match no branch.
func goodPostErrorCode(status: Int, body: String?) -> String {
    if let body, !body.trimmed.isEmpty,
       let data = body.data(using: .utf8),
       let dictionary = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let code = JSONScalar.string(dictionary["error"]), !code.isEmpty {
        return code
    }

    switch status {
    case 400: return "invalid_request"
    case 401: return "unauthorized"
    case 403: return "forbidden"
    case 404: return "not_found"
    case 408: return "timeout"
    case 413: return "payload_too_large"
    case 429: return "rate_limited"
    default: return status >= 500 ? "server_error" : "http_error"
    }
}

/// One response, as the transport hands it back.
struct GoodPostResponse: Sendable {
    let status: Int
    let data: Data

    var text: String? { String(data: data, encoding: .utf8) }

    var jsonObject: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// The bytes-level half of the API.
///
/// A protocol rather than a direct `URLSession` call for the same reason the Quran fetcher is
/// one: the network is the only part of this layer that is not deterministic, and the parts
/// whose *failure* paths matter most — a refused token, a proxy's HTML 502, a body that is not
/// the shape the contract promised — are exactly the ones a test can then produce on demand.
protocol GoodPostTransport: Sendable {
    /// Sends one JSON request.
    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> GoodPostResponse

    /// PUTs one file to a presigned URL, streaming from disk.
    func put(fileURL: URL, url: URL, headers: [String: String]) async throws -> GoodPostResponse
}

/// The real transport: `URLSession`.
///
/// On iOS there is no reason to hand-roll the client — connection pooling, HTTP/2, disk-backed
/// response caching and background transfer all come with the platform — so this is a thin
/// wrapper that fixes the headers, the timeouts and the shape of the answer. Uploads get a much
/// longer budget than a JSON call, because the body is a file rather than a few hundred bytes;
/// still bounded, because a stalled upload must fail with something the composer can word rather
/// than hang forever behind a spinner.
struct URLSessionGoodPostTransport: GoodPostTransport {

    private let session: URLSession
    private let jsonTimeout: TimeInterval
    private let uploadTimeout: TimeInterval

    init(
        session: URLSession = .shared,
        jsonTimeout: TimeInterval = 15,
        uploadTimeout: TimeInterval = 120
    ) {
        self.session = session
        self.jsonTimeout = jsonTimeout
        self.uploadTimeout = uploadTimeout
    }

    func send(method: String, url: URL, headers: [String: String], body: Data?) async throws -> GoodPostResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = jsonTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClearView-iOS", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        return GoodPostResponse(status: (response as? HTTPURLResponse)?.statusCode ?? -1, data: data)
    }

    func put(fileURL: URL, url: URL, headers: [String: String]) async throws -> GoodPostResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = uploadTimeout
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        // `upload(for:fromFile:)` streams the file rather than reading it into memory, which is
        // what keeps a hundred-megabyte video from costing its own size in resident memory. It
        // also sets a fixed content length, which is what the signature signed — so the bucket
        // can reject a truncated send instead of storing half a file.
        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        return GoodPostResponse(status: (response as? HTTPURLResponse)?.statusCode ?? -1, data: data)
    }
}

/// A presigned upload, plus the media id every later step refers to.
///
/// `uploadUrl` is a capability scoped to one object, one method and a short expiry. It is held
/// only for the duration of the PUT and never persisted: it expires, and a cached one would be a
/// stale key rather than a saved round trip.
struct GoodPostUpload: Equatable {
    let mediaId: String
    let uploadUrl: String
    /// `Content-Type`, and anything else the signature covers.
    let uploadHeaders: [String: String]
    /// `image`, `video` or `audio`.
    let kind: String
}

/// The two answers a creator sign-in can have.
///
/// A pair rather than an optional session, because "no channel yet" is a step in the flow and
/// not a failure: a nil session would have to be told apart from a sign-in that failed, and
/// those need completely different screens.
enum CreatorSignIn: Equatable {
    /// This creator already runs a channel.
    case session(AdminSession)
    /// No account yet. The address is what the identity provider knows, shown so the next screen
    /// can say **which** identity is about to own a channel.
    case needsChannel(email: String?)
}

/// A signed-in administrator, as the app holds it.
struct AdminSession: Equatable {
    let token: String
    /// The long-lived half of the session.
    ///
    /// Kept because the access token is deliberately short — it can publish and delete on a
    /// channel's behalf — while the session behind it lasts a week. Throwing this away is what
    /// made an expired token look like an empty account: with nothing to renew with, every
    /// refused call became a failure the dashboard rendered as "you have no channels".
    ///
    /// The server **rotates** it on every renewal: the new value is the only one that works for
    /// more than one further attempt, so the newest pair is written back after every refresh and
    /// two renewals must never run at once.
    let refreshToken: String
    /// `super_admin` or `channel_admin`. The server decides; the app words it.
    let role: String
    let email: String
    /// The channel a `channel_admin` is confined to; nil for a super admin.
    let channelId: String?

    var isSuperAdmin: Bool { role == "super_admin" }
}

/// Whether a renewal the server **refused** means the session is over.
///
/// The whole rule, in one place, because getting it wrong is not a cosmetic bug. A renewal can
/// fail in several ways and they call for opposite responses:
///
///  * **401 / 403** — the server looked at the refresh token and rejected it. Revoked, expired,
///    or the account was disabled. The session is genuinely over and the only honest next step
///    is to forget it and ask for a password.
///  * **A 5xx** — the server broke while answering. That says nothing about the credential, and
///    discarding the session over it would be guessing.
///  * **Nothing at all** (offline, DNS, TLS, timeout) — handled by the caller, which keeps the
///    session. A dropped connection is not the server ending a session.
///
/// Only the first case may end a session. Public and `internal` rather than private so it is
/// tested directly: the mistake it exists to prevent was invisible from the app.
func renewalEndsSession(status: Int) -> Bool {
    status == 401 || status == 403
}

/// Marks a body that parsed as JSON but not as the expected shape.
struct GoodPostContractBreak: Error {}

/// The root this build talks to.
///
/// Read from the app's `Info.plist` under `GoodPostBaseURL`, which is the iOS equivalent of
/// Android's `BuildConfig.GOODPOST_BASE_URL`: the value is a build setting, not a constant in
/// the source, so pointing a build at a staging backend needs no code change. An empty value is
/// a supported state — every read then reports itself as unreachable, which is the same thing
/// the app would say offline.
enum GoodPostConfiguration {
    static let baseUrlKey = "GoodPostBaseURL"

    static var baseURL: String {
        (Bundle.main.object(forInfoDictionaryKey: baseUrlKey) as? String)?.trimmed
            ?? "https://clearview-1neb.onrender.com"
    }
}

/// The Good Post transport: one client for every endpoint.
///
/// No third-party HTTP or serialisation library is introduced — `URLSession` and
/// `JSONSerialization` are the platform's own. One transport serves every endpoint, so a new
/// call cannot arrive with different timeouts, a different way of reading an error code, or its
/// own idea of what "unreachable" means.
///
/// **The read half carries no credential, and that is the product.** Browsing, searching,
/// opening a channel and reading its posts are anonymous calls, which is what makes Good Post
/// usable with no signup, no login and no account.
///
/// **The write half is the admin surface only**, and it is a different path prefix with a
/// different token: `/admin/api`. A reader's device holds no token at all, so there is nothing
/// on it that could be used to publish.
///
/// Media is the one thing that does **not** travel through this API on its way out: the bytes go
/// straight to the bucket with a presigned URL, so a hundred-megabyte video never passes through
/// the backend process at all.
struct GoodPostApi {

    private let baseUrl: @Sendable () -> String
    private let transport: GoodPostTransport

    /// Anonymous reads. The root of the versioned API, not a `/public` sub-prefix: with the
    /// reader-facing surface the only thing under `/api/v1`, those paths *are* the product's own.
    private static let publicPath = "/api/v1"
    /// The administrator surface, on its own prefix and its own token.
    private static let adminPath = "/admin/api"
    /// A reader's own state, under the public prefix but behind a token.
    private static let readerPath = "\(publicPath)/readers"

    init(
        baseUrl: @escaping @Sendable () -> String = { GoodPostConfiguration.baseURL },
        transport: GoodPostTransport = URLSessionGoodPostTransport()
    ) {
        self.baseUrl = baseUrl
        self.transport = transport
    }

    /// True when a backend URL has been configured for this build.
    var isConfigured: Bool { !baseUrl().trimmed.isEmpty }

    // MARK: - Public reads

    /// Channel list and search.
    ///
    /// One endpoint for both: browsing is a search with an empty term, and the list screen
    /// renders the same rows either way. `limit` is sent for a discovery section, which previews
    /// a handful of channels and would otherwise fetch a whole page to show five of them.
    func channels(
        query: String? = nil,
        category: String? = nil,
        sort: String? = nil,
        cursor: String? = nil,
        limit: Int? = nil
    ) async -> ApiResult<GoodPostPage<GoodPostChannel>> {
        await parsedGet(channelsPath(query: query, category: category, sort: sort, cursor: cursor, limit: limit)) {
            GoodPostCodec.channelPage(from: $0)
        }
    }

    /// The categories Explore can filter by.
    func categories() async -> ApiResult<[GoodPostCategory]> {
        await parsedGet("\(GoodPostApi.publicPath)/categories") { GoodPostCodec.categories(from: $0) }
    }

    /// The advertisement cards active for one placement.
    ///
    /// Anonymous, like every other public read: a card is shown to readers who have no account
    /// at all. Which cards come back — enabled, started, not expired, placed here — is decided
    /// entirely by the server, so the app carries none of those rules and cannot show a card it
    /// should not.
    func ads(placement: GoodPostAdPlacement) async -> ApiResult<[GoodPostAd]> {
        await parsedGet("\(GoodPostApi.publicPath)/ads?placement=" + encode(placement.wire)) {
            GoodPostCodec.adList(from: $0)
        }
    }

    /// The external channel directory. Anonymous and read-only, like every other public read:
    /// the list is the same for everybody, so there is nothing on this call that could carry a
    /// credential.
    func directory() async -> ApiResult<DirectorySnapshot> {
        await parsedGet("\(GoodPostApi.publicPath)/directory", parse: DirectoryCodec.snapshot(from:))
    }

    /// One channel, by uuid or by the slug a share link carries.
    func channel(idOrSlug: String) async -> ApiResult<GoodPostChannel> {
        await parsedGet("\(GoodPostApi.publicPath)/channels/\(encode(idOrSlug))") { body in
            guard let channel = GoodPostCodec.singleChannel(from: body) else { throw GoodPostContractBreak() }
            return channel
        }
    }

    /// A channel's posts, newest first, optionally narrowed by a search term.
    ///
    /// One call for the feed and for a search inside the channel, because the server answers both
    /// from one endpoint: a separate search path would be a second payload shape and a second
    /// paging contract for the same list.
    func channelPosts(
        idOrSlug: String,
        cursor: String? = nil,
        query: String? = nil
    ) async -> ApiResult<GoodPostPage<GoodPostPost>> {
        let term = (query ?? "").trimmed
        var pairs: [String] = []
        if let cursor, !cursor.trimmed.isEmpty { pairs.append("cursor=" + encode(cursor)) }
        if !term.isEmpty { pairs.append("q=" + encode(term)) }
        let suffix = pairs.isEmpty ? "" : "?" + pairs.joined(separator: "&")
        return await parsedGet("\(GoodPostApi.publicPath)/channels/\(encode(idOrSlug))/posts" + suffix) {
            GoodPostCodec.postPage(from: $0)
        }
    }

    /// A channel's images and videos, for the profile gallery.
    func channelMedia(
        idOrSlug: String,
        cursor: String? = nil
    ) async -> ApiResult<GoodPostPage<GoodPostMediaItem>> {
        await parsedGet(
            "\(GoodPostApi.publicPath)/channels/\(encode(idOrSlug))/media" + pageQuery(cursor)
        ) { GoodPostCodec.mediaPage(from: $0) }
    }

    /// One post, reachable on its own from a link or a share.
    func post(postId: String) async -> ApiResult<GoodPostPost> {
        await parsedGet("\(GoodPostApi.publicPath)/posts/\(encode(postId))") { body in
            guard let post = GoodPostCodec.singlePost(from: body) else { throw GoodPostContractBreak() }
            return post
        }
    }

    /// Tell the server which posts this reader has just seen.
    ///
    /// The one write on the public surface, and it needs no credential: a read is not an account,
    /// and asking somebody to sign in before their read could be counted would make the count a
    /// census of accounts rather than of readers.
    ///
    /// Fire-and-forget from the caller's point of view — nothing in the UI waits on it, and a
    /// failure is not reported, because "we could not count your read" is not something a reader
    /// can act on. The ids are the server's own, so the worst a wrong batch can do is count a post
    /// that was on screen.
    func reportPostViews(idOrSlug: String, postIds: [String]) async -> ApiResult<Int> {
        guard !postIds.isEmpty else { return .ok(0) }
        return await parsedCall(
            method: "POST",
            path: "\(GoodPostApi.publicPath)/channels/\(encode(idOrSlug))/posts/views",
            body: ["ids": postIds],
            bearer: nil
        ) { body in JSONScalar.int(body["counted"]) ?? 0 }
    }

    // MARK: - A reader's own state
    //
    // The token is a parameter rather than something this type fetches: the transport stays a
    // transport, and the identity is resolved once per call in `GoodPostRepository`. It also
    // keeps the one thing that must never happen expressible — there is no path from these
    // methods to a request sent with somebody else's credential, because the only token they can
    // send is the one they were handed.

    /// The channels this reader follows, most recently active first.
    func following(token: String, cursor: String? = nil) async -> ApiResult<GoodPostPage<GoodPostChannel>> {
        await parsedCall(
            method: "GET",
            path: "\(GoodPostApi.readerPath)/me/following" + pageQuery(cursor),
            body: nil,
            bearer: token
        ) { GoodPostCodec.channelPage(from: $0) }
    }

    /// Follow a channel. Idempotent: following twice is one follow.
    func follow(token: String, idOrSlug: String) async -> ApiResult<GoodPostFollow> {
        await followCall(method: "POST", token: token, idOrSlug: idOrSlug, body: nil)
    }

    /// Stop following a channel.
    func unfollow(token: String, idOrSlug: String) async -> ApiResult<GoodPostFollow> {
        await followCall(method: "DELETE", token: token, idOrSlug: idOrSlug, body: nil)
    }

    /// Mute or unmute a followed channel's notifications.
    func setChannelMuted(
        token: String,
        idOrSlug: String,
        muted: Bool
    ) async -> ApiResult<GoodPostFollow> {
        await followCall(method: "PATCH", token: token, idOrSlug: idOrSlug, body: ["muted": muted])
    }

    /// Clear a channel's unread badge: the reader has opened it.
    ///
    /// No timestamp is sent — the server's clock decides whether a post came before or after the
    /// reader looked, and a device clock that is wrong would otherwise clear a badge for posts
    /// that had not arrived yet.
    func markChannelRead(token: String, idOrSlug: String) async -> ApiResult<GoodPostFollow> {
        await followCall(
            method: "POST",
            token: token,
            idOrSlug: idOrSlug,
            body: nil,
            suffix: "/read"
        )
    }

    /// Register this install for push.
    ///
    /// The token is the **device's** and the reader is the token's owner, resolved server-side
    /// from the bearer token — so this call cannot subscribe anybody else's phone to anything.
    /// Idempotent by design: it is called on every app start (a token can rotate while the app is
    /// not running), and registering twice must cost one row and not two.
    func registerDevice(
        token: String,
        deviceToken: String,
        platform: String = "ios"
    ) async -> ApiResult<Void> {
        await parsedCall(
            method: "POST",
            path: "\(GoodPostApi.readerPath)/me/devices",
            body: ["token": deviceToken, "platform": platform],
            bearer: token
        ) { _ in () }
    }

    /// Stop sending this install anything.
    ///
    /// Called when the reader turns notifications off. Best effort on the client: if it fails,
    /// the push still arrives and the device's own switch drops it — the alternative (refusing to
    /// turn the switch off because a request failed) would be a switch that lies about what it
    /// did.
    func unregisterDevice(token: String, deviceToken: String) async -> ApiResult<Void> {
        await parsedCall(
            method: "DELETE",
            path: "\(GoodPostApi.readerPath)/me/devices/\(encode(deviceToken))",
            body: nil,
            bearer: token
        ) { _ in () }
    }

    // MARK: - Reactions

    /// The emoji the product offers.
    ///
    /// Fetched rather than hard-coded in the app: the server refuses anything outside its own
    /// list, and an app carrying a copy of it would one day offer a seventh emoji the server
    /// rejects — a button that always fails. No token: it is the same set for everybody.
    func reactionEmoji() async -> ApiResult<[String]> {
        await parsedGet("\(GoodPostApi.readerPath)/reactions") { GoodPostCodec.reactionVocabulary(from: $0) }
    }

    /// The caller's own reactions in one channel.
    ///
    /// A second, tiny read alongside the public posts, because the public payload cannot carry
    /// per-reader state — it answers without a token by design. The app merges the two when it
    /// opens a channel.
    func myReactions(token: String, idOrSlug: String) async -> ApiResult<[String: String]> {
        await parsedCall(
            method: "GET",
            path: "\(GoodPostApi.readerPath)/me/reactions/\(encode(idOrSlug))",
            body: nil,
            bearer: token
        ) { GoodPostCodec.readerReactions(from: $0) }
    }

    /// React to a post, or change the reaction.
    ///
    /// PUT: the path names the reader's reaction to one post and the body is the value, so
    /// repeating it is the same state rather than a second reaction.
    func react(token: String, postId: String, emoji: String) async -> ApiResult<GoodPostReactionResult> {
        await reactionCall(method: "PUT", token: token, postId: postId, body: ["emoji": emoji], suffix: "")
    }

    /// Take the reaction back off.
    ///
    /// The emoji the app was showing travels as a query parameter, so the answer can carry the
    /// count of **that** emoji — the number currently on screen, which is the one the card has to
    /// correct.
    func unreact(token: String, postId: String, emoji: String?) async -> ApiResult<GoodPostReactionResult> {
        let trimmed = (emoji ?? "").trimmed
        let suffix = trimmed.isEmpty ? "" : "?emoji=" + encode(trimmed)
        return await reactionCall(method: "DELETE", token: token, postId: postId, body: nil, suffix: suffix)
    }

    // MARK: - Administrator sign-in

    /// Sign in as an administrator.
    ///
    /// This is **not** a viewer account and creates nothing: the addresses that work here were
    /// provisioned by the deployment, never by the app. The one message for every refusal comes
    /// from the server, so the screen cannot reveal whether an address exists.
    func adminLogin(email: String, password: String) async -> ApiResult<AdminSession> {
        await parsedCall(
            method: "POST",
            path: "\(GoodPostApi.adminPath)/auth/login",
            body: ["email": email, "password": password],
            bearer: nil,
            parse: adminSession
        )
    }

    /// Sign in as a creator with a third-party ID token.
    ///
    /// The token is the **credential** here, not a session: it goes in the `Authorization` header
    /// of a route that no bearer token of ours can call, because a creator who has not created a
    /// channel yet has no account for a session to name.
    func creatorLogin(idToken: String) async -> ApiResult<CreatorSignIn> {
        await parsedCall(
            method: "POST",
            path: "\(GoodPostApi.adminPath)/auth/firebase",
            body: nil,
            bearer: idToken
        ) { body in
            if JSONScalar.bool(body["needsChannel"]) == true {
                return CreatorSignIn.needsChannel(email: JSONScalar.nullableString(body["email"]))
            }
            return CreatorSignIn.session(try adminSession(from: body))
        }
    }

    /// A creator's first, and only, channel.
    ///
    /// Authenticated by the ID token for the same reason as above: there is no session yet, and
    /// this call is what creates the account a session would name. The reply is a full sign-in,
    /// so the app never sits in the state between "channel created" and "signed in".
    func creatorCreateChannel(idToken: String, name: String) async -> ApiResult<AdminSession> {
        await parsedCall(
            method: "POST",
            path: "\(GoodPostApi.adminPath)/creator/channel",
            body: ["name": name],
            bearer: idToken,
            parse: adminSession
        )
    }

    /// Exchange the session's long-lived half for a new pair.
    ///
    /// Sent with no bearer token on purpose: the whole point of this call is that the access
    /// token it would carry has expired. The reply includes a **new** refresh token — the server
    /// rotates it, so the one used here stops working immediately after.
    func adminRefresh(refreshToken: String) async -> ApiResult<AdminSession> {
        await parsedCall(
            method: "POST",
            path: "\(GoodPostApi.adminPath)/auth/refresh",
            body: ["refreshToken": refreshToken],
            bearer: nil,
            parse: adminSession
        )
    }

    /// Revoke the session on the server.
    ///
    /// Best effort by design: the caller has already forgotten the session locally and must not
    /// be held on a screen by a network failure. What it prevents is a refresh token outliving
    /// the device it was issued to.
    func adminSignOut(refreshToken: String) async -> ApiResult<Void> {
        await parsedCall(
            method: "POST",
            path: "\(GoodPostApi.adminPath)/auth/logout",
            body: ["refreshToken": refreshToken],
            bearer: nil
        ) { _ in () }
    }

    // MARK: - Channels (admin)

    /// The channels this administrator may publish to.
    func adminChannels(token: String) async -> ApiResult<[GoodPostChannel]> {
        await parsedCall(method: "GET", path: "\(GoodPostApi.adminPath)/channels", body: nil, bearer: token) { body in
            (body["channels"] as? [Any] ?? [])
                .compactMap { $0 as? [String: Any] }
                .compactMap(GoodPostCodec.channel(from:))
        }
    }

    /// Create a channel, and the administrator account that runs it.
    func adminCreateChannel(token: String, body: [String: Any]) async -> ApiResult<GoodPostChannel> {
        await parsedCall(method: "POST", path: "\(GoodPostApi.adminPath)/channels", body: body, bearer: token) {
            guard let channel = GoodPostCodec.singleChannel(from: $0) else { throw GoodPostContractBreak() }
            return channel
        }
    }

    /// Change a channel's name, description or category.
    func adminUpdateChannel(
        token: String,
        channelId: String,
        body: [String: Any]
    ) async -> ApiResult<GoodPostChannel> {
        await parsedCall(
            method: "PATCH",
            path: "\(GoodPostApi.adminPath)/channels/\(encode(channelId))",
            body: body,
            bearer: token
        ) {
            guard let channel = GoodPostCodec.singleChannel(from: $0) else { throw GoodPostContractBreak() }
            return channel
        }
    }

    /// Delete a channel, with its posts, its media and the login that ran it.
    ///
    /// There is no undo on the other end, so the app asks first — the confirmation is a UI
    /// decision, but its existence is why this returns nothing useful: there is nothing to render
    /// from a channel that no longer exists.
    func adminDeleteChannel(token: String, channelId: String) async -> ApiResult<Void> {
        await parsedCall(
            method: "DELETE",
            path: "\(GoodPostApi.adminPath)/channels/\(encode(channelId))",
            body: nil,
            bearer: token
        ) { _ in () }
    }

    // MARK: - Advertisements (admin)

    /// Every card, active or not — the admin list.
    func adminAds(token: String) async -> ApiResult<[GoodPostAd]> {
        await parsedCall(method: "GET", path: "\(GoodPostApi.adminPath)/ads", body: nil, bearer: token) {
            GoodPostCodec.adList(from: $0)
        }
    }

    /// One card, for the editor.
    func adminAd(token: String, adId: String) async -> ApiResult<GoodPostAd> {
        await parsedCall(
            method: "GET",
            path: "\(GoodPostApi.adminPath)/ads/\(encode(adId))",
            body: nil,
            bearer: token
        ) {
            guard let ad = GoodPostCodec.singleAd(from: $0) else { throw GoodPostContractBreak() }
            return ad
        }
    }

    /// Create a card. The whole body is supplied by the editor.
    func adminCreateAd(token: String, body: [String: Any]) async -> ApiResult<GoodPostAd> {
        await parsedCall(method: "POST", path: "\(GoodPostApi.adminPath)/ads", body: body, bearer: token) {
            guard let ad = GoodPostCodec.singleAd(from: $0) else { throw GoodPostContractBreak() }
            return ad
        }
    }

    /// Edit a card, including switching its content type.
    func adminUpdateAd(token: String, adId: String, body: [String: Any]) async -> ApiResult<GoodPostAd> {
        await parsedCall(
            method: "PATCH",
            path: "\(GoodPostApi.adminPath)/ads/\(encode(adId))",
            body: body,
            bearer: token
        ) {
            guard let ad = GoodPostCodec.singleAd(from: $0) else { throw GoodPostContractBreak() }
            return ad
        }
    }

    /// Remove a card, and its picture, for good.
    func adminDeleteAd(token: String, adId: String) async -> ApiResult<Void> {
        await parsedCall(
            method: "DELETE",
            path: "\(GoodPostApi.adminPath)/ads/\(encode(adId))",
            body: nil,
            bearer: token
        ) { _ in () }
    }

    // MARK: - Channel directory (admin)
    //
    // Super administrators only, checked on the server. Mutations answer with nothing usable and
    // the manager re-reads the whole directory afterwards: the list is a curated one, so the
    // extra read is cheap, and every change renders from a single source of truth rather than
    // from whatever fragment a route happened to return.

    /// The whole directory, for the manager screen.
    func adminDirectory(token: String) async -> ApiResult<DirectorySnapshot> {
        await parsedCall(
            method: "GET",
            path: "\(GoodPostApi.adminPath)/directory",
            body: nil,
            bearer: token,
            parse: DirectoryCodec.snapshot(from:)
        )
    }

    func adminCreateDirectoryCategory(token: String, body: [String: Any]) async -> ApiResult<Void> {
        await adminDirectoryMutation("POST", "\(GoodPostApi.adminPath)/directory/categories", token, body)
    }

    func adminUpdateDirectoryCategory(
        token: String,
        categoryId: String,
        body: [String: Any]
    ) async -> ApiResult<Void> {
        await adminDirectoryMutation(
            "PATCH",
            "\(GoodPostApi.adminPath)/directory/categories/\(encode(categoryId))",
            token,
            body
        )
    }

    func adminDeleteDirectoryCategory(token: String, categoryId: String) async -> ApiResult<Void> {
        await adminDirectoryMutation(
            "DELETE",
            "\(GoodPostApi.adminPath)/directory/categories/\(encode(categoryId))",
            token,
            nil
        )
    }

    func adminCreateDirectorySubcategory(token: String, body: [String: Any]) async -> ApiResult<Void> {
        await adminDirectoryMutation("POST", "\(GoodPostApi.adminPath)/directory/subcategories", token, body)
    }

    func adminUpdateDirectorySubcategory(
        token: String,
        subcategoryId: String,
        body: [String: Any]
    ) async -> ApiResult<Void> {
        await adminDirectoryMutation(
            "PATCH",
            "\(GoodPostApi.adminPath)/directory/subcategories/\(encode(subcategoryId))",
            token,
            body
        )
    }

    func adminDeleteDirectorySubcategory(token: String, subcategoryId: String) async -> ApiResult<Void> {
        await adminDirectoryMutation(
            "DELETE",
            "\(GoodPostApi.adminPath)/directory/subcategories/\(encode(subcategoryId))",
            token,
            nil
        )
    }

    /// Add a channel by handle. The server fills in the name and icon.
    func adminCreateDirectoryChannel(token: String, body: [String: Any]) async -> ApiResult<Void> {
        await adminDirectoryMutation("POST", "\(GoodPostApi.adminPath)/directory/channels", token, body)
    }

    func adminUpdateDirectoryChannel(
        token: String,
        channelId: String,
        body: [String: Any]
    ) async -> ApiResult<Void> {
        await adminDirectoryMutation(
            "PATCH",
            "\(GoodPostApi.adminPath)/directory/channels/\(encode(channelId))",
            token,
            body
        )
    }

    /// Re-copy a channel's name and icon from its platform, on demand.
    func adminRefreshDirectoryChannel(token: String, channelId: String) async -> ApiResult<Void> {
        await adminDirectoryMutation(
            "POST",
            "\(GoodPostApi.adminPath)/directory/channels/\(encode(channelId))/refresh",
            token,
            nil,
            sendEmptyBody: true
        )
    }

    func adminDeleteDirectoryChannel(token: String, channelId: String) async -> ApiResult<Void> {
        await adminDirectoryMutation(
            "DELETE",
            "\(GoodPostApi.adminPath)/directory/channels/\(encode(channelId))",
            token,
            nil
        )
    }

    /// One directory write, whose body is discarded on success.
    ///
    /// `sendEmptyBody` exists because the refresh route is a POST with no input: the server reads
    /// no body, but a request that declares one has to send it, or the connection writes a
    /// `Content-Length` header with nothing behind it.
    private func adminDirectoryMutation(
        _ method: String,
        _ path: String,
        _ token: String,
        _ body: [String: Any]?,
        sendEmptyBody: Bool = false
    ) async -> ApiResult<Void> {
        await parsedCall(
            method: method,
            path: path,
            body: body ?? (sendEmptyBody ? [:] : nil),
            bearer: token
        ) { _ in () }
    }

    // MARK: - Brain Rot repository (admin)
    //
    // The global protection repository: the community's suggestions and the rules they become.
    // A platform surface behind its own permission, held by super administrators only, and the
    // server re-checks that on every call regardless of what the app draws.
    //
    // There is deliberately no path here that turns a suggestion into a rule implicitly: the only
    // route that writes a rule is a review decision, so one accidental submission cannot change
    // what everyone blocks.

    /// Every global keyword, enabled or not.
    func adminBrainRotKeywords(token: String) async -> ApiResult<[GoodPostBrainRotRule]> {
        await parsedCall(
            method: "GET",
            path: "\(GoodPostApi.adminPath)/brainrot/keywords",
            body: nil,
            bearer: token
        ) { GoodPostCodec.brainRotKeywords(from: $0) }
    }

    /// Every global channel, enabled or not.
    func adminBrainRotChannels(token: String) async -> ApiResult<[GoodPostBrainRotRule]> {
        await parsedCall(
            method: "GET",
            path: "\(GoodPostApi.adminPath)/brainrot/channels",
            body: nil,
            bearer: token
        ) { GoodPostCodec.brainRotChannels(from: $0) }
    }

    /// Add a global keyword directly. Inert until the rule is enabled.
    func adminAddBrainRotKeyword(
        token: String,
        keyword: String,
        reason: String?
    ) async -> ApiResult<GoodPostBrainRotRule> {
        await parsedCall(
            method: "POST",
            path: "\(GoodPostApi.adminPath)/brainrot/keywords",
            body: ["keyword": keyword, "reason": reason ?? NSNull()],
            bearer: token
        ) { body in
            guard let row = body["keyword"] as? [String: Any],
                  let rule = GoodPostCodec.brainRotRule(from: row) else { throw GoodPostContractBreak() }
            return rule
        }
    }

    /// Add a global channel directly. Inert until the rule is enabled.
    func adminAddBrainRotChannel(
        token: String,
        handle: String,
        displayName: String?,
        reason: String?
    ) async -> ApiResult<GoodPostBrainRotRule> {
        await parsedCall(
            method: "POST",
            path: "\(GoodPostApi.adminPath)/brainrot/channels",
            body: ["handle": handle, "displayName": displayName ?? NSNull(), "reason": reason ?? NSNull()],
            bearer: token
        ) { body in
            guard let row = body["channel"] as? [String: Any],
                  let rule = GoodPostCodec.brainRotRule(from: row) else { throw GoodPostContractBreak() }
            return rule
        }
    }

    /// Enable or disable a rule.
    ///
    /// Disabling is the reversible move: the row stays, so a rule switched off because it was
    /// too broad can be switched back on once it is narrowed, rather than being deleted and
    /// re-added from memory.
    func adminSetBrainRotRuleEnabled(
        token: String,
        kind: String,
        ruleId: String,
        enabled: Bool
    ) async -> ApiResult<Void> {
        await parsedCall(
            method: "POST",
            path: "\(GoodPostApi.adminPath)/brainrot/\(brainRotKindPath(kind))/\(encode(ruleId))/status",
            body: ["enabled": enabled],
            bearer: token
        ) { _ in () }
    }

    /// Remove a rule for good.
    func adminDeleteBrainRotRule(token: String, kind: String, ruleId: String) async -> ApiResult<Void> {
        await parsedCall(
            method: "DELETE",
            path: "\(GoodPostApi.adminPath)/brainrot/\(brainRotKindPath(kind))/\(encode(ruleId))",
            body: nil,
            bearer: token
        ) { _ in () }
    }

    /// The review queue, oldest first. `status` defaults to `pending`.
    func adminBrainRotSubmissions(
        token: String,
        status: String = "pending"
    ) async -> ApiResult<[GoodPostBrainRotSubmission]> {
        await parsedCall(
            method: "GET",
            path: "\(GoodPostApi.adminPath)/brainrot/submissions?status=" + encode(status),
            body: nil,
            bearer: token
        ) { GoodPostCodec.brainRotSubmissions(from: $0) }
    }

    /// Approve or reject a suggestion.
    ///
    /// Approving writes the rule and marks the submission in one transaction on the server, so an
    /// approval can never leave a suggestion marked approved whose rule was not created.
    func adminReviewBrainRotSubmission(
        token: String,
        submissionId: String,
        decision: String
    ) async -> ApiResult<Void> {
        await parsedCall(
            method: "POST",
            path: "\(GoodPostApi.adminPath)/brainrot/submissions/\(encode(submissionId))/review",
            body: ["decision": decision],
            bearer: token
        ) { _ in () }
    }

    /// The dashboard's totals and most-requested targets.
    func adminBrainRotDashboard(token: String) async -> ApiResult<GoodPostBrainRotDashboard> {
        await parsedCall(
            method: "GET",
            path: "\(GoodPostApi.adminPath)/brainrot/dashboard",
            body: nil,
            bearer: token
        ) { GoodPostCodec.brainRotDashboard(from: $0) }
    }

    /// The false-positive queue: targets users reported as wrongly blocked.
    ///
    /// The counterpart to the review queue — a submission asks for a rule, a report asks for one
    /// to stop applying.
    func adminBrainRotReports(token: String) async -> ApiResult<[GoodPostBrainRotReport]> {
        await parsedCall(
            method: "GET",
            path: "\(GoodPostApi.adminPath)/brainrot/reports",
            body: nil,
            bearer: token
        ) { GoodPostCodec.brainRotReports(from: $0) }
    }

    /// Answer every open report for one target.
    ///
    /// `resolution` is `kept` (the reports were wrong) or `removed` (the rule is switched off).
    /// The server does both writes in one transaction, so a rule can never end up off with its
    /// reports still queued.
    func adminResolveBrainRotReport(
        token: String,
        kind: String,
        value: String,
        resolution: String
    ) async -> ApiResult<Void> {
        await parsedCall(
            method: "POST",
            path: "\(GoodPostApi.adminPath)/brainrot/reports/resolve",
            body: [
                "kind": kind == "channel" ? "channel" : "keyword",
                "value": value,
                "resolution": resolution,
            ],
            bearer: token
        ) { _ in () }
    }

    /// The URL segment for a rule kind, validated so a bad kind cannot build a path.
    private func brainRotKindPath(_ kind: String) -> String {
        kind == "channel" ? "channels" : "keywords"
    }

    // MARK: - Posts (admin)

    /// Publish a post. The type follows from what is attached.
    func adminCreatePost(
        token: String,
        channelId: String,
        body: [String: Any]
    ) async -> ApiResult<GoodPostPost> {
        await parsedCall(
            method: "POST",
            path: "\(GoodPostApi.adminPath)/channels/\(encode(channelId))/posts",
            body: body,
            bearer: token
        ) {
            guard let post = GoodPostCodec.singlePost(from: $0) else { throw GoodPostContractBreak() }
            return post
        }
    }

    /// Edit a post's text or link.
    func adminUpdatePost(
        token: String,
        postId: String,
        body: [String: Any]
    ) async -> ApiResult<GoodPostPost> {
        await parsedCall(
            method: "PATCH",
            path: "\(GoodPostApi.adminPath)/posts/\(encode(postId))",
            body: body,
            bearer: token
        ) {
            guard let post = GoodPostCodec.singlePost(from: $0) else { throw GoodPostContractBreak() }
            return post
        }
    }

    /// Remove a post. Soft on the server, so it stays reversible.
    func adminDeletePost(token: String, postId: String) async -> ApiResult<Void> {
        await parsedCall(
            method: "DELETE",
            path: "\(GoodPostApi.adminPath)/posts/\(encode(postId))",
            body: nil,
            bearer: token
        ) { _ in () }
    }

    /// Remove several posts in one request.
    ///
    /// One call for a whole selection, because the server applies it atomically: a partial delete
    /// would be a list with some rows missing and no way to know which, and re-sending would be
    /// the only way to find out.
    func adminDeletePosts(token: String, postIds: [String]) async -> ApiResult<Int> {
        await parsedCall(
            method: "POST",
            path: "\(GoodPostApi.adminPath)/posts/bulk-delete",
            body: ["postIds": postIds],
            bearer: token
        ) { body in JSONScalar.int(body["deleted"]) ?? 0 }
    }

    // MARK: - Media uploads

    /// Ask for a place to put one file.
    ///
    /// The response carries a presigned URL, the headers that go with it, and a media id. What it
    /// deliberately does **not** carry is the object key: the server derives that from an id it
    /// generates, so no request this app makes can choose where its bytes land. The file's content
    /// type and size are declared here because the URL **signs** both — the bucket refuses an
    /// upload that differs, which puts the authoritative check at the bucket rather than in our
    /// own validation.
    ///
    /// A deployment with no storage answers `media_unavailable`, which the composer words
    /// explicitly rather than as a generic failure: text and link posts still work there.
    func adminRequestUpload(
        token: String,
        contentType: String,
        byteSize: Int64,
        width: Int? = nil,
        height: Int? = nil,
        durationMs: Int64? = nil,
        fileName: String? = nil
    ) async -> ApiResult<GoodPostUpload> {
        var body: [String: Any] = ["contentType": contentType, "byteSize": byteSize]
        if let width { body["width"] = width }
        if let height { body["height"] = height }
        if let durationMs { body["durationMs"] = durationMs }
        if let fileName { body["fileName"] = fileName }

        return await parsedCall(
            method: "POST",
            path: "\(GoodPostApi.adminPath)/media/uploads",
            body: body,
            bearer: token
        ) { response in
            guard let upload = response["upload"] as? [String: Any],
                  let mediaId = JSONScalar.nullableString(upload["mediaId"]),
                  let url = JSONScalar.nullableString(upload["uploadUrl"]) else {
                throw GoodPostContractBreak()
            }
            return GoodPostUpload(
                mediaId: mediaId,
                uploadUrl: url,
                uploadHeaders: headers(from: upload["uploadHeaders"]),
                kind: JSONScalar.string(upload["kind"]) ?? ""
            )
        }
    }

    /// Tell the server the bytes are there, and let it check.
    ///
    /// Idempotent on the server side, so a retry after a dropped response is not punished. Only
    /// after this does the media become claimable by a post.
    func adminConfirmUpload(token: String, mediaId: String) async -> ApiResult<GoodPostMedia> {
        await parsedCall(
            method: "POST",
            path: "\(GoodPostApi.adminPath)/media/uploads/\(encode(mediaId))/confirm",
            body: nil,
            bearer: token
        ) { body in
            guard let media = body["media"] as? [String: Any],
                  let parsed = GoodPostCodec.media(from: media) else { throw GoodPostContractBreak() }
            return parsed
        }
    }

    /// PUT the file to the presigned URL.
    ///
    /// The URL is absolute and goes to the bucket, not to our API — which is the point of
    /// presigning. It carries its own signature, so no credential of ours is involved and the
    /// token that authorised it is not sent anywhere. A non-2xx answer (an expired signature, a
    /// size the bucket refused) is reported as a failure with the status, so the composer can say
    /// something true rather than claiming the upload worked.
    func putFile(
        uploadUrl: String,
        headers: [String: String],
        fileURL: URL
    ) async -> ApiResult<Void> {
        guard let url = URL(string: uploadUrl) else { return .unreachable }
        do {
            let response = try await transport.put(fileURL: fileURL, url: url, headers: headers)
            if (200...299).contains(response.status) { return .ok(()) }
            return .failed(status: response.status, code: goodPostErrorCode(status: response.status, body: nil))
        } catch {
            return .unreachable
        }
    }

    /// The signable headers for an upload, as the server listed them.
    private func headers(from value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, raw) in dictionary {
            if let text = JSONScalar.string(raw) { out[key] = text }
        }
        return out
    }

    // MARK: - Internals

    /// The session payload, shared by sign-in and renewal.
    ///
    /// Both routes answer with this shape, and a body missing either token is a contract break
    /// rather than a signed-in administrator: an access token with nothing to renew it with would
    /// work for ten minutes and then fail with no way back.
    private func adminSession(from body: [String: Any]) throws -> AdminSession {
        let token = JSONScalar.string(body["accessToken"]) ?? ""
        let refresh = JSONScalar.string(body["refreshToken"]) ?? ""
        guard !token.isEmpty, !refresh.isEmpty else { throw GoodPostContractBreak() }

        let admin = body["admin"] as? [String: Any]
        return AdminSession(
            token: token,
            refreshToken: refresh,
            role: admin.flatMap { JSONScalar.string($0["role"]) } ?? "",
            email: admin.flatMap { JSONScalar.string($0["email"]) } ?? "",
            channelId: admin.flatMap { JSONScalar.nullableString($0["channelId"]) }
        )
    }

    /// A follow-shaped call: the path names the channel, and the answer names it back.
    private func followCall(
        method: String,
        token: String,
        idOrSlug: String,
        body: [String: Any]?,
        suffix: String = ""
    ) async -> ApiResult<GoodPostFollow> {
        await parsedCall(
            method: method,
            path: "\(GoodPostApi.readerPath)/me/following/\(encode(idOrSlug))\(suffix)",
            body: body,
            bearer: token
        ) { response in
            // The server always names the channel it acted on, so a body without one is not
            // "no follow" — it is a response this client cannot read, and saying so is better
            // than reporting a success whose effect is unknown.
            guard let follow = GoodPostCodec.follow(from: response) else { throw GoodPostContractBreak() }
            return follow
        }
    }

    /// A reaction-shaped call: the answer carries the count the card has to correct.
    private func reactionCall(
        method: String,
        token: String,
        postId: String,
        body: [String: Any]?,
        suffix: String
    ) async -> ApiResult<GoodPostReactionResult> {
        await parsedCall(
            method: method,
            path: "\(GoodPostApi.readerPath)/me/reactions/\(encode(postId))\(suffix)",
            body: body,
            bearer: token
        ) { response in
            // The count is the reason the answer is read at all, so a body without one is not
            // "no reaction" — it is an answer this client cannot use, and the same retryable
            // failure as any other unreadable 2xx.
            guard let result = GoodPostCodec.reactionResult(from: response) else {
                throw GoodPostContractBreak()
            }
            return result
        }
    }

    /// A read that never carries a token, decoded into a domain shape.
    ///
    /// Kept separate from `parsedCall` so no read call site can acquire a credential by accident:
    /// an anonymous request is not a call with a nil token, it is a call whose signature has
    /// nowhere to put one.
    private func parsedGet<T>(
        _ path: String,
        parse: ([String: Any]) throws -> T
    ) async -> ApiResult<T> {
        await send(method: "GET", path: path, body: nil, bearer: nil, parse: parse)
    }

    private func parsedCall<T>(
        method: String,
        path: String,
        body: [String: Any]?,
        bearer: String?,
        parse: ([String: Any]) throws -> T
    ) async -> ApiResult<T> {
        await send(method: method, path: path, body: body, bearer: bearer, parse: parse)
    }

    /// One request, end to end.
    ///
    /// A 2xx whose body does not fit the shape is **not** a success — storing or rendering half of
    /// it would put a channel with no name on screen — so a contract break is reported as
    /// unreachable, which is the only sane response to "the server said something we do not
    /// understand" and is what makes the caller retry.
    private func send<T>(
        method: String,
        path: String,
        body: [String: Any]?,
        bearer: String?,
        parse: ([String: Any]) throws -> T
    ) async -> ApiResult<T> {
        let root = baseUrl().trimmed
        guard !root.isEmpty else { return .unreachable }

        let trimmedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard let url = URL(string: trimmedRoot + path) else { return .unreachable }

        var headers: [String: String] = [:]
        if let bearer, !bearer.isEmpty { headers["Authorization"] = "Bearer \(bearer)" }

        var payload: Data?
        if let body {
            payload = try? JSONSerialization.data(withJSONObject: body)
        }

        let response: GoodPostResponse
        do {
            response = try await transport.send(method: method, url: url, headers: headers, body: payload)
        } catch {
            // Never log a request body: on the admin surface it carries a password, and on the
            // read surface it carries a search term.
            return .unreachable
        }

        if (200...299).contains(response.status) {
            guard let dictionary = response.jsonObject else { return .unreachable }
            do {
                return .ok(try parse(dictionary))
            } catch {
                return .unreachable
            }
        }
        return .failed(status: response.status, code: goodPostErrorCode(status: response.status, body: response.text))
    }

    private func channelsPath(
        query: String?,
        category: String?,
        sort: String?,
        cursor: String?,
        limit: Int?
    ) -> String {
        var pairs: [String] = []
        let term = (query ?? "").trimmed
        if !term.isEmpty { pairs.append("q=" + encode(term)) }
        let categoryValue = (category ?? "").trimmed
        if !categoryValue.isEmpty { pairs.append("category=" + encode(categoryValue)) }
        let sortValue = (sort ?? "").trimmed
        if !sortValue.isEmpty { pairs.append("sort=" + encode(sortValue)) }
        if let limit, limit > 0 { pairs.append("limit=\(limit)") }
        let cursorValue = (cursor ?? "").trimmed
        if !cursorValue.isEmpty { pairs.append("cursor=" + encode(cursorValue)) }
        let suffix = pairs.isEmpty ? "" : "?" + pairs.joined(separator: "&")
        return "\(GoodPostApi.publicPath)/channels" + suffix
    }

    /// The query string a paged read carries: an optional cursor, and nothing else. Listing it
    /// rather than concatenating is what keeps a second `?` from ending the path and pushing the
    /// term into the cursor.
    private func pageQuery(_ cursor: String?) -> String {
        guard let cursor, !cursor.trimmed.isEmpty else { return "" }
        return "?cursor=" + encode(cursor)
    }

    /// Percent-encode a path or query component.
    ///
    /// A cursor is base64url, which can contain `-` and `_`, and is still encoded defensively: a
    /// raw `&` or `#` reaching the URL would silently truncate the request and look like an empty
    /// page rather than like a bug.
    private func encode(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;= ")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

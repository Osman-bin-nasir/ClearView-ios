import Foundation

/// A reader's identity for Good Post.
///
/// The app identifies the reader **silently** the first time Good Post needs to know who they
/// are, and sends the resulting ID token to the ClearView backend, which verifies it and keys the
/// reader's own state off it. That identity is what a follow, a read position and a mute hang
/// from.
///
/// **Nothing here asks the reader for anything.** No email, no password, no phone number, no
/// verification step — the sign-in is silent and happens behind the tab. The whole reader surface
/// works before it and after it; what the identity adds is remembering which channels are
/// *theirs*.
///
/// ## Why a protocol
///
/// So the repository and the screens can be tested, and so "this build has no identity provider
/// configured" is a state rather than a crash. `NoIdentity` is what a build without one gets:
/// reader-scoped calls then report themselves as unavailable, which is the same thing the backend
/// says when it cannot verify anybody, and the app words both the same way.
///
/// ## What is deliberately not stored
///
/// No uid, and no reader token written to disk. The reader token is short-lived and only needed
/// while the app is running, so it is asked for per request: a cached token would be a credential
/// sitting in a file for a feature that does not need it. The one credential the app *does* store
/// is the administrator's — see `GoodPostAdminSessionStore` — because publishing is not something
/// a person re-authenticates for every ten minutes.
protocol GoodPostIdentity: Sendable {

    /// Whether this build can identify a reader **at all**.
    ///
    /// Not "is somebody signed in" — the sign-in is silent and happens on demand — but "is there
    /// an identity mechanism here". The home tab asks it to tell two situations apart: a reader
    /// whose follows could not be fetched (show what is known, and say the rest failed) and a
    /// build with no identity provider, which has no list of follows to fetch and must therefore
    /// fall back to the public catalogue rather than show an empty tab forever.
    var available: Bool { get }

    /// A verifiable ID token for this device's reader, or nil.
    ///
    /// Nil is not an error the caller has to handle differently from a refused request: the
    /// backend answers `auth_unavailable` for a deployment that cannot verify and `invalid_token`
    /// for a token it does not like, and a caller that has no token simply does not make the call.
    func token() async -> String?

    /// A verifiable ID token for a **creator** identity, or nil.
    ///
    /// Different from `token()` in the one way that matters to the server: the token names a
    /// provider and carries an email, so it is not anonymous and may therefore own a channel. Nil
    /// means the credentials were refused — a wrong password, or a sign-up for an address that
    /// already has an account.
    ///
    /// - Parameter signUp: create the account if there is not one already.
    func creatorToken(email: String, password: String, signUp: Bool) async -> String?

    /// A creator ID token obtained through an external provider, or nil.
    ///
    /// Nil covers every refusal. The screen words a dismissal differently from a failure, which is
    /// why the answer is a three-way result rather than an optional.
    func googleCreatorToken() async -> GoogleSignIn

    /// Forget the creator identity, and only that.
    ///
    /// Called when an administrator signs out. "Only that" is the whole of it: the **reader's**
    /// identity stays exactly where it was, so signing out of a channel does not take the channels
    /// this device follows with it.
    func creatorSignOut() async
}

/// The three answers an external-provider sign-in attempt can have.
enum GoogleSignIn: Equatable {
    /// The provider accepted the account; this is its ID token.
    case token(String)
    /// The account picker was dismissed, or there was nothing to offer.
    case cancelled
    /// Something went wrong that saying "cancelled" would misdescribe.
    case failed
}

/// What a build with no configured identity provider uses.
///
/// A supported state rather than a placeholder: the entire reader surface — browsing, searching,
/// reading a channel, sharing — works without any identity, and follows are the one thing that
/// needs one. A build pointed at a backend that cannot verify anybody runs this, and so does a
/// fresh clone with no identity provider added yet.
struct NoIdentity: GoodPostIdentity {
    var available: Bool { false }

    func token() async -> String? { nil }

    func creatorToken(email: String, password: String, signUp: Bool) async -> String? { nil }

    func googleCreatorToken() async -> GoogleSignIn { .cancelled }

    func creatorSignOut() async {}
}

/// A reader identity minted by the app itself, for a deployment whose reader tokens are its own.
///
/// The ClearView backend verifies tokens rather than issuing them, so an implementation of
/// `GoodPostIdentity` normally wraps an identity provider. This one exists for the two cases that
/// do not: a build pointed at a backend which trusts the app's own session, and a test that needs a
/// token without a network. It is deliberately **not** a fallback for a refused sign-in — nothing
/// selects it by default.
struct ProvidedIdentity: GoodPostIdentity {

    private let readerToken: @Sendable () async -> String?
    private let creatorTokens: @Sendable (String, String, Bool) async -> String?

    init(
        readerToken: @escaping @Sendable () async -> String?,
        creatorToken: @escaping @Sendable (String, String, Bool) async -> String? = { _, _, _ in nil }
    ) {
        self.readerToken = readerToken
        self.creatorTokens = creatorToken
    }

    /// A fixed token, which is all a reader-scoped call needs.
    init(token: String) {
        self.init(readerToken: { token })
    }

    var available: Bool { true }

    func token() async -> String? { await readerToken() }

    func creatorToken(email: String, password: String, signUp: Bool) async -> String? {
        await creatorTokens(email, password, signUp)
    }

    func googleCreatorToken() async -> GoogleSignIn { .cancelled }

    func creatorSignOut() async {}
}

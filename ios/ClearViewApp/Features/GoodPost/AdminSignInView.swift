import SwiftUI

/// The administrator way in (§16).
///
/// This is reached from "Create a channel", and it is the ONLY place the app asks anyone to
/// identify themselves. That is the whole point: a reader of Good Post never sees this screen, and
/// the credentials that work here were provisioned by the deployment rather than signed up for.
///
/// # One form, two populations
///
/// An administrator's password lives on the server; a creator's account lives in Firebase. The
/// app tries the server first and falls through to Firebase for everyone else, which is why
/// nothing here asks which kind of account somebody has — that is a fact the app can find out in
/// one round trip, and asking would be asking the person to know something only the backend does.
///
/// # The refusal is deliberately uninformative
///
/// A wrong address and a wrong password produce the same sentence, because distinguishing them
/// would turn this screen into a way to discover which addresses exist — and the server answers
/// identically for both, so the wording here cannot leak what the API withholds. The two refusals
/// that DO say something are the two that are not credential problems at all: an account that was
/// switched off, and a deployment that cannot verify anybody.
struct AdminSignInView: View {
    let repository: GoodPostRepository
    /// Told the session that landed, and — when the account was already here — its address, so the
    /// tab can greet a returning creator rather than dropping them onto a list with no word about
    /// what happened.
    let onLanded: (AdminSession, String?) -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var message: String?
    /// A creator who signed in and has no channel yet: the second half of ONE sign-in.
    ///
    /// A step rather than a screen, because it is not a place anyone can navigate to or away from —
    /// backing out of it should leave them on the sign-in with no account created, and nothing is
    /// written server-side until the button on it is pressed.
    @State private var naming: Naming?

    private struct Naming: Equatable {
        let email: String
        let idToken: String
    }

    var body: some View {
        Group {
            if let naming {
                CreatorChannelStep(
                    email: naming.email,
                    busy: busy,
                    message: message,
                    onBack: {
                        // Back to the credentials, not out of the flow. The identity is dropped so
                        // the next attempt really does use whatever is typed now; the email and
                        // password are kept, because they are what somebody returning here came
                        // back to change.
                        self.naming = nil
                        message = nil
                    },
                    onCreate: { channelName in
                        await createChannel(named: channelName, token: naming.idToken)
                    }
                )
            } else {
                credentials
            }
        }
    }

    private var credentials: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("Sign in to create and run your own channel. Readers never need an account.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.cvOnSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // The Good Post artwork, centred and at a fixed size — a logo, not a banner.
                // `scaledToFit` deliberately: the drawing is very nearly square, and cropping a
                // near-square into a wide band is how a logo loses its edges on the one screen
                // where it is the first thing anybody sees.
                Image("GoodPostArtwork")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.top, 22)

                // The name under the mark, set in the artwork's own typeface — Amatic SC, the face
                // the drawing is lettered in — so the two read as one lock-up rather than a picture
                // with a caption.
                Text("GOODPOST")
                    .font(.custom("AmaticSC-Regular", size: 46))
                    .tracking(2)
                    .padding(.top, 10)

                // The credentials, shown rather than hidden behind a reveal.
                //
                // Android puts them behind an "Other ways" line because the button above them is
                // Google, and a creator who signs up with it never has to see a password field.
                // This build has no Google provider wired in (`googleCreatorToken` answers
                // `.cancelled`), so hiding the form would hide the only way in — which is the one
                // thing a reveal must never do.
                VStack(spacing: 14) {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(busy)
                    Divider()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .disabled(busy)
                        .onSubmit { Task { await signIn() } }
                }
                .textFieldStyle(.plain)
                .padding(18)
                .background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 16))
                .padding(.top, 24)

                Text("A new address is signed up with the password you type. Provisioned channel accounts sign in with theirs.")
                    .font(.caption)
                    .foregroundStyle(Color.cvOnSurfaceVariant)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)

                if let message {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(Color.cvError)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 16)
                        .accessibilityIdentifier("goodpost.signin.error")
                }

                Button {
                    Task { await signIn() }
                } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(Color.cvOnPrimary) }
                        Text("Continue").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy || email.trimmed.isEmpty || password.isEmpty)
                .padding(.top, 24)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        }
    }

    // MARK: - Signing in

    /// One action for the form.
    ///
    /// It is not labelled "Sign in" or "Sign up" because it is both: the server decides whether
    /// these credentials are a provisioned administrator, and Firebase decides whether they are a
    /// creator who signed up this way.
    private func signIn() async {
        let address = email.trimmed.lowercased()
        guard !address.isEmpty, !password.isEmpty else { return }
        busy = true
        message = nil
        defer { busy = false }

        switch await repository.adminLogin(email: address, password: password) {
        case .ok(let session):
            password = ""
            onLanded(session, nil)

        case .failed(let status, let code):
            // Two refusals stop the attempt rather than falling through, because the Firebase try
            // cannot succeed and would only delay the truth: an account that exists and is locked
            // or switched off, and a deployment that cannot verify anybody.
            if adminRefusalIsFinal(status: status, code: code) {
                message = refusalMessage(status: status, code: code)
            } else if signInHitAnotherContract(status: status, code: code) {
                message = "This server does not offer the administrator sign-in this app expects. It is probably running an older version of the backend."
            } else {
                await creatorSignIn(address: address)
            }

        case .unreachable:
            message = "Couldn't connect. Check your connection and try again."
        }
    }

    /// The Firebase half, with the credentials already validated.
    ///
    /// `signUp` decides which way round Firebase tries its two calls; it does not decide whether an
    /// account exists, because only Firebase knows that — see `creatorToken`.
    private func creatorSignIn(address: String) async {
        guard let token = await repository.creatorToken(email: address, password: password, signUp: true) else {
            // One sentence for a wrong password and for an address that cannot be signed up: the
            // distinction is a way to discover which addresses exist.
            message = "Invalid credentials."
            return
        }
        await continueCreatorSignIn(token)
    }

    /// The shared second half: trade the Firebase token for a session or a step.
    private func continueCreatorSignIn(_ idToken: String) async {
        switch await repository.creatorLogin(idToken: idToken) {
        case .ok(.session(let session)):
            // `session` (rather than `needsChannel`) means this account was already here, so the
            // reader is greeted instead of dropped onto a list.
            password = ""
            onLanded(session, session.email)
        case .ok(.needsChannel(let address)):
            // Held in memory, and only until the channel exists: it is a credential with minutes
            // of life, so it is not written to disk — the session that replaces it is.
            naming = Naming(email: address ?? email.trimmed.lowercased(), idToken: idToken)
        case .failed(let status, let code):
            message = refusalMessage(status: status, code: code)
        case .unreachable:
            message = "Couldn't connect. Check your connection and try again."
        }
    }

    /// Create the creator's channel, which is also what creates their account.
    private func createChannel(named rawName: String, token: String) async {
        let name = rawName.trimmed
        guard !name.isEmpty else {
            message = "Give the channel a name."
            return
        }
        busy = true
        message = nil
        defer { busy = false }

        switch await repository.creatorCreateChannel(idToken: token, name: name) {
        case .ok(let session):
            password = ""
            onLanded(session, nil)
        case .failed(_, let code):
            // A token the server refused cannot be retried with: it is the same string on every
            // attempt, so the flow goes back to the half that obtains a NEW one. The typed channel
            // name is kept by the step's own field rather than here.
            if code == "session_expired" || code == "invalid_token" || code == "missing_token"
                || code == "invalid_refresh_token" || code == "session_revoked" {
                naming = nil
            }
            message = refusalMessage(status: 0, code: code)
        case .unreachable:
            message = "Couldn't connect. Check your connection and try again."
        }
    }

    private func adminRefusalIsFinal(status: Int, code: String) -> Bool {
        goodPostSignInRefusalIsFinal(code: code)
    }

    private func signInHitAnotherContract(status: Int, code: String) -> Bool {
        goodPostSignInHitAnotherContract(status: status, code: code)
    }

    private func refusalMessage(status: Int, code: String) -> String {
        goodPostSignInMessage(status: status, code: code)
    }
}

/// Whether a refusal from the administrator sign-in route is the END of the attempt (§16).
///
/// One form serves two populations: an administrator whose password lives on the server, and a
/// creator whose account lives in Firebase. The app tries the server first and falls through for
/// everyone else, so this rule decides which refusals are allowed to mean "not a provisioned
/// account" — and getting it wrong in either direction is visible to the person signing in:
///
///  * **locked or disabled** is final. The account EXISTS and was switched off, and no Firebase
///    sign-up can change that. Falling through would spend a round trip to reach the same answer,
///    and — worse — a wrong password on a locked account would be reported as "invalid credentials"
///    from the second attempt, hiding the lockout that is the actual problem.
///  * **`auth_unavailable`** is final. This deployment cannot verify anybody, which is a stated
///    condition rather than a mistyped one, and there is nothing for Firebase to try.
///
/// Everything else falls through — including a refusal that says this server speaks another
/// contract, because an address with no administrator behind it is exactly who the creator path is
/// for.
func goodPostSignInRefusalIsFinal(code: String) -> Bool {
    code == "admin_locked" || code == "admin_disabled" || code == "auth_unavailable"
}

/// Whether a failed sign-in means this server speaks a different contract.
///
/// 404 is no route there at all (a backend built without an administrator surface), 405 is something
/// else at that path, and `invalid_request` is a body refused as malformed by a server that wanted a
/// different one. None of those can come from a server implementing this route, and all of them used
/// to be reported as a wrong password — which sent whoever typed a correct one off to reset
/// something that was never wrong.
///
/// The last rule only holds because this client cannot send a malformed body: an unparsable address
/// and an empty password are refused before the call, and the button is disabled while either field
/// is blank.
func goodPostSignInHitAnotherContract(status: Int, code: String) -> Bool {
    status == 404 || status == 405 || code == "invalid_request"
}

/// What the sign-in screen says about a refusal.
///
/// The sentences of its own are the conditions that are not "you typed it wrong", because those are
/// the ones the reader acts on differently: wait, or find out that this build cannot sign anybody in
/// at all.
func goodPostSignInMessage(status: Int, code: String) -> String {
    switch code {
    case "admin_locked", "admin_disabled":
        return "Too many failed attempts, or this account is disabled. Try again later."
    case "auth_unavailable":
        return "Account services aren't configured for this build."
    case "invalid_credentials", "unauthorized", "admin_credentials_incomplete":
        return "Invalid credentials."
    case "weak_password":
        return "That password is too short."
    case "email_taken":
        return "That address already has an account. Sign in with it instead."
    default:
        break
    }
    if status == 404 || status == 405 {
        return "This server does not offer the administrator sign-in this app expects. It is probably running an older version of the backend."
    }
    let readable = code.replacingOccurrences(of: "_", with: " ")
    return "Couldn't complete the sign-in (\(readable))."
}

/// The last step of becoming a creator: naming the channel you will run (§16).
///
/// Its arrow goes back to the credentials rather than out of the flow, because it is the second
/// half of one sign-in — and it is the only way out that does not leave the half-made creator
/// state behind.
struct CreatorChannelStep: View {
    let email: String
    let busy: Bool
    let message: String?
    let onBack: () -> Void
    let onCreate: (String) async -> Void

    @State private var name = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Button(action: onBack) {
                        Image(systemName: "arrow.left").font(.system(size: 18))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Back to sign-in")
                    Text("Name your channel").font(.system(size: 20, weight: .medium))
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 12)

                // Which identity the channel will belong to, said plainly. It is the account just
                // signed in as, so showing it here is the one place somebody can notice it is the
                // wrong one before a channel exists under it.
                Text(email).font(.system(size: 13)).foregroundStyle(Color.cvPrimary)
                    .padding(.bottom, 10)

                Text("This is the last step. Your channel is created with this account and you can rename it later.")
                    .font(.system(size: 14)).foregroundStyle(Color.cvOnSurfaceVariant)

                TextField("Channel name", text: $name)
                    .textFieldStyle(.plain)
                    .disabled(busy)
                    .padding(16)
                    .background(Color.cvSurfaceContainer, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.top, 24)
                    .accessibilityIdentifier("goodpost.creator.channelName")

                if let message {
                    Text(message).font(.subheadline).foregroundStyle(Color.cvError)
                        .padding(.top, 14)
                }

                Button {
                    Task { await onCreate(name) }
                } label: {
                    HStack(spacing: 8) {
                        if busy { ProgressView().tint(Color.cvOnPrimary) }
                        Text("Continue").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                // Disabled rather than refused: an empty name is a field that is not finished, not
                // an error to be announced.
                .disabled(busy || name.trimmed.isEmpty)
                .padding(.top, 24)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        }
    }
}

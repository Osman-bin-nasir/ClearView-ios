import XCTest
@testable import ClearView

/// The two rules that decide what a failed administrator sign-in MEANS (§16).
///
/// They are the whole of the fall-through: one form serves a provisioned administrator and a
/// creator whose account lives in Firebase, so every refusal has to be sorted into "not a
/// provisioned account, try Firebase" and "stop, this is the answer". Getting either wrong is
/// visible to whoever is signing in — a locked account reported as a wrong password, or a second
/// round trip that delays the truth — which is why the boundary is pinned here rather than left to
/// the screen that happens to call it.
final class GoodPostSignInTests: XCTestCase {

    // MARK: - Which refusals end the attempt

    func testLockedAndDisabledAccountsEndTheAttempt() {
        XCTAssertTrue(goodPostSignInRefusalIsFinal(code: "admin_locked"))
        XCTAssertTrue(goodPostSignInRefusalIsFinal(code: "admin_disabled"))
    }

    func testADeploymentThatCannotVerifyAnybodyEndsTheAttempt() {
        XCTAssertTrue(goodPostSignInRefusalIsFinal(code: "auth_unavailable"))
    }

    /// A wrong password is NOT the end: an address with no administrator behind it is exactly the
    /// account the creator path signs up.
    func testCredentialRefusalsFallThroughToFirebase() {
        XCTAssertFalse(goodPostSignInRefusalIsFinal(code: "invalid_credentials"))
        XCTAssertFalse(goodPostSignInRefusalIsFinal(code: "unauthorized"))
        XCTAssertFalse(goodPostSignInRefusalIsFinal(code: "admin_credentials_incomplete"))
    }

    /// A server that speaks another contract is deliberately NOT final: the fall-through is what
    /// makes a deployment without an administrator surface still usable by a creator.
    func testAnotherContractStillAllowsTheCreatorPath() {
        XCTAssertTrue(goodPostSignInHitAnotherContract(status: 404, code: "http_error"))
        XCTAssertFalse(goodPostSignInRefusalIsFinal(code: "http_error"))
        XCTAssertFalse(goodPostSignInRefusalIsFinal(code: "admin_unavailable"))
    }

    // MARK: - Reading another contract from an answer

    func testAMissingOrMismatchedRouteIsAnotherContract() {
        XCTAssertTrue(goodPostSignInHitAnotherContract(status: 404, code: "not_found"))
        XCTAssertTrue(goodPostSignInHitAnotherContract(status: 405, code: "http_error"))
        XCTAssertTrue(goodPostSignInHitAnotherContract(status: 400, code: "invalid_request"))
    }

    func testAnOrdinaryRefusalIsNotAnotherContract() {
        XCTAssertFalse(goodPostSignInHitAnotherContract(status: 401, code: "invalid_credentials"))
        XCTAssertFalse(goodPostSignInHitAnotherContract(status: 429, code: "rate_limited"))
        XCTAssertFalse(goodPostSignInHitAnotherContract(status: 500, code: "server_error"))
    }

    // MARK: - What the screen says

    /// The two conditions a reader can act on differently, and the one that must not be worded as a
    /// credential problem.
    func testTheActedUponRefusalsHaveTheirOwnSentences() {
        XCTAssertEqual(
            goodPostSignInMessage(status: 401, code: "admin_locked"),
            "Too many failed attempts, or this account is disabled. Try again later."
        )
        XCTAssertEqual(
            goodPostSignInMessage(status: 503, code: "auth_unavailable"),
            "Account services aren't configured for this build."
        )
        XCTAssertEqual(goodPostSignInMessage(status: 401, code: "invalid_credentials"), "Invalid credentials.")
    }

    /// A wrong address and a wrong password word the same, so the screen cannot be used to discover
    /// which addresses exist.
    func testEveryCredentialRefusalWordsTheSame() {
        let sentences = [
            "invalid_credentials",
            "unauthorized",
            "admin_credentials_incomplete",
        ].map { goodPostSignInMessage(status: 401, code: $0) }
        XCTAssertEqual(Set(sentences).count, 1)
    }

    func testAnUnknownCodeStillSaysSomething() {
        let sentence = goodPostSignInMessage(status: 418, code: "something_new")
        XCTAssertTrue(sentence.contains("something new"), sentence)
    }
}

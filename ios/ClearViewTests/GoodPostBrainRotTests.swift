import XCTest
@testable import ClearView

/// The Shared blocklist's two small rules.
///
/// Both are one line of code and both are load-bearing: the decision words are what the server
/// accepts, and which answers a false report offers decides whether an operator is shown a button
/// that would quietly do nothing. Neither is visible on the screen they come from, so they are
/// pinned here.
final class GoodPostBrainRotTests: XCTestCase {

    // MARK: - Review decisions

    func testTheDecisionsAreTheWordsTheServerAccepts() {
        XCTAssertEqual(GoodPostBrainRotDecision.approve.rawValue, "approved")
        XCTAssertEqual(GoodPostBrainRotDecision.reject.rawValue, "rejected")
        XCTAssertEqual(GoodPostBrainRotDecision.underReview.rawValue, "under_review")
    }

    func testTheResolutionsAreTheWordsTheServerAccepts() {
        XCTAssertEqual(GoodPostBrainRotResolution.keep.rawValue, "kept")
        XCTAssertEqual(GoodPostBrainRotResolution.stop.rawValue, "removed")
    }

    // MARK: - What a report offers

    /// A term a global rule matches can keep the block or stop it.
    func testAReportWithARuleOffersBothAnswers() {
        XCTAssertEqual(brainRotReportAnswers(hasRule: true), [.keep, .stop])
        XCTAssertEqual(brainRotAnswerLabel(.keep, hasRule: true), "Keep blocking")
        XCTAssertEqual(brainRotAnswerLabel(.stop, hasRule: true), "Stop blocking")
    }

    /// A term nothing matches has no block to stop, so it is offered the single honest action — and
    /// that action is called "Dismiss" rather than "Keep blocking", which would claim a rule is being
    /// enforced for everyone when none is.
    func testAReportWithNoRuleOffersOnlyADismissal() {
        XCTAssertEqual(brainRotReportAnswers(hasRule: false), [.keep])
        XCTAssertEqual(brainRotAnswerLabel(.keep, hasRule: false), "Dismiss")
    }

    /// The order is the order the buttons are drawn in, and the destructive one is last: an
    /// irreversible-looking answer does not belong under the thumb's resting place.
    func testTheStopAnswerIsTheLastOneOffered() {
        let answers = brainRotReportAnswers(hasRule: true)
        XCTAssertEqual(answers.last, .stop)
        XCTAssertEqual(answers.first, .keep)
    }
}

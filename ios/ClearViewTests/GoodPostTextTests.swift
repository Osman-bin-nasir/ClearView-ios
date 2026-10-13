import XCTest
@testable import ClearView

/// Tests for Good Post's inline formatting: the four toggle cases, the whitespace rule
/// and the conservative "is this one run?" test.
///
/// These are behavioural tests of a toolbar, so each one is phrased as what a person
/// does: put the caret somewhere and tap, highlight a word and tap twice, highlight a
/// finger-sized slice including a space, and so on.
final class GoodPostTextTests: XCTestCase {

    private func apply(
        _ text: String,
        _ start: Int,
        _ end: Int,
        _ format: GoodPostFormat = .bold
    ) -> GoodPostFormatEdit {
        GoodPostText.applyFormat(text: text, selectionStart: start, selectionEnd: end, format: format)
    }

    /// Nothing selected: the pair is planted and the caret lands between the markers, so
    /// typing continues inside the format.
    func testACaretPlantsThePairAndStandsBetweenIt() {
        let edit = apply("hello", 5, 5)

        XCTAssertEqual(edit.text, "hello**")
        XCTAssertEqual(edit.selectionStart, 6)
        XCTAssertEqual(edit.selectionEnd, 6)

        let middle = apply("hello world", 5, 5)
        XCTAssertEqual(middle.text, "hello** world")
        XCTAssertEqual(middle.selection, 6..<6)
    }

    /// A selection with no markup is wrapped, and the whole wrapped run stays selected —
    /// which is what lets the next tap take the pair off again.
    func testASelectionIsWrappedAndTheRunStaysSelected() {
        let edit = apply("hello world", 0, 5)

        XCTAssertEqual(edit.text, "*hello* world")
        XCTAssertEqual(edit.selection, 0..<7, "the delimiters are inside the selection")
    }

    /// Tapping twice is a round trip: wrap, then unwrap, back to the original text.
    func testTappingTwiceReturnsTheOriginalText() {
        let wrapped = apply("hello world", 0, 5)
        let unwrapped = apply(wrapped.text, wrapped.selectionStart, wrapped.selectionEnd)

        XCTAssertEqual(unwrapped.text, "hello world")
        XCTAssertEqual(unwrapped.selection, 0..<5, "the plain text is highlighted again")
    }

    /// A hand-selected word **inside** existing markers unwraps: the caller selected the
    /// text, not the markers.
    func testASelectionInsideExistingMarkersUnwraps() {
        let edit = apply("*hello* world", 1, 6)

        XCTAssertEqual(edit.text, "hello world")
        XCTAssertEqual(edit.selection, 0..<5)
    }

    /// A selection that starts on the space before a word — what a drag really produces —
    /// puts the markers **inside** the whitespace, which is what the renderer requires. A
    /// pair whose content begins with a space is refused by the renderer, so wrapping the
    /// space would have made the button look broken.
    func testWhitespaceStaysOutsideTheMarkers() {
        let edit = apply("her book", 3, 8, .italic)

        XCTAssertEqual(edit.text, "her _book_", "the markers hug the word, not the space")
        XCTAssertEqual(edit.selection, 4..<10)

        let trailing = apply("book her", 0, 5, .italic)
        XCTAssertEqual(trailing.text, "_book_ her", "and the same at the end of the selection")
    }

    /// A selection of nothing but whitespace has no text to format, so the pair is planted
    /// — at the *end* of the whitespace run, which is where the trimming scan leaves the
    /// insertion point. Predictable rather than silently nothing.
    func testAWhitespaceOnlySelectionPlantsThePair() {
        let edit = apply("a   b", 1, 4)

        XCTAssertEqual(edit.text, "a   **b")
        XCTAssertEqual(edit.selection, 5..<5)

        let wholeThing = apply("   ", 0, 3)
        XCTAssertEqual(wholeThing.text, "   **")
        XCTAssertEqual(wholeThing.selection, 4..<4)
    }

    /// The multi-run case: selecting `*a* and *b*` whole is two bold runs, not one, so it
    /// is wrapped rather than stripped — stripping the outer pair would leave `a* and *b`.
    func testTwoRunsAreNotTreatedAsOne() {
        XCTAssertFalse(GoodPostFormat.bold.wraps("*a* and *b*"))

        let edit = apply("*a* and *b*", 0, 11)
        XCTAssertEqual(edit.text, "**a* and *b**")
    }

    /// The conservative run test itself, including the cases it must reject.
    func testTheRunTest() {
        XCTAssertTrue(GoodPostFormat.bold.wraps("*bold*"))
        XCTAssertTrue(GoodPostFormat.monospace.wraps("```code```"))
        XCTAssertTrue(GoodPostFormat.strikethrough.wraps("~gone~"))
        XCTAssertFalse(GoodPostFormat.bold.wraps("*bold* extra *bold*"))
        XCTAssertFalse(GoodPostFormat.bold.wraps("**"), "an empty run is not a run")
        XCTAssertFalse(GoodPostFormat.bold.wraps("*"), "half a marker is not a run")
        XCTAssertFalse(GoodPostFormat.bold.wraps("plain"))
        XCTAssertFalse(
            GoodPostFormat.bold.wraps("*   *"),
            "a run of nothing but whitespace is not a run"
        )
        XCTAssertFalse(
            GoodPostFormat.italic.wraps("*bold*"),
            "another format's markers are not this one's"
        )
    }

    /// The three-character marker is handled as one marker, not as three toggles.
    func testTheMonospaceMarkerIsThreeCharacters() {
        let wrapped = apply("code", 0, 4, .monospace)

        XCTAssertEqual(wrapped.text, "```code```")
        XCTAssertEqual(wrapped.selection, 0..<10)

        let unwrapped = apply(wrapped.text, wrapped.selectionStart, wrapped.selectionEnd, .monospace)
        XCTAssertEqual(unwrapped.text, "code")
        XCTAssertEqual(unwrapped.selection, 0..<4)
    }

    /// A selection raced by a recomposition must not crash the editor: offsets outside
    /// the text are pulled back into it, and a reversed selection is read as a range.
    func testOutOfRangeAndReversedSelectionsAreHandled() {
        let beyond = apply("abc", 0, 99)
        XCTAssertEqual(beyond.text, "*abc*")
        XCTAssertEqual(beyond.selection, 0..<5)

        let negative = apply("abc", -5, 3)
        XCTAssertEqual(negative.text, "*abc*")

        let reversed = apply("hello", 5, 0)
        XCTAssertEqual(reversed.text, "*hello*")
        XCTAssertEqual(reversed.selection, 0..<7)

        let emptyText = apply("", 0, 0)
        XCTAssertEqual(emptyText.text, "**")
        XCTAssertEqual(emptyText.selection, 1..<1)
    }

    /// The formats are independent: wrapping bold inside italic keeps both markers.
    func testFormatsNest() {
        let italic = apply("note", 0, 4, .italic)
        let both = apply(italic.text, italic.selectionStart, italic.selectionEnd, .bold)

        XCTAssertEqual(both.text, "*_note_*")
        XCTAssertEqual(
            GoodPostText.applyFormat(
                text: both.text,
                selectionStart: both.selectionStart,
                selectionEnd: both.selectionEnd,
                format: .bold
            ).text,
            "_note_",
            "unwrapping bold leaves the italic run intact"
        )
    }

    /// What the toolbar highlights: the selection is one run of exactly these formats.
    func testTheActiveFormatsForASelection() {
        XCTAssertEqual(GoodPostText.activeFormats(text: "*bold*", selectionStart: 0, selectionEnd: 6), [.bold])
        XCTAssertEqual(
            GoodPostText.activeFormats(text: "```code```", selectionStart: 0, selectionEnd: 10),
            [.monospace]
        )
        XCTAssertEqual(GoodPostText.activeFormats(text: "plain", selectionStart: 0, selectionEnd: 5), [])
        XCTAssertEqual(
            GoodPostText.activeFormats(text: "plain", selectionStart: 2, selectionEnd: 2),
            [],
            "a caret has no formatting"
        )
        XCTAssertEqual(GoodPostText.activeFormats(text: "*bold*", selectionStart: 1, selectionEnd: 5), [])
    }

    /// Every format's marker and its round trip, so a new format cannot be added with the
    /// wrong marker and go unnoticed.
    func testEveryFormatRoundTrips() {
        for format in GoodPostFormat.allCases {
            let wrapped = apply("text", 0, 4, format)
            XCTAssertEqual(wrapped.text, "\(format.marker)text\(format.marker)", format.label)

            let unwrapped = apply(wrapped.text, wrapped.selectionStart, wrapped.selectionEnd, format)
            XCTAssertEqual(unwrapped.text, "text", format.label)
        }
    }
}

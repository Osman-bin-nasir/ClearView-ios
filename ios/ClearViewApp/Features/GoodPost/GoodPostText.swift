import Foundation

/// Good Post's inline formatting, in the WhatsApp dialect.
///
/// The stored representation is the text **itself**, with the markers left in it:
/// `*bold*`, `_italic_`, `~strikethrough~` and `` ```monospace``` ``. There is no
/// rich-text model, no HTML and no span table — a post body is one string, and this file
/// is the only place that knows the markers mean anything.
///
/// That choice is deliberate, and it is what makes formatting survive every step of the
/// round trip for free:
///
///  * **Storage** — the server keeps an opaque `text` column. It never parses, never
///    validates and never rewrites the body, so there is no server-side formatter to keep
///    in step with the client.
///  * **Reload and edit** — the raw string is what comes back, and it is what the editor
///    re-opens with, so an edit cannot lose formatting it never decoded.
///  * **Safety** — nothing is ever rendered as HTML. The renderer turns markers into
///    styled runs, so the worst a body can do is make text bold.
///
/// The trade is that markers are visible while typing, which is exactly how WhatsApp
/// behaves and why it needs no explanation.
enum GoodPostFormat: String, CaseIterable {
    case bold
    case italic
    case monospace
    case strikethrough

    /// The exact sequence that opens and closes this format.
    var marker: String {
        switch self {
        case .bold: return "*"
        case .italic: return "_"
        case .monospace: return "```"
        case .strikethrough: return "~"
        }
    }

    /// A name for accessibility and for the toolbar's tooltips.
    var label: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .monospace: return "Monospace"
        case .strikethrough: return "Strikethrough"
        }
    }

    /// True when `selected` is exactly **one** run of this format, so the toolbar can
    /// show it as active and a second tap can take it off.
    ///
    /// The content test is what makes this conservative, and it matters: `*a* and *b*`
    /// selected whole begins and ends with the marker, but it is two bold runs rather
    /// than one, and stripping only the outer pair would leave the mangled `a* and *b`.
    /// So a run counts only when the delimiters it is asked to remove are the only ones
    /// inside it.
    func wraps(_ selected: String) -> Bool {
        let characters = Array(selected)
        let width = marker.count
        let markerCharacters = Array(marker)
        guard characters.count > width * 2 else { return false }
        guard characters.starts(with: markerCharacters),
              characters.suffix(width).elementsEqual(markerCharacters) else { return false }
        let inner = Array(characters[width..<(characters.count - width)])
        guard !inner.isEmpty, !inner.allSatisfy({ $0.isWhitespace }) else { return false }
        return !contains(markerCharacters, in: inner)
    }

    private func contains(_ needle: [Character], in haystack: [Character]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            if Array(haystack[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }
}

/// The text and selection a formatting action leaves behind.
///
/// The selection comes back with the result rather than being recomputed by the caller
/// because the two are not independent: wrapping text moves the caret, and a caller that
/// kept its own offsets would put the caret in the middle of a marker.
struct GoodPostFormatEdit: Equatable {
    let text: String
    let selectionStart: Int
    let selectionEnd: Int

    /// The selection range as `Range<Int>` offsets into `text` (character offsets, which
    /// is what a SwiftUI text selection deals in — Kotlin's editor counts UTF-16 units,
    /// and this is the one place the two platforms' offsets are deliberately different
    /// units).
    var selection: Range<Int> { selectionStart..<selectionEnd }
}

/// What a formatting tap does to the text and the selection.
///
/// Four cases, and each is the one a person expects from a toolbar:
///
///  * **Nothing selected** — the marker pair is inserted with the caret between it, so
///    typing lands inside the format. The same as typing `**` by hand, which is what the
///    visible markers imply.
///  * **Selected, already formatted** — the pair is removed. This is what makes the
///    button a toggle rather than an "add another pair" button that would grow `*bold*`
///    into `**bold**`.
///  * **Selected, with the markers immediately outside it** — the same removal, found by
///    looking around the highlight instead of inside it. It is what unwraps a
///    hand-selected word inside `*bold*`, which is how someone who typed the markers
///    themselves expects it to behave.
///  * **Selected, not formatted** — the selection is wrapped, and the **whole** wrapped
///    run stays selected, delimiters included. Selecting the whole run is what lets the
///    next tap find case two rather than wrapping a second time; leaving only the inner
///    text highlighted made the button add a pair on every tap.
///
/// Pure, clamped and total: offsets outside the text are pulled back into it rather than
/// throwing, because a selection raced by a recomposition must not crash the editor.
enum GoodPostText {

    static func applyFormat(
        text: String,
        selectionStart: Int,
        selectionEnd: Int,
        format: GoodPostFormat
    ) -> GoodPostFormatEdit {
        let characters = Array(text)
        let length = characters.count
        let start = min(max(selectionStart, 0), length)
        let end = min(max(selectionEnd, 0), length)
        let from = min(start, end)
        let to = max(start, end)
        let marker = Array(format.marker)
        let width = marker.count

        // No selection: plant the pair and stand in the middle of it.
        if from == to {
            let updated = insert(marker + marker, at: from, into: characters)
            let caret = from + width
            return GoodPostFormatEdit(text: String(updated), selectionStart: caret, selectionEnd: caret)
        }

        // Whitespace at the ends of the selection is left OUTSIDE the markers.
        //
        // Nobody selects a word exactly: a drag starts on the character before it and
        // ends on the space after it. Wrapping what a finger actually covered used to
        // produce "``` her```", and the renderer refuses a pair whose content begins with
        // whitespace — so the button looked broken for monospace, italic and
        // strikethrough alike, and worked only when the selection happened to be
        // pixel-exact. The markers move inside the whitespace instead, which is what the
        // reader meant and what the stored text has to be to parse.
        var runStart = from
        var runEnd = to
        while runStart < runEnd, characters[runStart].isWhitespace { runStart += 1 }
        while runEnd > runStart, characters[runEnd - 1].isWhitespace { runEnd -= 1 }

        // A selection of nothing but whitespace has no text to format. The pair is planted
        // at the start of it, exactly as for a caret, so the control still does something
        // predictable rather than silently nothing.
        if runStart == runEnd {
            let updated = insert(marker + marker, at: runStart, into: characters)
            let caret = runStart + width
            return GoodPostFormatEdit(text: String(updated), selectionStart: caret, selectionEnd: caret)
        }

        let selected = Array(characters[runStart..<runEnd])

        // Already wrapped inside the selection: take the outer pair off.
        if format.wraps(String(selected)) {
            let inner = Array(selected[width..<(selected.count - width)])
            let updated = Array(characters[0..<runStart]) + inner + Array(characters[runEnd...])
            return GoodPostFormatEdit(
                text: String(updated),
                selectionStart: runStart,
                selectionEnd: runStart + inner.count
            )
        }

        // The markers sit immediately OUTSIDE the selection, so the highlighted text is
        // already this format. Removing them keeps the same characters highlighted.
        let outerStart = runStart - width
        let outerEnd = runEnd + width
        if outerStart >= 0, outerEnd <= length,
           matches(marker, in: characters, at: outerStart),
           matches(marker, in: characters, at: runEnd) {
            let updated = Array(characters[0..<outerStart]) + selected + Array(characters[outerEnd...])
            return GoodPostFormatEdit(
                text: String(updated),
                selectionStart: outerStart,
                selectionEnd: outerStart + selected.count
            )
        }

        // Wrap it, and select the whole wrapped run so the button toggles from here.
        let updated = Array(characters[0..<runStart]) + marker + selected + marker + Array(characters[runEnd...])
        return GoodPostFormatEdit(
            text: String(updated),
            selectionStart: runStart,
            selectionEnd: runEnd + (width * 2)
        )
    }

    /// The format a selection is already wrapped in, for a toolbar that highlights the
    /// active control. Nil when the selection is plain, empty, or spans more than one run
    /// of the same format.
    static func activeFormats(text: String, selectionStart: Int, selectionEnd: Int) -> Set<GoodPostFormat> {
        let characters = Array(text)
        let length = characters.count
        let from = min(max(min(selectionStart, selectionEnd), 0), length)
        let to = min(max(max(selectionStart, selectionEnd), 0), length)
        guard from < to else { return [] }
        let selected = String(characters[from..<to])
        return Set(GoodPostFormat.allCases.filter { $0.wraps(selected) })
    }

    /// True when the marker starts at `index` in `characters`.
    private static func matches(_ marker: [Character], in characters: [Character], at index: Int) -> Bool {
        guard index >= 0, index + marker.count <= characters.count else { return false }
        return Array(characters[index..<(index + marker.count)]) == marker
    }

    private static func insert(_ insertion: [Character], at index: Int, into characters: [Character]) -> [Character] {
        Array(characters[0..<index]) + insertion + Array(characters[index...])
    }
}

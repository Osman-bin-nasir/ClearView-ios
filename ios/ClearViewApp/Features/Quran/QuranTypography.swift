import SwiftUI
import UIKit

/// The typeface every Arabic Quran surface renders with, and the reader's scale.
///
/// The iOS counterpart of `quran/ui/QuranTypography.kt`, and it bundles the
/// **same two faces** the Android app does, in the same order:
///
/// 1. `DigitalKhattIndoPakRegular` — DigitalKhatt IndoPak, a purpose-built
///    IndoPak Mushaf face. The primary face, and the one that gives the text its
///    Mushaf look.
/// 2. `ScheherazadeNew-Regular` — the fallback for the marks the Mushaf face does
///    not carry. Measured over all 6236 verses, the corpus uses a newer IndoPak
///    encoding than the Mushaf face was built for and exactly eight codepoints
///    (U+0658, U+06E0, U+06E1, U+08D4, U+08DA, U+08E0, U+08E1, U+200F) fall
///    outside it.
///
/// ## Why the uncovered codepoints are rewritten instead of falling back
///
/// A fallback face is not enough on iOS, and the way it fails is the exact bug a
/// reader sees as "the letters are separate".
///
/// CoreText cuts a line into a **separate run per face** and shapes each run on
/// its own. Arabic joining is a property of a shaped run, so a run boundary in
/// the middle of a word **resets the joining state**: the letter before the break
/// is drawn in its final/initial form with a visible gap, and so is the letter
/// after it. The uncovered codepoints are not rare — U+06E1 is the corpus's jazm
/// and occurs **62,381 times** — so with a fallback face in play most words of
/// most verses were drawn as two or three disconnected fragments. Ayat al-Kursi
/// (2:255) measured **96 runs**, 73 of those glyphs drawn by the fallback face.
///
/// Android never showed this: Compose lays text out with HarfBuzz, which
/// substitutes a missing glyph from the next face **within the same shaping
/// run**, so the joining state survives the swap. There is no descriptor
/// attribute that makes CoreText merge the runs — a cascade list, with or without
/// a character set, still measures 96 runs — so the coverage has to come from the
/// primary face itself.
///
/// [drawableText] does that: it rewrites each uncovered codepoint as the
/// codepoint the Mushaf face draws the same mark as. Nothing falls to the
/// fallback, so no run is split, so every word joins — and the marks keep the
/// Mushaf face's own anchors instead of landing at another face's positions.
/// Measured over the whole corpus, 718,938 scalars and not one left uncovered.
///
/// ## Why the cascade list is still set
///
/// `ScheherazadeNew-Regular` stays chained behind the primary face as a safety
/// net, for a codepoint [drawableText] has not been taught about — a new edition,
/// or a mark this list does not name yet. It should never be reached for the
/// edition the app ships with, and `QuranSurahReaderTests` asserts that it is.
///
/// Regular, not bold: a Bold Quran face draws the marks heavy enough to merge
/// into the letters, which makes dense harakat harder to read, not easier. That is
/// why no weight is requested anywhere here.
enum QuranTypography {

    /// The extra vertical room a Quran line needs, as a multiple of the font size.
    /// Android's `QURAN_LINE_HEIGHT_RATIO`: combining marks are drawn above and
    /// below the base letters, and 2.0 gives them room at the traditional
    /// proportion. A ratio rather than a fixed size so the reader (30pt) and the
    /// compact surah list (18pt) both stay clear without hand-tuning each.
    static let lineHeightRatio: CGFloat = 2.0

    /// The base size of the verse on the home page, before the reader's scale.
    static let readerBaseSize: CGFloat = 30

    /// The base size of Arabic inside a list or a compact row.
    static let listBaseSize: CGFloat = 18

    /// The two bundled faces, by PostScript name — what `UIAppFonts` registers.
    static let primaryFace = "DigitalKhattIndoPakRegular"
    static let fallbackFace = "ScheherazadeNew-Regular"

    /// The corpus codepoints the Mushaf face has no glyph for, rewritten as the
    /// codepoint it draws the same mark as.
    ///
    /// Every entry is measured against the `ara-quranindopak` edition, not guessed
    /// from the Unicode names:
    ///
    /// - `U+06E1` — the IndoPak **jazm** (SILENT/sukoon). The corpus's dominant
    ///   unreplaced mark by two orders of magnitude: 62,381 of the 68,238
    ///   uncovered occurrences. Written as `U+0652`, the face's own sukoon.
    /// - `U+0658` — **noon ghunna**, the nasalisation mark written over a letter.
    ///   Written as `U+06E8`, the face's small high noon: 3,027 occurrences.
    /// - `U+06E0` — the Uthmani **upright rectangular zero**, a sukoon variant.
    ///   Written as `U+06DF`, the face's rounded zero: 25 occurrences.
    /// - `U+08D4`, `U+08DA`, `U+08E0`, `U+08E1` — word- and ayah-level signs
    ///   (ar-rub, ath-thalatha, footnote marker, sign safha), two to three
    ///   occurrences each in the whole Quran. Dropped: they annotate a mushaf
    ///   page's layout rather than the recitation, and there is no equivalent
    ///   glyph to borrow.
    /// - `U+200F` — the **right-to-left mark**, a zero-width bidi control the
    ///   edition writes at the end of a verse (2,796 occurrences). Dropped; it
    ///   draws nothing, and the reader states its direction explicitly.
    ///
    /// Empty replacements delete the codepoint. A mapping is only ever added for a
    /// codepoint proven absent from [primaryFace] — an entry for something the
    /// face does carry would replace a correct glyph with a different one.
    static let faceSubstitutions: [Unicode.Scalar: String] = [
        "\u{06E1}": "\u{0652}",
        "\u{0658}": "\u{06E8}",
        "\u{06E0}": "\u{06DF}",
        "\u{08D4}": "",
        "\u{08DA}": "",
        "\u{08E0}": "",
        "\u{08E1}": "",
        "\u{200F}": "",
    ]

    /// The Arabic as [primaryFace] can draw all of it — the text every Arabic
    /// surface must render, so no codepoint falls to the fallback and splits the
    /// run in the middle of a word.
    ///
    /// A pure rewrite, so it costs one pass and is trivially testable. Applied per
    /// surface rather than to the downloaded text on purpose: the stored edition
    /// stays exactly what the API returned, so the verse a reader copies or shares
    /// is the edition's own, codepoint for codepoint.
    static func drawableText(_ text: String) -> String {
        // Fast path: the overwhelming majority of Arabic in a verse is covered, so
        // a string with nothing to rewrite is returned untouched rather than
        // rebuilt.
        guard text.unicodeScalars.contains(where: { faceSubstitutions[$0] != nil }) else {
            return text
        }
        var rewritten = String.UnicodeScalarView()
        rewritten.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if let replacement = faceSubstitutions[scalar] {
                rewritten.append(contentsOf: replacement.unicodeScalars)
            } else {
                rewritten.append(scalar)
            }
        }
        return String(rewritten)
    }

    /// The Arabic font at `baseSize` scaled by the reader's choice, with the
    /// fallback face chained behind it.
    ///
    /// Falls back to the system font when even the primary face cannot be built,
    /// which is a build mistake rather than a state a reader can reach — but one
    /// that must not take the Quran tab down.
    static func font(baseSize: CGFloat, scale: CGFloat) -> Font {
        guard let face = uiFont(baseSize: baseSize, scale: scale) else {
            return .system(size: baseSize * scale)
        }
        return Font(face)
    }

    /// The built `UIFont` behind `font(baseSize:scale:)` — the Mushaf face with
    /// the fallback chained behind it, or nil when the face is not in the bundle.
    ///
    /// Split out of `font` for one reason: a SwiftUI `Font` cannot be inspected, so
    /// "the Arabic is set in the Quran's own face" would otherwise be a property
    /// nothing could assert — and it is precisely the property that fails
    /// *silently*, by drawing Arabic in the system font with a different face's
    /// mark anchors rather than by failing to build.
    static func uiFont(baseSize: CGFloat, scale: CGFloat) -> UIFont? {
        let size = baseSize * scale
        guard let primary = UIFont(name: primaryFace, size: size) else { return nil }
        let cascade = cascadeDescriptors(size: size)
        guard !cascade.isEmpty else { return primary }
        let descriptor = primary.fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontCascadeListAttribute as String): cascade
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    /// The faces chained behind the primary one for the codepoints it does not
    /// carry — empty when the fallback face is not in the bundle, in which case the
    /// head of the chain is all there is.
    ///
    /// A safety net, not the coverage story: [drawableText] is what keeps the
    /// corpus inside the primary face. This only decides what happens if a future
    /// text reaches the reader with a codepoint neither knows about — a glyph from
    /// the fallback face rather than a `.notdef` box or a system face.
    static func cascadeDescriptors(size: CGFloat) -> [CTFontDescriptor] {
        guard UIFont(name: fallbackFace, size: size) != nil else { return [] }
        return [CTFontDescriptorCreateWithNameAndSize(fallbackFace as CFString, size)]
    }

    /// The ayah's own number, as a mushaf writes it: the end-of-ayah ornament
    /// `۝` followed by the number in Arabic-Indic digits.
    ///
    /// Android's `arabicDigits`, and the reason neither reader carries a separate
    /// counter or a Western numeral badge: a printed mushaf states the position
    /// *inside* the running text, at the end of the verse it closes, and the
    /// reader that adds a second numbering on the side is the one that looks
    /// wrong next to a page of scripture.
    ///
    /// Both codepoints it uses — U+06DD and the digits — are in the Mushaf face, so
    /// the ornament needs no rewriting and joins the verse it closes.
    static func ayahOrnament(_ ayahNumber: Int32) -> String {
        "۝" + arabicDigits(ayahNumber)
    }

    /// `12` → `١٢` — the digits U+0660–U+0669, the same mapping Android's
    /// `arabicDigits` uses, so the two platforms number a verse identically.
    static func arabicDigits(_ value: Int32) -> String {
        String(value).map { character in
            guard let digit = character.wholeNumberValue, (0...9).contains(digit) else {
                return String(character)
            }
            return String(UnicodeScalar(0x0660 + digit)!)
        }.joined()
    }

    /// The line spacing that keeps pace with `font(baseSize:scale:)`.
    ///
    /// Derived rather than set independently, because the marks only stay
    /// unclipped if the line grows with the glyphs: a fixed spacing that fits
    /// 30pt clips a 45pt verse. Compose sets a *line box* of `size × 2.0`;
    /// SwiftUI's `lineSpacing` is the gap it adds *between* lines, so the ratio
    /// minus the face's own default leading (≈1.17 em) is what reproduces the
    /// same line box here.
    static func lineSpacing(baseSize: CGFloat, scale: CGFloat) -> CGFloat {
        max(0, (lineHeightRatio - 1.17) * baseSize * scale)
    }

    /// The Arabic scripture as a `Text`: the text rewritten to stay inside the
    /// Mushaf face ([drawableText]) and set in it, at the reader's size.
    ///
    /// The single construction every Arabic surface should use for the *text*.
    /// Splitting [drawableText] from [font] would leave two things a surface can
    /// get wrong, and getting the first one wrong is invisible in review — the
    /// text is still Arabic, just with its words broken apart.
    ///
    /// A `Text` rather than a `View` so a surface can still concatenate it (the
    /// reader appends the ayah ornament) and tint the two parts separately — which
    /// is also why the line box is *not* set here: `lineSpacing` is a `View`
    /// modifier, so it has to be applied to the concatenated result, where it
    /// spaces the whole ayah rather than half of it.
    static func arabic(_ text: String, baseSize: CGFloat, scale: CGFloat) -> Text {
        Text(drawableText(text))
            .font(font(baseSize: baseSize, scale: scale))
    }
}

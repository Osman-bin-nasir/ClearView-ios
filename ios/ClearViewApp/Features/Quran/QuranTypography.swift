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
///    encoding than the Mushaf face was built for and exactly seven codepoints
///    (U+0658, U+06E0, U+06E1, U+08D4, U+08DA, U+08E0, U+08E1) fall to this face.
///
/// ## Why the cascade list is set by hand
///
/// Compose resolves a `FontFamily` with several faces as a fallback chain for the
/// same codepoint. iOS does not: it draws a missing glyph from its own system
/// fallback, which would put a *different* Arabic face — with different mark
/// anchors — into the middle of authoritative scripture, and the seven codepoints
/// above would land differently from Android's. Setting the cascade list on the
/// font descriptor names the second face explicitly, so a mark Android draws with
/// Scheherazade is the mark iOS draws with Scheherazade.
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
    /// A function of its own so the chain can be asserted: what it holds is the part
    /// iOS does not do by itself, and a descriptor assembled without it draws the
    /// seven uncovered codepoints with the *system's* fallback face instead of the
    /// one Android uses.
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
}

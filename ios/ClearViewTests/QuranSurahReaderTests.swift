import XCTest
import UIKit
import CoreText
@testable import ClearView

/// The surah reader's numbering and its face — the two properties of the mushaf
/// page that neither the compiler nor a screenshot would catch.
///
/// ## The ayah marker
///
/// A verse's position is drawn *inside* its own Arabic, as the end-of-ayah
/// ornament `۝` followed by the number in Arabic-Indic digits, which is how a
/// printed mushaf writes it. The failure this guards against is subtler than
/// "the number is missing": a Latin `12` in a separate reference line beside a
/// `...۝١٢` is the same number stated twice in two scripts, and it reads as a
/// list of excerpts rather than as a page of Quran.
///
/// The anchors are the same two the Android test pins
/// (`app/src/test/java/com/muddassir/clearview/ui/QuranSurahReaderTest.kt`), so the
/// two platforms cannot drift into numbering a verse differently: Android asserts
/// `arabicDigits(1) == "\u0661"` and `arabicDigits(128) == "\u0661\u0662\u0668"`,
/// and so does this.
///
/// ## The face
///
/// `QuranTypography.font` falls back to the system font when the bundled face
/// cannot be built, and that fallback is the whole reason it can fail *silently*:
/// a missing file, a renamed face, or a `UIAppFonts` entry dropped from
/// `ios/Info.plist` all leave the app building and drawing Arabic — just not the
/// Quran's own Arabic, and with mark anchors belonging to a different face. The
/// resolver below is the exact call the reader makes, so this test fails the
/// moment the Mushaf face stops resolving.
final class QuranSurahReaderTests: XCTestCase {

    // MARK: - The ayah marker

    /// Single digits and multi-digit numbers, in the digits a mushaf uses.
    func testTheAyahMarkerCarriesArabicIndicDigits() {
        XCTAssertEqual(QuranTypography.arabicDigits(1), "\u{0661}")
        XCTAssertEqual(QuranTypography.arabicDigits(128), "\u{0661}\u{0662}\u{0668}")
    }

    /// Every digit is mapped, not just the ones a short surah reaches: Al-Baqara's
    /// 286 is the longest ayah number in the Quran, and it is the one a wrong
    /// mapping is most likely to mangle.
    func testEveryDigitOfTheLongestAyahNumberIsMapped() {
        XCTAssertEqual(QuranTypography.arabicDigits(286), "\u{0662}\u{0668}\u{0666}")
        XCTAssertEqual(QuranTypography.arabicDigits(9), "\u{0669}")
        XCTAssertEqual(QuranTypography.arabicDigits(10), "\u{0661}\u{0660}")
    }

    /// The ornament is the end-of-ayah mark *and* the number together — the mark
    /// alone would state no position, and the number alone would not say where the
    /// verse ends.
    func testTheOrnamentIsTheEndOfAyahMarkAroundTheNumber() {
        XCTAssertEqual(QuranTypography.ayahOrnament(1), "۝\u{0661}")
        XCTAssertEqual(QuranTypography.ayahOrnament(286), "۝\u{0662}\u{0668}\u{0666}")
        // No Latin digit survives into the ornament. This is the assertion that
        // fails if Arabic-Indic mapping is ever swapped for `String(number)`.
        XCTAssertFalse(QuranTypography.ayahOrnament(128).contains(where: \.isASCII))
    }

    // MARK: - The face

    /// The two faces the reader renders Arabic with are in the bundle and resolve
    /// by the PostScript names the code asks for.
    ///
    /// A PostScript name that does not match the file is the failure mode worth
    /// pinning: the font file ships, `UIAppFonts` lists it, and `UIFont(name:)`
    /// still returns nil — so the app draws the scripture in the system font and
    /// nothing anywhere reports a problem.
    func testTheMushafFacesAreBundledAndResolve() {
        XCTAssertNotNil(
            UIFont(name: QuranTypography.primaryFace, size: 30),
            "the IndoPak Mushaf face (\(QuranTypography.primaryFace)) must ship and register"
        )
        XCTAssertNotNil(
            UIFont(name: QuranTypography.fallbackFace, size: 30),
            "the coverage fallback face (\(QuranTypography.fallbackFace)) must ship and register"
        )
    }

    /// The reader's Arabic is set in the Mushaf face, at the reader's size — the
    /// font `SurahReaderView` actually draws a verse with.
    ///
    /// This is the assertion the reader did not have: with the face resolving but
    /// nothing checking it, a verse could be drawn with `Font.system` and look
    /// plausibly Arabic while being the wrong face with the wrong mark anchors.
    func testTheReaderVerseIsSetInTheMushafFace() throws {
        let face = try XCTUnwrap(
            QuranTypography.uiFont(baseSize: QuranTypography.readerBaseSize, scale: 1),
            "a verse must be built from the bundled face, not the system font"
        )

        XCTAssertEqual(face.fontName, QuranTypography.primaryFace)
        // Android's `quranFontSize(30f)` for a verse in the reader.
        XCTAssertEqual(QuranTypography.readerBaseSize, 30)
        XCTAssertEqual(face.pointSize, 30)

        // ...and the reader's chosen scale reaches the face, so the size controls
        // move the scripture rather than the chrome around it.
        let larger = try XCTUnwrap(QuranTypography.uiFont(baseSize: 30, scale: 2), "the face must scale")
        XCTAssertEqual(larger.pointSize, 60)
    }

    /// The fallback face is attached as a Core Text **cascade** list, which is the
    /// part iOS does not do on its own.
    ///
    /// Compose resolves a `FontFamily` of several faces itself; iOS draws a
    /// missing glyph from its own system fallback instead. The seven codepoints the
    /// Mushaf face does not carry would therefore be drawn by a different Arabic
    /// face on iOS than on Android — the same verse, two different mark positions.
    /// Setting the cascade list is what prevents that, so it is pinned here: a
    /// descriptor assembled without it would otherwise pass every other check in
    /// this file.
    func testTheFallbackFaceIsChainedAsACascade() throws {
        // What is chained, and which face it names.
        let cascade = QuranTypography.cascadeDescriptors(size: 30)
        XCTAssertEqual(cascade.count, 1, "the coverage face must be chained behind the primary one")
        XCTAssertEqual(
            UIFont(descriptor: cascade[0], size: 30).fontName,
            QuranTypography.fallbackFace,
            "the chained face must be the coverage face, not another copy of the primary one"
        )

        // ...and that the chain is attached to the font the reader actually draws
        // with. Asked as a count, because the attribute is Core Text's own array:
        // a descriptor carrying no cascade list draws the uncovered marks in the
        // system's fallback face, which is the failure this pins.
        let face = try XCTUnwrap(QuranTypography.uiFont(baseSize: 30, scale: 1))
        let key = UIFontDescriptor.AttributeName(rawValue: kCTFontCascadeListAttribute as String)
        let attached = face.fontDescriptor.fontAttributes[key] as? NSArray
        XCTAssertEqual(attached?.count, 1, "the cascade must reach the font the reader draws with")
    }

    /// The reader's line box is Android's `QURAN_LINE_HEIGHT_RATIO`, so the harakat
    /// have the room the marks need at every size the reader can choose.
    ///
    /// Derived rather than fixed, and this is the property that keeps it honest:
    /// the space above the marks must grow with the glyphs, so a line box that fits
    /// a 24pt verse must not be reused at 60pt.
    func testTheLineBoxGrowsWithTheAyahType() {
        let small = QuranTypography.lineSpacing(baseSize: 30, scale: 1)
        let large = QuranTypography.lineSpacing(baseSize: 30, scale: 2)

        XCTAssertGreaterThan(small, 0, "the marks need room above the baseline")
        XCTAssertEqual(large, small * 2, accuracy: 0.001, "the line box must scale with the type")
    }
}

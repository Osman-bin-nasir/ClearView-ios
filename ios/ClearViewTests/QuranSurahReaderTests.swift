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

    // MARK: - Coverage: the face the corpus is actually written in

    /// Al-Faatiha 1:1 as the `ara-quranindopak` edition writes it, including the
    /// two marks the Mushaf face has no glyph for: U+06E1 (jazm) in `بِسۡمِ` and
    /// U+0670 elsewhere.
    private static let basmala =
        "\u{0628}\u{0650}\u{0633}\u{06E1}\u{0645}\u{0650} \u{0627}\u{064E}\u{0644}\u{0644}\u{064E}\u{0647}\u{0650}"

    /// Every substitution names a codepoint the Mushaf face really lacks, and
    /// replaces it with one it really carries.
    ///
    /// This is the assertion that keeps the table honest in both directions. An
    /// entry for a codepoint the face *does* carry would replace a correct glyph
    /// with a different one — a silent change to scripture that no other check in
    /// this file would notice, because the verse would still render.
    func testSubstitutionsOnlyCoverCodepointsTheFaceLacks() throws {
        let face = try XCTUnwrap(UIFont(name: QuranTypography.primaryFace, size: 30))
        let covered = CTFontCopyCharacterSet(face as CTFont) as CharacterSet

        for (uncovered, replacement) in QuranTypography.faceSubstitutions {
            let code = String(uncovered.value, radix: 16, uppercase: true)
            XCTAssertFalse(
                covered.contains(uncovered),
                "U+\(code) is carried by the Mushaf face, so rewriting it changes a correct glyph"
            )
            for scalar in replacement.unicodeScalars {
                XCTAssertTrue(
                    covered.contains(scalar),
                    "the replacement for U+\(code) must be a codepoint the face carries"
                )
            }
        }
    }

    /// The reader draws a verse as **one** run in the Mushaf face — the property
    /// the whole substitution table exists to buy.
    ///
    /// CoreText starts a new run at every codepoint the face cannot draw, and each
    /// run is shaped on its own, so a run boundary inside a word breaks the Arabic
    /// joining and the letters come out detached. Without `drawableText` this verse
    /// measures two runs, the second in the fallback face; with it, one run in the
    /// Mushaf face. The attributed string is built with exactly the two calls
    /// `SurahReaderView` makes, because a SwiftUI `Text` cannot be inspected.
    func testAVerseLaysOutAsASingleRunInTheMushafFace() throws {
        let source = Self.basmala
        XCTAssertTrue(source.unicodeScalars.contains("\u{06E1}"), "the fixture must carry an uncovered mark")

        let face = try XCTUnwrap(QuranTypography.uiFont(baseSize: QuranTypography.readerBaseSize, scale: 1))
        let wordCount = source.split(separator: " ").count

        func runs(in text: String) -> [CTRun] {
            let attributed = NSAttributedString(string: text, attributes: [.font: face])
            return CTLineGetGlyphRuns(CTLineCreateWithAttributedString(attributed)) as! [CTRun]
        }
        func faces(of runs: [CTRun]) -> Set<String> {
            Set(runs.map { run in
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let runFont = attributes[kCTFontAttributeName as String] as! CTFont
                return CTFontCopyPostScriptName(runFont) as String
            })
        }

        // The bug, pinned: the raw edition text splits into more runs than the
        // verse has words and hands some of it to another face.
        let raw = runs(in: source)
        XCTAssertGreaterThan(
            raw.count,
            wordCount,
            "an uncovered mark must be what splits the verse, or this test is not exercising the fix"
        )
        XCTAssertNotEqual(faces(of: raw), [QuranTypography.primaryFace])

        // The fix: fewer, uninterrupted runs, every one of them the Mushaf face.
        // The count is deliberately not pinned to the word count — CoreText splits
        // whitespace into its own run in some shapes and not others, so the number
        // is not the property. "No glyph falls to another face" is, and it is what
        // stops a run boundary landing inside a word.
        XCTAssertEqual(QuranTypography.drawableText(source), source.replacingOccurrences(of: "\u{06E1}", with: "\u{0652}"))
        let fixed = runs(in: QuranTypography.drawableText(source))
        XCTAssertLessThan(fixed.count, raw.count, "the substitutions must remove the run boundaries, not move them")
        XCTAssertEqual(faces(of: fixed), [QuranTypography.primaryFace], "no glyph may fall to another face")
    }

    /// The verse the reader draws — text plus its end-of-ayah ornament — asks for
    /// no face but the Mushaf one, so the ayah's number is drawn by the face the
    /// verse is set in rather than by a system fallback.
    func testTheOrnamentIsDrawnInTheMushafFace() throws {
        let face = try XCTUnwrap(QuranTypography.uiFont(baseSize: 30, scale: 1))
        let line = QuranTypography.drawableText("\u{0645}\u{06E1}\u{0646}")
            + QuranTypography.ayahOrnament(12)
        let attributed = NSAttributedString(string: line, attributes: [.font: face])
        let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(attributed)) as! [CTRun]

        XCTAssertFalse(runs.isEmpty, "the verse must draw something")
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName as String] as! CTFont
            XCTAssertEqual(
                CTFontCopyPostScriptName(runFont) as String,
                QuranTypography.primaryFace,
                "the ornament is drawn in the verse's own face, not the system fallback"
            )
        }
    }
}

import XCTest
@testable import ClearView
import SharedKotlin

/// Tests for the reminder: the stored current verse, picking a new one, and
/// stepping to a neighbour.
///
/// The stepping rule itself is tested in the shared module (`QuranSequenceTest`,
/// running on JVM and iOS). What is tested here is that the repository actually
/// puts it to use, that a pick is persisted, and that the injected picker makes
/// "don't repeat the current verse" observable — that rule is otherwise invisible
/// behind an unseeded random source.
final class QuranReminderTests: XCTestCase {

    private var directory: URL!
    private var cache: QuranCache!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: QuranStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuranReminderTests-\(UUID().uuidString)", isDirectory: true)
        cache = QuranCache(directory: directory)

        suiteName = "QuranReminderTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = QuranStore(defaults: defaults)

        // A lopsided edition — surah 1 with 2 ayahs, surah 2 with 3 — so a surah
        // boundary is reachable from both sides and no surah-length table could be
        // what makes the boundary tests pass.
        try cache.write(.english, json: edition(
            (1...2).map { (1, $0, "faatiha \($0)") } + (1...3).map { (2, $0, "baqara \($0)") }
        ))
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    private func makeRepository() -> QuranRepository {
        QuranRepository(cache: cache, fetcher: UnreachableFetcher(), store: store)
    }

    /// Serves a fixed script of indices, then repeats the last one — so a test can
    /// say exactly what the picker was offered.
    private final class ScriptedPicker {
        private var script: [Int]
        private let fallback: Int
        init(_ script: [Int]) {
            self.script = script
            fallback = script.last ?? 0
        }
        func next(_ count: Int) -> Int {
            guard !script.isEmpty else { return fallback }
            return script.removeFirst()
        }
    }

    // MARK: - The stored verse

    /// Nothing stored before the first pick, which must read as nil rather than as
    /// a verse with no text.
    func testAFreshStoreHasNoCurrentVerse() {
        XCTAssertNil(store.currentVerse)
    }

    /// Every field survives the store, including the ones the reminder needs to
    /// render a position and a count.
    func testTheCurrentVerseRoundTripsThroughTheStore() {
        let verse = QuranVerse(
            surahNumber: 36, ayahNumber: 68, surahName: "Yaseen",
            surahTranslation: "Yaseen", text: "Do they not then understand?",
            arabicText: "اَفَلَا يَعۡقِلُوۡنَ", totalAyahs: 83
        )

        store.saveCurrentVerse(verse)

        let read = try? XCTUnwrap(store.currentVerse)
        XCTAssertEqual(read?.surahNumber, 36)
        XCTAssertEqual(read?.ayahNumber, 68)
        XCTAssertEqual(read?.surahName, "Yaseen")
        XCTAssertEqual(read?.text, "Do they not then understand?")
        XCTAssertEqual(read?.arabicText, "اَفَلَا يَعۡقِلُوۡنَ")
        XCTAssertEqual(read?.totalAyahs, 83)
    }

    /// A store written by a build that never finished picking is "no verse", not a
    /// blank one — the caller's response is to pick again.
    func testAHalfWrittenVerseReadsAsNone() {
        defaults.set(36, forKey: "current_surah_number")
        defaults.set(68, forKey: "current_ayah_number")
        // ...and no text.

        XCTAssertNil(store.currentVerse)
    }

    /// Every key is the Android store's, so the reminder survives a move between
    /// the platforms.
    func testItWritesTheAndroidCurrentVerseKeys() {
        // The Arabic is a constant rather than two literals: written twice, a
        // missing combining mark makes the test fail for a reason that has nothing
        // to do with the store.
        let arabic = "اللّٰهُ لَآ إِلٰهَ إِلَّا هُوَ"
        let english = "Allah - there is no deity except Him"
        store.saveCurrentVerse(
            QuranVerse(
                surahNumber: 2, ayahNumber: 255, surahName: "Al-Baqara",
                surahTranslation: "The Cow", text: english,
                arabicText: arabic, totalAyahs: 286
            )
        )

        XCTAssertEqual(defaults.integer(forKey: "current_surah_number"), 2)
        XCTAssertEqual(defaults.integer(forKey: "current_ayah_number"), 255)
        XCTAssertEqual(defaults.string(forKey: "current_surah_name"), "Al-Baqara")
        XCTAssertEqual(defaults.string(forKey: "current_surah_translation"), "The Cow")
        XCTAssertEqual(defaults.string(forKey: "current_verse_text"), english)
        XCTAssertEqual(defaults.string(forKey: "current_verse_arabic_text"), arabic)
        XCTAssertEqual(defaults.integer(forKey: "current_verse_total_ayahs"), 286)
        // The Arabic must survive byte-for-byte: this is the store the reader and
        // the widget read, and a lossy write would corrupt scripture.
        XCTAssertNil(QuranTextIntegrity.shared.problemWith(text: arabic))
    }

    // MARK: - The reader's Arabic size

    /// The size starts at 1.0 (the default) and persists once changed.
    func testTheArabicTextScaleDefaultsAndPersists() {
        XCTAssertEqual(store.arabicTextScale, 1.0, accuracy: 0.0001)

        store.arabicTextScale = 1.4

        let reopened = QuranStore(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(reopened.arabicTextScale, 1.4, accuracy: 0.0001)
    }

    /// The size is clamped by the store, not by the control that writes it.
    ///
    /// A scale of 0 renders the scripture invisible and a huge one makes a single
    /// ayah fill the screen, so the bound belongs where every writer passes — and
    /// so does the guarantee that a value already stored outside it is repaired on
    /// read rather than reproduced.
    func testTheArabicTextScaleIsClamped() {
        store.arabicTextScale = 99
        XCTAssertEqual(store.arabicTextScale, QuranStore.arabicTextScaleRange.upperBound, accuracy: 0.0001)

        store.arabicTextScale = 0
        XCTAssertEqual(store.arabicTextScale, QuranStore.arabicTextScaleRange.lowerBound, accuracy: 0.0001)

        // ...and a nonsense value already on disk reads back clamped, not as-is.
        defaults.set(0.0, forKey: "arabic_text_scale")
        XCTAssertEqual(store.arabicTextScale, 1.0, accuracy: 0.0001, "zero on disk means 'unset', not 'invisible'")
    }

    /// The reader opens at the stored size and steps it in both directions.
    @MainActor
    func testTheReaderStepsTheArabicScale() async throws {
        let repository = makeRepository()
        store.arabicTextScale = 1.0
        let model = SurahReaderModel(
            surah: SurahSummary(number: 2, name: "Al-Baqara", translation: "The Cow", ayahCount: 3),
            repository: repository,
            store: store
        )
        await model.load()
        XCTAssertEqual(model.arabicTextScale, 1.0, accuracy: 0.0001, "the reader must open at the stored size")

        model.increaseArabicScale()
        XCTAssertEqual(model.arabicTextScale, 1.2, accuracy: 0.0001)
        XCTAssertEqual(store.arabicTextScale, 1.2, accuracy: 0.0001, "and the choice must be persisted")

        model.decreaseArabicScale()
        XCTAssertEqual(model.arabicTextScale, 1.0, accuracy: 0.0001)
    }

    /// The controls stop at the range, so the reader is never offered a tap that
    /// does nothing — and the model's own value follows the store's clamp rather
    /// than running away from it.
    @MainActor
    func testTheArabicScaleControlsStopAtTheRange() async throws {
        let repository = makeRepository()
        let model = SurahReaderModel(
            surah: SurahSummary(number: 2, name: "Al-Baqara", translation: "The Cow", ayahCount: 3),
            repository: repository,
            store: store
        )
        await model.load()

        for _ in 0..<20 { model.increaseArabicScale() }
        XCTAssertEqual(model.arabicTextScale, QuranStore.arabicTextScaleRange.upperBound, accuracy: 0.0001)
        XCTAssertFalse(model.canIncreaseArabicScale, "the increase control must switch off at the ceiling")

        for _ in 0..<40 { model.decreaseArabicScale() }
        XCTAssertEqual(model.arabicTextScale, QuranStore.arabicTextScaleRange.lowerBound, accuracy: 0.0001)
        XCTAssertFalse(model.canDecreaseArabicScale)
        XCTAssertTrue(model.canIncreaseArabicScale, "and back on once there is room")
    }

    // MARK: - Picking

    /// A first pick chooses a verse, saves it, and attaches its surah's count.
    func testAFirstPickIsSavedAsTheCurrentVerse() async throws {
        let repository = makeRepository()

        let picked = try await repository.pickRandomVerse(using: { _ in 3 })

        XCTAssertEqual(picked?.surahNumber, 2)
        XCTAssertEqual(picked?.ayahNumber, 2)
        XCTAssertEqual(picked?.totalAyahs, 3, "the surah's ayah count must come from the edition")
        XCTAssertEqual(store.currentVerse?.ayahNumber, 2, "and it must be persisted")
    }

    /// The pick must not repeat the verse already on screen when there is a choice
    /// — the reason the rule exists at all.
    func testAPickDoesNotRepeatTheCurrentVerse() async throws {
        let repository = makeRepository()
        // Verse at index 0 is on screen.
        store.saveCurrentVerse(
            QuranVerse(
                surahNumber: 1, ayahNumber: 1, surahName: "Al-Faatiha",
                surahTranslation: "The Opening", text: "faatiha 1", arabicText: "", totalAyahs: 2
            )
        )
        // The picker keeps offering index 0 (the current verse) before landing on 1.
        let picker = ScriptedPicker([0, 0, 1])

        let picked = try await repository.pickRandomVerse(using: picker.next)

        XCTAssertEqual(picked?.surahNumber, 1)
        XCTAssertEqual(picked?.ayahNumber, 2, "offering the current verse must be retried, not accepted")
    }

    /// The retry is bounded: a picker that only ever offers the current verse
    /// still returns, so the reminder cannot hang.
    func testTheRetryIsBounded() async throws {
        let repository = makeRepository()
        store.saveCurrentVerse(
            QuranVerse(
                surahNumber: 1, ayahNumber: 1, surahName: "Al-Faatiha",
                surahTranslation: "The Opening", text: "faatiha 1", arabicText: "", totalAyahs: 2
            )
        )

        let picked = try await repository.pickRandomVerse(using: { _ in 0 })

        XCTAssertEqual(picked?.ayahNumber, 1, "after the retries are spent, the same verse is acceptable")
    }

    /// A bad index from the injected picker is clamped rather than trapping — the
    /// generator is supplied by the caller, so it can be wrong.
    func testAnOutOfRangeIndexIsClamped() async throws {
        let repository = makeRepository()

        let high = try await repository.pickRandomVerse(using: { _ in 999 })
        XCTAssertEqual(high?.surahNumber, 2)
        XCTAssertEqual(high?.ayahNumber, 3)

        let low = try await repository.pickRandomVerse(using: { _ in -5 })
        XCTAssertEqual(low?.surahNumber, 1)
        XCTAssertEqual(low?.ayahNumber, 1)
    }

    /// An Arabic-only install: the pick still works and the reminder is readable.
    func testAPickWorksWithoutTheArabicEdition() async throws {
        let repository = makeRepository()

        let picked = try await repository.pickRandomVerse(using: { _ in 0 })

        XCTAssertEqual(picked?.arabicText, "")
        XCTAssertFalse(picked?.text.isEmpty ?? true, "the English text is what makes it readable")
    }

    // MARK: - Stepping

    /// Stepping forward crosses a surah boundary with no special case.
    func testSteppingForwardCrossesASurahBoundary() async throws {
        let repository = makeRepository()

        let next = try await repository.adjacentVerse(from: 1, ayahNumber: 2, step: 1)

        XCTAssertEqual(next?.surahNumber, 2)
        XCTAssertEqual(next?.ayahNumber, 1)
        XCTAssertEqual(store.currentVerse?.surahNumber, 2, "stepping is persisted: it moves the reminder")
    }

    /// Stepping backward does too.
    func testSteppingBackwardCrossesASurahBoundary() async throws {
        let repository = makeRepository()

        let previous = try await repository.adjacentVerse(from: 2, ayahNumber: 1, step: -1)

        XCTAssertEqual(previous?.surahNumber, 1)
        XCTAssertEqual(previous?.ayahNumber, 2)
    }

    /// The two ends of the Quran have no neighbour, and say so.
    func testTheEndsOfTheQuranHaveNoNeighbour() async throws {
        let repository = makeRepository()

        let beforeFirst = try await repository.adjacentVerse(from: 1, ayahNumber: 1, step: -1)
        XCTAssertNil(beforeFirst)

        let afterLast = try await repository.adjacentVerse(from: 2, ayahNumber: 3, step: 1)
        XCTAssertNil(afterLast)

        let hasNext = try await repository.hasAdjacentVerse(from: 2, ayahNumber: 3, step: 1)
        XCTAssertFalse(hasNext, "a Next button must be disabled at the last ayah")
        let hasPrevious = try await repository.hasAdjacentVerse(from: 2, ayahNumber: 3, step: -1)
        XCTAssertTrue(hasPrevious)
    }

    /// A nil step must not overwrite the reminder with nothing.
    func testAStepThatGoesNowhereLeavesTheReminderAlone() async throws {
        let repository = makeRepository()
        store.saveCurrentVerse(
            QuranVerse(
                surahNumber: 2, ayahNumber: 3, surahName: "Al-Baqara",
                surahTranslation: "The Cow", text: "baqara 3", arabicText: "", totalAyahs: 3
            )
        )

        let result = try await repository.adjacentVerse(from: 2, ayahNumber: 3, step: 1)

        XCTAssertNil(result)
        XCTAssertEqual(store.currentVerse?.ayahNumber, 3, "the previous reminder must still be there")
    }

    // MARK: - Backfill

    /// A verse stored before its surah's count was known gets the count filled in.
    func testBackfillFillsInAMissingAyahCount() async throws {
        let repository = makeRepository()
        store.saveCurrentVerse(
            QuranVerse(
                surahNumber: 1, ayahNumber: 1, surahName: "Al-Faatiha",
                surahTranslation: "The Opening", text: "faatiha 1", arabicText: "", totalAyahs: 0
            )
        )

        let backfilled = await repository.backfillCurrentVerseTotals()

        XCTAssertEqual(backfilled?.totalAyahs, 2, "counted from the edition, not hardcoded")
        XCTAssertEqual(store.currentVerse?.totalAyahs, 2, "and saved, so it need not be counted twice")
    }

    /// A verse that already knows its count is left alone.
    func testBackfillLeavesAKnownCountAlone() async throws {
        let repository = makeRepository()
        store.saveCurrentVerse(
            QuranVerse(
                surahNumber: 1, ayahNumber: 1, surahName: "Al-Faatiha",
                surahTranslation: "The Opening", text: "faatiha 1", arabicText: "", totalAyahs: 2
            )
        )

        let backfilled = await repository.backfillCurrentVerseTotals()

        XCTAssertEqual(backfilled?.totalAyahs, 2)
    }

    /// Nothing stored is not a failure to backfill.
    func testBackfillOfNothingIsNothing() async {
        let repository = makeRepository()

        let backfilled = await repository.backfillCurrentVerseTotals()

        XCTAssertNil(backfilled)
    }

    // MARK: - Helpers

    private func edition(_ ayahs: [(surah: Int, ayah: Int, text: String)]) -> String {
        let rows = ayahs
            .map { #"{"chapter":\#($0.surah),"verse":\#($0.ayah),"text":"\#($0.text)"}"# }
            .joined(separator: ",")
        return #"{"quran":[\#(rows)]}"#
    }
}

private struct UnreachableFetcher: QuranEditionFetching {
    func fetch(_ edition: QuranEdition) async throws -> String {
        throw URLError(.cannotConnectToHost)
    }
}

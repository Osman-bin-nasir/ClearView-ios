import XCTest
@testable import ClearView
import SharedKotlin

/// Tests for what the Quran tab remembers between launches: reading positions,
/// bookmarked verses and starred surahs.
///
/// The *rules* are tested where they live — in the shared Kotlin module
/// (`QuranReadingPositionsTest`, `QuranVerseKeysTest`, both running on JVM and
/// iOS). What is tested here is the Swift half: that the store delegates to those
/// rules rather than reimplementing them, and that it writes the same keys and
/// the same string shapes the Android app writes. If that drifts, a reader's
/// bookmarks stop surviving a move between platforms — which is the whole reason
/// the encoding was shared.
final class QuranStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: QuranStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // A throwaway suite per test, so these never touch — or are affected by —
        // the real app's defaults.
        suiteName = "QuranStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = QuranStore(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    // MARK: - Reading positions

    /// A fresh install has read nothing, which must read as "no position" rather
    /// than as ayah 0 or a crash.
    func testAFreshStoreHasNoPositions() {
        XCTAssertNil(store.readingPosition(ofSurah: 2))
        XCTAssertEqual(store.readingPositionEntries, [])
    }

    /// The round trip the feature depends on.
    func testAPositionIsRememberedAndReadBack() {
        store.setReadingPosition(ofSurah: 2, ayahNumber: 255)

        XCTAssertEqual(store.readingPosition(ofSurah: 2), 255)
        XCTAssertNil(store.readingPosition(ofSurah: 3), "one surah's position must not become another's")
    }

    /// Surah numbers that are prefixes of each other must not collide — the rule
    /// the shared codec exists to get right, checked again here because this
    /// store is what hands it the strings.
    func testSurahNumbersThatShareAPrefixDoNotCollide() {
        store.setReadingPosition(ofSurah: 11, ayahNumber: 5)

        XCTAssertNil(store.readingPosition(ofSurah: 1))
        XCTAssertEqual(store.readingPosition(ofSurah: 11), 5)
    }

    /// Leaving a surah at its first ayah clears the entry rather than storing it.
    func testReturningToTheFirstAyahClearsTheEntry() {
        store.setReadingPosition(ofSurah: 16, ayahNumber: 40)
        XCTAssertEqual(store.readingPosition(ofSurah: 16), 40)

        store.setReadingPosition(ofSurah: 16, ayahNumber: 1)

        XCTAssertNil(store.readingPosition(ofSurah: 16))
        XCTAssertEqual(store.readingPositionEntries, [], "nothing should be left behind")
    }

    /// A surah holds at most one entry, however much it is read.
    func testASurahHoldsAtMostOneEntry() {
        for ayah in 2...30 {
            store.setReadingPosition(ofSurah: 16, ayahNumber: Int32(ayah))
        }

        XCTAssertEqual(store.readingPositionEntries.count, 1)
        XCTAssertEqual(store.readingPosition(ofSurah: 16), 30)
    }

    /// The store hands its strings to the shared rule rather than parsing them
    /// itself: a damaged entry is reported as absent, exactly as Android does.
    func testADamagedReadingPositionEntryIsTreatedAsAbsent() {
        defaults.set(["16", "16:", "16:x"], forKey: QuranStore.Key.readingPositions)

        XCTAssertNil(store.readingPosition(ofSurah: 16))
    }

    // MARK: - Storage shape (the Android contract)

    /// Every key and value shape, asserted against the literals the Android app
    /// uses. This is the test that would fail if the two stores drifted apart.
    func testItWritesTheAndroidKeysAndShapes() {
        store.setReadingPosition(ofSurah: 2, ayahNumber: 255)
        store.toggleBookmark(surahNumber: 2, ayahNumber: 255)
        store.toggleStar(surahNumber: 2)

        XCTAssertEqual(QuranStore.Key.readingPositions, "reading_positions")
        XCTAssertEqual(QuranStore.Key.bookmarkedVerses, "bookmarked_verses")
        XCTAssertEqual(QuranStore.Key.bookmarkedSurahs, "bookmarked_surahs")

        XCTAssertEqual(defaults.stringArray(forKey: "reading_positions"), ["2:255"])
        XCTAssertEqual(defaults.stringArray(forKey: "bookmarked_verses"), ["2:255"])
        XCTAssertEqual(defaults.stringArray(forKey: "bookmarked_surahs"), ["2"])
    }

    /// A key written by the Android app resolves here — the cross-platform case
    /// the shared codec exists for.
    func testItReadsKeysWrittenByTheAndroidApp() {
        defaults.set(["2:255", "36:68"], forKey: QuranStore.Key.bookmarkedVerses)
        defaults.set(["2", "36"], forKey: QuranStore.Key.bookmarkedSurahs)

        XCTAssertTrue(store.isBookmarked(surahNumber: 2, ayahNumber: 255))
        XCTAssertTrue(store.isBookmarked(surahNumber: 36, ayahNumber: 68))
        XCTAssertEqual(store.starredSurahs, [2, 36])
    }

    // MARK: - Bookmarked verses

    func testABookmarkIsToggledOnAndOff() {
        XCTAssertFalse(store.isBookmarked(surahNumber: 2, ayahNumber: 255))

        XCTAssertTrue(store.toggleBookmark(surahNumber: 2, ayahNumber: 255), "the first toggle adds it")
        XCTAssertTrue(store.isBookmarked(surahNumber: 2, ayahNumber: 255))

        XCTAssertFalse(store.toggleBookmark(surahNumber: 2, ayahNumber: 255), "the second removes it")
        XCTAssertFalse(store.isBookmarked(surahNumber: 2, ayahNumber: 255))
        XCTAssertEqual(store.bookmarkedVerseKeys, [])
    }

    func testBookmarksArePerVerse() {
        store.toggleBookmark(surahNumber: 2, ayahNumber: 255)

        XCTAssertTrue(store.isBookmarked(surahNumber: 2, ayahNumber: 255))
        XCTAssertFalse(store.isBookmarked(surahNumber: 2, ayahNumber: 256), "a neighbouring ayah is not bookmarked")
        XCTAssertFalse(store.isBookmarked(surahNumber: 3, ayahNumber: 255), "the same ayah number in another surah is not bookmarked")
    }

    func testRemovingABookmarkThatIsNotThereDoesNothing() {
        store.toggleBookmark(surahNumber: 2, ayahNumber: 255)

        store.removeBookmark(surahNumber: 9, ayahNumber: 1)

        XCTAssertEqual(store.bookmarkedVerseKeys, ["2:255"], "the other bookmark must be untouched")
    }

    // MARK: - Starred surahs

    func testASurahStarIsToggledOnAndOff() {
        XCTAssertFalse(store.isStarred(surahNumber: 36))

        XCTAssertTrue(store.toggleStar(surahNumber: 36))
        XCTAssertTrue(store.isStarred(surahNumber: 36))

        XCTAssertFalse(store.toggleStar(surahNumber: 36))
        XCTAssertFalse(store.isStarred(surahNumber: 36))
    }

    /// Stars come back in Quran order however they were added, so no writer has
    /// to remember to sort.
    func testStarredSurahsAreSortedOnRead() {
        store.toggleStar(surahNumber: 36)
        store.toggleStar(surahNumber: 2)
        store.toggleStar(surahNumber: 114)

        XCTAssertEqual(store.starredSurahs, [2, 36, 114])
    }

    /// Starring a surah must not put an entry in the verse bookmarks: `"2:255"`
    /// and `"2"` are different intents, and one collection holding both would show
    /// a verse nobody bookmarked.
    func testStarsAndVerseBookmarksAreSeparate() {
        store.toggleStar(surahNumber: 2)

        XCTAssertEqual(store.bookmarkedVerseKeys, [], "starring a surah must not add a verse bookmark")
        XCTAssertEqual(store.starredSurahEntries, ["2"])
    }

    // MARK: - Persistence

    /// A second store over the same defaults sees everything the first wrote —
    /// which is what "survives a relaunch" means at this level.
    func testEverythingSurvivesANewStoreInstance() {
        store.setReadingPosition(ofSurah: 36, ayahNumber: 68)
        store.toggleBookmark(surahNumber: 36, ayahNumber: 68)
        store.toggleStar(surahNumber: 36)

        let reopened = QuranStore(defaults: UserDefaults(suiteName: suiteName)!)

        XCTAssertEqual(reopened.readingPosition(ofSurah: 36), 68)
        XCTAssertTrue(reopened.isBookmarked(surahNumber: 36, ayahNumber: 68))
        XCTAssertEqual(reopened.starredSurahs, [36])
    }
}

/// Tests for the reader's use of the store, at the store's boundary.
final class SurahReaderBookmarkTests: XCTestCase {

    @MainActor
    func testTheReaderPublishesAndTogglesBookmarks() async throws {
        let (cache, store) = try makeEnv()
        let model = SurahReaderModel(
            surah: SurahSummary(number: 1, name: "Al-Faatiha", translation: "The Opening", ayahCount: 7),
            repository: QuranRepository(cache: cache, fetcher: UnreachableFetcher()),
            store: store
        )
        await model.load()

        XCTAssertFalse(model.isBookmarked(ayahNumber: 3))

        model.toggleBookmark(ayahNumber: 3)

        XCTAssertTrue(model.isBookmarked(ayahNumber: 3), "the row must repaint as bookmarked")
        XCTAssertTrue(store.isBookmarked(surahNumber: 1, ayahNumber: 3), "and the store must have it")
        XCTAssertFalse(model.isBookmarked(ayahNumber: 4), "only the tapped ayah")

        model.toggleBookmark(ayahNumber: 3)
        XCTAssertFalse(model.isBookmarked(ayahNumber: 3))
    }

    /// A bookmark made in an earlier session shows as bookmarked on open — the
    /// row state is read from the store, not assumed empty.
    @MainActor
    func testTheReaderShowsBookmarksSavedEarlier() async throws {
        let (cache, store) = try makeEnv()
        store.toggleBookmark(surahNumber: 1, ayahNumber: 5)

        let model = SurahReaderModel(
            surah: SurahSummary(number: 1, name: "Al-Faatiha", translation: "The Opening", ayahCount: 7),
            repository: QuranRepository(cache: cache, fetcher: UnreachableFetcher()),
            store: store
        )
        await model.load()

        XCTAssertTrue(model.isBookmarked(ayahNumber: 5))
        XCTAssertFalse(model.isBookmarked(ayahNumber: 6))
    }

    @MainActor
    func testTheSurahStarIsToggledAndPublished() async throws {
        let (cache, store) = try makeEnv()
        let model = SurahReaderModel(
            surah: SurahSummary(number: 1, name: "Al-Faatiha", translation: "The Opening", ayahCount: 7),
            repository: QuranRepository(cache: cache, fetcher: UnreachableFetcher()),
            store: store
        )
        await model.load()
        XCTAssertFalse(model.isStarred)

        model.toggleStar()

        XCTAssertTrue(model.isStarred)
        XCTAssertEqual(store.starredSurahs, [1])
    }

    /// `openAt` wins over the saved reading position — arriving from the
    /// bookmarks list means "take me to this verse", not "take me to wherever I
    /// stopped", and those are different intents.
    @MainActor
    func testOpenAtOverridesTheSavedReadingPosition() async throws {
        let (cache, store) = try makeEnv()
        store.setReadingPosition(ofSurah: 1, ayahNumber: 2)

        let model = SurahReaderModel(
            surah: SurahSummary(number: 1, name: "Al-Faatiha", translation: "The Opening", ayahCount: 7),
            repository: QuranRepository(cache: cache, fetcher: UnreachableFetcher()),
            store: store,
            openAt: 6
        )
        await model.load()

        XCTAssertEqual(model.restorePosition, 6, "the requested verse must win")
    }

    /// ...and with no explicit target, the saved position is still used.
    @MainActor
    func testWithoutAnExplicitTargetTheSavedPositionIsUsed() async throws {
        let (cache, store) = try makeEnv()
        store.setReadingPosition(ofSurah: 1, ayahNumber: 2)

        let model = SurahReaderModel(
            surah: SurahSummary(number: 1, name: "Al-Faatiha", translation: "The Opening", ayahCount: 7),
            repository: QuranRepository(cache: cache, fetcher: UnreachableFetcher()),
            store: store
        )
        await model.load()

        XCTAssertEqual(model.restorePosition, 2)
    }

    // MARK: - Helpers

    @MainActor
    private func makeEnv() throws -> (QuranCache, QuranStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SurahReaderBookmarkTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "SurahReaderBookmarkTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        let cache = QuranCache(directory: directory)
        let rows = (1...7)
            .map { #"{"chapter":1,"verse":\#($0),"text":"verse \#($0)"}"# }
            .joined(separator: ",")
        try cache.write(.english, json: #"{"quran":[\#(rows)]}"#)
        return (cache, QuranStore(defaults: defaults))
    }
}

private struct UnreachableFetcher: QuranEditionFetching {
    func fetch(_ edition: QuranEdition) async throws -> String {
        throw URLError(.cannotConnectToHost)
    }
}

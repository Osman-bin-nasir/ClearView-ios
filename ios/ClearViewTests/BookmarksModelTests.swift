import XCTest
@testable import ClearView
import SharedKotlin

/// Tests for the bookmarks screen's model: which saves are listed, in what
/// order, and what happens to a save that no longer resolves.
///
/// These run the real repository over a fake fetcher and the real shared Kotlin
/// parser, so the resolution path is the same one the app uses — the only thing
/// replaced is the network.
@MainActor
final class BookmarksModelTests: XCTestCase {

    private var directory: URL!
    private var cache: QuranCache!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: QuranStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarksModelTests-\(UUID().uuidString)", isDirectory: true)
        cache = QuranCache(directory: directory)

        suiteName = "BookmarksModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = QuranStore(defaults: defaults)

        // Two surahs, so cross-surah ordering is testable rather than assumed.
        // Surah 1 has 7 ayahs, surah 2 has 3.
        let rows = (1...7).map { (1, $0, "faatiha \($0)") } + (1...3).map { (2, $0, "baqara \($0)") }
        try cache.write(.english, json: edition(rows))
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    private func makeModel() -> BookmarksModel {
        BookmarksModel(repository: QuranRepository(cache: cache, fetcher: UnreachableFetcher()), store: store)
    }

    private func readyState(of model: BookmarksModel) -> ([SurahSummary], [BookmarksModel.BookmarkedVerse])? {
        guard case .ready(let starred, let verses) = model.state else { return nil }
        return (starred, verses)
    }

    /// Nothing saved is an empty screen, not a failure or a spinner.
    func testNothingSavedIsAnEmptyReadyState() async throws {
        let model = makeModel()

        await model.reload()

        let state = try XCTUnwrap(readyState(of: model))
        XCTAssertTrue(state.0.isEmpty)
        XCTAssertTrue(state.1.isEmpty)
    }

    /// Bookmarked verses come back in Quran order — surah, then ayah — whatever
    /// order they were saved in. The same order the Android repository sorts to,
    /// so the two platforms list the same saves in the same sequence.
    func testBookmarkedVersesAreListedInQuranOrder() async throws {
        // Saved deliberately out of order.
        store.toggleBookmark(surahNumber: 2, ayahNumber: 3)
        store.toggleBookmark(surahNumber: 1, ayahNumber: 5)
        store.toggleBookmark(surahNumber: 1, ayahNumber: 2)
        let model = makeModel()

        await model.reload()

        let verses = try XCTUnwrap(readyState(of: model)).1
        XCTAssertEqual(verses.map(\.id), ["1:2", "1:5", "2:3"])
        XCTAssertEqual(verses.map(\.surah.number), [1, 1, 2])
    }

    /// The row needs the verse text, resolved from the edition rather than
    /// reconstructed from the stored key.
    func testEachRowCarriesItsVerseTextAndSurah() async throws {
        store.toggleBookmark(surahNumber: 2, ayahNumber: 2)
        let model = makeModel()

        await model.reload()

        let verse = try XCTUnwrap(readyState(of: model)).1.first
        XCTAssertEqual(verse?.text, "baqara 2")
        XCTAssertEqual(verse?.surah.name, "Al-Baqara")
        XCTAssertEqual(verse?.surah.translation, "The Cow")
    }

    /// Starred surahs are listed in Quran order too, resolved to full rows.
    func testStarredSurahsAreListedInQuranOrder() async throws {
        store.toggleStar(surahNumber: 2)
        store.toggleStar(surahNumber: 1)
        let model = makeModel()

        await model.reload()

        let starred = try XCTUnwrap(readyState(of: model)).0
        XCTAssertEqual(starred.map(\.number), [1, 2])
        XCTAssertEqual(starred.map(\.name), ["Al-Faatiha", "Al-Baqara"])
    }

    /// A bookmark that names a verse the edition does not contain is dropped
    /// rather than rendered as a row with no text. This is why the list is
    /// resolved against the edition instead of rebuilt from the keys.
    func testABookmarkForAVerseNotInTheEditionIsDropped() async throws {
        store.toggleBookmark(surahNumber: 1, ayahNumber: 2)   // real
        store.toggleBookmark(surahNumber: 1, ayahNumber: 99)  // surah 1 has 7
        store.toggleBookmark(surahNumber: 114, ayahNumber: 1) // surah not in this edition
        let model = makeModel()

        await model.reload()

        let verses = try XCTUnwrap(readyState(of: model)).1
        XCTAssertEqual(verses.map(\.id), ["1:2"], "only the resolvable bookmark should be listed")
    }

    /// One damaged stored key drops that key and nothing else — the list must not
    /// fail because a single entry is unreadable.
    func testADamagedKeyIsDroppedWithoutFailingTheList() async throws {
        defaults.set(["1:2", "nonsense", "1:", ""], forKey: QuranStore.Key.bookmarkedVerses)
        let model = makeModel()

        await model.reload()

        let verses = try XCTUnwrap(readyState(of: model)).1
        XCTAssertEqual(verses.map(\.id), ["1:2"])
    }

    /// The cross-platform case the shared codec exists for: keys written by the
    /// Android app resolve here.
    func testKeysWrittenByTheAndroidAppResolve() async throws {
        defaults.set(["2:1", "1:7"], forKey: QuranStore.Key.bookmarkedVerses)
        let model = makeModel()

        await model.reload()

        let verses = try XCTUnwrap(readyState(of: model)).1
        XCTAssertEqual(verses.map(\.id), ["1:7", "2:1"])
    }

    /// Removing from the list unbookmarks and refreshes, so the row disappears
    /// and the store agrees.
    func testRemovingAVerseUnbookmarksItAndRefreshes() async throws {
        store.toggleBookmark(surahNumber: 1, ayahNumber: 4)
        let model = makeModel()
        await model.reload()
        let verse = try XCTUnwrap(try XCTUnwrap(readyState(of: model)).1.first)

        await model.remove(verse)

        XCTAssertEqual(try XCTUnwrap(readyState(of: model)).1.count, 0)
        XCTAssertFalse(store.isBookmarked(surahNumber: 1, ayahNumber: 4), "the store must agree with the list")
    }

    /// Reloading picks up a save made elsewhere — the reason this screen reloads
    /// on every appearance rather than loading once.
    func testReloadPicksUpASaveMadeAfterTheFirstLoad() async throws {
        let model = makeModel()
        await model.reload()
        XCTAssertEqual(try XCTUnwrap(readyState(of: model)).1.count, 0)

        // As if the reader had bookmarked a verse and the user came back.
        store.toggleBookmark(surahNumber: 2, ayahNumber: 1)
        await model.reload()

        XCTAssertEqual(try XCTUnwrap(readyState(of: model)).1.map(\.id), ["2:1"])
    }

    /// Stars and verse bookmarks are separate lists, so starring a surah does not
    /// add a verse row for it.
    func testStarsDoNotAppearAsBookmarkedVerses() async throws {
        store.toggleStar(surahNumber: 2)
        let model = makeModel()

        await model.reload()

        let state = try XCTUnwrap(readyState(of: model))
        XCTAssertEqual(state.0.map(\.number), [2])
        XCTAssertTrue(state.1.isEmpty)
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

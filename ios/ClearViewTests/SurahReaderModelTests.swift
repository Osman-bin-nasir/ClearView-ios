import XCTest
@testable import ClearView
import SharedKotlin

/// Tests for the reading screen's model: what it renders once a surah is open,
/// and what happens when the Arabic edition is missing.
///
/// These run the real `QuranRepository` (over a fake fetcher) and the real shared
/// Kotlin parser, so they cover the whole path a tap on a surah row takes:
/// open → load verses → join the Arabic → publish rows.
@MainActor
final class SurahReaderModelTests: XCTestCase {

    private var directory: URL!
    private var cache: QuranCache!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SurahReaderModelTests-\(UUID().uuidString)", isDirectory: true)
        cache = QuranCache(directory: directory)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    /// The happy path: each ayah carries its English text, its Arabic text and
    /// its position.
    func testPublishesAyahsWithArabicJoinedIn() async throws {
        try cache.write(.english, json: edition([(1, 1, "In the name of Allah"), (1, 2, "All praise")]))
        try cache.write(.arabic, json: edition([(1, 1, "بِسۡمِ"), (1, 2, "الۡحَمۡدُ")]))

        let model = SurahReaderModel(
            surah: SurahSummary(number: 1, name: "Al-Faatiha", translation: "The Opening", ayahCount: 7),
            repository: QuranRepository(cache: cache, fetcher: FakeFetcher())
        )

        await model.load()

        guard case .ready(let ayahs) = model.state else {
            return XCTFail("expected .ready, got \(model.state)")
        }
        XCTAssertEqual(ayahs.count, 2)
        XCTAssertEqual(ayahs.map(\.id), [1, 2])
        XCTAssertEqual(ayahs[0].verse.text, "In the name of Allah")
        XCTAssertEqual(ayahs[0].arabic, "بِسۡمِ")
        XCTAssertEqual(ayahs[1].arabic, "الۡحَمۡدُ")
    }

    /// With no Arabic edition, the reader still opens and shows the English.
    /// The Arabic is supplementary, so its absence must not be an error state —
    /// which is why each row carries `arabic: ""` rather than the load failing.
    func testMissingArabicDegradesToEnglishOnly() async throws {
        try cache.write(.english, json: edition([(1, 1, "In the name of Allah")]))
        // The Arabic fetch fails, and only the English is cached.

        let model = SurahReaderModel(
            surah: SurahSummary(number: 1, name: "Al-Faatiha", translation: "The Opening", ayahCount: 7),
            repository: QuranRepository(cache: cache, fetcher: FakeFetcher())
        )

        await model.load()

        guard case .ready(let ayahs) = model.state else {
            return XCTFail("expected .ready, got \(model.state)")
        }
        XCTAssertEqual(ayahs.count, 1)
        XCTAssertEqual(ayahs[0].arabic, "")
        XCTAssertEqual(ayahs[0].verse.text, "In the name of Allah")
    }

    /// The reader is given the list's repository, so opening a second surah
    /// reuses the edition already in memory instead of re-downloading it. On a
    /// slow connection this is the difference between instant and a wait.
    func testReaderReusesTheRepositoryAlreadyLoaded() async throws {
        let fetcher = FakeFetcher([.english: edition([(1, 1, "a"), (2, 1, "b")])])
        let repository = QuranRepository(cache: cache, fetcher: fetcher)

        // The list loads first, as it would in the app.
        _ = try await repository.surahs()

        let model = SurahReaderModel(
            surah: SurahSummary(number: 2, name: "Al-Baqara", translation: "The Cow", ayahCount: 1),
            repository: repository
        )
        await model.load()

        guard case .ready(let ayahs) = model.state else {
            return XCTFail("expected .ready, got \(model.state)")
        }
        XCTAssertEqual(ayahs.map { $0.verse.text }, ["b"])
        let requests = await fetcher.requests
        XCTAssertEqual(requests.filter { $0 == .english }.count, 1, "the edition must not be re-downloaded")
    }

    /// A failure has to reach the user as a message, not as an empty screen.
    func testFailureSurfacesAMessage() async throws {
        let model = SurahReaderModel(
            surah: SurahSummary(number: 1, name: "Al-Faatiha", translation: "The Opening", ayahCount: 7),
            repository: QuranRepository(cache: cache, fetcher: FakeFetcher())
        )

        await model.load()

        guard case .failed(let message) = model.state else {
            return XCTFail("expected .failed, got \(model.state)")
        }
        XCTAssertEqual(message, "Couldn't reach the network to download the Quran.")
    }

    /// Opening the same surah twice (SwiftUI re-running `.task`) must not load
    /// twice; the model is created per screen, so this guards the `.task`
    /// contract rather than the repository's cache.
    func testLoadIsIdempotent() async throws {
        try cache.write(.english, json: edition([(1, 1, "a")]))
        let model = SurahReaderModel(
            surah: SurahSummary(number: 1, name: "Al-Faatiha", translation: "The Opening", ayahCount: 7),
            repository: QuranRepository(cache: cache, fetcher: FakeFetcher())
        )

        await model.load()
        await model.load()

        guard case .ready(let ayahs) = model.state else {
            return XCTFail("expected .ready, got \(model.state)")
        }
        XCTAssertEqual(ayahs.count, 1)
    }

    /// The surah's own ayah count is what the header shows, and it comes from
    /// the parsed edition — not from a table that could disagree with the text.
    func testHeaderReflectsTheParsedEdition() async throws {
        try cache.write(.english, json: edition((1...7).map { (1, $0, "verse \($0)") }))
        let repository = QuranRepository(cache: cache, fetcher: FakeFetcher())

        let surahs = try await repository.surahs()
        XCTAssertEqual(surahs.first?.ayahCount, 7)

        let model = SurahReaderModel(surah: surahs[0], repository: repository)
        await model.load()

        guard case .ready(let ayahs) = model.state else {
            return XCTFail("expected .ready, got \(model.state)")
        }
        XCTAssertEqual(ayahs.count, model.surah.ayahCount, "the header count must match the verses rendered")
    }

    // MARK: - The basmala

    /// The line above the first verse is the edition's own Al-Faatiha 1:1.
    ///
    /// Taken from the text rather than typed here, because the basmala is the one
    /// line of a surah that is not a numbered ayah and a hand-typed copy would
    /// re-decide its harakat and its waqf mark — which is exactly how the app ends
    /// up disagreeing with the scripture it prints underneath it.
    func testTheBasmalaComesFromTheEditionsOwnAlFaatiha() async throws {
        try cache.write(.english, json: edition([(2, 1, "Alif Lam Meem"), (2, 2, "This is the Book")]))
        try cache.write(.arabic, json: edition([(1, 1, "بِسْمِ ٱللَّهِ"), (2, 1, "الٓمٓ"), (2, 2, "ذَٰلِكَ")]))

        let model = SurahReaderModel(
            surah: SurahSummary(number: 2, name: "Al-Baqara", translation: "The Cow", ayahCount: 2),
            repository: QuranRepository(cache: cache, fetcher: FakeFetcher())
        )

        await model.load()

        XCTAssertEqual(model.basmala, "بِسْمِ ٱللَّهِ")
    }

    /// At-Tawba is the one surah that opens without it.
    ///
    /// The Arabic edition is present and does contain a 1:1, so a blank head here
    /// is the rule being applied rather than the text being missing — which is the
    /// distinction a test that only checked for "blank" could not make.
    func testAtTawbaOpensWithoutTheBasmala() async throws {
        try cache.write(.english, json: edition([(9, 1, "A declaration from Allah")]))
        try cache.write(.arabic, json: edition([(1, 1, "بِسْمِ ٱللَّهِ"), (9, 1, "بَرَآءَةٌ")]))

        let model = SurahReaderModel(
            surah: SurahSummary(number: 9, name: "At-Tawba", translation: "The Repentance", ayahCount: 1),
            repository: QuranRepository(cache: cache, fetcher: FakeFetcher())
        )

        await model.load()

        XCTAssertEqual(model.basmala, "")
        guard case .ready(let ayahs) = model.state else {
            return XCTFail("expected .ready, got \(model.state)")
        }
        XCTAssertEqual(ayahs.map(\.arabic), ["بَرَآءَةٌ"], "the verses still render")
    }

    /// With no Arabic edition the head is blank rather than invented — a missing
    /// line is better than a fabricated one, and the reader still opens in English.
    func testTheBasmalaIsBlankWhenTheArabicIsNotOnTheDevice() async throws {
        try cache.write(.english, json: edition([(2, 1, "Alif Lam Meem")]))

        let model = SurahReaderModel(
            surah: SurahSummary(number: 2, name: "Al-Baqara", translation: "The Cow", ayahCount: 1),
            repository: QuranRepository(cache: cache, fetcher: FakeFetcher())
        )

        await model.load()

        XCTAssertEqual(model.basmala, "")
        guard case .ready(let ayahs) = model.state else {
            return XCTFail("expected .ready, got \(model.state)")
        }
        XCTAssertEqual(ayahs.map(\.arabic), [""])
    }

    func testReaderSearchMatchesBothLanguagesAndVerseReferencesWithoutLosingTheSurah() async throws {
        try cache.write(.english, json: edition([(1, 1, "In the name of Allah"), (1, 2, "All praise")]))
        try cache.write(.arabic, json: edition([(1, 1, "بِسْمِ اللَّهِ"), (1, 2, "الْحَمْدُ")]))
        let model = SurahReaderModel(
            surah: SurahSummary(number: 1, name: "Al-Faatiha", translation: "The Opening", ayahCount: 7),
            repository: QuranRepository(cache: cache, fetcher: FakeFetcher())
        )
        await model.load()
        model.search = "بسم"
        XCTAssertEqual(model.filteredAyahs.map(\.id), [1], "Arabic search ignores vocalization marks")
        model.search = "PRAISE"
        XCTAssertEqual(model.filteredAyahs.map(\.id), [2])
        model.search = "1:2"
        XCTAssertEqual(model.filteredAyahs.map(\.id), [2])
        model.search = "missing"
        XCTAssertTrue(model.filteredAyahs.isEmpty)
        model.search = ""
        XCTAssertEqual(model.filteredAyahs.map(\.id), [1, 2])
        XCTAssertEqual(model.ayahs.count, 2)
    }

    func testCopyUsesTheSelectedLanguageAndIncludesTheVerseReference() async throws {
        try cache.write(.english, json: edition([(1, 1, "In the name of Allah")]))
        try cache.write(.arabic, json: edition([(1, 1, "بِسْمِ اللَّهِ")]))
        let model = SurahReaderModel(
            surah: SurahSummary(number: 1, name: "Al-Faatiha", translation: "The Opening", ayahCount: 7),
            repository: QuranRepository(cache: cache, fetcher: FakeFetcher())
        )
        await model.load()
        let ayah = try XCTUnwrap(model.ayahs.first)
        XCTAssertEqual(model.copyText(for: ayah), "بِسْمِ اللَّهِ\n— Al-Faatiha 1:1")
        model.language.toggle()
        XCTAssertEqual(model.copyText(for: ayah), "In the name of Allah\n— Al-Faatiha 1:1")
        model.language.toggle()
        let missingArabic = SurahReaderModel.Ayah(verse: ayah.verse, arabic: "")
        XCTAssertEqual(model.copyText(for: missingArabic), "In the name of Allah\n— Al-Faatiha 1:1")
    }

    func testTextSizeSliderPersistsAndClampsItsValue() {
        let suite = "ReaderSliderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = QuranStore(defaults: defaults)
        let model = SurahReaderModel(
            surah: SurahSummary(number: 1, name: "Al-Faatiha", translation: "The Opening", ayahCount: 7),
            repository: QuranRepository(cache: cache, fetcher: FakeFetcher()), store: store
        )
        model.setArabicTextScale(1.35)
        XCTAssertEqual(model.arabicTextScale, 1.35, accuracy: 0.0001)
        XCTAssertEqual(store.arabicTextScale, 1.35, accuracy: 0.0001)
        model.setArabicTextScale(10)
        XCTAssertEqual(model.arabicTextScale, QuranStore.arabicTextScaleRange.upperBound)
        XCTAssertFalse(model.canIncreaseArabicScale)
        model.setArabicTextScale(0)
        XCTAssertEqual(model.arabicTextScale, QuranStore.arabicTextScaleRange.lowerBound)
        XCTAssertFalse(model.canDecreaseArabicScale)
    }

    // MARK: - Helpers

    private func edition(_ ayahs: [(surah: Int, ayah: Int, text: String)]) -> String {
        let rows = ayahs
            .map { #"{"chapter":\#($0.surah),"verse":\#($0.ayah),"text":"\#($0.text)"}"# }
            .joined(separator: ",")
        return #"{"quran":[\#(rows)]}"#
    }
}

// MARK: - Fakes

private actor FakeFetcher: QuranEditionFetching {
    private(set) var requests: [QuranEdition] = []
    private let responses: [QuranEdition: String]

    init(_ responses: [QuranEdition: String] = [:]) {
        self.responses = responses
    }

    func fetch(_ edition: QuranEdition) async throws -> String {
        requests.append(edition)
        guard let body = responses[edition] else { throw URLError(.cannotConnectToHost) }
        return body
    }
}

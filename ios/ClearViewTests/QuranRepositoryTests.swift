import XCTest
@testable import ClearView
import SharedKotlin

/// Tests for the iOS half of the Quran slice: the download, the cache, and the
/// join between the shared Kotlin parser and the screens.
///
/// The network is the only non-deterministic part of this feature, so it is
/// behind `QuranEditionFetching` and faked here. What is *not* faked is the
/// parsing: every test goes through the real `QuranJsonParser` in the shared
/// Kotlin module, because the point of these tests is the seam between Swift and
/// Kotlin — cache policy, actor isolation, and the shape of the parsed result —
/// and faking that seam would test nothing.
final class QuranRepositoryTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuranRepositoryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: - Cache policy

    func testSearchMatchesWordsReferencesAndArabicFromCache() async throws {
        let cache = QuranCache(directory: directory)
        try cache.write(.english, json: edition([(2, 255, "Allah is ever living"), (2, 256, "No compulsion"), (3, 255, "Another verse")]))
        try cache.write(.arabic, json: edition([(2, 255, "اللّٰهُ"), (2, 256, "لَا إِكۡرَاهَ")]))
        let repository = QuranRepository(cache: cache, fetcher: FakeFetcher())
        let word = try await repository.searchVerses("LIVING")
        XCTAssertEqual(word.map(\.ayahNumber), [255])
        XCTAssertEqual(word.first?.arabicText, "اللّٰهُ")
        for reference in ["2:255", "2.255", "2 255"] {
            let result = try await repository.searchVerses(reference)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result.first?.surahNumber, 2)
        }
        let arabic = try await repository.searchVerses("اللّٰهُ")
        XCTAssertEqual(arabic.count, 1)
        let numeric = try await repository.searchVerses("255")
        XCTAssertEqual(numeric.count, 2)
        let empty = try await repository.searchVerses("  ")
        XCTAssertTrue(empty.isEmpty)
        let limited = try await repository.searchVerses("2", limit: 1)
        XCTAssertEqual(limited.count, 1)
    }

    /// A cached edition must be used with no network at all — that is the whole
    /// point of caching it. The fake throws if it is even asked.
    func testUsesCachedEditionWithoutTouchingTheNetwork() async throws {
        let cache = QuranCache(directory: directory)
        try cache.write(.english, json: edition([(65, 1, "One"), (65, 2, "Two"), (66, 1, "Three")]))

        let fetcher = FakeFetcher()  // no responses configured: any fetch fails
        let repository = QuranRepository(cache: cache, fetcher: fetcher)

        let surahs = try await repository.surahs()

        XCTAssertEqual(surahs.map(\.number), [65, 66])
        let requests = await fetcher.requests
        XCTAssertTrue(requests.isEmpty, "a cached edition must not be re-downloaded")
    }

    /// The first run downloads, parses, and leaves a usable cache behind.
    func testDownloadsAndCachesOnAFreshInstall() async throws {
        let cache = QuranCache(directory: directory)
        let fetcher = FakeFetcher([.english: edition([(1, 1, "Alif"), (1, 2, "Lam")])])
        let repository = QuranRepository(cache: cache, fetcher: fetcher)

        XCTAssertFalse(cache.isCached(.english), "nothing should be cached before the first load")

        let surahs = try await repository.surahs()

        XCTAssertEqual(surahs, [SurahSummary(number: 1, name: "Al-Faatiha", translation: "The Opening", ayahCount: 2)])
        XCTAssertTrue(cache.isCached(.english), "the download must be persisted for offline use")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.fileURL(for: .english).path))
    }

    /// A truncated or corrupt file must be re-downloaded, not trusted. This is
    /// the failure mode that would otherwise leave the reader permanently empty,
    /// because "the file exists" is true and parsing is the only thing that
    /// catches it.
    func testCorruptCacheIsRedownloadedInsteadOfTrusted() async throws {
        let cache = QuranCache(directory: directory)
        try cache.write(.english, json: #"{"quran":[{"chapter":65,"verse":1,"tex"#)  // truncated

        let fetcher = FakeFetcher([.english: edition([(36, 68, "Yaseen")])])
        let repository = QuranRepository(cache: cache, fetcher: fetcher)

        let surahs = try await repository.surahs()

        XCTAssertEqual(surahs.map(\.name), ["Yaseen"])
        let requests = await fetcher.requests
        // The English edition had to be re-fetched. Its Arabic counterpart is
        // *also* requested here, which is correct — English succeeded, so the
        // supplementary edition is attempted next.
        XCTAssertTrue(requests.contains(.english), "a corrupt cache must trigger a re-download")
        XCTAssertEqual(requests.filter { $0 == .english }.count, 1)
    }

    /// A payload that parses but holds nothing is a failure, not a success, and
    /// it must not be cached: caching it would make every later launch read a
    /// file that parses to an empty list and never retry.
    func testEmptyEditionIsRejectedAndNotCached() async throws {
        let cache = QuranCache(directory: directory)
        let fetcher = FakeFetcher([.english: #"{"quran":[]}"#])
        let repository = QuranRepository(cache: cache, fetcher: fetcher)

        do {
            _ = try await repository.surahs()
            XCTFail("an edition with no verses must not load")
        } catch let error as QuranRepositoryError {
            guard case .emptyEdition(.english) = error else {
                return XCTFail("expected .emptyEdition, got \(error)")
            }
        }

        XCTAssertFalse(cache.isCached(.english), "an unusable payload must not be cached")
    }

    /// An HTML error page served with HTTP 200, or any other non-JSON body, must
    /// surface as a typed error rather than crash or render as "no surahs".
    func testUnparseableBodyReportsCorruptCache() async throws {
        let cache = QuranCache(directory: directory)
        let fetcher = FakeFetcher([.english: "<!DOCTYPE html><h1>404</h1>"])
        let repository = QuranRepository(cache: cache, fetcher: fetcher)

        do {
            _ = try await repository.surahs()
            XCTFail("a non-JSON body must not load")
        } catch let error as QuranRepositoryError {
            guard case .corruptCache(.english) = error else {
                return XCTFail("expected .corruptCache, got \(error)")
            }
        }
        XCTAssertFalse(cache.isCached(.english))
    }

    /// A transport failure — offline, DNS, TLS — is reported as a download
    /// failure with no HTTP status, which is what lets the UI say "couldn't
    /// reach the network" rather than inventing an HTTP code.
    func testTransportFailureIsReportedAsDownloadFailure() async throws {
        let cache = QuranCache(directory: directory)
        let fetcher = ThrowingFetcher(error: URLError(.notConnectedToInternet))
        let repository = QuranRepository(cache: cache, fetcher: fetcher)

        do {
            _ = try await repository.surahs()
            XCTFail("offline must not succeed")
        } catch let error as QuranRepositoryError {
            guard case .downloadFailed(.english, status: -1) = error else {
                return XCTFail("expected .downloadFailed with no status, got \(error)")
            }
            XCTAssertEqual(error.errorDescription, "Couldn't reach the network to download the Quran.")
        }
    }

    // MARK: - Parsed shape

    /// The list is in Quran order with derived ayah counts — no hardcoded table.
    func testSurahListIsOrderedWithDerivedAyahCounts() async throws {
        let cache = QuranCache(directory: directory)
        try cache.write(
            .english,
            json: edition([
                (2, 1, "a"), (2, 2, "b"), (2, 3, "c"),
                (3, 1, "d"),
                (4, 1, "e"), (4, 2, "f"),
            ])
        )
        let repository = QuranRepository(cache: cache, fetcher: FakeFetcher())

        let surahs = try await repository.surahs()

        XCTAssertEqual(surahs.map(\.number), [2, 3, 4])
        XCTAssertEqual(surahs.map(\.ayahCount), [3, 1, 2])
        XCTAssertEqual(surahs[0].name, "Al-Baqara")
        XCTAssertEqual(surahs[0].translation, "The Cow")
        XCTAssertEqual(surahs[0].displayName, "2. Al-Baqara")
        // Identifiable id is the surah number, which is what the list keys on.
        XCTAssertEqual(surahs.map(\.id), [2, 3, 4])
    }

    /// Reading one surah returns only that surah's verses, in order.
    func testVersesOfOneSurahAreIsolatedAndOrdered() async throws {
        let cache = QuranCache(directory: directory)
        try cache.write(.english, json: edition([(36, 1, "Ya"), (36, 2, "Seen"), (37, 1, "Other")]))
        let repository = QuranRepository(cache: cache, fetcher: FakeFetcher())

        let verses = try await repository.verses(inSurah: 36)

        XCTAssertEqual(verses.count, 2)
        XCTAssertEqual(verses.map(\.ayahNumber), [1, 2])
        XCTAssertEqual(verses.map(\.text), ["Ya", "Seen"])
        XCTAssertEqual(verses[0].surahName, "Yaseen")
    }

    /// The Arabic edition is joined in per surah, keyed by ayah number, so the
    /// reader can render it beside the English.
    func testArabicIsJoinedPerSurah() async throws {
        let cache = QuranCache(directory: directory)
        try cache.write(.english, json: edition([(2, 255, "Ayat al-Kursi"), (2, 256, "No compulsion")]))
        try cache.write(
            .arabic,
            json: edition([(2, 255, "اللّٰهُ"), (2, 256, "لَا إِكۡرَاهَ"), (99, 1, "unrelated")])
        )
        let repository = QuranRepository(cache: cache, fetcher: FakeFetcher())

        _ = try await repository.surahs()
        let arabic = await repository.arabicTexts(inSurah: 2)

        XCTAssertEqual(arabic.count, 2)
        XCTAssertEqual(arabic[255], "اللّٰهُ")
        XCTAssertEqual(arabic[256], "لَا إِكۡرَاهَ")
        let hasArabic = await repository.hasArabic
        XCTAssertTrue(hasArabic)
    }

    /// Arabic is supplementary: if it cannot be fetched, the English edition
    /// still loads and the reader simply shows no Arabic line. Failing the whole
    /// tab over the optional edition would be the wrong trade.
    func testArabicFailureDoesNotBlockTheEnglishEdition() async throws {
        let cache = QuranCache(directory: directory)
        let fetcher = FakeFetcher([.english: edition([(1, 1, "Alif")])])  // arabic unconfigured → fails
        let repository = QuranRepository(cache: cache, fetcher: fetcher)

        let surahs = try await repository.surahs()

        XCTAssertEqual(surahs.map(\.number), [1])
        let hasArabic = await repository.hasArabic
        XCTAssertFalse(hasArabic)
        XCTAssertTrue(cache.isCached(.english))
        XCTAssertFalse(cache.isCached(.arabic), "a failed Arabic download must not leave a cache file")
    }

    /// The parsed edition is held in memory, so moving between surahs — and
    /// returning to the list — does not re-parse the file or re-download it.
    func testParsedEditionIsHeldInMemory() async throws {
        let cache = QuranCache(directory: directory)
        let fetcher = FakeFetcher([.english: edition([(1, 1, "Alif"), (2, 1, "Ba")])])
        let repository = QuranRepository(cache: cache, fetcher: fetcher)

        _ = try await repository.surahs()
        _ = try await repository.verses(inSurah: 1)
        _ = try await repository.surahs()

        let requests = await fetcher.requests
        XCTAssertEqual(requests.filter { $0 == .english }.count, 1, "the English edition must be fetched exactly once")
    }

    /// Two editions, two cache files. A shared file name would mean the Arabic
    /// download silently overwrites the English one.
    func testEditionsHaveDistinctCacheFiles() {
        XCTAssertNotEqual(
            QuranEdition.english.cacheFileName,
            QuranEdition.arabic.cacheFileName
        )
        XCTAssertNotEqual(QuranEdition.english.url, QuranEdition.arabic.url)
        XCTAssertTrue(QuranEdition.english.url.absoluteString.hasSuffix("eng-mustafakhattaba.json"))
        XCTAssertTrue(QuranEdition.arabic.url.absoluteString.hasSuffix("ara-quranindopak.json"))
    }

    // MARK: - Live network

    /// The real end-to-end path: URLSession → jsDelivr → the shared parser.
    ///
    /// Opt-in, because a test suite that needs the internet is a test suite that
    /// fails on a plane. Run it deliberately with
    /// `CLEARVIEW_LIVE_QURAN_TESTS=1` and it proves the real CDN URLs, the real
    /// payload shape and the real full-size parse, which the fixtures above
    /// cannot (they are deliberately tiny).
    func testLiveDownloadOfBothEditions() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CLEARVIEW_LIVE_QURAN_TESTS"] == "1",
            "set CLEARVIEW_LIVE_QURAN_TESTS=1 to run the live download test"
        )

        let cache = QuranCache(directory: directory)
        let repository = QuranRepository(cache: cache, fetcher: QuranHttpFetcher())

        let surahs = try await repository.surahs()
        XCTAssertEqual(surahs.count, 114, "the full edition must yield all 114 surahs")
        XCTAssertEqual(surahs.map(\.number), Array(1...114))
        XCTAssertEqual(surahs[0].name, "Al-Faatiha")
        XCTAssertEqual(surahs[0].ayahCount, 7)
        XCTAssertEqual(surahs[1].ayahCount, 286)
        XCTAssertEqual(surahs[113].name, "An-Naas")
        // 6236 ayahs is the canonical count: a partial download would show fewer.
        XCTAssertEqual(surahs.reduce(0) { $0 + $1.ayahCount }, 6236)

        let fatiha = try await repository.verses(inSurah: 1)
        XCTAssertEqual(fatiha.count, 7)
        XCTAssertFalse(fatiha[0].text.isEmpty)

        let arabic = await repository.arabicTexts(inSurah: 1)
        XCTAssertEqual(arabic.count, 7, "the IndoPak edition must join in for Al-Faatiha")
        XCTAssertTrue(
            arabic.values.allSatisfy { QuranTextIntegrity.shared.problemWith(text: $0) == nil },
            "every Arabic verse must pass the shared integrity check (no U+FFFD, marks intact)"
        )
    }

    // MARK: - Helpers

    /// Builds an edition body in the real wire shape.
    private func edition(_ ayahs: [(surah: Int, ayah: Int, text: String)]) -> String {
        let rows = ayahs
            .map { #"{"chapter":\#($0.surah),"verse":\#($0.ayah),"text":"\#($0.text)"}"# }
            .joined(separator: ",")
        return #"{"quran":[\#(rows)]}"#
    }
}

// MARK: - Fakes

/// A fetcher that answers from a fixed table and records what was asked for.
///
/// An actor so it is `Sendable` and its request log is safe to inspect after the
/// calls — the same isolation the real fetcher's callers rely on.
private actor FakeFetcher: QuranEditionFetching {

    private(set) var requests: [QuranEdition] = []
    private let responses: [QuranEdition: String]

    init(_ responses: [QuranEdition: String] = [:]) {
        self.responses = responses
    }

    func fetch(_ edition: QuranEdition) async throws -> String {
        requests.append(edition)
        guard let body = responses[edition] else {
            // A missing configuration stands in for an unreachable edition.
            throw URLError(.cannotConnectToHost)
        }
        return body
    }
}

/// A fetcher that always fails — for the offline path.
private struct ThrowingFetcher: QuranEditionFetching {
    let error: Error
    func fetch(_ edition: QuranEdition) async throws -> String { throw error }
}

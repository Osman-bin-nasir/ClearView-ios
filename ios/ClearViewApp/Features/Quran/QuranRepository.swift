import Foundation
import SharedKotlin

/// What went wrong while getting the Quran onto the device.
///
/// A typed error rather than an optional return, which is what the Android
/// repository uses (`null` means "failed"). The reader has to tell the two
/// failures apart to say anything useful to the user: "you are offline" and
/// "the file we downloaded is not usable" need different advice, and a `null`
/// collapses them.
enum QuranRepositoryError: LocalizedError {
    case downloadFailed(QuranEdition, status: Int)
    case emptyEdition(QuranEdition)
    case corruptCache(QuranEdition)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let edition, let status):
            return status > 0
                ? "Couldn't download the Quran (\(edition.rawValue), HTTP \(status))."
                : "Couldn't reach the network to download the Quran."
        case .emptyEdition(let edition):
            return "The downloaded Quran edition (\(edition.rawValue)) contained no verses."
        case .corruptCache(let edition):
            return "The cached Quran edition (\(edition.rawValue)) couldn't be read."
        }
    }
}

/// One of the 114 surahs, as offered on the Quran tab's list.
///
/// Built from the parsed edition rather than from a hardcoded table: the ayah
/// count is counted from the verses that actually downloaded, so the list can
/// never claim "286 ayahs" for a surah the download only partly contains.
struct SurahSummary: Identifiable, Hashable {
    let number: Int
    let name: String
    let translation: String
    let ayahCount: Int

    var id: Int { number }

    /// "36 · Yaseen" — the label the list row shows.
    var displayName: String { "\(number). \(name)" }
}

/// Single entry point for Quran verse data on iOS.
///
/// The same role as the Android `QuranRepository`, and deliberately the same
/// contract: download each edition once, keep it on disk, work offline
/// afterwards, and treat a cache that does not parse as absent. Everything that
/// is *pure* — parsing the JSON, the surah names, the derived ayah counts, the
/// Arabic integrity rules — is delegated to the shared Kotlin module, so this
/// class only owns the platform half: the network call and the file cache.
///
/// An `actor` because its job is to keep one copy of some large parsed data
/// alive across concurrent callers; without isolation a second caller could
/// start a duplicate multi-megabyte download while the first is in flight.
actor QuranRepository {

    private let cache: QuranCache
    private let fetcher: QuranEditionFetching
    private let store: QuranStore

    /// Parsed-in-memory copies, so switching surahs does not re-parse ~2 MB.
    private var verses: [QuranVerse]?
    private var arabicAyahs: [QuranArabicAyah]?

    init(
        cache: QuranCache = .applicationSupport,
        fetcher: QuranEditionFetching = QuranHttpFetcher(),
        store: QuranStore = QuranStore()
    ) {
        self.cache = cache
        self.fetcher = fetcher
        self.store = store
    }

    /// True when the required (English) edition is already on disk.
    func isCached() -> Bool { cache.isCached(.english) }

    /// True when the supplementary Arabic edition is already on disk.
    func isArabicCached() -> Bool { cache.isCached(.arabic) }

    /// Makes the English edition available, downloading it if necessary, and
    /// loads the Arabic one if it is present or can be fetched.
    ///
    /// Mirrors `QuranRepository.ensureEnglishAndArabic`: English is required and
    /// a failure propagates, while Arabic is best-effort — a failure there must
    /// not stop the reader, which is fully usable in English alone.
    @discardableResult
    func ensureCached() async throws -> [QuranVerse] {
        if let loaded = verses { return loaded }

        // A present-but-unparseable file is treated as absent. A truncated
        // download is the common case here (a background fetch killed mid-write
        // on Android's synchronous writer; a partial body on a flaky link), and
        // trusting the file's existence would leave the reader permanently empty
        // with no way back except reinstalling.
        if let onDisk = parseCachedEnglish() {
            verses = onDisk
            loadArabicIfPresent()
            return onDisk
        }

        let json = try await fetch(.english)

        // Parse BEFORE writing: if the payload is not usable, caching it would
        // make the corrupt-cache check above accept it on every later launch.
        let parsed: [QuranVerse]
        do {
            parsed = try QuranJsonParser.shared.parse(raw: json)
        } catch {
            throw QuranRepositoryError.corruptCache(.english)
        }
        guard !parsed.isEmpty else { throw QuranRepositoryError.emptyEdition(.english) }

        try? cache.write(.english, json: json)
        verses = parsed

        await downloadArabicIfNeeded()
        return parsed
    }

    /// The 114 surahs, in order, from the downloaded edition.
    func surahs() async throws -> [SurahSummary] {
        let all = try await ensureCached()

        var summaries: [SurahSummary] = []
        var seen = Set<Int32>()
        // The edition is in Quran order, so first-appearance order is surah
        // order — no sorting step, and no table of 114 surah names to maintain:
        // the name and the ayah count both come from the parsed data.
        for verse in all where seen.insert(verse.surahNumber).inserted {
            summaries.append(
                SurahSummary(
                    number: Int(verse.surahNumber),
                    name: verse.surahName,
                    translation: verse.surahTranslation,
                    ayahCount: Int(verse.totalAyahs)
                )
            )
        }
        return summaries
    }

    /// Every verse of a surah, in order.
    func verses(inSurah surahNumber: Int32) async throws -> [QuranVerse] {
        try await ensureCached().filter { $0.surahNumber == surahNumber }
    }

    /// The Arabic text of one surah, keyed by ayah number; empty when the
    /// Arabic edition is not cached — the reader then shows English only, which
    /// is the documented behaviour rather than an error state.
    ///
    /// A whole surah at a time, in one hop, deliberately: the reader wants all
    /// of them at once, and a per-ayah accessor would cross the actor boundary
    /// once per verse — 286 times for Al-Baqara.
    func arabicTexts(inSurah surahNumber: Int32) -> [Int32: String] {
        guard let arabicAyahs else { return [:] }
        var texts = [Int32: String]()
        for ayah in arabicAyahs where ayah.surahNumber == surahNumber {
            texts[ayah.ayahNumber] = ayah.text
        }
        return texts
    }

    /// True once the Arabic edition is in memory, so a caller can tell "the
    /// Arabic is not with this verse" apart from "the Arabic never loaded".
    var hasArabic: Bool { arabicAyahs != nil }

    // MARK: - The current verse (the reminder)

    /// The verse currently shown as the reminder, or nil before the first pick.
    func currentVerse() -> QuranVerse? { store.currentVerse }

    /// Fills in the surah's ayah count on a stored verse that predates it, and
    /// saves it back so the reader and the reminder show "ayah / total" from then
    /// on. Ported from the Android repository's method of the same name.
    ///
    /// Async because answering it can need the edition — the count is *counted*
    /// from the downloaded text, never hardcoded — and it returns the verse
    /// unchanged when the count is already known or no edition is cached.
    func backfillCurrentVerseTotals() async -> QuranVerse? {
        guard let current = store.currentVerse else { return nil }
        guard current.totalAyahs <= 0 else { return current }
        guard let all = try? await ensureCached(), !all.isEmpty else { return current }

        let total = all.filter { $0.surahNumber == current.surahNumber }.count
        guard total > 0 else { return current }

        let updated = Self.replacing(
            current,
            arabicText: current.arabicText,
            totalAyahs: Int32(total)
        )
        store.saveCurrentVerse(updated)
        return updated
    }

    /// Picks a new verse from the cached edition, saves it as the current one, and
    /// returns it — the Android repository's `pickRandomVerse`.
    ///
    /// - Parameter randomIndex: how a candidate is chosen, given the number of
    ///   verses. Injected so the pick is testable: "avoid repeating the current
    ///   verse" and "a first pick with nothing stored" are behaviours worth
    ///   pinning, and neither is observable through an unseeded random source.
    ///   A default is supplied for production use.
    @discardableResult
    func pickRandomVerse(using randomIndex: (Int) -> Int = { Int.random(in: 0..<$0) }) async throws -> QuranVerse? {
        let all = try await ensureCached()
        guard !all.isEmpty else { return nil }

        var picked = all[clamped(randomIndex(all.count), within: all.count)]

        // Don't show the same verse twice in a row when there is a choice.
        //
        // Compared by POSITION, not by value, and that is a real difference rather
        // than a shortcut: `QuranVerse` is a Kotlin class on the Swift side, so
        // `==` is reference equality and two structurally identical verses would
        // compare as different — the rule would silently never fire.
        var attempts = 0
        while all.count > 1, attempts < 5, let current = store.currentVerse,
              picked.surahNumber == current.surahNumber,
              picked.ayahNumber == current.ayahNumber {
            picked = all[clamped(randomIndex(all.count), within: all.count)]
            attempts += 1
        }

        let enriched = enrich(picked)
        store.saveCurrentVerse(enriched)
        return enriched
    }

    /// The verse [step] positions away in the edition (+1 next, -1 previous),
    /// saved as the current one. Nil at either end of the Quran.
    ///
    /// Whether a neighbour exists is the shared `QuranSequence`'s rule — the
    /// edition is a flat, Quran-ordered list, so stepping over a surah boundary
    /// needs no length table and no special case.
    func adjacentVerse(from surahNumber: Int32, ayahNumber: Int32, step: Int32) async throws -> QuranVerse? {
        let all = try await ensureCached()
        guard let target = QuranSequence.shared.adjacent(
            verses: all,
            surahNumber: surahNumber,
            ayahNumber: ayahNumber,
            step: step
        ) else { return nil }

        let enriched = enrich(target)
        store.saveCurrentVerse(enriched)
        return enriched
    }

    /// Whether stepping [step] from a verse would land anywhere — what a
    /// Previous/Next button is enabled by.
    func hasAdjacentVerse(from surahNumber: Int32, ayahNumber: Int32, step: Int32) async throws -> Bool {
        let all = try await ensureCached()
        return QuranSequence.shared.hasAdjacent(
            verses: all,
            surahNumber: surahNumber,
            ayahNumber: ayahNumber,
            step: step
        )
    }

    /// Attaches the Arabic text when the Arabic edition is cached, and the surah's
    /// ayah count. The reminder is readable in English alone, so a missing Arabic
    /// edition leaves the verse usable rather than failing.
    private func enrich(_ verse: QuranVerse) -> QuranVerse {
        let arabic = verse.arabicText.isEmpty
            ? (arabicTexts(inSurah: verse.surahNumber)[verse.ayahNumber] ?? "")
            : verse.arabicText
        return Self.replacing(verse, arabicText: arabic, totalAyahs: verse.totalAyahs)
    }

    /// A copy of [verse] with two fields replaced.
    ///
    /// An explicit helper because Kotlin data classes arrive in Swift as plain
    /// classes with no `copy` — the generated memberwise initialiser is the only
    /// way to change one field, and spelling it out at each call site is how a
    /// field gets silently dropped.
    private static func replacing(_ verse: QuranVerse, arabicText: String, totalAyahs: Int32) -> QuranVerse {
        QuranVerse(
            surahNumber: verse.surahNumber,
            ayahNumber: verse.ayahNumber,
            surahName: verse.surahName,
            surahTranslation: verse.surahTranslation,
            text: verse.text,
            arabicText: arabicText,
            totalAyahs: totalAyahs
        )
    }

    /// Keeps an index inside the edition. The generator is injected, so it can be
    /// wrong — a test or a future caller passing a bad value must not crash the app
    /// with an out-of-range subscript.
    private func clamped(_ index: Int, within count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    // ── Internals ─────────────────────────────────────────────────────────

    private func fetch(_ edition: QuranEdition) async throws -> String {
        do {
            return try await fetcher.fetch(edition)
        } catch let error as QuranRepositoryError {
            throw error
        } catch {
            // The status is unknown here (a transport error, not an HTTP one),
            // which `downloadFailed(_, status: -1)` reports as "couldn't reach
            // the network" rather than inventing a code.
            throw QuranRepositoryError.downloadFailed(edition, status: -1)
        }
    }

    private func parseCachedEnglish() -> [QuranVerse]? {
        guard cache.isCached(.english), let json = try? cache.read(.english) else { return nil }
        guard let parsed = try? QuranJsonParser.shared.parse(raw: json), !parsed.isEmpty else { return nil }
        return parsed
    }

    private func loadArabicIfPresent() {
        guard arabicAyahs == nil, cache.isCached(.arabic), let json = try? cache.read(.arabic) else { return }
        guard let ayahs = try? QuranJsonParser.shared.parseArabic(raw: json), !ayahs.isEmpty else { return }
        arabicAyahs = ayahs
    }

    private func downloadArabicIfNeeded() async {
        guard arabicAyahs == nil else { return }
        if cache.isCached(.arabic) {
            loadArabicIfPresent()
            return
        }
        guard let json = try? await fetcher.fetch(.arabic) else { return }
        guard let ayahs = try? QuranJsonParser.shared.parseArabic(raw: json), !ayahs.isEmpty else { return }
        try? cache.write(.arabic, json: json)
        arabicAyahs = ayahs
    }
}

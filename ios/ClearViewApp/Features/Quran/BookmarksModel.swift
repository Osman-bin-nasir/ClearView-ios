import Foundation
import Observation
import SharedKotlin

/// Drives the bookmarks screen: the starred surahs and the bookmarked verses.
///
/// Both collections are resolved against the *downloaded edition* rather than
/// reconstructed from the stored keys, so a bookmark that names a verse which is
/// no longer in the cached edition is dropped instead of rendering as a row with
/// no text. That mirrors the Android repository, which resolves bookmarks through
/// its parsed edition for the same reason.
@MainActor
@Observable
final class BookmarksModel {

    /// One bookmarked verse, with the text needed to show why it was saved.
    struct BookmarkedVerse: Identifiable {
        let surah: SurahSummary
        let ayahNumber: Int32
        let text: String

        /// Identified by position, like the reader's rows: an ayah's identity is
        /// where it is, and two verses never share a place.
        var id: String { "\(surah.number):\(ayahNumber)" }
    }

    enum State {
        case loading
        case ready(starred: [SurahSummary], verses: [BookmarkedVerse])
        case failed(String)
    }

    private(set) var state: State = .loading

    let repository: QuranRepository

    private let store: QuranStore

    init(repository: QuranRepository, store: QuranStore = QuranStore()) {
        self.repository = repository
        self.store = store
    }

    /// Reloads every time, unlike the reader's one-shot `load`.
    ///
    /// This screen is a summary of state the reader can change: come back from a
    /// surah having bookmarked a verse and the list must include it. Loading once
    /// would show a stale list for the rest of the session.
    func reload() async {
        state = .loading
        do {
            let surahs = try await repository.surahs()
            let byNumber = Dictionary(uniqueKeysWithValues: surahs.map { ($0.number, $0) })

            // Starred surahs are numbers in the store and need no lookup to be
            // correct — a surah's name comes from the bundled parser — but the
            // row wants the summary, so a number with no matching surah is
            // skipped rather than shown as a blank.
            let starred = store.starredSurahs.compactMap { byNumber[Int($0)] }

            state = .ready(starred: starred, verses: try await bookmarkedVerses(byNumber: byNumber))
        } catch {
            state = .failed(QuranModel.message(for: error))
        }
    }

    /// Resolves the stored keys into verses, in Quran order.
    private func bookmarkedVerses(byNumber: [Int: SurahSummary]) async throws -> [BookmarkedVerse] {
        // Parsed with the shared codec, so a key written by the Android app reads
        // identically — and a damaged entry is one dropped key rather than a
        // failed list.
        let refs = store.bookmarkedVerseKeys.compactMap { QuranVerseKeys.shared.parse(key: $0) }
        guard !refs.isEmpty else { return [] }

        // Grouped by surah so each surah's verses are fetched once, not once per
        // bookmarked ayah — a reader with 20 bookmarks in Al-Baqara would
        // otherwise parse the same 286 verses 20 times.
        var bySurah: [Int32: [Int32]] = [:]
        for ref in refs {
            bySurah[ref.surahNumber, default: []].append(ref.ayahNumber)
        }

        var verses: [BookmarkedVerse] = []
        for (surahNumber, ayahNumbers) in bySurah {
            guard let surah = byNumber[Int(surahNumber)] else { continue }
            let all = try await repository.verses(inSurah: surahNumber)
            let textByAyah = Dictionary(uniqueKeysWithValues: all.map { ($0.ayahNumber, $0.text) })
            for ayahNumber in ayahNumbers {
                guard let text = textByAyah[ayahNumber] else { continue }
                verses.append(BookmarkedVerse(surah: surah, ayahNumber: ayahNumber, text: text))
            }
        }

        // Quran order, matching the Android repository's `compareBy { surah } thenBy { ayah }`
        // so the two platforms list the same bookmarks in the same sequence.
        return verses.sorted {
            $0.surah.number == $1.surah.number
                ? $0.ayahNumber < $1.ayahNumber
                : $0.surah.number < $1.surah.number
        }
    }

    /// Unbookmarks one verse — the counterpart to the reader's per-ayah toggle,
    /// for when the reader is looking at the list rather than the verse.
    func remove(_ verse: BookmarkedVerse) async {
        store.removeBookmark(surahNumber: Int32(verse.surah.number), ayahNumber: verse.ayahNumber)
        await reload()
    }
}

import Foundation
import Observation
import SharedKotlin

/// Drives the Quran tab: fetch, then publish the 114 surahs — or why not.
///
/// `@MainActor` because it feeds SwiftUI directly; the download and the parsing
/// happen inside `QuranRepository`, which is an actor, so nothing heavy runs on
/// the main thread. The three states are modelled explicitly rather than as
/// "optional list + optional error string", because a list, an error and a
/// loading spinner are mutually exclusive and the type should say so.
@MainActor
@Observable
final class QuranModel {

    enum State {
        case loading
        case ready([SurahSummary])
        case failed(String)
    }

    private(set) var state: State = .loading

    /// True once a load attempt has finished — successfully or not. The toolbar's
    /// bookmarks button is disabled until then, because the bookmarks screen
    /// resolves its rows against the downloaded edition and would have nothing to
    /// resolve them with.
    ///
    /// Distinct from the private `hasLoaded` guard, which is about not starting a
    /// second download; this is about whether there is data to show.
    var isReady: Bool {
        if case .loading = state { return false }
        return true
    }

    /// The reminder verse — the one-and-a-bit the Quran tab shows above the list.
    /// Nil until the edition is loaded and a verse has been picked.
    private(set) var currentVerse: QuranVerse?

    /// The surah `currentVerse` belongs to, so tapping the reminder can open the
    /// reader on it. Resolved from the loaded list rather than invented, so it is
    /// only ever a surah the edition actually contains.
    private(set) var currentVerseSurah: SurahSummary?

    /// Why the last pick failed, if it did. Separate from `state`: a reminder that
    /// could not be chosen must not blank out a surah list that loaded fine.
    private(set) var verseError: String?

    /// Whether there is an ayah before / after the one on the card. Drives the
    /// Previous/Next controls, so the reader is never offered a tap that does
    /// nothing — there is no verse before 1:1 or after 114:6.
    private(set) var canGoBackward = false
    private(set) var canGoForward = false

    let repository: QuranRepository

    /// The reader's own state: bookmarks, the Arabic text scale, the Ramadan-style
    /// Islamic-date adjustment and the reminder interval. The same store the
    /// Android hub reads, under the same preference keys.
    private let store = QuranStore()
    private let islamicDateStore = IslamicDateStore()

    /// Whether the copy currently on the page is bookmarked — what the top bar's
    /// bookmark icon draws itself from. Android keeps this on the hub and
    /// refreshes it whenever the verse changes, because a single icon that
    /// disagreed with the list would be the bug a reader notices first.
    private(set) var isBookmarked = false

    /// The reader's scale factor for the Arabic text (1.0 is the default size).
    /// Every Arabic surface reads it, so "make the Quran text bigger" moves them
    /// together and none is left behind.
    private(set) var arabicTextScale: Double = QuranStore.Default.arabicTextScale

    /// The ±1 day adjustment to the calculated Umm al-Qura date.
    private(set) var islamicDateAdjustment = 0

    /// Whether the Listen control is showing. Hidden by default: the headphones
    /// icon in the top bar reveals it, so the verse page stays a reading page
    /// until the reader asks to hear it.
    var showVerseListen = false

    /// The reminder interval, in hours, between automatic new verses — the cadence
    /// the notifications sheet states and the picker in Settings sets.
    private(set) var refreshIntervalHours = QuranStore.Default.refreshIntervalHours

    /// Guards against re-entering the download from `.task` on every redraw —
    /// SwiftUI calls it again whenever the view's identity changes, and a
    /// duplicate call would re-run a 2 MB fetch.
    private var hasLoaded = false

    init(repository: QuranRepository = QuranRepository()) {
        self.repository = repository
        self.arabicTextScale = store.arabicTextScale
        self.islamicDateAdjustment = IslamicDateStore().adjustmentDays
        self.refreshIntervalHours = store.refreshIntervalHours
        self.isBookmarked = false
    }

    // MARK: - The reader's state

    /// Toggles the bookmark on the verse currently shown, and keeps the top-bar
    /// icon honest. Returns the new state so the caller can say what happened.
    @discardableResult
    func toggleBookmark() -> Bool {
        guard let verse = currentVerse else { return false }
        let added = store.toggleBookmark(surahNumber: verse.surahNumber, ayahNumber: verse.ayahNumber)
        isBookmarked = added
        return added
    }

    /// Re-reads the bookmark state for the verse on the page. Called whenever the
    /// verse changes, for the reason the Android hub calls it there: the icon is
    /// about THIS verse, so it has to be re-answered when this verse changes.
    func refreshBookmarkState() {
        guard let verse = currentVerse else {
            isBookmarked = false
            return
        }
        isBookmarked = store.isBookmarked(surahNumber: verse.surahNumber, ayahNumber: verse.ayahNumber)
    }

    /// Sets and persists the Arabic Quran text scale. Clamped by the store, which
    /// is the one place that cannot be forgotten by a future caller.
    func setArabicTextScale(_ scale: Double) {
        store.arabicTextScale = scale
        arabicTextScale = store.arabicTextScale
    }

    /// Sets and persists the ±1 day Islamic-date adjustment.
    func setIslamicDateAdjustment(_ days: Int) {
        islamicDateStore.adjustmentDays = days
        islamicDateAdjustment = islamicDateStore.adjustmentDays
    }

    /// The verse exactly as it should be sent to the clipboard — Android's
    /// `formatVerseForSharing`/`copyVerseToClipboard` pair, which put the Arabic
    /// above the translation and the reference last.
    func clipboardText(for verse: QuranVerse) -> String {
        var parts: [String] = []
        if !verse.arabicText.isEmpty { parts.append(verse.arabicText) }
        parts.append(verse.text)
        parts.append("\(verse.surahName) — Quran \(verse.surahNumber):\(verse.ayahNumber)")
        return parts.joined(separator: "\n\n")
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await reload()
    }

    func retry() async {
        await reload()
    }

    /// Picks a different reminder verse. The card's refresh button, and what a
    /// first-ever load does when nothing has been stored yet.
    func refreshVerse() async {
        do {
            currentVerse = try await repository.pickRandomVerse()
            currentVerseSurah = surahSummary(for: currentVerse)
            verseError = nil
            refreshBookmarkState()
            await refreshStepAvailability()
        } catch {
            verseError = Self.message(for: error)
        }
    }

    /// Moves the reminder one ayah forward (+1) or back (-1) through the Quran.
    ///
    /// Stepping past a surah boundary is the shared `QuranSequence`'s job, and it
    /// is why this needs no special case: the edition is a flat, Quran-ordered
    /// list, so the next ayah after 1:7 is simply 2:1.
    func stepVerse(_ step: Int32) async {
        guard let verse = currentVerse else { return }
        do {
            guard let moved = try await repository.adjacentVerse(
                from: verse.surahNumber,
                ayahNumber: verse.ayahNumber,
                step: step
            ) else { return }
            currentVerse = moved
            currentVerseSurah = surahSummary(for: moved)
            verseError = nil
            refreshBookmarkState()
            await refreshStepAvailability()
        } catch {
            verseError = Self.message(for: error)
        }
    }

    /// Recomputes which directions are available.
    ///
    /// A failure here disables the control rather than reporting an error: the
    /// verse on the card is already loaded, so the edition is demonstrably present
    /// and a throw is not something the reader can act on. "Unknown" therefore
    /// resolves to "not offered", which is the safe direction — the alternative is
    /// a button that looks live and does nothing.
    private func refreshStepAvailability() async {
        guard let verse = currentVerse else {
            canGoBackward = false
            canGoForward = false
            return
        }
        canGoBackward = (try? await repository.hasAdjacentVerse(
            from: verse.surahNumber, ayahNumber: verse.ayahNumber, step: -1
        )) ?? false
        canGoForward = (try? await repository.hasAdjacentVerse(
            from: verse.surahNumber, ayahNumber: verse.ayahNumber, step: 1
        )) ?? false
    }

    private func reload() async {
        state = .loading
        do {
            let surahs = try await repository.surahs()
            state = .ready(surahs)
            await loadVerse(from: surahs)
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// Shows the stored reminder, picking the first one when there is none — the
    /// Android reminder's `MODE_ONLY_IF_MISSING` behaviour.
    private func loadVerse(from surahs: [SurahSummary]) async {
        // Backfilled first: a verse stored by a build that predates the surah
        // counts has no total, and "ayah / total" would render as "3 / 0".
        let stored = await repository.backfillCurrentVerseTotals()
        guard let stored else {
            await refreshVerse()
            return
        }
        currentVerse = stored
        currentVerseSurah = surahSummary(for: stored, in: surahs)
        refreshBookmarkState()
        await refreshStepAvailability()
    }

    private func surahSummary(for verse: QuranVerse?, in surahs: [SurahSummary]? = nil) -> SurahSummary? {
        guard let verse else { return nil }
        if let surahs { return surahs.first { $0.number == Int(verse.surahNumber) } }
        guard case .ready(let loaded) = state else { return nil }
        return loaded.first { $0.number == Int(verse.surahNumber) }
    }

    /// A message worth showing: the repository's own explanation when it has
    /// one ("Couldn't reach the network…"), rather than a generic failure line
    /// that tells the user nothing about whether to retry or find Wi-Fi.
    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

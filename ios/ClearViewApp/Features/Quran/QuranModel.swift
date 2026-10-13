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

    /// Guards against re-entering the download from `.task` on every redraw —
    /// SwiftUI calls it again whenever the view's identity changes, and a
    /// duplicate call would re-run a 2 MB fetch.
    private var hasLoaded = false

    init(repository: QuranRepository = QuranRepository()) {
        self.repository = repository
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

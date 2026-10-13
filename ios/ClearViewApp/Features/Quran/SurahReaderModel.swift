import Foundation
import Observation
import SharedKotlin

/// Drives one surah's reading screen.
///
/// Holds the repository rather than creating one, so opening a surah after the
/// list has already downloaded the edition reuses the parsed copy in memory
/// instead of parsing the cache again — the same reason the Android repository
/// keeps process-wide parsed caches stamped against the file.
@MainActor
@Observable
final class SurahReaderModel {

    /// One ayah, ready to render: the shared `QuranVerse` plus the Arabic text
    /// joined in from the separately cached Arabic edition.
    struct Ayah: Identifiable {
        let verse: QuranVerse
        let arabic: String

        /// Identified by its position, not its text: two ayahs never share a
        /// position, and Kotlin data classes arrive in Swift as reference types
        /// that are not `Hashable`, so the text would not do as a key.
        var id: Int32 { verse.ayahNumber }
    }

    enum State {
        case loading
        case ready([Ayah])
        case failed(String)
    }

    let surah: SurahSummary

    private(set) var state: State = .loading

    /// The ayah the reader should open on — where they left off, or nil to open
    /// at the top. Filled in by [load] rather than at init, so it is read from the
    /// store at the moment the screen appears instead of when it was constructed.
    private(set) var restorePosition: Int32?

    /// The bookmarked verses of this surah, as `"surah:ayah"` keys.
    ///
    /// Held as state rather than asked of the store per row, so a tap repaints
    /// exactly one row and every row agrees with every other — the same reason
    /// the Android `ContentHub` keeps a `bookmarkKeys` list beside its verse.
    private(set) var bookmarkedKeys: Set<String> = []

    private(set) var isStarred = false

    /// The reader's Arabic text scale, read from the store so the reader opens at
    /// the size the reader last chose.
    private(set) var arabicTextScale = QuranStore.Default.arabicTextScale

    private let repository: QuranRepository
    private let store: QuranStore
    private var hasLoaded = false

    /// - Parameter openAt: an explicit ayah to open on, overriding the saved
    ///   reading position. Used when arriving from the bookmarks list, where the
    ///   reader asked for a *specific* verse rather than for wherever they last
    ///   stopped — the two are different intents and only one of them is a
    ///   position.
    init(
        surah: SurahSummary,
        repository: QuranRepository,
        store: QuranStore = QuranStore(),
        openAt: Int32? = nil
    ) {
        self.surah = surah
        self.repository = repository
        self.store = store
        self.openAt = openAt
    }

    private let openAt: Int32?

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        state = .loading

        let surahNumber = Int32(surah.number)
        restorePosition = openAt ?? store.readingPosition(ofSurah: surahNumber)
        bookmarkedKeys = Set(store.bookmarkedVerseKeys)
        isStarred = store.isStarred(surahNumber: surahNumber)
        arabicTextScale = store.arabicTextScale

        do {
            let verses = try await repository.verses(inSurah: surahNumber)
            // The Arabic join is only needed once the English verses are in
            // hand, and it may be absent — the reader then renders the English
            // alone rather than failing, exactly as the Android reader does.
            let arabic = await repository.arabicTexts(inSurah: surahNumber)
            state = .ready(
                verses.map { verse in
                    Ayah(verse: verse, arabic: arabic[verse.ayahNumber] ?? "")
                }
            )
        } catch {
            state = .failed(QuranModel.message(for: error))
        }
    }

    /// Remembers the ayah currently at the top of the page.
    ///
    /// Saving on every change rather than on disappear is deliberate: a screen
    /// that is swiped away, backgrounded, or killed never gets a chance to save,
    /// and "where I stopped" is exactly the state a user notices losing.
    ///
    /// Passing ayah 0 (the header, i.e. the top of the surah) is not filtered out
    /// here — the shared rule already treats anything at or below ayah 1 as
    /// "clear the entry", which is what scrolling back to the top should mean.
    func rememberTopAyah(_ ayahNumber: Int32) {
        store.setReadingPosition(ofSurah: Int32(surah.number), ayahNumber: ayahNumber)
    }

    // MARK: - Bookmarks

    /// True when [ayahNumber] is bookmarked.
    func isBookmarked(ayahNumber: Int32) -> Bool {
        bookmarkedKeys.contains(key(ayahNumber))
    }

    /// Toggles the bookmark on [ayahNumber] and publishes the new state.
    ///
    /// The store is the source of truth and this is the single write path — the
    /// ayah rows and the bookmarks list all read what it wrote, so the two can
    /// never show different answers.
    func toggleBookmark(ayahNumber: Int32) {
        let surahNumber = Int32(surah.number)
        store.toggleBookmark(surahNumber: surahNumber, ayahNumber: ayahNumber)
        bookmarkedKeys = Set(store.bookmarkedVerseKeys)
    }

    // MARK: - Starred surahs

    /// Stars or unstars this whole surah.
    func toggleStar() {
        store.toggleStar(surahNumber: Int32(surah.number))
        isStarred = store.isStarred(surahNumber: Int32(surah.number))
    }

    // MARK: - Arabic text size

    /// How much one tap of the size controls changes the scale.
    private static let scaleStep = 0.2

    var canIncreaseArabicScale: Bool {
        arabicTextScale < QuranStore.arabicTextScaleRange.upperBound - 0.001
    }

    var canDecreaseArabicScale: Bool {
        arabicTextScale > QuranStore.arabicTextScaleRange.lowerBound + 0.001
    }

    func increaseArabicScale() { setArabicTextScale(arabicTextScale + Self.scaleStep) }

    func decreaseArabicScale() { setArabicTextScale(arabicTextScale - Self.scaleStep) }

    /// The store clamps to the allowed range, and this re-reads it rather than
    /// assuming the write was taken as given — so the two can never disagree about
    /// the size on screen.
    private func setArabicTextScale(_ scale: Double) {
        store.arabicTextScale = scale
        arabicTextScale = store.arabicTextScale
    }

    private func key(_ ayahNumber: Int32) -> String {
        QuranVerseKeys.shared.key(surahNumber: Int32(surah.number), ayahNumber: ayahNumber)
    }
}

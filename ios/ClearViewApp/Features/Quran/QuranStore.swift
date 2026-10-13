import Foundation
import SharedKotlin

/// Everything the Quran tab remembers between launches, in `UserDefaults`.
///
/// The iOS counterpart of the Android `QuranStore`, and it stores the *same
/// shapes* under the *same keys* (`reading_positions`, `bookmarked_verses`,
/// `bookmarked_surahs`). That is deliberate: the encoding lives in the shared
/// `QuranReadingPositions` and `QuranVerseKeys`, so both platforms agree on what
/// the strings mean, and a reader moving between them keeps their place and their
/// bookmarks.
///
/// Only the reader's own state is here — positions, bookmarks, stars, the Arabic
/// text scale and the reminder's interval, notification toggle and "changed at"
/// stamp. The downloaded editions are files, not preferences, and live in
/// `QuranCache`.
struct QuranStore {

    /// The Android preference names, kept identical so the two stores are
    /// recognisably the same store.
    enum Key {
        static let readingPositions = "reading_positions"
        static let bookmarkedVerses = "bookmarked_verses"
        static let bookmarkedSurahs = "bookmarked_surahs"
        // The current verse (the reminder), stored field by field rather than as
        // one blob. Same keys and same shape as the Android store, so the verse
        // survives a move between the platforms — and so a widget or notification
        // can read a single field without decoding anything.
        static let currentSurahNumber = "current_surah_number"
        static let currentAyahNumber = "current_ayah_number"
        static let currentSurahName = "current_surah_name"
        static let currentSurahTranslation = "current_surah_translation"
        static let currentVerseText = "current_verse_text"
        static let currentVerseArabic = "current_verse_arabic_text"
        static let currentVerseTotalAyahs = "current_verse_total_ayahs"
        /// When the reminder last changed, in epoch milliseconds. The Android
        /// store's `current_verse_updated_at`, and the input to every "is a new
        /// verse due?" question — which is why it is written by
        /// `saveCurrentVerse` rather than by each caller.
        static let currentVerseUpdatedAt = "current_verse_updated_at"
        static let arabicTextScale = "arabic_text_scale"
        static let refreshIntervalHours = "refresh_interval_hours"
        static let quranNotificationsEnabled = "quran_notifications_enabled"
    }

    /// Defaults, matching the Android store's.
    enum Default {
        static let arabicTextScale = 1.0
        static let refreshIntervalHours = QuranReminder.defaultIntervalHours
        static let notificationsEnabled = true
    }

    /// The bounds the reader's Arabic text is allowed to scale between. Clamped
    /// here rather than at the control, so every writer gets the same guarantee —
    /// a stored 0 would otherwise render the scripture invisible.
    static let arabicTextScaleRange = 0.8...2.0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Where the reader left off

    /// The raw entries. A missing or non-string array reads as empty rather than
    /// throwing — a corrupt store means "no positions", which opens every surah
    /// at its top, and that is a usable app.
    var readingPositionEntries: [String] {
        defaults.stringArray(forKey: Key.readingPositions) ?? []
    }

    /// The ayah last left at the top of [surahNumber], or nil when the surah has
    /// never been read — or was left at its first ayah, which the shared rule
    /// treats as "no position" rather than as a stored one.
    func readingPosition(ofSurah surahNumber: Int32) -> Int32? {
        QuranReadingPositions.shared
            .positionOf(positions: readingPositionEntries, surahNumber: surahNumber)
            // Kotlin's `Int?` arrives boxed, so an absent position is a nil
            // `KotlinInt` and a present one has to be unboxed.
            .map { $0.int32Value }
    }

    /// Remembers the ayah at the top of [surahNumber].
    func setReadingPosition(ofSurah surahNumber: Int32, ayahNumber: Int32) {
        defaults.set(
            QuranReadingPositions.shared.withPosition(
                positions: readingPositionEntries,
                surahNumber: surahNumber,
                ayahNumber: ayahNumber
            ),
            forKey: Key.readingPositions
        )
    }

    // MARK: - Bookmarked verses

    /// The raw `"surah:ayah"` keys.
    var bookmarkedVerseKeys: [String] {
        defaults.stringArray(forKey: Key.bookmarkedVerses) ?? []
    }

    func isBookmarked(surahNumber: Int32, ayahNumber: Int32) -> Bool {
        bookmarkedVerseKeys.contains(Self.key(surahNumber, ayahNumber))
    }

    /// Toggles a verse bookmark. Returns true when it is now bookmarked, which is
    /// what a row needs in order to draw itself.
    @discardableResult
    func toggleBookmark(surahNumber: Int32, ayahNumber: Int32) -> Bool {
        let key = Self.key(surahNumber, ayahNumber)
        var current = bookmarkedVerseKeys
        let added: Bool
        if let index = current.firstIndex(of: key) {
            current.remove(at: index)
            added = false
        } else {
            current.append(key)
            added = true
        }
        defaults.set(current, forKey: Key.bookmarkedVerses)
        return added
    }

    /// Removes a verse bookmark (no-op when it is not bookmarked).
    func removeBookmark(surahNumber: Int32, ayahNumber: Int32) {
        let key = Self.key(surahNumber, ayahNumber)
        var current = bookmarkedVerseKeys
        guard let index = current.firstIndex(of: key) else { return }
        current.remove(at: index)
        defaults.set(current, forKey: Key.bookmarkedVerses)
    }

    // MARK: - Starred surahs

    /// The raw surah numbers, as strings — the Android store's shape.
    var starredSurahEntries: [String] {
        defaults.stringArray(forKey: Key.bookmarkedSurahs) ?? []
    }

    /// Starred surahs in Quran order.
    ///
    /// Sorted on read rather than kept sorted: `UserDefaults` hands back whatever
    /// order it was written in, and the screen wants Quran order every time, so
    /// sorting here means no writer has to remember to. Numbers only, too — a
    /// surah's name and translation come from the bundled parser, so nothing here
    /// can fail or needs waiting for.
    var starredSurahs: [Int32] {
        starredSurahEntries.compactMap { Int32($0) }.sorted()
    }

    func isStarred(surahNumber: Int32) -> Bool {
        starredSurahEntries.contains(String(surahNumber))
    }

    /// Toggles a surah star. Returns true when it is now starred.
    ///
    /// A second collection rather than a flag on the verse keys, which is the
    /// Android store's reasoning and applies here too: `"2:255"` and `"2"` are two
    /// different intents — a passage to come back to, and a whole surah to come
    /// back to — and one collection holding both would make starring a surah show
    /// up in the verse list as an ayah nobody starred.
    @discardableResult
    func toggleStar(surahNumber: Int32) -> Bool {
        let key = String(surahNumber)
        var current = starredSurahEntries
        let added: Bool
        if let index = current.firstIndex(of: key) {
            current.remove(at: index)
            added = false
        } else {
            current.append(key)
            added = true
        }
        defaults.set(current, forKey: Key.bookmarkedSurahs)
        return added
    }

    // MARK: - The current verse (the reminder)

    /// The verse currently shown as the reminder, or nil before the first pick.
    ///
    /// A missing text field reads as "no verse" rather than as an empty one, and a
    /// non-positive position likewise: that is a store written by a build that
    /// never finished picking, and the caller's response is to pick again.
    var currentVerse: QuranVerse? {
        guard let text = defaults.string(forKey: Key.currentVerseText), !text.isEmpty else { return nil }
        let surah = defaults.integer(forKey: Key.currentSurahNumber)
        let ayah = defaults.integer(forKey: Key.currentAyahNumber)
        guard surah > 0, ayah > 0 else { return nil }
        return QuranVerse(
            surahNumber: Int32(surah),
            ayahNumber: Int32(ayah),
            surahName: defaults.string(forKey: Key.currentSurahName) ?? "",
            surahTranslation: defaults.string(forKey: Key.currentSurahTranslation) ?? "",
            text: text,
            arabicText: defaults.string(forKey: Key.currentVerseArabic) ?? "",
            // 0 for a verse persisted before its surah's count was known; the
            // repository fills it in when it next reads the edition.
            totalAyahs: Int32(defaults.integer(forKey: Key.currentVerseTotalAyahs))
        )
    }

    /// Persists [verse] as the reminder, stamping when it changed.
    ///
    /// The stamp is written here, not by callers, because it is the same fact as
    /// "this verse is now the current one" — a caller that forgot it would leave the
    /// reminder reading as hours old the moment it arrived, and the next-launch
    /// check would immediately replace the verse it had just shown.
    func saveCurrentVerse(_ verse: QuranVerse, at now: Date = Date()) {
        defaults.set(Int64(now.timeIntervalSince1970 * 1000), forKey: Key.currentVerseUpdatedAt)
        defaults.set(Int(verse.surahNumber), forKey: Key.currentSurahNumber)
        defaults.set(Int(verse.ayahNumber), forKey: Key.currentAyahNumber)
        defaults.set(verse.surahName, forKey: Key.currentSurahName)
        defaults.set(verse.surahTranslation, forKey: Key.currentSurahTranslation)
        defaults.set(verse.text, forKey: Key.currentVerseText)
        defaults.set(verse.arabicText, forKey: Key.currentVerseArabic)
        defaults.set(Int(verse.totalAyahs), forKey: Key.currentVerseTotalAyahs)
    }

    /// When the reminder verse last changed, or nil when it never has.
    ///
    /// Read back as a `Date` so the reminder rules can be expressed in the units
    /// they reason about; the stored form stays an epoch-millisecond integer, which
    /// is what Android writes and what a widget reading one field expects.
    var currentVerseUpdatedAt: Date? {
        guard defaults.object(forKey: Key.currentVerseUpdatedAt) != nil else { return nil }
        let millis = defaults.object(forKey: Key.currentVerseUpdatedAt) as? Int64 ?? 0
        guard millis > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }

    // MARK: - Reader settings

    /// The interval, in hours, between automatic new verses.
    ///
    /// Coerced on the way in *and* out, unlike the Android store, which stores raw
    /// and lets the UI coerce: a value the app cannot offer must never be what the
    /// schedule runs at, and clamping in the store is the one place that cannot be
    /// forgotten by a future caller. Values outside the offered set fall back to the
    /// default rather than to the nearest option — a stored 2 h cannot be said to
    /// *mean* 1 or 3, and the default is the documented behaviour.
    var refreshIntervalHours: Int {
        get {
            guard defaults.object(forKey: Key.refreshIntervalHours) != nil else {
                return Default.refreshIntervalHours
            }
            return QuranReminder.normalizedInterval(defaults.integer(forKey: Key.refreshIntervalHours))
        }
        nonmutating set {
            defaults.set(QuranReminder.normalizedInterval(newValue), forKey: Key.refreshIntervalHours)
        }
    }

    /// Whether the app posts a notification when a new verse is chosen. Defaults to
    /// on, matching Android — the reminder is the feature, and a silent one that the
    /// user has to open the app to see is the feature switched off.
    var notificationsEnabled: Bool {
        get {
            guard defaults.object(forKey: Key.quranNotificationsEnabled) != nil else {
                return Default.notificationsEnabled
            }
            return defaults.bool(forKey: Key.quranNotificationsEnabled)
        }
        nonmutating set { defaults.set(newValue, forKey: Key.quranNotificationsEnabled) }
    }

    /// The reader's scale factor for the Arabic text (1.0 is the default size).
    ///
    /// The one setting that exists here today, because the reader that applies it
    /// exists today. The reminder's interval and notification toggle are *not*
    /// stored yet: a preference with no screen reading it is a lie in the settings
    /// UI waiting to happen, so those arrive with the notification that consumes
    /// them.
    var arabicTextScale: Double {
        get {
            let stored = defaults.double(forKey: Key.arabicTextScale)
            guard stored > 0 else { return Default.arabicTextScale }
            return min(max(stored, Self.arabicTextScaleRange.lowerBound), Self.arabicTextScaleRange.upperBound)
        }
        nonmutating set {
            let clamped = min(max(newValue, Self.arabicTextScaleRange.lowerBound), Self.arabicTextScaleRange.upperBound)
            defaults.set(clamped, forKey: Key.arabicTextScale)
        }
    }

    // MARK: - Keys

    /// The stored key for a verse, from the shared codec — so iOS writes exactly
    /// what the shared reader reads and what Android writes.
    private static func key(_ surahNumber: Int32, _ ayahNumber: Int32) -> String {
        QuranVerseKeys.shared.key(surahNumber: surahNumber, ayahNumber: ayahNumber)
    }
}

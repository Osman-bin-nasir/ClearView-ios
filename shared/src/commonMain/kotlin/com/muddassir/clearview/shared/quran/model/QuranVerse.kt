package com.muddassir.clearview.shared.quran.model

/**
 * A single Quran verse.
 *
 * Ported verbatim from the Android application
 * (`app/src/main/java/com/muddassir/clearview/quran/model/QuranVerse.kt`) into
 * the shared module. It is plain data with no platform dependency, so it is
 * identical on both platforms by construction — there is no second definition to
 * drift out of step.
 *
 * @property surahNumber  1-based surah number (1..114)
 * @property ayahNumber   Verse number within its surah (1-based)
 * @property surahName    English transliterated surah name, e.g. "At-Talaaq"
 * @property surahTranslation English meaning of the surah name, e.g. "Divorce"
 * @property text         English verse text (The Clear Quran translation)
 * @property arabicText   Arabic verse text (IndoPak script). Empty string when
 *                        the Arabic edition is not cached yet — the surfaces
 *                        still work, they just show English.
 * @property totalAyahs   Number of ayahs in this verse's surah (e.g. 7 for
 *                        Al-Faatiha). Derived from the downloaded edition —
 *                        never hardcoded. 0 when the count isn't known yet.
 */
data class QuranVerse(
    val surahNumber: Int,
    val ayahNumber: Int,
    val surahName: String,
    val surahTranslation: String,
    val text: String,
    val arabicText: String = "",
    val totalAyahs: Int = 0
)

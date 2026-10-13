package com.muddassir.clearview.shared.quran.model

/**
 * One ayah of the Arabic-script edition.
 *
 * The Arabic text is kept in its own type rather than merged into
 * [QuranVerse.arabicText], because the two editions are downloaded and cached
 * independently: English is required and Arabic is supplementary, so an ayah can
 * legitimately exist in one and not the other. The Arabic file is also the
 * larger of the two, and joining it at read time keeps one copy of it instead of
 * copying it into every verse.
 *
 * @property surahNumber 1-based surah number (1..114)
 * @property ayahNumber  verse number within its surah (1-based)
 * @property text        Arabic verse text (IndoPak script)
 */
data class QuranArabicAyah(
    val surahNumber: Int,
    val ayahNumber: Int,
    val text: String
)

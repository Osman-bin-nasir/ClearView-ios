package com.muddassir.clearview.shared.quran.model

/**
 * A reference to one verse by position — the thing a bookmark and a
 * reading-position entry both name.
 *
 * The Android app stores these as the string `"surah:ayah"` (see its
 * `QuranStore`), and so does iOS, which is why the encoding lives in the shared
 * module: two platforms writing the same preference must agree on what the
 * strings mean, or a bookmark saved on one is unreadable on the other.
 */
data class QuranVerseRef(
    val surahNumber: Int,
    val ayahNumber: Int
)

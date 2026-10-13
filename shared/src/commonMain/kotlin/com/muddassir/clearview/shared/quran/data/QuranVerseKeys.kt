package com.muddassir.clearview.shared.quran.data

import com.muddassir.clearview.shared.quran.model.QuranVerseRef

/**
 * The `"surah:ayah"` encoding used by the reader's stored references — the key
 * for a bookmarked verse, and the entry for a reading position.
 *
 * Ported from the Android application, where the format is written inline in
 * three places (`QuranStore.toggleBookmark`, `isBookmarked` and `removeBookmark`,
 * and the two reading-position helpers). It is gathered here because it is no
 * longer one app's private format: iOS writes the same preference, so the
 * encoding needs a single definition both can be tested against rather than a
 * convention each side reimplements.
 *
 * The colon is load-bearing, not decorative: `"11:5"` does not read as surah 1,
 * and surah 1 does not match surah 11's entry.
 */
object QuranVerseKeys {

    /** `"surah:ayah"` — the stored key for a verse. */
    fun key(surahNumber: Int, ayahNumber: Int): String = "$surahNumber:$ayahNumber"

    /**
     * The prefix that every key for [surahNumber] starts with.
     *
     * Exposed alongside [key] so a caller can match a surah's entries by prefix
     * without rebuilding the separator itself — which is how the reading-position
     * rules look a surah up, and the reason they do not parse entries instead
     * (see `QuranReadingPositions.positionOf`).
     */
    fun surahPrefix(surahNumber: Int): String = "$surahNumber:"

    /**
     * The verse [key] names, or null when it does not name one.
     *
     * Deliberately split-and-take-the-first-two rather than "exactly two parts
     * or nothing", because that is what the Android app has always done
     * (`key.split(":").getOrNull(0)`, `getOrNull(1)`): `"2:255:3"` reads as
     * `2:255` there, and a stricter rule here would silently drop a bookmark
     * Android still shows.
     *
     * A key with no ayah (`"2"`), an empty one (`"2:"`), and one with a
     * non-numeric part (`"2:x"`) are all null — reported as "not a reference"
     * rather than as an error, so a single damaged entry cannot fail a whole
     * bookmark list.
     */
    fun parse(key: String): QuranVerseRef? {
        val parts = key.split(":")
        val surah = parts.getOrNull(0)?.toIntOrNull() ?: return null
        val ayah = parts.getOrNull(1)?.toIntOrNull() ?: return null
        return QuranVerseRef(surahNumber = surah, ayahNumber = ayah)
    }
}

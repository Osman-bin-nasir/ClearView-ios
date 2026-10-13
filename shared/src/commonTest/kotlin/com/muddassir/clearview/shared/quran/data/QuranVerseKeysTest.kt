package com.muddassir.clearview.shared.quran.data

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * The `"surah:ayah"` encoding, which is now shared rather than Android-private.
 *
 * The exact strings matter: these are the values Android writes into
 * `bookmarked_verses` and `reading_positions`, so a change here would make every
 * bookmark a reader already has unreadable. The literals below are the Android
 * app's, not invented.
 */
class QuranVerseKeysTest {

    @Test
    fun `a key is surah colon ayah`() {
        assertEquals("2:255", QuranVerseKeys.key(2, 255))
        assertEquals("114:6", QuranVerseKeys.key(114, 6))
        assertEquals("1:1", QuranVerseKeys.key(1, 1))
    }

    @Test
    fun `a key reads back as its verse`() {
        val ref = QuranVerseKeys.parse("2:255")

        assertEquals(2, ref?.surahNumber)
        assertEquals(255, ref?.ayahNumber)
    }

    @Test
    fun `a key round trips`() {
        for (surah in 1..114) {
            val key = QuranVerseKeys.key(surah, 286)
            val ref = QuranVerseKeys.parse(key)
            assertEquals(surah, ref?.surahNumber, "surah $surah must survive the round trip")
            assertEquals(286, ref?.ayahNumber)
        }
    }

    @Test
    fun `the prefix matches only its own surah`() {
        val prefix = QuranVerseKeys.surahPrefix(1)

        assertEquals("1:", prefix)
        assertEquals(true, QuranVerseKeys.key(1, 7).startsWith(prefix))
        // The colon is what stops surah 1 from claiming surah 11's entries.
        assertEquals(false, QuranVerseKeys.key(11, 7).startsWith(prefix))
    }

    @Test
    fun `a key that names no verse is not a reference`() {
        assertNull(QuranVerseKeys.parse(""))
        assertNull(QuranVerseKeys.parse("2"))
        assertNull(QuranVerseKeys.parse("2:"))
        assertNull(QuranVerseKeys.parse("2:x"))
        assertNull(QuranVerseKeys.parse(":255"))
        assertNull(QuranVerseKeys.parse("x:255"))
    }

    @Test
    fun `extra parts are ignored the way the Android store ignores them`() {
        // Android splits and reads the first two parts, so this resolves to 2:255
        // rather than being rejected. Matching it exactly is the point: a
        // stricter iOS rule would drop a bookmark Android still shows.
        val ref = QuranVerseKeys.parse("2:255:3")

        assertEquals(2, ref?.surahNumber)
        assertEquals(255, ref?.ayahNumber)
    }

    @Test
    fun `the reading position helpers use this encoding`() {
        // The two must not drift: a position written through one and matched
        // through the other is how a reader loses their place.
        val written = QuranReadingPositions.withPosition(emptyList(), 16, 40)

        assertEquals(listOf(QuranVerseKeys.key(16, 40)), written)
        assertEquals(
            QuranVerseKeys.parse(QuranVerseKeys.key(16, 40))?.ayahNumber,
            QuranReadingPositions.positionOf(written, 16)
        )
    }
}

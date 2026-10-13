package com.muddassir.clearview.shared.quran.data

import com.muddassir.clearview.shared.quran.model.QuranVerse
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Moving one ayah at a time through the flat, Quran-ordered edition.
 *
 * The rule to pin is that surah boundaries need no special case: the neighbour of
 * an ayah is the next element of the list. The tests below therefore use a
 * deliberately lopsided sample — surah 1 with 2 ayahs, surah 2 with 3 — so that
 * "the end of a surah" and "the start of the next" are both reachable, and so a
 * length table (which this rule must not need) cannot be what makes them pass.
 */
class QuranSequenceTest {

    /** Surah 1 (2 ayahs), surah 2 (3 ayahs), surah 114 (1 ayah at the end). */
    private val verses = listOf(
        verse(1, 1), verse(1, 2),
        verse(2, 1), verse(2, 2), verse(2, 3),
        verse(114, 6)
    )

    private fun verse(surah: Int, ayah: Int) = QuranVerse(
        surahNumber = surah,
        ayahNumber = ayah,
        surahName = QuranJsonParser.surahName(surah),
        surahTranslation = QuranJsonParser.surahTranslation(surah),
        text = "text $surah:$ayah"
    )

    @Test
    fun `an ayah is found in the list`() {
        assertEquals(0, QuranSequence.indexOf(verses, 1, 1))
        assertEquals(2, QuranSequence.indexOf(verses, 2, 1))
        assertEquals(5, QuranSequence.indexOf(verses, 114, 6))
    }

    @Test
    fun `an ayah that is not in the list is not found`() {
        assertEquals(-1, QuranSequence.indexOf(verses, 2, 9))
        assertEquals(-1, QuranSequence.indexOf(verses, 3, 1))
    }

    @Test
    fun `the next ayah inside a surah is the following one`() {
        val next = QuranSequence.adjacent(verses, 2, 1, 1)

        assertEquals("text 2:2", next?.text)
        assertEquals(2, next?.ayahNumber)
    }

    @Test
    fun `the next ayah after the last of a surah is the first of the next`() {
        // No surah-length table is consulted: 1:2 is followed by 2:1 because it is
        // the next element of the edition.
        val next = QuranSequence.adjacent(verses, 1, 2, 1)

        assertEquals(2, next?.surahNumber)
        assertEquals(1, next?.ayahNumber)
    }

    @Test
    fun `the previous ayah before the first of a surah is the last of the previous`() {
        val previous = QuranSequence.adjacent(verses, 2, 1, -1)

        assertEquals(1, previous?.surahNumber)
        assertEquals(2, previous?.ayahNumber)
    }

    @Test
    fun `there is nothing before the first ayah of the Quran`() {
        assertNull(QuranSequence.adjacent(verses, 1, 1, -1))
        assertFalse(QuranSequence.hasAdjacent(verses, 1, 1, -1))
        // ...but there is something after it.
        assertTrue(QuranSequence.hasAdjacent(verses, 1, 1, 1))
    }

    @Test
    fun `there is nothing after the last ayah of the Quran`() {
        assertNull(QuranSequence.adjacent(verses, 114, 6, 1))
        assertFalse(QuranSequence.hasAdjacent(verses, 114, 6, 1))
        // ...but there is something before it.
        assertTrue(QuranSequence.hasAdjacent(verses, 114, 6, -1))
    }

    @Test
    fun `an unknown starting verse has no neighbour`() {
        // Not an error: a reader whose position no longer resolves is shown
        // disabled buttons rather than sent somewhere wrong.
        assertNull(QuranSequence.adjacent(verses, 9, 9, 1))
        assertFalse(QuranSequence.hasAdjacent(verses, 9, 9, 1))
    }

    @Test
    fun `an empty edition has no neighbours rather than a crash`() {
        assertNull(QuranSequence.adjacent(emptyList(), 1, 1, 1))
        assertFalse(QuranSequence.hasAdjacent(emptyList(), 1, 1, 1))
    }

    @Test
    fun `walking forward reaches the end and no further`() {
        // The property the reader relies on: stepping forward repeatedly visits
        // every ayah exactly once, in order, then stops.
        var current = verses.first()
        var visited = 1
        while (true) {
            val next = QuranSequence.adjacent(verses, current.surahNumber, current.ayahNumber, 1)
                ?: break
            // Each step is exactly the next element of the ordered edition.
            assertEquals(visited, QuranSequence.indexOf(verses, next.surahNumber, next.ayahNumber))
            current = next
            visited++
        }
        assertEquals(verses.size, visited)
        assertEquals(114, current.surahNumber)
        assertEquals(6, current.ayahNumber)
    }

    @Test
    fun `a step larger than one lands further along`() {
        val third = QuranSequence.adjacent(verses, 1, 1, 3)

        assertEquals(2, third?.surahNumber)
        assertEquals(2, third?.ayahNumber)
    }

    @Test
    fun `a step of zero is the verse itself`() {
        val same = QuranSequence.adjacent(verses, 2, 3, 0)

        assertEquals("text 2:3", same?.text)
    }
}

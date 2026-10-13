package com.muddassir.clearview.shared.quran.data

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * The reading-position rules, ported from the Android test
 * (`app/src/test/java/com/muddassir/clearview/quran/data/QuranReadingPositionTest.kt`)
 * with JUnit's `org.junit.Assert` replaced by multiplatform `kotlin.test`. Same
 * assertions — they are the contract, not a rewrite of it.
 *
 * Two rules are worth pinning, and neither is visible in a screenshot. The first
 * is that ayah 1 CLEARS the entry instead of storing it: a stored "16:1" means the
 * same thing, so it would have to be read on every open to find out whether the
 * reader had been there or never opened the surah at all — and the answer decides
 * whether the page scrolls. The second is that a surah holds at most ONE entry,
 * which is what lets the reader resolve a position with a single scan rather than
 * sorting entries by age.
 */
class QuranReadingPositionsTest {

    @Test
    fun `a position is read back for its own surah`() {
        val positions = listOf("2:255", "16:40")

        assertEquals(255, QuranReadingPositions.positionOf(positions, 2))
        assertEquals(40, QuranReadingPositions.positionOf(positions, 16))
        assertNull(QuranReadingPositions.positionOf(positions, 3))
    }

    @Test
    fun `a surah number that is a prefix of another does not collide`() {
        val positions = listOf("11:5")

        // Surah 1 must not find surah 11's position. The colon is what stops it.
        assertNull(QuranReadingPositions.positionOf(positions, 1))
        assertEquals(5, QuranReadingPositions.positionOf(positions, 11))
    }

    @Test
    fun `a damaged entry is not a position`() {
        assertNull(QuranReadingPositions.positionOf(listOf("16"), 16))
        assertNull(QuranReadingPositions.positionOf(listOf("16:"), 16))
        assertNull(QuranReadingPositions.positionOf(listOf("16:x"), 16))
    }

    @Test
    fun `a surah holds at most one position`() {
        val after = QuranReadingPositions.withPosition(listOf("16:40"), 16, 55)

        assertEquals(listOf("16:55"), after)
    }

    @Test
    fun `writing a position leaves every other surah alone`() {
        val before = listOf("2:255", "16:40")

        assertEquals(
            listOf("2:255", "16:41"),
            QuranReadingPositions.withPosition(before, 16, 41)
        )
    }

    @Test
    fun `returning to the first ayah clears the entry`() {
        val before = listOf("2:255", "16:40")

        assertEquals(listOf("2:255"), QuranReadingPositions.withPosition(before, 16, 1))
        // A nonsense ayah clears too: the reader is at the top either way, and an
        // entry saying otherwise would send them somewhere that does not exist.
        assertEquals(listOf("2:255"), QuranReadingPositions.withPosition(before, 16, 0))
        // Nothing to clear, and nothing added.
        assertEquals(
            listOf("2:255"),
            QuranReadingPositions.withPosition(listOf("2:255"), 16, 1)
        )
    }

    @Test
    fun `writing does not mutate the list it was handed`() {
        val before = listOf("2:255", "16:40")

        QuranReadingPositions.withPosition(before, 16, 99)

        // The caller hands over the collection its platform store is holding;
        // editing it in place would be writing to their instance behind their back.
        assertEquals(listOf("2:255", "16:40"), before)
    }

    @Test
    fun `a position survives a round trip`() {
        // The rule the feature actually depends on: what the reader writes is
        // what the reader reads back, for every surah with a scrollable length.
        var positions = emptyList<String>()
        for (surah in 1..114) {
            positions = QuranReadingPositions.withPosition(positions, surah, surah * 2 + 1)
        }
        for (surah in 1..114) {
            assertEquals(surah * 2 + 1, QuranReadingPositions.positionOf(positions, surah))
        }
        // ...and the store never grew past one entry per surah.
        assertEquals(114, positions.size)
    }
}

package com.muddassir.clearview.shared.quran.data

import com.muddassir.clearview.shared.quran.model.QuranVerse

/**
 * Moving through the Quran one ayah at a time.
 *
 * Ported from the Android repository's `getAdjacentVerse` / `hasAdjacentVerse`
 * (`app/src/main/java/com/muddassir/clearview/quran/data/QuranRepository.kt`),
 * with the IO stripped off. What is left is the rule, and it is worth sharing for
 * one reason: the edition is a **flat, Quran-ordered list**, so an ayah's
 * neighbour is simply the next element. That is what makes surah boundaries fall
 * out for free — the ayah after 1:7 is 2:1, the ayah before 2:1 is 1:286 — with no
 * table of surah lengths and no special case at each boundary. Written as a
 * "step within the surah, else next surah" rule instead, it would need both.
 *
 * The two ends are the only genuine edges: there is nothing before 1:1 or after
 * 114:6, and a reader has to be told that rather than left with a dead button.
 */
object QuranSequence {

    /**
     * The index of the verse at (surahNumber, ayahNumber) in [verses], or -1.
     *
     * A linear scan, because the list is ordered and short enough (6 236) that
     * the reader's single lookup per tap is not worth indexing for.
     */
    fun indexOf(verses: List<QuranVerse>, surahNumber: Int, ayahNumber: Int): Int {
        for (i in verses.indices) {
            val v = verses[i]
            if (v.surahNumber == surahNumber && v.ayahNumber == ayahNumber) return i
        }
        return -1
    }

    /**
     * The verse [step] positions from (surahNumber, ayahNumber) — +1 is the next
     * ayah, -1 the previous — or null when that would fall off either end of the
     * Quran, or when the starting verse is not in [verses].
     */
    fun adjacent(verses: List<QuranVerse>, surahNumber: Int, ayahNumber: Int, step: Int): QuranVerse? {
        if (verses.isEmpty()) return null
        val index = indexOf(verses, surahNumber, ayahNumber)
        if (index < 0) return null
        val target = index + step
        if (target !in verses.indices) return null
        return verses[target]
    }

    /**
     * Whether [adjacent] would find anything — which is what a Previous/Next
     * button is enabled by, so the reader is not offered a tap that does nothing.
     */
    fun hasAdjacent(verses: List<QuranVerse>, surahNumber: Int, ayahNumber: Int, step: Int): Boolean =
        adjacent(verses, surahNumber, ayahNumber, step) != null
}

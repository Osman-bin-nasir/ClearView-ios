package com.muddassir.clearview.shared.quran.data

/**
 * Where the reader left off: one `"surah:ayah"` entry per surah, saying which
 * ayah was at the top of the page.
 *
 * Ported from the Android application
 * (`app/src/main/java/com/muddassir/clearview/quran/data/QuranStore.kt`, where
 * these are the top-level `readingPositionOf` / `withReadingPosition` helpers).
 * They were already written as pure functions — free of `Context`, of prefs and
 * of Android — for the exact reason they can move here: anything in that store
 * that is a RULE rather than a prefs call does not belong next to the prefs call.
 *
 * Grouped into an object rather than left top-level because Kotlin/Native
 * flattens top-level functions into a per-file class (`QuranStoreKt`) that is
 * awkward to reach from Swift, while an object becomes `QuranReadingPositions`.
 *
 * The stored shape is a list of strings rather than a `Set<String>`: the iOS
 * bridge turns a Kotlin `Set` into a `KotlinSet`, which Swift cannot use as a
 * `Set`, whereas `List<String>` arrives as `[String]`. Nothing here needs hashing
 * — a position lookup is a scan over at most 114 entries either way.
 */
object QuranReadingPositions {

    /**
     * The ayah recorded for [surahNumber] in [positions], or null.
     *
     * Matches on the `"16:"` PREFIX rather than by parsing each entry and
     * comparing surah numbers. The two are not the same rule: parsing accepts
     * `"016:5"` and would report a position for surah 16, while the prefix test
     * rejects it — and the prefix test is what the Android app has always done.
     * Matching it exactly matters here for more than tidiness: these entries live
     * in a store that is meant to survive the move between platforms, so a
     * reader's position must resolve identically on both.
     *
     * The colon is load-bearing, not decorative: `"11:5"` does not start with
     * `"1:"`, so surah 1 does not read surah 11's entry.
     */
    fun positionOf(positions: List<String>, surahNumber: Int): Int? {
        val prefix = QuranVerseKeys.surahPrefix(surahNumber)
        for (entry in positions) {
            if (entry.startsWith(prefix)) {
                // A damaged entry ("16", "16:", "16:x") is not a position. It is
                // reported as absent rather than as an error: the reader simply
                // opens the surah at the top.
                return entry.removePrefix(prefix).toIntOrNull()
            }
        }
        return null
    }

    /**
     * [positions] with [surahNumber]'s entry REPLACED by [ayahNumber] — or
     * removed entirely when that ayah is the first one.
     *
     * Two rules, both ported and both deliberate:
     *
     *  - **A surah holds at most one entry.** A position is a single fact about a
     *    surah, so writing a new one replaces the old, and the store holds at most
     *    114 entries however long the app is used.
     *  - **Ayah 1 clears instead of storing.** The first ayah is the top of the
     *    surah, so reopening there needs no scroll; storing it would spell "the
     *    beginning" the same way as "never opened", and the reader would have to
     *    scroll to the top on every open to find out which it was. It is also why
     *    the store stays small — otherwise every reader who scrolled back up would
     *    leave an entry behind.
     *
     * Returns a NEW list instead of editing one: the caller hands over whatever
     * its platform store is holding (on Android, the set SharedPreferences owns),
     * and mutating that in place would be writing to their instance behind their
     * back.
     */
    fun withPosition(positions: List<String>, surahNumber: Int, ayahNumber: Int): List<String> {
        val prefix = QuranVerseKeys.surahPrefix(surahNumber)
        val updated = ArrayList<String>(positions.size + 1)
        for (entry in positions) {
            if (!entry.startsWith(prefix)) updated.add(entry)
        }
        // Ayah <= 1 clears: a nonsense ayah means "the reader is at the top",
        // and an entry claiming otherwise would send them somewhere that does
        // not exist.
        if (ayahNumber > 1) updated.add(QuranVerseKeys.key(surahNumber, ayahNumber))
        return updated
    }
}

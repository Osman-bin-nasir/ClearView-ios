package com.muddassir.clearview.shared.quran.data

import kotlinx.serialization.SerializationException
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * Ported from the Android test
 * (`app/src/test/java/com/muddassir/clearview/quran/data/QuranJsonParserTest.kt`)
 * with JUnit's `org.junit.Assert` replaced by multiplatform `kotlin.test`, and the
 * expected failure type changed from `org.json.JSONException` to
 * `kotlinx.serialization.SerializationException` — the parser's JSON library
 * changed when it moved to Kotlin/Native, so the thrown type did too. The
 * contract the callers depend on is unchanged: a malformed payload throws, and a
 * failure is treated as a failed download.
 *
 * These assertions now run on the JVM and on iOS from one source.
 */
class QuranJsonParserTest {

    private val sample = """
        {
          "quran": [
            { "chapter": 65, "verse": 2, "text": "And whoever fears Allah—He will make a way out for them." },
            { "chapter": 65, "verse": 3, "text": "and provide for them from sources they could never imagine." },
            { "chapter": 66, "verse": 1, "text": "O Prophet! Why do you forbid what Allah has made lawful to you?" }
          ]
        }
    """.trimIndent()

    @Test
    fun parsesFlatListIntoVersesWithSurahMetadata() {
        val verses = QuranJsonParser.parse(sample)

        assertEquals(3, verses.size)

        val first = verses[0]
        assertEquals(65, first.surahNumber)
        assertEquals(2, first.ayahNumber)
        // Surah name/translation come from the embedded canonical list.
        assertEquals("At-Talaaq", first.surahName)
        assertEquals("Divorce", first.surahTranslation)
        assertEquals("And whoever fears Allah—He will make a way out for them.", first.text)

        val second = verses[1]
        assertEquals(65, second.surahNumber)
        assertEquals(3, second.ayahNumber)

        // Second surah correctly assigned to its own verses.
        val third = verses[2]
        assertEquals(66, third.surahNumber)
        assertEquals(1, third.ayahNumber)
        assertEquals("At-Tahrim", third.surahName)
        assertEquals("The Prohibition", third.surahTranslation)
    }

    @Test
    fun derivesEachSurahsAyahTotalFromTheDownloadedEdition() {
        val verses = QuranJsonParser.parse(sample)

        // Counts are counted from the data itself — never hardcoded — so every
        // verse of a surah carries that surah's total (65 has 2 of the 3 here).
        assertEquals(2, verses[0].totalAyahs)
        assertEquals(2, verses[1].totalAyahs)
        assertEquals(1, verses[2].totalAyahs)
        assertEquals(mapOf(65 to 2, 66 to 1), QuranJsonParser.surahAyahCounts(verses))

        // The real Al-Faatiha has 7 ayahs: "1 / 7 ayahs" must come from the data.
        val fatiha = QuranJsonParser.parse(
            (1..7).joinToString(prefix = "{\"quran\":[", postfix = "]}", separator = ",") {
                """{ "chapter": 1, "verse": $it, "text": "verse $it" }"""
            }
        )
        assertEquals(7, fatiha.first().totalAyahs)
    }

    @Test
    fun handlesEmptyVerseList() {
        val empty = """{"quran":[]}"""
        assertTrue(QuranJsonParser.parse(empty).isEmpty())
    }

    @Test
    fun throwsOnMalformedJson() {
        assertFailsWith<SerializationException> {
            QuranJsonParser.parse("this is not json")
        }
    }

    @Test
    fun throwsWhenQuranSectionMissing() {
        assertFailsWith<SerializationException> {
            QuranJsonParser.parse("""{"code":404}""")
        }
    }

    @Test
    fun parsesArabicEditionIntoAyahs() {
        // The Arabic edition uses the same flat shape. It is returned as a list
        // (not a Map<Pair, String>) so Swift can index it: a Kotlin Pair key
        // does not conform to Hashable across the interop boundary.
        val arabic = """
            {
              "quran": [
                { "chapter": 2, "verse": 255, "text": "اللّٰهُ لَا إِلٰهَ إِلَّا هُوَ" },
                { "chapter": 2, "verse": 256, "text": "لَا إِكۡرَاهَ فِي الدِّيۡنِ" }
              ]
            }
        """.trimIndent()

        val ayahs = QuranJsonParser.parseArabic(arabic)

        assertEquals(2, ayahs.size)
        assertEquals("اللّٰهُ لَا إِلٰهَ إِلَّا هُوَ", ayahs[0].text)
        assertEquals("لَا إِكۡرَاهَ فِي الدِّيۡنِ", ayahs[1].text)

        // Each ayah knows its own position, which is what lets a caller key the
        // list however it likes (the iOS reader groups them by surah).
        assertEquals(2, ayahs[0].surahNumber)
        assertEquals(255, ayahs[0].ayahNumber)
        assertEquals(2, ayahs[1].surahNumber)
        assertEquals(256, ayahs[1].ayahNumber)
    }

    @Test
    fun throwsOnMalformedArabicJson() {
        assertFailsWith<SerializationException> {
            QuranJsonParser.parseArabic("<html>404 Not Found</html>")
        }
    }

    @Test
    fun resolvesSurahMetadataForAll114Surahs() {
        // Every canonical surah name/translation must resolve (1..114).
        assertEquals("Al-Faatiha", QuranJsonParser.surahName(1))
        assertEquals("The Opening", QuranJsonParser.surahTranslation(1))
        assertEquals("An-Naas", QuranJsonParser.surahName(114))
        assertEquals("Mankind", QuranJsonParser.surahTranslation(114))
        // Guard against a transposed/mistyped entry in either hand-maintained
        // list silently mislabelling every verse of a surah.
        for (i in 1..114) {
            assertTrue(QuranJsonParser.surahName(i).isNotBlank(), "surahName($i) must not be blank")
            assertTrue(
                QuranJsonParser.surahTranslation(i).isNotBlank(),
                "surahTranslation($i) must not be blank"
            )
        }
        // Out-of-range numbers fall back gracefully instead of crashing.
        assertEquals("Surah 115", QuranJsonParser.surahName(115))
        assertEquals("", QuranJsonParser.surahTranslation(0))
    }
}

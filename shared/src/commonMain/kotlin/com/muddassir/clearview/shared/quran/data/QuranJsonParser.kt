package com.muddassir.clearview.shared.quran.data

import com.muddassir.clearview.shared.quran.model.QuranArabicAyah
import com.muddassir.clearview.shared.quran.model.QuranVerse
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

/**
 * Parses the fawazahmed0/quran-api edition JSON (The Clear Quran English and the
 * IndoPak Arabic script) into verses.
 *
 * Ported from the Android application
 * (`app/src/main/java/com/muddassir/clearview/quran/data/QuranJsonParser.kt`).
 * The parsing *rules* are unchanged; only the JSON library is, because the
 * Android original used `org.json`, which is an Android/JVM artifact with no
 * Kotlin/Native implementation. `kotlinx.serialization` is the multiplatform
 * replacement, so this one implementation serves both platforms.
 *
 * Expected shape:
 * ```
 * { "quran": [ { "chapter": 1, "verse": 1, "text": "In the Name of Allah..." } ] }
 * ```
 * The flat list carries no surah names, so the canonical 114 surah names +
 * translations are resolved from [SURAH_NAMES] / [SURAH_TRANSLATIONS].
 */
object QuranJsonParser {

    /**
     * The wire DTOs. Deliberately private: the public API speaks [QuranVerse], so
     * the JSON shape is an implementation detail that can change without any
     * caller changing. `ignoreUnknownKeys` mirrors `org.json`'s tolerance of
     * fields the parser does not read.
     */
    @Serializable
    private data class EditionDto(val quran: List<AyahDto>)

    @Serializable
    private data class AyahDto(val chapter: Int, val verse: Int, val text: String)

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * @throws kotlinx.serialization.SerializationException if the payload is
     *         malformed (callers treat any thrown failure as a failed download and
     *         retry later — the same contract the Android original had with
     *         `org.json.JSONException`).
     *
     * `@Throws` is load-bearing for iOS, not decoration: Kotlin/Native only
     * bridges an exception into a Swift `throws` when it is declared here.
     * Without it, this call from Swift would not be `try`, and a malformed
     * payload would terminate the app instead of surfacing as an error the
     * caller can handle — a network response is not something to crash over.
     */
    @Throws(SerializationException::class)
    fun parse(raw: String): List<QuranVerse> {
        val edition = json.decodeFromString<EditionDto>(raw)

        val verses = ArrayList<QuranVerse>(6236)
        for (ayah in edition.quran) {
            val surahNumber = ayah.chapter
            verses.add(
                QuranVerse(
                    surahNumber = surahNumber,
                    ayahNumber = ayah.verse,
                    surahName = surahName(surahNumber),
                    surahTranslation = surahTranslation(surahNumber),
                    text = ayah.text
                )
            )
        }
        // Each verse carries its surah's ayah count, counted straight from the
        // downloaded edition (nothing hardcoded), so read views can render
        // "ayah / total ayahs" progress.
        val totals = surahAyahCounts(verses)
        if (totals.isEmpty()) return verses
        return verses.map { v -> v.copy(totalAyahs = totals[v.surahNumber] ?: 0) }
    }

    /**
     * Counts the ayahs of every surah present in [verses], keyed by surah
     * number. Pure + derived from the data, so it also serves the cached-list
     * backfill path in the repository (and stays unit-testable).
     */
    fun surahAyahCounts(verses: List<QuranVerse>): Map<Int, Int> {
        if (verses.isEmpty()) return emptyMap()
        val counts = HashMap<Int, Int>(114)
        for (v in verses) counts[v.surahNumber] = (counts[v.surahNumber] ?: 0) + 1
        return counts
    }

    /**
     * Parses an Arabic-script edition (same flat shape) into its ayahs.
     *
     * Returns a LIST, not a `Map<Pair<Int, Int>, String>`, and that is a
     * deliberate interop decision rather than a style one: Kotlin/Native exports
     * a `Pair` key to Swift as a `KotlinPair` object, which does not conform to
     * `Hashable` — Swift would receive the map and then be unable to index into
     * it. The API would have been unusable from the exact caller that needs it.
     * A typed list bridges cleanly, and each platform builds whatever lookup
     * shape suits it. That is the module's rule throughout: return lists, let
     * the caller key them.
     *
     * @throws kotlinx.serialization.SerializationException if the payload is malformed.
     *         Declared for the same Swift-interop reason as [parse].
     */
    @Throws(SerializationException::class)
    fun parseArabic(raw: String): List<QuranArabicAyah> {
        val edition = json.decodeFromString<EditionDto>(raw)

        return edition.quran.map { ayah ->
            QuranArabicAyah(
                surahNumber = ayah.chapter,
                ayahNumber = ayah.verse,
                text = ayah.text
            )
        }
    }

    /** Canonical English name of surah [number] (1..114), or "Surah N". */
    fun surahName(number: Int): String =
        SURAH_NAMES.getOrNull(number - 1) ?: "Surah $number"

    /** English translation of the surah name (e.g. "The Opening"), or "". */
    fun surahTranslation(number: Int): String =
        SURAH_TRANSLATIONS.getOrNull(number - 1) ?: ""

    private val SURAH_NAMES = listOf(
        "Al-Faatiha", "Al-Baqara", "Aal-i-Imraan", "An-Nisaa", "Al-Maaida",
        "Al-An'aam", "Al-A'raaf", "Al-Anfaal", "At-Tawba", "Yunus",
        "Hud", "Yusuf", "Ar-Ra'd", "Ibrahim", "Al-Hijr",
        "An-Nahl", "Al-Israa", "Al-Kahf", "Maryam", "Taa-Haa",
        "Al-Anbiyaa", "Al-Hajj", "Al-Muminoon", "An-Noor", "Al-Furqaan",
        "Ash-Shu'araa", "An-Naml", "Al-Qasas", "Al-Ankaboot", "Ar-Room",
        "Luqman", "As-Sajda", "Al-Ahzaab", "Saba", "Faatir",
        "Yaseen", "As-Saaffaat", "Saad", "Az-Zumar", "Ghafir",
        "Fussilat", "Ash-Shura", "Az-Zukhruf", "Ad-Dukhaan", "Al-Jaathiya",
        "Al-Ahqaf", "Muhammad", "Al-Fath", "Al-Hujuraat", "Qaaf",
        "Adh-Dhaariyat", "At-Tur", "An-Najm", "Al-Qamar", "Ar-Rahmaan",
        "Al-Waaqia", "Al-Hadid", "Al-Mujaadila", "Al-Hashr", "Al-Mumtahana",
        "As-Saff", "Al-Jumu'a", "Al-Munaafiqoon", "At-Taghaabun", "At-Talaaq",
        "At-Tahrim", "Al-Mulk", "Al-Qalam", "Al-Haaqqa", "Al-Ma'aarij",
        "Nooh", "Al-Jinn", "Al-Muzzammil", "Al-Muddaththir", "Al-Qiyaama",
        "Al-Insaan", "Al-Mursalaat", "An-Naba", "An-Naazi'aat", "Abasa",
        "At-Takwir", "Al-Infitaar", "Al-Mutaffifin", "Al-Inshiqaaq", "Al-Burooj",
        "At-Taariq", "Al-A'laa", "Al-Ghaashiya", "Al-Fajr", "Al-Balad",
        "Ash-Shams", "Al-Lail", "Ad-Dhuhaa", "Ash-Sharh", "At-Tin",
        "Al-Alaq", "Al-Qadr", "Al-Bayyina", "Az-Zalzala", "Al-Aadiyaat",
        "Al-Qaari'a", "At-Takaathur", "Al-Asr", "Al-Humaza", "Al-Fil",
        "Quraish", "Al-Maa'un", "Al-Kawthar", "Al-Kaafiroon", "An-Nasr",
        "Al-Masad", "Al-Ikhlaas", "Al-Falaq", "An-Naas"
    )

    private val SURAH_TRANSLATIONS = listOf(
        "The Opening", "The Cow", "The Family of Imraan", "The Women", "The Table",
        "The Cattle", "The Heights", "The Spoils of War", "The Repentance", "Jonas",
        "Hud", "Joseph", "The Thunder", "Abraham", "The Rock",
        "The Bee", "The Night Journey", "The Cave", "Mary", "Taa-Haa",
        "The Prophets", "The Pilgrimage", "The Believers", "The Light", "The Criterion",
        "The Poets", "The Ant", "The Stories", "The Spider", "The Romans",
        "Luqman", "The Prostration", "The Clans", "Sheba", "The Originator",
        "Yaseen", "Those drawn up in Ranks", "The letter Saad", "The Groups", "The Forgiver",
        "Explained in detail", "Consultation", "Ornaments of gold", "The Smoke", "Crouching",
        "The Dunes", "Muhammad", "The Victory", "The Inner Apartments", "The letter Qaaf",
        "The Winnowing Winds", "The Mount", "The Star", "The Moon", "The Beneficent",
        "The Inevitable", "The Iron", "The Pleading Woman", "The Exile", "She that is to be examined",
        "The Ranks", "Friday", "The Hypocrites", "Mutual Disillusion", "Divorce",
        "The Prohibition", "The Sovereignty", "The Pen", "The Reality", "The Ascending Stairways",
        "Noah", "The Jinn", "The Enshrouded One", "The Cloaked One", "The Resurrection",
        "Man", "The Emissaries", "The Announcement", "Those who drag forth", "He frowned",
        "The Overthrowing", "The Cleaving", "Defrauding", "The Splitting Open", "The Constellations",
        "The Morning Star", "The Most High", "The Overwhelming", "The Dawn", "The City",
        "The Sun", "The Night", "The Morning Hours", "The Consolation", "The Fig",
        "The Clot", "The Power, Fate", "The Evidence", "The Earthquake", "The Chargers",
        "The Calamity", "Competition", "The Declining Day, Epoch", "The Traducer", "The Elephant",
        "Quraysh", "Almsgiving", "Abundance", "The Disbelievers", "Divine Support",
        "The Palm Fibre", "Sincerity", "The Dawn", "Mankind"
    )
}

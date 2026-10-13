package com.muddassir.clearview.shared.quran.data

/**
 * Cheap checks that the Quran Arabic a surface is about to render is still the
 * authoritative text — not a string that some transform quietly ate the harakat
 * out of.
 *
 * Ported from the Android application
 * (`app/src/main/java/com/muddassir/clearview/quran/data/QuranTextIntegrity.kt`)
 * into the shared module. The logic is pure and identical on both platforms; the
 * only change from the Android original is the combining-mark test, which used
 * `java.lang.Character.getType(int)` (a JVM-only API) and now uses Kotlin
 * stdlib's multiplatform [Char.category] — see [isCombiningMark].
 *
 * The Android version's own rationale still applies: the download pipeline does
 * not strip or normalize Arabic, but a check that says so is worth keeping,
 * because a future change that splits a string, lower-cases it, or slices it by
 * code unit could corrupt it silently. These functions are pure and cheap, so
 * they can run in tests without touching production behaviour.
 */
// Public rather than `internal`, which is what this was ported as: Kotlin's
// `internal` is not exported into the iOS framework at all, so the rule would
// have been callable from Android and from these tests but invisible to the
// platform whose Arabic decoding is the newest and least proven. A shared check
// that only half its consumers can call is not shared.
object QuranTextIntegrity {

    /** The Unicode replacement character — the fingerprint of a decoding failure. */
    private const val REPLACEMENT = '\uFFFD'

    /** True when [code] is an Arabic-script letter (the bases a verse is made of). */
    fun isArabicLetter(code: Int): Boolean =
        code in 0x0620..0x064A ||
            code in 0x066E..0x06D3 ||
            code in 0x06EE..0x06EF ||
            code in 0x0750..0x077F ||
            code in 0x08A0..0x08FF ||
            code in 0xFB50..0xFDFF ||
            code in 0xFE70..0xFEFF

    /**
     * True when [code] is a combining mark (zabar, zer, pesh, shadda, sukoon…).
     *
     * The Android original read the Unicode general category from
     * `java.lang.Character.getType`, which does not exist on Kotlin/Native.
     * Kotlin stdlib exposes the same information multiplatform as
     * [Char.category] ([CharCategory]), so the test is expressed on `Char`
     * instead of on an `Int` code point. Every mark this checks for is inside the
     * Basic Multilingual Plane (and `code` comes from `Char.code`, which cannot
     * exceed 0xFFFF), so the conversion loses nothing.
     */
    fun isCombiningMark(code: Int): Boolean = when (Char(code).category) {
        CharCategory.NON_SPACING_MARK,
        CharCategory.COMBINING_SPACING_MARK,
        CharCategory.ENCLOSING_MARK -> true

        else -> false
    }

    /** How many combining marks [text] carries. */
    fun combiningMarkCount(text: String): Int = text.count { isCombiningMark(it.code) }

    /**
     * A problem with [text], or null when it looks like real Quranic Arabic.
     *
     * Flags a decoding failure ([REPLACEMENT]) and a string with no Arabic base
     * letters at all. A blank string is reported as null: "no Arabic yet" is a
     * normal, expected state (an English-only install), not corruption.
     */
    fun problemWith(text: String): String? {
        if (text.isBlank()) return null
        if (text.contains(REPLACEMENT)) return "contains U+FFFD (decoding failure)"
        if (text.none { isArabicLetter(it.code) }) return "no Arabic letters"
        return null
    }

    /**
     * True when [text] has Arabic letters but not a single combining mark.
     *
     * A diacritics-stripping bug looks exactly like this, so it is worth being
     * able to ask. It is NOT treated as an error on its own: some short or
     * non-Quranic Arabic is legitimately unmarked, and refusing to render real
     * text would be a worse failure than the one it guards against.
     */
    fun looksUnmarked(text: String): Boolean =
        text.isNotBlank() &&
            text.any { isArabicLetter(it.code) } &&
            combiningMarkCount(text) == 0
}

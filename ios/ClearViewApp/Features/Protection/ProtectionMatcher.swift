import Foundation

/// One compiled keyword: the value as the user or the preset wrote it, plus the two
/// things matching needs from it.
///
/// Compiled once per rule change rather than per comparison. The Android matcher keeps
/// the same cache for the same reason — the normalisation and the boundary
/// classification are per-keyword, not per-scan, and the scan runs on every feed card.
struct ProtectionKeywordEntry: Equatable, Hashable {
    /// The value to report when this entry matches ("bikini", "pornhub.com").
    let original: String
    /// The normalised form the text is compared against.
    let normalized: String
    /// Whether the match must respect word boundaries (see `isPlainWordKeyword`).
    let needsBoundary: Bool
}

/// The active rule set, as one immutable snapshot.
///
/// Immutable on purpose: the matcher is a pure function of (text, rules), so a scan
/// cannot observe a rule change half-applied, and the whole set can be built once when
/// a setting changes instead of being re-derived for every item on screen.
struct ProtectionRules: Equatable {
    var alwaysBlock: [ProtectionKeywordEntry] = []
    /// Keywords the user blocked **everywhere** (their own list plus the shared rules).
    var userKeywords: [ProtectionKeywordEntry] = []
    /// Keywords that apply to YouTube content only — a term added under YouTube
    /// Protection must never block a website, which is the promise that section makes.
    var youTubeKeywords: [ProtectionKeywordEntry] = []
    var domains: [String] = []
    var combinationGeneric: [ProtectionKeywordEntry] = []
    var combinationRisky: [ProtectionKeywordEntry] = []
    /// Blocked YouTube channel handles, as the user typed them (with the `@`).
    var channels: [String] = []

    /// Nothing can ever match this set — what an untouched install has before any rule.
    static let empty = ProtectionRules()

    var isEmpty: Bool {
        alwaysBlock.isEmpty && userKeywords.isEmpty && youTubeKeywords.isEmpty
            && domains.isEmpty && channels.isEmpty
    }
}

/// What blocked a piece of content, and why.
struct BlockDecision: Equatable {
    /// The rule that matched ("bikini", "pornhub.com", "@somedrama").
    let matched: String
    /// The Activity dashboard's category label — Android's own wording.
    let category: String
    /// The channel the content came from, when the caller knows it (Activity shows it).
    var channel: String?
}

/// The matching engine: Android's `KeywordMatcher`, reduced to what iOS can enforce.
///
/// **What this is.** The same rule tiers, the same normalisation and the same
/// word-boundary rule as the Android app, so a term that blocks there blocks here and a
/// term that does not, does not. What differs is only *where* it can be applied: iOS
/// gives an app no way to read another app's screen, so on iOS these rules run over the
/// content ClearView itself displays (its own feed and its own player) rather than over
/// Chrome and the Google app. The rules are identical; the reach is the platform's.
///
/// **Why the normalisation is ported at all.** `p.o.r.n` and `n u d e` are how a
/// keyword list is defeated in practice, and the Android side answers that generically
/// — NFKC folding, homoglyph folding, separator collapsing, leetspeak — rather than
/// with a list of hardcoded evasions. Reusing the same steps here is what makes "the
/// same rules on both platforms" true for the disguised spellings too.
enum ProtectionMatcher {

    // ── Visually-similar non-Latin letters folded to their Latin look-alikes ──
    //
    // The same practical subset Android folds. A full confusables database is not the
    // point: these are the substitutions a person actually types or a page actually
    // ships, and the map is O(1) per character instead of a table lookup per script.
    private static let homoglyphs: [Character: Character] = [
        // Cyrillic.
        "а": "a", "е": "e", "о": "o", "р": "p", "с": "c", "у": "y",
        "х": "x", "в": "b", "н": "h", "м": "m", "т": "t", "к": "k",
        "і": "i", "ѕ": "s", "г": "r",
        // Greek (practical subset).
        "α": "a", "ε": "e", "ο": "o", "ρ": "p", "σ": "s", "ς": "s",
        "ι": "i", "ν": "v", "χ": "x", "κ": "k", "μ": "m", "τ": "t",
    ]

    /// Digit/symbol → letter leetspeak stand-ins, applied only to word-like tokens.
    private static let leet: [Character: Character] = [
        "0": "o", "1": "i", "3": "e", "4": "a", "5": "s",
        "7": "t", "@": "a", "$": "s", "!": "i",
    ]

    // ── Whole-word matching ────────────────────────────────────────────────

    /// Whether a keyword is a plain word — letters and single spaces only, every
    /// space-separated token at least two letters.
    ///
    /// Plain words match on **word boundaries only**, which is what keeps "cock" out of
    /// "cocktail", "ass" out of "class", "anal" out of "analysis", "bra" out of
    /// "library", "hot" out of "hotel" and "sex" out of "Middlesex". Everything else —
    /// `p0rn`, `f*ck`, `p.o.r.n`, `18+`, `🔞`, and the spaced single-letter forms
    /// (`n u d e`) — keeps plain substring matching: those spellings are
    /// punctuation-embedded on purpose, so their only realistic occurrence is
    /// standalone, and their inflections (`f*cked`, `p0rnhub`) must keep matching.
    static func isPlainWordKeyword(_ keyword: String) -> Bool {
        var sawLetter = false
        for character in keyword {
            if character == " " { continue }
            if !character.isLetter { return false }
            sawLetter = true
        }
        if !sawLetter { return false }
        for token in keyword.split(separator: " ", omittingEmptySubsequences: false)
        where token.count < 2 {
            return false
        }
        return true
    }

    /// Word-boundary-aware `contains`. `text` must already be normalised and lowercased.
    ///
    /// The boundary test is `isLetter || isNumber` rather than a regex `\b`, because
    /// that is Unicode-aware: non-Latin letters count as letters, so a keyword cannot
    /// hide inside a neighbouring word in another script either.
    static func containsKeyword(_ text: String, keyword: String, needsBoundary: Bool) -> Bool {
        if keyword.isEmpty { return false }
        if !needsBoundary { return text.contains(keyword) }

        var searchStart = text.startIndex
        while let range = text.range(of: keyword, range: searchStart..<text.endIndex) {
            let beforeIsWord = range.lowerBound > text.startIndex
                && isWordCharacter(text[text.index(before: range.lowerBound)])
            let afterIsWord = range.upperBound < text.endIndex
                && isWordCharacter(text[range.upperBound])
            if !beforeIsWord && !afterIsWord { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    // ── Normalisation ──────────────────────────────────────────────────────

    /// The canonical form every comparison uses: lowercase + NFKC, homoglyph folding,
    /// separator collapsing, single-letter-run joining, then leetspeak.
    ///
    /// Ordinary text passes through untouched — "the score was 100 to 0", "class of
    /// 2025", "watch porn now" — so this can run over any title before matching without
    /// inventing matches.
    static func normalizeForMatching(_ text: String) -> String {
        // 1. Lowercase, then NFKC (collapses fullwidth/compatibility forms:
        //    "ＰＯＲＮ" → "porn").
        let base = text.lowercased().precomposedStringWithCompatibilityMapping

        // 2. Homoglyph folding, only when the text contains any.
        let folded: String
        if base.contains(where: { homoglyphs[$0] != nil }) {
            folded = String(base.map { homoglyphs[$0] ?? $0 })
        } else {
            folded = base
        }

        // 3. Per-token separator collapsing, then single-letter-run joining, then
        //    leetspeak. Split on spaces only — Android's `split(' ')` — so a tab or a
        //    newline inside a title is not treated as a word break either.
        let tokens = folded.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let collapsed = tokens.map(collapseSingleLetterSeparators)
        return collapseSingleLetterRuns(collapsed).map(applyLeet).joined(separator: " ")
    }

    /// "p.o.r.n" → "porn", "p/o/r/n" → "porn", "n_u_d_3" → "nud3".
    ///
    /// Digits are leetspeak letters, not separators, so "s3x", "p0rn" and "4x4" are
    /// never split. A token containing a multi-character run ("x-videos", "18+") or no
    /// content at all ("🔞") is returned unchanged — collapsing those would change
    /// meaning rather than undo an evasion.
    private static func collapseSingleLetterSeparators(_ token: String) -> String {
        let characters = Array(token)
        guard characters.count > 1 else { return token }

        var content = ""
        var sawSeparator = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isLetter || character.isNumber {
                var end = index
                while end < characters.count,
                      characters[end].isLetter || characters[end].isNumber {
                    end += 1
                }
                if end - index > 1 { return token }
                content.append(character)
                index = end
            } else {
                sawSeparator = true
                index += 1
            }
        }
        return sawSeparator && !content.isEmpty ? content : token
    }

    /// "n u d e" → "nude", "p o r n site" → "porn site".
    ///
    /// Longer tokens break the run, so ordinary multi-word text is never joined.
    private static func collapseSingleLetterRuns(_ tokens: [String]) -> [String] {
        guard tokens.count > 1 else { return tokens }
        var output: [String] = []
        var index = 0
        while index < tokens.count {
            if tokens[index].count == 1 {
                let runStart = index
                while index < tokens.count, tokens[index].count == 1 { index += 1 }
                if index - runStart >= 2 {
                    output.append(tokens[runStart..<index].joined())
                } else {
                    output.append(tokens[runStart])
                }
            } else {
                output.append(tokens[index])
                index += 1
            }
        }
        return output
    }

    /// Leetspeak substitution, only on word-like tokens.
    ///
    /// Serials ("4x4", "2fast", "1st") and pure-numeric tokens ("100", "2025", "3.14")
    /// are returned untouched: applying the map there would mangle a year into a word.
    private static func applyLeet(_ token: String) -> String {
        if isPureNumericToken(token) { return token }
        let characters = Array(token)
        let letters = characters.filter(\.isLetter).count
        if letters < 2 { return token }
        guard characters.contains(where: { leet[$0] != nil }) else { return token }
        return String(characters.map { leet[$0] ?? $0 })
    }

    private static func isPureNumericToken(_ token: String) -> Bool {
        if token.isEmpty { return false }
        return token.allSatisfy { $0.isNumber || $0 == "." || $0 == "," }
    }

    // ── Domains ────────────────────────────────────────────────────────────

    /// A user-entered website as a bare hostname, or nil when it is not one.
    ///
    /// `https://www.Example.com/path` → `example.com`. Android's rule, verbatim: the
    /// stored value has to be a hostname the matcher can compare against, so nonsense
    /// is refused at the door rather than stored and never matched.
    static func normalizeDomain(_ input: String) -> String? {
        var candidate = input.trimmed.lowercased()
        if candidate.isEmpty { return nil }
        if !candidate.hasPrefix("http://"), !candidate.hasPrefix("https://") {
            candidate = "https://" + candidate
        }
        guard var host = URLComponents(string: candidate)?.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        while host.hasSuffix(".") { host.removeLast() }

        guard !host.isEmpty,
              host.count <= 253,
              host.range(of: "^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$", options: .regularExpression) != nil,
              !host.contains(".."),
              !host.hasPrefix("."),
              !host.hasSuffix(".")
        else { return nil }
        return host
    }

    /// The host of a URL-like string, for domain matching. `www.` is dropped.
    static func extractHost(_ text: String) -> String? {
        var candidate = text.trimmed.lowercased()
        if !candidate.hasPrefix("http://"), !candidate.hasPrefix("https://") {
            candidate = "https://" + candidate
        }
        guard var host = URLComponents(string: candidate)?.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? nil : host
    }

    /// A channel handle in the form the block list stores: `@handle`, lowercased.
    ///
    /// Accepts what a person actually pastes — a bare handle, an `@handle`, or a
    /// youtube.com URL — and returns nil when there is no handle in it, so the add field
    /// can refuse with a reason instead of storing something unmatchable.
    static func normalizeHandle(_ input: String) -> String? {
        var candidate = input.trimmed
        if candidate.isEmpty { return nil }
        if let url = URL(string: candidate.hasPrefix("http") ? candidate : "https://" + candidate),
           let host = url.host?.lowercased(),
           host.contains("youtube.com") || host.contains("youtu.be") {
            let parts = url.pathComponents.filter { $0 != "/" }
            if let marker = parts.firstIndex(where: { $0 == "channel" || $0 == "user" || $0 == "c" }),
               parts.count > marker + 1 {
                candidate = parts[marker + 1]
            } else if let first = parts.first {
                candidate = first
            }
        }
        if candidate.hasPrefix("@") { candidate.removeFirst() }
        candidate = candidate.trimmed.lowercased()
        guard !candidate.isEmpty,
              candidate.range(of: "^[a-z0-9._-]{3,60}$", options: .regularExpression) != nil
        else { return nil }
        return "@" + candidate
    }

    // ── The three tiers ────────────────────────────────────────────────────

    /// The first keyword in `entries` that appears in the already-normalised `text`.
    ///
    /// Longest first, so "sex video" is the reported match rather than "sex" — the
    /// reason shown back to a reader should be the most specific rule that caught it.
    static func firstMatch(in normalizedText: String, entries: [ProtectionKeywordEntry]) -> String? {
        for entry in entries {
            if containsKeyword(normalizedText, keyword: entry.normalized, needsBoundary: entry.needsBoundary) {
                return entry.original
            }
        }
        return nil
    }

    /// Tier 3 — context combination: `woman + bikini`, `girl + pics`.
    ///
    /// Blocks only when the text holds BOTH a generic discovery half and a risky half,
    /// which is what lets everyday browsing through while catching a search that is
    /// plainly heading for sexualized content. A term that is both halves ("beach")
    /// never self-combines: a bare "beach" stays innocent.
    static func combinationMatch(in normalizedText: String, rules: ProtectionRules) -> String? {
        guard !rules.combinationGeneric.isEmpty, !rules.combinationRisky.isEmpty else { return nil }

        var genericHit: String?
        for entry in rules.combinationGeneric {
            if containsKeyword(normalizedText, keyword: entry.normalized, needsBoundary: entry.needsBoundary) {
                genericHit = entry.original
                // Prefer a generic half that is NOT also risky ("women" over "beach" in
                // "women beach") so the risky copy stays available to combine with it.
                if !rules.combinationRisky.contains(where: { $0.original == entry.original }) { break }
            }
        }
        guard let generic = genericHit else { return nil }

        for entry in rules.combinationRisky {
            if entry.original == generic { continue }
            if containsKeyword(normalizedText, keyword: entry.normalized, needsBoundary: entry.needsBoundary) {
                return "\(generic) + \(entry.original)"
            }
        }
        return nil
    }

    // ── The two entry points the app uses ──────────────────────────────────

    /// Why this text is blocked, or nil when it is not.
    ///
    /// The order is Android's: the always-on adult tier, then the user's own keywords,
    /// then the context combination — so the reported reason is the most authoritative
    /// rule that applies rather than whichever list happened to be checked first. The
    /// YouTube-only tier sits between the two, and only when the caller says this
    /// content is YouTube's.
    static func decision(
        forText text: String,
        rules: ProtectionRules,
        channel: String? = nil,
        includeYouTubeKeywords: Bool = false
    ) -> BlockDecision? {
        let normalized = normalizeForMatching(text)
        if let match = firstMatch(in: normalized, entries: rules.alwaysBlock) {
            return BlockDecision(matched: match, category: "Adult", channel: channel)
        }
        if let match = firstMatch(in: normalized, entries: rules.userKeywords) {
            return BlockDecision(matched: match, category: "Your keywords", channel: channel)
        }
        if includeYouTubeKeywords,
           let match = firstMatch(in: normalized, entries: rules.youTubeKeywords) {
            return BlockDecision(matched: match, category: "YouTube keywords", channel: channel)
        }
        if let match = combinationMatch(in: normalized, rules: rules) {
            return BlockDecision(matched: match, category: "Pattern", channel: channel)
        }
        return nil
    }

    /// Why this URL is blocked, or nil when it is not.
    ///
    /// A blocked domain applies to the host of the link. A domain rule is deliberately
    /// **not** matched against the whole URL string as a keyword: a link whose path
    /// merely contains a blocked word is not the blocked site, and blocking on that
    /// would take out innocent pages.
    static func decision(
        forURL url: String,
        rules: ProtectionRules,
        channel: String? = nil,
        includeYouTubeKeywords: Bool = false
    ) -> BlockDecision? {
        guard let host = extractHost(url) else { return nil }
        for domain in rules.domains where host == domain || host.hasSuffix("." + domain) {
            return BlockDecision(matched: domain, category: "Blocked website", channel: channel)
        }
        return decision(forText: url, rules: rules, channel: channel, includeYouTubeKeywords: includeYouTubeKeywords)
    }

    /// Whether this channel is on the user's own block list.
    ///
    /// Matched against the `@handle` and against the display name, case-insensitively:
    /// people block "@SomeDrama" from a handle and "Some Drama" from a video's byline,
    /// and both should work.
    static func blockedChannel(name: String?, handle: String?, rules: ProtectionRules) -> String? {
        guard !rules.channels.isEmpty else { return nil }
        let candidates: [String] = [name, handle].compactMap { value in
            guard let value, !value.trimmed.isEmpty else { return nil }
            var normalized = value.trimmed.lowercased()
            if normalized.hasPrefix("@") { normalized.removeFirst() }
            return normalized
        }
        for blocked in rules.channels {
            var needle = blocked.lowercased()
            if needle.hasPrefix("@") { needle.removeFirst() }
            if candidates.contains(needle) { return blocked }
        }
        return nil
    }

    // ── Compiling a rule set ───────────────────────────────────────────────

    /// Compile one keyword list into match-ready entries, longest first.
    ///
    /// The normalised form and the boundary flag are computed here, once per rule
    /// change, exactly as Android's per-set cache does — a scan on every feed card must
    /// not re-normalise 700 keywords.
    static func compile(_ keywords: some Sequence<String>) -> [ProtectionKeywordEntry] {
        var seen: Set<String> = []
        var entries: [ProtectionKeywordEntry] = []
        for keyword in keywords {
            let value = keyword.trimmed
            guard !value.isEmpty else { continue }
            let normalized = normalizeForMatching(value)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            entries.append(
                ProtectionKeywordEntry(
                    original: value,
                    normalized: normalized,
                    needsBoundary: isPlainWordKeyword(normalized)
                )
            )
        }
        // Longest first: the reason shown to a reader is the most specific rule that
        // matched ("sex video", not "sex").
        return entries.sorted { first, second in
            if first.normalized.count != second.normalized.count {
                return first.normalized.count > second.normalized.count
            }
            return first.original < second.original
        }
    }

    /// The always-on adult tier plus the Strict Mode discovery terms when it is on.
    ///
    /// Strict Mode adds to the built-in set; it never removes from it, so turning it on
    /// can only ever block more, which is the whole point of a stricter mode.
    static func builtInKeywords(strictMode: Bool) -> [String] {
        strictMode
            ? ProtectionPresets.alwaysBlockKeywords + ProtectionPresets.strictModeKeywords
            : ProtectionPresets.alwaysBlockKeywords
    }
}

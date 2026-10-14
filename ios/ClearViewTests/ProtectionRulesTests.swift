import XCTest
@testable import ClearView

/// The built-in rules, the matching engine, and the enforcement built on both.
///
/// These are the three places a port can go quietly wrong: a preset that lost entries, a
/// matcher that blocks the wrong words, and an enforcer that reports blocks it did not
/// make. Each is pinned here against Android's own behaviour rather than against whatever
/// the Swift happened to do the first time it ran.
final class ProtectionRulesTests: XCTestCase {

    /// A store of this test's own, so one test can never read another's settings — or a
    /// previous run's.
    private var suiteName = ""

    private lazy var rules: ProtectionRules = makeStore().rules()

    override func setUp() {
        super.setUp()
        suiteName = "ProtectionRulesTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A clean store in this test's own suite.
    private func makeStore() -> ProtectionStore {
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = ProtectionStore(defaults: defaults)
        return store
    }

    // MARK: - The generated presets

    /// The counts, pinned.
    ///
    /// `ProtectionPresets.swift` is generated from Android's `BlockRepository.kt` by
    /// `ios/scripts/generate_protection_presets.py`. These numbers are what that script
    /// printed when the file was generated; a regeneration that drops a list — or a lane
    /// of it — fails here instead of silently protecting less. When the Android lists
    /// change on purpose, regenerate and update these with the new counts.
    func testThePresetsHoldEveryAndroidEntry() {
        XCTAssertEqual(ProtectionPresets.alwaysBlockKeywords.count, 661)
        XCTAssertEqual(ProtectionPresets.adultDomains.count, 92)
        XCTAssertEqual(ProtectionPresets.strictModeKeywords.count, 27)
        XCTAssertEqual(ProtectionPresets.combinationGenericTerms.count, 55)
        XCTAssertEqual(ProtectionPresets.combinationRiskyTerms.count, 42)
    }

    /// Every preset entry is a usable rule: non-empty, trimmed, and — for the domains —
    /// already in the hostname form the matcher compares against.
    func testEveryPresetEntryIsUsable() {
        for keyword in ProtectionPresets.alwaysBlockKeywords
            + ProtectionPresets.strictModeKeywords
            + ProtectionPresets.combinationGenericTerms
            + ProtectionPresets.combinationRiskyTerms {
            XCTAssertFalse(keyword.isBlank, "\"\(keyword)\" is blank")
            XCTAssertEqual(keyword, keyword.trimmed, "\"\(keyword)\" carries whitespace")
        }
        for domain in ProtectionPresets.adultDomains {
            XCTAssertEqual(
                ProtectionMatcher.normalizeDomain(domain),
                domain,
                "\(domain) is not stored in the form the matcher compares"
            )
        }
    }

    /// A couple of the entries that carry the product, so a file that came back empty in a
    /// valid-looking way is still caught.
    func testThePresetsCarryTheTermsThatMatter() {
        XCTAssertTrue(ProtectionPresets.alwaysBlockKeywords.contains("pornhub"))
        XCTAssertTrue(ProtectionPresets.alwaysBlockKeywords.contains("nsfw"))
        XCTAssertTrue(ProtectionPresets.adultDomains.contains("pornhub.com"))
        XCTAssertTrue(ProtectionPresets.strictModeKeywords.contains("bikini"))
        XCTAssertTrue(ProtectionPresets.combinationGenericTerms.contains("women"))
        XCTAssertTrue(ProtectionPresets.combinationRiskyTerms.contains("bikini"))
    }

    /// Strict Mode adds to the always-on tier and never replaces it.
    func testStrictModeOnlyEverAddsTerms() {
        let off = Set(ProtectionMatcher.builtInKeywords(strictMode: false))
        let on = Set(ProtectionMatcher.builtInKeywords(strictMode: true))
        XCTAssertTrue(off.isSubset(of: on))
        XCTAssertEqual(on.count - off.count, ProtectionPresets.strictModeKeywords.count)
    }

    // MARK: - Whole-word matching

    /// A plain word matches only as a whole word, which is what keeps ordinary browsing
    /// out of the block list.
    func testPlainWordsMatchOnWordBoundaries() {
        XCTAssertNil(ProtectionMatcher.decision(forText: "cocktail recipes", rules: rules))
        XCTAssertNil(ProtectionMatcher.decision(forText: "peacock documentary", rules: rules))
        XCTAssertNil(ProtectionMatcher.decision(forText: "class of 2025", rules: rules))
        XCTAssertNil(ProtectionMatcher.decision(forText: "grass growing tips", rules: rules))
        XCTAssertNil(ProtectionMatcher.decision(forText: "data analysis", rules: rules))
        XCTAssertNil(ProtectionMatcher.decision(forText: "the library closes at six", rules: rules))
        XCTAssertNil(ProtectionMatcher.decision(forText: "hoteL booking", rules: rules))
        XCTAssertNil(ProtectionMatcher.decision(forText: "Middlesex county", rules: rules))

        XCTAssertNotNil(ProtectionMatcher.decision(forText: "a good cocktail and porn", rules: rules))
    }

    /// The most specific term wins, so the reason a person reads is the one that explains
    /// the block — a phrase in the list beats the single word inside it.
    func testTheLongestMatchIsTheReportedOne() {
        XCTAssertEqual(ProtectionMatcher.decision(forText: "watch a sex video", rules: rules)?.matched, "sex video")
        XCTAssertEqual(ProtectionMatcher.decision(forText: "watch sex videos", rules: rules)?.matched, "watch sex videos")
    }

    // MARK: - Normalisation

    /// Disguised spellings are caught by the normaliser rather than by a list of
    /// hardcoded evasions.
    func testDisguisedSpellingsAreStillBlocked() {
        let cases = [
            "p.o.r.n",           // intra-token separators
            "p o r n",           // spaced single letters
            "n u d e",
            "p0rn",              // leetspeak
            "s3x tape",
            "f*ck",
            "🔞 preview",         // an emoji entry, matched by substring
        ]
        for text in cases {
            XCTAssertNotNil(
                ProtectionMatcher.decision(forText: text, rules: rules),
                "\"\(text)\" was not blocked"
            )
        }
    }

    /// Homoglyphs — the same word typed in another script's look-alike letters — fold to
    /// Latin before matching.
    func testHomoglyphSpellingsAreFolded() {
        // "pоrn" with a Cyrillic о, and "рorn" with a Cyrillic р.
        XCTAssertNotNil(ProtectionMatcher.decision(forText: "pоrn", rules: rules))
        XCTAssertNotNil(ProtectionMatcher.decision(forText: "рorn", rules: rules))
    }

    /// Ordinary text is left alone, digits and all: a year must not be leeted into a word,
    /// and a multi-character token must not be collapsed into one.
    func testOrdinaryTextIsNotMangled() {
        XCTAssertEqual(ProtectionMatcher.normalizeForMatching("the score was 100 to 0"), "the score was 100 to 0")
        XCTAssertEqual(ProtectionMatcher.normalizeForMatching("class of 2025"), "class of 2025")
        XCTAssertNil(ProtectionMatcher.decision(forText: "watch a 4x4 review", rules: rules))
        XCTAssertNil(ProtectionMatcher.decision(forText: "18 wheels trucking", rules: rules))
    }

    /// Fullwidth characters fold to their ASCII form, so a paste from a non-Latin keyboard
    /// layout cannot walk past the list.
    func testFullwidthTextFolds() {
        XCTAssertNotNil(ProtectionMatcher.decision(forText: "ＰＯＲＮ", rules: rules))
    }

    // MARK: - The tiers

    /// Strict Mode's discovery terms only apply while Strict Mode is on.
    func testStrictModeGate() {
        XCTAssertNil(ProtectionMatcher.decision(forText: "summer bikini haul", rules: rules))

        let strictStore = makeStore()
        strictStore.strictMode = true
        let strict = strictStore.rules()
        XCTAssertEqual(ProtectionMatcher.decision(forText: "summer bikini haul", rules: strict)?.matched, "bikini")
    }

    /// The context combination blocks the pair and never the halves on their own.
    func testTheCombinationTier() {
        XCTAssertNotNil(ProtectionMatcher.decision(forText: "women bikini", rules: rules))
        XCTAssertNotNil(ProtectionMatcher.decision(forText: "girl pics", rules: rules))
        XCTAssertNil(ProtectionMatcher.decision(forText: "women's health", rules: rules))
        XCTAssertNil(ProtectionMatcher.decision(forText: "women athletes", rules: rules))
        XCTAssertNil(ProtectionMatcher.decision(forText: "beach holiday", rules: rules), "a half that is also a risky half never self-combines")
        XCTAssertNotNil(ProtectionMatcher.decision(forText: "beach bikini", rules: rules))
        XCTAssertNil(ProtectionMatcher.decision(forText: "hottest day of the year", rules: rules), "hot does not match inside hottest")
    }

    /// A blocked website matches the host and its subdomains, and nothing else.
    func testDomainMatching() {
        XCTAssertEqual(
            ProtectionMatcher.decision(forURL: "https://www.pornhub.com/view_video.php?viewkey=1", rules: rules)?.matched,
            "pornhub.com"
        )
        XCTAssertEqual(
            ProtectionMatcher.decision(forURL: "https://m.pornhub.com/x", rules: rules)?.matched,
            "pornhub.com",
            "a subdomain of a blocked site is the blocked site"
        )
        XCTAssertNil(ProtectionMatcher.decision(forURL: "https://example.com/photos", rules: rules))
        XCTAssertNil(
            ProtectionMatcher.decision(forURL: "https://example.com/pornhubs", rules: rules),
            "a host that merely contains a blocked site's name is not the blocked site"
        )
        // A URL whose *path* names a blocked site is matched by the keyword tier rather
        // than the domain tier — exactly as Android's `checkString(isUrl = true)` does,
        // which scans the URL text after the host check. The two say different things, and
        // the reported category is what tells them apart.
        XCTAssertEqual(
            ProtectionMatcher.decision(forURL: "https://example.com/pornhub.com-review", rules: rules)?.category,
            "Adult"
        )
    }

    /// The stored form of a website, from what a person actually types.
    func testDomainNormalisation() {
        XCTAssertEqual(ProtectionMatcher.normalizeDomain("https://www.Example.com/path?q=1"), "example.com")
        XCTAssertEqual(ProtectionMatcher.normalizeDomain("  reddit.com.  "), "reddit.com")
        XCTAssertEqual(ProtectionMatcher.normalizeDomain("sub.domain.co.uk"), "sub.domain.co.uk")
        XCTAssertNil(ProtectionMatcher.normalizeDomain(""))
        XCTAssertNil(ProtectionMatcher.normalizeDomain("   "))
        XCTAssertNil(ProtectionMatcher.normalizeDomain("not a domain"))
        XCTAssertNil(ProtectionMatcher.normalizeDomain("http://"))
    }

    /// A channel handle, from a handle, an @handle or a channel URL.
    func testHandleNormalisation() {
        XCTAssertEqual(ProtectionMatcher.normalizeHandle("SomeChannel"), "@somechannel")
        XCTAssertEqual(ProtectionMatcher.normalizeHandle("@somechannel"), "@somechannel")
        XCTAssertEqual(ProtectionMatcher.normalizeHandle("https://www.youtube.com/@somechannel/videos"), "@somechannel")
        XCTAssertEqual(ProtectionMatcher.normalizeHandle("https://www.youtube.com/channel/UC123abc"), "@uc123abc")
        XCTAssertNil(ProtectionMatcher.normalizeHandle("ab"), "too short to be a handle")
        XCTAssertNil(ProtectionMatcher.normalizeHandle("  "))
    }

    /// A channel block matches the handle and the display name, in either case.
    func testBlockedChannelMatching() {
        var withChannel = rules
        withChannel.channels = ["@somedrama"]
        XCTAssertEqual(
            ProtectionMatcher.blockedChannel(name: "Some Drama", handle: nil, rules: withChannel),
            nil,
            "the display name only matches when it is the same string as the block"
        )
        XCTAssertEqual(
            ProtectionMatcher.blockedChannel(name: nil, handle: "SomeDrama", rules: withChannel),
            "@somedrama",
            "a handle block matches the handle in any case"
        )
        XCTAssertNil(ProtectionMatcher.blockedChannel(name: "Other", handle: "@other", rules: withChannel))
    }

    // MARK: - The enforcer

    private let on = ProtectionEnforcementOptions(
        protectionEnabled: true,
        youTubeProtection: true,
        blockShorts: true,
        strictMode: false
    )

    /// With Protection off nothing is filtered, whatever the rules say.
    func testNothingIsFilteredWhileProtectionIsOff() {
        let subjects = [subject(title: "porn compilation"), subject(title: "a normal video")]
        let result = ProtectionEnforcer.partition(subjects, rules: rules, options: .off)
        XCTAssertEqual(result.kept.count, 2)
        XCTAssertTrue(result.hidden.isEmpty)
    }

    /// With Protection on, an adult title is hidden and an ordinary one is untouched.
    func testAdultTitlesAreHiddenAndOthersAreNot() {
        let subjects = [subject(title: "Free porn compilation"), subject(title: "Learn Swift generics")]
        let result = ProtectionEnforcer.partition(subjects, rules: rules, options: on)
        XCTAssertEqual(result.kept.map(\.id), ["Learn Swift generics"])
        XCTAssertEqual(result.hidden.map(\.decision.category), ["Adult"])
    }

    /// A YouTube-only keyword applies to YouTube content and never to anything else.
    func testYouTubeKeywordsApplyToYouTubeOnly() {
        var rules = self.rules
        rules.youTubeKeywords = ProtectionMatcher.compile(["drama"])
        let youTube = ProtectionSubject(id: "yt", title: "drama at the airport", isYouTube: true)
        let instagram = ProtectionSubject(id: "ig", title: "drama at the airport", isYouTube: false)

        let result = ProtectionEnforcer.partition([youTube, instagram], rules: rules, options: on)
        XCTAssertEqual(result.hidden.map(\.subject.id), ["yt"])
        XCTAssertEqual(result.hidden.first?.decision.category, "YouTube keywords")
        XCTAssertEqual(result.kept.map(\.id), ["ig"])
    }

    /// The description is checked as well as the title — a video's real content is both.
    func testTheDescriptionIsChecked() {
        let video = ProtectionSubject(id: "1", title: "Vlog episode 4", description: "contains porn", isYouTube: true)
        let result = ProtectionEnforcer.partition([video], rules: rules, options: on)
        XCTAssertEqual(result.hidden.count, 1)
    }

    /// A blocked channel hides everything from that channel.
    func testABlockedChannelHidesItsVideos() {
        var rules = self.rules
        rules.channels = ["@somedrama"]
        let video = ProtectionSubject(id: "1", title: "Episode 4", channelName: "Some Drama", channelHandle: "@SomeDrama")
        let result = ProtectionEnforcer.partition([video], rules: rules, options: on)
        XCTAssertEqual(result.hidden.first?.decision.category, "Blocked channel")
        XCTAssertEqual(result.hidden.first?.decision.matched, "@somedrama")
    }

    /// Block Shorts hides Shorts, and only Shorts.
    func testBlockShortsHidesShortsOnly() {
        let short = ProtectionSubject(id: "short", title: "A funny clip", isYouTube: true, isShort: true)
        let long = ProtectionSubject(id: "long", title: "A funny clip", isYouTube: true, isShort: false)
        let result = ProtectionEnforcer.partition([short, long], rules: rules, options: on)
        XCTAssertEqual(result.hidden.map(\.subject.id), ["short"])
        XCTAssertEqual(result.kept.map(\.id), ["long"])

        let noShorts = ProtectionEnforcementOptions(
            protectionEnabled: true, youTubeProtection: true, blockShorts: false, strictMode: false
        )
        XCTAssertTrue(ProtectionEnforcer.partition([short, long], rules: rules, options: noShorts).hidden.isEmpty)
    }

    /// A blocked website hides a link to it.
    func testABlockedWebsiteHidesItsLinks() {
        let video = ProtectionSubject(id: "1", title: "Saved link", url: "https://m.pornhub.com/view", isYouTube: false)
        let result = ProtectionEnforcer.partition([video], rules: rules, options: on)
        XCTAssertEqual(result.hidden.first?.decision.matched, "pornhub.com")
    }

    /// `keptIDs` keeps the caller's own order, so filtering a feed never reshuffles it.
    func testKeptIDsPreserveOrder() {
        let subjects = [
            ProtectionSubject(id: "a", title: "first"),
            ProtectionSubject(id: "b", title: "porn"),
            ProtectionSubject(id: "c", title: "third"),
        ]
        let ids = ProtectionEnforcer.keptIDs(subjects, rules: rules, options: on)
        XCTAssertEqual(Array(ids).sorted(), ["a", "c"])
        XCTAssertEqual(ProtectionEnforcer.partition(subjects, rules: rules, options: on).kept.map(\.id), ["a", "c"])
    }

    // MARK: - Helpers

    private func subject(title: String, isYouTube: Bool = true, isShort: Bool = false) -> ProtectionSubject {
        ProtectionSubject(id: title, title: title, isYouTube: isYouTube, isShort: isShort)
    }
}

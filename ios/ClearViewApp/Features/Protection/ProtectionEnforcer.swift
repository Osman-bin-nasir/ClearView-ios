import Foundation

/// One piece of content the rules can be applied to, in the terms the rules need.
///
/// Deliberately not the media model: the Protection feature decides what is blocked, and
/// keeping its input this small is what lets the decision be tested without a library, a
/// network, or a view. The caller maps whatever it has onto these fields.
struct ProtectionSubject: Equatable, Identifiable {
    let id: String
    let title: String
    var description: String? = nil
    var channelName: String? = nil
    var channelHandle: String? = nil
    var url: String? = nil
    var isYouTube = true
    var isShort = false
}

/// Which rules apply right now.
///
/// The switches are separate because Android's are: the always-on adult filter and the
/// user's everywhere-keywords are the base, YouTube Protection adds the YouTube-only
/// keywords and the blocked channels, and Block Shorts is its own switch. All of them
/// hang off the hero switch — while protection is off, nothing is filtered, which is what
/// the hero card's status line claims.
struct ProtectionEnforcementOptions: Equatable {
    var protectionEnabled: Bool
    var youTubeProtection: Bool
    var blockShorts: Bool
    var strictMode: Bool

    static let off = ProtectionEnforcementOptions(
        protectionEnabled: false,
        youTubeProtection: false,
        blockShorts: false,
        strictMode: false
    )

    /// The options as the store has them — one place that reads the settings, so a view
    /// cannot disagree with the tab about what is on.
    static func current(_ store: ProtectionStore) -> ProtectionEnforcementOptions {
        ProtectionEnforcementOptions(
            protectionEnabled: store.hasBeenEnabled,
            youTubeProtection: store.youTubeProtection,
            blockShorts: store.blockShorts,
            strictMode: store.strictMode
        )
    }
}

/// What a list turned into: the entries that stay, and the ones that were blocked and why.
struct ProtectionEnforcement {
    var kept: [ProtectionSubject] = []
    var hidden: [(subject: ProtectionSubject, decision: BlockDecision)] = []

    var hiddenCount: Int { hidden.count }
}

/// Applying the rules to the content ClearView shows.
///
/// This is the half of the Android app that iOS can actually reproduce. Android points its
/// matcher at another app's screen through an Accessibility Service; iOS forbids that, so
/// the same rules run over the content ClearView itself is about to render — the feed, the
/// Shorts shelf, the player's page. The rules are the ones the Block tab edits, which is
/// what makes that tab real on this platform rather than a settings page over nothing.
///
/// Everything here is a pure function of (subject, rules, options): the caller decides
/// when to run it, and a test can run it over a fixture list without a device.
enum ProtectionEnforcer {

    /// The verdict for one subject, or nil when nothing blocks it.
    ///
    /// Order matters and follows Android's: a blocked channel first (it is the strongest
    /// statement a user can make about a source), then a blocked website, then the
    /// always-on adult tier, the user's own keywords, the YouTube-only tier, the
    /// context-combination pattern, and finally Shorts. The first rule that applies is the
    /// reason reported, so the Activity dashboard explains the *most specific* thing that
    /// happened rather than the most general one.
    static func verdict(
        for subject: ProtectionSubject,
        rules: ProtectionRules,
        options: ProtectionEnforcementOptions
    ) -> BlockDecision? {
        guard options.protectionEnabled else { return nil }

        let youTube = subject.isYouTube
        let applyYouTubeRules = youTube && options.youTubeProtection

        if applyYouTubeRules,
           let blocked = ProtectionMatcher.blockedChannel(
               name: subject.channelName,
               handle: subject.channelHandle,
               rules: rules
           ) {
            return BlockDecision(matched: blocked, category: "Blocked channel", channel: subject.channelName)
        }

        if let url = subject.url,
           let decision = ProtectionMatcher.decision(
               forURL: url,
               rules: rules,
               channel: subject.channelName,
               includeYouTubeKeywords: applyYouTubeRules
           ),
           decision.category == "Blocked website" {
            return decision
        }

        for text in [subject.title, subject.description].compactMap({ $0 }) where !text.isBlank {
            if let decision = ProtectionMatcher.decision(
                forText: text,
                rules: rules,
                channel: subject.channelName,
                includeYouTubeKeywords: applyYouTubeRules
            ) {
                return decision
            }
        }

        if let channelName = subject.channelName, !channelName.isBlank {
            // The channel's own name is checked against the keywords too: a channel called
            // "Drama Clips" is the content, not a container for it.
            if let decision = ProtectionMatcher.decision(
                forText: channelName,
                rules: rules,
                channel: channelName,
                includeYouTubeKeywords: applyYouTubeRules
            ) {
                return decision
            }
        }

        if applyYouTubeRules, options.blockShorts, subject.isShort {
            return BlockDecision(matched: "Shorts", category: "Shorts", channel: subject.channelName)
        }

        return nil
    }

    /// Split a list into what stays and what is blocked.
    ///
    /// The order of `kept` is the caller's own, so filtering a feed never reshuffles it.
    static func partition(
        _ subjects: [ProtectionSubject],
        rules: ProtectionRules,
        options: ProtectionEnforcementOptions
    ) -> ProtectionEnforcement {
        var result = ProtectionEnforcement()
        for subject in subjects {
            if let decision = verdict(for: subject, rules: rules, options: options) {
                result.hidden.append((subject, decision))
            } else {
                result.kept.append(subject)
            }
        }
        return result
    }

    /// The ids a list keeps. The view keeps items whose id is in here, which is how a feed
    /// stays a filter over its own model rather than a second copy of it.
    static func keptIDs(
        _ subjects: [ProtectionSubject],
        rules: ProtectionRules,
        options: ProtectionEnforcementOptions
    ) -> Set<String> {
        guard options.protectionEnabled else { return Set(subjects.map(\.id)) }
        return Set(partition(subjects, rules: rules, options: options).kept.map(\.id))
    }
}

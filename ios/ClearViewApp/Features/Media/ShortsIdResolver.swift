import Foundation

/// Which of a channel's videos are Shorts.
///
/// The same technique as the Android app, and for the same reason: the channel RSS
/// feed carries no duration, and many Shorts never use the `#shorts` hashtag, so
/// title-based detection leaves the Shorts row mostly empty. YouTube's channel
/// `/shorts` tab server-renders `ytInitialData` listing *only* that channel's Shorts,
/// so every 11-character video id on that page belongs to one.
///
/// Extraction is pure and tested; the fetch is a small, cached network call. A failure
/// returns an empty set rather than an error, and the feed then falls back to the
/// hashtag signal alone — a degraded Shorts row is better than a Media tab that cannot
/// load.
enum ShortsIdResolver {

    /// `"videoId":"<11 characters>"` anywhere in the page, which is how the id appears
    /// in the embedded JSON.
    static let videoIdPattern = "\"videoId\"\\s*:\\s*\"([0-9A-Za-z_-]{11})\""

    /// Every 11-character video id on a `/shorts` tab page.
    ///
    /// Intentionally permissive: on that tab virtually every id is a Short of the
    /// channel, so a stray recommended id costs nothing while a missed one hides a
    /// Short from the row.
    static func extractShortsIds(from html: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: videoIdPattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var ids: Set<String> = []
        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: html) else {
                continue
            }
            ids.insert(String(html[capture]))
        }
        return ids
    }

    /// How long a resolved channel's ids are trusted.
    ///
    /// Short-lived, and only non-empty results are cached: a channel that starts
    /// posting Shorts later is picked up on the next refresh rather than being stuck
    /// with an empty answer.
    static let cacheLifetime: TimeInterval = 10 * 60

    /// Fetches a channel's `/shorts` tab and extracts its video ids.
    ///
    /// A desktop user agent is required — YouTube serves a reduced page without
    /// `ytInitialData` to a mobile one, which would look like "this channel has no
    /// Shorts".
    static func fetchShortsIds(
        channelId: String,
        session: URLSession = .shared,
        now: Date = Date()
    ) async -> Set<String> {
        if let cached = await cache.value(for: channelId, now: now) { return cached }

        guard let url = URL(string: "https://www.youtube.com/channel/\(channelId)/shorts") else {
            return []
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                + "(KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let html = String(data: data, encoding: .utf8) ?? ""
            let ids = extractShortsIds(from: html)
            if !ids.isEmpty {
                await cache.store(ids, for: channelId, now: now)
            }
            return ids
        } catch {
            return []
        }
    }

    /// A tiny in-memory TTL cache, shared across the tab's refreshes.
    ///
    /// An actor because the Media tab resolves several channels' Shorts at once, and a
    /// plain dictionary mutated from concurrent tasks is the classic way to crash a
    /// feed that was only trying to be quick.
    private actor Cache {
        private var entries: [String: (ids: Set<String>, at: Date)] = [:]

        func value(for channelId: String, now: Date) -> Set<String>? {
            guard let entry = entries[channelId] else { return nil }
            guard now.timeIntervalSince(entry.at) < cacheLifetime else {
                entries.removeValue(forKey: channelId)
                return nil
            }
            return entry.ids
        }

        func store(_ ids: Set<String>, for channelId: String, now: Date) {
            entries[channelId] = (ids, now)
        }

        func removeAll() {
            entries.removeAll()
        }
    }

    private static let cache = Cache()

    /// Forgets every cached answer. For the tests, and for a "refresh everything" that
    /// must not be served yesterday's Shorts.
    static func clearCache() async {
        await cache.removeAll()
    }
}

import Foundation

/// A downloadable Quran edition.
///
/// Two editions, from the same `fawazahmed0/quran-api` mirror the Android app
/// uses (served over the jsDelivr CDN — no API key, stable public URLs). The URL
/// is deliberately byte-for-byte the same as
/// `app/src/main/java/com/muddassir/clearview/quran/data/QuranApi.kt`, so both
/// platforms render the same translation of the same ayah.
enum QuranEdition: String, CaseIterable, Sendable {
    /// English: "The Clear Quran" translation by Dr Mustafa Khattab. Required —
    /// every verse's text comes from it.
    case english = "eng-mustafakhattaba"

    /// Arabic: the full Quran in IndoPak script. Supplementary — shown beside
    /// the English when cached, but the reader works without it.
    case arabic = "ara-quranindopak"

    var url: URL {
        URL(string: "https://cdn.jsdelivr.net/gh/fawazahmed0/quran-api@1/editions/\(rawValue).json")!
    }

    /// The cache file name for this edition.
    ///
    /// The edition id is part of the name rather than fixed as
    /// `quran_cache.json`, which is what the Android store calls it. Android had
    /// to add an explicit migration that deletes the old files and clears the
    /// persisted verse whenever the chosen editions changed, because a stale
    /// file under a reused name parses fine and then silently serves the wrong
    /// text. Naming the file after its edition makes that class of bug
    /// impossible: a different edition simply has no cache.
    var cacheFileName: String { "quran-\(rawValue).json" }
}

/// How the raw edition JSON is obtained.
///
/// A protocol rather than a direct `URLSession` call so the repository can be
/// tested without the network — the download is the only part of this feature
/// that is not deterministic, and it is the part whose *failure* paths matter
/// most (offline first run, a truncated body, a 404 HTML error page).
protocol QuranEditionFetching: Sendable {
    func fetch(_ edition: QuranEdition) async throws -> String
}

/// The real fetcher: `URLSession`, which is what iOS brings for free —
/// connection pooling, HTTP/2, disk-backed response caching, and background
/// transfer. The Android side hand-rolls `HttpURLConnection` because it has to;
/// here there is no reason to bypass the platform client.
struct QuranHttpFetcher: QuranEditionFetching {

    /// Generous: the Arabic edition is roughly 2 MB on a slow connection.
    private let timeout: TimeInterval = 60

    func fetch(_ edition: QuranEdition) async throws -> String {
        var request = URLRequest(url: edition.url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw QuranRepositoryError.downloadFailed(edition, status: status)
        }
        // Decoded as UTF-8 explicitly. The verses are Arabic and English with
        // diacritics; a lossy decode would corrupt them into U+FFFD, which is
        // exactly what `QuranTextIntegrity` exists to catch. Better to fail the
        // download than to cache mangled scripture.
        guard let text = String(data: data, encoding: .utf8) else {
            throw QuranRepositoryError.downloadFailed(edition, status: http.statusCode)
        }
        return text
    }
}

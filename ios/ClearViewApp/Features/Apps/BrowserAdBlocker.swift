import Foundation
import WebKit

/// Request rules are scoped to YouTube documents. Never block the general
/// googlevideo CDN, which also carries the video the person chose to watch.
@MainActor
enum BrowserAdBlocker {
    private static var compilation: Task<WKContentRuleList, Error>?

    static func rules() async throws -> WKContentRuleList {
        if let compilation { return try await compilation.value }
        let task = Task<WKContentRuleList, Error> {
            let filters = [
                #"^https?://([a-z0-9-]+\.)*doubleclick\.net/"#,
                #"^https?://([a-z0-9-]+\.)*googlesyndication\.com/"#,
                #"^https?://([a-z0-9-]+\.)*googleadservices\.com/"#,
                #"^https?://([a-z0-9-]+\.)*youtube\.com/pagead/"#,
                #"^https?://([a-z0-9-]+\.)*youtube\.com/api/stats/ads"#,
                #"^https?://([a-z0-9-]+\.)*youtube\.com/youtubei/v1/player/ads"#
            ]
            let rules: [[String: Any]] = filters.map {
                ["trigger": ["url-filter": $0, "if-domain": ["*youtube.com"]], "action": ["type": "block"]]
            }
            let data = try JSONSerialization.data(withJSONObject: rules)
            let source = String(decoding: data, as: UTF8.self)
            return try await withCheckedThrowingContinuation { continuation in
                WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "clearview.youtube-ads.v1", encodedContentRuleList: source) { rules, error in
                    if let rules { continuation.resume(returning: rules) }
                    else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                }
            }
        }
        compilation = task
        do { return try await task.value }
        catch { compilation = nil; throw error }
    }
}

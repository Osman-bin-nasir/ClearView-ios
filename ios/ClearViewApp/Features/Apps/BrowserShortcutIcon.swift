import SwiftUI

struct BrowserShortcutIcon: View {
    let shortcut: BrowserShortcut
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(image == nil ? Color.cvSurfaceContainerHigh : .white)
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(width: 34, height: 34)
            } else {
                Text(String(shortcut.name.prefix(1)).uppercased())
                    .font(.title2.weight(.semibold)).foregroundStyle(Color.cvPrimary)
            }
        }.frame(width: 56, height: 56).accessibilityHidden(true)
            .task(id: shortcut.url) {
                let loaded = await BrowserShortcutIconStore.shared.image(for: shortcut.url)
                guard !Task.isCancelled else { return }
                image = loaded
            }
    }
}

/// Fetch icons from the saved website, without a third-party favicon service or
/// the person's browser cookies. Decoded images reuse ClearView's disk cache.
@MainActor
private final class BrowserShortcutIconStore {
    static let shared = BrowserShortcutIconStore()
    private var images: [String: UIImage] = [:]
    private var loading: [String: Task<UIImage?, Never>] = [:]
    private var missing = Set<String>()
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    func image(for url: URL) async -> UIImage? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https" else { return nil }
        parts.path = "/"; parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        guard let origin = parts.url else { return nil }
        let key = origin.absoluteString
        if let image = images[key] { return image }
        if missing.contains(key) { return nil }
        if let pending = loading[key] { return await pending.value }
        let pending = Task<UIImage?, Never> {
            let favicon = origin.appendingPathComponent("favicon.ico")
            if let image = await RemoteImageCache.shared.image(for: favicon.absoluteString) { return image }
            let discovered = await discoverIcons(at: origin)
            let candidates = discovered + [origin.appendingPathComponent("apple-touch-icon.png"), origin.appendingPathComponent("favicon.png")]
            var tried: Set<URL> = [favicon]
            for candidate in candidates where tried.insert(candidate).inserted {
                if let image = await RemoteImageCache.shared.image(for: candidate.absoluteString) { return image }
            }
            return nil
        }
        loading[key] = pending
        let result = await pending.value
        loading[key] = nil
        if let result { images[key] = result } else { missing.insert(key) }
        return result
    }

    private func discoverIcons(at origin: URL) async -> [URL] {
        do {
            let (bytes, response) = try await session.bytes(from: origin)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  response.url?.scheme == "https", response.mimeType?.contains("html") == true else { return [] }
            // Only the bounded document head is needed, never the full page.
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 131_072 { break }
                if byte == 62, data.suffix(7).elementsEqual(Data("</head>".utf8)) { break }
            }
            guard let html = String(data: data, encoding: .utf8) else { return [] }
            let links = try NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive])
            let attributes = try NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
            var icons: [(url: URL, priority: Int)] = []
            for match in links.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                guard let range = Range(match.range, in: html) else { continue }
                let tag = String(html[range])
                var values: [String: String] = [:]
                for attr in attributes.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                    guard let name = Range(attr.range(at: 1), in: tag),
                          let value = (2...4).compactMap({ Range(attr.range(at: $0), in: tag) }).first else { continue }
                    values[String(tag[name]).lowercased()] = String(tag[value])
                }
                let rel = (values["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
                let apple = rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed")
                guard apple || rel.contains("icon"), let href = values["href"],
                      values["type"]?.lowercased() != "image/svg+xml",
                      let icon = URL(string: href.replacingOccurrences(of: "&amp;", with: "&"), relativeTo: response.url ?? origin)?.absoluteURL,
                      icon.scheme == "https", icon.user == nil, icon.password == nil,
                      icon.pathExtension.lowercased() != "svg" else { continue }
                icons.append((icon, apple ? 1 : 0))
            }
            return Array(icons.sorted { $0.priority > $1.priority }.prefix(6).map(\.url))
        } catch { return [] }
    }
}

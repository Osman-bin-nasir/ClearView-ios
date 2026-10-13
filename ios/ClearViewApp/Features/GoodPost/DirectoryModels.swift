import Foundation

/// The channel directory: a curated list of **external** channels.
///
/// A directory row is not a ClearView channel. It cannot post, it has no followers, and
/// nothing about it is stored on this device beyond a copy of the list itself. It is a
/// platform, a handle and the two things worth drawing — a name and a picture — and a tap
/// opens the platform's own page.
///
/// The whole list arrives as one `DirectorySnapshot` rather than one call per category:
/// the screen wants the list and its shape together, and a tab that fetched itself would
/// flicker as each answer landed. The set is curated, so it stays small enough for that to
/// be the cheap design.
struct DirectoryChannel: Identifiable, Equatable, Codable {
    let id: String
    /// `youtube`, `instagram` or `x`. The server decides; the app words it.
    let platform: String
    /// The handle as stored: no leading `@`, lowercased.
    let handle: String
    let name: String?
    let iconUrl: String?
    /// The platform page a tap opens, built by the server.
    let url: String
    let categoryId: String?
    let subcategoryId: String?
    let sort: Int

    /// What a card shows when the platform gave us no name.
    ///
    /// The handle is identity, so a channel with no name is a working row rather than a
    /// broken one — it shows the thing a person would type to find it.
    var displayName: String {
        guard let name, !name.trimmed.isEmpty else { return "@\(handle)" }
        return name
    }

    /// The handle as it is shown: with the `@` the stored form deliberately omits.
    var displayHandle: String { "@\(handle)" }

    /// The platform's name, in the app's wording — the server sends a slug, not a label,
    /// so a new platform reads sensibly in the UI without a server change.
    var platformLabel: String {
        switch platform.lowercased() {
        case "youtube", "yt": return "YouTube"
        case "instagram", "ig": return "Instagram"
        case "x", "twitter": return "X"
        default: return platform.prefix(1).uppercased() + platform.dropFirst()
        }
    }
}

/// A grouping inside one category.
struct DirectorySubcategory: Identifiable, Equatable, Codable {
    let id: String
    let categoryId: String
    let name: String
    let slug: String
    let sort: Int
    let channels: [DirectoryChannel]
}

/// A top-level grouping.
struct DirectoryCategory: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let slug: String
    let sort: Int
    let subcategories: [DirectorySubcategory]
    /// Channels filed directly under the category, with no subcategory.
    let channels: [DirectoryChannel]

    /// Every channel under this category, subcategories included.
    var channelCount: Int { channels.count + subcategories.reduce(0) { $0 + $1.channels.count } }
}

/// The whole directory, as one object.
///
/// `unfiled` holds the channels whose category was never chosen, or was deleted
/// afterwards. That is **not** an error state — the read still returns them — and the
/// screen shows them under an "All" tab alongside the categorised ones.
struct DirectorySnapshot: Equatable, Codable {
    var categories: [DirectoryCategory] = []
    var unfiled: [DirectoryChannel] = []

    var isEmpty: Bool { categories.isEmpty && unfiled.isEmpty }

    /// Every channel, categorised or not, in server order — what the "All" tab draws.
    ///
    /// Built here rather than in a screen so the one idea of "the whole list" is defined
    /// once. Categories and their subcategories are walked in stored order, which is the
    /// server's curated order, not alphabetical.
    var allChannels: [DirectoryChannel] {
        var channels: [DirectoryChannel] = []
        for category in categories {
            channels.append(contentsOf: category.channels)
            for subcategory in category.subcategories {
                channels.append(contentsOf: subcategory.channels)
            }
        }
        channels.append(contentsOf: unfiled)
        return channels
    }

    /// The categories that have something to show, in order. A category whose channels
    /// were all dropped as unreadable would otherwise draw an empty tab.
    var displayableCategories: [DirectoryCategory] {
        categories.filter { $0.channelCount > 0 }
    }

    /// Look up a channel by id, across every category and the unfiled list.
    func channel(id: String) -> DirectoryChannel? {
        allChannels.first { $0.id == id }
    }
}

/// Parsing and serialising the directory.
///
/// The wire shape and the cache shape are deliberately the same object, so one codec
/// serves the live read and a stored copy — there is no second shape to drift out of step.
enum DirectoryCodec {

    /// Parses a `{ categories: [...], unfiled: [...] }` body in full.
    ///
    /// Tolerant per record, like every other codec here: an unreadable category or channel
    /// is skipped, and the rest of the directory still draws.
    static func snapshot(from dictionary: [String: Any]) -> DirectorySnapshot {
        let categories = (dictionary["categories"] as? [Any] ?? [])
            .compactMap { $0 as? [String: Any] }
            .compactMap { category(from: $0) }
        return DirectorySnapshot(
            categories: categories,
            unfiled: channels(from: dictionary["unfiled"])
        )
    }

    /// Parses a whole body from JSON text.
    static func snapshot(json: String) -> DirectorySnapshot? {
        guard let data = json.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return snapshot(from: dictionary)
    }

    /// One category, or nil when it has no id or no name — a tab nobody can label.
    static func category(from dictionary: [String: Any]) -> DirectoryCategory? {
        let id = string(dictionary["id"]) ?? ""
        let name = string(dictionary["name"]) ?? ""
        guard !id.isEmpty, !name.isEmpty else { return nil }
        return DirectoryCategory(
            id: id,
            name: name,
            slug: string(dictionary["slug"]) ?? "",
            sort: int(dictionary["sort"]) ?? 0,
            subcategories: (dictionary["subcategories"] as? [Any] ?? [])
                .compactMap { $0 as? [String: Any] }
                .compactMap { subcategory(from: $0) },
            channels: channels(from: dictionary["channels"])
        )
    }

    /// One subcategory, or nil when it has no id or no name.
    static func subcategory(from dictionary: [String: Any]) -> DirectorySubcategory? {
        let id = string(dictionary["id"]) ?? ""
        let name = string(dictionary["name"]) ?? ""
        guard !id.isEmpty, !name.isEmpty else { return nil }
        return DirectorySubcategory(
            id: id,
            categoryId: string(dictionary["categoryId"]) ?? "",
            name: name,
            slug: string(dictionary["slug"]) ?? "",
            sort: int(dictionary["sort"]) ?? 0,
            channels: channels(from: dictionary["channels"])
        )
    }

    /// One channel, or nil when a required field is missing.
    ///
    /// `id`, `platform`, `handle` and `url` are required: a row missing any of them cannot
    /// be drawn, copied or opened, so dropping it is better than showing a card whose tap
    /// goes nowhere.
    static func channel(from dictionary: [String: Any]) -> DirectoryChannel? {
        guard let id = string(dictionary["id"]), !id.isEmpty,
              let platform = string(dictionary["platform"]), !platform.isEmpty,
              let handle = string(dictionary["handle"]), !handle.isEmpty,
              let url = string(dictionary["url"]), !url.isEmpty else {
            return nil
        }
        return DirectoryChannel(
            id: id,
            platform: platform,
            handle: handle,
            name: nullableString(dictionary["name"]),
            iconUrl: nullableString(dictionary["iconUrl"]),
            url: url,
            categoryId: nullableString(dictionary["categoryId"]),
            subcategoryId: nullableString(dictionary["subcategoryId"]),
            sort: int(dictionary["sort"]) ?? 0
        )
    }

    // MARK: - The offline cache

    /// Serialises the whole snapshot for the offline cache.
    ///
    /// Kept **whole** — categories, subcategories and channels — because the screen draws
    /// a nested shape, and a flattened copy would have to be reassembled by guessing what
    /// belonged to what.
    static func encode(_ snapshot: DirectorySnapshot) -> String {
        let body: [String: Any] = [
            "categories": snapshot.categories.map(encodedCategory),
            "unfiled": snapshot.unfiled.map(encodedChannel),
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    /// Decodes a stored snapshot, or nil when it is missing or unreadable — the caller
    /// then fetches, which is the same thing it does on a first launch.
    static func decode(_ raw: String?) -> DirectorySnapshot? {
        guard let raw, !raw.trimmed.isEmpty else { return nil }
        return snapshot(json: raw)
    }

    /// A snapshot survives its own round trip unchanged — the property that lets the cache
    /// and the network share one shape.
    static func roundTrip(_ snapshot: DirectorySnapshot) -> DirectorySnapshot? {
        decode(encode(snapshot))
    }

    private static func encodedCategory(_ category: DirectoryCategory) -> [String: Any] {
        [
            "id": category.id,
            "name": category.name,
            "slug": category.slug,
            "sort": category.sort,
            "channels": category.channels.map(encodedChannel),
            "subcategories": category.subcategories.map { subcategory in
                [
                    "id": subcategory.id,
                    "categoryId": subcategory.categoryId,
                    "name": subcategory.name,
                    "slug": subcategory.slug,
                    "sort": subcategory.sort,
                    "channels": subcategory.channels.map(encodedChannel),
                ] as [String: Any]
            },
        ]
    }

    private static func encodedChannel(_ channel: DirectoryChannel) -> [String: Any] {
        [
            "id": channel.id,
            "platform": channel.platform,
            "handle": channel.handle,
            "name": channel.name.map { $0 as Any } ?? NSNull(),
            "iconUrl": channel.iconUrl.map { $0 as Any } ?? NSNull(),
            "url": channel.url,
            "categoryId": channel.categoryId.map { $0 as Any } ?? NSNull(),
            "subcategoryId": channel.subcategoryId.map { $0 as Any } ?? NSNull(),
            "sort": channel.sort,
        ]
    }

    private static func channels(from value: Any?) -> [DirectoryChannel] {
        (value as? [Any] ?? []).compactMap { $0 as? [String: Any] }.compactMap { channel(from: $0) }
    }

    private static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return value as? String
    }

    /// A string that is present *and* not blank; an empty name is not a name.
    private static func nullableString(_ value: Any?) -> String? {
        guard let text = string(value) else { return nil }
        return text.trimmed.isEmpty ? nil : text
    }

    private static func int(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        return value as? Int
    }
}

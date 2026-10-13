import Foundation

/// One dhikr phrase in the Dhikr Counter, together with its *own* counting state.
///
/// The Swift shape of the Android `DhikrItem`, field for field — each dhikr keeps
/// its count, target and last-completed session independently, so switching
/// between them never loses progress, and `DhikrCodec` can read what the Android
/// app wrote (and the other way round) without a translation layer.
///
/// - `id`: stable identifier — `"subhanallah"` for the built-ins,
///   `"custom-<uuid>"` for user-created ones. It never changes on rename, which is
///   what keeps the persisted selection valid.
/// - `target`: the repetition goal (33 / 99 / 100 / 1000 / custom). 0 means "no
///   target": the ring stays empty and the screen shows "—" rather than a
///   percentage of nothing.
/// - `visible`: hidden dhikr stay in management but never appear in the swipeable
///   selection, so a phrase can be retired without losing its count.
/// - `count`: the current count, persisted — this is what survives a restart.
/// - `lastCompletedCount` / `lastCompletedAt`: the most recent *completed* session,
///   recorded the first time the count reaches the target and kept after a reset
///   as the "Last: N" indicator.
struct DhikrItem: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var arabic: String = ""
    var translation: String = ""
    var target: Int = 33
    var visible: Bool = true
    var order: Int = 0
    var count: Int = 0
    var lastCompletedCount: Int = 0
    var lastCompletedAt: Int64 = 0

    /// The stored JSON names, which are the Android codec's — camelCase, and
    /// (deliberately) not Swifty snake_case. Renaming them here would silently
    /// break the one thing this codec exists for: a list that moves between the
    /// platforms unchanged.
    enum CodingKey: String, Swift.CodingKey {
        case id
        case name
        case arabic
        case translation
        case target
        case visible
        case order
        case count
        case lastCompletedCount
        case lastCompletedAt
    }

    /// True when the count has reached a target it can reach (0 = no target).
    var hasTarget: Bool { target > 0 }

    /// The count as a fraction of the target, clamped to 0…1. 0 when there is no
    /// target, which is what makes the ring draw empty rather than full.
    var progress: Double {
        guard target > 0 else { return 0 }
        return min(max(Double(count) / Double(target), 0), 1)
    }

    /// How many repetitions are left, or nil when there is no target.
    var remaining: Int? {
        guard target > 0 else { return nil }
        return max(target - count, 0)
    }

    /// "12 / 33" — or "12" for a dhikr with no target, so a counter that cannot
    /// finish still reads honestly.
    var progressLabel: String {
        target > 0 ? "\(count) / \(target)" : "\(count)"
    }

    /// The default target offered for a new custom dhikr: the classic 33.
    static let defaultTarget = 33

    /// Memberwise initialiser, written out by hand.
    ///
    /// Swift's synthesised one is suppressed by the custom `init(from:)` below, and
    /// with it every call site's labels and defaults — so the alternative to spelling
    /// it out is spelling out ten arguments everywhere a dhikr is created.
    init(
        id: String,
        name: String,
        arabic: String = "",
        translation: String = "",
        target: Int = DhikrItem.defaultTarget,
        visible: Bool = true,
        order: Int = 0,
        count: Int = 0,
        lastCompletedCount: Int = 0,
        lastCompletedAt: Int64 = 0
    ) {
        self.id = id
        self.name = name
        self.arabic = arabic
        self.translation = translation
        self.target = target
        self.visible = visible
        self.order = order
        self.count = count
        self.lastCompletedCount = lastCompletedCount
        self.lastCompletedAt = lastCompletedAt
    }

    // MARK: - Decoding, tolerantly

    /// Decodes a stored dhikr, filling in a default for every field that is
    /// absent rather than rejecting the whole record.
    ///
    /// The Android codec's `optString` / `optInt` behaviour, and the reason it is
    /// worth hand-writing instead of taking the synthesised initialiser: a stored
    /// list written by an older build (or a half-finished write) is missing fields,
    /// and losing the user's 3000-tap count because one key is absent would be a
    /// data loss, not a validation error.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKey.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        arabic = try container.decodeIfPresent(String.self, forKey: .arabic) ?? ""
        translation = try container.decodeIfPresent(String.self, forKey: .translation) ?? ""
        target = try container.decodeIfPresent(Int.self, forKey: .target) ?? DhikrItem.defaultTarget
        visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
        lastCompletedCount = try container.decodeIfPresent(Int.self, forKey: .lastCompletedCount) ?? 0
        lastCompletedAt = try container.decodeIfPresent(Int64.self, forKey: .lastCompletedAt) ?? 0
    }

    /// Encodes all ten fields, always — Android's `DhikrCodec.encode` writes every
    /// key even when its value is the default, so a reader of the JSON never has to
    /// know which build wrote it.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKey.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(arabic, forKey: .arabic)
        try container.encode(translation, forKey: .translation)
        try container.encode(target, forKey: .target)
        try container.encode(visible, forKey: .visible)
        try container.encode(order, forKey: .order)
        try container.encode(count, forKey: .count)
        try container.encode(lastCompletedCount, forKey: .lastCompletedCount)
        try container.encode(lastCompletedAt, forKey: .lastCompletedAt)
    }
}

import Foundation

/// Pure helpers for the Dhikr Counter: the built-in dhikr list, JSON
/// (de)serialisation, and every mutation of a `[DhikrItem]`.
///
/// The direct port of the Android `DhikrCodec`, kept free of `UserDefaults` for
/// the same reason Android keeps its own version free of `Context`: the whole
/// lifecycle — counting, completing, resetting, reordering — is unit-testable
/// without a device, and the store stays a thin wrapper over a value.
///
/// Every mutation is *functional*: it takes the current list and returns the new
/// one. The counter screen saves on every single tap, so there is no in-place
/// state to get out of step with what was persisted — the list that was returned
/// is the list that was saved.
enum DhikrCodec {

    /// The built-in dhikr, with the targets the Android app ships.
    ///
    /// Order is selection order; the targets follow the classic 33 / 33 / 34
    /// tasbih and the common counts for the longer phrases. Used on first launch
    /// and whenever the stored list is missing or yields nothing usable — which is
    /// why it returns a fresh value rather than a shared one: a caller that mutates
    /// the result must not be able to edit the defaults for everyone.
    static func defaults() -> [DhikrItem] {
        [
            DhikrItem(
                id: "subhanallah",
                name: "SubhanAllah",
                arabic: "سُبْحَانَ ٱللَّٰهِ",
                translation: "Glory be to Allah",
                target: 33,
                order: 0
            ),
            DhikrItem(
                id: "alhamdulillah",
                name: "Alhamdulillah",
                arabic: "ٱلْحَمْدُ لِلَّٰهِ",
                translation: "Praise be to Allah",
                target: 33,
                order: 1
            ),
            DhikrItem(
                id: "allahu-akbar",
                name: "Allahu Akbar",
                arabic: "ٱللَّٰهُ أَكْبَرُ",
                translation: "Allah is the Greatest",
                target: 34,
                order: 2
            ),
            DhikrItem(
                id: "la-ilaha-illallah",
                name: "La ilaha illallah",
                arabic: "لَا إِلَٰهَ إِلَّا ٱللَّٰهُ",
                translation: "There is no god but Allah",
                target: 100,
                order: 3
            ),
            DhikrItem(
                id: "astaghfirullah",
                name: "Astaghfirullah",
                arabic: "أَسْتَغْفِرُ ٱللَّٰهَ",
                translation: "I seek forgiveness from Allah",
                target: 100,
                order: 4
            ),
            DhikrItem(
                id: "salawat",
                name: "Salawat",
                arabic: "ٱللَّٰهُمَّ صَلِّ عَلَىٰ مُحَمَّدٍ",
                translation: "O Allah, send blessings upon Muhammad",
                target: 100,
                order: 5
            ),
        ]
    }

    /// Ids of the built-ins, so a caller can tell "the user's own dhikr" from a
    /// shipped one without string-comparing against each name.
    static var builtInIds: Set<String> { Set(defaults().map(\.id)) }

    // MARK: - Persistence

    /// JSON-encodes the list, in the order given (the caller decides the order;
    /// `saveItems` re-indexes first).
    ///
    /// A list that cannot be encoded encodes as `"[]"` rather than throwing. The
    /// caller is a screen that has just changed something the user is looking at, so
    /// the only useful failure mode there is "save what can be saved"; throwing
    /// would leave the UI and the disk disagreeing.
    static func encode(_ items: [DhikrItem]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        guard let data = try? encoder.encode(items) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Decodes persisted JSON, skipping unreadable records and coercing the
    /// counts, as the Android codec does.
    ///
    /// An empty array means "nothing usable", which the store reads as "fall back
    /// to the built-ins". A single bad *record* is skipped rather than taking the
    /// whole list with it: the counts in that JSON are the user's, and a list that
    /// loses five phrases because the sixth was written badly is not a recovery.
    static func decode(_ json: String?) -> [DhikrItem] {
        guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        guard let data = json.data(using: .utf8) else { return [] }
        guard let salvaged = try? JSONDecoder().decode([SalvagedDhikr].self, from: data) else {
            return []
        }
        return salvaged
            .compactMap(\.item)
            .filter { !$0.id.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { item in
                var item = item
                item.target = max(item.target, 0)
                item.count = max(item.count, 0)
                item.lastCompletedCount = max(item.lastCompletedCount, 0)
                item.lastCompletedAt = max(item.lastCompletedAt, 0)
                return item
            }
    }

    /// One record of a stored list, decoded on its own so a single unreadable
    /// entry cannot fail the whole array.
    ///
    /// Swift has no per-element `catch` inside a decoding pass the way Android's
    /// loop has one inside `try`; this wrapper is that `catch`, in type form.
    private struct SalvagedDhikr: Decodable {
        let item: DhikrItem?

        init(from decoder: Decoder) throws {
            item = try? DhikrItem(from: decoder)
        }
    }

    // MARK: - Read helpers

    /// The list in `order` — the canonical stored order, and what the pager shows.
    ///
    /// Sorted with the original position as a tie-break, because `sorted(by:)` in
    /// Swift is not stable and two dhikr sharing an `order` (a hand-edited store,
    /// or a bug) would otherwise reshuffle between launches. Android's `sortedBy`
    /// is stable, so this is also what keeps the two platforms showing the same
    /// sequence for the same stored list.
    static func ordered(_ items: [DhikrItem]) -> [DhikrItem] {
        items.enumerated()
            .sorted { first, second in
                first.element.order == second.element.order
                    ? first.offset < second.offset
                    : first.element.order < second.element.order
            }
            .map(\.element)
    }

    /// Re-indexes `order` to match the *current* list positions.
    ///
    /// Deliberately does not sort. After a manual reorder the `order` values no
    /// longer match positions, and sorting here would silently undo the move the
    /// user just made; renumbering in place instead makes the list the source of
    /// truth while it is being edited.
    static func reindexed(_ items: [DhikrItem]) -> [DhikrItem] {
        items.enumerated().map { index, item in
            var item = item
            item.order = index
            return item
        }
    }

    /// The dhikr with `id`, or nil.
    static func item(_ items: [DhikrItem], _ id: String) -> DhikrItem? {
        items.first { $0.id == id }
    }

    // MARK: - Counting

    /// Increments the count of `id` by one. A no-op when `id` is not in the list.
    static func incremented(_ items: [DhikrItem], id: String) -> [DhikrItem] {
        items.map { item in
            guard item.id == id else { return item }
            var item = item
            item.count += 1
            return item
        }
    }

    /// Whether `id`'s count *just* crossed its target — the caller passes the list
    /// **after** the increment.
    ///
    /// The rule is the Android one: at or above the target now, and below it on the
    /// previous tap. That makes it fire exactly once per crossing — not on the tap
    /// that reaches 33, and not again on 34 — which is what stops the celebration
    /// and the "completed" record from repeating on every subsequent tap. False
    /// when there is no target, since nothing can be crossed.
    static func crossesTarget(_ items: [DhikrItem], id: String) -> Bool {
        guard let item = item(items, id) else { return false }
        return item.target > 0 && item.count >= item.target && item.count - 1 < item.target
    }

    /// Records a completed session for `id` — its count reached the target.
    static func markedCompleted(_ items: [DhikrItem], id: String, at: Int64) -> [DhikrItem] {
        items.map { item in
            guard item.id == id else { return item }
            var item = item
            item.lastCompletedCount = item.target
            item.lastCompletedAt = at
            return item
        }
    }

    /// Resets the count of `id`. The last-completed session is *kept*: it is
    /// history ("Last: 33"), not part of the current round.
    static func resetItem(_ items: [DhikrItem], id: String) -> [DhikrItem] {
        items.map { item in
            guard item.id == id else { return item }
            var item = item
            item.count = 0
            return item
        }
    }

    /// Sets the target of `id` (a negative target is stored as 0 = no target).
    static func withTarget(_ items: [DhikrItem], id: String, target: Int) -> [DhikrItem] {
        items.map { item in
            guard item.id == id else { return item }
            var item = item
            item.target = max(target, 0)
            return item
        }
    }

    /// Shows or hides `id`.
    ///
    /// Hiding never drops the count — a hidden dhikr stays in management, out of the
    /// pager, and can be switched back on with its progress intact.
    static func withVisibility(_ items: [DhikrItem], id: String, visible: Bool) -> [DhikrItem] {
        items.map { item in
            guard item.id == id else { return item }
            var item = item
            item.visible = visible
            return item
        }
    }

    // MARK: - Managing the list

    /// Moves `id` by `delta` positions (−1 up / +1 down) and re-indexes.
    ///
    /// A move that would leave the list is clamped to the ends rather than
    /// rejected, and a move that changes nothing returns the list untouched —
    /// both so the caller can wire "move up" to the top row without disabling it
    /// and still not corrupt the order.
    static func moved(_ items: [DhikrItem], id: String, delta: Int) -> [DhikrItem] {
        let ordered = reindexed(items)
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return items }
        let to = (from + delta).clamped(to: ordered.indices)
        guard to != from else { return items }
        var moved = ordered
        let item = moved.remove(at: from)
        moved.insert(item, at: to)
        return reindexed(moved)
    }

    /// Appends a new dhikr at the end of the order. It is always visible: a dhikr
    /// the user just created and cannot see would read as a failure.
    static func added(_ items: [DhikrItem], item newItem: DhikrItem) -> [DhikrItem] {
        let ordered = reindexed(items)
        var inserted = newItem
        inserted.order = ordered.count
        inserted.visible = true
        return reindexed(ordered + [inserted])
    }

    /// Replaces the dhikr with the same id — a rename or an edit.
    ///
    /// Only the four editable fields are taken from `item`: count, last-completed
    /// history, visibility and position belong to the stored record, so editing a
    /// phrase's spelling cannot reset the running count.
    static func updated(_ items: [DhikrItem], item newItem: DhikrItem) -> [DhikrItem] {
        items.map { existing in
            guard existing.id == newItem.id else { return existing }
            var existing = existing
            existing.name = newItem.name
            existing.arabic = newItem.arabic
            existing.translation = newItem.translation
            existing.target = max(newItem.target, 0)
            return existing
        }
    }

    /// Removes `id` entirely, re-indexing the rest. Its progress goes with it —
    /// which is exactly why the screen asks first.
    static func removed(_ items: [DhikrItem], id: String) -> [DhikrItem] {
        reindexed(items.filter { $0.id != id })
    }

    /// Resets every count and every completed-session record. The phrases, their
    /// targets and their visibility stay: this is "start the count again", not
    /// "throw away my setup".
    static func resetAllProgress(_ items: [DhikrItem]) -> [DhikrItem] {
        items.map { item in
            var item = item
            item.count = 0
            item.lastCompletedCount = 0
            item.lastCompletedAt = 0
            return item
        }
    }

    /// The next dhikr in the pager after `id`, wrapping around, or nil when there
    /// is nothing visible to count.
    ///
    /// Built here rather than in the screen because "swipe to the next one" has to
    /// agree with "which dhikr was selected" — both read the same ordered, visible
    /// list, so a hidden dhikr can never become the selection by accident.
    static func adjacent(_ items: [DhikrItem], id: String?, step: Int) -> DhikrItem? {
        let visible = ordered(items).filter(\.visible)
        guard !visible.isEmpty else { return nil }
        guard let id, let index = visible.firstIndex(where: { $0.id == id }) else {
            return visible.first
        }
        let count = visible.count
        let target = ((index + step) % count + count) % count
        return visible[target]
    }

    /// The dhikr the counter should open on: `selectedId` when it is still
    /// visible, otherwise the first visible one, otherwise nil.
    static func initialSelection(_ items: [DhikrItem], selectedId: String?) -> DhikrItem? {
        let visible = ordered(items).filter(\.visible)
        if let selectedId, let match = visible.first(where: { $0.id == selectedId }) {
            return match
        }
        return visible.first
    }
}

private extension Int {
    /// This value held inside `range`.
    ///
    /// The codec moves items by a delta the caller chooses, and `Array.insert` with
    /// an out-of-range index is a crash, so the clamp is the safety, not a nicety.
    func clamped(to range: Range<Int>) -> Int {
        guard !range.isEmpty else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound - 1)
    }
}

import Foundation
import Observation

/// The Dhikr Counter's behaviour: what a tap does, what a reset does, and what is
/// still selected after a relaunch.
///
/// The iOS equivalent of the state half of Android's `DhikrCounterScreen` — the
/// half that outlives the composable. Every rule it applies lives in `DhikrCodec`
/// (pure, and tested there); this type is the part that has state, persistence and
/// a notion of "now", so it is where a tap can be tested end to end without a
/// screen: tap 33 times, the session is recorded, exactly once.
///
/// `@MainActor` + `@Observable` because it feeds SwiftUI directly, and because a
/// tap is a main-thread event — the persistence behind it is a `UserDefaults`
/// write, which is cheap enough to do synchronously on the same thread. A counter
/// that saved asynchronously could lose the last few taps of a fast round.
@MainActor
@Observable
final class DhikrCounterModel {

    /// A session that has just been completed, for the screen to acknowledge.
    ///
    /// Returned rather than stored as a flag, so the acknowledgement cannot be
    /// forgotten and replayed: it exists for one tap, and the next tap produces a
    /// new one (or none).
    struct Completion: Equatable {
        let itemId: String
        let name: String
        let count: Int
        let at: Int64
    }

    /// Every dhikr with its counting state, in selection order.
    private(set) var items: [DhikrItem]

    /// The dhikr the counter is on. Nil only when every dhikr is hidden.
    private(set) var selectedId: String?

    /// The most recent completed session, cleared by `acknowledgeCompletion()`.
    private(set) var lastCompletion: Completion?

    /// The clock, injectable so a test can complete a session at a known instant
    /// rather than at whatever `Date()` returns mid-run.
    private let now: () -> Int64

    private let store: DhikrStore

    init(store: DhikrStore = DhikrStore(), now: @escaping () -> Int64 = DhikrCounterModel.systemNow) {
        self.store = store
        self.now = now
        let restored = store.items
        self.items = restored
        self.selectedId = DhikrCodec.initialSelection(restored, selectedId: store.selectedId)?.id
        // A selection that no longer exists (its dhikr was deleted or hidden) is
        // written back rather than left dangling, so the next launch does not have
        // to re-resolve it.
        store.selectedId = selectedId
    }

    /// Epoch milliseconds — the unit `lastCompletedAt` is stored in, and the one
    /// Android writes.
    static func systemNow() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - What is on screen

    /// The dhikr the counter is showing, or nil when there is nothing visible.
    var selected: DhikrItem? {
        guard let selectedId else { return nil }
        return DhikrCodec.item(items, selectedId)
    }

    /// The dhikr in the swipeable pager, in stored order.
    var visibleItems: [DhikrItem] { DhikrCodec.ordered(items).filter(\.visible) }

    /// Every dhikr, hidden ones included — the management list.
    var allItems: [DhikrItem] { DhikrCodec.ordered(items) }

    /// Whether the phone should vibrate on a tap.
    var vibrationEnabled: Bool {
        get { store.vibrationEnabled }
        set { store.vibrationEnabled = newValue }
    }

    /// The count to show for `id` — 0 for an id that is no longer in the list, so a
    /// stale row renders as empty rather than crashing.
    func count(of id: String) -> Int { DhikrCodec.item(items, id)?.count ?? 0 }

    /// The stored target of `id` (0 = no target).
    func target(of id: String) -> Int { DhikrCodec.item(items, id)?.target ?? 0 }

    /// The last completed session's count for `id`, or 0 when it never completed.
    func lastCompletedCount(of id: String) -> Int {
        DhikrCodec.item(items, id)?.lastCompletedCount ?? 0
    }

    // MARK: - Counting

    /// One tap on the counter.
    ///
    /// Increments the selected dhikr, and — only on the tap that reaches its
    /// target — records the completed session and returns it. The caller uses the
    /// return value to celebrate and to stop; everything else about the tap is
    /// already persisted.
    @discardableResult
    func tap() -> Completion? {
        guard let selectedId else { return nil }
        let incremented = DhikrCodec.incremented(items, id: selectedId)
        let crossed = DhikrCodec.crossesTarget(incremented, id: selectedId)
        let at = now()
        let updated = crossed
            ? DhikrCodec.markedCompleted(incremented, id: selectedId, at: at)
            : incremented
        persist(updated)

        guard crossed, let item = DhikrCodec.item(updated, selectedId) else { return nil }
        let completion = Completion(
            itemId: item.id,
            name: item.name,
            count: item.count,
            at: at
        )
        lastCompletion = completion
        return completion
    }

    /// Clears the pending completion once the screen has acknowledged it.
    func acknowledgeCompletion() {
        lastCompletion = nil
    }

    /// Resets the selected dhikr's count, keeping its completed-session history.
    func resetSelection() {
        guard let selectedId else { return }
        persist(DhikrCodec.resetItem(items, id: selectedId))
    }

    /// Resets every dhikr's count and history. Phrases, targets and visibility
    /// stay — this is "start again", not "forget my setup".
    func resetAllProgress() {
        persist(DhikrCodec.resetAllProgress(items))
        lastCompletion = nil
    }

    // MARK: - Moving between dhikr

    /// Selects `id`, if it exists and is visible.
    func select(id: String) {
        guard let item = DhikrCodec.item(items, id), item.visible else { return }
        selectedId = item.id
        store.selectedId = item.id
    }

    /// Swipes to the next (`step` = +1) or previous (−1) visible dhikr, wrapping
    /// around at the ends.
    func step(by step: Int) {
        guard let next = DhikrCodec.adjacent(items, id: selectedId, step: step) else { return }
        select(id: next.id)
    }

    // MARK: - Editing

    /// Sets the target of `id` (0 = no target). The running count is untouched:
    /// changing the goal posts does not send the count back to zero, and the next
    /// tap re-evaluates whether it crossed.
    func setTarget(_ target: Int, id: String) {
        persist(DhikrCodec.withTarget(items, id: id, target: target))
    }

    /// Shows or hides `id`. Hiding the selected dhikr moves the selection to the
    /// next visible one, so the counter is never left pointing at something the
    /// pager cannot reach.
    func setVisible(_ visible: Bool, id: String) {
        persist(DhikrCodec.withVisibility(items, id: id, visible: visible))
        if !visible, selectedId == id {
            selectedId = DhikrCodec.initialSelection(items, selectedId: nil)?.id
            store.selectedId = selectedId
        }
    }

    /// Moves `id` by `delta` positions in the list (−1 up / +1 down).
    func move(id: String, by delta: Int) {
        persist(DhikrCodec.moved(items, id: id, delta: delta))
    }

    /// Moves `id` to a specific position, which is what a drag-and-drop
    /// reorder hands over. Expressed as a delta so it goes through the same clamp.
    func move(id: String, toIndex index: Int) {
        guard let current = allItems.firstIndex(where: { $0.id == id }) else { return }
        move(id: id, by: index - current)
    }

    /// Adds a dhikr and returns its id — `"custom-<uuid>"`, matching the Android
    /// naming so the two platforms' records are recognisable as the same kind.
    @discardableResult
    func add(name: String, arabic: String = "", translation: String = "", target: Int = DhikrItem.defaultTarget) -> String {
        let id = "custom-\(UUID().uuidString.lowercased())"
        let item = DhikrItem(
            id: id,
            name: name.trimmed,
            arabic: arabic.trimmed,
            translation: translation.trimmed,
            target: max(target, 0),
            visible: true
        )
        persist(DhikrCodec.added(items, item: item))
        return id
    }

    /// Applies an edit to the dhikr with the same id. Only the phrase fields and
    /// the target are taken from `item`; the count and the history stay as stored.
    func update(_ item: DhikrItem) {
        persist(DhikrCodec.updated(items, item: item))
    }

    /// Renames a dhikr, keeping everything else about it.
    func rename(id: String, name: String) {
        guard var item = DhikrCodec.item(items, id) else { return }
        item.name = name.trimmed
        update(item)
    }

    /// Removes a dhikr and its progress. The selection falls back to the first
    /// visible dhikr when the removed one was selected.
    func remove(id: String) {
        let wasSelected = selectedId == id
        persist(DhikrCodec.removed(items, id: id))
        if wasSelected {
            selectedId = DhikrCodec.initialSelection(items, selectedId: nil)?.id
            store.selectedId = selectedId
        }
    }

    /// Forgets everything: the built-in list, no selection, vibration back on.
    func resetEverything() {
        store.reset()
        items = store.items
        selectedId = nil
        store.selectedId = nil
        lastCompletion = nil
    }

    /// Re-reads the store. Used after another surface (a widget's "count" action,
    /// or a second screen) has written to it.
    func reload() {
        let restored = store.items
        items = restored
        selectedId = DhikrCodec.initialSelection(restored, selectedId: store.selectedId)?.id
        store.selectedId = selectedId
    }

    // MARK: - Persistence

    /// Stores the new list and adopts it. Writes through immediately rather than
    /// batching: the counter's whole value is that a count tapped on a moving bus
    /// is still there afterwards.
    private func persist(_ updated: [DhikrItem]) {
        items = updated
        store.saveItems(updated)
    }
}

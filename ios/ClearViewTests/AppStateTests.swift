import XCTest
@testable import ClearView

@MainActor
final class AppStateTests: XCTestCase {
    func testTaskCompletionAndArchiveSurviveReload() {
        let suite = "AppStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TodoStore(defaults: defaults)
        let model = TodoScreenModel(store: store)
        let item = TodoItem(id: "read", title: "Read Quran", type: .permanent, startDateEpochDay: model.today)
        model.save(item)
        model.toggle(item)
        let restored = TodoScreenModel(store: store)
        XCTAssertEqual(restored.completedToday, 1)
        XCTAssertNotNil(restored.items.first?.completions[model.today])
        restored.remove(restored.items[0])
        let archived = TodoScreenModel(store: store)
        XCTAssertTrue(archived.visible.isEmpty)
        XCTAssertNotNil(archived.items.first?.completions[model.today])
    }

    func testMediaLinksValidateAndPersistWithoutDuplicates() {
        let suite = "MediaStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MediaLibrary(defaults: defaults)
        XCTAssertFalse(model.addLink(title: "Invalid", url: "javascript:alert(1)"))
        XCTAssertFalse(model.addLink(title: "Invalid", url: "not a URL"))
        XCTAssertTrue(model.addLink(title: "A good watch", url: "https://youtu.be/abcdefghijk"))
        XCTAssertTrue(model.addLink(title: "Duplicate", url: "https://youtu.be/abcdefghijk"))
        let restored = MediaLibrary(defaults: defaults)
        XCTAssertEqual(restored.state.saved.count, 1)
        XCTAssertEqual(restored.state.saved.first?.title, "A good watch")
    }

    func testDeepLinksOnlyRouteSupportedChannels() {
        let router = Router()
        router.open(URL(string: "https://example.com/c/not-clearview")!)
        XCTAssertNil(router.channelSlug)
        router.open(URL(string: "clearview://goodpost/channel/clearview")!)
        XCTAssertEqual(router.selectedTab, .goodPost)
        XCTAssertEqual(router.channelSlug, "clearview")
        router.open(URL(string: "https://clearview-1neb.onrender.com/c/temp?v=123")!)
        XCTAssertEqual(router.channelSlug, "temp")
    }
}

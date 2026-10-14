import SwiftUI

@main
struct ClearViewApp: App {
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) private var notificationDelegate

    init() {
        Self.resetPreferencesIfAsked()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }

    /// Clears the app's stored preferences when a UI test asks for a clean slate.
    ///
    /// Why this exists: several screens remember what the reader chose — the Arabic
    /// text scale, the reading positions, the bookmarks, the Islamic-date
    /// adjustment — and a UI test that leaves one of them at an extreme changes the
    /// *layout* for the next run. That is not a hypothetical: growing the Arabic
    /// text to its ceiling in one test left the surah reader's rows twice as tall,
    /// so the next run could no longer see the last ayah of Al-Faatiha without
    /// scrolling, and reported it as a rendering failure.
    ///
    /// Two arguments, not one, on purpose. `--uitesting` alone is used by tests
    /// that *depend* on persistence (a task surviving a relaunch, a reading
    /// position surviving a relaunch), so the reset has to be something a test asks
    /// for explicitly rather than something being in test mode implies.
    ///
    /// Only preferences are cleared — not the downloaded Quran editions, which are
    /// files rather than defaults and whose re-download would add minutes to every
    /// run for no extra coverage.
    private static func resetPreferencesIfAsked() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--uitesting") else { return }
        if arguments.contains("--reset-preferences") {
            let domain = Bundle.main.bundleIdentifier ?? "com.muddassir.clearview"
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        seedReadingPositionIfAsked(arguments)
        if let fixture = ProcessInfo.processInfo.environment["CLEARVIEW_MEDIA_FIXTURE"],
           let data = fixture.data(using: .utf8), (try? JSONDecoder().decode(MediaLibraryState.self, from: data)) != nil {
            UserDefaults.standard.set(data, forKey: "media.library.v1")
        }
    }

    /// Records a reading position before the app opens, when a UI test asks for
    /// one: `--seed-reading-position 2:13`.
    ///
    /// This exists to separate two failures that look identical on screen: "the
    /// reader did not save where I stopped" and "the reader did not go back there".
    /// Seeding the store from outside means a test of the *restore* is not also a
    /// test of the save, and a failure names one of them instead of both. It writes
    /// the same preference the reader writes, in the same shared `"surah:ayah"`
    /// shape, so it cannot pass against a rule the real store does not use.
    private static func seedReadingPositionIfAsked(_ arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "--seed-reading-position"),
              arguments.indices.contains(flag + 1) else { return }
        let entry = arguments[flag + 1]
        guard entry.range(of: #"^\d+:\d+$"#, options: .regularExpression) != nil else { return }
        UserDefaults.standard.set([entry], forKey: "reading_positions")
    }
}

import SwiftUI

/// ClearView for iOS.
///
/// The shell is the four-tab structure the Android app uses. The features behind
/// the tabs are being migrated one slice at a time; the Quran tab is the first,
/// which is why it is the only one that does real work today.
@main
struct ClearViewApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

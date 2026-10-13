# ClearView for iOS

A native SwiftUI app for iPhone and iPad (iOS 18+), using the ClearView Android app and supplied screen recording as the design reference. Four tabs share an adaptive teal palette, native navigation, searchable lists, rounded cards, sheets, and persistent preferences.

## Run

1. Install Xcode 16.4 or newer and JDK 21. Select the full Xcode installation in Xcode → Settings → Locations → Command Line Tools.
2. Open `ios/ClearView.xcodeproj` and select the **ClearView** scheme and an iPhone simulator.
3. Build and run. The first build downloads Gradle/Kotlin dependencies and builds the `SharedKotlin` framework automatically. No Android SDK is needed.
4. For a physical device, select your development team under Signing & Capabilities. The default bundle identifier is `com.muddassir.clearview`.

## Screens and behavior

| Area | Included |
| --- | --- |
| Quran | Verse-first home, Arabic and English, previous/next/random verse, copy, Alafasy recitation, Hijri date, searchable 114-surah library, reading position, bookmarks, text sizing, and reminder settings |
| Media | Live curated directory, YouTube RSS subscriptions, Shorts filter, search, custom channel URLs, saved web links, recently opened videos, local playlists, share and remove actions |
| Good Post | Live channel catalogue, categories, discovery, verified badges, channel posts, images/video/documents, pagination, cached reads, follows, reactions, local bookmarks, and channel deep links |
| Publisher studio | Creator email/password registration and login, first-channel creation, administrator login, channel list, text/link/file publishing, attachment upload, post deletion, and sign-out |
| More | Todo creation/editing/completion, temporary and daily schedules, priority/sort/search/history, weekly completion chart, daily target, persistent Dhikr counter with targets/custom phrases/haptics, focus countdown, light/dark/system appearance |

Empty libraries start empty: the app never invents personal tasks, watch progress, followers, or posts. Use **Media → Explore** to add channels, or **+** to save a link. Good Post reads public data immediately and falls back to cached content with a visible retry message when offline.

## Backend and identity

- Backend: `https://clearview-1neb.onrender.com`, configured in `ios/Info.plist` under `GoodPostBaseURL`.
- Firebase uses the **public client API key** already published in the Android repository's `app/google-services.json`, project `clearview-28413`. It is not an administrator credential. Authentication uses Firebase's HTTPS REST API, so no Firebase SDK or package installation is required. Check Firebase key restrictions if the project restricts clients to Android; iOS requests include `X-Ios-Bundle-Identifier`.
- Anonymous reader refresh credentials and publisher sessions use separate device-only Keychain entries. Access tokens remain in memory; passwords are cleared after sign-in. Anonymous reading still works if identity services are unavailable; authenticated failures remain visible and do not become fake follows.
- Creator registration depends on the existing Firebase project's email/password provider. No production accounts, posts, reactions, or follows are created as part of the test suite. UI tests launch with `--uitesting`, disabling reader identity creation.
- `clearview://goodpost/channel/<slug>` is registered as an app URL scheme. HTTPS share links can also be routed by the app, but automatic Universal Link handoff requires the website's association file and an Apple team entitlement; it is not claimed here.

## Platform boundaries

Android accessibility-based blocking, overlays, app locking, device administration, uninstall protection, and the Block/Protection tab are intentionally excluded. The focus timer schedules a local notification; it does not lock the device. Instagram and X profiles/links open in the in-app browser. YouTube videos open an embedded WKWebView IFrame API player, including real play/pause, ten-second seeking, mute, supported playback speeds, sharing, and local playlist selection. Actual playback progress is saved every five seconds and on pause/exit; live broadcasts are not marked watched. Imported YouTube playlists, Google provider sign-in, APNs channel push, and live-broadcast aggregation are not included in this UI-focused release. Local playlists and email/password creator accounts are implemented.

### YouTube player boundaries

The iframe retains YouTube's own visible player and native controls, with the app's action row, timeline, and transport controls below it. It uses the bundle-ID HTTPS origin as the local HTML base URL and widget referrer, following YouTube's embedded-player identity guidance. Playback state, duration, mute status, and available rates come from the IFrame API rather than optimistic UI state. It requests autoplay when the video page opens; a user may need to tap Play inside the iframe if YouTube blocks scripted playback. Videos whose owners prohibit embedding show an explicit error; they are not silently redirected to an external app.

The Audio mode and Download Audio buttons preserve Android's positions but explain the missing capability: the official iframe does not expose audio extraction or downloads, and this app does not offer hidden/background YouTube playback. Leaving the page or backgrounding the app pauses playback. Speed choices are limited to rates reported by YouTube, not Android's arbitrary 0.25–5× range. Device import remains an explicitly unavailable action, not a fabricated successful import.

`YouTubePlayerTests` exercises HTML configuration, player events, JavaScript command delivery, progress persistence, and playlist deduplication. `MediaPlayerUITests` captures controls and playlist/menu workflows on iPhone 16 Pro and iPhone SE through CI. Its real-network playback smoke test is explicitly skipped if YouTube cannot load/play on the runner; such a skip is not evidence of successful playback and requires an iPhone follow-up.

Quran editions download on first use, then read from cache. Recitation and external media require a connection. While iOS suspends the app, repeating Quran reminders show the last loaded verse; the verse refreshes on the next app visit. Store distribution, APNs, Universal Links, and Firebase project configuration require the project's Apple/Firebase owner setup.

## Validation

```sh
./gradlew -p shared jvmTest
xcodebuild test -project ios/ClearView.xcodeproj -scheme ClearView \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO
```

`.github/workflows/ios.yml` builds the actual app on a macOS runner, runs shared tests and iOS unit/UI tests, and uploads the `.xcresult`, build log, and screenshots. Regression tests cover task persistence/archive behavior, media validation/deduplication, deep-link routing, tab navigation, Dhikr interaction, playlist creation, Quran discovery/search, library migration, and feed filters. Quran/bookmark tests enter **Search Quran → Surah** before exercising the reader. Targeted discovery checks also run on a compact available iPhone. See `UI_PARITY_AUDIT.md` for the Android reference map and remaining phases.

Use the workflow's screenshot artifacts to review the Quran, Media, Good Post, More, Todo, and Dhikr screens. Never run publisher write tests against the production backend; use a staging deployment and dedicated account for authenticated end-to-end testing.

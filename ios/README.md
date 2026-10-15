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
| Media | Live curated directory, YouTube RSS subscriptions, Instagram and X profile feeds, Shorts filter, search, custom channel URLs, saved web links, recently opened videos, local playlists, share and remove actions, and offline audio (listen mode + downloads) |
| Good Post | Live channel catalogue, categories, discovery, verified badges, channel posts, images/video/documents, pagination, cached reads, follows, reactions, local bookmarks, and channel deep links |
| Publisher studio | Creator email/password registration and login, first-channel creation, administrator login, channel list, text/link/file publishing, attachment upload, post deletion, and sign-out |
| More | Todo creation/editing/completion, temporary and daily schedules, priority/sort/search/history, weekly completion chart, daily target, persistent Dhikr counter with targets/custom phrases/haptics, focus countdown, light/dark/system appearance |

Empty libraries start empty: the app never invents personal tasks, watch progress, followers, or posts. Use **Media → Explore** to add channels, or **+** to save a link. Good Post reads public data immediately and falls back to cached content with a visible retry message when offline.

### Quran reader controls

A surah opens as a vertical verse list in Arabic, with an Arabic/English toggle and the bundled IndoPak font. The top controls switch language, enter or exit full screen, search either language or an ayah reference, reveal a compact text-size slider, and offer Slow/Medium/Fast auto-scroll. Full screen hides navigation, status, and tab bars while retaining the reading controls. Text size persists and applies to either language.

Auto-scroll moves continuously, stops at the document end, and pauses on touch-down anywhere in the reading area, manual scrolling, opening another reading control, leaving the page, or backgrounding. A verse tap reveals Copy and Listen; Copy includes the selected language and verse reference, and Listen streams that ayah's Alafasy recitation with pause/resume/retry/stop controls. Surah stars remain in the navigation bar and verse bookmarks are available on long press. Search results do not replace the full surah or save a filtered reading position.

Portable auto-scroll motion checks and Swift syntax checks pass locally. New unit/UI coverage checks search, copying, text-size persistence, scroll lifecycle, language/full-screen controls, and tap-to-pause. Xcode, XCTest, and an iOS simulator are unavailable on this machine, so the iOS test suite, actual playback, and visual layout still require an iPhone or CI run.

### Good Post reference UI

Good Post uses flat custom headers and an anchored overflow menu to follow the supplied Android screenshots. Channel rows and the Explore header use compact Android spacing; post text, previews, and the compose field use Android's bundled JetBrains Mono font. Channel updates use the Android repository's `goodpost_chat_bg.jpg` wallpaper and its olive bubble/sage timestamp colours. Updates read oldest to newest, with date separators and the newest update at the bottom; earlier pages load above them. The channel information page remains reachable through the compact avatar/name header, while Follow and Save remain available in the channel menu. The publisher composer retains its draft and attachment workflow behind the attachment and pencil controls. Advertisement management is offered only to super administrators.

The channel feed hides the app tab bar and reserves only the actual composer height, with zero inset spacing and no bottom content padding. Offline notices stay below the channel header. Post actions (copy, star, share, and reactions) are available on long press; the metadata row shows the timestamp, a view count only when positive, and a star only when saved. Extra iOS destinations remain under More options in the home menu.

Swift syntax parsing, plist validation, font registration inspection, and diff checks pass locally. Xcode and the iOS simulator are unavailable on this machine, so compilation and visual parity still need verification on an iPhone. The tab-navigation UI check now recognizes Good Post's custom header. Review home and overflow, Explore, a channel with text/media updates, earlier-page loading, search, follow/save, and the composer both with and without the keyboard.

### More reference UI

More follows Android's `MoreTab.kt`: a compact title/subtitle, appearance and settings actions, three Tools cards, and a highlighted Protection destination. Settings and the phone-limit countdown open as sheets. Quran refresh intervals and notifications use the existing reminder model; the reading-size slider updates the existing Arabic text preference rather than pretending to resize iOS alerts.

Todo uses the reference's Today/Upcoming/Completed count chips, compact task rows, floating add button, and weekly productivity card. Additional filters, task editing, sort, and the daily target remain available. Weekly figures come from the user's existing tasks and completions; the extended Android annual heatmap/monthly calendar is not part of this UI slice. Dhikr retains its stored counts, targets, and haptics with the Android title order and an adaptive counter ring.

Protection is an explicitly unconnected overview, not a working device-blocking service. Phone limits retain the existing cancellable, minute-based iOS reminder timer; Android's device locking and second-level duration input are not implemented. Channel/media notification preferences are also not connected. No tests, builds, lint, or simulator checks were run for this refinement at the user's request. Manually review More and its sheets, task creation/completion/filtering, Dhikr counting, and timer start/end before merging.

## Backend and identity

- Backend: `https://clearview-1neb.onrender.com`, configured in `ios/Info.plist` under `GoodPostBaseURL`.
- Firebase uses the **public client API key** already published in the Android repository's `app/google-services.json`, project `clearview-28413`. It is not an administrator credential. Authentication uses Firebase's HTTPS REST API, so no Firebase SDK or package installation is required. Check Firebase key restrictions if the project restricts clients to Android; iOS requests include `X-Ios-Bundle-Identifier`.
- Anonymous reader refresh credentials and publisher sessions use separate device-only Keychain entries. Access tokens remain in memory; passwords are cleared after sign-in. Anonymous reading still works if identity services are unavailable; authenticated failures remain visible and do not become fake follows.
- Creator registration depends on the existing Firebase project's email/password provider. No production accounts, posts, reactions, or follows are created as part of the test suite. UI tests launch with `--uitesting`, disabling reader identity creation.
- `clearview://goodpost/channel/<slug>` is registered as an app URL scheme. HTTPS share links can also be routed by the app, but automatic Universal Link handoff requires the website's association file and an Apple team entitlement; it is not claimed here.

## Platform boundaries

Android accessibility-based blocking, overlays, app locking, device administration, uninstall protection, and the Block/Protection tab are intentionally excluded. The focus timer schedules a local notification; it does not lock the device. Instagram profiles are read from Instagram's own login-free `/<handle>/embed/` page, and X profiles from the public syndication endpoint; both rate-limit per IP, so a `429` stands that source down for ten minutes rather than retrying into the same wall. The X endpoint now serves a Next.js page, so its posts are read as JSON from `__NEXT_DATA__` (`props.pageProps.timeline.entries[].content.tweet`) rather than scraped — the older markup scanner, which assumed one post id per post, produced 135 phantom posts from a 101-entry timeline because retweets, quoted posts and the author each carry their own `id_str`. Media is read from `extended_entities.media[]` when present and otherwise `entities.media[]`; playable attachments are preferred over a leading still image. The markup scanner is kept only as a fallback for the legacy page shape. Instagram exposes only its newest few posts per read, so those feeds accumulate across refreshes instead of being replaced. The RSS-Bridge and Atom fallbacks that Android keeps as best-effort second sources are not ported — Android measures them as already dead. YouTube videos open an embedded WKWebView IFrame API player, including real play/pause, ten-second seeking, mute, supported playback speeds, sharing, and local playlist selection. Actual playback progress is saved every five seconds and on pause/exit; live broadcasts are not marked watched. Imported YouTube playlists, Google provider sign-in, APNs channel push, and live-broadcast aggregation are not included in this UI-focused release. Local playlists and email/password creator accounts are implemented.

### Instagram and X profile feeds

Fetched items use the subscription's actual ID, whether it came from the directory or a manually added profile. Previously stored `ig_<handle>` / `x_<handle>` IDs are migrated across feed, saved items, recent items, playlists, and hidden-channel preferences. Profile refresh persists the source's display name and avatar; X reads the requested author's timeline metadata and falls back to its public avatar endpoint. Profile filters default to all dates and all watch states independently of All Feed.

Reels appear in Shorts, long Instagram/X videos in Videos, and photos/carousels/text in Posts. Explicit Instagram product type takes precedence over duration, so a long Reel remains a Reel and a carousel containing a video remains a post. X videos use the available progressive MP4, while text/photo tweets remain posts. Non-YouTube videos open a native player. Instagram resolves its public embed's rendered video element, matching Android's approach. Audio mode plays the resolved media without a video view; offline downloads export its audio to M4A before publishing the manifest entry. Public/private/deleted content and rate limits still determine what the service makes available.

Local verification on 2026-10-15: Instagram returned six real items plus a profile avatar; X's avatar endpoint answered, but its timeline returned HTTP 429. YouTube returned HTTP 206 audio bytes, and a complete 3,449,447-byte download passed AVFoundation's playable-file check. Core regression methods are also executed with portable assertions against actual model/parser/downloader source because XCTest is unavailable locally. Xcode, iPhone UI, lock-screen/background playback, and Instagram's WebKit-to-native handoff still require device or CI verification.

### YouTube player boundaries

The iframe retains YouTube's own visible player and native controls, with the app's action row, timeline, and transport controls below it. It uses the bundle-ID HTTPS origin as the local HTML base URL and widget referrer, following YouTube's embedded-player identity guidance. Playback state, duration, mute status, and available rates come from the IFrame API rather than optimistic UI state. It requests autoplay when the video page opens; a user may need to tap Play inside the iframe if YouTube blocks scripted playback. Videos whose owners prohibit embedding show an explicit error; they are not silently redirected to an external app.

The embedded iframe remains the watching player. Audio mode pauses it and resumes audio at its actual current position. Android uses NewPipeExtractor; iOS now uses the native [YouTubeKit](https://github.com/alexeichhorn/YouTubeKit) package, pinned to 0.4.9, for on-device signature and throttling transforms, with direct player clients retained as a fallback. Only local extraction is enabled. Selection retains the original language and requires a direct AAC/MP4 stream; unsupported WebM is rejected rather than saved as an unplayable success. The same extractor serves Audio mode and Download Audio. Public extraction can still be blocked by the service or this device's network; failures are shown to the reader.

Audio mode resolves that URL and hands it to `AudioPlaybackController`, an `AVPlayer` behind an active `.playback` audio session with the `audio` background mode declared, so playback survives backgrounding and the screen locking, with lock-screen and Control Center controls from `MPRemoteCommandCenter`. Download Audio streams to a `.part` file that is renamed only on success (an interrupted download can never look complete), using parallel ranged GETs when the server honours them and a single stream otherwise. Ignored ranges fall back to one transfer; every response range, received byte count, and final size must agree before publication. Missing downloaded files can be fetched again. Failed streams offer Retry audio, which resolves a fresh stream while retaining the position and sleep timer. Speed choices are limited to rates that play correctly, not Android's arbitrary 0.25–5× range. Device import remains an explicitly unavailable action, not a fabricated successful import.

`YouTubePlayerTests` exercises HTML configuration, player events, JavaScript command delivery, progress persistence, and playlist deduplication. `MediaPlayerUITests` captures controls and playlist/menu workflows on iPhone 16 Pro and iPhone SE through CI. Its real-network playback smoke test is explicitly skipped if YouTube cannot load/play on the runner; such a skip is not evidence of successful playback and requires an iPhone follow-up.

Quran editions download on first use, then read from cache. Recitation and external media require a connection. While iOS suspends the app, repeating Quran reminders show the last loaded verse; the verse refreshes on the next app visit. Store distribution, APNs, Universal Links, and Firebase project configuration require the project's Apple/Firebase owner setup.

## Validation

```sh
./gradlew -p shared jvmTest
xcodebuild test -project ios/ClearView.xcodeproj -scheme ClearView \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO
```

`.github/workflows/ios.yml` builds the actual app on a macOS runner, runs shared tests and iOS unit/UI tests, and uploads the `.xcresult`, build log, and screenshots. Regression tests cover task persistence/archive behavior, media validation/deduplication, deep-link routing, tab navigation, Dhikr interaction, playlist creation, Quran discovery/search, library migration, and feed filters. Quran/bookmark tests enter **Search Quran → Surah** before exercising the reader. Targeted discovery checks also run on a compact available iPhone. See `UI_PARITY_AUDIT.md` for the Android reference map and remaining phases.

Audio extraction is the one thing unit tests cannot prove: YouTube refuses innertube requests from datacenter addresses, so `MediaAudioLiveTests` hits the real service and is therefore skipped unless asked for, and must be run on a physical device where the request comes from the phone's own IP.

```sh
xcodebuild test -project ios/ClearView.xcodeproj -scheme ClearView \
  -destination 'id=<connected-device-udid>' \
  -only-testing:ClearViewTests/MediaAudioLiveTests TEST_RUNNER_CLEARVIEW_LIVE_AUDIO=1
```

Use the workflow's screenshot artifacts to review the Quran, Media, Good Post, More, Todo, and Dhikr screens. Never run publisher write tests against the production backend; use a staging deployment and dedicated account for authenticated end-to-end testing.

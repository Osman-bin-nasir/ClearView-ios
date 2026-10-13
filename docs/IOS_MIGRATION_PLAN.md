# ClearView — Android → iOS Migration: Repository Audit and Implementation Plan

**Status:** planning only. No iOS code was written, no Android code was changed, no
backend was touched, nothing was committed or pushed.
**Audit date:** 13 October 2026.
**Audited revision:** `9524796` (`main`, "v5 quran fixed"). Working tree was clean.
**Auditor:** Buffy (Freebuff), acting as cross-platform architect.
**Deliverable:** this file (`docs/IOS_MIGRATION_PLAN.md`). It did not previously exist.

---

## 0. How to read this document

Every claim below is tagged with how it was established:

| Tag | Meaning |
|---|---|
| **[verified]** | Confirmed by reading the file named in the same row/sentence. |
| **[inferred]** | Derived from evidence (config, imports, call sites) but not executed on a device. |
| **[assumed]** | A choice or environment fact I could not verify from the repository. |
| **[uncertain]** | A platform or distribution fact that cannot be settled without Apple or a device test. |

Wherever this plan converts Android behaviour to iOS, the distinction the brief
asks for is kept explicit: **reproducing a screen** (a SwiftUI view that looks the
same) is almost always possible; **reproducing the behaviour behind that screen**
often is not, and is called out as such.

Measured facts about the codebase live in §2 and §3. Feature behaviour lives in
§6. Platform limits live in §9. Nothing in this report was validated by building
or running the app; the Android project was **not** compiled, installed or tested
during this audit.

---

## 1. Executive summary and recommended strategy

**ClearView is not one app. It is five products sharing a shell.**

1. A **content-blocking / parental-control tool** built on Android's
   `AccessibilityService`, screen-text extraction, keyword matching, a block
   overlay, Device Admin, and a phone-usage countdown — the original product, and
   the part the Play listing leads with. **[verified]** (§2, §6.1)
2. A **Quran app** with a daily verse, full offline text, bookmarks, reading
   positions, a Dhikr counter, a home-screen widget and an Islamic-date helper.
   **[verified]** (§6.4)
3. A **media hub** — YouTube RSS feeds, Instagram, X, Shorts, Live broadcast,
   offline audio download and a background audio player. **[verified]** (§6.5)
4. A **Good Post / WhatsApp-Channels-style publishing product** with its own
   Node/Express + Neon + S3 backend, Firebase identity, FCM push, ads, a channel
   directory and an admin surface. **[verified]** (§6.7, §8)
5. A **productivity suite** — to-dos (with history, attempted/time behaviours,
   alarms, snooze), a progress-card generator, and a screen-time "Phone Limit".
   **[verified]** (§6.6)

**The recommended architecture is Option D: a Kotlin Multiplatform *domain* module
plus a fully native SwiftUI application, with the existing backend reused
unchanged.** Concretely:

- **Shared (KMP, `commonMain`):** the pure domain *rules* that already exist and
  are already unit-tested — the keyword-matching/normalisation engine, media feed
  models and filter logic, URL/playlist parsers, todo stats and codec rules, Quran
  text integrity, Good Post text formatting and error vocabulary — plus the
  **HTTP API contracts** (typed calls to the existing server endpoints).
- **Native SwiftUI (iOS):** 100 % of the UI, all navigation, and every
  platform-bound service (Screen Time / ManagedSettings shields, Safari Content
  Blocker extension, WidgetKit widgets, AVPlayer audio/video, UNUserNotificationCenter
  alarms, Keychain, FCM via APNs).
- **Android stays as it is** and is migrated toward the same shared module only
  when it is cheap to do so; the iOS app does not depend on Android being refactored
  first.

**Why not Compose Multiplatform (Option B):** the UI is the majority of the code
(~50 % of lines live under `*/ui/*`, and ~58 % of lines import `androidx.compose`;
§3.1), it is written against **Material3, `androidx.compose.material.icons.extended`,
platform `WebView`/`android.media.MediaPlayer`/`android.view.WindowManager` and
Android lifecycle**, and there is **no Navigation-Compose** — navigation is one
hand-rolled `when(selectedTab)` state machine inside a single Activity. Sharing
that through Compose Multiplatform would mean rewriting most of it against
Compose-MP-compatible equivalents anyway, *and* shipping a non-native iOS feel,
*and* losing the platform integrations that are the product (Screen Time, Safari
Content Blocker, WidgetKit, background audio, lock-screen alarms). It buys the
least reuse for the most risk.

**Why not a pure Swift rewrite (Option C):** it throws away ~10 000 lines of
Android-free, unit-tested Kotlin (§3.2) — most importantly a hardened keyword
engine with Unicode normalisation, homoglyph folding, leetspeak handling and
whole-word boundaries that has 90 JVM test files behind it — and it duplicates
every future Good Post API change twice. It is simpler but strictly more work.

**What iOS cannot do (the honest headline):** the accessibility-based live
content monitoring — reading Chrome's URL bar, the Google app's search box, and
the YouTube app's video titles/Shorts signals, then drawing a full-screen block
overlay — **has no iOS equivalent and cannot be reproduced**. No third-party iOS
app can read another app's UI. The closest legitimate substitutes are Apple's
**Screen Time frameworks** (`FamilyControls` / `ManagedSettings` / `DeviceActivity`,
which need an Apple-approved Family Controls entitlement) and a **Safari Content
Blocker** extension (Safari-only, declarative rules). These change *what* is
blocked (apps/categories/web domains rather than live text) and *where*
(Safari and shieldable apps, not arbitrary in-app browsers). Preserving ClearView's
*purpose* is realistic; reproducing its *mechanism* is not. (§9)

**Suggested first vertical slice:** the **Quran tab**. It is the largest body of
pure, movable logic, it touches no restricted entitlement, it exercises the KMP
module boundary plus SwiftUI + a WidgetKit widget + a local notification, and it
proves the architecture end-to-end in days rather than months. The second slice
should be **Good Post read-only**, because it proves the backend-reuse claim and
the KMP networking layer. **Blocking comes last**, because it is the highest-risk,
entitlement-gated, least-reusable part — and must not be allowed to block the rest.

---

## 2. Repository architecture and dependency inventory

### 2.1 Top-level layout **[verified]**

```
ClearView/
├── app/                     the entire Android application (single Gradle module)
├── server/                  the Good Post backend — a SEPARATE Node deployable
├── docs/                    architecture notes, media playback, Good Post, S3, store listing
├── gradle/                  version catalog + wrapper (Gradle 9.5)
├── scripts/                 python/shell helpers (icon gen, dev tap, string prune)
├── licenses/                bundled font licences (IndoPak, Scheherazade, Barlow)
├── index.html               static landing/privacy page
├── Notes.md                 the author's feature backlog (Media/Todo work list)
├── build.gradle.kts, settings.gradle.kts, gradle.properties
└── check_device.ps1         Windows adb helper
```

Single Gradle module: `settings.gradle.kts` contains only `include(":app")`. There
is **no `:shared`, no `:core`, no feature modules** — the "modules" are package
directories under `com.muddassir.clearview`. **[verified]**

### 2.2 Build configuration **[verified]**

| Setting | Value | Source |
|---|---|---|
| Application id / namespace | `com.muddassir.clearview` | `app/build.gradle.kts` |
| Debug variant id | `com.muddassir.clearview.debug` | `applicationIdSuffix = ".debug"` |
| versionCode / versionName | 37 / **11.7** | `app/build.gradle.kts` |
| minSdk / targetSdk / compileSdk | 24 / 37 / 37 | `app/build.gradle.kts` |
| Kotlin | **2.2.10** | `gradle/libs.versions.toml` |
| Android Gradle Plugin | 9.3.1 | `libs.versions.toml` |
| Gradle wrapper | 9.5 (`-bin`) | `gradle/wrapper/gradle-wrapper.properties` |
| JVM toolchain | **21** | `gradle/gradle-daemon-jvm.properties` |
| Java source/target | 11 + core-library desugaring (`java.time`) | `app/build.gradle.kts` |
| Compose BOM | **2026.02.01** | `libs.versions.toml` |
| Build features | `compose = true`, `buildConfig = true` | `app/build.gradle.kts` |
| Release | R8 minify+shrink, signing from gitignored `keystore.properties` | `app/build.gradle.kts` |

**Build-generated config values** (all non-secret): `GOODPOST_BASE_URL`
(from `goodPostBaseUrl`, default `https://clearview-1neb.onrender.com`),
`GOOGLE_WEB_CLIENT_ID` (parsed out of `google-services.json`), `ADMIN_MIN_PASSWORD_LENGTH` (8).
**[verified]** `gradle.properties`, `app/build.gradle.kts`.

### 2.3 Dependencies **[verified]** — `app/build.gradle.kts`, `libs.versions.toml`

| Area | Dependency | iOS impact |
|---|---|---|
| UI | Compose BOM, `material3`, `material-icons-extended`, `ui-tooling` | **Android-only.** Rewrite in SwiftUI; `material-icons-extended` has no iOS twin. |
| Lifecycle / VM | `androidx.lifecycle.*`, `viewmodel-compose` | **Android-only.** Swift `ObservableObject`/`@Observable`. |
| Coroutines | `kotlinx-coroutines-android` 1.10.1 | `kotlinx-coroutines-core` is KMP; only the `-android` main-dispatcher artifact is Android. |
| Background | `androidx.work` 2.10.0 (WorkManager) — **7 files** | Rewrite → `BGTaskScheduler`. |
| Media playback | `androidx.media` 1.8.0 (MediaSessionCompat), `media3-exoplayer`+`media3-ui` 1.11.1 | Rewrite → AVFoundation / `AVPlayer`, `MPNowPlayingInfoCenter`. |
| YouTube extraction | `com.github.TeamNewPipe:NewPipeExtractor` v0.26.4 — **GPL-3.0-or-later** | **Do not port.** GPL + ToS risk → see §11.4. |
| Identity | Firebase BOM 34.18.0: `firebase-analytics`, `firebase-auth`, `firebase-messaging` (3 files) | Firebase iOS SDK exists; FCM needs APNs. |
| Google sign-in | `androidx.credentials` + `googleid` (Credential Manager) | Rewrite → GoogleSignIn-iOS SDK. |
| JSON | `org.json` (32 files) | Android/JVM only → `kotlinx.serialization` in KMP. |
| Serialization framework | **none** — hand-rolled `org.json` | KMP will need a serialization library. |
| Networking | **none** — `java.net.HttpURLConnection` (22 files) | Not on Kotlin/Native → Ktor client. |
| DI | **none** (manual construction) | Manual construction, or a small Swift DI. |
| Navigation | **none** (hand-rolled state) | SwiftUI `NavigationStack` + a router. |
| Persistence | `SharedPreferences` (33 files), file cache, `EncryptedSharedPreferences` (1 file: `AdminTokenStore`) | `UserDefaults` / Keychain / files. |

### 2.4 Manifest surface — the system integrations **[verified]** `app/src/main/AndroidManifest.xml`

| Component | Class | Purpose |
|---|---|---|
| Activity | `LauncherActivity` → `MainActivity` (the only real activity) | single-activity Compose shell |
| Activity | `ui.BlockOverlayActivity` | full-screen block screen (no history/recents) |
| Activity | `quran.ui.QuranVerseActivity` | widget's verse+Media+Live hub |
| Activity | `todo.ui.TodoAlarmActivity` | over-lock-screen alarm screen |
| Activity | `todo.ui.TodoSnoozeActivity` | dialog-style snooze picker |
| Service (a11y) | `service.UrlBlockerService` | `BIND_ACCESSIBILITY_SERVICE` — the blocker |
| Service (FGS) | `media.playback.AudioPlaybackService` | `mediaPlayback` background audio |
| Service (FGS) | `phonelimit.PhoneLimitService` | `specialUse` countdown timer |
| Service (FGS) | `todo.data.TodoAlarmService` | `mediaPlayback` alarm ringtone |
| Service (push) | `goodpost.data.GoodPostMessagingService` | FCM `MESSAGING_EVENT` |
| Receiver | `quran.widget.QuranReminderWidgetProvider` | home-screen widget |
| Receiver | `todo.widget.TodoWidgetProvider` | home-screen widget |
| Receiver | `phonelimit.PhoneLimitReceiver` | boot recovery |
| Receiver | `todo.data.TodoReminderReceiver` | alarm + actions + boot rescheduling |
| Receiver | `media.worker.NotificationDismissReceiver` | notification swipe bookkeeping |
| Receiver | `receiver.DeviceAdminReceiver` | `BIND_DEVICE_ADMIN` (uninstall friction) |
| Provider | `androidx.core.content.FileProvider` | share the generated progress-card PNG |

**Permissions:** `BIND_ACCESSIBILITY_SERVICE`, `PACKAGE_USAGE_STATS`,
`POST_NOTIFICATIONS`, `INTERNET`, `USE_FULL_SCREEN_INTENT`, `VIBRATE`,
`FOREGROUND_SERVICE(+_MEDIA_PLAYBACK,+_SPECIAL_USE)`, `RECEIVE_BOOT_COMPLETED`,
`SCHEDULE_EXACT_ALARM`; the ad-ID permissions are explicitly **removed**. Deep link
scheme `clearview://goodpost/channel/<slug>` is registered (BROWSABLE). **[verified]**

---

## 3. Kotlin and UI reuse assessment

### 3.1 Measured size **[verified]**

Method: `find app/src/main/java -name '*.kt'` line counts (source only; tests
excluded). Counting is by physical line, so comments and KDoc are included — this
inflates every bucket equally and is not a measure of "useful logic".

| Metric | Count |
|---|---|
| Kotlin source files (`app/src/main/java`) | **208** |
| Total Kotlin source lines | **97 992** |
| Lines under a `*/ui/*` path (Compose screens + view-layer helpers) | **49 032** (~50 %) |
| Lines in files importing `androidx.compose.*` (66 files) | **56 493** (~58 %) |
| Lines in files with **no `import android.` and no `import androidx.`** (53 files) | **10 070** (~10.3 %) |
| …of those, files that also avoid JVM-only APIs (`java.net`, `javax.xml`, `org.json`, `java.util`, `java.text`, `java.io`) — 27 files | **3 746** (~3.8 %) |

**I am deliberately not giving a single "reusable %".** These numbers measure
*text*, not value, and UI text is the cheapest to rewrite while the ~1 300-line
keyword engine is the most valuable to keep. The honest breakdown is:

- **Rules/logic worth sharing:** the 27 near-pure files (~3.7k lines) *plus* the
  business-rule portions of larger Android-coupled files that can be extracted —
  chiefly `matching/KeywordMatcher.kt` (1 322 lines, the normalisation + boundary
  matcher is largely platform-free apart from `android.net.Uri`/`android.util.Log`),
  `todo/data/TodoCodec.kt` (1 079), `todo/data/TodoStats.kt` (1 191),
  `media/util/*`, `quran/data/QuranJsonParser.kt`, `goodpost/data/GoodPostModels.kt`,
  `goodpost/data/GoodPostText.kt`.
- **Rules that must be rewritten** (platform-bound): the accessibility extractors,
  the block overlay and all "press Back / return Home / draw over the UI" logic.
- **UI:** ~50 % of lines, effectively **0 % reusable**.

Method caveat: I did not compile anything. "No Android import" does not guarantee
the code compiles under Kotlin/Native — 23 of the 53 platform-free files still use
JVM-only libraries, which is exactly why the number shrinks to 27/3 746 when those
are excluded.

### 3.2 The four options, evaluated against *this* code

#### Option A — KMP + native SwiftUI

**Viable, and recommended.** The domain code is already well-factored behind
interfaces and is unusually testable (90 JVM test files, §3.3). The seams exist:
the matching engine takes a `ContentSnapshot` data class and a repository
interface; the media layer separates source-fetchers from a repository; the todo
layer separates a codec, a stats module and a store.

What must change to compile under KMP:
- `org.json` → `kotlinx.serialization` (32 files touched, but most are one-line
  swaps inside codecs).
- `java.net.HttpURLConnection` → Ktor client (`commonMain`) with Darwin/Android engines.
- `java.util.Calendar`/`SimpleDateFormat` → `kotlinx-datetime`.
- `org.w3c.dom`/`javax.xml.parsers` (RSS/Atom parsing) → `kotlinx-serialization` XML
  or a small hand-rolled parser (two parser files).
- `android.util.Log` in shared files → a `expect fun log()`/`Napier` shim.
- `SharedPreferences`-backed stores stay native per platform (an `expect` storage
  interface is fine, but there is little value in forcing it).

#### Option B — Compose Multiplatform

**Not recommended.** Reasons, each from the code:

1. **No navigation framework to share.** `MainActivity.kt` is one 967-line
   `when(selectedTab)` with ~10 hand-rolled `LaunchedEffect` deep-link handlers and
   `BackHandler` calls. There is no `NavHost` to port. **[verified]**
2. **Android-view interop is load-bearing.** `media/ui/YoutubePlayer.kt` and
   `VideoPlayerScreen.kt` (3 220 lines) drive a real `WebView`; `GoodPostInlineVideo.kt`
   embeds a real `androidx.media3` `PlayerView` ("*a real view is composited above
   the Compose content*", per `docs/GOODPOST.md`); the Shorts/long-video coordinators
   add **system overlay views via `WindowManager`** and inject **gestures**.
   Compose-MP cannot carry any of that to iOS as-is. **[verified]**
3. **Material3 + extended icons + Android lifecycle.** 66 files import
   `androidx.compose.*`; `material-icons-extended` alone has no iOS equivalent, so
   every icon would be re-sourced. **[verified]**
4. **The product's value is the platform integrations**, which Compose-MP
   explicitly does not abstract (Screen Time, Safari extension, WidgetKit, AVFoundation,
   APNs). You would write them natively *anyway* and then also maintain a Compose-MP
   layer.

#### Option C — pure Swift rewrite

**Technically clean, economically worse.** It forfeits the 27 near-pure files and
the extractable rule code, and — more importantly — forfeits the **test corpus**:
`matching/` has 4 dedicated test files (boundary matching, normalisation, Google
commit detection, extractor), `todo/data/` has 9, `media/` ~25, `goodpost/data/` ~6.
Those tests encode hard-won fixes ("`ass` must not match `class`", leetspeak,
homoglyphs) that a rewrite would silently regress. **[verified]** (§3.3)

#### Option D — hybrid (shared Kotlin domain + native SwiftUI)

**Recommended.** It is Option A with an explicit rule: *share logic, never UI.* It
keeps the tested Kotlin, keeps SwiftUI idiomatic, keeps the backend contract in one
place, and stops at exactly the boundary the platform forces.

### 3.3 Test corpus (an under-rated reuse asset) **[verified]**

| Suite | Files | Framework |
|---|---|---|
| Android JVM unit tests (`app/src/test`) | **90** | JUnit4 (real `org.json` on the JVM classpath) |
| Android instrumented (`app/src/androidTest`) | 1 | Espresso / Compose test |
| Backend (`server/tests`) | **18** | Vitest + Supertest + PGlite (in-process Postgres) |

The JVM unit tests are the single most valuable thing to port: once the shared
module exists, many of them move to `commonTest` and keep protecting both
platforms. The backend suite is untouched by the migration.

---

## 4. Subsystem reuse classification

Legend: **R1** directly reusable · **R2** reusable after refactoring · **R3**
platform-specific implementation required · **R4** must be rewritten · **R5**
cannot be reproduced equivalently.

| # | Subsystem | Key source files | Current dependency | Class | Proposed iOS solution | Est. effort (dev-days) |
|---|---|---|---|---|---|---|
| 1 | Keyword/domain matcher (normalise, homoglyph, leet, boundary) | `matching/KeywordMatcher.kt`, `repository/BlockRepository.kt` | stdlib + `android.net.Uri`/`Log` | **R2** | Move rules to `commonMain`; strip `android.*` behind a tiny shim | 6–10 |
| 2 | Live screen extraction (Chrome URL bar, Google box, YouTube titles/Shorts) | `extractor/ContentExtractor.kt`, `GoogleAppUrlExtractor.kt`, `GoogleSignalParser.kt` | `AccessibilityNodeInfo`, `AccessibilityEvent` | **R5** | No iOS equivalent. Substitute: Safari Content Blocker rules + Screen Time shields | — (see §9) |
| 3 | Block enforcement + overlay | `service/UrlBlockerService.kt`, `ui/BlockOverlayActivity.kt`, `youtubetest/*Coordinator.kt` | Accessibility globals, `WindowManager` overlays, gesture injection | **R5** | Substitute only; the overlay screen itself becomes a SwiftUI informational screen | — |
| 4 | Keyword/domain *storage & UI* | `repository/BlockRepository.kt`, `ui/BlockTab.kt` | SharedPreferences + Compose | **R4** UI / **R2** store | SwiftUI + `UserDefaults`/`Keychain`; feed rules into blockers | 5–8 |
| 5 | Incognito blocking | `ContentExtractor.matchesStrongIncognitoText`, `KeywordMatcher.check` | Accessibility tree | **R5** | Substitute: managed "Limit Adult Websites"/private-browsing restrictions | — |
| 6 | Global rule repository (Brain Rot: fetch/report/submit) | `brainrot/BrainRotClient.kt`, `GlobalRulesStore.kt`, `BrainRotRepository.kt`, `NotificationStore.kt` | `HttpURLConnection` + `org.json` + SharedPreferences | **R2** | Ktor client in `commonMain`; SwiftUI screens; backend reused | 4–6 |
| 7 | Device Admin / uninstall protection | `receiver/DeviceAdminReceiver.kt` | `DevicePolicyManager`, `setUninstallBlocked` (Device Owner) | **R5** | Only MDM/supervised devices; not available to a normal App Store app | — |
| 8 | Phone Limit (countdown + usage stats + lock) | `phonelimit/PhoneLimitCoordinator.kt`, `Service.kt`, `Receiver.kt`, `ui/PhoneLimitSheet.kt` | FGS, `AlarmManager`, `UsageStatsManager`, `lockNow` | **R3** | `DeviceActivity` schedules + `ManagedSettings` shields; no arbitrary usage read; no screen lock | 8–12 |
| 9 | Quran data: download, parse, integrity | `quran/data/QuranApi.kt`, `QuranJsonParser.kt`, `QuranTextIntegrity.kt`, `QuranRepository.kt` | `HttpURLConnection` + `org.json` + files | **R2** (parser) / **R1** (`QuranTextIntegrity`) | Ktor + kotlinx-serialization in `commonMain` | 3–5 |
| 10 | Quran store: bookmarks, positions, prefs | `quran/data/QuranStore.kt` | SharedPreferences + files | **R2** | Port the pure helpers (`readingPositionOf`, `withReadingPosition`); native storage | 2–3 |
| 11 | Quran UI + widget + verse notification | `quran/ui/*`, `widget/QuranReminderWidgetProvider.kt`, `worker/*` | Compose, AppWidget, WorkManager | **R4** | SwiftUI + WidgetKit + `BGTaskScheduler`/local notification | 8–12 |
| 12 | Dhikr counter | `quran/ui/DhikrCounterScreen.kt`, `data/DhikrStore.kt`, `DhikrCodec.kt` | Compose + SharedPreferences + Vibrator | **R2** codec / **R4** UI | SwiftUI + haptics; codec movable | 3–4 |
| 13 | Media feed models + filters | `media/model/*`, `media/util/*` | pure + `java.util.Calendar` | **R1/R2** | Move to `commonMain`; `java.util` → `kotlinx-datetime` | 3–5 |
| 14 | YouTube RSS parser | `media/data/YouTubeRssParser.kt` | `org.w3c.dom`, `javax.xml`, `SimpleDateFormat` | **R2** | kotlinx-serialization XML (or hand parser) | 2–3 |
| 15 | Instagram sources/parsers | `media/data/Instagram*.kt` (10 files) | `HttpURLConnection`, `org.json`, regex | **R2** | Ktor + kotlinx-serialization; regex is portable | 4–6 |
| 16 | X/Twitter source + parser | `media/data/XSource.kt` | `HttpURLConnection`, regex, `javax.xml` | **R2** | Ktor; regex portable | 3–5 |
| 17 | Live stream resolution (HLS) | `media/data/LiveStreamResolver.kt`, `LiveStreamConfig.kt`, `LiveStreamCacheStore.kt` | `HttpURLConnection` + prefs | **R2** resolution / **R4** playback | `AVPlayer` plays HLS natively | 3–4 |
| 18 | Video playback (IFrame WebView + MediaPlayer) | `media/ui/VideoPlayerScreen.kt`, `YoutubePlayer.kt`, `media3` inline | `WebView`, `MediaPlayer`, ExoPlayer | **R4** | `WKWebView` (YouTube IFrame) + `AVPlayer`; no ExoPlayer equivalent needed | 12–18 |
| 19 | Background audio + sleep timer | `media/playback/AudioPlaybackService.kt`, `AudioPlayback.kt`, `SleepTimer.kt` | FGS, `MediaSessionCompat`, `MediaPlayer` | **R2** timer / **R4** service | `AVAudioSession(.playback)` + `MPNowPlayingInfoCenter`; timer portable | 8–12 |
| 20 | Audio download + extraction | `media/download/*` (8 files), `NewPipeDownloader.kt` | NewPipeExtractor (**GPL**), files | **R2** store/policy / **R4** extractor; **do not port NewPipe** | URLSession download of permitted sources; YouTube audio extraction dropped | 5–8 |
| 21 | Media worker / notifications | `media/worker/*` (6 files) | WorkManager, FCM/notifications | **R4** | `BGTaskScheduler` + `UNUserNotificationCenter` | 4–6 |
| 22 | Todo domain (model, codec, stats, completion) | `todo/model/TodoItem.kt`, `data/TodoCodec.kt`, `TodoStats.kt`, `TodoCompletion.kt`, `ProgressCardStats.kt` | pure + `org.json` | **R2** (much of it **R1**) | `commonMain`; swap JSON lib | 5–8 |
| 23 | Todo scheduling / alarms / snooze | `todo/data/TodoScheduler.kt`, `TodoReminderReceiver.kt`, `TodoAlarmService.kt`, `AlarmSounds.kt`, `ui/TodoAlarmActivity.kt`, `TodoSnoozeActivity.kt` | `AlarmManager` exact alarms, FGS, full-screen intent | **R4** | `UNUserNotificationCenter` (time-sensitive/critical alerts) + a custom alarm screen; no Clock-app integration | 8–12 |
| 24 | Todo UI + widget + progress card | `todo/ui/TodoScreen.kt` (3 798), `TodoEditor.kt`, `ProgressCard*.kt`, `widget/TodoWidgetProvider.kt` | Compose, AppWidget, Canvas, FileProvider | **R4** UI / **R2** layout maths | SwiftUI + WidgetKit + `ImageRenderer` + `ShareLink` | 12–18 |
| 25 | Good Post client (transport, repo, cache, models) | `goodpost/data/GoodPostApi.kt` (1 425), `GoodPostRepository.kt`, `GoodPostCache.kt`, `GoodPostModels.kt`, `GoodPostText.kt` | `HttpURLConnection`, `org.json`, SharedPreferences | **R2** transport+models / **R4** cache & FCM | Ktor + kotlinx-serialization in `commonMain`; native cache | 10–15 |
| 26 | Good Post identity (anonymous + creator + Google) | `goodpost/data/GoodPostIdentity.kt` | Firebase Android + Credential Manager | **R4** | Firebase iOS SDK (anonymous + email) + GoogleSignIn-iOS | 4–6 |
| 27 | Good Post UI + composer + admin (29 files) | `goodpost/ui/*` (incl. `GoodPostStyle.kt` 2 300, `GoodPostFeed.kt` 2 063) | Compose, `androidx.media3` `PlayerView`, `MediaMetadataRetriever` | **R4** | SwiftUI + AVPlayer + `AVAssetImageGenerator` | 25–40 |
| 28 | Good Post push | `goodpost/data/GoodPostMessagingService.kt`, `GoodPostPush.kt` | FCM | **R4** | APNs + Firebase Messaging iOS; server `notifications/fcm.ts` adds APNs | 3–5 |
| 29 | Channel directory | `directory/ui/ChannelDirectoryScreen.kt`, `goodpost/data/DirectoryModels.kt` | Compose + `HttpURLConnection` + `org.json` | **R2** codec / **R4** UI | Ktor + SwiftUI; backend reused | 4–6 |
| 30 | Good Post ads | `goodpost/ui/GoodPostAds.kt`, `data/AdDuration.kt`, server `ads/*` | Compose + org.json | **R2** duration / **R4** UI | SwiftUI; backend reused | 3–5 |
| 31 | Theme / design tokens | `ui/theme/Color.kt`, `Theme.kt`, `Type.kt`, `ThemeStore.kt` (350 lines) | Compose Material3 | **R4** (values are **R1**) | Re-express palette/type as SwiftUI `Color`/`Font` tokens; keep hex values, fonts already licensed in `licenses/` | 2–3 |
| 32 | App shell + navigation + deep links | `MainActivity.kt`, `LauncherActivity.kt`, `ui/ContentHub.kt` | Compose, single Activity | **R4** | SwiftUI TabView + `NavigationStack` + `onOpenURL` | 8–12 |
| 33 | Crash-free plumbing (refresh bus, notification state, storage policy) | `brainrot/BrainRotRefreshBus.kt`, `media/worker/NotificationStateStore.kt`, `media/download/StoragePolicy.kt` | kotlinx.coroutines / prefs | **R2** | Mostly portable | 2–3 |
| 34 | Backend + database + storage | `server/**` (49 source files) | Node 22, Express 5, Neon, S3, Render | **R1** | Reused unchanged (add APNs for iOS push) | 2–4 (backend) |

**Effort units:** developer-days for one senior engineer already fluent in iOS +
KMP. They are *estimates*, not commitments, and exclude review/approval lead times
(which are the real long pole — see §9.2).

---

## 5. Navigation and state architecture (what has to change)

**[verified]** `MainActivity.kt`, `ui/ContentHub.kt`, `ui/ContentHubSheets.kt`:

- One activity, `LauncherActivity extends MainActivity`, no `::class` per screen.
- Bottom navigation is four `NavigationBarItem`s: **Quran**, **Media**, **Good Post**,
  **More** (`MainTab{QURAN, MEDIA, GOODPOST, MORE}`; the More tab has an internal
  "Protection" page).
- Media/Quran are a shared `ContentHubState` (`rememberContentHubState()`) with
  overlays (`showHaramaynLive`, `showChannelDirectory`, `showTodoScreen`,
  `showDhikrCounter`, `showPhoneLimitSheet`, `showSettingsSheet`, `playingVideo`,
  `playingAudio`, `playerFullscreen`).
- Deep links are handled by ~10 separate `LaunchedEffect` blocks reading
  intent extras (`EXTRA_OPEN_TODO`, `EXTRA_OPEN_PHONE_LIMIT`,
  `EXTRA_OPEN_BLOCKING`, now-playing extras, `clearview://goodpost/channel/<slug>`).
- Back is handled by three stacked `BackHandler`s (player → overlay → Protection page).

**iOS translation:** a `TabView` for the four tabs, a `Router` `ObservableObject`
for the hub state, `NavigationStack` per tab, and a single `onOpenURL` +
`UNUserNotificationCenter` delegate that fans out to the same destinations. This is
a clean rewrite, not a port. There is nothing to "share" here, and no
Navigation-Compose to mirror.

---

## 6. Feature-by-feature iOS compatibility matrix

Compatibility categories: **① Full parity** · **② Parity, different implementation**
· **③ Partial parity** · **④ Substitute experience** · **⑤ Not realistically available**.

Each confirmed feature lists: what Android does → key files → business-logic reuse →
iOS framework → parity verdict → restrictions → recommended approach → difficulty/priority.

### 6.1 Content blocking (the core product)

**What Android does [verified]** (`service/UrlBlockerService.kt` 2 578 lines;
`extractor/ContentExtractor.kt` 1 854; `extractor/GoogleAppUrlExtractor.kt`;
`matching/KeywordMatcher.kt` 1 322; `repository/BlockRepository.kt`; `ui/BlockOverlayActivity.kt`):
an `AccessibilityService` polls the foreground app's accessibility tree (500 ms for
Chrome/Google, 1 500 ms for embedded browsers) and reacts to `TYPE_WINDOW_STATE_CHANGED`
and `TYPE_VIEW_TEXT_CHANGED`. It extracts, per package:
- **Chrome:** the URL from the address-bar node IDs (`chrome:id/url_bar`, …), plus
  incognito detection from strong page phrases; blocks on domain and URL keyword.
- **Google app:** search query from the search-box node IDs / window title, gated so
  a *submitted* search is required (not while typing).
- **YouTube app:** video title + a "Shorts" signal + hashtags (no URL bar exists).
- **Any package:** a generic fallback.
- Then it closes the offending surface (Back presses / navigates to `google.com`),
  presses HOME via `GLOBAL_ACTION_HOME`, and shows a full-screen overlay.
- Additional coordinators: `YouTubeChromeTestCoordinator` (Shorts-in-Chrome),
  `LongVideoBlockCoordinator` (blocks a YouTube `/watch` page), `NotInterestedCoordinator`
  (reads YouTube's "Not interested" and blocks that channel).
- Also blocks **pre-emptively in YouTube feeds** via a weighted risk score
  (title hard-block; thumbnail caption 0.4 + channel 0.3 ≥ 0.3 threshold), and
  **blocks all incognito browsing**.

**Business-logic reuse:** the *decision* logic is mostly portable — normalisation
(NFKC + homoglyph map + leetspeak + separator collapsing), whole-word boundary
matching via `Char.isLetterOrDigit()`, the keyword cache, the Facebook-free
`ContentSnapshot`, and the risk-score weights. The *inputs* (`ContentSnapshot`
population) are not.

**iOS framework / parity:** **④ Substitute experience** for live monitoring;
**② Parity, different implementation** for rule management.

**Restrictions:** iOS has **no API by which a third-party app may inspect another
app's UI**. `UIAccessibility` exists to make *your own* app accessible; VoiceOver
does not hand other apps' trees to you. There is no `GLOBAL_ACTION_HOME`, no drawing
over other apps, no gesture injection into other apps. **[uncertain only in the
sense that this is an absence — see §9.1 for the positive alternatives]**

**Recommended iOS approach:**
1. **Safari Content Blocker extension** that compiles the same keyword/domain rules
   to WebKit content-blocker JSON (`block` rules by URL filter). Safari-only;
   declarative; rules must be `json`/`display-none`/`css-display-none`/`block-cookies`.
2. **Screen Time frameworks** (needs the Family Controls entitlement): shield
   distracting apps/categories and filter web content; use `DeviceActivity` to
   schedule.
3. Keep the **rules editor** (keywords, domains, built-ins, strict mode) as a
   native SwiftUI screen — this is the part users can still fully control.

**What the user loses:** blocking that reacts to *what is on screen inside Chrome,
the Google app and the YouTube app*; incognito blocking via page-text detection;
pre-emptive YouTube feed card blocking; the block overlay; the "return to Home"
behaviour. In exchange they get app/category/web-domain blocking that is harder to
bypass (system-enforced) but coarser.

**Difficulty: very high. Priority: highest strategic, but schedule last** (gate it
behind the Family Controls entitlement request — see §9.2).

### 6.2 Brain Rot global rules (shared blocklists + reporting)

**Android [verified]:** `brainrot/*` (11 files) fetch
`GET /api/v1/brainrot/rules` (`BrainRotClient.fetchRules`, cached in `GlobalRulesStore`),
let the user submit suggestions/reports (`POST /api/v1/brainrot/suggestions`,
`/reports`) keyed by an on-device `AnonymousId`, and show their own submission
statuses. `ChannelBlockRepository` + `ClearViewBackendClient` are a parallel
channel-blocking client. Both are best-effort: a dead backend must never weaken
local protection. **[verified]**

**Reuse:** **R2** — the client is `HttpURLConnection` + `org.json` + `SharedPreferences`;
moving to Ktor + kotlinx-serialization in `commonMain` makes it shared with Android.

**iOS:** **② Parity, different implementation** for fetching/reporting (trivial HTTP).
Parity of *enforcement* depends on §6.1. Backend reused unchanged.

**Difficulty: low-medium. Priority: high** (it is the cheapest way to keep the
"community blocklist" value alive on iOS).

### 6.3 Content filtering UI (Block tab, Lock screen)

**Android [verified]:** `ui/BlockTab.kt` (2 654 lines) with keyword chips, domain
list, built-in sets, Strict Mode toggle, "Block Shorts" toggle, activity stats,
YouTube-only keywords (`youtubetest/YoutubeTestKeywordRepository.kt`), plus a
password-gated lock screen (`MainViewModel` `hasPassword`/`isAppLocked`,
`lockApp()` on `ON_STOP`). YouTube-Chrome test toggle.

**Reuse:** UI **R4**; the *storage* (`BlockRepository`, `YoutubeTestKeywordRepository`)
**R2**; the password gate **R2** (move to Keychain + a hash).

**iOS:** **② Parity, different implementation.** SwiftUI screens + Keychain-backed
passcode + `LocalAuthentication` (Face ID can be offered).

**Difficulty: medium. Priority: high** (needed for §6.1's rules editor).

### 6.4 Quran, Dhikr, widgets, Islamic date

**Android [verified]:** `quran/data/QuranApi.kt` downloads two full editions from
**jsDelivr** (`eng-mustafakhattaba`, `ara-quranindopak`) — no ClearView backend
involved; `QuranStore` caches raw JSON to `filesDir` and the current verse to
SharedPreferences; `QuranJsonParser` (pure) builds `QuranVerse`s and derives surah
ayah counts; `QuranTextIntegrity` sanity-checks Arabic; `QuranRepository` reads
offline first; bookmarks (`"surah:ayah"`), starred surahs, and reading positions
(`readingPositionOf`/`withReadingPosition`, pure) are in prefs; `QuranTab.kt`,
`QuranVerseActivity.kt`, `QuranTypography.kt` render it;
`QuranReminderWidgetProvider` is a 4×1 resizable widget; a
`QuranDownloadWorker`/`QuranWorkScheduler` refreshes every N hours and posts an
optional notification; `DhikrCounterScreen.kt` (1 472 lines) + `DhikrStore`/`DhikrCodec`
and `DhikrVibrator` implement the counter; `IslamicDateFormatter`/`IslamicDateStore`
give the Hijri date.

**Reuse:** `QuranJsonParser` **R2**, `QuranTextIntegrity` **R1**, `QuranVerse`/`DhikrItem`
**R1**, `DhikrCodec` **R2**, reading-position helpers **R1**. UI/widget/workers **R4**.

**iOS:** **①/② parity is realistic.** Files + `UserDefaults`/Keychain; `WidgetKit`
widget (verse + dhikr); `BGTaskScheduler` or a local notification for the refresh;
`AVSpeechSynthesizer`/`AVPlayer` for verse audio (`VerseAudioPlayer` exists on Android).

**Difficulty: medium. Priority: highest as the *first slice*** (§13).

### 6.5 Media (YouTube, Instagram, X, Shorts, Live, downloads, background audio)

**Android [verified]:**
- **Sources:** YouTube per-channel RSS (`YouTubeRssParser`, pureish), a `/shorts`
  scrape (`ShortsIdResolver`), Instagram (`InstagramRssParser`, `InstagramSource`,
  embed resolver, stream resolver), X via `syndication.twitter.com` +
  RSS-Bridge fallbacks (`XSource`, `XFeedParser`). All deduplicated, cached to disk
  per channel, throttled with backoff, and surfaced through `MediaSourceStatusStore`.
- **Feed model:** one `MediaVideo` with `platform`/`instagramType`/media/source URLs
  and `bodyText`; filters in `media/model/FeedFilter.kt`, applied in
  `media/util/FeedFilters.kt`; unified `MediaPlatform{YOUTUBE, INSTAGRAM, X}`.
- **Playback:** `VideoPlayerScreen.kt` (3 220) — a `WebView` YouTube IFrame for
  video, a bespoke `android.media.MediaPlayer` + `SurfaceView` for direct streams;
  `YoutubePlayer.kt`; `LiveTab.kt` for HLS live; `AudioPlayerScreen.kt`; a
  **foreground `AudioPlaybackService`** with `MediaSessionCompat` for background
  listen-mode and a `SleepTimer`.
- **Download:** `AudioDownloader`/`NewPipeDownloader` resolve audio-only streams via
  **NewPipeExtractor** on-device; `StoragePolicy`, `AudioDownloadStore`, cleanup worker.
- **Refresh:** `MediaUpdateWorker` + `MediaWorkScheduler` (hourly, network-constrained)
  and unread badges (`MediaBadge`, `NotificationStateStore`).

**Reuse:** models+filters+parsers **R1/R2** (the `java.util.Calendar` in `FeedFilter`
and the DOM/`org.json` in the parsers need substitution). Playback/download **R4**.

**iOS:** **② parity for feeds/filters** (Ktor + kotlinx-serialization). Playback
**②**: `WKWebView` for the YouTube IFrame embed, `AVPlayer` for direct `.mp4`/`.m3u8`,
`AVAudioSession(.playback)` + `MPNowPlayingInfoCenter` for background audio (this is
a *better* fit on iOS than Android). Live HLS is native. Widget/notification refresh
**④** (BGTaskScheduler is best-effort).

**Restrictions / risks:**
- **NewPipe audio extraction cannot be ported** (GPL-3.0 + it circumvents YouTube's
  delivery). On iOS, "listen in background" for a YouTube video can only work through
  the official player (which does not allow audio-only background playback without
  the platform's own background support). Instagram's progressive `.mp4` and X's
  progressive `.mp4` are playable with `AVPlayer`.
- **Scraping third-party services (Instagram non-RSS, X syndication, RSS-Bridge)
  carries App Review risk** and is fragile (the code itself documents X shutting
  mirrors down in Sept 2026). Treat these as best-effort sources, not guarantees.
  **[uncertain]** This is a policy judgement, not a documented rejection.
- **YouTube IFrame in `WKWebView`** is the intended embedding path but is subject to
  YouTube's ToS (ads/attribution).

**Difficulty: high. Priority: medium-high** (a lot of value, a lot of surface).

### 6.6 Todos, alarms, snooze, progress card, Phone Limit

**Android [verified]:**
- `todo/model/TodoItem.kt` — immutable model with `TodoBehavior{NORMAL, ATTEMPTED, TIME}`,
  `TodoType{TEMPORARY, PERMANENT}`, `ReminderConfig` (times, repeat, `asAlarm`,
  ring length, a device `content://` ringtone URI), completion map, permanent
  `events` history, `missedClearedBefore`/`completedClearedBefore` watermarks,
  `strictInterval`, and `isDeleted`.
- `todo/data/TodoCodec.kt` (1 079) — JSON encode/decode of the whole list, pure.
- `TodoStats.kt` (1 191), `ProgressCardStats.kt`, `TodoCompletion.kt`, `HeatmapGrid.kt`,
  `ProgressCardLayout.kt` — pure statistics and layout maths.
- `TodoStore` — **SharedPreferences JSON**, `commit()` (synchronous) on purpose;
  tracks scheduled alarms, snoozes and seen reminders.
- `TodoScheduler` — `AlarmManager` exact alarms (`setAlarmClock`) + boot rescheduling.
- `TodoAlarmService` (FGS ringtone/vibration), `TodoAlarmActivity` (over lock screen),
  `TodoSnoozeActivity` (dialog).
- `TodoWidgetProvider` — 1×1 progress-ring widget.
- `ProgressCard` — generates a PNG (share via FileProvider).
- `PhoneLimitCoordinator/Service/Receiver` — a `specialUse` FGS countdown, `AlarmManager`
  backstop, `UsageStatsManager` for today's usage, `DevicePolicyManager.lockNow` on expiry.

**Reuse:** `TodoCodec`, `TodoStats`, `ProgressCardStats`, `TodoCompletion`,
`ProgressCardLayout`, `HeatmapGrid` maths, `TodoItem`, `SleepTimer` **R2/R1** (JSON
lib swap). Scheduler/alarm/service/UI **R4**. `PhoneLimitCoordinator` storage
**R2**; enforcement **R3**.

**iOS:** **② parity for the domain and most of the UI** (SwiftUI, `UNUserNotificationCenter`
time-sensitive notifications, a custom full-screen alarm view, a `Button(intent:)`
widget). **③/④ for alarms:** there is no version of `setAlarmClock` that appears in
the Clock app; "critical alerts" (which bypass silent/DND) require a separate
Apple-approved entitlement. **③ for Phone Limit:** `DeviceActivity` can shield apps
after a threshold and report usage for *the categories you monitor*, but there is no
`UsageStatsManager`-equivalent for arbitrary per-app usage totals and no
`lockNow` to lock the device.

**Difficulty: high. Priority: medium** (large surface; do after Quran + Good Post read).

### 6.7 Good Post (channels, following, publishing, notifications, admin, ads, directory)

**Android [verified]:** `GoodPostViewModel.kt` (5 030) drives a whole navigation
stack; `data/GoodPostApi.kt` (1 425) is the transport (`HttpURLConnection` +
coroutines + `org.json`); `GoodPostRepository` is cache-first with admin sessions
and token renewal; `GoodPostCache` is SharedPreferences + JSON; `GoodPostModels`/
`GoodPostText`/`GoodPostErrors` are pure-ish; identity is Firebase anonymous (reader)
+ a second Firebase app for creators (email/password and Google via Credential
Manager); push is FCM data messages; the UI is 29 files (~12k+ lines) including a
WhatsApp-style composer, media viewer/crop, ads, and an admin surface; the channel
**directory** is server-driven. Backend: §8.

**Reuse:** transport+models+text+errors **R2**; cache/identity/push/UI **R4**.

**iOS:** **② parity** for read, follow, publish, directory and ads (backend unchanged).
Identity: Firebase iOS SDK (anonymous + email/password) and GoogleSignIn-iOS.
Push: Firebase Messaging iOS over APNs. Media: `AVPlayer` + `AVAssetImageGenerator`
(the poster-frame logic is portable in spirit).

**Difficulty: very high (biggest single workstream). Priority: high for *read-only*
first; publishing/admin later.**

### 6.8 Widgets across the app

**Android [verified]:** Quran reminder (4×1 resizable), Todo (1×1 progress ring);
RemoteViews layouts; `updatePeriodMillis="0"` and explicit `refreshAllWidgets` on write.

**iOS:** **② parity** via **WidgetKit** — but note the refresh model is different:
timelines are refreshed on a *budget* (a minimum of ~5 minutes between reloads, and
a daily budget the system controls), with explicit `WidgetCenter.shared.reloadTimelines`.
There are no `RemoteViews`, and interactive widgets use SwiftUI `Button(intent:)`.
**[verified via Apple docs snippet; §9.4]**

**Difficulty: medium. Priority: medium.**

### 6.9 Notifications, alarms and background work

**Android [verified]:** FCM push (Good Post updates), a 15-minute WorkManager check
(`GoodPostUpdateWorker`), hourly media update worker, 6-hourly Quran worker, exact
alarms for todos, an FGS-based countdown, and per-notification dismiss state.

**iOS:** **③/④** — FCM works over APNs; `BGTaskScheduler` app-refresh tasks are
**opportunistic and not guaranteed to run on schedule** (the system decides, based on
usage and budgets); there is no persistent foreground service for a countdown; a
"background deadline" only applies while a task is running (typically ~30 s for
`BGAppRefreshTask`). Apps cannot guarantee a notification every 15 minutes.
**[verified via WWDC/support material; §9.4]**

**Difficulty: medium individually, but it changes the product's promises** — iOS
must be worded as "checks periodically" rather than "within 15 minutes".

### 6.10 Features that are Android-only by construction

`DeviceAdminReceiver` (uninstall friction/blocking), the block overlay, gesture
injection, `UsageStatsManager`, `lockNow`, `setAlarmClock`, `MediaMetadataRetriever`
(→ `AVAssetImageGenerator` on iOS, so this one *does* have a twin), and
`EncryptedSharedPreferences` (→ Keychain).

---

## 7. Android → iOS system API mapping

| Android mechanism | Used by (files) | iOS equivalent | Fidelity |
|---|---|---|---|
| `AccessibilityService` (tree reading, `performGlobalAction`) | `service/UrlBlockerService.kt`, `extractor/*`, `youtubetest/*` | **none** | **⑤ none** |
| Full-screen overlay (`WindowManager`/activity) over other apps | `ui/BlockOverlayActivity.kt`, `youtubetest/*` | **none** (own app only) | **⑤ none** |
| Device Admin (`DevicePolicyManager`, `lockNow`, `setUninstallBlocked`) | `receiver/DeviceAdminReceiver.kt`, `phonelimit/*` | **MDM only** (supervised/managed devices) | **⑤ for normal apps** |
| `UsageStatsManager` (per-app usage) | `phonelimit/PhoneLimitCoordinator.kt` | `DeviceActivity` reports + `DeviceActivityMonitor` thresholds (entitlement) | **③ partial** |
| `SharedPreferences` | 33 files | `UserDefaults` / `NSUbiquitousKeyValueStore` | **①** |
| `EncryptedSharedPreferences` | `goodpost/data/AdminTokenStore.kt` | **Keychain** (`kSecClassGenericPassword`) | **①** |
| Internal file cache (`filesDir`) | Quran, media feeds, downloads | App Sandbox `Documents`/`Caches` | **①** |
| `WorkManager` (periodic, constrained) | 7 files | `BGTaskScheduler` (`BGAppRefreshTask`) — opportunistic | **③** |
| `AlarmManager.setAlarmClock` (exact, Clock-app) | `todo/data/TodoScheduler.kt` | `UNUserNotificationCenter` (+ critical-alert entitlement for loud) | **③** |
| Foreground service (media playback) | `AudioPlaybackService`, `TodoAlarmService` | `AVAudioSession(.playback)` + background-audio mode + `MPNowPlayingInfoCenter` | **① for audio** |
| Foreground service (`specialUse` countdown) | `PhoneLimitService` | none; use timers + notifications | **③** |
| `MediaSessionCompat` / notification controls | `AudioPlaybackService` | `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` | **①** |
| `MediaPlayer` / ExoPlayer | `media/ui/*`, `media3` inline | `AVPlayer` / `AVPlayerViewController` | **①** |
| `WebView` (YouTube IFrame / in-app browsers) | `YoutubePlayer.kt`, `VideoPlayerScreen.kt` | `WKWebView` | **①** |
| HLS live stream | `LiveStreamResolver`, `LiveTab` | `AVPlayer` (native HLS) | **①** |
| `Vibrator` | `DhikrVibrator`, block feedback | `UIImpactFeedbackGenerator` / `CoreHaptics` | **①** |
| AppWidget (`RemoteViews`) | `QuranReminderWidgetProvider`, `TodoWidgetProvider` | `WidgetKit` | **②** |
| FileProvider share sheet | `ProgressCard` | `ShareLink` + `ImageRenderer` | **①** |
| FCM (data messages) | `GoodPostMessagingService`, `GoodPostPush` | APNs + Firebase Messaging iOS | **②** |
| Firebase Auth (anonymous, email, Google via Credential Manager) | `goodpost/data/GoodPostIdentity.kt` | Firebase iOS SDK + GoogleSignIn-iOS | **②** |
| `clearview://` custom-scheme deep link | `AndroidManifest.xml`, `MainActivity` | Custom URL scheme + (optional) Universal Links | **① / ②** |
| `java.net.HttpURLConnection` | 22 files | `URLSession` (Swift) / Ktor (KMP) | **①** |
| `org.json` | 32 files | `Codable` (Swift) / kotlinx-serialization (KMP) | **①** |
| Screenshot/`MediaMetadataRetriever` frame grab | `goodpost/data/GoodPostVideoPoster.kt` | `AVAssetImageGenerator` | **①** |

---

## 8. Backend reuse assessment

**Verdict: the `server/` backend can serve iOS unchanged (one additive change for
APNs).** **[verified]** `server/src/app.ts`, `server/README.md`, `server/package.json`.

### 8.1 What it is

Node 22 + TypeScript + Express 5, `pg` (no ORM), `zod` validation, `bcryptjs`,
`jsonwebtoken`, AWS SDK v3, `node-cron`, deployed on Render (**Frankfurt**), Neon
PostgreSQL, S3-compatible object storage. Deployed at `clearview-1neb.onrender.com`
(`goodPostBaseUrl` in `gradle.properties`). Migrations are immutable, checksummed,
forward-only SQL (17 files in `server/migrations/`). **[verified]**

### 8.2 API surfaces (all platform-neutral) **[verified]** `server/src/app.ts`, `server/README.md`

- **`/api/v1`** — anonymous, read-only: `/channels` (+`q`,`category`,`sort`,`limit`,`cursor`),
  `/categories`, `/channels/:idOrSlug`, `/channels/:idOrSlug/posts`, `/channels/:idOrSlug/media`,
  `/posts/:postId`, `POST /channels/:idOrSlug/posts/views`.
- **`/api/v1/ads`**, **`/api/v1/brainrot`**, **`/api/v1/directory`** — mounted on their
  own exact paths before the parameterised router.
- **`/api/v1/readers/*`** — requires `Authorization: Bearer <Firebase ID token>`
  (verified against Google's public certs using only `FIREBASE_PROJECT_ID`):
  `/me`, `/me/following`, follow/unfollow/read, `/me/reactions/*`.
- **`/admin/api/*`** — separate path prefix, token audience and signing key; login
  (email+password and Firebase), creator channel creation, channels, posts, media
  upload (presign → PUT → confirm → claim), admins, audit, settings, ads, brainrot,
  directory admin.
- **`/c/:slug`** — the public share page (HTML + `og:` meta + `/c/app.js` fallback to
  the store), plus `/c/:slug/icon`.
- **`/health`, `/health/db`**.

### 8.3 Is anything Android-specific?

**[verified]** — nothing in the request/response contract is Android-specific. The
stated assumptions are:
- The Android client sends **no `Origin` header**, so `CORS_ORIGINS` is empty and
  browsers are refused. **iOS native clients also send no `Origin`, so a URLSession
  request is unaffected — but if any iOS code ever runs in a `WKWebView` context that
  sets an Origin, CORS would matter. Flag as a low-risk item.**
- The share flow depends on the deep link `clearview://goodpost/channel/<slug>` and
  falls back to a store URL. **iOS needs:** register the same scheme (or a new one
  such as `clearview://` unchanged — schemes are not platform-owned), and update the
  `/c/app.js` + store-fallback logic to point at the App Store once the iOS app exists.
  The server's fallback URL currently assumes one store; this is an **additive backend
  change** (serve a platform-appropriate store link, e.g. sniff `User-Agent`).
- Push: `server/src/notifications/fcm.ts` uses FCM. **iOS requires APNs credentials**
  (an APNs auth key, `APNS_*` env vars, device-token storage per platform) — an
  **additive** backend change; the `reader_devices` table already stores tokens and
  can gain a platform column.

### 8.4 What the iOS client needs (non-secret)

- `GOODPOST_BASE_URL` → an iOS build setting (`Info.plist` value or an xcconfig),
  mirroring `goodPostBaseUrl`. **No secret.**
- `adminMinPasswordLength` → mirror the 8-character floor in the iOS form.
- `FIREBASE_PROJECT_ID` → the iOS `GoogleService-Info.plist` (public).
- **`GOOGLE_WEB_CLIENT_ID`** → the iOS OAuth client id (public) for GoogleSignIn-iOS.
- **Secrets never ship in either app** (AWS keys, JWT secret, DB URLs, hash pepper
  are server-side only). This audit did **not** print or copy any secret value; the
  report refers to variables only.

### 8.5 Server-side work required before/with the iOS release

1. **APNs sender** + a `platform` on `reader_devices` (small; additive).
2. **Store-link sniffing** on `/c/app.js` and the share page (small; additive).
3. **Nothing else** — the reader/admin API, media pipeline, retention job and
   database are platform-agnostic.

### 8.6 What is NOT backend-served

Quran text, YouTube RSS, Instagram, X and the live streams are fetched by the
**device** from third-party endpoints (jsDelivr, youtube.com, instagram.com,
syndication.twitter.com, the live-source URLs). These must be re-implemented in the
iOS client, and each carries its own platform/ToS fragility (§11.4).

---

## 9. iOS system restrictions (the part that decides the product)

This section is the reason the recommendation is "share logic, rewrite everything
else". I verified what I could against Apple documentation; where a page renders
only via JavaScript and returned no text, I attribute the claim to the documentation
URL and mark confidence.

### 9.1 There is no iOS equivalent of Android's accessibility-based monitoring

Android's whole blocker rests on one capability: a running service that can read
**another app's** view hierarchy and act on it. iOS deliberately has no such
capability for third-party apps. Apple's own Accessibility framework
(`UIAccessibility`) is for making *your own* app usable with VoiceOver/Switch
Control; it does not expose foreign UI trees, and there is no `performGlobalAction`,
no cross-app gesture injection and no draw-over-other-apps surface.

**Consequence:** ClearView's Chrome/Google/YouTube monitoring, its incognito
detection, its YouTube Shorts/title blocking, its pre-emptive feed-card blocking and
its full-screen overlay **cannot be reproduced**. The rule *engine* survives; the
*trigger* does not. **[verified by the absence of any such API in the frameworks
referenced below; treat as certain in practice.]**

### 9.2 Screen Time frameworks (the closest legitimate substitute)

`FamilyControls`, `ManagedSettings` and `DeviceActivity` (iOS 15+) are Apple's
supported screen-time APIs. Key facts **[verified via Apple developer documentation
and an independent practitioner guide — see sources]**:

- **FamilyControls** requests the user's authorisation and yields **opaque
  `ApplicationToken` / `ActivityCategoryToken` values**. A parental-control app can
  *shield* or *limit* an app or category **without ever learning which app it is**.
  There is no way to enumerate installed apps.
- **ManagedSettings** applies shields/restrictions (app shields, web-content filters,
  and account/media restrictions of the kind Screen Time exposes).
- **DeviceActivity** schedules windows and monitors usage, and can fire
  `DeviceActivityMonitor` events at thresholds (e.g. "used 30 minutes").
- **Entitlement gate:** you can build and test locally with
  `com.apple.developer.family-controls.development`, but **you cannot ship to
  TestFlight or the App Store until Apple approves a separate
  "Family Controls (Distribution)" request** — requested **per bundle id and per
  Screen Time extension** (Device Activity Monitor, Device Activity Report, Shield
  Action, Shield Configuration). Manual review; developers commonly report **several
  business days to a few weeks**, with reports of longer waits and rejections for a
  vague or unnecessary use case. Apple evaluates whether Screen Time access is
  **genuinely central** to the app, and refuses use for advertising/profiling.
- **This is an uncertainty and a schedule risk, not a promise:** the entitlement may
  be granted, granted with conditions, or refused, and it can take longer than the
  whole rest of the migration.

**What it buys ClearView:** app/category shielding (block the YouTube/Instagram/X
apps by token, or whole categories), scheduled limits, and web-content filtering —
system-enforced, so it cannot be dismissed with an overlay or bypassed by switching
browsers. **What it does not buy:** live reading of *what* is on screen, selective
blocking of YouTube Shorts inside the YouTube app, or blocking a keyword the user
types into a third-party app.

### 9.3 Safari Content Blocker (the substitute for URL/keyword blocking)

A **Content Blocker extension** supplies Safari a set of **declarative rules** that
tell it what to block in the browser window (Apple: *"Content blockers are app
extensions that you build using Xcode. They indicate to Safari a set of rules to
use to block content"*). **[verified via Apple documentation URL; the page's body is
JS-rendered so I could not extract more than the title/description.]**

Practical capabilities and limits:
- Rules are **declarative** (JSON compiled to WebKit rules): block by URL filter
  (with `url-filter`, `resource-type`, `load-type`, `if-domain`, `unless-domain`,
  `regex`), plus `css-display-none`, `block-cookies`, `ignore-previous-rules`.
- It applies **only inside Safari** (and to `SFSafariViewController`/
  `WKWebView`-based Safari surfaces per Apple's rules). It **does not** apply to
  third-party browsers (Chrome/Firefox on iOS use their own engines now but the
  extension API is Safari's), and it does **not** apply to in-app web views.
- It **cannot classify page content** or block based on text the user types; it
  matches URLs/resources. So "block a search for a keyword" becomes "block the
  search-results URL pattern", which is coarser and can over/under-block.
- It cannot draw an overlay or return the user home.

**[verified for mechanism; the exact third-party-browser behaviour is version-
dependent → mark [uncertain] and test on target iOS.]**

### 9.4 Background execution, alarms and widgets

- **`BGTaskScheduler`** app-refresh tasks are **opportunistic**: you request an
  earliest begin date and the system decides whether/when to run, with a daily
  budget; a task typically gets ~30 seconds. You cannot promise "every 15 minutes".
  **[verified via WWDC/support material snippets.]**
- **Widgets (WidgetKit):** Apple states *"WidgetKit imposes a minimum amount of time
  before it reloads a widget"* and timelines should have entries *"at least about
  5 minutes"* apart; there is a daily refresh budget and `WidgetCenter.reloadTimelines`
  for app-driven updates. **[verified via Apple documentation snippet.]** The Quran
  and Todo widgets are achievable; "always instantly in sync" is not, and must be
  worded as "updates when the app changes it".
- **Alarms:** no Clock-app integration; `UNUserNotificationCenter` can post
  time-sensitive notifications (and critical alerts with a separate entitlement) but
  a recurring exact alarm that rings like an alarm clock is not available to normal
  apps.
- **Continuous playback:** background **audio** is fully supported with the
  `audio` background mode + `AVAudioSession(.playback)`; background **video** is not
  a supported mode for a general app.

### 9.5 Device management, uninstall protection and MDM

- A normal App Store app **cannot** prevent its own uninstall, cannot be a device
  admin, and cannot lock the device. Android's `DeviceAdminReceiver` friction and
  Device-Owner `setUninstallBlocked` have **no App Store equivalent**; the closest is
  MDM on a **supervised/managed** device (enterprise or Family Sharing-managed),
  which is a different distribution model.
- Apple's App Review Guidelines tie device management and content-filtering APIs to
  **approved providers**: MDM apps must request the mobile device management
  capability and may only be offered by approved providers; and *"Parental control,
  content blocking, and security apps, among others, from approved providers may also
  use the `NEVPNManager` API."* **[verified via App Store Review Guidelines snippet.]**
  A **Network Extension / NEFilter** (content filter) is therefore a *possible* third
  blocking mechanism for approved providers, but it requires an Apple-approved
  Network Extension entitlement and a managed/NEFilterProvider architecture — a
  substantially heavier route than Screen Time, and not something to promise.
  **[uncertain]** for ClearView's eligibility.

### 9.6 Secure storage, offline, credentials

- **Keychain** replaces `EncryptedSharedPreferences` (used for `AdminTokenStore`).
- App-sandbox files replace `filesDir`; `URLCache`/files for offline feeds.
- **No hardware limitations** apply to the Quran's offline text or the media cache.

### 9.7 App Store policy risks to plan for **[uncertain — policy judgement]**

1. **Screen Time entitlement approval** (§9.2) — the gating risk.
2. **Scraping third-party platforms** (Instagram non-RSS, X syndication, RSS-Bridge,
   the YouTube `/shorts` scrape). The code itself records that X shut down its
   community mirrors in Sept 2026. App Review may treat systematic scraping of a
   third-party service without authorisation as a violation. Treat these as
   best-effort and be ready to swap them behind the existing source abstraction
   (`MediaSourceStatusStore` + per-source resolver) or move them server-side.
3. **NewPipe GPL code** (§11.4) — must not be linked into an App Store binary.
4. **Content-blocking/parental-control category** — the Play listing's
   accessibility declaration has an iOS analogue in the privacy declarations and
   the Family Controls justification; the product must be described honestly.

---

## 10. Architecture comparison and rationale

Weights are for *this* repository (a large, platform-integration-heavy, existing
Android app with a reusable backend).

| Criterion (weight) | A: KMP + SwiftUI | B: Compose MP | C: Pure Swift | **D: Hybrid** |
|---|---|---|---|---|
| Practical reuse of existing Kotlin rules | **High** | Medium | None | **High** |
| iOS UI quality / native feel | **High** | Low–Medium | High | **High** |
| Migration complexity for *this* codebase | Medium | **High** (view interop, no nav to share) | Medium | **Medium** |
| Compatibility with Android-only deps | **Good** (they stay Android-side) | Poor | N/A | **Good** |
| Ability to reproduce current features | Same as any iOS option — limited by §9 | limited | limited | **limited but honest** |
| Long-term maintenance across 2 platforms | **Best** (one domain) | Good (one UI too, but non-native) | Worst (two domains) | **Best** |
| Debugging / testing complexity | Medium–High (KMP toolchain) | High | Low | **Medium–High** |
| Performance / offline | **High** | Medium | High | **High** |
| Dependency on platform code | Bounded to the shared module | Sprawls into UI | Sprawls everywhere | **Bounded** |
| App Store constraints | Same | Same | Same | **Same** |
| **Verdict** | Strong | **Rejected** | **Rejected** | **Recommended** |

**Why D over A:** they are the same architecture with one explicit rule — *never
share UI*. Naming it prevents scope creep back toward Compose MP.
**Why D over B:** §3.2, Option B — the UI is Android-view-interop-heavy, there is no
navigation graph to share, and the product's value is the platform integrations
Compose MP does not abstract.
**Why D over C:** it keeps ~10k lines of Android-free Kotlin and ~90 test files, and
it keeps the Good Post API contract in one language, so a future API change is one
change rather than two.

**Consequence to accept:** the shared module is bounded by pragmatism, not purity.
I recommend **three shared targets** (`commonMain`: rules, models, API clients,
parsers; `androidMain`: `HttpURLConnection`/`org.json` adapters and the accessibility
extractors stay here; `iosMain`: Darwin engine + Keychain adapter) so the Android app
can adopt the module incrementally without a rewrite.

---

## 11. Risks, unknowns, external dependencies, costs, capabilities

### 11.1 Highest risks (ordered)

1. **Family Controls (Distribution) entitlement** — may be slow or refused; blocks
   the entire "blocking" story. **Mitigation:** file it first; build everything else
   in parallel; design the blocking feature to degrade to "Safari-only content
   blocker + rules editor" if the entitlement is not granted. **[uncertain]**
2. **Feature expectation gap** — users who came for Android-style live monitoring
   will not get it. **Mitigation:** an in-app explainer + a rewritten App Store
   listing that sells the substitute, not the original.
3. **Scope size** — this is a 98k-line app with five sub-products. **Mitigation:**
   the phased plan (§13) and one-vertical-slice-first rule.
4. **Third-party source fragility / ToS** (§9.7).
5. **NewPipe GPL / ToS** (§11.4).
6. **Background refresh expectations** — iOS cannot promise 15-minute checks (§9.4).

### 11.2 Unknowns to resolve before or during Phase A

| # | Unknown | How to resolve |
|---|---|---|
| U1 | Target **iOS deployment target** — Floor 15+ for Screen Time; 16+ for current WidgetKit APIs; iOS 26 is current (2026). | Decide product-wide; **assumed iOS 17+** here unless family reach argues lower. |
| U2 | Mac/architecture & Xcode version | On the MacBook: `xcodebuild -version`, `uname -m`, `xcode-select -p`. Not detectable from the repo. |
| U3 | Do we ship one app or two (parent/child)? | Product decision; Screen Time supports single-device self-control. |
| U4 | Family Controls approval timeline for this Apple Developer team | Submit the request in Phase A and track it. |
| U5 | Whether to route fragile scrapes server-side | Architecture decision; the per-source abstraction already permits it. |
| U6 | App Store: is an MDM/Network-Extension route acceptable? | Probably not worth it; confirm with counsel/Apple. |

### 11.3 Required Apple capabilities / entitlements (checklist)

| Capability | Needed for | Approval |
|---|---|---|
| Family Controls (Development) | local testing of Screen Time | none (local) |
| **Family Controls (Distribution)** | shipping Screen Time | **Apple request, per bundle id + per extension** |
| App Groups | share data between app + extensions (widgets, blockers, DeviceActivity monitor) | none |
| Background Modes: Audio | background Quran/media audio | none |
| Background Modes: App Refresh / Processing | BGTaskScheduler | none |
| Push Notifications + APNs key | Good Post updates | Apple Developer account |
| Keychain Sharing (optional) | shared secrets between app + extension | none |
| Critical Alerts | loud todo alarms | **Apple request** (optional) |
| Network Extension (only if attempting NEFilter) | provider-approval route | **Apple request + guidelines** |

### 11.4 Accessibility / licensing note (must not be skipped)

`NewPipeExtractor` is **GPL-3.0-or-later** and is used to resolve YouTube audio
streams on-device (`media/download/NewPipeDownloader.kt`,
`media/download/OnDeviceStreamExtractor.kt`, `media/download/AudioDownloader.kt`,
`libs.versions.toml`). **Do not port it to iOS**: (a) GPL-3.0 is incompatible with an
App Store distribution if the iOS app is not itself GPL, and (b) it circumvents
YouTube's delivery rules. On iOS, background audio for YouTube content cannot be
provided by an independent extractor without the same problems; the honest options
are to support background audio only for sources you may legitimately play
(Instagram/X progressive media, downloaded Quran/audio, RSS-served media) and to drop
the YouTube audio-extraction feature on iOS.

### 11.5 Rough cost envelope **[assumed, for planning only]**

Assumption: **one senior iOS+KMP engineer, full-time**, already fluent; excludes
Family Controls approval lead time and App Store review.

| Workstream | Dev-days (est.) |
|---|---|
| Phase A–C setup + shared module + shell + design tokens | 20–30 |
| Quran slice (incl. widget) | 15–22 |
| Good Post read-only + identity + notifications | 25–35 |
| Media hub (feeds, filters, players, background audio) | 45–65 |
| Todo suite (incl. alarms, widget, progress card) | 30–45 |
| Phone Limit (Screen Time substitute) | 8–12 |
| Blocking rules editor + Safari content blocker | 15–25 |
| Screen Time shielding integration (if entitled) | 10–20 |
| Good Post write/admin + ads + directory | 30–45 |
| Test migration + UI tests | 20–30 |
| Distribution prep (entitlements, privacy, TestFlight, review) | 10–20 |
| **Total** | **≈ 230–350 dev-days (~9–14 person-months)** |

At a two-engineer split (one KMP, one SwiftUI) after Phase C, a realistic calendar
estimate is **5–8 months to a full-featured 1.0**, *conditional on the Family
Controls entitlement*. A **useful iOS app without Screen Time blocking** (Quran +
Media + Good Post + Todo) is achievable in roughly **3–4 months**.

---

## 12. Proposed directory structure

### 12.1 Repository (additive — Android is not disturbed)

```
ClearView/
├── app/                          # UNCHANGED Android application
├── server/                       # UNCHANGED backend (additive APNs + store-link work)
├── shared/                       # NEW: Kotlin Multiplatform
│   ├── build.gradle.kts          # kotlin("multiplatform")
│   ├── src/commonMain/kotlin/com/muddassir/clearview/shared/
│   │   ├── matching/             # KeywordMatcher rules, normalization, boundaries, ContentSnapshot
│   │   ├── media/
│   │   │   ├── model/            # MediaVideo, MediaPlatform, FeedFilter, SavedChannel…
│   │   │   ├── filter/           # FeedFilters, DownloadFilters
│   │   │   └── parse/            # YouTubeRssParser, PlaylistPageParser, YouTubeUrlParser,
│   │   │                         #   InstagramRssParser, XFeedParser  (kotlinx-serialization)
│   │   ├── quran/                # QuranVerse, QuranJsonParser, QuranTextIntegrity, DhikrCodec
│   │   ├── todo/                 # TodoItem, TodoCodec, TodoStats, ProgressCardStats, Completion
│   │   ├── goodpost/             # GoodPostModels, GoodPostText, GoodPostErrors, DirectoryCodec
│   │   ├── net/                  # Ktor client + typed API clients (GoodPost, brainrot, directory, ads)
│   │   └── platform/             # expect: log(), storage, clock, httpEngine, dispatcher
│   ├── src/commonTest/kotlin/    # ported JVM tests (boundary matching, normalisation, codecs…)
│   ├── src/androidMain/kotlin/   # HttpURLConnection/org.json adapters (for the Android app)
│   └── src/iosMain/kotlin/       # Darwin engine, Keychain adapter, NSUserDefaults storage
├── ios/                          # NEW: Xcode project (SwiftUI)
│   ├── ClearView.xcodeproj
│   ├── ClearViewApp/             # app target (SwiftUI)
│   │   ├── App/                  # @main, Router, TabView, deep links, AppDelegate/UN delegate
│   │   ├── Design/               # ThemeTokens.swift (colours/type/spacing ported from ui/theme)
│   │   ├── Features/
│   │   │   ├── Quran/ Media/ GoodPost/ Todo/ Blocking/ PhoneLimit/ Directory/ More/
│   │   ├── Services/             # ScreenTime, Notifications, Audio, Keychain, Firebase, Push
│   │   └── Resources/            # fonts (licenses/), GoogleService-Info.plist, Assets
│   ├── SharedKotlin/             # generated/referenced KMP framework (XCFramework)
│   ├── ContentBlockerExtension/  # Safari Content Blocker target
│   ├── ShieldConfigurationExt/   # Screen Time extension (if entitled)
│   ├── DeviceActivityMonitorExt/ # Screen Time extension (if entitled)
│   └── Widgets/                  # WidgetKit: Quran + Todo widgets
└── docs/IOS_MIGRATION_PLAN.md    # this file
```

### 12.2 Boundaries (the contract)

- **SwiftUI never sees Kotlin UI types.** It consumes plain shared *models* and
  suspending functions exposed via the KMP framework (`async`).
- **Kotlin never triggers platform side-effects** (no notifications, no shields,
  no file writes to platform paths) — it returns values/results; Swift performs the
  effect. This keeps the shared code testable on a JVM and keeps entitlements out of it.
- **Persistence stays native** (Keychain/UserDefaults/files); the shared module
  receives and returns data, never opens storage itself.
- **The API surface is typed in `commonMain`** so a server change breaks the build,
  not the device.

---

## 13. Phased implementation roadmap

Effort units are dev-days for one senior engineer. Every milestone lists: deliverables,
dependencies, relevant existing files, key decisions, acceptance criteria, risks.

### Phase A — Environment and project setup

**Required now** (do not defer):
1. On the MacBook, record: `xcodebuild -version`, `uname -m`, `xcode-select -p`,
   `swift --version`, available simulators. **[assumed]** Apple silicon + Xcode 16/17.
2. Install the KMP toolchain: Kotlin **2.2.10** (match Android), Gradle **9.5**
   (match the wrapper), JDK 21 (match `gradle-daemon-jvm.properties`). Add
   `kotlin("multiplatform")` and (for iOS framework output) the Kotlin CocoaPods or
   direct-framework integration.
3. Create the `shared/` Gradle module with `iosX64/iosArm64/iosSimulatorArm64` targets.
4. Create the Xcode project + add the KMP framework as a build dependency.
5. **Submit the Family Controls (Distribution) entitlement request immediately** —
   it is the long pole (§9.2). Add the *development* entitlement and build a throwaway
   Screen Time spike to prove signing.
6. Create an Apple Developer App ID + bundle id (`com.muddassir.clearview`), an APNs
   key, and the Firebase iOS app entry in the existing Firebase project
   (`clearview-28413`) so `GoogleService-Info.plist` exists.
7. Add the iOS OAuth client to the Google Cloud project and record its
   `GOOGLE_WEB_CLIENT_ID`.

**Can wait:** TestFlight setup, App Store Connect metadata, the exact iOS deployment
target if it only affects a few APIs (**settle it now if possible** — it affects
availability of Screen Time/WidgetKit features).

**Acceptance:** `./gradlew :shared:build` produces an XCFramework; a hello-world
SwiftUI app launches in the simulator and calls one shared Kotlin function (e.g.
`KeywordMatcher.normalizeForMatching("p.o.r.n")` returns `"porn"`).

**Risks:** KMP + Kotlin 2.2/Gradle 9.5 compatibility; Xcode↔Gradle script-phase setup.

### Phase B — Project architecture and shared-module extraction

**Deliverables:** `shared/` populated with the R1/R2 domain code from §4; the
`platform` `expect`/`actual` seams; ported `commonTest`s; the Xcode target layout of
§12.1.

**Dependencies:** Phase A.

**Relevant existing files:** `matching/KeywordMatcher.kt`, `media/model/*`,
`media/util/*`, `media/data/YouTubeRssParser.kt`, `quran/data/QuranJsonParser.kt`,
`quran/data/QuranTextIntegrity.kt`, `todo/model/TodoItem.kt`, `todo/data/TodoCodec.kt`,
`todo/data/TodoStats.kt`, `goodpost/data/GoodPostModels.kt`, `goodpost/data/GoodPostText.kt`,
`goodpost/data/DirectoryModels.kt`, `brainrot/BrainRotStats.kt`.

**Key decisions:** JSON library (`kotlinx.serialization`), HTTP client (Ktor),
coroutines `Dispatchers` on Darwin, `expect` for log/storage/clock.

**Acceptance:** the ported unit tests (target: port ≥ 40 of the 90 JVM tests) pass in
`commonTest` on `jvm` and `iosSimulatorArm64`; a shared `GoodPostApi` call succeeds
against the deployed Render host from a simulator.

**Risks:** scope creep (shared module absorbing UI); XML parser replacement;
timezone handling in `FeedFilter`.

### Phase C — Foundation (shell, theme, networking, persistence, navigation)

**Deliverables:** SwiftUI `TabView` (Quran/Media/Good Post/More), `Router`,
`NavigationStack`s, deep-link + notification routing, `Design/ThemeTokens.swift`
(colours/typography/spacing from `ui/theme/*`), `UserDefaults`/Keychain/file
persistence adapters, the Ktor client wired to `GOODPOST_BASE_URL`, error vocabulary
from `GoodPostErrors.kt`, and an app-level logging/error surface.

**Dependencies:** Phase B.

**Relevant files:** `MainActivity.kt`, `ui/ContentHub.kt`, `ui/theme/*.kt`,
`ui/MoreTab.kt`, `LauncherActivity.kt`, `network_security_config.xml` (HTTPS-only).

**Acceptance:** four tabs navigate; a deep link opens Good Post; the app configures
the backend URL and shows the honest "not set up" state when empty; palette/type
match the Android app (spot-check against `ui/theme/Color.kt`).

**Risks:** reproducing the glass bottom bar and Good Post's fixed dark surfaces;
getting the notification/deep-link fan-out equivalent to the ten `LaunchedEffect`s.

### Phase D — Feature migration (milestones)

Ordered by dependency and by "prove the architecture first".

**D1 — Quran (the first vertical slice).** Requirement: a working end-to-end slice.
Deliverables: verse of the day (download + cache + parse), surah reader with Arabic
scale, bookmarks/starred/reading positions, Dhikr counter, WidgetKit verse widget,
optional local notification, Islamic date. Deps: C. Files: `quran/**`,
`widget/QuranReminderWidgetProvider.kt`, `worker/*`. Acceptance: works fully offline
after first download; widget shows the current verse and updates when the app changes
it; reading position survives relaunch; the ported `QuranJsonParser` tests pass.
Risk: font licensing/rendering (`licenses/digitalkhatt_indopak`, `scheherazade_new`).

**D2 — Good Post read-only + identity + notifications.** Deliverables: channel list,
search/Explore, channel page, posts feed with keyset pagination, images, reactions,
follows (Firebase anonymous), cached offline read, notification permission +
APNs registration. Deps: C, Phase A step 6. Files: `goodpost/data/*` (transport,
models, cache), `goodpost/ui/GoodPostHome.kt`, `GoodPostFeed.kt`,
`GoodPostChannelInfo.kt`. Acceptance: the tab opens instantly from cache, then
refreshes; follow/unfollow persists across relaunch (Firebase uid stable); a push
from the backend arrives and opens the channel. Risk: FCM/APNs wiring; the anonymous
identity must be created once (the Android code documents a real bug about duplicate
anonymous uids — replicate the locking).

**D3 — Media hub.** Deliverables: saved channels + playlists, unified feed with the
full filter model, YouTube RSS, Instagram, X (behind per-source status), YouTube
IFrame in `WKWebView`, `AVPlayer` video, HLS live tab, background audio player with
sleep timer, downloads with a storage policy. Deps: B (parsers), C. Files:
`media/**`. Acceptance: the feed's default (Last 3 days / Unwatched / Newest)
matches the Android app; watched state round-trips; background audio keeps playing
with lock-screen controls; a lapsed stream re-resolves once. Risk: **largest
workstream**; scraping fragility; the NewPipe feature is deliberately dropped.
**Acceptance criterion for the dropped feature:** document the omission in the iOS
release notes rather than shipping a broken button.

**D4 — Todo suite.** Deliverables: list/editor with the three behaviours, permanent
history, Time-Todo adjustments, snooze rules, progress card + share, Todo widget,
reminders (time-sensitive notifications) and a custom alarm screen. Deps: B
(codec/stats), C. Files: `todo/**`. Acceptance: `TodoCodec` round-trips a list
produced by the Android codec (write a fixture test); attempted/time states and
history behave identically; deleting with history offers the same two choices; the
progress card renders and shares. Risk: alarm parity (§9.4) — word the UI honestly.

**D5 — Directory, ads, Good Post write/admin.** Deliverables: directory screen,
ad cards, composer (text + media upload via presign→PUT→confirm), edit/delete,
admin sign-in (email/password + Google), creator onboarding. Deps: D2, Phase A step 7.
Files: `directory/**`, `goodpost/ui/GoodPostComposer.kt`, `GoodPostAds.kt`,
`GoodPostAdmin.kt`, `goodpost/data/GoodPostUploads.kt`. Acceptance: publish an
image post end-to-end and see it on Android. Risk: upload/`AVAssetImageGenerator`;
admin permission model (server enforces it — mirror the UI only).

**D6 — Brain Rot + rules editor.** Deliverables: rules fetch/cache, submission/report,
status list, the full keyword/domain/strict-mode editor, the password gate. Deps: C.
Files: `brainrot/**`, `repository/BlockRepository.kt`, `ui/BlockTab.kt`. Acceptance:
the editor's rules are reflected in the shared matcher's unit tests and are exported
as Safari content-blocker rules.

### Phase E — Restricted / platform-specific features

**Deliverables:** Safari Content Blocker extension compiling `BlockRepository` rules
to WebKit JSON; Screen Time integration (FamilyControls auth, ManagedSettings shields
for distracting apps/categories, DeviceActivity schedules) **conditional on the
entitlement**; the Phone Limit substitute built on DeviceActivity thresholds; a
"Protection" screen that explains exactly what iOS can and cannot do (this is a
deliverable, not a nicety).

**Dependencies:** Phase A step 5 (**approval**); D6.

**Acceptance:** with the development entitlement, shielding a category blocks the
apps and surviving a relaunch; the Safari extension blocks a configured domain in
Safari; the app states the limitations in-app; **if the entitlement is refused**,
the Safari blocker + rules editor still ship as the blocking story.

**Risks:** approval timing/refusal; extension signing per bundle id; the Apple
requirement that each Screen Time extension have its own approved request.

### Phase F — Testing and validation

**Deliverables & acceptance criteria:**
- **Shared-logic tests:** the ported `commonTest` suite (target: the matching,
  media, todo, quran, goodpost codec tests) runs on `iosSimulatorArm64` in CI.
- **Unit tests (Swift):** API clients, view models, formatters, date logic.
- **UI tests:** XCUITest for the four tabs, deep links, the Quran flow, publish flow.
- **Integration:** publish→read→react→notify against the deployed backend (or a local
  server with `npm run dev`); verify cached/offline reads.
- **Offline tests:** airplane-mode first launch per tab; Quran fully offline after
  first download; cached Good Post readable.
- **Permission tests:** notification denial, Screen Time authorization denial,
  Keychain locked, backend URL empty.
- **Device testing:** real iPhone + simulator; **iOS version coverage** decided in A.
- **Regression:** the Android `./gradlew test` suite must still pass after the
  shared-module extraction (run it in Phase B).

**Risk:** KMP test infrastructure on CI (macOS runner required).

### Phase G — Distribution preparation

**Deliverables/checklist:** App ID + capabilities (App Groups, Background Modes,
Push, Family Controls once approved); distribution provisioning profiles for **the
app and every extension**; `PrivacyInfo.xcprivacy` privacy manifest (network access,
no tracking — matching the Android "no data collected" posture); App Privacy answers;
age rating (parental-control framing → likely 12+/17+); TestFlight internal then
external; App Store listing rewrite (see §9.7 — sell the substitute, not the Android
mechanism); the in-app limitation explainer; the support/Help row the Android notes
ask for; and the `/c/app.js` store-link update on the backend.

**Acceptance:** TestFlight build installs cleanly; the share link opens the iOS app;
publishing works from the store build; review submission includes the Screen Time
justification, if applicable.

**Risks:** review rejection over scraping/branding/entitlement; the store-link
fallback pointing at the wrong store.

### Milestone acceptance summary

| Milestone | Acceptance (one line) |
|---|---|
| A | Shared framework builds; hello-world app calls shared Kotlin. |
| B | ≥40 ported tests green on both JVM and iOS simulator. |
| C | Four tabs, deep link, theme, backend config, honest empty state. |
| D1 | Quran fully offline + widget + notification, first end-to-end slice. |
| D2 | Good Post read-only + follows + push, cached and offline-capable. |
| D3 | Unified media feed with the full filter model + background audio. |
| D4 | Todo parity incl. history, three behaviours, alarms, widget, card. |
| D5 | Directory, ads, publish an image post end-to-end. |
| D6 | Rules editor feeding the shared matcher + Safari blocker rules. |
| E | Screen Time shielding (if entitled) or Safari blocker + explainer. |
| F | Shared + Swift unit tests, UI tests, offline/permission tests pass. |
| G | TestFlight green; share link opens the app; listing + privacy done. |

---

### Implementation status — iOS logic layer (October 2026)

A snapshot of what actually exists in `ios/`, so the next session does not have to
re-derive it. **Scope of this pass: the logic layer only.** Tab screens are still
`ComingSoonView` placeholders, and accessibility work has not started.

**Ported and tested (`ClearViewTests`, 166 tests, 1 opt-in live test skipped):**

| Area | Swift files | State |
|---|---|---|
| Quran reader + reminder (D1) | `Features/Quran/*` | Surah list, reader, bookmarks, reading positions, verse stepping, Arabic text size, current-verse persistence, all offline-capable |
| Islamic date (D1) | `Features/Quran/IslamicDate.swift` | Umm al-Qura via `.islamicUmmAlQura`; verified against the JVM anchors in `IslamicDateFormatterTest` (2025-01-01, 2025-06-26, 2026-08-10) so both platforms agree |
| Quran reminder notification (D1) | `QuranReminder.swift`, `QuranReminderNotifier.swift`, `QuranReminderSettingsModel.swift` | Interval (1/3/6/12/24 h), notification toggle, permission refusal handling, repeating local notification, foreground post |
| Dhikr counter | `DhikrItem.swift`, `DhikrCodec.swift`, `DhikrStore.swift`, `DhikrCounterModel.swift` | Built-ins, targets, attempted/completed history, ordering, visibility, persistence |
| Todo domain (D4) | `Features/Todo/TodoItem.swift`, `TodoCodec.swift`, `TodoCalendar.swift`, `TodoStore.swift` | Full codec, applicability, strict windows with refusal reasons, soft delete, filters/sorts, occurrence history and clear watermarks, labels |
| Media link handling (D3) | `Features/Media/YouTubeLink.swift`, `ShortsIdResolver.swift` | The single YouTube URL parser (watch/shorts/live/embed/short-link/bare id, `t=` offsets, host validation), playlist ids, Shorts detection |
| Media feed filter (D3) | `Features/Media/MediaVideo.swift`, `FeedFilter.swift` | The feed item model (YouTube / Instagram Reel-vs-post / X post classification, offline-audio rows) and the full filter: date presets incl. custom ranges, platform+content together, watch status thresholds, source, sort, JSON persistence with Android's migrations, and the summary line |
| Media channel feed (D3) | `Features/Media/YouTubeRssParser.swift` | Channel RSS → feed items, with Shorts classified from YouTube's own canonical link, the hashtag/scrape fallbacks, the live-thumbnail signal and per-entry tolerance |
| Good Post inline formatting | `Features/GoodPost/GoodPostText.swift` | The WhatsApp-style marker model (`*bold*`, `_italic_`, `` ```monospace``` ``, `~strikethrough~`) and the toolbar toggle: wrap, unwrap inside, unwrap outside, caret insert, whitespace trimming |
| Channel directory | `Features/GoodPost/DirectoryModels.swift` | The external-channel directory models, the tolerant codec and the offline cache round trip |
| Protection activity | `Features/Protection/AnonymousId.swift`, `BlockActivity.swift` | The anonymous device id (canonical-UUID validated), the block-event log with its 500-event cap, the Activity summary (today/week/top-N/streak) and the submission status rules |
| Good Post local read state | `Features/GoodPost/GoodPostLocalState.swift` | Hidden posts ("delete for me"), counted views (so a restart cannot inflate a counter) and stars that keep the words — all bounded, all surviving a relaunch |

**Not started:** the Media feed's network layer, players, downloads and playback
(§6.5); the Good Post network layer — models, anonymous identity/session, the API
client, cache and push (§6.7); the keyword matcher and the rules editor (§6.2/6.6);
ads and uploads (§6.7); Phone Limit; WidgetKit extensions; the Safari content
blocker; Screen Time/Family Controls; the Todo statistics suite
(`TodoStats`/`ProgressCardStats`), the Todo reminder scheduler and the progress card;
and every SwiftUI screen for the three unfinished tabs.

**Known gaps inside what is ported:** the Todo domain has no `@Observable` model yet
(the codec and store are done, the screen's state machine is not), and the Quran
Arabic text still renders in the system font rather than the licensed IndoPak face in
`licenses/`.

---

## 14. Android-to-iOS system API mapping

See §7 for the full table. The one-line summary: **storage, networking, media
playback, HLS, haptics, widgets and push all have close iOS equivalents; live
cross-app inspection, cross-app overlays, device admin, arbitrary usage stats,
exact alarms and screen locking do not.**

---

## 15. Prioritized first tasks (when implementation is authorized)

1. **File the Family Controls (Distribution) entitlement request** (bundle id +
   every planned extension). Everything else can proceed while it is reviewed.
2. **Record the environment facts (U2)** on the MacBook: Xcode, Swift, macOS arch,
   simulators; write them into this plan's §11.2.
3. **Create `shared/` and prove the toolchain**: one KMP module producing an
   XCFramework consumable by a throwaway SwiftUI app.
4. **Port the keyword matcher rules + its tests first** — highest value, no
   entitlement, and it validates the `commonMain` boundary immediately.
5. **Create the Xcode project skeleton** (app + App Groups + extension targets) and
   the `Design/ThemeTokens.swift` from `ui/theme/*`.
6. **Build the Quran vertical slice (D1)** end-to-end, including the WidgetKit widget.
7. **Set up an APNs key + Firebase iOS app entry** so D2 is not blocked.
8. **Stand up a macOS CI job** that runs the shared tests and a simulator build.

---

## Appendix A — What was inspected, and what was not

**Inspected (read in full or in substantial windows):**
`settings.gradle.kts`, `build.gradle.kts`, `app/build.gradle.kts`, `gradle.properties`,
`gradle/libs.versions.toml`, `gradle/wrapper/gradle-wrapper.properties`,
`gradle/gradle-daemon-jvm.properties`, `app/src/main/AndroidManifest.xml`,
`res/xml/{accessibility_service_config,device_admin_policies,quran_reminder_widget_info,todo_widget_info,network_security_config}.xml`,
`MainActivity.kt`, `LauncherActivity.kt`, `viewmodel/MainViewModel.kt` (partial),
`matching/KeywordMatcher.kt` (substantial), `repository/BlockRepository.kt` (targeted),
`extractor/ContentExtractor.kt` (head), `service/UrlBlockerService.kt` (head) and
`youtubetest/YouTubeChromeTestCoordinator.kt` (head), `phonelimit/PhoneLimitService.kt`,
`phonelimit/PhoneLimitCoordinator` (referenced), `brainrot/BrainRotClient.kt`,
`backend/ClearViewBackendClient.kt`, `goodpost/data/GoodPostIdentity.kt`,
`todo/data/TodoStore.kt`, `todo/model/TodoItem.kt`, `quran/data/{QuranApi,QuranJsonParser,QuranTextIntegrity,QuranStore}.kt`,
`media/data/{XSource,YouTubeRssParser,MediaRepository(head)}.kt`,
`media/model/{MediaVideo,FeedFilter}.kt`, `directory/ui/ChannelDirectoryScreen.kt`,
`goodpost/data/DirectoryModels.kt`, `docs/{ARCHITECTURE_ANALYSIS,GOODPOST,MEDIA_PLAYBACK,play-store-listing}.md`,
`server/{README.md,package.json,src/app.ts}`, plus directory listings, import scans,
line counts and the full test-file inventory for `app/src/test`, `app/src/androidTest`
and `server/tests`.
Also read: the author's `Notes.md` (the Media/Todo backlog).

**Not inspected line-by-line (recorded honestly):** the interiors of the largest
Compose files (`media/ui/MediaTab.kt` 5 287, `goodpost/GoodPostViewModel.kt` 5 030,
`todo/ui/TodoScreen.kt` 3 798, `media/ui/VideoPlayerScreen.kt` 3 220,
`ui/ContentHubSheets.kt` 2 715, `ui/BlockTab.kt` 2 654, `goodpost/ui/GoodPostStyle.kt`
2 300), `extractor/ContentExtractor.kt` beyond the head, `service/UrlBlockerService.kt`
beyond the head, `todo/data/TodoCodec.kt`/`TodoStats.kt` interiors, the `server/src/*`
route bodies, `server/migrations/*`, the remaining docs
(`MANUAL_TEST_PLAN.md`, `WHATSAPP_CHANNELS_UX.md`, `AWS_S3_SETUP.md`,
`privacy-policy.html`) and `index.html`. Conclusions about *behaviour* in those areas
are drawn from the file's own KDoc, its call sites and the architecture docs, and are
marked **[inferred]** where they appear.

**Not done (out of scope, per the brief):** no build, no test run, no device run, no
code change, no dependency change, no Xcode project, no commit, no push.

---

## Appendix B — Sources for iOS platform claims

- Apple, *Screen Time Technology Frameworks* —
  https://developer.apple.com/documentation/screentimeapidocumentation
- Apple, *Family Controls* — https://developer.apple.com/documentation/familycontrols
- Apple, *Requesting the Family Controls entitlement* —
  https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement
- Apple, *Creating a content blocker* —
  https://developer.apple.com/documentation/safariservices/creating-a-content-blocker
- Apple, *Keeping a widget up to date* (WidgetKit refresh minimum / budget) —
  https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date
- Apple, *Finish tasks in the background* (WWDC25) —
  https://developer.apple.com/videos/play/wwdc2025/227/
- Apple, *App Review Guidelines* (MDM/approved-provider and parental-control /
  `NEVPNManager` language) — https://developer.apple.com/app-store/review/guidelines/
- Apple, *Device management restrictions for iPhone and iPad* —
  https://support.apple.com/guide/deployment/restrictions-for-iphone-and-ipad-dep0f7dd3d8/web
- Newly, *How to Get the Apple Family Controls Entitlement* (entitlement keys,
  per-extension requests, review timeline, common rejections) —
  https://newly.app/how-to/family-controls-entitlement
- Apple Developer Forums, Family Controls / Screen Time / entitlements threads
  (evidence of multi-week approval waits) —
  https://developer.apple.com/forums/tags/family-controls

Where a page's body is JavaScript-rendered (the Screen Time, Family Controls and
Content Blocker documentation pages returned only titles/descriptions to the fetch
tool), the claim is attributed to that documentation URL and the corroborating
secondary source above, and should be re-verified on a device/Mac before it is
relied on for a release decision.

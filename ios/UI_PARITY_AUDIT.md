# Android UI parity audit

## Baseline

This phase builds on upstream iOS `f25f428`. Its Quran home, fonts, recitation,
notifications, date controls, reader, and tab styling are preserved. Android code
and the supplied screenshots remain the source of truth.

## Screen map and phase status

| Surface | Android reference | iOS status |
| --- | --- | --- |
| Quran home | `quran/ui/QuranTab.kt` | Preserve upstream `QuranView.swift`; change only its discovery destination. |
| Quran discovery | `ui/ContentHubSheets.kt: QuranSearchScreen`, `quran/data/QuranRepository.kt: searchVerses` | `QuranHomeView.swift`: Search / Surah / Bookmarks, cached word/reference search, English/Arabic results, favorite stars, reader links. |
| Bookmarks | `ui/ContentHubSheets.kt` | `BookmarksView.swift`: search and separate Surah/verse sections; existing storage retained. |
| Media home | `media/ui/MediaTab.kt` | `MediaView.swift`: subscription strip, All/Playlists/Haramayn/Directory shortcuts, feed actions, progress-backed Continue Watching, horizontal Shorts, compact Videos rows. |
| Channel addition | `media/ui/MediaTab.kt: AddChannelDialog` | `MediaDiscoverySheets.swift`: platform selection then handle/URL input; actual persisted subscriptions. |
| Filters | `media/ui/FilterSheet.kt`, `media/util/FeedFilters.kt` | Existing Swift rules reused; six collapsible groups, draft state, Reset/Apply, platform normalization, inclusive custom dates. |
| Safina Society | `media/data/MediaRepository.kt: DEFAULT_CHANNEL` | Android's real default channel, seeded only on first initialization. Existing empty subscriptions are not reseeded. |
| Playlists | `media/ui/MediaTab.kt: PlaylistsSheet` | Existing local create/add/remove flows retained. URL imports and detailed edit/search/filter parity pending. |
| Video/audio player | `media/ui/VideoPlayerScreen.kt`, `AudioPlayerScreen.kt` | Embedded YouTube iframe; Android-order actions, timeline, transport, genuine progress capture, and local playlist picker. Audio-only/background playback, extraction/downloads, and device import are explicitly unavailable. |
| Haramayn | `media/ui/LiveTab.kt`, `media/data/LiveStreamConfig.kt` | Makkah/Madinah destinations and official live-channel entry points added. Embedded live resolver pending. |
| Directory | `directory/ui/ChannelDirectoryScreen.kt`, `media/ui/ChannelDirectorySheet.kt` | Existing real API directory retained; further category/subcategory layout refinement pending. |
| Good Post | `goodpost/ui/GoodPostHome.kt`, `GoodPostExplore.kt`, `GoodPostDiscover.kt` | Compact followed/owned channel rows, search/overflow toolbar, Explore pill, actual advertisement carousel, sectioned discovery, separate Follow controls, and server-backed category search/sorting/paging implemented. Visual verification deferred to the user. |
| Good Post channel | `goodpost/ui/GoodPostFeed.kt`, `GoodPostChannelInfo.kt`, `GoodPostStarredScreen.kt`, `GoodPostMediaGallery.kt`, `GoodPostAdmin.kt: ChannelFormScreen` | Channel feed with an **editable draft strip** that opens the full posting page with the draft intact, an information page (avatar, `Public channel · N followers`, Follow/Share link/Search, description + Read more, `Created on dd/MM/yy`, media strip, notification switch, starred row), a **channel edit form with picture change/remove** (the `adminUpdateChannel` route had no caller before this), the starred-messages list with per-row thumbnails and local highlighting search, and the channel media gallery with on-device video poster frames. Post-level selection/bulk actions, the crop step on a picked picture, and the inline video player remain pending. |
| More / productivity | `ui/ContentHub.kt`, `todo/ui/TodoScreen.kt`, `quran/ui/DhikrCounterScreen.kt` | Existing tools retained. More layout and Todo statistics/calendar/editor parity pending. |
| Administrator | `goodpost/ui/GoodPostAds.kt`, `GoodPostBrainRot.kt`, `GoodPostDirectory.kt` | **Advertisement management implemented**: role-gated list (reachable from the Good Post overflow when signed in), text/image card editor with the fixed background/text palettes, placement toggles, priority, enable switch, picture upload, and delete — against `adminAds` / `adminCreateAd` / `adminUpdateAd` / `adminDeleteAd`. **Brain Rot (dashboard, review queue, rules, false reports) and directory administration remain pending.** The public curated directory is implemented (`GoodPostDirectoryView`): category chips, subcategories, `Saved copy` indicator, refresh, platform-labelled rows. |

## Integration boundaries

- No production sample channels, videos, playlists, ads, or directory records.
  Deterministic screenshot fixtures are gated by `--uitesting` and
  `CLEARVIEW_MEDIA_FIXTURE`; they neither authenticate nor write to the backend.
- YouTube feed content comes from RSS. Instagram/X feed ingestion is not connected
  on iOS; the channel-add UI explicitly says so and preserves profile browsing.
- Opening a link is not evidence that a video was watched. The feed menu has only
  Hidden Videos, Hidden Channels, Add Video by URL, and Add Video from Device.
  Saved and recently opened records are retained. Continue Watching only renders stored, valid progress and
  excludes Shorts, live streams, hidden videos, and hidden All Feed channels.
  Embedded playback now records real player position/duration, throttled to five seconds with pause/exit flushes.
- Existing Media JSON migrates through optional fields without deleting saved
  videos, playlists, or subscriptions. Unknown durations/timestamps are omitted.
- Device import reports the missing integration instead of fabricating success.
  Android accessibility blocking remains excluded.

## Validation

Local checks: Swift syntax, plist/project validation, diff whitespace, shared JVM
tests. Xcode and device access are unavailable locally. The iOS workflow runs the
full iPhone simulator suite and targeted discovery checks on a compact available
iPhone, exporting screenshots for visual review. Compilation alone is not visual
validation.

Tests cover Quran word/reference/Arabic search, library migration, progress-based
filters, hiding, and UI navigation. Good Post adds `GoodPostBookmarkTests`, which
pins the star→bookmark conversion (channel id and **name**, the words, the time,
and Android's `kind` precedence: a clip beats a picture, and a post carrying a
link is `link` even when it also has words — the label is only drawn when the post
has none). Screenshots cover Quran Search/Surah/Bookmarks
and Media Feed/Videos/Filters/channel addition. Targeted player checks add command
delivery, player state, progress/playlist persistence, control placement, and the
four-item menu. Real-network playback verification can be skipped by CI when
YouTube is unavailable; a skipped smoke test is not a playback success.

This is the Quran/Media discovery slice, not a claim of complete parity across all
nine requested phases. Playback/playlists precede Good Post, tools, and admin work.

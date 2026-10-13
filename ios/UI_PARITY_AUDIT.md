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
| Video/audio player | `media/ui/VideoPlayerScreen.kt`, `AudioPlayerScreen.kt` | Playback still opens the platform page. Embedded controls, progress capture, device import, and downloads pending. |
| Haramayn | `media/ui/LiveTab.kt`, `media/data/LiveStreamConfig.kt` | Makkah/Madinah destinations and official live-channel entry points added. Embedded live resolver pending. |
| Directory | `directory/ui/ChannelDirectoryScreen.kt`, `media/ui/ChannelDirectorySheet.kt` | Existing real API directory retained; further category/subcategory layout refinement pending. |
| Good Post | `goodpost/ui/GoodPostHome.kt`, `GoodPostExplore.kt`, `GoodPostDiscover.kt` | Following-channel rows, role menus, advertisement carousel, and category discovery are the next UI phase. |
| More / productivity | `ui/ContentHub.kt`, `todo/ui/TodoScreen.kt`, `quran/ui/DhikrCounterScreen.kt` | Existing tools retained. More layout and Todo statistics/calendar/editor parity pending. |
| Administrator | `goodpost/ui/GoodPostAds.kt`, `GoodPostBrainRot.kt`, `GoodPostDirectory.kt` | Existing repository endpoints are available; dedicated role-gated management UI pending. |

## Integration boundaries

- No production sample channels, videos, playlists, ads, or directory records.
  Deterministic screenshot fixtures are gated by `--uitesting` and
  `CLEARVIEW_MEDIA_FIXTURE`; they neither authenticate nor write to the backend.
- YouTube feed content comes from RSS. Instagram/X feed ingestion is not connected
  on iOS; the channel-add UI explicitly says so and preserves profile browsing.
- Opening Safari is not evidence that a video was watched. Recently opened remains
  in the feed menu. Continue Watching only renders stored, valid progress and
  excludes Shorts, live streams, hidden videos, and hidden All Feed channels.
  Genuine progress capture awaits the embedded-player phase.
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
filters, hiding, and UI navigation. Screenshots cover Quran Search/Surah/Bookmarks
and Media Feed/Videos/Filters/channel addition.

This is the Quran/Media discovery slice, not a claim of complete parity across all
nine requested phases. Playback/playlists precede Good Post, tools, and admin work.

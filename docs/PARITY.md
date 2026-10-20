# Parity with Mihon

libtachi aims to behave as Mihon (mihonapp/mihon 487c313) does in everything
that isn't presentation. This is where it stands, area by area, and where it
differs on purpose.

## Library and chapters

| Mihon | libtachi |
|---|---|
| Chapter sync (`SyncChaptersWithSource`): dedup by URL, sanitized names, recognition, carry-over by number, synthesized upload dates, new-release detection | Same (`library.syncSource`) |
| Chapter number recognition | Same algorithm, Mihon's tests ported (`recognition.zig`) |
| Smart update scheduling (FetchInterval, ReleaseSchedule, ReleasePattern) | Same, Mihon's tests ported (`fetch_interval.zig`) |
| Library update restrictions, categories, skipped counts, metadata only when asked | Same |
| Library filters, per-category sorts, grouping, random sort | Same; the random sort uses its own generator, so its order differs from Kotlin's `Random(seed)` |
| Library search syntax | Same (`query.zig`); case folding is ASCII only |
| Chapter list flags, sorts, mark previous read | Same |
| Reader chapter list (skip read, filtered, duplicates) | Same |
| Reading progress, read on the last page, history time | Same, through `pageShown`; a progress write per call rather than a 2-second debounce |
| Incognito, globally and per extension | Same |
| Delete after reading, duplicate marking, download ahead | Same; download-ahead checks once per chapter once the next one is downloaded |
| Mark read/unread, bookmarks, history removal and clearing | Same |
| Updates feed, history feed, upcoming, stats, unseen-updates badge | Same |
| Categories: create, rename, delete, reorder, assign, sort | Same; the default category's sort is the global sort |
| Duplicate detection | Same, LIKE wildcards included |
| Migration with its flags | Same; enhanced trackers' URL rewrite pending trackers |
| Removing from the library keeps the title for its history; "clear database" | Same |
| Downloaded chapters a source drops | **Deviation:** kept, marked `orphaned`, instead of deleted with the chapter row |
| Notes, excluded scanlators, reader flags, custom intervals | Same |

## Downloads and reading

| Mihon | libtachi |
|---|---|
| Download queue: oldest first, persisted, failed entries stay, per-source parallelism, 200 MiB check | Same |
| Page retries 2/4/8 s | Same |
| Downloader reuses the reader's cache | Same |
| Online reading through a 100 MiB chapter cache, Mihon's page order | Same; eviction is per chapter, least recently written; cleared at launch with `auto_clear_chapter_cache` (`Engine.launched`) |
| Download deletion protections (bookmarks, excluded categories) | Same, explicit deletes included |
| Download storage | **Deviation:** libtachi keeps its own layout (`downloads/`), and imports and exports Mihon's (`import_downloads`, `export_downloads`) with Mihon's names, legacy names, CBZ and ComicInfo.xml |
| Image formats | Saves every format Mihon decodes (PNG, JPEG, GIF, WebP, JPEG XL, AVIF, HEIF); whether the app can show them is the app's concern |
| Wi-Fi-only downloads | Same, with the network the app reports (`Engine.setNetwork`); off Wi-Fi the queue waits with its entries kept |

## Local source

| Mihon | libtachi |
|---|---|
| Folders, ZIP/CBZ, TAR/CBT, EPUB chapters; details.json, ComicInfo.xml, covers | Same |
| RAR/CBR, 7z/CB7 | **Not supported:** no decoder without a new dependency |

## Sources and extensions

| Mihon | libtachi |
|---|---|
| Source list: languages, hidden, pinned, last used, local source | Same (`views.sourceList`) |
| Global search: pinned or all, one page per source, Mihon's result order | Same; sources are searched one at a time because extension calls are serialized |
| Extension stores: multiple stores, every index format, refresh rules | Same (`stores.zig`, `repo.zig`) |
| Listings merged by package and key, language and content-warning filters, obsolete installs | Same |
| Trust: store keys, version-scoped manual trust, untrusted listing | Same; checked when a file is installed and listed by `untrustedExtensions` |
| Extension updates across stores | Same |
| Source preferences | Through the extension's own preference screen (`preferences`, `set_preference`) |
| Covers: URL-keyed cache, custom covers | Same; fetched through the source's client |

## Backups

| Mihon | libtachi |
|---|---|
| Manga, chapters, categories, tracking, history, sources, read entries | Same, byte-identical to kotlinx.serialization's encoding |
| App settings | Same keys and types; mapped onto libtachi's settings, category ids matched by name on restore; Mihon settings libtachi has no use for are kept for the next backup; app state never, private values on request |
| Source settings | Same; read from and written to the runtime's preference files |
| Extension stores | Same, upserted by index URL on restore |

## Tracking

| Mihon | libtachi |
|---|---|
| Trackers' statuses, score scales and conversions, setters, automatic completion | Same (`tracking.zig`) |
| AddTracks, TrackChapter, refresh, deferred retries, mark-read always/ask/never | Same |
| Services: MyAnimeList, AniList, Kitsu, Shikimori, Bangumi, MangaUpdates, Hikka, MangaBaka, Comick | Same requests and mappings, one file each under `src/track/`; the app keeps an OAuth login's verifier and state between opening the login page and finishing. AniList's 25-a-minute limit isn't ported |
| Enhanced trackers (Komga, Kavita, Suwayomi): bound when a title joins the library, progress sync, migration | Same rules. **Deviation:** they authenticate from the extension's own settings (API key or basic auth for Komga, Kavita's JWT, Suwayomi's login modes) instead of sharing Android's cookie jar, and accept sources by extension package rather than class; see [enhanced-tracking.md](enhanced-tracking.md) |

## Boundaries

- **Cloudflare challenges and WebView sources** need a browser; Mihon solves
  them in a WebView. An app that has one can plug a solver into the host.
- **DNS over HTTPS** isn't implemented; the system resolver is used.
- **Extension calls are serialized** in one runtime, where Mihon runs
  several sources at once. Native page downloads still run in parallel.
- **Scheduling** (periodic updates, notifications) is the app's:
  `libraryUpdateDue` says when Mihon would update.

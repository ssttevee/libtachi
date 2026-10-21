# The engine

`tachi.Engine` is a Tachiyomi/Mihon engine an app only has to put a UI on:
the library, its chapters and reading state, downloads, the local source,
library updates, backups and every list a Mihon-style app shows. It follows
Mihon's behavior (mihonapp/mihon 487c313) unless [PARITY.md](PARITY.md) says
otherwise.

Extensions run behind a `Backend`: in the app's own process
(`backend.InProcess`, wrapping a `Runtime`), or in a helper process
(`worker.Client`), which lets the app keep the JVM out of its address space
and let it exit when idle. The engine itself never needs the JVM: everything
except extension calls runs in the app's process, and only that process
writes the library.

```zig
var worker: tachi.worker.Client = undefined;
try worker.init(gpa, io, .{ .exe = "bin/my-worker", .args = &.{"--serve"} });
var engine: tachi.Engine = .init(gpa, io, worker.backend(), .{ .dir = data_dir });

const job = try tachi.Job.start(&engine, .{ .update_library = .{} });
defer job.deinit();
job.join(); // or poll job.done, job.phase, job.pages_done / pages_total
if (job.failure) |why| show(why) else show(job.result.message);
```

The worker side is one call: `tachi.worker.serve(gpa, &in_process, .{})` in
the helper executable.

## Jobs

Anything that may touch the network or take long is a `Request`, run as a
`Job` the app can watch and cancel:

| Request | Does |
|---|---|
| `sources`, `extensions`, `install`, `install_file`, `uninstall`, `update_extensions` | extension management |
| `browse`, `filters`, `related`, `preferences`, `set_preference` | source calls |
| `global_search` | Mihon's global search; partial results through `Job.searchResults` |
| `add`, `refresh`, `update_library` | fetch titles into the library with Mihon's sync and update rules |
| `download`, `read` | download a chapter; load one for reading through the chapter cache (`Job.pageStates`) |
| `cover` | fetch a thumbnail into the cover cache |
| `delete_download`, `remove`, `scan_local` | library edits that are jobs for history's sake |
| `migrate` | move a title to another source |
| `import_backup`, `export_backup` | Mihon `.tachibk` backups |
| `import_downloads`, `export_downloads` | Mihon's downloads folder layout |
| `add_store`, `refresh_stores` | extension stores; with stores, `extensions` merges them all |
| `tracker`, `track_bind`, `track_unbind`, `track_set`, `track_refresh`, `track_chapter`, `track_pending` | tracking: log in, search, bind, edit, refresh, progress and deferred retries |

`Job.phase` says whether the JVM is starting or an extension is loading
before the operation itself; `pages_done` / `pages_total` give progress.
`Engine.pause` cancels extension work and refuses new jobs, for an app going
to the background; `resume` undoes it.

## Concurrency

`Engine.Options.parallelism` bounds each independent I/O loop (default 4):
global source search, chapter pages, library title fetches, store refreshes and
store listings. Zero is treated as one. Chapter pages also honor the saved
`Settings.downloads.parallel_pages` limit (default 5), taking the lower of the
two limits. Direct users of `downloads.downloadChapter` set
`downloads.Options.parallelism` (default 4).

The download queue uses the same runner with its existing
`Settings.downloads.parallel_sources` limit (default 5), keeping one chapter
per source active. Each chapter has its own page limit. These are per-loop
limits, so several jobs or queued sources can collectively exceed one loop's
limit.

All these loops use `src/parallel.zig`: bounded `Io.concurrent` futures,
completion notifications through `Io.Queue`, private scratch arenas, and
result publication on the parent task. Fatal errors and cancellation join
outstanding tasks before releasing their memory. Global-search partial
results and page callbacks arrive in completion order; progress counts are
monotonic. Final search ranking, chapter reading order, store precedence,
and library update report/automatic-download order remain stable.
`downloads.Options.order` is a permutation defining dispatch priority;
completion order can differ. Completed page files survive a canceled or
failed chapter for reuse on retry. Source rate reservations and TLS setup
are synchronized across native page transfers.

An in-process backend can execute JVM operations concurrently. A single
`worker.Client` still serializes JVM calls over its connection; native page
transfers overlap independently. Backends and download fallbacks must make
mutable state safe for overlapping calls. The general allocator must support
concurrent allocations, and the supplied `Io` must support concurrency.
Set `parallelism = 1` when serial dispatch is required.

Tracker transactions, extension installation/registry changes and ordered
backup/download import/export retain their sequential execution. Their
iterations share mutable state, collision precedence or an ordered output.
Retry loops and deadline races retain their own control flow.

## Cancellation

`job.cancel()` cancels that job's `std.Io` task and waits for it to finish.
For in-process JVM calls, the runtime translates cancellation to the matching
Kotlin coroutine job and HTTP calls. Other engine jobs keep running. A job
that finishes before cancellation is observed can still succeed; inspect
`job.failure` after cancellation or joining. The operation need not be on the
network to observe cancellation: suspending source procedures inherit the
same coroutine job.

The runtime retains arguments, JNI references and result buffers until foreign
execution has unwound. In-process extension code that ignores coroutine
cancellation and does not unblock on HTTP cancellation can therefore delay
`cancel()` indefinitely. Use `worker.Client` when uncooperative extension
code must be stopped: it terminates the active worker on cancellation, and
starts another for the next call. Canceling a queued worker request does not
terminate a different request already running.

`Engine.pause()` and `Backend.cancel()` remain broad administrative controls.
`Runtime.cancelRequests(source_id)` explicitly cancels a source client's HTTP
requests; it is not the per-operation cancellation API. Custom backends should
observe their caller's `std.Io` cancellation and propagate `error.Canceled`.

The same cancellation contract is available without the engine. Run a runtime
call in an `Io.concurrent` task using the `Io` supplied to `Runtime.init`, then
cancel that future. `Runtime.supportsCancellation()` is false for older host
jars; these retain synchronous JNI behavior. All outstanding calls must be
joined before destroying a runtime.

## Views

Pure functions over the stored library (`views.zig`), wrapped by the engine
so they pick up the settings:

- `libraryView(arena, search)`: titles grouped by category, filtered and
  sorted per category, searched with Mihon's query syntax (`query.zig`).
- `chapterList(arena, manga_id)`: a title's chapters by its chapter flags.
- `readerChapters(arena, chapter_id)`: the chapters the reader moves
  through, skipping read, filtered or duplicate chapters as set.
- `updatesFeed`, `history`, `upcoming`, `stats`, `duplicates`,
  `sourceList`, `unseenUpdates`.
- `coverPath(arena, manga)`: the custom cover, local cover or cached
  thumbnail to show.
- `pagePath(gpa, relative)`: the file to open for a page, extracting it
  first if it lives in an archive.

## Actions

Quick local edits are plain methods:

- Reading: `pageShown` (call on every page; it records progress and does
  what Mihon's reader does when a chapter is finished), `leaveReader`.
- Chapters: `markRead`, `markTitleRead`, `markPreviousRead`, `setBookmark`,
  `deleteDownloads`, `removeHistory`.
- Titles: `setFavorite`, `setNotes`, `setExcludedScanlators`,
  `setChapterFlags`, `setReaderFlags`, `setFetchInterval`,
  `setDefaultChapterFlags`, `setCustomCover`, `removeCustomCover`,
  `clearDatabase`.
- Categories: `createCategory`, `renameCategory`, `deleteCategory`,
  `moveCategory`, `setCategories`, `setLibrarySort`.
- Sources: `setSourceHidden`, `setSourcePinned`, `setLanguage`,
  `setLastSource`.
- Extensions: `extensionStores`, `removeStore`, `trustExtension`,
  `untrustedExtensions`.
- Tracking: `loadTrackers`, `trackerLogout`, `saveTrackerFormats`,
  `markReadTracked`, `applyTracking`; reader completion tracks on its own.
- Housekeeping: `launched` (once at start), `setNetwork` (the device's
  network, for Wi-Fi-only downloads), `markUpdatesSeen`,
  `libraryUpdateDue`, `chapterCacheBytes`, `clearChapterCache`, the
  download queue (`engine.queue`: `enqueue`, `start`, `pause`, `remove`,
  `moveToFront`, `clear`, `snapshot`, `waitingForWifi`), and at exit
  `finishTracking`, `queue.deinit` and `deinit`.

## Settings

`Settings` (`settings.zig`, `settings.json`) holds every preference that
changes engine behavior, with Mihon's defaults and its preference keys in
the doc comments: library update rules and schedule, downloads and deletion,
reader skipping and incognito, source languages and pins, library filters
and sorts, updates-feed filters, migration flags. Display-only preferences
are the app's. Read with `loadSettings`, change, write with `saveSettings`.

## Files

Everything lives in the directory given as `Options.dir`:

| Path | What |
|---|---|
| `library.json` | titles, chapters, categories, known sources |
| `reading.json` | per-chapter reading state, rewritten on page turns |
| `settings.json` | `Settings` |
| `stores.json` | extension stores and hand-trusted extensions |
| `trackers.json` | tracker credentials, score formats, deferred updates |
| `prefs/` | extensions' settings (the runtime's, with `Options.host_dir`) |
| `downloads/` | downloaded pages; `queue.json` and `pending_delete.json` |
| `local/` | the local source: one folder per series |
| `covers/` | cached thumbnails and `custom/` covers |
| `cache/` | chapter cache for online reading, archive page extracts |

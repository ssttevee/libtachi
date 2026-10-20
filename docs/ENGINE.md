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

`Job.phase` says whether the JVM is starting or an extension is loading
before the operation itself; `pages_done` / `pages_total` give progress.
`Engine.pause` cancels extension work and refuses new jobs, for an app going
to the background; `resume` undoes it.

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
- Housekeeping: `markUpdatesSeen`, `libraryUpdateDue`, `chapterCacheBytes`,
  `clearChapterCache`, the download queue (`engine.queue`: `enqueue`,
  `start`, `pause`, `remove`, `moveToFront`, `clear`, `snapshot`).

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
| `downloads/` | downloaded pages; `queue.json` and `pending_delete.json` |
| `local/` | the local source: one folder per series |
| `covers/` | cached thumbnails and `custom/` covers |
| `cache/` | chapter cache for online reading, archive page extracts |

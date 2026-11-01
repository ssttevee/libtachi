# PocketBook responsiveness implementation handoff

Scope: upstream `libtachi`, based on `a0a87ec328875d623d58aa85183b2b4c1614ba27`.
The PocketBook app, dependency manifest, vendor sources and package caches were
not edited. No device upload or deployment was performed. Measurements below
are host validation, not device performance claims.

## Changes

- Migrated typed-document reads use shared read transactions; migration takes a
  write reservation only after a miss, then rechecks under that reservation.
- Queue restore copies identities/source IDs and persistent browser blocks.
  Page progress starts unknown and is validated when work is admitted. Restore
  builds privately outside the state lock and publishes once. A concurrent clear
  cannot be overwritten by the restored list.
- Completion validates resume files and discards disposable plans outside the
  state lock. Queue saves capture owning snapshots under a short state lock,
  serialize their capture/commit order using an Io mutex, then do I/O unlocked.
  They still rewrite queue rows transactionally. Existing FULL sync and rollback
  journaling remain in effect.
- Enqueue, read preparation, queue planning and transfer use chapter previews
  rather than whole-library snapshots. Page count and downloaded-page updates
  patch one chapter and leave independent reading overlays untouched.
- Root scans restrict category/favorite candidates in SQL, avoid unused chapter
  aggregates for history/updates/upcoming candidates, stream ordered rows instead
  of repeatedly scanning OFFSET batches, and compile search once with resettable
  per-title scratch memory. Final requested-page OFFSET remains supported.
- Filtered rank/count APIs share chapterPage predicates and tie ordering. There
  is no new persistent aggregate cache to invalidate; each query reads live rows.
- Interactive root/title/chapter page/rank/count reads install a SQLite progress
  handler and propagate Io cancellation, including during SQLite sorts.
- JVM fallback consumes decoded image bodies with a 16 MiB cap, checks declared
  lengths, and closes bodies on success/failure. Worker IPC rejects oversized
  images before base64 allocation and before decoded-image allocation.

## Backward-compatible APIs

Here `A = std.mem.Allocator`. Types are exported through `tachi.library` and
`tachi.queue`. Methods take the normal mutable pointer receiver.

```zig
// library.Store
pub fn setPageCount(self: *Store, a: A, id: []const u8, count: u32) !bool;
pub fn setPages(self: *Store, a: A, id: []const u8, pages: []const []const u8) !void;
pub fn chapterRank(self: *Store, a: A, manga_id: []const u8,
    flags: u32, downloaded_only: bool, chapter_id: []const u8) !?usize;
pub fn chapterTotal(self: *Store, a: A, manga_id: []const u8,
    flags: u32, downloaded_only: bool) !usize;
pub fn titleCounts(self: *Store, a: A, manga_id: []const u8) !Counts;

// queue.Queue
pub const Activity = struct { running: bool, waiting_for_wifi: bool };
pub fn tryActivity(self: *Queue) ?Activity;
pub fn trySnapshotPage(self: *Queue, arena: A,
    offset: usize, limit: usize) !?SnapshotPage;

// views: compiled query allocation separate from per-match scratch allocation
pub fn searchWithScratch(arena: A, scratch: A, lib: Library,
    text: []const u8, utc_offset_s: i32) !?Matcher;
```

`setPageCount` returns false for unchanged or missing chapters. `setPages` rejects
unsafe paths and missing chapters; clearing pages retains the known count.
`chapterRank` returns a zero-based filtered rank, null for missing/hidden rows or
missing title. `chapterTotal` and `titleCounts` return zero counts for a missing
title. Separate calls are separate snapshots; chapterPage still provides a page
and total in one read transaction.

`trySnapshotPage` never loads disk or waits for the queue lock. Null means busy
or not restored: keep the last UI view and retry later. It retains normal page
clamping and the 1..256 limit, and copies identity/failure strings into the
caller allocator. `tryActivity` returns null only on contention and does no I/O.
The legacy blocking methods remain compatible. App workers must adopt these
new polling methods to get the nonblocking UI behavior. Reset the scratch arena
after each matcher call, not the arena owning the compiled query.

## Validation

- Full upstream `zig build test --summary all`: 250/250 tests passed on the final
  implementation, including the strengthened rank invalidation assertion.
- Full upstream `./host/gradlew -p host check --console=plain`: passed, including
  image stream size/boundary/truncation/closure, operations, host compatibility,
  Mihon golden backup, and zstd stream checks.
- `zig build test-jvm test-core-jvm --summary all`: passed real-JNI cancellation,
  worker termination/restart, operation isolation and independent core tests.
- Upstream ReleaseSmall build with JDK 17: 14/14 steps passed.
- App production-codec test command: 175/175 tests passed.
- App ReleaseSmall ARM build with JDK 17: 25/25 steps passed.
- The app checks used its unchanged a0a87ec dependency pin. Integrated upstream
  validation must be repeated by the parent after updating that pin.

Regressions cover nonblocking lock contention, copied status string ownership,
restore allocation rollback, a blocked persistence writer capturing replacement
membership, transaction rollback preserving the previous queue, restoration
versus clear publication, reading-overlay preservation, filtered rank/count
parity and invalidation, settings reads beside an uncommitted writer, and SQLite
cancellation/rollback/connection reuse.

## Remaining work and review focus

- An earlier full Zig run stalled in `queue pause retains plans across restart
  and explicit removal discards them` (seed `0x12ec8b37`), while subsequent full
  runs passed. It was stopped with TERM after stack capture. The trace showed
  pause awaiting the runner, runner waiting on parallel completions, and page
  workers parked in PipelineFixture. Root cause was not established; do not
  treat the later passing run as proof this intermittent stall is resolved.
- Infrequent remove/clear cache cleanup still runs under the queue state lock.
  New try-poll APIs return busy there. Legacy running/snapshot APIs can still
  wait/spin; no unconditional lock-free compatibility behavior is claimed.
- Queue persistence still copies/replaces the complete membership list. Large
  queue write amplification could be reduced with ordered row-level mutations.
- Root count-dependent library filters/sorts still aggregate chapters for each
  surviving candidate. Random sorting and final deep page OFFSET are unchanged.
  Filtered rank uses a SQLite window sort, not an indexed constant-time lookup.
- JVM fallback is capped, but retains a whole-image byte array and base64 JSON
  IPC. True streaming/binary/file IPC needs a versioned protocol/lifecycle pass.
- Library bulk edits and non-download title refresh paths retain Store.update.
- Crash behavior is covered by transactional rollback and existing migration
  tests, not by power-loss fault injection on a device filesystem.
- Parent owns app pin integration and fresh independent review. No independent
  review was dispatched by this implementation worker, per instruction.

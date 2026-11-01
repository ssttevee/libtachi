//! Mihon's download queue: chapters waiting to download, worked through in
//! order in the background. Ordered entries are kept in SQLite, importing
//! legacy `downloads/queue.json` once, so
//! the queue survives a restart; a chapter that fails stays queued for a
//! retry, as in Mihon, and the next one goes on.
const std = @import("std");
const Io = std.Io;
const library = @import("library.zig");
const models = @import("tachicore").models;
const sqlite = @import("sqlite.zig");
const persistence = @import("persistence.zig");
const engine_mod = @import("engine.zig");
const downloads = @import("downloads.zig");
const parallel = @import("parallel.zig");
const tachi = @import("tachi.zig");
const Engine = engine_mod.Engine;
const Job = engine_mod.Job;

const log = std.log.scoped(.tachi);

pub const Status = enum { queued, downloading, failed };
pub const Stage = enum { queued, listing_pages, pages_ready, downloading };

/// A queue entry as `snapshot` reports it.
pub const Entry = struct {
    chapter_id: []const u8,
    status: Status,
    stage: Stage = .queued,
    pages_done: usize = 0,
    pages_total: usize = 0,
    phase: engine_mod.Phase = .operation,
    /// Why the last attempt failed.
    failure: ?[]const u8 = null,
};

const Item = struct {
    chapter_id: []u8,
    /// The source concurrency limit applies to overlapping chapter transfers.
    source: i64 = 0,
    status: Status = .queued,
    failure: ?[]u8 = null,
    browser_verification_required: bool = false,
    /// The download running now, for its page progress.
    job: ?*Job = null,
    prepared: bool = false,
    planning: bool = false,
    pages_done: usize = 0,
    pages_total: usize = 0,
};

const Blocked = struct { chapter_id: []const u8, failure: []const u8 };
const Saved = struct {
    chapters: []const []const u8 = &.{},
    /// Only non-retryable failures survive restart; old queue files remain valid.
    browser_verification_required: []const Blocked = &.{},
};

pub const Queue = struct {
    lock: std.atomic.Mutex = .unlocked,
    persistence_lock: Io.Mutex = .init,
    /// Serializes ownership of runner futures, including the entire join. Never
    /// acquired with state held, and never needed by a runner or its workers.
    lifecycle_lock: Io.Mutex = .init,
    closed: bool = false,
    /// Stop requests invalidate starts that crossed an unlocked load/save/join.
    generation: u64 = 0,
    items: std.ArrayList(Item) = .empty,
    loaded: bool = false,
    paused: bool = true,
    /// Removal temporarily pauses transfers while joining and persisting. Carry
    /// its prior running intent across overlapping removals; explicit stops
    /// clear it, and only a generation-valid restart may consume it.
    resume_after_remove: bool = false,
    runner: ?Io.Future(void) = null,
    /// The runner ran out of work and returned; it still has to be awaited.
    runner_done: bool = false,
    /// The queue stopped because downloads are Wi-Fi only and the device
    /// isn't on Wi-Fi; `start` it again once it is.
    waiting_for_wifi: bool = false,
    waiters: []Io.Event = &.{},
    planner_done: bool = false,

    fn acquire(self: *Queue) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn notify(self: *Queue, io: Io) void {
        for (self.waiters) |*event| event.set(io);
    }

    pub fn deinit(self: *Queue, engine: *Engine) void {
        self.acquire();
        self.closed = true;
        self.generation +%= 1;
        self.paused = true;
        self.resume_after_remove = false;
        self.notify(engine.io);
        self.lock.unlock();
        self.lifecycle_lock.lockUncancelable(engine.io);
        defer self.lifecycle_lock.unlock(engine.io);
        self.acquire();
        defer self.lock.unlock();
        self.joinLocked(engine, true);
        for (self.items.items) |item| freeItem(engine.gpa, item);
        self.items.deinit(engine.gpa);
        self.items = .empty;
    }

    fn freeItem(gpa: std.mem.Allocator, item: Item) void {
        gpa.free(item.chapter_id);
        if (item.failure) |f| gpa.free(f);
    }

    /// Transfers the ID to the queue only once the list owns the item.
    fn append(self: *Queue, gpa: std.mem.Allocator, id: []const u8, source: i64) !void {
        const owned_id = try gpa.dupe(u8, id);
        errdefer gpa.free(owned_id);
        try self.items.append(gpa, .{ .chapter_id = owned_id, .source = source });
    }

    const migration_key = "download-queue";

    fn openDatabase(engine: *Engine) !sqlite.Db {
        var db = try sqlite.Db.open(engine.gpa, engine.io, engine.options.dir);
        errdefer db.close();
        try db.exec("CREATE TABLE IF NOT EXISTS queue_entries(position INTEGER PRIMARY KEY, chapter_id TEXT NOT NULL UNIQUE, browser_failure TEXT)");
        return db;
    }

    fn saveRows(db: *sqlite.Db, saved: Saved) !void {
        try db.exec("DELETE FROM queue_entries");
        const stmt = try db.prepare("INSERT INTO queue_entries(position,chapter_id,browser_failure) VALUES(?1,?2,?3)");
        defer stmt.close();
        for (saved.chapters, 0..) |id, i| {
            try stmt.bindInt(1, @intCast(i));
            try stmt.bindText(2, id);
            // An empty failure denotes a retryable queue entry. Browser
            // verification failures stay blocked across restarts.
            const failure = for (saved.browser_verification_required) |blocked| {
                if (std.mem.eql(u8, id, blocked.chapter_id)) break blocked.failure;
            } else "";
            try stmt.bindText(3, failure);
            _ = try stmt.step();
            try stmt.reset();
        }
        try persistence.markMigrated(db, migration_key);
    }

    fn loadSaved(engine: *Engine, a: std.mem.Allocator) !Saved {
        var db = try openDatabase(engine);
        defer db.close();
        try db.begin();
        errdefer db.rollback();
        if (!try persistence.migrated(&db, migration_key)) {
            const file = try std.fs.path.join(a, &.{ engine.options.dir, "downloads", "queue.json" });
            const bytes = Io.Dir.cwd().readFileAlloc(engine.io, file, a, .limited(16 << 20)) catch |err| switch (err) {
                error.FileNotFound => null,
                else => return err,
            };
            const saved = if (bytes) |json| try std.json.parseFromSliceLeaky(Saved, a, json, models.parse_options) else Saved{};
            // Parsing and the entire ordered import must succeed before the
            // marker commits. A malformed backup remains retryable.
            try saveRows(&db, saved);
            try db.commit();
            return saved;
        }
        var ids: std.ArrayList([]const u8) = .empty;
        var blocked: std.ArrayList(Blocked) = .empty;
        const stmt = try db.prepare("SELECT chapter_id,browser_failure FROM queue_entries ORDER BY position");
        defer stmt.close();
        while (try stmt.step()) {
            const id = try a.dupe(u8, stmt.columnText(0));
            try ids.append(a, id);
            const failure = stmt.columnText(1);
            if (failure.len != 0) try blocked.append(a, .{ .chapter_id = id, .failure = try a.dupe(u8, failure) });
        }
        try db.commit();
        return .{ .chapters = ids.items, .browser_verification_required = blocked.items };
    }

    /// Loads the saved queue once; the caller holds the lock.
    fn ensureLoaded(self: *Queue, engine: *Engine) !void {
        if (self.closed) return error.QueueClosed;
        if (self.loaded) return;
        self.lock.unlock();
        self.restore(engine) catch |err| {
            self.acquire();
            return err;
        };
        self.acquire();
        if (self.closed) return error.QueueClosed;
    }

    /// Persistence ordering is acquired without state, and restored ownership
    /// is published under state only if teardown has not closed the queue.
    fn restore(self: *Queue, engine: *Engine) !void {
        self.persistence_lock.lockUncancelable(engine.io);
        defer self.persistence_lock.unlock(engine.io);
        self.acquire();
        const already_loaded = self.loaded;
        const closed = self.closed;
        self.lock.unlock();
        if (closed) return error.QueueClosed;
        if (already_loaded) return;
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const saved = try loadSaved(engine, a);
        const sources = try engine.store.chapterSources(a, saved.chapters);
        var restored: Queue = .{};
        defer {
            for (restored.items.items) |item| freeItem(engine.gpa, item);
            restored.items.deinit(engine.gpa);
        }
        for (saved.chapters, sources) |id, source| {
            try restored.append(engine.gpa, id, source);
            for (saved.browser_verification_required) |blocked| if (std.mem.eql(u8, id, blocked.chapter_id)) {
                const item = &restored.items.items[restored.items.items.len - 1];
                item.failure = try engine.gpa.dupe(u8, blocked.failure);
                item.browser_verification_required = true;
                item.status = .failed;
                break;
            };
        }
        self.acquire();
        // clear() may have published an empty queue during this read. Never
        // replace it with restored entries. Other loaders serialize above.
        if (!self.loaded and !self.closed) {
            self.items = restored.items;
            restored.items = .empty;
            self.loaded = true;
        }
        const closed_after_load = self.closed;
        self.lock.unlock();
        if (closed_after_load) return error.QueueClosed;
    }

    /// Caller holds state lock on entry and return. Serialize before capturing
    /// an owning snapshot of the latest state; no older writer can commit last.
    fn persist(self: *Queue, engine: *Engine) !void {
        self.lock.unlock();
        // Uncancelable: queue membership changes must reach their durable save.
        self.persistence_lock.lockUncancelable(engine.io);
        self.acquire();
        // Release persistence ordering before reacquiring state, to avoid a
        // cycle with a later writer waiting for persistence without state.
        var state_held = true;
        defer {
            if (state_held) self.lock.unlock();
            self.persistence_lock.unlock(engine.io);
            self.acquire();
        }
        // Teardown may have freed membership while this writer waited for
        // persistence. Never turn its empty, closed state into a durable clear.
        if (self.closed) return error.QueueClosed;
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const ids = try a.alloc([]const u8, self.items.items.len);
        for (self.items.items, ids) |item, *id| id.* = try a.dupe(u8, item.chapter_id);
        var blocked: std.ArrayList(Blocked) = .empty;
        for (self.items.items) |item| if (item.browser_verification_required) {
            try blocked.append(a, .{ .chapter_id = try a.dupe(u8, item.chapter_id), .failure = try a.dupe(u8, item.failure orelse "BrowserVerificationRequired") });
        };
        state_held = false;
        self.lock.unlock();
        var db = try openDatabase(engine);
        defer db.close();
        try db.begin();
        errdefer db.rollback();
        try saveRows(&db, .{ .chapters = ids, .browser_verification_required = blocked.items });
        try db.commit();
    }

    /// Adds chapters, skipping those already downloaded, local or queued,
    /// oldest first as Mihon does. Starts downloading unless `start` is false.
    pub fn enqueue(self: *Queue, engine: *Engine, chapter_ids: []const []const u8, autostart: bool) !usize {
        self.acquire();
        const generation = self.generation;
        const closed = self.closed;
        self.lock.unlock();
        if (closed) return error.QueueClosed;
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const Found = struct { chapter: library.Chapter, source: i64 };
        var chapters: std.ArrayList(Found) = .empty;
        for (chapter_ids) |id| {
            const m = engine.store.chapterPreview(a, id) catch |err| switch (err) {
                error.UnknownChapter => continue,
                else => return err,
            };
            const source = m.source_id orelse continue;
            const ch = m.chapters[0];
            if (!ch.downloaded()) try chapters.append(a, .{ .chapter = ch, .source = source });
        }
        // Oldest first: the source lists newest first.
        std.mem.sort(Found, chapters.items, {}, struct {
            fn less(_: void, x: Found, y: Found) bool {
                return x.chapter.source_order > y.chapter.source_order;
            }
        }.less);
        self.acquire();
        defer self.lock.unlock();
        try self.ensureLoaded(engine);
        var added: usize = 0;
        for (chapters.items) |found| {
            const queued = for (self.items.items) |item| {
                if (std.mem.eql(u8, item.chapter_id, found.chapter.id)) break true;
            } else false;
            if (queued) continue;
            try self.append(engine.gpa, found.chapter.id, found.source);
            added += 1;
        }
        if (added > 0) try self.persist(engine);
        if (autostart) try self.startLocked(engine, generation);
        return added;
    }

    /// Explicit user retry: clear the block without dropping plans or saved pages.
    /// An active item is left alone so repeated taps cannot duplicate a job.
    pub fn retry(self: *Queue, engine: *Engine, chapter_id: []const u8) !void {
        self.acquire();
        defer self.lock.unlock();
        const generation = self.generation;
        try self.ensureLoaded(engine);
        for (self.items.items) |*item| {
            if (!std.mem.eql(u8, item.chapter_id, chapter_id)) continue;
            if (item.status != .failed) return;
            item.browser_verification_required = false;
            if (item.failure) |f| engine.gpa.free(f);
            item.failure = null;
            item.status = .queued;
            try self.persist(engine);
            try self.startLocked(engine, generation);
            self.notify(engine.io);
            return;
        }
    }

    /// Works through the queue, retrying failures except unsupported browser verification.
    pub fn start(self: *Queue, engine: *Engine) !void {
        self.acquire();
        defer self.lock.unlock();
        const generation = self.generation;
        try self.ensureLoaded(engine);
        for (self.items.items) |*item| if (item.status == .failed and !item.browser_verification_required) {
            item.status = .queued;
        };
        try self.startLocked(engine, generation);
    }

    /// State is held on entry/return; only lifecycle owners touch the future.
    fn startLocked(self: *Queue, engine: *Engine, generation: u64) !void {
        self.lock.unlock();
        self.lifecycle_lock.lockUncancelable(engine.io);
        self.acquire();
        defer self.lifecycle_lock.unlock(engine.io);
        if (self.closed) return error.QueueClosed;
        if (generation != self.generation) return;
        if (self.runner != null) {
            if (!self.runner_done) return;
            self.joinLocked(engine, false);
        }
        if (self.closed) return error.QueueClosed;
        if (generation != self.generation) return;
        self.paused = false;
        self.resume_after_remove = false;
        if (self.items.items.len == 0) return;
        self.runner_done = false;
        self.runner = try engine.io.concurrent(run, .{ self, engine });
    }

    /// Caller owns lifecycle and state. Keep the handle published until join
    /// finishes; workers and backend cleanup may need state while joining.
    fn joinLocked(self: *Queue, engine: *Engine, cancel: bool) void {
        if (self.runner) |*runner| {
            self.lock.unlock();
            if (cancel) runner.cancel(engine.io) else runner.await(engine.io);
            self.acquire();
            self.runner = null;
            self.runner_done = false;
        }
    }

    /// Stops after cancelling the download in progress; its saved pages stay.
    pub fn pause(self: *Queue, engine: *Engine) void {
        self.acquire();
        self.generation +%= 1;
        self.paused = true;
        self.resume_after_remove = false;
        self.notify(engine.io);
        self.lock.unlock();
        self.lifecycle_lock.lockUncancelable(engine.io);
        defer self.lifecycle_lock.unlock(engine.io);
        self.acquire();
        defer self.lock.unlock();
        self.paused = true;
        self.joinLocked(engine, true);
        // Also invalidate starts requested while cancellation was joining.
        self.generation +%= 1;
    }

    /// Removes a chapter from the queue, cancelling it if it is downloading.
    pub fn remove(self: *Queue, engine: *Engine, chapter_id: []const u8) !void {
        self.acquire();
        const request_generation = self.generation;
        self.ensureLoaded(engine) catch |err| {
            self.lock.unlock();
            return err;
        };
        const queued = for (self.items.items) |item| {
            if (std.mem.eql(u8, item.chapter_id, chapter_id)) break true;
        } else false;
        if (!queued) {
            self.lock.unlock();
            return;
        }
        // Joining the runner closes the promotion race: a queued entry may
        // begin planning/transferring immediately after we drop this lock.
        const was_running = self.runner != null and !self.runner_done and !self.paused;
        self.lock.unlock();
        self.lifecycle_lock.lockUncancelable(engine.io);
        self.acquire();
        if (self.closed) {
            self.lock.unlock();
            self.lifecycle_lock.unlock(engine.io);
            return error.QueueClosed;
        }
        // A preceding removal may be waiting for persistence with no runner
        // and paused=true. Its stale restart must transfer running intent to
        // this removal, while an intervening explicit stop invalidates it.
        const running_now = self.runner != null and !self.runner_done and !self.paused;
        const should_resume = self.resume_after_remove or running_now or
            (was_running and request_generation == self.generation);
        self.resume_after_remove = should_resume;
        self.generation +%= 1;
        const generation = self.generation;
        self.paused = true;
        self.notify(engine.io);
        self.joinLocked(engine, true);
        // Release lifecycle before persistence: pause must be able to join
        // without waiting for an unrelated durable membership update.
        var lifecycle_held = true;
        defer if (lifecycle_held) self.lifecycle_lock.unlock(engine.io);
        defer self.lock.unlock();
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        try engine.discardQueuedPlan(arena.allocator(), chapter_id);
        for (self.items.items, 0..) |item, i| if (std.mem.eql(u8, item.chapter_id, chapter_id)) {
            freeItem(engine.gpa, self.items.orderedRemove(i));
            break;
        };
        self.lifecycle_lock.unlock(engine.io);
        lifecycle_held = false;
        try self.persist(engine);
        if (should_resume) try self.startLocked(engine, generation);
    }

    /// Moves a queued chapter to the front.
    pub fn moveToFront(self: *Queue, engine: *Engine, chapter_id: []const u8) !void {
        self.acquire();
        defer self.lock.unlock();
        try self.ensureLoaded(engine);
        for (self.items.items, 0..) |item, i| if (std.mem.eql(u8, item.chapter_id, chapter_id)) {
            const moved = self.items.orderedRemove(i);
            try self.items.insert(engine.gpa, 0, moved);
            break;
        };
        try self.persist(engine);
    }

    pub fn clear(self: *Queue, engine: *Engine) !void {
        self.acquire();
        self.generation +%= 1;
        self.paused = true;
        self.resume_after_remove = false;
        self.notify(engine.io);
        self.lock.unlock();
        self.lifecycle_lock.lockUncancelable(engine.io);
        var lifecycle_held = true;
        defer if (lifecycle_held) self.lifecycle_lock.unlock(engine.io);
        self.acquire();
        defer self.lock.unlock();
        self.paused = true;
        self.joinLocked(engine, true);
        self.generation +%= 1;
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        if (self.closed) return error.QueueClosed;
        // Clear even before the saved queue has been loaded, and clean up
        // orphan plans left by an interrupted queue update.
        for (self.items.items) |*item| item.prepared = false;
        try Io.Dir.cwd().deleteTree(engine.io, try std.fs.path.join(arena.allocator(), &.{ engine.options.dir, "downloads", "queued-plans" }));
        try persistence.removePrefix(arena.allocator(), engine.io, engine.options.dir, "queued-plan/");
        self.loaded = true;
        for (self.items.items) |item| freeItem(engine.gpa, item);
        self.items.clearRetainingCapacity();
        self.lifecycle_lock.unlock(engine.io);
        lifecycle_held = false;
        try self.persist(engine);
    }

    /// The queue in order, with the running download's page progress.
    pub fn snapshot(self: *Queue, engine: *Engine, arena: std.mem.Allocator) ![]Entry {
        self.acquire();
        defer self.lock.unlock();
        try self.ensureLoaded(engine);
        const out = try arena.alloc(Entry, self.items.items.len);
        for (self.items.items, out) |item, *e| {
            e.* = .{ .stage = if (item.planning) .listing_pages else if (item.status == .downloading) .downloading else if (item.prepared) .pages_ready else .queued, .pages_done = item.pages_done, .pages_total = item.pages_total, .phase = .operation, .chapter_id = try arena.dupe(u8, item.chapter_id), .status = item.status, .failure = if (item.failure) |f| try arena.dupe(u8, f) else null };
            if (item.job) |job| {
                e.phase = job.phase.load(.acquire);
                e.pages_done = job.pages_done.load(.acquire);
                e.pages_total = job.pages_total.load(.acquire);
            }
        }
        return out;
    }

    pub const SnapshotPage = struct { entries: []Entry, total: usize, offset: usize };
    pub fn snapshotPage(self: *Queue, engine: *Engine, arena: std.mem.Allocator, offset: usize, limit: usize) !SnapshotPage {
        if (limit == 0 or limit > 256) return error.InvalidPageSize;
        self.acquire();
        defer self.lock.unlock();
        try self.ensureLoaded(engine);
        return self.snapshotPageLocked(arena, offset, limit);
    }

    /// Nonblocking UI poll. Null means busy or not yet restored; keep the last
    /// view and retry later. Does no I/O and copies all strings to the caller.
    pub fn trySnapshotPage(self: *Queue, arena: std.mem.Allocator, offset: usize, limit: usize) !?SnapshotPage {
        if (limit == 0 or limit > 256) return error.InvalidPageSize;
        if (!self.lock.tryLock()) return null;
        defer self.lock.unlock();
        if (!self.loaded) return null;
        return try self.snapshotPageLocked(arena, offset, limit);
    }

    pub const Activity = struct { running: bool, waiting_for_wifi: bool };

    /// Nonblocking status read; null means busy. No disk access, even at startup.
    pub fn tryActivity(self: *Queue) ?Activity {
        if (!self.lock.tryLock()) return null;
        defer self.lock.unlock();
        return .{ .running = self.runner != null and !self.runner_done and !self.paused, .waiting_for_wifi = self.waiting_for_wifi };
    }

    fn snapshotPageLocked(self: *Queue, arena: std.mem.Allocator, offset: usize, limit: usize) !SnapshotPage {
        const total = self.items.items.len;
        const base = if (total == 0) 0 else @min(offset / limit, (total - 1) / limit) * limit;
        const out = try arena.alloc(Entry, @min(limit, total - base));
        for (self.items.items[base..][0..out.len], out) |item, *e| {
            e.* = .{ .stage = if (item.planning) .listing_pages else if (item.status == .downloading) .downloading else if (item.prepared) .pages_ready else .queued, .pages_done = item.pages_done, .pages_total = item.pages_total, .phase = .operation, .chapter_id = try arena.dupe(u8, item.chapter_id), .status = item.status, .failure = if (item.failure) |f| try arena.dupe(u8, f) else null };
            if (item.job) |job| {
                e.phase = job.phase.load(.acquire);
                e.pages_done = job.pages_done.load(.acquire);
                e.pages_total = job.pages_total.load(.acquire);
            }
        }
        return .{ .entries = out, .total = total, .offset = base };
    }

    /// A queued transfer's page states. All strings belong to `arena`, so
    /// completion or removal of the queue entry cannot invalidate the snapshot.
    /// Null means the entry is not currently transferring (it may be planning).
    pub fn chapterPages(self: *Queue, engine: *Engine, arena: std.mem.Allocator, chapter_id: []const u8) !?[]Job.PageState {
        self.acquire();
        defer self.lock.unlock();
        try self.ensureLoaded(engine);
        for (self.items.items) |item| {
            if (!std.mem.eql(u8, item.chapter_id, chapter_id) or item.planning) continue;
            const job = item.job orelse return null;
            const states = try job.pageStates(arena);
            for (states) |*state| state.* = switch (state.*) {
                .ready => |saved_path| .{ .ready = try arena.dupe(u8, saved_path) },
                .failed => |message| .{ .failed = try arena.dupe(u8, message) },
                .loading => .loading,
            };
            return states;
        }
        return null;
    }

    /// Whether the queue stopped to wait for Wi-Fi.
    pub fn waitingForWifi(self: *Queue) bool {
        self.acquire();
        defer self.lock.unlock();
        return self.waiting_for_wifi;
    }

    /// Whether the queue is working through its entries.
    pub fn running(self: *Queue) bool {
        self.acquire();
        defer self.lock.unlock();
        return self.runner != null and !self.runner_done and !self.paused;
    }

    /// Plan chapter lists independently from transfers. Two chapter windows
    /// per source let the successor use slots as the predecessor drains.
    fn run(self: *Queue, engine: *Engine) void {
        var allocations: parallel.Allocations = .{ .child = engine.gpa, .io = engine.io };
        const gpa = allocations.allocator();
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const settings = engine.loadSettings(arena.allocator()) catch |err| blk: {
            if (err == error.Canceled) engine.io.recancel();
            break :blk @import("settings.zig").Settings{};
        };
        const source_limit = @max(1, settings.downloads.parallel_sources);
        const page_limit = engine.pageParallelism(arena.allocator()) catch |err| blk: {
            if (err == error.Canceled) engine.io.recancel();
            break :blk 1;
        };
        var scheduler: downloads.Scheduler = .init(gpa, page_limit);
        defer scheduler.deinit();
        defer if (engine.options.release_jvm) engine.backend.release();
        const Workers = struct {
            queue: *Queue,
            engine: *Engine,
            gpa: std.mem.Allocator,
            scheduler: *downloads.Scheduler,
            source_limit: usize,
            fn work(ctx: *@This(), _: std.mem.Allocator, index: usize) !void {
                if (index == 0) {
                    try ctx.queue.plan(ctx.engine, ctx.gpa);
                } else {
                    try ctx.queue.work(ctx.engine, ctx.gpa, ctx.scheduler, ctx.source_limit, index);
                }
                // Preserve cancellation that arrived as the worker finished
                // its last operation, before publishing Slot.result.
                try ctx.engine.io.checkCancel();
            }
            fn publish(_: *@This(), _: usize, _: void, _: *std.heap.ArenaAllocator) !void {}
        };
        const count = source_limit * 2 + 1;
        const waiters = gpa.alloc(Io.Event, count) catch {
            self.acquire();
            self.runner_done = true;
            self.lock.unlock();
            return;
        };
        defer gpa.free(waiters);
        for (waiters) |*event| event.* = .unset;
        self.acquire();
        self.waiters = waiters;
        self.lock.unlock();
        var workers: Workers = .{ .queue = self, .engine = engine, .gpa = gpa, .scheduler = &scheduler, .source_limit = source_limit };
        while (true) {
            self.acquire();
            self.planner_done = false;
            self.lock.unlock();
            parallel.run(gpa, engine.io, count, count, &workers, Workers.work, Workers.publish) catch |err| {
                if (err != error.Canceled) log.warn("download queue stopped: {s}", .{@errorName(err)});
                break;
            };
            // New entries may have arrived after this batch's planner ended.
            self.acquire();
            const more = !self.paused and !self.waiting_for_wifi and for (self.items.items) |item| {
                if (item.status == .queued and !item.prepared) break true;
            } else false;
            if (!more) {
                // Publish the empty-work decision and completion together;
                // enqueue/start can now safely launch the next runner.
                self.waiters = &.{};
                self.runner_done = true;
                self.lock.unlock();
                return;
            }
            self.lock.unlock();
        }
        self.acquire();
        self.waiters = &.{};
        self.runner_done = true;
        self.lock.unlock();
    }

    fn plan(self: *Queue, engine: *Engine, gpa: std.mem.Allocator) Io.Cancelable!void {
        defer {
            self.acquire();
            self.planner_done = true;
            self.notify(engine.io);
            self.lock.unlock();
        }
        while (true) {
            try engine.io.checkCancel();
            const allowed = networkAllowed(engine);
            self.acquire();
            self.waiting_for_wifi = !allowed;
            const next = for (self.items.items) |*item| {
                if (item.status == .queued and !item.prepared) break item;
            } else null;
            if (!allowed or self.paused or next == null) {
                self.lock.unlock();
                return;
            }
            const id = gpa.dupe(u8, next.?.chapter_id) catch {
                self.lock.unlock();
                return;
            };
            defer gpa.free(id);
            var job: Job = .{ .arena = .init(gpa), .engine = engine, .request = .{ .download = id } };
            defer job.arena.deinit();
            next.?.status = .downloading;
            next.?.planning = true;
            next.?.job = &job;
            self.lock.unlock();
            tachi.setLastError("");
            const outcome: anyerror!void = blk: {
                var attempt: usize = 0;
                while (true) : (attempt += 1) {
                    engine.prepareQueuedChapter(&job, id) catch |err| {
                        // JVM extension errors and verification have no reliable
                        // transient classification. Only retry known transport failures.
                        if (err != error.NetworkError and err != error.Timeout and err != error.ConnectionResetByPeer) break :blk err;
                        if (attempt >= downloads.mihon_retry_ms.len) break :blk err;
                        engine.io.sleep(.fromMilliseconds(downloads.mihon_retry_ms[attempt]), .awake) catch |cancel| break :blk cancel;
                        continue;
                    };
                    break :blk {};
                }
            };
            self.finish(engine, id, &job, outcome, true);
            if (outcome) |_| {} else |err| if (err == error.Canceled) return error.Canceled;
        }
    }

    fn work(self: *Queue, engine: *Engine, gpa: std.mem.Allocator, scheduler: *downloads.Scheduler, source_limit: usize, waiter: usize) Io.Cancelable!void {
        while (true) {
            try engine.io.checkCancel();
            const allowed = networkAllowed(engine);
            self.acquire();
            self.waiters[waiter].reset();
            self.waiting_for_wifi = !allowed;
            var active: usize = 0;
            var distinct: usize = 0;
            for (self.items.items, 0..) |item, i| if (item.status == .downloading and !item.planning) {
                active += 1;
                const seen = for (self.items.items[0..i]) |other| {
                    if (other.status == .downloading and !other.planning and other.source == item.source) break true;
                } else false;
                if (!seen) distinct += 1;
            };
            const next = for (self.items.items) |*item| {
                if (item.status == .failed) continue;
                // Later chapters may overlap a predecessor's tail only once
                // every preceding page has a slot (or is already cached).
                // Rebuild this admission order on every restart as well.
                if (item.status == .downloading) {
                    if (item.planning) break null;
                    const job = item.job orelse break null;
                    const total = job.pages_total.load(.acquire);
                    if (total == 0 or job.pages_dispatched.load(.acquire) < total) break null;
                    continue;
                }
                if (!item.prepared) break null;
                var same: usize = 0;
                for (self.items.items) |other| {
                    if (other.status == .downloading and !other.planning and other.source == item.source) same += 1;
                }
                if (same < 2 and (same > 0 or distinct < source_limit)) break item;
            } else null;
            if (!allowed or self.paused or (next == null and self.planner_done and active == 0)) {
                self.lock.unlock();
                return;
            }
            if (next == null) {
                self.lock.unlock();
                try self.waiters[waiter].wait(engine.io);
                continue;
            }
            const id = gpa.dupe(u8, next.?.chapter_id) catch {
                self.lock.unlock();
                return;
            };
            defer gpa.free(id);
            var job: Job = .{ .arena = .init(gpa), .engine = engine, .request = .{ .download = id } };
            defer job.arena.deinit();
            const Dispatch = struct {
                queue: *Queue,
                io: Io,
                fn notify(ptr: *anyopaque) void {
                    const ctx: *@This() = @ptrCast(@alignCast(ptr));
                    ctx.queue.acquire();
                    defer ctx.queue.lock.unlock();
                    ctx.queue.notify(ctx.io);
                }
            };
            var dispatch: Dispatch = .{ .queue = self, .io = engine.io };
            job.dispatch_notify = .{ .context = &dispatch, .notify = Dispatch.notify };
            next.?.status = .downloading;
            next.?.job = &job;
            self.lock.unlock();
            tachi.setLastError("");
            const outcome: anyerror!void = blk: {
                const enough = enoughSpace(engine, id) catch |err| break :blk err;
                if (!enough) break :blk error.NotEnoughSpace;
                const plan_value = engine.loadQueuedPlan(job.arena.allocator(), id) catch |err| break :blk err;
                const plan_value_ready = plan_value orelse break :blk error.MissingPagePlan;
                break :blk engine.downloadPreparedChapter(&job, id, plan_value_ready, scheduler);
            };
            self.finish(engine, id, &job, outcome, false);
            if (outcome) |_| {} else |err| if (err == error.Canceled) return error.Canceled;
        }
    }

    fn finish(self: *Queue, engine: *Engine, id: []const u8, job: *Job, outcome: anyerror!void, planning: bool) void {
        // The job remains owned by this worker until finish returns. Removing
        // an active item holds lifecycle through join and removal, so validation
        // can run unlocked even when another pause/start/teardown is pending.
        var allocations: parallel.Allocations = .{ .child = engine.gpa, .io = engine.io };
        const gpa = allocations.allocator();
        const saved_progress = engine.downloadProgress(job.arena.allocator(), id) catch |err| blk: {
            // Cancellation is one-shot. Swallowing it here can let the runner
            // await this successful worker and then wait forever on siblings.
            if (err == error.Canceled) engine.io.recancel();
            break :blk null;
        };
        if (!planning) if (outcome) |_| {
            engine.discardQueuedPlan(job.arena.allocator(), id) catch |err| {
                if (err == error.Canceled) engine.io.recancel();
                log.warn("page plan not removed: {s}", .{@errorName(err)});
            };
        } else |_| {};
        self.acquire();
        defer self.lock.unlock();
        defer self.notify(engine.io);
        const i = for (self.items.items, 0..) |item, index| {
            if (std.mem.eql(u8, item.chapter_id, id)) break index;
        } else return;
        const item = &self.items.items[i];
        item.job = null;
        item.planning = false;
        item.pages_done = job.pages_done.load(.acquire);
        item.pages_total = job.pages_total.load(.acquire);
        // Cancellation may happen after atomic page publication but before
        // the progress callback. The filesystem is the resumability authority.
        if (!planning) if (saved_progress) |progress| {
            item.pages_done = progress.done;
            item.pages_total = progress.total;
        };
        if (outcome) |_| {
            if (planning) {
                item.prepared = true;
                item.status = .queued;
                if (saved_progress) |progress| {
                    item.pages_done = progress.done;
                    item.pages_total = progress.total;
                }
            } else {
                freeItem(gpa, self.items.orderedRemove(i));
                self.persist(engine) catch |err| {
                    if (err == error.Canceled) engine.io.recancel();
                    log.warn("download queue not saved: {s}", .{@errorName(err)});
                };
            }
        } else |err| switch (err) {
            error.Canceled => item.status = .queued,
            else => {
                item.status = .failed;
                if (item.failure) |f| gpa.free(f);
                const detail = tachi.lastError();
                item.failure = (if (job.failure) |failure|
                    gpa.dupe(u8, failure)
                else if (detail.len > 0)
                    std.fmt.allocPrint(gpa, "{s}: {s}", .{ @errorName(err), detail })
                else
                    gpa.dupe(u8, @errorName(err))) catch null;
                item.browser_verification_required = err == error.BrowserVerificationRequired;
                log.warn("download {s}: {s}", .{ id, item.failure orelse @errorName(err) });
                self.persist(engine) catch |save_err| {
                    if (save_err == error.Canceled) engine.io.recancel();
                    log.warn("download queue not saved: {s}", .{@errorName(save_err)});
                };
            },
        }
    }

    fn networkAllowed(engine: *Engine) bool {
        var allocations: parallel.Allocations = .{ .child = engine.gpa, .io = engine.io };
        var arena: std.heap.ArenaAllocator = .init(allocations.allocator());
        defer arena.deinit();
        const s = engine.loadSettings(arena.allocator()) catch |err| {
            if (err == error.Canceled) {
                engine.io.recancel();
                return false;
            }
            return true;
        };
        return engine.downloadsAllowed(s);
    }

    /// Mihon refuses to start a chapter with less than 200 MiB free; an
    /// unknown amount doesn't stop it.
    fn enoughSpace(engine: *Engine, chapter_id: []const u8) !bool {
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        const target = try engine.downloadTarget(arena.allocator(), chapter_id);
        var buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const dir = std.fmt.bufPrintSentinel(&buf, "{s}", .{target.dir}, 0) catch return true;
        var free = @import("worker.zig").tachi_free_bytes(dir.ptr);
        // The app directory may not exist on a newly inserted card yet.
        if (free < 0) if (std.fs.path.dirname(target.dir)) |parent| {
            const mounted = std.fmt.bufPrintSentinel(&buf, "{s}", .{parent}, 0) catch return true;
            free = @import("worker.zig").tachi_free_bytes(mounted.ptr);
        };
        return free < 0 or free >= min_free_bytes;
    }

    pub const min_free_bytes = 200 << 20;
};

test "the queue waits for Wi-Fi when downloads are Wi-Fi only" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    var engine: Engine = .init(std.testing.allocator, io, @import("backend.zig").none, .{ .dir = dir });
    defer engine.queue.deinit(&engine);
    try engine.store.save(a, .{ .manga = &.{.{ .id = "1:/m", .title = "M", .source_id = 1, .chapters = &.{.{ .id = "1:/c", .title = "C" }} }} });
    engine.setNetwork(.other);
    _ = try engine.queue.enqueue(&engine, &.{"1:/c"}, true);
    var waited: usize = 0;
    while (engine.queue.running()) : (waited += 1) {
        if (waited > 5000) return error.QueueStuck;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(engine.queue.waitingForWifi());
    const entries = try engine.queue.snapshot(&engine, a);
    try std.testing.expectEqual(Status.queued, entries[0].status);
}

test "queue append releases owned IDs when list growth fails" {
    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var queue: Queue = .{};
            defer {
                for (queue.items.items) |item| Queue.freeItem(gpa, item);
                queue.items.deinit(gpa);
            }
            for (0..20) |i| {
                try queue.append(gpa, "chapter", @intCast(i));
                try std.testing.expectEqual(i + 1, queue.items.items.len);
                try std.testing.expectEqualStrings("chapter", queue.items.items[i].chapter_id);
                try std.testing.expectEqual(@as(i64, @intCast(i)), queue.items.items[i].source);
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "queue restoration rolls back allocation failures and remains retryable" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "downloads");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "downloads/queue.json", .data = "{\"chapters\":[\"first\",\"second\"]}" });
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    const Check = struct {
        fn run(gpa: std.mem.Allocator, root: []const u8) !void {
            var engine: Engine = .init(gpa, std.testing.io, @import("backend.zig").none, .{ .dir = root });
            defer engine.deinit();
            defer engine.queue.deinit(&engine);
            engine.queue.acquire();
            defer engine.queue.lock.unlock();
            engine.queue.ensureLoaded(&engine) catch |err| {
                try std.testing.expect(!engine.queue.loaded);
                try std.testing.expectEqual(0, engine.queue.items.items.len);
                return err;
            };
            try engine.queue.ensureLoaded(&engine);
            try std.testing.expect(engine.queue.loaded);
            try std.testing.expectEqual(2, engine.queue.items.items.len);
            try std.testing.expectEqualStrings("first", engine.queue.items.items[0].chapter_id);
            try std.testing.expectEqualStrings("second", engine.queue.items.items[1].chapter_id);
        }
    };
    try t.checkAllAllocationFailures(t.allocator, Check.run, .{dir});
}

test "queue restoration retries a corrected file after a parse failure" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "downloads");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "downloads/queue.json", .data = "{" });
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    var engine: Engine = .init(t.allocator, t.io, @import("backend.zig").none, .{ .dir = dir });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    engine.queue.acquire();
    defer engine.queue.lock.unlock();
    try t.expectError(error.UnexpectedEndOfInput, engine.queue.ensureLoaded(&engine));
    try t.expect(!engine.queue.loaded);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "downloads/queue.json", .data = "{\"chapters\":[\"recovered\"]}" });
    try engine.queue.ensureLoaded(&engine);
    try t.expect(engine.queue.loaded);
    try t.expectEqual(1, engine.queue.items.items.len);
    try t.expectEqualStrings("recovered", engine.queue.items.items[0].chapter_id);
}

test "queue keeps browser-blocked failures actionable across starts and restoration" {
    const t = std.testing;
    const be = @import("backend.zig");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const Fixture = struct {
        attempts: std.atomic.Value(usize) = .init(0),
        fn run(ptr: *anyopaque, _: std.mem.Allocator, _: be.Call, _: ?be.Status) !be.Reply {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = self.attempts.fetchAdd(1, .acq_rel);
            tachi.setLastError("Cloudflare challenge on images.example; no CloudflareSolver is registered with the tachi host.");
            return error.BrowserVerificationRequired;
        }
        fn yes(_: *anyopaque) bool {
            return true;
        }
        fn none(_: *anyopaque) void {}
        fn wait(queue: *Queue) !void {
            for (0..5000) |_| {
                if (!queue.running()) return;
                try t.io.sleep(.fromMilliseconds(1), .awake);
            }
            return error.QueueStuck;
        }
    };
    var fixture: Fixture = .{};
    const backend: be.Backend = .{ .ptr = &fixture, .vtable = &.{ .run = Fixture.run, .warm = Fixture.yes, .cancel = Fixture.none, .release = Fixture.none, .idle = Fixture.none } };
    {
        var engine: Engine = .init(t.allocator, t.io, backend, .{ .dir = root });
        defer engine.deinit();
        defer engine.queue.deinit(&engine);
        try engine.store.save(a, .{ .manga = &.{.{ .id = "1:/m", .title = "M", .source_id = 1, .chapters = &.{ .{ .id = "1:/c", .title = "C", .remote = .{ .url = "/c", .name = "C" } }, .{ .id = "1:/c2", .title = "C2", .remote = .{ .url = "/c2", .name = "C2" } } } }} });
        engine.setNetwork(.wifi);
        _ = try engine.queue.enqueue(&engine, &.{"1:/c"}, true);
        try Fixture.wait(&engine.queue);
        var entries = try engine.queue.snapshot(&engine, a);
        try t.expectEqual(Status.failed, entries[0].status);
        try t.expect(std.mem.startsWith(u8, entries[0].failure.?, "BrowserVerificationRequired: Cloudflare challenge on images.example"));
        try engine.queue.start(&engine);
        try Fixture.wait(&engine.queue);
        _ = try engine.queue.enqueue(&engine, &.{"1:/c"}, true);
        try Fixture.wait(&engine.queue);
        entries = try engine.queue.snapshot(&engine, a);
        try t.expectEqual(Status.failed, entries[0].status);
        try t.expectEqual(1, fixture.attempts.load(.acquire));
        // New chapters still run, including ones from the blocked chapter's source.
        _ = try engine.queue.enqueue(&engine, &.{"1:/c2"}, true);
        try Fixture.wait(&engine.queue);
        try t.expectEqual(2, fixture.attempts.load(.acquire));
        try t.expectEqual(2, (try engine.queue.snapshot(&engine, a)).len);
    }
    var restored: Engine = .init(t.allocator, t.io, backend, .{ .dir = root });
    defer restored.deinit();
    defer restored.queue.deinit(&restored);
    restored.setNetwork(.wifi);
    try restored.queue.start(&restored);
    try Fixture.wait(&restored.queue);
    const entries = try restored.queue.snapshot(&restored, a);
    try t.expectEqual(Status.failed, entries[0].status);
    try t.expect(std.mem.indexOf(u8, entries[0].failure.?, "images.example") != null);
    try t.expectEqual(2, fixture.attempts.load(.acquire));
}

test "queue snapshots report worker phases before the page list is known" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine: Engine = .init(a, std.testing.io, @import("backend.zig").none, .{ .dir = "." });
    var job: Job = .{ .arena = .init(a), .engine = &engine, .request = .{ .download = "chapter" } };
    engine.queue.loaded = true;
    try engine.queue.append(a, "chapter", 1);
    engine.queue.items.items[0].status = .downloading;
    engine.queue.items.items[0].job = &job;
    for ([_]engine_mod.Phase{ .starting, .extension_loading, .operation }) |phase| {
        job.setPhase(phase);
        const snapshot = try engine.queue.snapshot(&engine, a);
        try std.testing.expectEqual(phase, snapshot[0].phase);
        try std.testing.expectEqual(0, snapshot[0].pages_total);
    }
}

test "queue capacity checks preserve an unavailable SD target error" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: Engine = .init(a, std.testing.io, @import("backend.zig").none, .{ .dir = dir });
    var prefs: @import("settings.zig").Settings = .{};
    prefs.downloads.storage = .sd_card;
    try prefs.save(a, std.testing.io, dir);
    try std.testing.expectError(error.StorageUnavailable, Queue.enoughSpace(&engine, "chapter"));
}

const PipelineFixture = struct {
    first_image: Io.Event = .unset,
    tail_started: Io.Event = .unset,
    release_tail: Io.Event = .unset,
    second_planned: Io.Event = .unset,
    plans: std.atomic.Value(usize) = .init(0),
    active: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),
    second_while_tail: std.atomic.Value(bool) = .init(false),
    park_images: bool = false,
    park_planning: bool = false,
    planning_started: Io.Event = .unset,

    fn run(ptr: *anyopaque, a: std.mem.Allocator, call: @import("backend.zig").Call, _: ?@import("backend.zig").Status) anyerror!@import("backend.zig").Reply {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        switch (call) {
            .image_requests => |request| {
                _ = self.plans.fetchAdd(1, .acq_rel);
                self.planning_started.set(std.testing.io);
                if (self.park_planning) try self.release_tail.wait(std.testing.io);
                const second = std.mem.eql(u8, request.chapter.url, "/c2");
                if (second) {
                    // Listing the next chapter happens during the first one's transfer.
                    try self.first_image.wait(std.testing.io);
                    self.second_planned.set(std.testing.io);
                }
                const plan = try a.alloc(models.ImageRequest, if (second) 2 else 3);
                for (plan, 0..) |*page, i| page.* = .{
                    .page = .{ .index = @intCast(i), .url = request.chapter.url },
                    .url = try std.fmt.allocPrint(a, "jvm://{s}/{d}", .{ request.chapter.url, i }),
                    .method = "GET",
                    .headers = &.{},
                    .fallback = "test",
                };
                return .{ .image_requests = plan };
            },
            .image => |request| {
                const active = self.active.fetchAdd(1, .acq_rel) + 1;
                defer _ = self.active.fetchSub(1, .acq_rel);
                _ = self.peak.fetchMax(active, .acq_rel);
                const second = std.mem.eql(u8, request.page.url, "/c2");
                if (!second) self.first_image.set(std.testing.io);
                if (self.park_images) {
                    try self.release_tail.wait(std.testing.io);
                } else if (second) {
                    try self.tail_started.wait(std.testing.io);
                    if (!self.release_tail.isSet()) self.second_while_tail.store(true, .release);
                    self.release_tail.set(std.testing.io);
                } else if (request.page.index == 2) {
                    self.tail_started.set(std.testing.io);
                    try self.release_tail.wait(std.testing.io);
                }
                return .{ .image = try a.dupe(u8, "\x89PNG\r\n\x1a\ntest") };
            },
            else => return error.UnexpectedCall,
        }
    }
    fn yes(_: *anyopaque) bool {
        return true;
    }
    fn none(_: *anyopaque) void {}
    fn backend(self: *@This()) @import("backend.zig").Backend {
        return .{ .ptr = self, .vtable = &.{ .run = run, .warm = yes, .cancel = none, .release = none, .idle = none } };
    }
    fn setup(engine: *Engine, a: std.mem.Allocator) !void {
        engine.setNetwork(.wifi);
        try engine.store.save(a, .{ .manga = &.{.{ .id = "1:/m", .title = "M", .source_id = 1, .chapters = &.{
            .{ .id = "1:/c1", .title = "C1", .source_order = 1, .remote = .{ .url = "/c1", .name = "C1" } },
            .{ .id = "1:/c2", .title = "C2", .source_order = 0, .remote = .{ .url = "/c2", .name = "C2" } },
        } }} });
    }
    fn wait(queue: *Queue) !void {
        for (0..5000) |_| {
            if (!queue.running()) return;
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.QueueStuck;
    }
};

test "queue plans ahead and shares bounded transfer slots across chapter tails" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: PipelineFixture = .{};
    var engine: Engine = .init(t.allocator, t.io, fixture.backend(), .{ .dir = try tmp.dir.realPathFileAlloc(t.io, ".", a), .parallelism = 2 });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    try PipelineFixture.setup(&engine, a);
    _ = try engine.queue.enqueue(&engine, &.{ "1:/c1", "1:/c2" }, true);
    try PipelineFixture.wait(&engine.queue);
    try t.expect(fixture.second_planned.isSet());
    try t.expect(fixture.second_while_tail.load(.acquire));
    try t.expectEqual(2, fixture.plans.load(.acquire));
    try t.expectEqual(2, fixture.peak.load(.acquire));
    try t.expectEqual(0, fixture.active.load(.acquire));
    try t.expectEqual(0, (try engine.queue.snapshot(&engine, a)).len);
    try t.expect(try engine.loadQueuedPlan(a, "1:/c1") == null);
    try t.expect(try engine.loadQueuedPlan(a, "1:/c2") == null);
    const lib = try engine.store.load(a);
    for (lib.manga[0].chapters) |chapter| try t.expect(chapter.downloaded());
}

test "queue pause retains plans across restart and explicit removal discards them" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var fixture: PipelineFixture = .{ .park_images = true };
    {
        var engine: Engine = .init(t.allocator, t.io, fixture.backend(), .{ .dir = dir, .parallelism = 2 });
        defer engine.deinit();
        defer engine.queue.deinit(&engine);
        try PipelineFixture.setup(&engine, a);
        _ = try engine.queue.enqueue(&engine, &.{ "1:/c1", "1:/c2" }, true);
        try fixture.second_planned.wait(t.io);
        // Wait for the planner's atomic cache publication before cancellation.
        for (0..5000) |_| {
            if (try engine.loadQueuedPlan(a, "1:/c2") != null) break;
            try t.io.sleep(.fromMilliseconds(1), .awake);
        }
        engine.queue.pause(&engine);
        try t.expectEqual(0, fixture.active.load(.acquire));
        try t.expect(try engine.loadQueuedPlan(a, "1:/c1") != null);
        try t.expect(try engine.loadQueuedPlan(a, "1:/c2") != null);
    }
    fixture.park_images = false;
    fixture.release_tail.set(t.io);
    var restored: Engine = .init(t.allocator, t.io, fixture.backend(), .{ .dir = dir, .parallelism = 2 });
    defer restored.deinit();
    defer restored.queue.deinit(&restored);
    restored.setNetwork(.wifi);
    try restored.queue.remove(&restored, "1:/c2");
    try t.expect(try restored.loadQueuedPlan(a, "1:/c2") == null);
    try restored.queue.start(&restored);
    try PipelineFixture.wait(&restored.queue);
    try t.expectEqual(2, fixture.plans.load(.acquire));
    try t.expect(try restored.loadQueuedPlan(a, "1:/c1") == null);
}

test "removing a chapter during page-list preparation joins and deletes its cache" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: PipelineFixture = .{ .park_planning = true };
    var engine: Engine = .init(t.allocator, t.io, fixture.backend(), .{ .dir = try tmp.dir.realPathFileAlloc(t.io, ".", a) });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    try PipelineFixture.setup(&engine, a);
    _ = try engine.queue.enqueue(&engine, &.{"1:/c1"}, true);
    try fixture.planning_started.wait(t.io);
    const before = try engine.queue.snapshot(&engine, a);
    try t.expectEqual(Stage.listing_pages, before[0].stage);
    try engine.queue.remove(&engine, "1:/c1");
    try t.expectEqual(0, (try engine.queue.snapshot(&engine, a)).len);
    try t.expect(try engine.loadQueuedPlan(a, "1:/c1") == null);
    try t.expectEqual(0, fixture.active.load(.acquire));
}

test "queued native HTTP transfers overlap across chapter boundaries" {
    const t = std.testing;
    const be = @import("backend.zig");
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var server = try (try Io.net.IpAddress.parse("127.0.0.1", 0)).listen(t.io, .{});
    defer server.deinit(t.io);
    const Fixture = struct {
        server: *Io.net.Server,
        first_received: Io.Event = .unset,
        overlap: bool = false,
        release_calls: std.atomic.Value(usize) = .init(0),
        fn run(ptr: *anyopaque, scratch: std.mem.Allocator, call: be.Call, _: ?be.Status) !be.Reply {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const request = switch (call) {
                .image_requests => |request| request,
                else => return error.UnexpectedFallback,
            };
            if (std.mem.eql(u8, request.chapter.url, "/c2")) try self.first_received.wait(t.io);
            return .{ .image_requests = try scratch.dupe(models.ImageRequest, &.{.{
                .page = .{ .index = 0, .url = request.chapter.url },
                .url = try std.fmt.allocPrint(scratch, "http://127.0.0.1:{d}{s}", .{ self.server.socket.address.getPort(), request.chapter.url }),
                .method = "GET",
                .headers = &.{},
            }}) };
        }
        fn readHead(stream: Io.net.Stream, expected: []const u8) !void {
            var buffer: [4096]u8 = undefined;
            var reader = stream.reader(t.io, &buffer);
            const first = try reader.interface.takeDelimiterInclusive('\n');
            try t.expect(std.mem.indexOf(u8, first, expected) != null);
            while ((try reader.interface.takeDelimiterInclusive('\n')).len > 2) {}
        }
        fn serve(self: *@This()) !void {
            const first = try self.server.accept(t.io);
            defer first.close(t.io);
            try readHead(first, "/c1");
            self.first_received.set(t.io);
            // Chapter one's final image is held until chapter two sends HTTP.
            const second = try self.server.accept(t.io);
            defer second.close(t.io);
            try readHead(second, "/c2");
            self.overlap = true;
            for ([_]Io.net.Stream{ second, first }) |stream| {
                var writer = stream.writer(t.io, &.{});
                try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\n\x89PNG\r\n\x1a\npage");
                try writer.interface.flush();
            }
        }
        fn yes(_: *anyopaque) bool {
            return true;
        }
        fn none(_: *anyopaque) void {}
        fn release(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = self.release_calls.fetchAdd(1, .acq_rel);
        }
    };
    var fixture: Fixture = .{ .server = &server };
    var serving = try t.io.concurrent(Fixture.serve, .{&fixture});
    defer _ = serving.cancel(t.io) catch {};
    const backend: be.Backend = .{ .ptr = &fixture, .vtable = &.{ .run = Fixture.run, .warm = Fixture.yes, .cancel = Fixture.none, .release = Fixture.release, .idle = Fixture.none } };
    var engine: Engine = .init(t.allocator, t.io, backend, .{ .dir = try tmp.dir.realPathFileAlloc(t.io, ".", a), .parallelism = 2, .release_jvm = true });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    try PipelineFixture.setup(&engine, a);
    _ = try engine.queue.enqueue(&engine, &.{ "1:/c1", "1:/c2" }, true);
    try PipelineFixture.wait(&engine.queue);
    try serving.await(t.io);
    try t.expect(fixture.overlap);
    try t.expectEqual(0, (try engine.queue.snapshot(&engine, a)).len);
    // A native chapter must not retire the worker while the planner is using it.
    try t.expectEqual(1, fixture.release_calls.load(.acquire));
}

test "removing an actively transferring chapter joins page tasks and clears all plans" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: PipelineFixture = .{ .park_images = true };
    var engine: Engine = .init(t.allocator, t.io, fixture.backend(), .{ .dir = try tmp.dir.realPathFileAlloc(t.io, ".", a), .parallelism = 2 });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    try PipelineFixture.setup(&engine, a);
    _ = try engine.queue.enqueue(&engine, &.{"1:/c1"}, true);
    try fixture.first_image.wait(t.io);
    try engine.queue.remove(&engine, "1:/c1");
    try t.expectEqual(0, fixture.active.load(.acquire));
    try t.expectEqual(0, (try engine.queue.snapshot(&engine, a)).len);
    try t.expect(try engine.loadQueuedPlan(a, "1:/c1") == null);
    // Clearing a paused queue removes plans as well, while keeping saved pages.
    _ = try engine.queue.enqueue(&engine, &.{"1:/c1"}, false);
    var job: Job = .{ .arena = .init(t.allocator), .engine = &engine, .request = .{ .download = "1:/c1" } };
    defer job.arena.deinit();
    try engine.prepareQueuedChapter(&job, "1:/c1");
    try engine.queue.clear(&engine);
    try t.expect(try engine.loadQueuedPlan(a, "1:/c1") == null);
    try t.expect(try engine.downloadProgress(a, "1:/c1") != null);
}

test "clearing an unloaded queue discards persisted and orphan page plans" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.createDirPath(t.io, "downloads/queued-plans");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "downloads/queued-plans/orphan.json", .data = "[]" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "downloads/queue.json", .data = "{\"chapters\":[\"chapter\"]}" });
    var engine: Engine = .init(t.allocator, t.io, @import("backend.zig").none, .{ .dir = dir });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    try t.expect(!engine.queue.loaded);
    try engine.queue.clear(&engine);
    try t.expectEqual(0, (try engine.queue.snapshot(&engine, a)).len);
    try t.expectError(error.FileNotFound, tmp.dir.openDir(t.io, "downloads/queued-plans", .{}));
}

test "restarted queue admits all earlier chapter pages before its successor" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var fixture: PipelineFixture = .{ .park_images = true };
    var engine: Engine = .init(t.allocator, t.io, fixture.backend(), .{ .dir = dir, .parallelism = 2 });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    try PipelineFixture.setup(&engine, a);
    _ = try engine.queue.enqueue(&engine, &.{ "1:/c1", "1:/c2" }, true);
    try fixture.second_planned.wait(t.io);
    engine.queue.pause(&engine);
    try t.expectEqual(0, fixture.active.load(.acquire));
    try engine.queue.start(&engine);
    for (0..5000) |_| {
        if (fixture.active.load(.acquire) == 2) break;
        try t.io.sleep(.fromMilliseconds(1), .awake);
    }
    // With both slots held by chapter one, chapter two must stay ready,
    // rather than competing with its predecessor's final pending page.
    const entries = try engine.queue.snapshot(&engine, a);
    try t.expectEqual(Stage.downloading, entries[0].stage);
    try t.expectEqual(Stage.pages_ready, entries[1].stage);
    try t.expectEqual(0, entries[1].pages_done);
    engine.queue.pause(&engine);
}

test "queued reader snapshots expose saved pages before the chapter completes" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: PipelineFixture = .{};
    var engine: Engine = .init(t.allocator, t.io, fixture.backend(), .{ .dir = try tmp.dir.realPathFileAlloc(t.io, ".", a), .parallelism = 1 });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    try PipelineFixture.setup(&engine, a);
    _ = try engine.queue.enqueue(&engine, &.{"1:/c1"}, true);
    try fixture.tail_started.wait(t.io);
    const states = (try engine.queue.chapterPages(&engine, a, "1:/c1")).?;
    try t.expectEqual(3, states.len);
    try t.expect(states[0] == .ready);
    try t.expect(states[1] == .ready);
    try t.expect(states[2] == .loading);
    const saved_path = states[0].ready;
    try t.expect(std.mem.startsWith(u8, saved_path, "downloads/"));
    // Removing the entry joins and frees its job; snapshots own their strings.
    try engine.queue.remove(&engine, "1:/c1");
    const bytes = try Io.Dir.cwd().readFileAlloc(t.io, try engine.pagePath(a, saved_path), a, .limited(128));
    try t.expect(std.mem.startsWith(u8, bytes, "\x89PNG"));
    try t.expectEqual(2, (try engine.downloadProgress(a, "1:/c1")).?.done);
}

test "queue rows preserve priority and blocked failures without reimporting a stale backup" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.createDirPath(t.io, "downloads");
    const original = "{\"chapters\":[\"first\",\"blocked\"],\"browser_verification_required\":[{\"chapter_id\":\"blocked\",\"failure\":\"Verification required\"}]}";
    try tmp.dir.writeFile(t.io, .{ .sub_path = "downloads/queue.json", .data = original });
    var engine = Engine.init(t.allocator, t.io, @import("backend.zig").none, .{ .dir = root });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    const imported = try Queue.loadSaved(&engine, a);
    try t.expectEqualStrings("first", imported.chapters[0]);
    try t.expectEqualStrings("blocked", imported.chapters[1]);
    try t.expectEqualStrings("Verification required", imported.browser_verification_required[0].failure);
    // Reordering is a single transaction, preserving the blocking reason.
    {
        var db = try Queue.openDatabase(&engine);
        defer db.close();
        try db.begin();
        errdefer db.rollback();
        try Queue.saveRows(&db, .{ .chapters = &.{ "blocked", "first" }, .browser_verification_required = imported.browser_verification_required });
        try db.commit();
    }
    const restored = try Queue.loadSaved(&engine, a);
    try t.expectEqualStrings("blocked", restored.chapters[0]);
    try t.expectEqualStrings("first", restored.chapters[1]);
    try t.expectEqualStrings("blocked", restored.browser_verification_required[0].chapter_id);
    try t.expectEqualStrings(original, try tmp.dir.readFileAlloc(t.io, "downloads/queue.json", a, .unlimited));
    // clear() works before ensureLoaded and cannot resurrect the retained JSON.
    try engine.queue.clear(&engine);
    try t.expectEqual(0, (try Queue.loadSaved(&engine, a)).chapters.len);
}

test "clearing the queue removes orphan SQLite page plans and retains unrelated documents" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const Value = struct { count: u32 };
    try persistence.save(a, t.io, root, "queued-plan/orphan", Value{ .count = 4 });
    try persistence.save(a, t.io, root, "settings", Value{ .count = 8 });
    var engine = Engine.init(t.allocator, t.io, @import("backend.zig").none, .{ .dir = root });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    try engine.queue.clear(&engine);
    try t.expectEqual(null, try persistence.load(Value, a, t.io, root, "queued-plan/orphan", "missing.json"));
    try t.expectEqual(8, (try persistence.load(Value, a, t.io, root, "settings", "missing.json")).?.count);
}

test "cold queue restore resolves sources without loading unrelated library metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var engine: Engine = .init(std.testing.allocator, std.testing.io, @import("backend.zig").none, .{ .dir = dir });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    try engine.store.save(a, .{ .manga = &.{
        .{ .id = "m", .title = "Queued title", .source_id = 42, .chapters = &.{.{ .id = "c", .title = "Chapter" }} },
        .{ .id = "unrelated", .title = "Unrelated", .chapters = &.{.{ .id = "other", .title = "Other" }} },
    } });
    try std.testing.expectEqual(1, try engine.queue.enqueue(&engine, &.{"c"}, false));
    engine.queue.deinit(&engine);
    engine.queue = .{};
    var db = try Queue.openDatabase(&engine);
    defer db.close();
    // Valid JSON with an invalid title type makes a full library parse fail.
    try db.exec("UPDATE library_manga SET metadata=json_set(metadata,'$.title',123) WHERE id='unrelated'");
    const page = try engine.queue.snapshotPage(&engine, a, 0, 10);
    try std.testing.expectEqual(1, page.entries.len);
    try std.testing.expectEqualStrings("c", page.entries[0].chapter_id);
    try std.testing.expectEqual(42, engine.queue.items.items[0].source);
    const sources = try engine.store.chapterSources(a, &.{ "c", "other", "missing" });
    try std.testing.expectEqualSlices(i64, &.{ 42, 0, 0 }, sources);
}

test "nonblocking queue polls return busy and own copied identity and failure" {
    const t = std.testing;
    var queue: Queue = .{};
    defer {
        for (queue.items.items) |item| Queue.freeItem(t.allocator, item);
        queue.items.deinit(t.allocator);
    }
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(null, try queue.trySnapshotPage(a, 0, 6));
    queue.loaded = true;
    queue.acquire();
    try t.expectEqual(null, try queue.trySnapshotPage(a, 0, 6));
    try t.expectEqual(null, queue.tryActivity());
    queue.lock.unlock();
    try queue.append(t.allocator, "owned", 1);
    queue.items.items[0].failure = try t.allocator.dupe(u8, "failure");
    const page = (try queue.trySnapshotPage(a, 0, 6)).?;
    Queue.freeItem(t.allocator, queue.items.orderedRemove(0));
    try t.expectEqualStrings("owned", page.entries[0].chapter_id);
    try t.expectEqualStrings("failure", page.entries[0].failure.?);
    try t.expect(!queue.tryActivity().?.running);
}

test "queue persistence waits outside state lock and captures newest owned snapshot" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var engine = Engine.init(t.allocator, t.io, @import("backend.zig").none, .{ .dir = try tmp.dir.realPathFileAlloc(t.io, ".", a) });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    engine.queue.loaded = true;
    try engine.queue.append(t.allocator, "first", 1);
    const Writer = struct {
        engine: *Engine,
        started: Io.Event = .unset,
        fn run(ctx: *@This()) !void {
            ctx.engine.queue.acquire();
            defer ctx.engine.queue.lock.unlock();
            ctx.started.set(ctx.engine.io);
            try ctx.engine.queue.persist(ctx.engine);
        }
    };
    var writer: Writer = .{ .engine = &engine };
    engine.queue.persistence_lock.lockUncancelable(t.io);
    var future = try t.io.concurrent(Writer.run, .{&writer});
    try writer.started.wait(t.io);
    // acquire succeeds once the writer parks on persistence ordering. This
    // would deadlock if it waited with the state lock held.
    engine.queue.acquire();
    Queue.freeItem(t.allocator, engine.queue.items.orderedRemove(0));
    try engine.queue.append(t.allocator, "replacement", 2);
    engine.queue.lock.unlock();
    engine.queue.persistence_lock.unlock(t.io);
    try future.await(t.io);
    const saved = try Queue.loadSaved(&engine, a);
    try t.expectEqual(1, saved.chapters.len);
    try t.expectEqualStrings("replacement", saved.chapters[0]);
    // An aborted replacement transaction leaves the last committed order.
    var db = try Queue.openDatabase(&engine);
    defer db.close();
    try db.begin();
    try Queue.saveRows(&db, .{ .chapters = &.{"aborted"} });
    db.rollback();
    try t.expectEqualStrings("replacement", (try Queue.loadSaved(&engine, a)).chapters[0]);
}

test "queue restore waits without state lock and honors an intervening clear publication" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.createDirPath(t.io, "downloads");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "downloads/queue.json", .data = "{\"chapters\":[\"old\"]}" });
    var engine = Engine.init(t.allocator, t.io, @import("backend.zig").none, .{ .dir = try tmp.dir.realPathFileAlloc(t.io, ".", a) });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    const Loader = struct {
        engine: *Engine,
        started: Io.Event = .unset,
        fn run(ctx: *@This()) !void {
            ctx.engine.queue.acquire();
            defer ctx.engine.queue.lock.unlock();
            ctx.started.set(ctx.engine.io);
            try ctx.engine.queue.ensureLoaded(ctx.engine);
        }
    };
    var loader: Loader = .{ .engine = &engine };
    engine.queue.persistence_lock.lockUncancelable(t.io);
    var future = try t.io.concurrent(Loader.run, .{&loader});
    try loader.started.wait(t.io);
    engine.queue.acquire();
    engine.queue.loaded = true; // clear's state publication
    engine.queue.lock.unlock();
    try t.expect(engine.queue.tryActivity() != null);
    engine.queue.persistence_lock.unlock(t.io);
    try future.await(t.io);
    try t.expectEqual(0, engine.queue.items.items.len);
}

const LifecycleGate = struct {
    engine: *Engine,
    parked: Io.Event = .unset,
    cleaning: Io.Event = .unset,
    release: Io.Event = .unset,
    ended: std.atomic.Value(bool) = .init(false),
    returned: std.atomic.Value(bool) = .init(false),

    fn runner(ctx: *@This()) void {
        ctx.parked.wait(std.testing.io) catch {};
        ctx.cleaning.set(std.testing.io);
        ctx.release.waitUncancelable(std.testing.io);
        // Cancellation/cleanup is allowed to reacquire queue state. Holding
        // state across either cancel or await deadlocks this barrier.
        ctx.engine.queue.acquire();
        ctx.ended.store(true, .release);
        ctx.engine.queue.lock.unlock();
    }
    fn pause(ctx: *@This()) void {
        ctx.engine.queue.pause(ctx.engine);
        ctx.returned.store(true, .release);
    }
    fn start(ctx: *@This()) !void {
        ctx.engine.queue.start(ctx.engine) catch |err| switch (err) {
            error.QueueClosed => {},
            else => return err,
        };
        ctx.returned.store(true, .release);
    }
    fn deinit(ctx: *@This()) void {
        ctx.engine.queue.deinit(ctx.engine);
        ctx.returned.store(true, .release);
    }
    fn waitContended(mutex: *Io.Mutex) !void {
        for (0..5000) |_| {
            if (mutex.state.load(.acquire) == .contended) return;
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.LifecycleNotContended;
    }
};

test "queue concurrent pauses keep the joining runner visible until cleanup ends" {
    const t = std.testing;
    var engine = Engine.init(t.allocator, t.io, @import("backend.zig").none, .{ .dir = "unused" });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    var first: LifecycleGate = .{ .engine = &engine };
    var second: LifecycleGate = .{ .engine = &engine };
    engine.queue.runner = try t.io.concurrent(LifecycleGate.runner, .{&first});
    engine.queue.paused = false;
    var pause_one = try t.io.concurrent(LifecycleGate.pause, .{&first});
    try first.cleaning.wait(t.io);
    var pause_two = try t.io.concurrent(LifecycleGate.pause, .{&second});
    try LifecycleGate.waitContended(&engine.queue.lifecycle_lock);
    engine.queue.acquire();
    const visible = engine.queue.runner != null;
    engine.queue.lock.unlock();
    const early = second.returned.load(.acquire);
    first.release.set(t.io);
    pause_one.await(t.io);
    pause_two.await(t.io);
    try t.expect(visible);
    try t.expect(!early);
    try t.expect(first.ended.load(.acquire));
    try t.expect(engine.queue.runner == null);
    try t.expect(engine.queue.paused);
}

test "queue start waits for a canceling runner without holding state" {
    const t = std.testing;
    var engine = Engine.init(t.allocator, t.io, @import("backend.zig").none, .{ .dir = "unused" });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    engine.queue.loaded = true;
    var old: LifecycleGate = .{ .engine = &engine };
    var starter: LifecycleGate = .{ .engine = &engine };
    engine.queue.runner = try t.io.concurrent(LifecycleGate.runner, .{&old});
    engine.queue.paused = false;
    var pausing = try t.io.concurrent(LifecycleGate.pause, .{&old});
    try old.cleaning.wait(t.io);
    var starting = try t.io.concurrent(LifecycleGate.start, .{&starter});
    try LifecycleGate.waitContended(&engine.queue.lifecycle_lock);
    const early = starter.returned.load(.acquire);
    old.release.set(t.io);
    pausing.await(t.io);
    try starting.await(t.io);
    try t.expect(!early);
    try t.expect(old.ended.load(.acquire));
}

test "queue teardown joins concurrent pauses and rejects a waiting start" {
    const t = std.testing;
    var engine = Engine.init(t.allocator, t.io, @import("backend.zig").none, .{ .dir = "unused" });
    defer engine.deinit();
    engine.queue.loaded = true;
    try engine.queue.append(t.allocator, "owned until join", 1);
    var old: LifecycleGate = .{ .engine = &engine };
    var second: LifecycleGate = .{ .engine = &engine };
    var starter: LifecycleGate = .{ .engine = &engine };
    var teardown: LifecycleGate = .{ .engine = &engine };
    engine.queue.runner = try t.io.concurrent(LifecycleGate.runner, .{&old});
    engine.queue.paused = false;
    var pause_one = try t.io.concurrent(LifecycleGate.pause, .{&old});
    try old.cleaning.wait(t.io);
    var pause_two = try t.io.concurrent(LifecycleGate.pause, .{&second});
    var starting = try t.io.concurrent(LifecycleGate.start, .{&starter});
    var deinitializing = try t.io.concurrent(LifecycleGate.deinit, .{&teardown});
    // Closing publishes before waiting for lifecycle, regardless of which
    // waiter acquires that mutex next.
    while (true) {
        engine.queue.acquire();
        const closed = engine.queue.closed;
        engine.queue.lock.unlock();
        if (closed) break;
        try t.io.sleep(.fromMilliseconds(1), .awake);
    }
    const early = teardown.returned.load(.acquire) or second.returned.load(.acquire);
    old.release.set(t.io);
    pause_one.await(t.io);
    pause_two.await(t.io);
    try starting.await(t.io);
    deinitializing.await(t.io);
    try t.expect(!early);
    try t.expect(old.ended.load(.acquire));
    try t.expect(engine.queue.runner == null);
    try t.expect(engine.queue.paused);
    try t.expectEqual(0, engine.queue.items.items.len);
    try t.expectError(error.QueueClosed, engine.queue.start(&engine));
}

test "queue start joins a completed runner outside state before replacement" {
    const t = std.testing;
    var engine = Engine.init(t.allocator, t.io, @import("backend.zig").none, .{ .dir = "unused" });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    engine.queue.loaded = true;
    var old: LifecycleGate = .{ .engine = &engine };
    var starter: LifecycleGate = .{ .engine = &engine };
    old.parked.set(t.io);
    engine.queue.runner = try t.io.concurrent(LifecycleGate.runner, .{&old});
    try old.cleaning.wait(t.io);
    engine.queue.runner_done = true; // run's decision precedes deferred cleanup
    var starting = try t.io.concurrent(LifecycleGate.start, .{&starter});
    // Wait until start is actually awaiting the old future. Reacquiring
    // state in runner cleanup then proves await did not keep it locked.
    while (engine.queue.lifecycle_lock.state.load(.acquire) == .unlocked)
        try t.io.sleep(.fromMilliseconds(1), .awake);
    const early = starter.returned.load(.acquire);
    old.release.set(t.io);
    try starting.await(t.io);
    try t.expect(!early);
    try t.expect(old.ended.load(.acquire));
}

test "queue finish preserves cancellation during best effort progress inspection" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var engine = Engine.init(t.allocator, t.io, @import("backend.zig").none, .{ .dir = try tmp.dir.realPathFileAlloc(t.io, ".", arena.allocator()) });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    const Worker = struct {
        engine: *Engine,
        started: Io.Event = .unset,
        parked: Io.Event = .unset,
        fn run(ctx: *@This()) !void {
            const e = ctx.engine;
            var job: Job = .{ .arena = .init(t.allocator), .engine = e, .request = .{ .download = "c" } };
            defer job.arena.deinit();
            // Deterministically deliver cancellation to finish's I/O rather
            // than the plan itself, matching the sampled pause deadlock.
            ctx.started.set(t.io);
            try t.expectError(error.Canceled, ctx.parked.wait(t.io));
            t.io.recancel();
            e.queue.finish(e, "c", &job, {}, true);
            try t.expectError(error.Canceled, t.io.checkCancel());
        }
    };
    var ctx: Worker = .{ .engine = &engine };
    var worker = try t.io.concurrent(Worker.run, .{&ctx});
    try ctx.started.wait(t.io);
    try worker.cancel(t.io);
}

test "queue removal waits for another pause to finish owning its job" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var engine = Engine.init(t.allocator, t.io, @import("backend.zig").none, .{ .dir = try tmp.dir.realPathFileAlloc(t.io, ".", arena.allocator()) });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    engine.queue.loaded = true;
    try engine.queue.append(t.allocator, "owned until join", 1);
    var old: LifecycleGate = .{ .engine = &engine };
    engine.queue.runner = try t.io.concurrent(LifecycleGate.runner, .{&old});
    engine.queue.paused = false;
    var pausing = try t.io.concurrent(LifecycleGate.pause, .{&old});
    try old.cleaning.wait(t.io);
    const Remover = struct {
        fn run(e: *Engine) !void {
            try e.queue.remove(e, "owned until join");
        }
    };
    var removing = try t.io.concurrent(Remover.run, .{&engine});
    try LifecycleGate.waitContended(&engine.queue.lifecycle_lock);
    engine.queue.acquire();
    const retained = engine.queue.items.items.len == 1;
    engine.queue.lock.unlock();
    old.release.set(t.io);
    pausing.await(t.io);
    try removing.await(t.io);
    try t.expect(retained);
    try t.expect(old.ended.load(.acquire));
    try t.expectEqual(0, engine.queue.items.items.len);
}

const StaleStartFixture = struct {
    const Operation = enum { enqueue, retry, remove, start };
    fn call(engine: *Engine, operation: Operation) !void {
        switch (operation) {
            .enqueue => _ = try engine.queue.enqueue(engine, &.{"1:/c1"}, true),
            .retry => try engine.queue.retry(engine, "1:/c1"),
            .remove => try engine.queue.remove(engine, "1:/c1"),
            .start => try engine.queue.start(engine),
        }
    }
    fn check(operation: Operation, cold: bool) !void {
        const t = std.testing;
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var engine = Engine.init(t.allocator, t.io, @import("backend.zig").none, .{ .dir = try tmp.dir.realPathFileAlloc(t.io, ".", a) });
        defer engine.deinit();
        defer engine.queue.deinit(&engine);
        try PipelineFixture.setup(&engine, a);
        if (cold) {
            var db = try Queue.openDatabase(&engine);
            defer db.close();
            try db.begin();
            errdefer db.rollback();
            try Queue.saveRows(&db, .{
                .chapters = &.{ "1:/c1", "1:/c2" },
                .browser_verification_required = if (operation == .retry) &.{.{ .chapter_id = "1:/c1", .failure = "blocked" }} else &.{},
            });
            try db.commit();
        } else {
            engine.queue.loaded = true;
            if (operation != .enqueue) {
                try engine.queue.append(t.allocator, "1:/c1", 1);
                try engine.queue.append(t.allocator, "1:/c2", 1);
                if (operation == .retry) engine.queue.items.items[0].status = .failed;
            }
        }
        // Removal normally joins a real active runner before persisting. Keep
        // its lifecycle deterministic and avoid backend or scheduling timing.
        var old: LifecycleGate = .{ .engine = &engine };
        old.release.set(t.io);
        if (operation == .remove) {
            engine.queue.runner = try t.io.concurrent(LifecycleGate.runner, .{&old});
            engine.queue.paused = false;
        }
        engine.queue.persistence_lock.lockUncancelable(t.io);
        var pending = try t.io.concurrent(call, .{ &engine, operation });
        try LifecycleGate.waitContended(&engine.queue.persistence_lock);
        // For cold calls the barrier is ensureLoaded; for warm calls it is
        // persist. Pause must return with persistence still gated in both.
        engine.queue.pause(&engine);
        const stopped = engine.queue.paused and !engine.queue.running();
        engine.queue.persistence_lock.unlock(t.io);
        try pending.await(t.io);
        try t.expect(stopped);
        try t.expect(engine.queue.paused);
        try t.expect(!engine.queue.running());
        try t.expect(engine.queue.runner == null);
        const saved = try Queue.loadSaved(&engine, a);
        if (operation == .remove) {
            try t.expectEqual(1, saved.chapters.len);
            try t.expectEqualStrings("1:/c2", saved.chapters[0]);
        } else if (operation == .enqueue) {
            try t.expectEqual(if (cold) @as(usize, 2) else 1, saved.chapters.len);
        } else if (operation == .retry) {
            try t.expectEqual(0, saved.browser_verification_required.len);
            try t.expectEqual(Status.queued, engine.queue.items.items[0].status);
        }
    }
};

test "queue pause invalidates enqueue autostart across persistence and cold restoration" {
    try StaleStartFixture.check(.enqueue, false);
    try StaleStartFixture.check(.enqueue, true);
}

test "queue pause invalidates retry autostart across persistence and cold restoration" {
    try StaleStartFixture.check(.retry, false);
    try StaleStartFixture.check(.retry, true);
}

test "queue pause invalidates remove resume across persistence and cold restoration" {
    try StaleStartFixture.check(.remove, false);
    try StaleStartFixture.check(.remove, true);
}

test "queue pause invalidates a cold explicit start waiting for restoration" {
    try StaleStartFixture.check(.start, true);
}

test "queue pause invalidates a start awaiting completed runner cleanup" {
    const t = std.testing;
    var engine = Engine.init(t.allocator, t.io, @import("backend.zig").none, .{ .dir = "unused" });
    defer engine.deinit();
    defer engine.queue.deinit(&engine);
    engine.queue.loaded = true;
    try engine.queue.append(t.allocator, "must not launch", 1);
    var old: LifecycleGate = .{ .engine = &engine };
    var starter: LifecycleGate = .{ .engine = &engine };
    var pauser: LifecycleGate = .{ .engine = &engine };
    old.parked.set(t.io);
    engine.queue.runner = try t.io.concurrent(LifecycleGate.runner, .{&old});
    try old.cleaning.wait(t.io);
    engine.queue.runner_done = true;
    var starting = try t.io.concurrent(LifecycleGate.start, .{&starter});
    while (engine.queue.lifecycle_lock.state.load(.acquire) == .unlocked)
        try t.io.sleep(.fromMilliseconds(1), .awake);
    var pausing = try t.io.concurrent(LifecycleGate.pause, .{&pauser});
    try LifecycleGate.waitContended(&engine.queue.lifecycle_lock);
    old.release.set(t.io);
    try starting.await(t.io);
    pausing.await(t.io);
    try t.expect(engine.queue.paused);
    try t.expect(engine.queue.runner == null);
}

test "queue pending persistence cannot erase durable membership after teardown" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var fixture: PipelineFixture = .{};
    var engine = Engine.init(t.allocator, t.io, fixture.backend(), .{ .dir = dir });
    defer engine.deinit();
    try PipelineFixture.setup(&engine, a);
    _ = try engine.queue.enqueue(&engine, &.{ "1:/c1", "1:/c2" }, false);
    const Writer = struct {
        fn run(e: *Engine) !void {
            try e.queue.moveToFront(e, "1:/c2");
        }
    };
    engine.queue.persistence_lock.lockUncancelable(t.io);
    var writer = try t.io.concurrent(Writer.run, .{&engine});
    while (engine.queue.persistence_lock.state.load(.acquire) != .contended)
        try t.io.sleep(.fromMilliseconds(1), .awake);
    engine.queue.deinit(&engine);
    engine.queue.persistence_lock.unlock(t.io);
    try t.expectError(error.QueueClosed, writer.await(t.io));
    var restored = Engine.init(t.allocator, t.io, fixture.backend(), .{ .dir = dir });
    defer restored.deinit();
    defer restored.queue.deinit(&restored);
    const saved = try restored.queue.snapshot(&restored, a);
    try t.expectEqual(2, saved.len);
    try t.expectEqualStrings("1:/c1", saved[0].chapter_id);
    try t.expectEqualStrings("1:/c2", saved[1].chapter_id);
}

const RemovalIntentFixture = struct {
    const Stop = enum { none, pause, clear, teardown };
    fn remove(e: *Engine, id: []const u8) !void {
        try e.queue.remove(e, id);
    }
    fn clear(e: *Engine) anyerror!void {
        try e.queue.clear(e);
    }
    fn check(stop: Stop) !void {
        const t = std.testing;
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var fixture: PipelineFixture = .{ .park_images = true };
        var engine = Engine.init(t.allocator, t.io, fixture.backend(), .{ .dir = try tmp.dir.realPathFileAlloc(t.io, ".", a), .parallelism = 2 });
        defer engine.deinit();
        defer engine.queue.deinit(&engine);
        engine.setNetwork(.wifi);
        try engine.store.save(a, .{ .manga = &.{.{ .id = "1:/m", .title = "M", .source_id = 1, .chapters = &.{
            .{ .id = "1:/c1", .title = "C1", .source_order = 2, .remote = .{ .url = "/c1", .name = "C1" } },
            .{ .id = "1:/c2", .title = "C2", .source_order = 1, .remote = .{ .url = "/c2", .name = "C2" } },
            .{ .id = "1:/c3", .title = "C3", .source_order = 0, .remote = .{ .url = "/c3", .name = "C3" } },
        } }} });
        _ = try engine.queue.enqueue(&engine, &.{ "1:/c1", "1:/c2", "1:/c3" }, false);
        // A real cancellable runner, with deterministic teardown and no page
        // timing before the two membership updates are parked on persistence.
        var old: LifecycleGate = .{ .engine = &engine };
        old.release.set(t.io);
        engine.queue.runner = try t.io.concurrent(LifecycleGate.runner, .{&old});
        engine.queue.paused = false;
        engine.queue.persistence_lock.lockUncancelable(t.io);
        var first = try t.io.concurrent(remove, .{ &engine, "1:/c1" });
        try LifecycleGate.waitContended(&engine.queue.persistence_lock);
        var second = try t.io.concurrent(remove, .{ &engine, "1:/c2" });
        while (true) {
            engine.queue.acquire();
            const ready = engine.queue.items.items.len == 1;
            engine.queue.lock.unlock();
            if (ready) break;
            try t.io.sleep(.fromMilliseconds(1), .awake);
        }
        var clearing: ?Io.Future(anyerror!void) = null;
        switch (stop) {
            .none => {},
            .pause => engine.queue.pause(&engine),
            .teardown => engine.queue.deinit(&engine),
            .clear => {
                clearing = try t.io.concurrent(clear, .{&engine});
                while (true) {
                    engine.queue.acquire();
                    const empty = engine.queue.items.items.len == 0;
                    engine.queue.lock.unlock();
                    if (empty) break;
                    try t.io.sleep(.fromMilliseconds(1), .awake);
                }
            },
        }
        engine.queue.persistence_lock.unlock(t.io);
        if (stop == .teardown) {
            try t.expectError(error.QueueClosed, first.await(t.io));
            try t.expectError(error.QueueClosed, second.await(t.io));
        } else {
            try first.await(t.io);
            try second.await(t.io);
        }
        if (clearing) |*future| try future.await(t.io);
        if (stop == .none) {
            try fixture.first_image.wait(t.io);
            try t.expect(engine.queue.running());
            const entries = try engine.queue.snapshot(&engine, a);
            try t.expectEqual(1, entries.len);
            try t.expectEqualStrings("1:/c3", entries[0].chapter_id);
            try t.expectEqual(1, fixture.plans.load(.acquire));
        } else {
            try t.expect(engine.queue.paused);
            try t.expect(!engine.queue.running());
            try t.expectEqual(0, fixture.plans.load(.acquire));
        }
    }
};

test "queue overlapping removals transfer running intent to the surviving chapter" {
    try RemovalIntentFixture.check(.none);
}

test "queue explicit stops invalidate overlapping removal resume intent" {
    try RemovalIntentFixture.check(.pause);
    try RemovalIntentFixture.check(.clear);
    try RemovalIntentFixture.check(.teardown);
}

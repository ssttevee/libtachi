//! Mihon's download queue: chapters waiting to download, worked through in
//! order in the background. Ordered entries are kept in SQLite, importing
//! legacy `downloads/queue.json` once, so
//! the queue survives a restart; a chapter that fails stays queued for a
//! retry, as in Mihon, and the next one goes on.
const std = @import("std");
const Io = std.Io;
const library = @import("library.zig");
const models = @import("models.zig");
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
    items: std.ArrayList(Item) = .empty,
    loaded: bool = false,
    paused: bool = true,
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
        self.pause(engine);
        for (self.items.items) |item| freeItem(engine.gpa, item);
        self.items.deinit(engine.gpa);
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
        if (self.loaded) return;
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const saved = try loadSaved(engine, a);
        const lib = try engine.store.load(a);
        const original_len = self.items.items.len;
        errdefer {
            for (self.items.items[original_len..]) |item| freeItem(engine.gpa, item);
            self.items.shrinkRetainingCapacity(original_len);
        }
        for (saved.chapters) |id| {
            var source: i64 = 0;
            find: for (lib.manga) |m| for (m.chapters) |ch| if (std.mem.eql(u8, ch.id, id)) {
                source = m.source_id orelse 0;
                break :find;
            };
            try self.append(engine.gpa, id, source);
            const progress = engine.downloadProgress(a, id) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
            if (progress) |saved_pages| {
                const item = &self.items.items[self.items.items.len - 1];
                item.pages_done = saved_pages.done;
                item.pages_total = saved_pages.total;
            }
            for (saved.browser_verification_required) |blocked| if (std.mem.eql(u8, id, blocked.chapter_id)) {
                const item = &self.items.items[self.items.items.len - 1];
                item.failure = try engine.gpa.dupe(u8, blocked.failure);
                item.browser_verification_required = true;
                item.status = .failed;
                break;
            };
        }
        self.loaded = true;
    }

    /// Saves the queue; the caller holds the lock.
    fn persist(self: *Queue, engine: *Engine) !void {
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const ids = try a.alloc([]const u8, self.items.items.len);
        for (self.items.items, ids) |item, *id| id.* = item.chapter_id;
        var blocked: std.ArrayList(Blocked) = .empty;
        for (self.items.items) |item| if (item.browser_verification_required) {
            try blocked.append(a, .{ .chapter_id = item.chapter_id, .failure = item.failure orelse "BrowserVerificationRequired" });
        };
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
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const lib = try engine.store.load(a);
        const Found = struct { chapter: library.Chapter, source: i64 };
        var chapters: std.ArrayList(Found) = .empty;
        for (chapter_ids) |id| for (lib.manga) |m| {
            const source = m.source_id orelse continue;
            for (m.chapters) |ch| if (std.mem.eql(u8, ch.id, id) and !ch.downloaded()) try chapters.append(a, .{ .chapter = ch, .source = source });
        };
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
        if (autostart) try self.startLocked(engine);
        return added;
    }

    /// Works through the queue, retrying failures except unsupported browser verification.
    pub fn start(self: *Queue, engine: *Engine) !void {
        self.acquire();
        defer self.lock.unlock();
        try self.ensureLoaded(engine);
        try self.startLocked(engine);
    }

    fn startLocked(self: *Queue, engine: *Engine) !void {
        for (self.items.items) |*item| if (item.status == .failed and !item.browser_verification_required) {
            item.status = .queued;
        };
        self.paused = false;
        if (self.runner) |*r| {
            if (!self.runner_done) return;
            // Done already, so this returns at once.
            r.await(engine.io);
            self.runner = null;
        }
        if (self.items.items.len == 0) return;
        self.runner_done = false;
        self.runner = try engine.io.concurrent(run, .{ self, engine });
    }

    /// Stops after cancelling the download in progress; its saved pages stay.
    pub fn pause(self: *Queue, engine: *Engine) void {
        self.acquire();
        self.paused = true;
        self.notify(engine.io);
        var runner = self.runner;
        self.runner = null;
        self.lock.unlock();
        if (runner) |*r| r.cancel(engine.io);
    }

    /// Removes a chapter from the queue, cancelling it if it is downloading.
    pub fn remove(self: *Queue, engine: *Engine, chapter_id: []const u8) !void {
        self.acquire();
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
        if (was_running) self.pause(engine);
        self.acquire();
        defer self.lock.unlock();
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        try engine.discardQueuedPlan(arena.allocator(), chapter_id);
        for (self.items.items, 0..) |item, i| if (std.mem.eql(u8, item.chapter_id, chapter_id)) {
            freeItem(engine.gpa, self.items.orderedRemove(i));
            break;
        };
        try self.persist(engine);
        if (was_running) try self.startLocked(engine);
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
        self.pause(engine);
        self.acquire();
        defer self.lock.unlock();
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        // Clear even before the saved queue has been loaded, and clean up
        // orphan plans left by an interrupted queue update.
        for (self.items.items) |*item| item.prepared = false;
        try Io.Dir.cwd().deleteTree(engine.io, try std.fs.path.join(arena.allocator(), &.{ engine.options.dir, "downloads", "queued-plans" }));
        try persistence.removePrefix(arena.allocator(), engine.io, engine.options.dir, "queued-plan/");
        self.loaded = true;
        for (self.items.items) |item| freeItem(engine.gpa, item);
        self.items.clearRetainingCapacity();
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
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        const settings = engine.loadSettings(arena.allocator()) catch @import("settings.zig").Settings{};
        const source_limit = @max(1, settings.downloads.parallel_sources);
        const page_limit = engine.pageParallelism(arena.allocator()) catch 1;
        var scheduler: downloads.Scheduler = .init(engine.gpa, page_limit);
        defer scheduler.deinit();
        defer if (engine.options.release_jvm) engine.backend.release();
        const Workers = struct {
            queue: *Queue,
            engine: *Engine,
            scheduler: *downloads.Scheduler,
            source_limit: usize,
            fn work(ctx: *@This(), _: std.mem.Allocator, index: usize) !void {
                if (index == 0) return ctx.queue.plan(ctx.engine);
                try ctx.queue.work(ctx.engine, ctx.scheduler, ctx.source_limit, index);
            }
            fn publish(_: *@This(), _: usize, _: void, _: *std.heap.ArenaAllocator) !void {}
        };
        const count = source_limit * 2 + 1;
        const waiters = engine.gpa.alloc(Io.Event, count) catch {
            self.acquire();
            self.runner_done = true;
            self.lock.unlock();
            return;
        };
        defer engine.gpa.free(waiters);
        for (waiters) |*event| event.* = .unset;
        self.acquire();
        self.waiters = waiters;
        self.lock.unlock();
        var workers: Workers = .{ .queue = self, .engine = engine, .scheduler = &scheduler, .source_limit = source_limit };
        while (true) {
            self.acquire();
            self.planner_done = false;
            self.lock.unlock();
            parallel.run(engine.gpa, engine.io, count, count, &workers, Workers.work, Workers.publish) catch |err| {
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

    fn plan(self: *Queue, engine: *Engine) Io.Cancelable!void {
        defer {
            self.acquire();
            self.planner_done = true;
            self.notify(engine.io);
            self.lock.unlock();
        }
        while (true) {
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
            const id = engine.gpa.dupe(u8, next.?.chapter_id) catch {
                self.lock.unlock();
                return;
            };
            defer engine.gpa.free(id);
            var job: Job = .{ .arena = .init(engine.gpa), .engine = engine, .request = .{ .download = id } };
            defer job.arena.deinit();
            next.?.status = .downloading;
            next.?.planning = true;
            next.?.job = &job;
            self.lock.unlock();
            tachi.setLastError("");
            const outcome = engine.prepareQueuedChapter(&job, id);
            self.finish(engine, id, &job, outcome, true);
            if (outcome) |_| {} else |err| if (err == error.Canceled) return error.Canceled;
        }
    }

    fn work(self: *Queue, engine: *Engine, scheduler: *downloads.Scheduler, source_limit: usize, waiter: usize) Io.Cancelable!void {
        while (true) {
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
            const id = engine.gpa.dupe(u8, next.?.chapter_id) catch {
                self.lock.unlock();
                return;
            };
            defer engine.gpa.free(id);
            var job: Job = .{ .arena = .init(engine.gpa), .engine = engine, .request = .{ .download = id } };
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
        if (!planning) if (engine.downloadProgress(job.arena.allocator(), id) catch null) |progress| {
            item.pages_done = progress.done;
            item.pages_total = progress.total;
        };
        if (outcome) |_| {
            if (planning) {
                item.prepared = true;
                item.status = .queued;
                if (engine.downloadProgress(job.arena.allocator(), id) catch null) |progress| {
                    item.pages_done = progress.done;
                    item.pages_total = progress.total;
                }
            } else {
                engine.discardQueuedPlan(job.arena.allocator(), id) catch |err| log.warn("page plan not removed: {s}", .{@errorName(err)});
                freeItem(engine.gpa, self.items.orderedRemove(i));
                self.persist(engine) catch |err| log.warn("download queue not saved: {s}", .{@errorName(err)});
            }
        } else |err| switch (err) {
            error.Canceled => item.status = .queued,
            else => {
                item.status = .failed;
                if (item.failure) |f| engine.gpa.free(f);
                const detail = tachi.lastError();
                item.failure = (if (job.failure) |failure|
                    engine.gpa.dupe(u8, failure)
                else if (detail.len > 0)
                    std.fmt.allocPrint(engine.gpa, "{s}: {s}", .{ @errorName(err), detail })
                else
                    engine.gpa.dupe(u8, @errorName(err))) catch null;
                item.browser_verification_required = err == error.BrowserVerificationRequired;
                self.persist(engine) catch |save_err| log.warn("download queue not saved: {s}", .{@errorName(save_err)});
                log.warn("download {s}: {s}", .{ id, item.failure orelse @errorName(err) });
            },
        }
    }

    fn networkAllowed(engine: *Engine) bool {
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        const s = engine.loadSettings(arena.allocator()) catch return true;
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

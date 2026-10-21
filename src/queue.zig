//! Mihon's download queue: chapters waiting to download, worked through in
//! order in the background. Entries are kept in `downloads/queue.json`, so
//! the queue survives a restart; a chapter that fails stays queued for a
//! retry, as in Mihon, and the next one goes on.
const std = @import("std");
const Io = std.Io;
const library = @import("library.zig");
const models = @import("models.zig");
const engine_mod = @import("engine.zig");
const parallel = @import("parallel.zig");
const tachi = @import("tachi.zig");
const Engine = engine_mod.Engine;
const Job = engine_mod.Job;

const log = std.log.scoped(.tachi);

pub const Status = enum { queued, downloading, failed };

/// A queue entry as `snapshot` reports it.
pub const Entry = struct {
    chapter_id: []const u8,
    status: Status,
    pages_done: usize = 0,
    pages_total: usize = 0,
    phase: engine_mod.Phase = .operation,
    /// Why the last attempt failed.
    failure: ?[]const u8 = null,
};

const Item = struct {
    chapter_id: []u8,
    /// The chapter's source, which only one worker downloads from at a time.
    source: i64 = 0,
    status: Status = .queued,
    failure: ?[]u8 = null,
    browser_verification_required: bool = false,
    /// The download running now, for its page progress.
    job: ?*Job = null,
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

    fn acquire(self: *Queue) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
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

    fn path(engine: *Engine, a: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(a, &.{ engine.options.dir, "downloads", "queue.json" });
    }

    /// Loads the saved queue once; the caller holds the lock.
    fn ensureLoaded(self: *Queue, engine: *Engine) !void {
        if (self.loaded) return;
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const bytes = Io.Dir.cwd().readFileAlloc(engine.io, try path(engine, a), a, .limited(16 << 20)) catch |err| switch (err) {
            error.FileNotFound => {
                self.loaded = true;
                return;
            },
            else => return err,
        };
        const saved = try std.json.parseFromSliceLeaky(Saved, a, bytes, models.parse_options);
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
        const file = try path(engine, a);
        try Io.Dir.cwd().createDirPath(engine.io, std.fs.path.dirname(file).?);
        var blocked: std.ArrayList(Blocked) = .empty;
        for (self.items.items) |item| if (item.browser_verification_required) {
            try blocked.append(a, .{ .chapter_id = item.chapter_id, .failure = item.failure orelse "BrowserVerificationRequired" });
        };
        try library.writeJsonAtomic(a, engine.io, file, Saved{ .chapters = ids, .browser_verification_required = blocked.items });
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
        const downloading = for (self.items.items) |item| {
            if (std.mem.eql(u8, item.chapter_id, chapter_id)) break item.status == .downloading;
        } else false;
        self.lock.unlock();
        const was_running = !self.paused;
        if (downloading) self.pause(engine);
        self.acquire();
        defer self.lock.unlock();
        for (self.items.items, 0..) |item, i| if (std.mem.eql(u8, item.chapter_id, chapter_id)) {
            freeItem(engine.gpa, self.items.orderedRemove(i));
            break;
        };
        try self.persist(engine);
        if (downloading and was_running) try self.startLocked(engine);
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
            e.* = .{ .chapter_id = try arena.dupe(u8, item.chapter_id), .status = item.status, .failure = if (item.failure) |f| try arena.dupe(u8, f) else null };
            if (item.job) |job| {
                e.phase = job.phase.load(.acquire);
                e.pages_done = job.pages_done.load(.acquire);
                e.pages_total = job.pages_total.load(.acquire);
            }
        }
        return out;
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

    /// Mihon's scheduling: up to `parallel_sources` sources at once, each
    /// working through its own chapters in queue order.
    fn run(self: *Queue, engine: *Engine) void {
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        const limit = blk: {
            const s = engine.loadSettings(arena.allocator()) catch break :blk 1;
            break :blk @max(1, s.downloads.parallel_sources);
        };
        const Workers = struct {
            queue: *Queue,
            engine: *Engine,
            fn work(ctx: *@This(), _: std.mem.Allocator, _: usize) !void {
                try ctx.queue.work(ctx.engine);
            }
            fn publish(_: *@This(), _: usize, _: void, _: *std.heap.ArenaAllocator) !void {}
        };
        var workers: Workers = .{ .queue = self, .engine = engine };
        parallel.run(engine.gpa, engine.io, limit, limit, &workers, Workers.work, Workers.publish) catch |err| switch (err) {
            error.Canceled => {},
            else => log.warn("download queue stopped: {s}", .{@errorName(err)}),
        };
        self.acquire();
        self.runner_done = true;
        self.lock.unlock();
    }

    /// One worker: takes the first queued chapter whose source no other
    /// worker is downloading from, until none is left.
    fn work(self: *Queue, engine: *Engine) Io.Cancelable!void {
        while (true) {
            // Off Wi-Fi with Wi-Fi-only downloads, Mihon stops and keeps the queue.
            const allowed = networkAllowed(engine);
            self.acquire();
            self.waiting_for_wifi = !allowed;
            if (!allowed) {
                self.lock.unlock();
                return;
            }
            const next = for (self.items.items) |*item| {
                if (item.status != .queued) continue;
                const busy = for (self.items.items) |other| {
                    if (other.status == .downloading and other.source == item.source) break true;
                } else false;
                if (!busy) break item;
            } else null;
            if (self.paused or next == null) {
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
            next.?.job = &job;
            self.lock.unlock();
            tachi.setLastError("");
            const outcome = if (enoughSpace(engine)) engine.downloadChapter(&job, id) else error.NotEnoughSpace;
            self.acquire();
            const index = for (self.items.items, 0..) |item, i| {
                if (std.mem.eql(u8, item.chapter_id, id)) break i;
            } else null;
            if (index) |i| {
                const item = &self.items.items[i];
                item.job = null;
                if (outcome) |_| {
                    freeItem(engine.gpa, self.items.orderedRemove(i));
                    self.persist(engine) catch |err| log.warn("download queue not saved: {s}", .{@errorName(err)});
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
            self.lock.unlock();
            if (outcome) |_| {} else |err| if (err == error.Canceled) return error.Canceled;
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
    fn enoughSpace(engine: *Engine) bool {
        var buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const dir = std.fmt.bufPrintSentinel(&buf, "{s}", .{engine.options.dir}, 0) catch return true;
        const free = @import("worker.zig").tachi_free_bytes(dir.ptr);
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

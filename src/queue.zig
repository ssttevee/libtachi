//! Mihon's download queue: chapters waiting to download, worked through in
//! order in the background. Entries are kept in `downloads/queue.json`, so
//! the queue survives a restart; a chapter that fails stays queued for a
//! retry, as in Mihon, and the next one goes on.
const std = @import("std");
const Io = std.Io;
const library = @import("library.zig");
const models = @import("models.zig");
const engine_mod = @import("engine.zig");
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
    /// Why the last attempt failed.
    failure: ?[]const u8 = null,
};

const Item = struct {
    chapter_id: []u8,
    /// The chapter's source, which only one worker downloads from at a time.
    source: i64 = 0,
    status: Status = .queued,
    failure: ?[]u8 = null,
    /// The download running now, for its page progress.
    job: ?*Job = null,
};

const Saved = struct { chapters: []const []const u8 = &.{} };

pub const Queue = struct {
    lock: std.atomic.Mutex = .unlocked,
    items: std.ArrayList(Item) = .empty,
    loaded: bool = false,
    paused: bool = true,
    runner: ?Io.Future(void) = null,
    /// The runner ran out of work and returned; it still has to be awaited.
    runner_done: bool = false,

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

    fn path(engine: *Engine, a: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(a, &.{ engine.options.dir, "downloads", "queue.json" });
    }

    /// Loads the saved queue once; the caller holds the lock.
    fn ensureLoaded(self: *Queue, engine: *Engine) !void {
        if (self.loaded) return;
        self.loaded = true;
        var arena: std.heap.ArenaAllocator = .init(engine.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const bytes = Io.Dir.cwd().readFileAlloc(engine.io, try path(engine, a), a, .limited(16 << 20)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        const saved = try std.json.parseFromSliceLeaky(Saved, a, bytes, models.parse_options);
        const lib = try engine.store.load(a);
        for (saved.chapters) |id| {
            var source: i64 = 0;
            find: for (lib.manga) |m| for (m.chapters) |ch| if (std.mem.eql(u8, ch.id, id)) {
                source = m.source_id orelse 0;
                break :find;
            };
            try self.items.append(engine.gpa, .{ .chapter_id = try engine.gpa.dupe(u8, id), .source = source });
        }
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
        try library.writeJsonAtomic(a, engine.io, file, Saved{ .chapters = ids });
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
            try self.items.append(engine.gpa, .{ .chapter_id = try engine.gpa.dupe(u8, found.chapter.id), .source = found.source });
            added += 1;
        }
        if (added > 0) try self.persist(engine);
        if (autostart) try self.startLocked(engine);
        return added;
    }

    /// Works through the queue in the background, retrying failed entries.
    pub fn start(self: *Queue, engine: *Engine) !void {
        self.acquire();
        defer self.lock.unlock();
        try self.ensureLoaded(engine);
        try self.startLocked(engine);
    }

    fn startLocked(self: *Queue, engine: *Engine) !void {
        for (self.items.items) |*item| if (item.status == .failed) {
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
                e.pages_done = job.pages_done.load(.acquire);
                e.pages_total = job.pages_total.load(.acquire);
            }
        }
        return out;
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
        var group: Io.Group = .init;
        for (0..limit) |_| group.concurrent(engine.io, work, .{ self, engine }) catch {
            // No more threads: the workers already started share the queue.
            break;
        };
        group.await(engine.io) catch {};
        self.acquire();
        self.runner_done = true;
        self.lock.unlock();
    }

    /// One worker: takes the first queued chapter whose source no other
    /// worker is downloading from, until none is left.
    fn work(self: *Queue, engine: *Engine) Io.Cancelable!void {
        while (true) {
            self.acquire();
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
                        item.failure = std.fmt.allocPrint(engine.gpa, "{s}", .{job.failure orelse @errorName(err)}) catch null;
                        log.warn("download {s}: {s}", .{ id, item.failure orelse @errorName(err) });
                    },
                }
            }
            self.lock.unlock();
            if (outcome) |_| {} else |err| if (err == error.Canceled) return error.Canceled;
        }
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

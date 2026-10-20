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
    status: Status = .queued,
    failure: ?[]u8 = null,
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
    /// The download running now, for its page progress.
    current: ?*Job = null,

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
        for (saved.chapters) |id| try self.items.append(engine.gpa, .{ .chapter_id = try engine.gpa.dupe(u8, id) });
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
        var chapters: std.ArrayList(library.Chapter) = .empty;
        for (chapter_ids) |id| for (lib.manga) |m| {
            if (m.local()) continue;
            for (m.chapters) |ch| if (std.mem.eql(u8, ch.id, id) and !ch.downloaded()) try chapters.append(a, ch);
        };
        // Oldest first: the source lists newest first.
        std.mem.sort(library.Chapter, chapters.items, {}, struct {
            fn less(_: void, x: library.Chapter, y: library.Chapter) bool {
                return x.source_order > y.source_order;
            }
        }.less);
        self.acquire();
        defer self.lock.unlock();
        try self.ensureLoaded(engine);
        var added: usize = 0;
        for (chapters.items) |ch| {
            const queued = for (self.items.items) |item| {
                if (std.mem.eql(u8, item.chapter_id, ch.id)) break true;
            } else false;
            if (queued) continue;
            try self.items.append(engine.gpa, .{ .chapter_id = try engine.gpa.dupe(u8, ch.id) });
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
            if (item.status == .downloading) if (self.current) |job| {
                e.pages_done = job.pages_done.load(.acquire);
                e.pages_total = job.pages_total.load(.acquire);
            };
        }
        return out;
    }

    /// Whether the queue is working through its entries.
    pub fn running(self: *Queue) bool {
        self.acquire();
        defer self.lock.unlock();
        return self.runner != null and !self.runner_done and !self.paused;
    }

    fn run(self: *Queue, engine: *Engine) void {
        while (true) {
            self.acquire();
            const next = for (self.items.items) |*item| {
                if (item.status == .queued) break item;
            } else null;
            if (self.paused or next == null) {
                self.runner_done = true;
                self.lock.unlock();
                return;
            }
            next.?.status = .downloading;
            const id = engine.gpa.dupe(u8, next.?.chapter_id) catch {
                next.?.status = .queued;
                self.runner_done = true;
                self.lock.unlock();
                return;
            };
            defer engine.gpa.free(id);
            var job: Job = .{ .arena = .init(engine.gpa), .engine = engine, .request = .{ .download = id } };
            defer job.arena.deinit();
            self.current = &job;
            self.lock.unlock();
            const outcome = engine.downloadChapter(&job, id);
            self.acquire();
            self.current = null;
            const index = for (self.items.items, 0..) |item, i| {
                if (std.mem.eql(u8, item.chapter_id, id)) break i;
            } else null;
            if (index) |i| {
                const item = &self.items.items[i];
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
            const canceled = if (outcome) |_| false else |err| err == error.Canceled;
            if (canceled) self.runner_done = true;
            self.lock.unlock();
            if (canceled) return;
        }
    }
};

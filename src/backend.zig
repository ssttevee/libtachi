//! Everything the engine needs from extensions, as typed calls. `InProcess`
//! runs them on a `Runtime` in this process; `worker.Client` runs the same
//! calls in a helper process, so a JVM crash or its memory never touches the
//! caller. Either is used through `Backend`.
const std = @import("std");
const Io = std.Io;
const tachi = @import("tachi.zig");
const models = @import("models.zig");
const manage = @import("manage.zig");

const log = std.log.scoped(.tachi);

pub const Call = union(enum) {
    /// Installed sources.
    sources,
    /// The repository's extensions joined with what is installed.
    extensions: Repo,
    install: struct { pkg: []const u8, repo: Repo = .{} },
    install_file: []const u8,
    uninstall: []const u8,
    /// Updates every installed extension the repository has a newer version of.
    update_extensions: Repo,
    browse: struct { source: i64, page: i32 = 1, kind: tachi.Runtime.Browse = .popular },
    /// Details and chapters of a title, in one source call.
    update: struct { source: i64, manga: models.Manga, chapters: []const models.Chapter = &.{}, details: bool = true, chapter_list: bool = true },
    pages: struct { source: i64, chapter: models.Chapter },
    image_requests: struct { source: i64, chapter: models.Chapter },
    /// One page through the source's client; `cookies` from its plan are restored first.
    image: struct { source: i64, page: models.Page, url: []const u8 = "", cookies: []const []const u8 = &.{} },
    filters: i64,
    related: struct { source: i64, manga: models.Manga },
    preferences: i64,
    set_preference: struct { source: i64, key: []const u8, value: std.json.Value },
    /// Extensions read their preference files again.
    reload_preferences,

    pub const Repo = struct {
        /// Index URL; null for the default repository.
        url: ?[]const u8 = null,
        /// Ignore the cached index.
        refresh: bool = false,
        /// With stores configured and no `url`: every extension, not just
        /// those in enabled languages and content warnings.
        all: bool = false,

        fn options(self: Repo) manage.RepoOptions {
            return .{ .url = self.url, .refresh = self.refresh };
        }
    };

    /// The source a call runs on, if any.
    pub fn source(self: Call) ?i64 {
        return switch (self) {
            inline .browse, .update, .pages, .image_requests, .image, .related, .set_preference => |c| c.source,
            .filters, .preferences => |id| id,
            .sources, .extensions, .install, .install_file, .uninstall, .update_extensions, .reload_preferences => null,
        };
    }
};

/// What a call returns; only the field for that call is set.
pub const Reply = struct {
    sources: []const models.SourceInfo = &.{},
    extensions: []const manage.RepoEntry = &.{},
    extension_updates: ?manage.UpdateResult = null,
    page: ?models.MangasPage = null,
    update: ?models.MangaUpdate = null,
    pages: []const models.Page = &.{},
    image_requests: []const models.ImageRequest = &.{},
    image: ?[]const u8 = null,
    filters: []const models.Filter = &.{},
    mangas: []const models.Manga = &.{},
    preferences: []const models.Preference = &.{},
};

/// Progress a call reports while it runs; every function may be called from
/// another thread.
pub const Status = struct {
    context: *anyopaque,
    /// The JVM is starting before the call can run.
    starting: *const fn (context: *anyopaque) void,
    /// The JVM is ready; the call itself is running.
    ready: *const fn (context: *anyopaque) void,
    /// An extension is loading before its first call, or `null` once it has.
    loading: *const fn (context: *anyopaque, extension: ?[]const u8) void,
};

pub const Backend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Runs in the caller's Io task; propagate error.Canceled when that task
        /// is canceled. Foreign work must unwind before releasing its borrowed inputs.
        /// Returns a reply allocated in `arena`.
        run: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, call: Call, status: ?Status) anyerror!Reply,
        /// Whether a call would run without starting the JVM first.
        warm: *const fn (ptr: *anyopaque) bool,
        /// Backend-wide administrative cancellation, for pause/shutdown.
        /// Cancel an individual job through its Io task instead.
        cancel: *const fn (ptr: *anyopaque) void,
        /// The caller has no extension work for now: a helper process may exit
        /// to give its memory back. The next call starts it again.
        release: *const fn (ptr: *anyopaque) void,
        /// No call is running: a good moment for upkeep such as saving the
        /// startup cache. May pause briefly.
        idle: *const fn (ptr: *anyopaque) void,
    };

    pub fn run(self: Backend, arena: std.mem.Allocator, call: Call, status: ?Status) !Reply {
        return self.vtable.run(self.ptr, arena, call, status);
    }
    pub fn warm(self: Backend) bool {
        return self.vtable.warm(self.ptr);
    }
    pub fn cancel(self: Backend) void {
        self.vtable.cancel(self.ptr);
    }
    pub fn release(self: Backend) void {
        self.vtable.release(self.ptr);
    }
    pub fn idle(self: Backend) void {
        self.vtable.idle(self.ptr);
    }
};

/// A backend for engines whose jobs never reach extensions, such as tests
/// that set `Engine.execute_fn`. Every call fails with `error.NoBackend`.
pub const none: Backend = .{ .ptr = &none_state, .vtable = &.{ .run = noneRun, .warm = noneWarm, .cancel = noneQuiet, .release = noneQuiet, .idle = noneQuiet } };
var none_state: u8 = 0;
fn noneRun(_: *anyopaque, _: std.mem.Allocator, _: Call, _: ?Status) anyerror!Reply {
    return error.NoBackend;
}
fn noneWarm(_: *anyopaque) bool {
    return true;
}
fn noneQuiet(_: *anyopaque) void {}

/// Runs calls on a `Runtime` in this process, creating it on first use.
pub const InProcess = struct {
    gpa: std.mem.Allocator,
    io: Io,
    options: tachi.Options,
    rt: ?*tachi.Runtime = null,
    /// HotSpot cannot be created twice in a process, so a failed start is final.
    attempted: bool = false,
    lock: Io.Mutex = .init,
    /// Source of the call in progress, for `cancel`; 0 when none. Locked
    /// rather than atomic: 32-bit ARM has no 64-bit atomics.
    current: i64 = 0,
    current_lock: std.atomic.Mutex = .unlocked,

    pub fn init(gpa: std.mem.Allocator, io: Io, options: tachi.Options) InProcess {
        return .{ .gpa = gpa, .io = io, .options = options };
    }

    pub fn deinit(self: *InProcess) void {
        if (self.rt) |rt| rt.deinit();
        self.rt = null;
    }

    pub fn backend(self: *InProcess) Backend {
        return .{ .ptr = self, .vtable = &.{ .run = runErased, .warm = warmErased, .cancel = cancelErased, .release = releaseErased, .idle = idleErased } };
    }

    /// The runtime, created and restored on first use.
    pub fn runtime(self: *InProcess) !*tachi.Runtime {
        self.lock.lockUncancelable(self.io);
        defer self.lock.unlock(self.io);
        if (self.rt) |rt| return rt;
        if (self.attempted) return error.RuntimeStartupFailed;
        self.attempted = true;
        const started = now(self.io);
        const rt = try tachi.Runtime.init(self.gpa, self.io, self.options);
        self.rt = rt;
        const created = now(self.io);
        const restored = try rt.restore();
        defer self.gpa.free(restored);
        log.info("runtime jvm_ms={d} restore_ms={d}", .{ created - started, now(self.io) - created });
        const report = std.json.parseFromSlice(manage.RestoreResult, self.gpa, restored, models.parse_options) catch return rt;
        defer report.deinit();
        for (report.value.failed) |failure| log.warn("extension restore {s}: {s}", .{ failure.pkg, failure.@"error" });
        return rt;
    }

    /// Saves the runtime's startup cache if it has one to save (see
    /// `Runtime.saveStartupCache`); call while no call is running.
    pub fn idle(self: *InProcess) void {
        const rt = self.rt orelse return;
        if (!rt.startupCachePending()) return;
        const started = now(self.io);
        if (rt.saveStartupCache()) {
            log.info("startup cache saved ms={d}", .{now(self.io) - started});
        } else |err| log.warn("startup cache not saved: {s}", .{@errorName(err)});
        rt.detachThread();
    }

    pub fn run(self: *InProcess, arena: std.mem.Allocator, call: Call, status: ?Status) !Reply {
        tachi.setLastError("");
        if (self.rt == null) if (status) |s| s.starting(s.context);
        const rt = try self.runtime();
        defer rt.detachThread();
        if (status) |s| s.ready(s.context);
        if (call.source()) |id| {
            if (try rt.extensionToLoad(arena, id)) |name| {
                if (status) |s| s.loading(s.context, name);
                try rt.loadSource(id);
                if (status) |s| s.loading(s.context, null);
            }
            self.setCurrent(id);
        }
        defer self.setCurrent(0);
        return switch (call) {
            .sources => .{ .sources = try sources(rt, arena) },
            .extensions => |repo| .{ .extensions = try rt.repoList(arena, repo.options()) },
            .install => |c| blk: {
                self.gpa.free(try rt.repoInstall(c.pkg, c.repo.options()));
                break :blk .{ .sources = try sources(rt, arena) };
            },
            .install_file => |path| blk: {
                self.gpa.free(try rt.installExtension(path));
                break :blk .{ .sources = try sources(rt, arena) };
            },
            .uninstall => |pkg| blk: {
                _ = try rt.uninstallExtension(pkg);
                break :blk .{ .sources = try sources(rt, arena) };
            },
            .update_extensions => |repo| .{ .extension_updates = try into(manage.UpdateResult, arena, try rt.repoUpdate(repo.options()), self.gpa) },
            .reload_preferences => blk: {
                try rt.reloadPreferences();
                break :blk .{};
            },
            .browse => |c| blk: {
                const Args = struct { page: i32, query: []const u8 = "", filters: ?[]const models.Filter = null };
                const method: []const u8, const args: Args = switch (c.kind) {
                    .popular => .{ "popular", .{ .page = c.page } },
                    .latest => .{ "latest", .{ .page = c.page } },
                    .search => |s| .{ "search", .{ .page = c.page, .query = s.query, .filters = s.filters } },
                };
                break :blk .{ .page = try callInto(models.MangasPage, rt, arena, c.source, method, args) };
            },
            .update => |c| .{ .update = try callInto(models.MangaUpdate, rt, arena, c.source, "update", .{ .manga = c.manga, .chapters = c.chapters, .fetchDetails = c.details, .fetchChapters = c.chapter_list }) },
            .pages => |c| .{ .pages = try callInto([]const models.Page, rt, arena, c.source, "pages", .{ .chapter = c.chapter }) },
            .image_requests => |c| .{ .image_requests = try callInto([]const models.ImageRequest, rt, arena, c.source, "imageRequests", .{ .chapter = c.chapter }) },
            .image => |c| blk: {
                if (c.cookies.len > 0) try rt.restoreImageCookies(c.source, c.url, c.cookies);
                const page_json = try std.json.Stringify.valueAlloc(arena, c.page, .{});
                const image = try rt.fetchImage(c.source, page_json);
                defer image.deinit(self.gpa);
                break :blk .{ .image = try arena.dupe(u8, image.bytes) };
            },
            .filters => |id| .{ .filters = try callInto([]const models.Filter, rt, arena, id, "filters", .{}) },
            .related => |c| .{ .mangas = try callInto([]const models.Manga, rt, arena, c.source, "related", .{ .manga = c.manga }) },
            .preferences => |id| .{ .preferences = try callInto([]const models.Preference, rt, arena, id, "preferences", .{}) },
            .set_preference => |c| .{ .preferences = try callInto([]const models.Preference, rt, arena, c.source, "setPreference", .{ .key = c.key, .value = c.value }) },
        };
    }

    /// Cancels the source client's in-flight requests; JNI calls cannot be
    /// interrupted otherwise.
    fn setCurrent(self: *InProcess, id: i64) void {
        while (!self.current_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.current_lock.unlock();
        self.current = id;
    }

    pub fn cancel(self: *InProcess) void {
        const id = blk: {
            while (!self.current_lock.tryLock()) std.atomic.spinLoopHint();
            defer self.current_lock.unlock();
            break :blk self.current;
        };
        if (id == 0) return;
        const rt = self.rt orelse return;
        rt.cancelRequests(id) catch {};
        rt.detachThread();
    }

    fn runErased(ptr: *anyopaque, arena: std.mem.Allocator, call: Call, status: ?Status) anyerror!Reply {
        const self: *InProcess = @ptrCast(@alignCast(ptr));
        return self.run(arena, call, status);
    }
    fn cancelErased(ptr: *anyopaque) void {
        const self: *InProcess = @ptrCast(@alignCast(ptr));
        self.cancel();
    }
    fn warmErased(ptr: *anyopaque) bool {
        const self: *InProcess = @ptrCast(@alignCast(ptr));
        return self.rt != null;
    }
    fn releaseErased(_: *anyopaque) void {}
    fn idleErased(ptr: *anyopaque) void {
        const self: *InProcess = @ptrCast(@alignCast(ptr));
        self.idle();
    }
};

fn sources(rt: *tachi.Runtime, arena: std.mem.Allocator) ![]const models.SourceInfo {
    const extensions = try into([]const models.ExtensionInfo, arena, try rt.listExtensions(), rt.gpa);
    var list: std.ArrayList(models.SourceInfo) = .empty;
    for (extensions) |ext| try list.appendSlice(arena, ext.sources);
    return list.items;
}

/// Parses `json` (owned by `gpa`, freed here) into `arena`.
fn into(comptime T: type, arena: std.mem.Allocator, json: []u8, gpa: std.mem.Allocator) !T {
    defer gpa.free(json);
    return std.json.parseFromSliceLeaky(T, arena, json, models.parse_options);
}

fn callInto(comptime T: type, rt: *tachi.Runtime, arena: std.mem.Allocator, source: i64, method: []const u8, args: anytype) !T {
    const args_json = try models.sourceArguments(arena, args);
    return into(T, arena, try rt.call(source, method, args_json), rt.gpa);
}

fn now(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
}

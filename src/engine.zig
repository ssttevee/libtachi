//! A Tachiyomi-style engine. The library, downloads and local source live in
//! this process; extension calls go through a `Backend`, in this process or a
//! worker. Each operation runs as a `Job` the caller can watch and cancel.
//! Only this process writes the library, so a worker never races it.
//!
//! ```zig
//! var worker: tachi.worker.Client = undefined;
//! try worker.init(gpa, io, .{ .exe = "bin/my-worker", .args = &.{"--serve"} });
//! var engine: tachi.Engine = .init(gpa, io, worker.backend(), .{ .dir = data_dir });
//! const job = try tachi.Job.start(&engine, .{ .browse = .{ .source = id } });
//! job.join();
//! ```
const std = @import("std");
const Io = std.Io;
const tachi = @import("tachi.zig");
const models = @import("models.zig");
const manage = @import("manage.zig");
const library = @import("library.zig");
const downloads = @import("downloads.zig");
const parallel = @import("parallel.zig");
const local = @import("local.zig");
const backup = @import("backup.zig");
const settings = @import("settings.zig");
const queue_mod = @import("queue.zig");
const be = @import("backend.zig");
const views = @import("views.zig");
const tracking = @import("tracking.zig");
const track_drivers = @import("track/driver.zig");
const fetch_interval = @import("fetch_interval.zig");
const mihon_downloads = @import("mihon_downloads.zig");
const preferences = @import("preferences.zig");
const stores = @import("stores.zig");
const repo = @import("repo.zig");

const log = std.log.scoped(.tachi);

pub const Request = union(enum) {
    /// Installed sources.
    sources,
    /// The repository's extensions joined with what is installed.
    extensions: be.Call.Repo,
    install: struct { pkg: []const u8, repo: be.Call.Repo = .{} },
    install_file: []const u8,
    uninstall: []const u8,
    update_extensions: be.Call.Repo,
    browse: struct { source: i64, page: i32 = 1, kind: tachi.Runtime.Browse = .popular },
    filters: i64,
    related: struct { source: i64, manga: models.Manga },
    preferences: i64,
    set_preference: struct { source: i64, key: []const u8, value: std.json.Value },
    /// Adds a source title to the library with its details and chapters.
    add: struct { source: i64, manga: models.Manga },
    /// Fetches a library title's details and chapters again.
    refresh: []const u8,
    /// Refreshes library titles from their sources, with Mihon's rules for
    /// which to skip; `category` limits it to one category instead.
    update_library: struct { category: ?u32 = null },
    /// Downloads a library chapter, resuming pages an earlier attempt saved.
    download: []const u8,
    /// Fetches a thumbnail through its source into the cover cache, as for
    /// a title's cover or a browse result; `Result.cover` is its path.
    cover: struct { source: i64, url: []const u8 },
    /// Loads a chapter for reading as Mihon's online reader does: pages into
    /// the chapter cache from `page` (it, the one before, then forward, then
    /// backward), a failed page not stopping the rest. Downloaded and local
    /// chapters are ready at once. Watch pages with `Job.pageStates`.
    read: struct { chapter: []const u8, page: u32 = 0 },
    /// Deletes a chapter's downloaded pages, unless the deletion settings
    /// protect it; see `Engine.deleteDownloads`.
    delete_download: []const u8,
    /// Takes a title out of the library, keeping its chapters, history and
    /// downloads; `Engine.clearDatabase` forgets it.
    remove: []const u8,
    /// Adds the series in the local source to the library.
    scan_local,
    /// Searches sources for `query`, one page each, as Mihon's global search
    /// does: enabled sources, only pinned ones if `pinned_only`, or exactly
    /// `sources` if given. Results arrive as each source answers; see
    /// `Job.searchResults`.
    global_search: struct { query: []const u8, pinned_only: bool = true, sources: []const i64 = &.{} },
    /// Moves a library title to another source's title (`source`, `manga`)
    /// as Mihon's migration does, carrying over what the settings'
    /// `browse.migration` says. With `replace` false the old title stays in
    /// the library too.
    migrate: struct { from: []const u8, source: i64, manga: models.Manga, replace: bool = true },
    /// Adds an extension store by its index URL, fetching its name and
    /// signing key; a legacy `index.min.json` URL becomes its `repo.json`.
    add_store: []const u8,
    /// Fetches every store's details again, as Mihon's store refresh does.
    refresh_stores,
    /// Writes every downloaded chapter of source titles into a Mihon
    /// downloads folder at `root` (its `downloads` directory), named and
    /// packed as the settings say.
    export_downloads: []const u8,
    /// Takes chapters from a Mihon downloads folder at `root` for library
    /// chapters not yet downloaded, copying them into the library.
    import_downloads: []const u8,
    /// Restores a Mihon backup (`.tachibk`) into the library.
    import_backup: []const u8,
    /// Writes the library as a Mihon backup.
    export_backup: struct { path: []const u8, options: backup.ExportOptions = .{} },

    /// Browser login URL or credential/code/token exchange, or a provider call.
    tracker: struct { id: i32, operation: tracking.Operation },
    /// Match and bind logged-in enhanced trackers accepted by this title's source.
    track_match: struct { manga_id: []const u8 },
    track_bind: struct { manga_id: []const u8, track: library.Track },
    track_unbind: struct { manga_id: []const u8, tracker_id: i32, delete_remote: bool = false },
    track_set: struct { manga_id: []const u8, tracker_id: i32, value: tracking.Setter },
    track_refresh: struct { manga_id: ?[]const u8 = null },
    track_chapter: struct { manga_id: []const u8, chapter: f64 },
    /// Run once while connected; retry_at and attempts persist across restarts.
    track_pending: struct { connected: bool, force: bool = false },

    fn usesBackend(self: Request) bool {
        return switch (self) {
            .tracker, .track_match, .track_bind, .track_unbind, .track_set, .track_refresh, .track_chapter, .track_pending, .delete_download, .remove, .scan_local, .import_backup, .export_backup, .export_downloads, .import_downloads, .add_store, .refresh_stores => false,
            else => true,
        };
    }
};

pub const Result = struct {
    tracking_reply: tracking.Reply = .{},
    tracking_errors: []const TrackingError = &.{},
    sources: []const models.SourceInfo = &.{},
    extensions: []const manage.RepoEntry = &.{},
    extension_updates: ?manage.UpdateResult = null,
    /// Installed extensions no store lists any more.
    obsolete: []const []const u8 = &.{},
    /// An installed file nothing trusts: it was taken out again; see
    /// `Engine.trustExtension`.
    untrusted: ?Untrusted = null,
    page: ?models.MangasPage = null,
    filters: []const models.Filter = &.{},
    mangas: []const models.Manga = &.{},
    preferences: []const models.Preference = &.{},
    /// The library changed; load it again.
    library_changed: bool = false,
    /// The library title the request added or changed.
    manga_id: ?[]const u8 = null,
    /// Chapters new to the reader that an add, refresh or update found.
    new_chapters: []const []const u8 = &.{},
    /// Titles a library update could not refresh, and why.
    update_errors: []const UpdateError = &.{},
    /// Titles a library update skipped by its rules.
    update_skipped: usize = 0,
    /// A `cover` request's image, relative to the library directory.
    cover: ?[]const u8 = null,
    /// A `read` chapter's page paths, relative to the library directory;
    /// empty for a page that failed.
    pages: []const []const u8 = &.{},
    /// A global search's results, in Mihon's order: sources with results
    /// first, then pinned ones, then by name.
    search: []const SearchResult = &.{},
    message: []const u8 = "Ready",
};

pub const TrackingError = struct { manga_id: []const u8, tracker_id: i32, message: []const u8 };

pub const UpdateError = struct { manga_id: []const u8, title: []const u8, message: []const u8 };

pub const Untrusted = struct { pkg: []const u8, version_code: i64, fingerprint: []const u8 };

pub const SearchResult = struct {
    source: models.SourceInfo,
    pinned: bool = false,
    mangas: []const models.Manga = &.{},
    /// Why the source failed; null if it answered.
    failure: ?[]const u8 = null,
};

pub const Phase = enum(u8) {
    /// The operation itself is running.
    operation,
    /// The JVM is starting first.
    starting,
    /// An extension is loading before its first call; see `Job.extensionLoading`.
    extension_loading,
};

pub const Options = struct {
    /// The library directory: `library.json`, `downloads/` and `local/`.
    dir: []const u8,
    /// Maximum independent operations per search, chapter or bulk I/O loop.
    parallelism: usize = parallel.default_limit,
    /// PEM roots for native downloads; null uses the system's.
    ca_file: ?[]const u8 = null,
    /// Let a worker backend exit while a chapter downloads natively, and after.
    release_jvm: bool = true,
    /// Removable storage root; pages use the persistent `sdcard/` namespace.
    sd_dir: ?[]const u8 = null,
    /// Require this mount point to be mounted before accessing removable storage.
    sd_mount: ?[]const u8 = null,
    /// Native tracking adapter; no extension runtime is started by tracking.
    tracker_driver: ?tracking.Driver = null,
    /// The user's offset from UTC in seconds, for "today" in update
    /// schedules and the updates feed.
    utc_offset_s: i32 = 0,
    /// The runtime's data directory, where extensions keep their settings
    /// (`prefs/`); null if it is `dir`.
    host_dir: ?[]const u8 = null,
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    io: Io,
    backend: be.Backend,
    store: library.Store,
    options: Options,
    paused: std.atomic.Value(bool) = .init(false),
    /// Mihon's download queue; see `queue.Queue`.
    queue: queue_mod.Queue = .{},
    /// The network the app last reported; see `setNetwork`.
    network: std.atomic.Value(Network) = .init(.unknown),
    /// The chapter `pageShown` last checked for downloading ahead (a hash;
    /// 32 bits, as 32-bit ARM has no 64-bit atomics).
    ahead_checked: std.atomic.Value(u32) = .init(0),
    pending_lock: Io.Mutex = .init,
    tracking_lock: Io.Mutex = .init,
    tracking_job_lock: Io.Mutex = .init,
    tracking_job: ?*Job = null,
    /// Runs jobs instead of the engine, for tests without a JVM.
    execute_fn: ?*const fn (*Engine, *Job) anyerror!void = null,
    /// The built-in tracking services, used unless `Options.tracker_driver`.
    drivers: track_drivers.Drivers,

    pub fn init(gpa: std.mem.Allocator, io: Io, backend: be.Backend, options: Options) Engine {
        return .{ .gpa = gpa, .io = io, .backend = backend, .store = .{ .io = io, .dir = options.dir, .sd_dir = options.sd_dir }, .options = options, .drivers = .init(gpa, io, options.ca_file, options.host_dir orelse options.dir) };
    }

    /// Frees what the tracking services hold. Stop the queue first
    /// (`queue.deinit`).
    pub fn deinit(self: *Engine) void {
        self.drivers.deinit();
    }

    /// The library, allocated in `arena`.
    pub fn loadLibrary(self: *Engine, arena: std.mem.Allocator) !library.Library {
        return self.store.load(arena);
    }

    /// Absolute path of a page file the library refers to.
    pub fn pagePath(self: *Engine, gpa: std.mem.Allocator, relative: []const u8) ![:0]u8 {
        if (std.mem.startsWith(u8, relative, "sdcard/") and !self.sdAvailable()) return error.StorageUnavailable;
        return self.store.pagePath(gpa, relative);
    }

    /// Whether the configured SD volume is present; never create a missing mount.
    pub fn sdAvailable(self: *Engine) bool {
        const dir = self.options.sd_dir orelse return false;
        if (self.options.sd_mount) |mount| {
            const bytes = Io.Dir.cwd().readFileAlloc(self.io, "/proc/mounts", self.gpa, .limited(1 << 20)) catch return false;
            defer self.gpa.free(bytes);
            var lines = std.mem.tokenizeScalar(u8, bytes, '\n');
            while (lines.next()) |line| {
                var fields = std.mem.tokenizeScalar(u8, line, ' ');
                _ = fields.next() orelse continue;
                if (std.mem.eql(u8, fields.next() orelse continue, mount)) return true;
            }
            return false;
        }
        var parent = Io.Dir.cwd().openDir(self.io, std.fs.path.dirname(dir) orelse return false, .{}) catch return false;
        parent.close(self.io);
        return true;
    }

    /// Saved pages from the current resumable plan, including another destination.
    pub fn downloadProgress(self: *Engine, a: std.mem.Allocator, chapter_id: []const u8) !?downloads.ResumeProgress {
        if (try downloads.resumeProgress(a, self.io, self.options.dir, "downloads", chapter_id)) |p| return p;
        if (self.sdAvailable()) if (try downloads.resumeProgress(a, self.io, self.options.sd_dir.?, "downloads", chapter_id)) |p| return p;
        return null;
    }

    /// Records the page shown in a chapter, marks it read once requested,
    /// and adds `read_ms` of reading time to its history. Cheap enough for
    /// every page turn: only the reading-state file is rewritten.
    pub fn setProgress(self: *Engine, chapter_id: []const u8, page: u32, read: bool, read_ms: i64) !void {
        _ = try self.store.setProgress(self.gpa, &.{.{ .chapter_id = chapter_id, .page = page, .read = read, .now = wallMillis(self.io), .read_ms = read_ms }});
    }

    /// Records several chapters' progress in one write, as for an import.
    pub fn setProgressMany(self: *Engine, progress: []const library.Progress) !void {
        _ = try self.store.setProgress(self.gpa, progress);
    }

    /// Stops extension work and refuses new jobs until `resume`, as for an
    /// app going to the background. Cancel running jobs too.
    pub fn pause(self: *Engine) void {
        self.paused.store(true, .release);
        self.backend.cancel();
        self.backend.release();
    }

    pub fn @"resume"(self: *Engine) void {
        self.paused.store(false, .release);
    }

    pub const Network = enum(u8) { unknown, none, wifi, other };

    /// Tells the engine what network the device is on, so the download
    /// queue keeps to Wi-Fi when the settings ask; unknown doesn't stop it.
    pub fn setNetwork(self: *Engine, network: Network) void {
        self.network.store(network, .release);
    }

    /// Whether downloads may run on the network the app last reported.
    pub fn downloadsAllowed(self: *Engine, s: settings.Settings) bool {
        return switch (self.network.load(.acquire)) {
            .unknown, .wifi => true,
            .none => false,
            .other => !s.downloads.only_wifi,
        };
    }

    /// Call once when the app starts: does what Mihon does at launch,
    /// clearing the chapter cache if the settings say so.
    pub fn launched(self: *Engine) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        if ((try self.loadSettings(arena_state.allocator())).library.auto_clear_chapter_cache) try self.clearChapterCache();
    }

    /// The engine settings (`settings.json` in the library directory).
    pub fn loadSettings(self: *Engine, arena: std.mem.Allocator) !settings.Settings {
        return settings.Settings.load(arena, self.io, self.options.dir);
    }

    pub fn saveSettings(self: *Engine, value: settings.Settings) !void {
        try value.save(self.gpa, self.io, self.options.dir);
    }

    /// No job is running: lets the backend do its upkeep.
    pub fn idle(self: *Engine) void {
        self.backend.idle();
    }

    // ---- views -----------------------------------------------------------------

    /// The library as Mihon shows it, with the settings' filters and sorts,
    /// and only titles matching `search` in Mihon's search syntax (see
    /// `query`) if it isn't empty. Allocated in `arena`.
    pub fn libraryView(self: *Engine, arena: std.mem.Allocator, search: []const u8) ![]views.Group {
        const s = try self.loadSettings(arena);
        const lib = try self.store.load(arena);
        var options = try views.libraryOptions(arena, lib, s, search, self.options.utc_offset_s);
        options.track_score = tracking.scoreView(try self.loadTrackers(arena));
        return views.libraryView(arena, lib, options);
    }

    /// Where extensions keep their settings.
    fn prefsDir(self: *Engine, a: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(a, &.{ self.options.host_dir orelse self.options.dir, "prefs" });
    }

    // ---- extension stores ----------------------------------------------------------

    /// The extension stores, in the order they were added.
    pub fn extensionStores(self: *Engine, arena: std.mem.Allocator) ![]const stores.Store {
        return (try stores.File.load(arena, self.io, self.options.dir)).stores;
    }

    pub fn removeStore(self: *Engine, index_url: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const file = try stores.File.load(a, self.io, self.options.dir);
        try (try file.remove(a, index_url)).save(a, self.io, self.options.dir);
    }

    /// Trusts one version of an extension signed by `fingerprint`, as
    /// Mihon's "trust" does for an untrusted extension; install it again.
    pub fn trustExtension(self: *Engine, untrusted: Untrusted) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const file = try stores.File.load(a, self.io, self.options.dir);
        try (try file.trust(a, untrusted.pkg, untrusted.version_code, untrusted.fingerprint)).save(a, self.io, self.options.dir);
    }

    fn fetchStore(self: *Engine, a: std.mem.Allocator, url: []const u8) !stores.Store {
        var http: repo.Http = .init(self.gpa, self.io);
        defer http.deinit();
        if (self.options.ca_file) |ca| try http.useCaFile(ca);
        return stores.Store.fromIndex(try repo.fetchIndex(&http, a, url), url);
    }

    /// Fetches stores concurrently, logging individual failures;
    /// a store whose URL moved is kept under its new URL.
    fn refreshStores(self: *Engine, job: *Job) !void {
        const a = job.arena.allocator();
        const before = try stores.File.load(a, self.io, self.options.dir);
        const refreshed = try a.alloc(?stores.Store, before.stores.len);
        @memset(refreshed, null);
        const Refresh = struct {
            job: *Job,
            stores_before: []const stores.Store,
            refreshed: []?stores.Store,
            failed: usize = 0,
            fn work(ctx: *@This(), scratch: std.mem.Allocator, i: usize) !?stores.Store {
                const url = ctx.stores_before[i].index_url;
                return ctx.job.engine.fetchStore(scratch, url) catch |err| switch (err) {
                    error.Canceled, error.OutOfMemory => return err,
                    else => {
                        log.warn("store {s} not refreshed: {s}", .{ url, @errorName(err) });
                        return null;
                    },
                };
            }
            fn publish(ctx: *@This(), i: usize, result: ?stores.Store, scratch: *std.heap.ArenaAllocator) !void {
                if (result) |store| {
                    try ctx.job.keepArena(scratch);
                    ctx.refreshed[i] = store;
                } else ctx.failed += 1;
            }
        };
        var refresh: Refresh = .{ .job = job, .stores_before = before.stores, .refreshed = refreshed };
        try parallel.run(self.gpa, self.io, before.stores.len, self.options.parallelism, &refresh, Refresh.work, Refresh.publish);
        // Stores removed meanwhile stay removed.
        var file = try stores.File.load(a, self.io, self.options.dir);
        for (before.stores, refreshed) |previous, result| {
            const store = result orelse continue;
            const present = for (file.stores) |s| {
                if (std.mem.eql(u8, s.index_url, previous.index_url)) break true;
            } else false;
            if (!present) continue;
            file = try file.upsert(a, store);
            if (!std.mem.eql(u8, previous.index_url, store.index_url)) file = try file.remove(a, previous.index_url);
        }
        try file.save(a, self.io, self.options.dir);
        job.result.message = if (refresh.failed == 0) "Stores refreshed" else try std.fmt.allocPrint(a, "Stores refreshed; {d} could not be reached", .{refresh.failed});
    }

    /// One store's listing, or every configured store's merged as Mihon
    /// shows them, filtered by language and content warning unless `all`.
    fn listExtensions(self: *Engine, job: *Job, r: be.Call.Repo) !void {
        const a = job.arena.allocator();
        const file = try stores.File.load(a, self.io, self.options.dir);
        if (r.url != null or file.stores.len == 0) {
            job.result.extensions = (try job.call(.{ .extensions = r })).extensions;
            return;
        }
        const listings = try a.alloc([]const manage.RepoEntry, file.stores.len);
        @memset(listings, &.{});
        const Listing = struct {
            job: *Job,
            configured: []const stores.Store,
            refresh: bool,
            listings: [][]const manage.RepoEntry,
            fn work(ctx: *@This(), scratch: std.mem.Allocator, i: usize) ![]const manage.RepoEntry {
                const url = ctx.configured[i].index_url;
                tachi.setLastError("");
                const reply = ctx.job.engine.backend.run(scratch, .{ .extensions = .{ .url = url, .refresh = ctx.refresh } }, ctx.job.status()) catch |err| switch (err) {
                    error.Canceled, error.OutOfMemory => return err,
                    else => {
                        log.warn("store {s} not listed: {s}", .{ url, @errorName(err) });
                        return &.{};
                    },
                };
                return reply.extensions;
            }
            fn publish(ctx: *@This(), i: usize, entries: []const manage.RepoEntry, scratch: *std.heap.ArenaAllocator) !void {
                try ctx.job.keepArena(scratch);
                ctx.listings[i] = entries;
            }
        };
        var listing: Listing = .{ .job = job, .configured = file.stores, .refresh = r.refresh, .listings = listings };
        try parallel.run(self.gpa, self.io, file.stores.len, self.options.parallelism, &listing, Listing.work, Listing.publish);
        // Completion order must not change store precedence for equal versions.
        const merged = try stores.merge(a, listings);
        var installed: std.ArrayList([]const u8) = .empty;
        for (merged) |e| if (e.installed) try installed.append(a, e.pkg);
        for (try self.installedPackages(a)) |pkg| {
            const known = for (installed.items) |p| {
                if (std.mem.eql(u8, p, pkg)) break true;
            } else false;
            if (!known) try installed.append(a, pkg);
        }
        job.result.obsolete = try stores.obsolete(a, merged, installed.items);
        if (r.all) {
            job.result.extensions = merged;
        } else {
            const s = try self.loadSettings(a);
            job.result.extensions = try stores.filter(a, merged, s.browse.languages, s.browse.content_warnings);
        }
    }

    /// Updates installed extensions from every store (or `r.url`'s).
    fn updateExtensions(self: *Engine, job: *Job, r: be.Call.Repo) !?manage.UpdateResult {
        const a = job.arena.allocator();
        const file = try stores.File.load(a, self.io, self.options.dir);
        if (r.url != null or file.stores.len == 0) return (try job.call(.{ .update_extensions = r })).extension_updates;
        var updated: std.ArrayList(models.ExtensionInfo) = .empty;
        var failed: std.ArrayList(manage.RestoreResult.Failure) = .empty;
        for (file.stores) |s| {
            const result = (try job.call(.{ .update_extensions = .{ .url = s.index_url, .refresh = r.refresh } })).extension_updates orelse continue;
            try updated.appendSlice(a, result.updated);
            try failed.appendSlice(a, result.failed);
        }
        return .{ .updated = updated.items, .failed = failed.items, .missing = &.{} };
    }

    /// Packages the runtime has installed, from its registry.
    fn installedPackages(self: *Engine, a: std.mem.Allocator) ![]const []const u8 {
        const installed = try self.registry(a);
        const out = try a.alloc([]const u8, installed.extensions.len);
        for (installed.extensions, out) |e, *pkg| pkg.* = e.pkg;
        return out;
    }

    fn registry(self: *Engine, a: std.mem.Allocator) !manage.Registry {
        const path = try std.fs.path.join(a, &.{ self.options.host_dir orelse self.options.dir, "extensions", "installed.json" });
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(16 << 20)) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        return std.json.parseFromSliceLeaky(manage.Registry, a, bytes, models.parse_options);
    }

    /// Installed extensions nothing trusts any more (a store removed, or
    /// installed before trust was checked), as Mihon lists untrusted ones.
    pub fn untrustedExtensions(self: *Engine, arena: std.mem.Allocator) ![]const Untrusted {
        const file = try stores.File.load(arena, self.io, self.options.dir);
        var out: std.ArrayList(Untrusted) = .empty;
        for ((try self.registry(arena)).extensions) |e| {
            const fingerprints = repo.signerFingerprints(arena, self.io, e.path) catch continue;
            const trusted = for (fingerprints) |fp| {
                if (file.trusts(e.pkg, e.versionCode, &repo.hex(fp))) break true;
            } else false;
            if (trusted) continue;
            const fingerprint = if (fingerprints.len > 0) try arena.dupe(u8, &repo.hex(fingerprints[fingerprints.len - 1])) else "";
            try out.append(arena, .{ .pkg = e.pkg, .version_code = e.versionCode, .fingerprint = fingerprint });
        }
        return out.items;
    }

    /// Installs a file, then keeps it only if trusted as Mihon trusts
    /// extensions: signed with a store's key, or this version trusted by hand.
    fn installFile(self: *Engine, job: *Job, path: []const u8) !void {
        const a = job.arena.allocator();
        const sources = (try job.call(.{ .install_file = path })).sources;
        const absolute = Io.Dir.cwd().realPathFileAlloc(self.io, path, a) catch path;
        const entry = for ((try self.registry(a)).extensions) |e| {
            if (std.mem.eql(u8, e.path, absolute)) break e;
        } else {
            job.result = .{ .sources = sources, .message = "Extension installed" };
            return;
        };
        const fingerprints = repo.signerFingerprints(a, self.io, absolute) catch &.{};
        const file = try stores.File.load(a, self.io, self.options.dir);
        for (fingerprints) |fp| {
            if (file.trusts(entry.pkg, entry.versionCode, &repo.hex(fp))) {
                job.result = .{ .sources = sources, .message = "Extension installed" };
                return;
            }
        }
        _ = try job.call(.{ .uninstall = entry.pkg });
        const fingerprint = if (fingerprints.len > 0) try a.dupe(u8, &repo.hex(fingerprints[fingerprints.len - 1])) else "";
        job.result.untrusted = .{ .pkg = entry.pkg, .version_code = entry.versionCode, .fingerprint = fingerprint };
        job.failure = if (fingerprint.len == 0)
            try std.fmt.allocPrint(a, "{s} is not signed, so it can't be trusted", .{entry.pkg})
        else
            try std.fmt.allocPrint(a, "{s} {d} is signed by a key no store has: trust it to install", .{ entry.pkg, entry.versionCode });
        return error.UntrustedExtension;
    }

    // ---- covers ------------------------------------------------------------------

    const covers_dir = "covers";

    /// A title's cover on disk, relative to the library directory (see
    /// `pagePath`): its custom cover, a local title's own, else its cached
    /// thumbnail. Null if none is there yet; fetch the thumbnail with a
    /// `cover` request.
    pub fn coverPath(self: *Engine, arena: std.mem.Allocator, manga: library.Manga) !?[]const u8 {
        if (try self.customCover(arena, manga.id)) |path| return path;
        if (manga.cover) |path| return path;
        const remote = manga.remote orelse return null;
        const url = remote.thumbnailUrl orelse return null;
        if (url.len == 0) return null;
        return self.cachedCover(arena, url);
    }

    /// Sets a title's custom cover, as Mihon's "edit cover".
    pub fn setCustomCover(self: *Engine, manga_id: []const u8, image: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const ext = downloads.imageExtension(image) orelse return error.UnsupportedImageFormat;
        try self.removeCustomCover(manga_id);
        const path = try std.fmt.allocPrint(a, "{s}/{s}/custom/{x}.{s}", .{ self.options.dir, covers_dir, std.hash.Wyhash.hash(0, manga_id), ext });
        try Io.Dir.cwd().createDirPath(self.io, std.fs.path.dirname(path).?);
        try library.writeAtomic(a, self.io, path, image);
    }

    pub fn removeCustomCover(self: *Engine, manga_id: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        while (try self.customCover(a, manga_id)) |path| {
            try Io.Dir.cwd().deleteFile(self.io, try std.fs.path.join(a, &.{ self.options.dir, path }));
        }
    }

    fn customCover(self: *Engine, a: std.mem.Allocator, manga_id: []const u8) !?[]const u8 {
        return self.findImage(a, try std.fmt.allocPrint(a, "{s}/custom/{x}", .{ covers_dir, std.hash.Wyhash.hash(0, manga_id) }));
    }

    fn cachedCover(self: *Engine, a: std.mem.Allocator, url: []const u8) !?[]const u8 {
        return self.findImage(a, try std.fmt.allocPrint(a, "{s}/{x}", .{ covers_dir, std.hash.Wyhash.hash(0, url) }));
    }

    /// `stem` plus whichever image extension exists, relative to the library directory.
    fn findImage(self: *Engine, a: std.mem.Allocator, stem: []const u8) !?[]const u8 {
        for (downloads.image_extensions) |ext| {
            const path = try std.fmt.allocPrint(a, "{s}.{s}", .{ stem, ext });
            Io.Dir.cwd().access(self.io, try std.fs.path.join(a, &.{ self.options.dir, path }), .{}) catch continue;
            return path;
        }
        return null;
    }

    // ---- chapter cache -------------------------------------------------------------

    /// Bytes the chapter cache (pages read online) holds.
    pub fn chapterCacheBytes(self: *Engine) !u64 {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        var total: u64 = 0;
        for (try self.cachedChapters(arena_state.allocator())) |c| total += c.bytes;
        return total;
    }

    /// Empties the chapter cache, as Mihon's "clear chapter cache" (and its
    /// `auto_clear_chapter_cache` at launch).
    pub fn clearChapterCache(self: *Engine) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        try Io.Dir.cwd().deleteTree(self.io, try std.fs.path.join(a, &.{ self.options.dir, cache_root }));
    }

    const cache_root = "cache/chapters";
    const cache_pages = cache_root ++ "/pages";
    /// Mihon's chapter cache size.
    pub const chapter_cache_limit = 100 << 20;

    const CachedChapter = struct { path: []const u8, bytes: u64, newest: i96 };

    fn cachedChapters(self: *Engine, a: std.mem.Allocator) ![]CachedChapter {
        const root = try std.fs.path.join(a, &.{ self.options.dir, cache_pages });
        var dir = Io.Dir.cwd().openDir(self.io, root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        defer dir.close(self.io);
        var list: std.ArrayList(CachedChapter) = .empty;
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            const top = entry.path[0 .. std.mem.indexOfScalar(u8, entry.path, std.fs.path.sep) orelse continue];
            const st = try entry.dir.statFile(self.io, entry.basename, .{});
            const chapter = for (list.items) |*c| {
                if (std.mem.eql(u8, std.fs.path.basename(c.path), top)) break c;
            } else blk: {
                try list.append(a, .{ .path = try std.fs.path.join(a, &.{ root, top }), .bytes = 0, .newest = 0 });
                break :blk &list.items[list.items.len - 1];
            };
            chapter.bytes += st.size;
            chapter.newest = @max(chapter.newest, st.mtime.nanoseconds);
        }
        return list.items;
    }

    /// Deletes the least recently written chapters until the cache fits,
    /// never `keep` (a chapter id being read).
    fn trimChapterCache(self: *Engine, a: std.mem.Allocator, keep: []const u8) !void {
        const chapters = try self.cachedChapters(a);
        var total: u64 = 0;
        for (chapters) |c| total += c.bytes;
        if (total <= chapter_cache_limit) return;
        std.mem.sort(CachedChapter, chapters, {}, struct {
            fn less(_: void, x: CachedChapter, y: CachedChapter) bool {
                return x.newest < y.newest;
            }
        }.less);
        const kept = try std.fmt.allocPrint(a, "{x}", .{std.hash.Wyhash.hash(0, keep)});
        for (chapters) |c| {
            if (total <= chapter_cache_limit) break;
            if (std.mem.eql(u8, std.fs.path.basename(c.path), kept)) continue;
            Io.Dir.cwd().deleteTree(self.io, c.path) catch continue;
            total -= c.bytes;
        }
    }

    fn pageParallelism(self: *Engine, a: std.mem.Allocator) !usize {
        const s = try self.loadSettings(a);
        return @min(@max(1, self.options.parallelism), @max(1, s.downloads.parallel_pages));
    }

    fn readChapter(self: *Engine, job: *Job, chapter_id: []const u8, start: u32) !void {
        const a = job.arena.allocator();
        const current = try self.store.load(a);
        const found = findChapter(current, chapter_id) orelse return error.UnknownChapter;
        if (found.manga.local() or found.chapter.downloaded()) {
            job.setPages(found.chapter.pages.len);
            for (found.chapter.pages, 0..) |path, i| job.pageReady(i, path);
            job.result = .{ .manga_id = found.manga.id, .pages = found.chapter.pages, .message = "Chapter ready" };
            return;
        }
        const source = found.manga.source_id orelse return error.LocalChapter;
        const remote = found.chapter.remote orelse return error.MissingChapterMetadata;
        job.fallback_source = source;
        // Mihon keeps a chapter's page list in its cache.
        const plan_path = try std.fmt.allocPrint(a, "{s}/{s}/plans/{x}.json", .{ self.options.dir, cache_root, std.hash.Wyhash.hash(0, chapter_id) });
        const plan: []const models.ImageRequest = if (Io.Dir.cwd().readFileAlloc(self.io, plan_path, a, .limited(16 << 20))) |bytes|
            try std.json.parseFromSliceLeaky([]const models.ImageRequest, a, bytes, models.parse_options)
        else |_| blk: {
            const fetched = (try job.call(.{ .image_requests = .{ .source = source, .chapter = remote } })).image_requests;
            Io.Dir.cwd().createDirPath(self.io, std.fs.path.dirname(plan_path).?) catch {};
            library.writeJsonAtomic(a, self.io, plan_path, fetched) catch |err| log.warn("page list not cached: {s}", .{@errorName(err)});
            break :blk fetched;
        };
        if (plan.len == 0) return error.EmptyChapter;
        const Count = struct {
            chapter_id: []const u8,
            count: u32,
            changed: *bool,
            fn apply(value: @This(), arena: std.mem.Allocator, lib: library.Library) !?library.Library {
                const next = try library.setPageCount(arena, lib, value.chapter_id, value.count);
                value.changed.* = next != null;
                return next;
            }
        };
        var count_changed = false;
        _ = try self.store.update(a, Count{ .chapter_id = chapter_id, .count = @intCast(plan.len), .changed = &count_changed }, Count.apply);
        job.result.library_changed = count_changed;
        job.setPages(plan.len);
        const chapter = try downloads.downloadChapter(self.gpa, a, self.io, plan, .{
            .dir = self.options.dir,
            .chapter_id = chapter_id,
            .ca_file = self.options.ca_file,
            .parallelism = try self.pageParallelism(a),
            .fallback = .{ .context = job, .fetch = Job.fetchFallback },
            .progress = .{ .context = job, .report = Job.reportPages, .page = Job.reportReady, .failed = Job.reportFailed },
            .root = cache_pages,
            .order = try downloads.readingOrder(a, plan.len, start),
            // Mihon's reader has no retry loop; a failed page is retried by hand.
            .retry_ms = &.{},
            .keep_going = true,
        });
        self.trimChapterCache(a, chapter_id) catch |err| log.warn("chapter cache not trimmed: {s}", .{@errorName(err)});
        job.result = .{ .library_changed = count_changed, .manga_id = found.manga.id, .pages = chapter.pages, .message = "Chapter ready" };
    }

    /// A title's chapters as its chapter list flags show them.
    pub fn chapterList(self: *Engine, arena: std.mem.Allocator, manga_id: []const u8) ![]library.Chapter {
        const s = try self.loadSettings(arena);
        const lib = try self.store.load(arena);
        return views.chapterList(arena, lib.manga[lib.find(manga_id) orelse return error.UnknownManga], s.library.downloaded_only);
    }

    /// The chapters the reader moves through from `chapter_id`.
    pub fn readerChapters(self: *Engine, arena: std.mem.Allocator, chapter_id: []const u8) !views.ReaderChapters {
        const s = try self.loadSettings(arena);
        const found = findChapter(try self.store.load(arena), chapter_id) orelse return error.UnknownChapter;
        return (try views.readerChapters(arena, found.manga, chapter_id, s.reader, s.library.downloaded_only)).?;
    }

    /// Mihon's updates feed with the settings' filters.
    pub fn updatesFeed(self: *Engine, arena: std.mem.Allocator) ![]views.FeedItem {
        const s = try self.loadSettings(arena);
        const u = s.updates;
        return views.updates(arena, try self.store.load(arena), .{
            .downloaded = u.downloaded,
            .unread = u.unread,
            .started = u.started,
            .bookmarked = u.bookmarked,
            .hide_excluded_scanlators = u.hide_excluded_scanlators,
            .categories = u.categories,
            .exclude_categories = u.exclude_categories,
            .downloaded_only = s.library.downloaded_only,
            .now = wallMillis(self.io),
            .utc_offset_s = self.options.utc_offset_s,
        });
    }

    /// New chapters library updates found since the updates feed was last
    /// seen (Mihon's badge count).
    pub fn unseenUpdates(self: *Engine) !u32 {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        return (try self.loadSettings(arena_state.allocator())).updates.unseen;
    }

    /// Clears `unseenUpdates`, as opening Mihon's updates screen does.
    pub fn markUpdatesSeen(self: *Engine) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        var s = try self.loadSettings(arena_state.allocator());
        if (s.updates.unseen == 0) return;
        s.updates.unseen = 0;
        try self.saveSettings(s);
    }

    /// Other library titles Mihon would warn are the same as `manga`.
    pub fn duplicates(self: *Engine, arena: std.mem.Allocator, manga: library.Manga) ![]*const library.Manga {
        return views.duplicates(arena, try self.store.load(arena), manga);
    }

    pub const Device = struct { wifi: bool, unmetered: bool, charging: bool };

    /// Whether an automatic library update is due now on a device in this
    /// state, as Mihon's periodic update decides; start one with
    /// `update_library` if so.
    pub fn libraryUpdateDue(self: *Engine, device: Device) !bool {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const u = (try self.loadSettings(arena_state.allocator())).update;
        if (u.interval_hours == 0) return false;
        if ((u.only_wifi and !device.wifi) or (u.only_unmetered and !device.unmetered) or (u.only_charging and !device.charging)) return false;
        return wallMillis(self.io) - u.last_run >= @as(i64, u.interval_hours) * std.time.ms_per_hour;
    }

    /// Each title's latest read chapter, latest first.
    pub fn history(self: *Engine, arena: std.mem.Allocator, search: []const u8) ![]views.FeedItem {
        return views.history(arena, try self.store.load(arena), search);
    }

    /// Library titles expected to update today or later.
    pub fn upcoming(self: *Engine, arena: std.mem.Allocator) ![]*const library.Manga {
        const s = try self.loadSettings(arena);
        return views.upcoming(arena, try self.store.load(arena), s.updates.upcoming_categories, s.updates.upcoming_exclude_categories, wallMillis(self.io), self.options.utc_offset_s);
    }

    pub fn stats(self: *Engine, arena: std.mem.Allocator) !views.Stats {
        const s = try self.loadSettings(arena);
        return views.stats(try self.store.load(arena), s.update, tracking.scoreView(try self.loadTrackers(arena)));
    }

    // ---- reading ---------------------------------------------------------------

    pub const PageShown = struct {
        chapter_id: []const u8,
        /// Zero-based page now shown.
        page: u32,
        /// Pages in the chapter.
        pages: u32,
        /// Reading time since the last call, in milliseconds, for history.
        read_ms: i64 = 0,
        /// Whether the reader reached the chapter's final edge. Region-based
        /// readers can show only part of the last image; null keeps the
        /// page-based completion rule for existing callers.
        completed: ?bool = null,
    };

    /// The reader's hook for each page shown, doing what Mihon's reader
    /// does: records the page, and on the last one marks the chapter read,
    /// queues the download `remove_after_read_slots` chapters behind for
    /// deletion and marks same-numbered chapters read if the settings say
    /// so. Past a quarter of a downloaded chapter whose next chapter is
    /// downloaded, it queues the next unread ones (`Settings.downloads.ahead`).
    /// Records nothing in incognito. Call `leaveReader` when the reader closes.
    pub fn pageShown(self: *Engine, shown: PageShown) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const s = try self.loadSettings(a);
        if (s.reader.incognito) return;
        if (s.reader.incognito_extensions.len > 0 and try self.incognitoSource(a, s, shown.chapter_id)) return;
        const last = shown.completed orelse (shown.pages > 0 and shown.page + 1 >= shown.pages);
        const newly_read = try self.store.setProgress(self.gpa, &.{.{ .chapter_id = shown.chapter_id, .page = shown.page, .read = last, .now = wallMillis(self.io), .read_ms = shown.read_ms }}) > 0;
        const hash: u32 = @truncate(std.hash.Wyhash.hash(0, shown.chapter_id));
        const ahead = s.downloads.ahead > 0 and @as(u64, shown.page + 1) * 4 > shown.pages and self.ahead_checked.load(.acquire) != hash;
        if (!newly_read and !ahead) return;
        const lib = try self.store.load(a);
        const found = findChapter(lib, shown.chapter_id) orelse return;
        if (newly_read) {
            try self.chapterFinished(a, s, found);
            if (s.tracking.auto_update and found.chapter.recognized()) {
                if (try self.queueTracking(found.manga.id, found.chapter.number)) try self.startTracking();
            }
        }
        if (ahead) try self.downloadAhead(a, s, found, hash);
    }

    /// Whether the chapter's source comes from an extension read in
    /// incognito (Mihon's `incognito_extensions`).
    fn incognitoSource(self: *Engine, a: std.mem.Allocator, s: settings.Settings, chapter_id: []const u8) !bool {
        const lib = try self.store.load(a);
        const found = findChapter(lib, chapter_id) orelse return false;
        const id = found.manga.source_id orelse return false;
        for (lib.sources) |source| if (source.id == id) {
            for (s.reader.incognito_extensions) |pkg| if (std.mem.eql(u8, pkg, source.pkg)) return true;
        };
        return false;
    }

    /// Deletes the downloads finished chapters queued for deletion, as
    /// Mihon does when the reader closes.
    pub fn leaveReader(self: *Engine) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        self.pending_lock.lockUncancelable(self.io);
        defer self.pending_lock.unlock(self.io);
        const pending = try self.loadPending(a);
        if (pending.len == 0) return;
        _ = try self.removeDownloads(a, pending);
        try self.savePending(a, &.{});
    }

    fn chapterFinished(self: *Engine, a: std.mem.Allocator, s: settings.Settings, found: Found) !void {
        const manga = found.manga;
        if (s.downloads.remove_after_read_slots >= 0) if (try views.readerChapters(a, manga, found.chapter.id, s.reader, s.library.downloaded_only)) |list| {
            const slots: usize = @intCast(s.downloads.remove_after_read_slots);
            if (list.current >= slots and list.chapters[list.current - slots].read) {
                const target = list.chapters[list.current - slots];
                var doomed: std.ArrayList(library.Chapter) = .empty;
                try doomed.append(a, target);
                // Mihon deletes duplicates of the number too, as read.
                if (s.update.mark_existing_duplicates_read) for (manga.chapters) |ch| {
                    if (std.mem.eql(u8, ch.id, target.id) or !ch.recognized() or ch.number != target.number) continue;
                    var copy = ch;
                    copy.read = true;
                    try doomed.append(a, copy);
                };
                const ids = try deletable(a, s, manga, doomed.items);
                self.pending_lock.lockUncancelable(self.io);
                defer self.pending_lock.unlock(self.io);
                var pending: std.ArrayList([]const u8) = .empty;
                try pending.appendSlice(a, try self.loadPending(a));
                for (ids) |id| {
                    const known = for (pending.items) |p| {
                        if (std.mem.eql(u8, p, id)) break true;
                    } else false;
                    if (!known) try pending.append(a, id);
                }
                try self.savePending(a, pending.items);
            }
        };
        if (s.update.mark_existing_duplicates_read and found.chapter.recognized()) {
            var states: std.ArrayList(library.Reading) = .empty;
            for (manga.chapters) |ch| if (!ch.read and ch.recognized() and ch.number == found.chapter.number) {
                var state = readingOf(ch);
                state.read = true;
                try states.append(a, state);
            };
            try self.store.putReading(self.gpa, states.items);
        }
    }

    fn downloadAhead(self: *Engine, a: std.mem.Allocator, s: settings.Settings, found: Found, hash: u32) !void {
        const manga = found.manga;
        if (manga.local() or !found.chapter.downloaded()) return self.ahead_checked.store(hash, .release);
        const list = (try views.readerChapters(a, manga, found.chapter.id, s.reader, s.library.downloaded_only)).?;
        const next = list.next() orelse return self.ahead_checked.store(hash, .release);
        // Checked again on later pages, in case it finishes downloading.
        if (!next.downloaded()) return;
        self.ahead_checked.store(hash, .release);
        var chapters = try views.nextUnread(a, manga, next.id);
        if (s.reader.skip_duplicates) chapters = try views.removeDuplicates(a, chapters, next);
        const take = chapters[0..@min(chapters.len, s.downloads.ahead)];
        const ids = try a.alloc([]const u8, take.len);
        for (take, ids) |ch, *id| id.* = ch.id;
        if (ids.len > 0) _ = try self.queue.enqueue(self, ids, true);
    }

    const Pending = struct { chapters: []const []const u8 = &.{} };

    fn pendingPath(self: *Engine, a: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(a, &.{ self.options.dir, "downloads", "pending_delete.json" });
    }

    /// The caller holds `pending_lock`.
    fn loadPending(self: *Engine, a: std.mem.Allocator) ![]const []const u8 {
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, try self.pendingPath(a), a, .limited(4 << 20)) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        return (try std.json.parseFromSliceLeaky(Pending, a, bytes, models.parse_options)).chapters;
    }

    fn savePending(self: *Engine, a: std.mem.Allocator, ids: []const []const u8) !void {
        const path = try self.pendingPath(a);
        try Io.Dir.cwd().createDirPath(self.io, std.fs.path.dirname(path).?);
        try library.writeJsonAtomic(a, self.io, path, Pending{ .chapters = ids });
    }

    // ---- chapter actions ---------------------------------------------------------

    /// Marks chapters read or unread as Mihon does: marking read changes
    /// only unread chapters, marking unread also clears partly read ones'
    /// page. Marked read, their downloads are deleted if
    /// `remove_after_marked_read` is set, within the deletion protections.
    /// Returns how many chapters changed.
    pub fn markRead(self: *Engine, chapter_ids: []const []const u8, read: bool) !usize {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const s = try self.loadSettings(a);
        const lib = try self.store.load(a);
        var states: std.ArrayList(library.Reading) = .empty;
        var doomed: std.ArrayList([]const u8) = .empty;
        for (lib.manga) |m| {
            var changed: std.ArrayList(library.Chapter) = .empty;
            for (m.chapters) |ch| {
                if (!contains(chapter_ids, ch.id)) continue;
                if (if (read) ch.read else !ch.read and ch.last_page_read == 0) continue;
                var state = readingOf(ch);
                state.read = read;
                if (!read) state.page = 0;
                try states.append(a, state);
                var copy = ch;
                copy.read = read;
                try changed.append(a, copy);
            }
            if (read and s.downloads.remove_after_marked_read and !m.local()) try doomed.appendSlice(a, try deletable(a, s, m, changed.items));
        }
        try self.store.putReading(self.gpa, states.items);
        if (doomed.items.len > 0) _ = try self.removeDownloads(a, doomed.items);
        return states.items.len;
    }

    /// Marks every chapter of a title read or unread.
    pub fn markTitleRead(self: *Engine, manga_id: []const u8, read: bool) !usize {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const lib = try self.store.load(a);
        const m = lib.manga[lib.find(manga_id) orelse return error.UnknownManga];
        const ids = try a.alloc([]const u8, m.chapters.len);
        for (m.chapters, ids) |ch, *id| id.* = ch.id;
        return self.markRead(ids, read);
    }

    /// Marks read the chapters before `chapter_id` as the chapter list shows them.
    pub fn markPreviousRead(self: *Engine, chapter_id: []const u8) !usize {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const s = try self.loadSettings(a);
        const found = findChapter(try self.store.load(a), chapter_id) orelse return error.UnknownChapter;
        return self.markRead(try views.previousChapters(a, found.manga, chapter_id, s.library.downloaded_only), true);
    }

    pub fn setBookmark(self: *Engine, chapter_ids: []const []const u8, bookmark: bool) !usize {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const lib = try self.store.load(a);
        var states: std.ArrayList(library.Reading) = .empty;
        for (lib.manga) |m| for (m.chapters) |ch| {
            if (!contains(chapter_ids, ch.id) or ch.bookmark == bookmark) continue;
            var state = readingOf(ch);
            state.bookmark = bookmark;
            try states.append(a, state);
        };
        try self.store.putReading(self.gpa, states.items);
        return states.items.len;
    }

    pub const HistoryScope = union(enum) {
        chapter: []const u8,
        manga: []const u8,
        /// Clears all reading time too, as Mihon's "remove all" does.
        all,
    };

    /// Removes chapters from the history. A chapter or title keeps its
    /// reading time; clearing all forgets it.
    pub fn removeHistory(self: *Engine, scope: HistoryScope) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const lib = try self.store.load(a);
        var states: std.ArrayList(library.Reading) = .empty;
        for (lib.manga) |m| for (m.chapters) |ch| {
            const in_scope = switch (scope) {
                .chapter => |id| std.mem.eql(u8, ch.id, id),
                .manga => |id| std.mem.eql(u8, m.id, id),
                .all => true,
            };
            if (!in_scope or (ch.last_read == 0 and (scope != .all or ch.read_ms == 0))) continue;
            var state = readingOf(ch);
            state.last_read = 0;
            if (scope == .all) state.read_ms = 0;
            try states.append(a, state);
        };
        try self.store.putReading(self.gpa, states.items);
    }

    /// Deletes chapters' downloads, except those Mihon's deletion settings
    /// protect: bookmarked ones unless `remove_bookmarked`, and read ones of
    /// titles in `remove_exclude_categories`. Returns how many were deleted.
    pub fn deleteDownloads(self: *Engine, chapter_ids: []const []const u8) !usize {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const s = try self.loadSettings(a);
        const lib = try self.store.load(a);
        var doomed: std.ArrayList([]const u8) = .empty;
        for (lib.manga) |m| {
            if (m.local()) continue;
            var chapters: std.ArrayList(library.Chapter) = .empty;
            for (m.chapters) |ch| if (contains(chapter_ids, ch.id)) try chapters.append(a, ch);
            try doomed.appendSlice(a, try deletable(a, s, m, chapters.items));
        }
        return self.removeDownloads(a, doomed.items);
    }

    /// Takes chapters out of the download queue and deletes their files.
    fn removeDownloads(self: *Engine, a: std.mem.Allocator, chapter_ids: []const []const u8) !usize {
        const initial = try self.store.load(a);
        var partial: usize = 0;
        for (chapter_ids) |id| {
            const found = findChapter(initial, id) orelse continue;
            if (found.manga.local()) continue;
            if (try self.savedDownloadDestination(a, id)) |destination| {
                if (destination.sd_card and !self.sdAvailable()) return error.StorageUnavailable;
            }
            if (!found.chapter.downloaded() and try self.downloadProgress(a, id) != null) partial += 1;
        }
        if (!self.sdAvailable()) {
            const lib = initial;
            for (lib.manga) |m| for (m.chapters) |ch| {
                if (!contains(chapter_ids, ch.id)) continue;
                for (ch.pages) |page| if (std.mem.startsWith(u8, page, "sdcard/")) return error.StorageUnavailable;
            };
        }
        for (chapter_ids) |id| try self.queue.remove(self, id);
        const Edit = struct {
            ids: []const []const u8,
            pages: *std.ArrayList([]const u8),
            deleted: *usize,
            fn apply(edit: @This(), arena: std.mem.Allocator, current: library.Library) !?library.Library {
                var next = current;
                for (edit.ids) |id| {
                    const found = findChapter(next, id) orelse continue;
                    if (found.manga.local() or !found.chapter.downloaded()) continue;
                    try edit.pages.appendSlice(arena, found.chapter.pages);
                    next = (try library.setPages(arena, next, id, &.{})).?;
                    edit.deleted.* += 1;
                }
                return if (edit.deleted.* > 0) next else null;
            }
        };
        var pages: std.ArrayList([]const u8) = .empty;
        var deleted: usize = 0;
        _ = try self.store.update(a, Edit{ .ids = chapter_ids, .pages = &pages, .deleted = &deleted }, Edit.apply);
        var last_dir: ?[]const u8 = null;
        for (pages.items) |page| {
            // A page inside an archive goes with the archive.
            const file = page[0 .. std.mem.indexOfScalar(u8, page, '#') orelse page.len];
            if (!library.safePath(file)) continue;
            if (std.mem.startsWith(u8, file, "sdcard/") and !self.sdAvailable()) return error.StorageUnavailable;
            const path = try self.store.pagePath(a, file);
            Io.Dir.cwd().deleteFile(self.io, path) catch {};
            const dir = std.fs.path.dirname(path) orelse continue;
            if (last_dir == null or !std.mem.eql(u8, last_dir.?, dir)) {
                if (last_dir) |d| self.removeEmptyDirs(d);
                last_dir = dir;
            }
        }
        if (last_dir) |d| self.removeEmptyDirs(d);
        for (chapter_ids) |id| {
            const found = findChapter(initial, id) orelse continue;
            if (found.manga.local()) continue;
            const folder = try std.fmt.allocPrint(a, "downloads/{x}", .{std.hash.Wyhash.hash(0, id)});
            // Partial pages have not reached the library yet; delete their plans too.
            try Io.Dir.cwd().deleteTree(self.io, try std.fs.path.join(a, &.{ self.options.dir, folder }));
            if (self.sdAvailable()) try Io.Dir.cwd().deleteTree(self.io, try std.fs.path.join(a, &.{ self.options.sd_dir.?, folder }));
        }
        return deleted + partial;
    }

    /// Removes `dir` and its parent if they are empty, stopping at `downloads`.
    fn removeEmptyDirs(self: *Engine, dir: []const u8) void {
        Io.Dir.cwd().deleteDir(self.io, dir) catch return;
        const parent = std.fs.path.dirname(dir) orelse return;
        if (std.mem.eql(u8, std.fs.path.basename(parent), "downloads")) return;
        Io.Dir.cwd().deleteDir(self.io, parent) catch {};
    }

    // ---- titles -----------------------------------------------------------------

    /// Adds a title to the library or takes it out, keeping its chapters and
    /// history either way. Added, it gets the date and, if it has none, the
    /// default category.
    pub fn setFavorite(self: *Engine, manga_id: []const u8, favorite: bool) !void {
        const Edit = struct {
            favorite: bool,
            now: i64,
            default_category: ?u32,
            fn apply(edit: @This(), arena: std.mem.Allocator, m: *library.Manga) !bool {
                if (m.favorite == edit.favorite) return false;
                m.favorite = edit.favorite;
                m.date_added = if (edit.favorite) edit.now else 0;
                if (edit.favorite) {
                    if (m.categories.len == 0) if (edit.default_category) |c| {
                        m.categories = try arena.dupe(u32, &.{c});
                    };
                }
                return true;
            }
        };
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const s = try self.loadSettings(arena_state.allocator());
        try self.editTitle(arena_state.allocator(), manga_id, Edit{ .favorite = favorite, .now = wallMillis(self.io), .default_category = s.library.default_category }, Edit.apply);
    }

    pub fn setNotes(self: *Engine, manga_id: []const u8, notes: []const u8) !void {
        try self.setField(manga_id, "notes", notes);
    }

    /// Hides chapters from these scanlation groups and skips them in updates.
    pub fn setExcludedScanlators(self: *Engine, manga_id: []const u8, groups: []const []const u8) !void {
        try self.setField(manga_id, "excluded_scanlators", groups);
    }

    /// Sets a title's chapter list bits; see `views.ChapterFlags`.
    pub fn setChapterFlags(self: *Engine, manga_id: []const u8, flags: u32) !void {
        try self.setField(manga_id, "chapter_flags", flags);
    }

    /// Sets a title's reader bits: reading mode in 0x7, orientation in 0x38.
    pub fn setReaderFlags(self: *Engine, manga_id: []const u8, flags: u32) !void {
        try self.setField(manga_id, "reader_flags", flags);
    }

    /// Sets how many days a title waits between updates, as Mihon's custom
    /// interval; 0 goes back to estimating it from releases. Reschedules now.
    pub fn setFetchInterval(self: *Engine, manga_id: []const u8, days: u31) !void {
        const Edit = struct {
            interval: i32,
            now: i64,
            utc_offset_s: i32,
            fn apply(edit: @This(), arena: std.mem.Allocator, m: *library.Manga) !bool {
                const next = try fetch_interval.update(arena, .{
                    .chapters = try scheduleDates(arena, m.*),
                    .fetch_interval = edit.interval,
                    .next_update_ms = m.next_update,
                    .last_update_ms = m.last_update,
                    .now_ms = edit.now,
                    .utc_offset_s = edit.utc_offset_s,
                });
                m.fetch_interval = next.fetch_interval;
                m.next_update = next.next_update_ms;
                return true;
            }
        };
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        try self.editTitle(arena_state.allocator(), manga_id, Edit{ .interval = -@as(i32, days), .now = wallMillis(self.io), .utc_offset_s = self.options.utc_offset_s }, Edit.apply);
    }

    /// Makes a title's chapter list flags the default for new titles, and
    /// with `apply_to_library` for every library title too.
    pub fn setDefaultChapterFlags(self: *Engine, flags: u32, apply_to_library: bool) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var s = try self.loadSettings(a);
        s.library.default_chapter_flags = flags;
        try self.saveSettings(s);
        if (!apply_to_library) return;
        const Edit = struct {
            flags: u32,
            fn apply(edit: @This(), arena: std.mem.Allocator, current: library.Library) !?library.Library {
                const titles = try arena.dupe(library.Manga, current.manga);
                for (titles) |*m| if (m.favorite) {
                    m.chapter_flags = edit.flags;
                };
                var next = current;
                next.manga = titles;
                return next;
            }
        };
        _ = try self.store.update(a, Edit{ .flags = flags }, Edit.apply);
    }

    /// Mihon's "clear database": forgets titles not in the library, those
    /// with read chapters too unless `keep_read`. Their downloads stay.
    pub fn clearDatabase(self: *Engine, keep_read: bool) !usize {
        const Edit = struct {
            keep_read: bool,
            removed: *usize,
            fn apply(edit: @This(), arena: std.mem.Allocator, current: library.Library) !?library.Library {
                var kept: std.ArrayList(library.Manga) = .empty;
                for (current.manga) |m| {
                    if (!m.favorite and !(edit.keep_read and m.counts().read > 0)) continue;
                    try kept.append(arena, m);
                }
                edit.removed.* = current.manga.len - kept.items.len;
                if (edit.removed.* == 0) return null;
                var next = current;
                next.manga = kept.items;
                return next;
            }
        };
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        var removed: usize = 0;
        _ = try self.store.update(arena_state.allocator(), Edit{ .keep_read = keep_read, .removed = &removed }, Edit.apply);
        return removed;
    }

    fn setField(self: *Engine, manga_id: []const u8, comptime field: []const u8, value: anytype) !void {
        const Edit = struct {
            value: @TypeOf(value),
            fn apply(edit: @This(), _: std.mem.Allocator, m: *library.Manga) !bool {
                @field(m, field) = edit.value;
                return true;
            }
        };
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        try self.editTitle(arena_state.allocator(), manga_id, Edit{ .value = value }, Edit.apply);
    }

    fn editTitle(self: *Engine, a: std.mem.Allocator, manga_id: []const u8, context: anytype, comptime edit: fn (@TypeOf(context), std.mem.Allocator, *library.Manga) anyerror!bool) !void {
        const Edit = struct {
            id: []const u8,
            context: @TypeOf(context),
            found: *bool,
            fn apply(e: @This(), arena: std.mem.Allocator, current: library.Library) !?library.Library {
                e.found.* = current.find(e.id) != null;
                return library.editManga(arena, current, e.id, e.context, edit);
            }
        };
        var found = false;
        _ = try self.store.update(a, Edit{ .id = manga_id, .context = context, .found = &found }, Edit.apply);
        if (!found) return error.UnknownManga;
    }

    // ---- categories ---------------------------------------------------------------

    /// Adds a category after the others, sorted as the library sort says.
    pub fn createCategory(self: *Engine, name: []const u8) !u32 {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const s = try self.loadSettings(a);
        const Edit = struct {
            name: []const u8,
            flags: u32,
            id: *u32,
            fn apply(edit: @This(), arena: std.mem.Allocator, current: library.Library) !?library.Library {
                if (edit.name.len == 0) return error.InvalidCategoryName;
                var max_id: u32 = 0;
                var next_order: u32 = 0;
                for (current.categories) |c| {
                    if (std.mem.eql(u8, c.name, edit.name)) return error.DuplicateCategory;
                    max_id = @max(max_id, c.id);
                    next_order = @max(next_order, c.order + 1);
                }
                edit.id.* = max_id + 1;
                const categories = try arena.alloc(library.Category, current.categories.len + 1);
                @memcpy(categories[0..current.categories.len], current.categories);
                categories[current.categories.len] = .{ .id = max_id + 1, .name = edit.name, .order = next_order, .flags = edit.flags };
                var next = current;
                next.categories = categories;
                return next;
            }
        };
        var id: u32 = 0;
        _ = try self.store.update(a, Edit{ .name = name, .flags = s.library.sort, .id = &id }, Edit.apply);
        return id;
    }

    pub fn renameCategory(self: *Engine, id: u32, name: []const u8) !void {
        const Edit = struct {
            id: u32,
            name: []const u8,
            fn apply(edit: @This(), arena: std.mem.Allocator, current: library.Library) !?library.Library {
                if (edit.name.len == 0) return error.InvalidCategoryName;
                const categories = try arena.dupe(library.Category, current.categories);
                var found = false;
                for (categories) |*c| {
                    if (c.id == edit.id) {
                        c.name = edit.name;
                        found = true;
                    } else if (std.mem.eql(u8, c.name, edit.name)) return error.DuplicateCategory;
                }
                if (!found) return error.UnknownCategory;
                var next = current;
                next.categories = categories;
                return next;
            }
        };
        try self.editLibrary(Edit{ .id = id, .name = name }, Edit.apply);
    }

    /// Deletes a category; its titles leave it, and those in no other go to
    /// the default category.
    pub fn deleteCategory(self: *Engine, id: u32) !void {
        const Edit = struct {
            id: u32,
            fn apply(edit: @This(), arena: std.mem.Allocator, current: library.Library) !?library.Library {
                var kept: std.ArrayList(library.Category) = .empty;
                for (current.categories) |c| if (c.id != edit.id) try kept.append(arena, c);
                if (kept.items.len == current.categories.len) return error.UnknownCategory;
                sortByOrder(kept.items);
                for (kept.items, 0..) |*c, i| c.order = @intCast(i);
                const titles = try arena.dupe(library.Manga, current.manga);
                for (titles) |*m| {
                    if (std.mem.indexOfScalar(u32, m.categories, edit.id) == null) continue;
                    var own: std.ArrayList(u32) = .empty;
                    for (m.categories) |c| if (c != edit.id) try own.append(arena, c);
                    m.categories = own.items;
                }
                var next = current;
                next.categories = kept.items;
                next.manga = titles;
                return next;
            }
        };
        try self.editLibrary(Edit{ .id = id }, Edit.apply);
    }

    /// Moves a category to position `to` among the categories.
    pub fn moveCategory(self: *Engine, id: u32, to: usize) !void {
        const Edit = struct {
            id: u32,
            to: usize,
            fn apply(edit: @This(), arena: std.mem.Allocator, current: library.Library) !?library.Library {
                var list: std.ArrayList(library.Category) = .empty;
                try list.appendSlice(arena, current.categories);
                sortByOrder(list.items);
                const from = for (list.items, 0..) |c, i| {
                    if (c.id == edit.id) break i;
                } else return error.UnknownCategory;
                const moved = list.orderedRemove(from);
                try list.insert(arena, @min(edit.to, list.items.len), moved);
                for (list.items, 0..) |*c, i| c.order = @intCast(i);
                var next = current;
                next.categories = list.items;
                return next;
            }
        };
        try self.editLibrary(Edit{ .id = id, .to = to }, Edit.apply);
    }

    /// Puts titles in exactly these categories; empty is the default category.
    pub fn setCategories(self: *Engine, manga_ids: []const []const u8, category_ids: []const u32) !void {
        const Edit = struct {
            ids: []const []const u8,
            categories: []const u32,
            fn apply(edit: @This(), arena: std.mem.Allocator, current: library.Library) !?library.Library {
                for (edit.categories) |id| {
                    const known = for (current.categories) |c| {
                        if (c.id == id) break true;
                    } else false;
                    if (!known) return error.UnknownCategory;
                }
                const own = try arena.dupe(u32, edit.categories);
                const titles = try arena.dupe(library.Manga, current.manga);
                for (titles) |*m| if (contains(edit.ids, m.id)) {
                    m.categories = own;
                };
                var next = current;
                next.manga = titles;
                return next;
            }
        };
        try self.editLibrary(Edit{ .ids = manga_ids, .categories = category_ids }, Edit.apply);
    }

    /// Sets the library sort as Mihon does: for every category and the
    /// global sort, or with `per_category_sort` for just `category` (0, the
    /// default category, keeps the global sort).
    pub fn setLibrarySort(self: *Engine, category: u32, sort: views.LibrarySort) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var s = try self.loadSettings(a);
        const only: ?u32 = if (s.library.per_category_sort and category != 0) category else null;
        if (only == null) {
            s.library.sort = sort.encode(s.library.sort);
            try self.saveSettings(s);
        }
        const Edit = struct {
            only: ?u32,
            sort: views.LibrarySort,
            fn apply(edit: @This(), arena: std.mem.Allocator, current: library.Library) !?library.Library {
                const categories = try arena.dupe(library.Category, current.categories);
                for (categories) |*c| if (edit.only == null or edit.only.? == c.id) {
                    c.flags = edit.sort.encode(c.flags);
                };
                var next = current;
                next.categories = categories;
                return next;
            }
        };
        try self.editLibrary(Edit{ .only = only, .sort = sort }, Edit.apply);
    }

    fn editLibrary(self: *Engine, context: anytype, comptime edit: fn (@TypeOf(context), std.mem.Allocator, library.Library) anyerror!?library.Library) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        _ = try self.store.update(arena_state.allocator(), context, edit);
    }

    // ---- sources ---------------------------------------------------------------

    /// Mihon's sources screen from `sources` (a `.sources` job's result) and
    /// the settings.
    pub fn sourceList(self: *Engine, arena: std.mem.Allocator, sources: []const models.SourceInfo) !views.SourceList {
        const s = try self.loadSettings(arena);
        return views.sourceList(arena, sources, s.browse);
    }

    pub fn setSourceHidden(self: *Engine, id: i64, hidden: bool) !void {
        try self.setSourceFlag("hidden_sources", id, hidden);
    }

    pub fn setSourcePinned(self: *Engine, id: i64, pinned: bool) !void {
        try self.setSourceFlag("pinned_sources", id, pinned);
    }

    /// Shows or hides a language's sources.
    pub fn setLanguage(self: *Engine, lang: []const u8, enabled: bool) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var s = try self.loadSettings(a);
        var list: std.ArrayList([]const u8) = .empty;
        for (s.browse.languages) |l| if (!std.mem.eql(u8, l, lang)) try list.append(a, l);
        if (enabled) try list.append(a, lang);
        s.browse.languages = list.items;
        try self.saveSettings(s);
    }

    /// Remembers the source browsed last.
    pub fn setLastSource(self: *Engine, id: i64) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        var s = try self.loadSettings(arena_state.allocator());
        if (s.browse.last_source == id) return;
        s.browse.last_source = id;
        try self.saveSettings(s);
    }

    fn setSourceFlag(self: *Engine, comptime field: []const u8, id: i64, on: bool) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        var s = try self.loadSettings(a);
        var list: std.ArrayList(i64) = .empty;
        for (@field(s.browse, field)) |known| if (known != id) try list.append(a, known);
        if (on) try list.append(a, id);
        @field(s.browse, field) = list.items;
        try self.saveSettings(s);
    }

    fn globalSearch(self: *Engine, job: *Job, query: []const u8, pinned_only: bool, only: []const i64) !void {
        const a = job.arena.allocator();
        if (std.mem.trim(u8, query, " \t\r\n").len == 0) {
            job.result.message = "Nothing to search for";
            return;
        }
        const s = try self.loadSettings(a);
        const sources = (try job.call(.sources)).sources;
        try self.rememberSources(job, sources);
        var targets: std.ArrayList(models.SourceInfo) = .empty;
        for (sources) |source| {
            const id = source.idInt() catch continue;
            if (only.len > 0) {
                if (std.mem.indexOfScalar(i64, only, id) == null) continue;
            } else if (!views.sourceEnabled(source, s.browse) or (pinned_only and !views.sourcePinned(source, s.browse))) continue;
            try targets.append(a, source);
        }
        job.pages_total.store(targets.items.len, .release);
        const Search = struct {
            job: *Job,
            targets: []const models.SourceInfo,
            browse: @FieldType(settings.Settings, "browse"),

            fn starting(ptr: *anyopaque) void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                Job.starting(ctx.job);
            }
            fn ready(ptr: *anyopaque) void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                Job.ready(ctx.job);
            }
            fn loading(ptr: *anyopaque, extension: ?[]const u8) void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                Job.loading(ctx.job, extension);
            }
            fn publish(ptr: *anyopaque, result: be.SourceSearch) !void {
                const ctx: *@This() = @ptrCast(@alignCast(ptr));
                const source = for (ctx.targets) |target| {
                    if ((target.idInt() catch unreachable) == result.source) break target;
                } else return error.InvalidSearchSource;
                // A worker response and in-process task scratch are both borrowed.
                // Keep a private arena before publishing pointers to the UI.
                var scratch: std.heap.ArenaAllocator = .init(ctx.job.engine.gpa);
                defer scratch.deinit();
                const json = try std.json.Stringify.valueAlloc(scratch.allocator(), result, .{});
                const kept = try std.json.parseFromSliceLeaky(be.SourceSearch, scratch.allocator(), json, models.parse_options);
                const value: SearchResult = .{ .source = source, .pinned = views.sourcePinned(source, ctx.browse), .mangas = kept.mangas, .failure = kept.failure };
                try ctx.job.keepArena(&scratch);
                while (!ctx.job.search_lock.tryLock()) std.atomic.spinLoopHint();
                defer ctx.job.search_lock.unlock();
                try ctx.job.search_partial.append(ctx.job.arena.allocator(), value);
                ctx.job.pages_done.store(ctx.job.search_partial.items.len, .release);
            }
        };
        const ids = try a.alloc(i64, targets.items.len);
        for (targets.items, ids) |source, *id| id.* = source.idInt() catch unreachable;
        var search: Search = .{ .job = job, .targets = targets.items, .browse = s.browse };
        try self.backend.search(self.gpa, self.io, a, .{ .sources = ids, .query = query, .parallelism = self.options.parallelism }, .{
            .context = &search,
            .starting = Search.starting,
            .ready = Search.ready,
            .loading = Search.loading,
            .search_result = Search.publish,
        });
        const results = try a.dupe(SearchResult, job.search_partial.items);
        sortSearch(results);
        job.result.search = results;
        job.result.message = "Search finished";
    }

    fn naming(s: settings.Settings) mihon_downloads.Naming {
        return .{ .disallow_non_ascii = s.downloads.disallow_non_ascii_filenames, .chapter_hash = s.downloads.chapter_name_hash };
    }

    /// A title's folder in a Mihon downloads tree, or null if its source's
    /// name was never learned.
    fn mihonMangaDir(a: std.mem.Allocator, lib: library.Library, root: []const u8, m: library.Manga, n: mihon_downloads.Naming) !?[]const u8 {
        const id = m.source_id orelse return null;
        const source = for (lib.sources) |known| {
            if (known.id == id) break known;
        } else return null;
        return try std.fs.path.join(a, &.{ root, try mihon_downloads.sourceDirName(a, source.name, source.lang, n), try mihon_downloads.mangaDirName(a, m.title, n) });
    }

    fn exportDownloads(self: *Engine, job: *Job, root: []const u8) !void {
        const a = job.arena.allocator();
        const s = try self.loadSettings(a);
        const lib = try self.store.load(a);
        var total: usize = 0;
        for (lib.manga) |m| if (!m.local()) for (m.chapters) |ch| {
            if (ch.downloaded()) total += 1;
        };
        job.pages_total.store(total, .release);
        var done: usize = 0;
        var skipped: usize = 0;
        for (lib.manga) |m| {
            if (m.local()) continue;
            const manga_dir = try mihonMangaDir(a, lib, root, m, naming(s)) orelse {
                for (m.chapters) |ch| if (ch.downloaded()) {
                    skipped += 1;
                };
                continue;
            };
            var categories: std.ArrayList([]const u8) = .empty;
            for (m.categories) |id| for (lib.categories) |c| if (c.id == id) try categories.append(a, std.mem.trim(u8, c.name, " "));
            const source_name = for (lib.sources) |known| {
                if (known.id == m.source_id.?) break known.name;
            } else "";
            for (m.chapters) |ch| {
                if (!ch.downloaded()) continue;
                try self.io.checkCancel();
                var chapter_arena: std.heap.ArenaAllocator = .init(self.gpa);
                defer chapter_arena.deinit();
                const ca = chapter_arena.allocator();
                const pages = try ca.alloc([]const u8, ch.pages.len);
                for (ch.pages, pages) |page, *bytes| bytes.* = try Io.Dir.cwd().readFileAlloc(self.io, try self.pagePath(ca, page), ca, .limited(downloads.max_image));
                const url = if (ch.remote) |r| r.url else "";
                var urls: std.ArrayList([]const u8) = .empty;
                for (m.tracks) |t| if (t.url.len > 0) try urls.append(ca, t.url);
                try urls.append(ca, url);
                const xml = try mihon_downloads.comicInfoXml(ca, m, ch, source_name, categories.items, urls.items);
                const dir_name = try mihon_downloads.chapterDirName(ca, ch.title, ch.scanlator, url, naming(s));
                try mihon_downloads.exportChapter(ca, self.io, manga_dir, dir_name, pages, xml, s.downloads.cbz);
                done += 1;
                job.pages_done.store(done, .release);
            }
        }
        job.result.message = if (skipped == 0)
            try std.fmt.allocPrint(a, "Exported {d} chapters", .{done})
        else
            try std.fmt.allocPrint(a, "Exported {d} chapters; {d} of sources never loaded were skipped", .{ done, skipped });
    }

    fn importDownloads(self: *Engine, job: *Job, root: []const u8) !void {
        const a = job.arena.allocator();
        const s = try self.loadSettings(a);
        const lib = try self.store.load(a);
        const Attach = struct { id: []const u8, pages: []const []const u8 };
        var found_pages: std.ArrayList(Attach) = .empty;
        for (lib.manga) |m| {
            const manga_dir = try mihonMangaDir(a, lib, root, m, naming(s)) orelse continue;
            for (m.chapters) |ch| {
                if (ch.downloaded()) continue;
                try self.io.checkCancel();
                const url = if (ch.remote) |r| r.url else continue;
                const names = try mihon_downloads.chapterDirNames(a, ch.title, ch.scanlator, url, naming(s));
                const found = try mihon_downloads.findChapter(a, self.io, manga_dir, names) orelse continue;
                const page_names = try mihon_downloads.pageNames(a, self.io, found);
                if (page_names.len == 0) continue;
                // Copied in, so the library stays whole without the tree.
                const folder = try std.fmt.allocPrint(a, "downloads/mihon/{x}", .{std.hash.Wyhash.hash(0, ch.id)});
                const pages = try a.alloc([]const u8, page_names.len);
                if (found.cbz) {
                    const relative = try std.mem.concat(a, u8, &.{ folder, ".cbz" });
                    try self.copyInto(a, found.path, relative);
                    for (page_names, pages) |name, *page| page.* = try std.fmt.allocPrint(a, "{s}#{s}", .{ relative, name });
                } else for (page_names, pages) |name, *page| {
                    page.* = try std.fmt.allocPrint(a, "{s}/{s}", .{ folder, name });
                    try self.copyInto(a, try std.fs.path.join(a, &.{ found.path, name }), page.*);
                }
                try found_pages.append(a, .{ .id = ch.id, .pages = pages });
            }
        }
        const Edit = struct {
            found: []const Attach,
            fn apply(edit: @This(), arena: std.mem.Allocator, current: library.Library) !?library.Library {
                var next = current;
                for (edit.found) |f| next = (try library.setPages(arena, next, f.id, f.pages)) orelse next;
                return next;
            }
        };
        if (found_pages.items.len > 0) _ = try self.store.update(a, Edit{ .found = found_pages.items }, Edit.apply);
        job.result = .{ .library_changed = found_pages.items.len > 0, .message = try std.fmt.allocPrint(a, "Imported {d} chapters", .{found_pages.items.len}) };
    }

    /// Copies `from` (absolute) to `relative` in the library directory.
    fn copyInto(self: *Engine, a: std.mem.Allocator, from: []const u8, relative: []const u8) !void {
        const to = try std.fs.path.join(a, &.{ self.options.dir, relative });
        try Io.Dir.cwd().createDirPath(self.io, std.fs.path.dirname(to).?);
        const bytes = try Io.Dir.cwd().readFileAlloc(self.io, from, self.gpa, .limited(1 << 30));
        defer self.gpa.free(bytes);
        try library.writeAtomic(a, self.io, to, bytes);
    }

    fn migrate(self: *Engine, job: *Job, from: []const u8, source: i64, remote: models.Manga, replace: bool) !void {
        const a = job.arena.allocator();
        const current = try self.store.load(a);
        const old = current.manga[current.find(from) orelse return error.UnknownManga];
        const target_id = try library.mangaId(a, source, remote.url);
        if (std.mem.eql(u8, target_id, old.id)) return error.SameTitle;
        const existing = if (current.find(target_id)) |i| current.manga[i].chapters else &.{};
        _ = try self.fetchTitle(job, source, remote, existing, .{ .manual = true });
        const s = try self.loadSettings(a);
        const Edit = struct {
            old: []const u8,
            target: []const u8,
            flags: settings.Settings.Migration,
            replace: bool,
            now: i64,
            fn apply(edit: @This(), arena: std.mem.Allocator, lib: library.Library) !?library.Library {
                const titles = try arena.dupe(library.Manga, lib.manga);
                const o = titles[lib.find(edit.old) orelse return error.UnknownManga];
                const t = &titles[lib.find(edit.target).?];
                if (edit.flags.chapters) {
                    var max_read: ?f64 = null;
                    for (o.chapters) |ch| if (ch.read) {
                        max_read = @max(max_read orelse ch.number, ch.number);
                    };
                    const chapters = try arena.dupe(library.Chapter, t.chapters);
                    for (chapters) |*ch| {
                        if (!ch.recognized()) continue;
                        for (o.chapters) |prev| if (prev.recognized() and prev.number == ch.number) {
                            ch.date_fetch = prev.date_fetch;
                            ch.bookmark = prev.bookmark;
                            break;
                        };
                        if (max_read) |max| if (ch.number <= max) {
                            ch.read = true;
                        };
                    }
                    t.chapters = chapters;
                }
                if (edit.flags.categories) t.categories = o.categories;
                if (edit.flags.notes) t.notes = o.notes;
                var tracks: std.ArrayList(library.Track) = .empty;
                const enhanced = @import("track/enhanced.zig");
                for (o.tracks) |track| {
                    if (if (tracking.get(track.tracker_id)) |service| service.enhanced else false) {
                        if (!enhanced.isTrackFrom(track, o, enhanced.sourcePackage(lib, o))) continue;
                        if (enhanced.migrate(track, t.*, enhanced.sourcePackage(lib, t.*))) |moved| try tracks.append(arena, moved);
                    } else try tracks.append(arena, track);
                }
                t.tracks = try tracks.toOwnedSlice(arena);
                t.chapter_flags = o.chapter_flags;
                t.reader_flags = o.reader_flags;
                t.favorite = true;
                t.date_added = if (edit.replace and o.date_added != 0) o.date_added else edit.now;
                if (edit.replace) {
                    const previous = &titles[lib.find(edit.old).?];
                    previous.favorite = false;
                    previous.date_added = 0;
                }
                var next = lib;
                next.manga = titles;
                return next;
            }
        };
        _ = try self.store.update(a, Edit{ .old = from, .target = target_id, .flags = s.browse.migration, .replace = replace, .now = wallMillis(self.io) }, Edit.apply);
        if (s.browse.migration.remove_downloads and !old.local()) {
            var ids: std.ArrayList([]const u8) = .empty;
            for (old.chapters) |ch| if (ch.downloaded()) try ids.append(a, ch.id);
            _ = try self.removeDownloads(a, ids.items);
        }
        job.result = .{ .library_changed = true, .manga_id = target_id, .message = "Migrated" };
    }

    // ---- tracking --------------------------------------------------------------

    /// Credentials, score formats and deferred updates in trackers.json.
    pub fn loadTrackers(self: *Engine, a: std.mem.Allocator) !*tracking.State {
        const state = try a.create(tracking.State);
        state.* = try tracking.State.load(a, self.io, self.options.dir);
        return state;
    }

    pub fn saveTrackerFormats(self: *Engine, formats: tracking.Formats) !void {
        self.tracking_lock.lockUncancelable(self.io);
        defer self.tracking_lock.unlock(self.io);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const state = try self.loadTrackers(arena.allocator());
        state.formats = formats;
        try state.save(self.gpa, self.io, self.options.dir);
    }

    pub fn trackerLogout(self: *Engine, id: i32) !void {
        self.tracking_lock.lockUncancelable(self.io);
        defer self.tracking_lock.unlock(self.io);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const state = try self.loadTrackers(arena.allocator());
        try state.putCredential(arena.allocator(), .{ .tracker_id = id });
        try state.save(self.gpa, self.io, self.options.dir);
    }

    /// Joins and releases the reader's automatic job. Call before destroying
    /// the engine or its backend, and before inspecting automatic results.
    pub fn finishTracking(self: *Engine) void {
        self.tracking_job_lock.lockUncancelable(self.io);
        defer self.tracking_job_lock.unlock(self.io);
        if (self.tracking_job) |job| job.deinit();
        self.tracking_job = null;
    }

    fn startTracking(self: *Engine) !void {
        if (self.paused.load(.acquire)) return;
        self.tracking_job_lock.lockUncancelable(self.io);
        defer self.tracking_job_lock.unlock(self.io);
        if (self.tracking_job) |job| {
            if (!job.done.load(.acquire)) return;
            job.deinit();
            self.tracking_job = null;
        }
        self.tracking_job = try Job.start(self, .{ .track_pending = .{ .connected = true, .force = true } });
    }

    /// Queues `chapter` as progress for the title's logged-in trackers that
    /// are behind it; true if any were.
    pub fn queueTracking(self: *Engine, manga_id: []const u8, chapter: f64) !bool {
        if (!std.math.isFinite(chapter) or chapter < 0) return false;
        self.tracking_lock.lockUncancelable(self.io);
        defer self.tracking_lock.unlock(self.io);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const state = try self.loadTrackers(a);
        const lib = try self.store.load(a);
        const manga = lib.manga[lib.find(manga_id) orelse return error.UnknownManga];
        var added = false;
        for (manga.tracks) |t| if (state.loggedIn(t.tracker_id) and chapter > t.last_chapter_read) {
            try state.enqueue(a, .{ .manga_id = manga_id, .tracker_id = t.tracker_id, .chapter = chapter });
            added = true;
        };
        if (added) {
            state.attempts = 0;
            state.retry_at = 0;
            try state.save(self.gpa, self.io, self.options.dir);
        }
        return added;
    }

    pub const MarkTracked = struct { changed: usize, prompts: []const tracking.Pending };
    /// Manga-screen wrapper. Bulk library/feed markRead deliberately bypasses
    /// tracking. For ASK, pass prompts to applyTracking after confirmation.
    pub fn markReadTracked(self: *Engine, a: std.mem.Allocator, chapter_ids: []const []const u8, read: bool) !MarkTracked {
        const changed = try self.markRead(chapter_ids, read);
        const s = try self.loadSettings(a);
        if (!read or s.tracking.on_mark_read == .never) return .{ .changed = changed, .prompts = &.{} };
        const lib = try self.store.load(a);
        var prompts: std.ArrayList(tracking.Pending) = .empty;
        for (lib.manga) |m| {
            var max: f64 = -1;
            for (m.chapters) |ch| if (contains(chapter_ids, ch.id) and ch.recognized()) {
                max = @max(max, ch.number);
            };
            if (max >= 0 and m.tracks.len > 0) try prompts.append(a, .{ .manga_id = m.id, .tracker_id = 0, .chapter = max });
        }
        if (s.tracking.on_mark_read == .always) {
            try self.applyTracking(prompts.items);
            return .{ .changed = changed, .prompts = &.{} };
        }
        return .{ .changed = changed, .prompts = try prompts.toOwnedSlice(a) };
    }

    /// Applies manga-level progress to every eligible bound tracker.
    pub fn applyTracking(self: *Engine, prompts: []const tracking.Pending) !void {
        var any = false;
        for (prompts) |p| any = try self.queueTracking(p.manga_id, p.chapter) or any;
        if (any) try self.startTracking();
    }

    fn trackerCall(self: *Engine, job: *Job, state: *tracking.State, id: i32, op: tracking.Operation) !tracking.Reply {
        try job.checkCancelled();
        _ = tracking.get(id) orelse return error.UnknownTracker;
        const driver = self.options.tracker_driver orelse self.drivers.driver();
        const reply = driver.call(driver.context, job.arena.allocator(), self.io, id, state.credential(id), state.formats, op) catch |err| {
            if (err == error.AuthenticationExpired) {
                var c = state.credential(id);
                c.auth_expired = true;
                try state.putCredential(job.arena.allocator(), c);
                try state.save(self.gpa, self.io, self.options.dir);
            }
            return err;
        };
        if (reply.mangabaka_score_type) |format| {
            if (id != 11) return error.InvalidTrackerResponse;
            state.formats.mangabaka_score_type = format;
            try state.save(self.gpa, self.io, self.options.dir);
        }
        if (reply.anilist_score_type != null or reply.kitsu_score_type != null) {
            if (reply.anilist_score_type) |format| state.formats.anilist_score_type = format;
            if (reply.kitsu_score_type) |format| state.formats.kitsu_score_type = format;
            try state.save(self.gpa, self.io, self.options.dir);
        }
        if (reply.credential) |c| {
            if (c.tracker_id != id) return error.InvalidTrackerResponse;
            try state.putCredential(job.arena.allocator(), c);
            try state.save(self.gpa, self.io, self.options.dir);
        }
        if (reply.track) |t| if (t.tracker_id != id) return error.InvalidTrackerResponse;
        return reply;
    }

    fn putTrack(self: *Engine, job: *Job, manga_id: []const u8, id: i32, track: ?library.Track) !void {
        _ = try self.store.update(job.arena.allocator(), tracking.Edit{ .manga_id = manga_id, .tracker_id = id, .track = track }, tracking.Edit.apply);
        job.result.library_changed = true;
    }

    fn boundTrack(self: *Engine, a: std.mem.Allocator, manga_id: []const u8, id: i32) !library.Track {
        const lib = try self.store.load(a);
        const m = lib.manga[lib.find(manga_id) orelse return error.UnknownManga];
        for (m.tracks) |t| if (t.tracker_id == id) return t;
        return error.TrackNotBound;
    }

    fn trackChapter(self: *Engine, job: *Job, state: *tracking.State, manga_id: []const u8, chapter: f64) !void {
        if (!std.math.isFinite(chapter) or chapter < 0) return error.InvalidProgress;
        const a = job.arena.allocator();
        const lib = try self.store.load(a);
        const m = lib.manga[lib.find(manga_id) orelse return error.UnknownManga];
        var failures: std.ArrayList(TrackingError) = .empty;
        for (m.tracks) |track| {
            if (!state.loggedIn(track.tracker_id) or chapter <= track.last_chapter_read) continue;
            self.advanceTrack(job, state, manga_id, track, chapter) catch |err| {
                if (err == error.Canceled) return err;
                try state.enqueue(a, .{ .manga_id = manga_id, .tracker_id = track.tracker_id, .chapter = chapter });
                try failures.append(a, .{ .manga_id = manga_id, .tracker_id = track.tracker_id, .message = @errorName(err) });
            };
        }
        job.result.tracking_errors = try std.mem.concat(a, TrackingError, &.{ job.result.tracking_errors, failures.items });
        try state.save(self.gpa, self.io, self.options.dir);
    }

    fn advanceTrack(self: *Engine, job: *Job, state: *tracking.State, manga_id: []const u8, track: library.Track, chapter: f64) !void {
        var fresh = (try self.trackerCall(job, state, track.tracker_id, .{ .refresh = track })).track orelse return error.InvalidTrackerResponse;
        // Mihon assigns requested progress even when refreshed remote is ahead.
        fresh.last_chapter_read = chapter;
        _ = try self.trackerCall(job, state, track.tracker_id, .{ .update = .{ .track = fresh, .did_read_chapter = true } });
        // TrackChapter upserts the immutable pre-update domain copy.
        try self.putTrack(job, manga_id, track.tracker_id, fresh);
        try state.remove(job.arena.allocator(), manga_id, track.tracker_id);
    }

    /// Enhanced trackers update the server before importing any local reads.
    fn syncEnhanced(self: *Engine, job: *Job, state: *tracking.State, manga_id: []const u8, remote: library.Track) !void {
        if (!(tracking.get(remote.tracker_id) orelse return error.UnknownTracker).enhanced) return;
        const a = job.arena.allocator();
        const lib = try self.store.load(a);
        const manga = lib.manga[lib.find(manga_id) orelse return error.UnknownManga];
        var merged = remote;
        merged.last_chapter_read = @max(remote.last_chapter_read, try tracking.continuousRead(a, manga.chapters, true));
        _ = try self.trackerCall(job, state, remote.tracker_id, .{ .update = .{ .track = merged } });
        var reads: std.ArrayList(library.Reading) = .empty;
        for (manga.chapters) |ch| if (ch.recognized() and !ch.read and ch.number <= remote.last_chapter_read) {
            var r = readingOf(ch);
            r.read = true;
            try reads.append(a, r);
        };
        try self.store.putReading(self.gpa, reads.items);
        try self.putTrack(job, manga_id, remote.tracker_id, merged);
    }

    /// Binds the title to every logged-in enhanced tracker (Komga, Kavita,
    /// Suwayomi) whose extension provides it, as Mihon's
    /// `bindEnhancedTrackers`. The caller holds `tracking_lock`.
    fn matchEnhanced(self: *Engine, job: *Job, state: *tracking.State, manga_id: []const u8) !void {
        const a = job.arena.allocator();
        const lib = try self.store.load(a);
        const manga = lib.manga[lib.find(manga_id) orelse return error.UnknownManga];
        const enhanced = @import("track/enhanced.zig");
        const pkg = enhanced.sourcePackage(lib, manga);
        for ([_]i32{ 6, 8, 9 }) |id| {
            if (!state.loggedIn(id) or !enhanced.accepts(id, pkg)) continue;
            for (manga.tracks) |t| {
                if (t.tracker_id == id) break;
            } else {
                const reply = try self.trackerCall(job, state, id, .{ .search = (manga.remote orelse return error.LocalManga).url });
                if (reply.matches.len == 0) continue;
                const bound = (try self.trackerCall(job, state, id, .{ .bind = .{ .track = reply.matches[0].track, .has_read_chapters = false } })).track orelse return error.InvalidTrackerResponse;
                try self.syncEnhanced(job, state, manga.id, bound);
                job.result.tracking_reply = .{ .track = bound, .matches = reply.matches };
            }
        }
    }

    /// Mihon binds enhanced trackers when a title joins the library; a
    /// failure there doesn't stop the add.
    fn bindEnhancedOnAdd(self: *Engine, job: *Job, manga_id: []const u8) void {
        self.tracking_lock.lockUncancelable(self.io);
        defer self.tracking_lock.unlock(self.io);
        const state = self.loadTrackers(job.arena.allocator()) catch return;
        if (!state.loggedIn(6) and !state.loggedIn(8) and !state.loggedIn(9)) return;
        self.matchEnhanced(job, state, manga_id) catch |err| log.warn("enhanced trackers not bound: {s}", .{@errorName(err)});
    }

    fn executeTracking(self: *Engine, job: *Job) !void {
        try self.tracking_lock.lock(self.io);
        defer self.tracking_lock.unlock(self.io);
        const a = job.arena.allocator();
        const state = try self.loadTrackers(a);
        switch (job.request) {
            .tracker => |c| {
                switch (c.operation) {
                    .login, .login_url => {},
                    else => if (!state.loggedIn(c.id)) return error.TrackerLoggedOut,
                }
                job.result.tracking_reply = try self.trackerCall(job, state, c.id, c.operation);
            },
            .track_match => |c| try self.matchEnhanced(job, state, c.manga_id),
            .track_chapter => |c| try self.trackChapter(job, state, c.manga_id, c.chapter),
            .track_set => |c| {
                if (!state.loggedIn(c.tracker_id)) return error.TrackerLoggedOut;
                const old = try self.boundTrack(a, c.manga_id, c.tracker_id);
                const changed = try tracking.set(old, c.value, state.formats, wallMillis(self.io));
                const updated = (try self.trackerCall(job, state, c.tracker_id, .{ .update = .{ .track = changed } })).track orelse return error.InvalidTrackerResponse;
                try self.putTrack(job, c.manga_id, c.tracker_id, updated);
            },
            .track_unbind => |c| {
                const track = try self.boundTrack(a, c.manga_id, c.tracker_id);
                if (c.delete_remote) {
                    if (!(tracking.get(c.tracker_id) orelse return error.UnknownTracker).deletable) return error.UnsupportedDelete;
                    if (!state.loggedIn(c.tracker_id)) return error.TrackerLoggedOut;
                    _ = try self.trackerCall(job, state, c.tracker_id, .{ .delete = track });
                }
                try self.putTrack(job, c.manga_id, c.tracker_id, null);
                try state.remove(a, c.manga_id, c.tracker_id);
                try state.save(self.gpa, self.io, self.options.dir);
            },
            .track_bind => |c| {
                if (!state.loggedIn(c.track.tracker_id)) return error.TrackerLoggedOut;
                const lib = try self.store.load(a);
                const manga = lib.manga[lib.find(c.manga_id) orelse return error.UnknownManga];
                var has_read = false;
                var first_date: i64 = 0;
                for (manga.chapters) |ch| {
                    has_read = has_read or ch.read;
                    if (ch.last_read > 0 and (first_date == 0 or ch.last_read < first_date)) first_date = ch.last_read;
                }
                var bound = (try self.trackerCall(job, state, c.track.tracker_id, .{ .bind = .{ .track = c.track, .has_read_chapters = has_read } })).track orelse return error.InvalidTrackerResponse;
                try self.putTrack(job, c.manga_id, bound.tracker_id, bound);
                if (has_read) {
                    const prefix = try tracking.continuousRead(a, manga.chapters, false);
                    if (prefix > bound.last_chapter_read) {
                        bound = try tracking.set(bound, .{ .progress = @intFromFloat(prefix) }, state.formats, wallMillis(self.io));
                        bound = (try self.trackerCall(job, state, bound.tracker_id, .{ .update = .{ .track = bound } })).track orelse return error.InvalidTrackerResponse;
                        try self.putTrack(job, c.manga_id, bound.tracker_id, bound);
                    }
                    if (bound.started == 0 and first_date > 0) {
                        bound.started = first_date;
                        bound = (try self.trackerCall(job, state, bound.tracker_id, .{ .update = .{ .track = bound } })).track orelse return error.InvalidTrackerResponse;
                        try self.putTrack(job, c.manga_id, bound.tracker_id, bound);
                    }
                }
                try self.syncEnhanced(job, state, c.manga_id, bound);
            },
            .track_refresh => |c| {
                const lib = try self.store.load(a);
                var failures: std.ArrayList(TrackingError) = .empty;
                for (lib.manga) |m| {
                    if (c.manga_id) |id| if (!std.mem.eql(u8, id, m.id)) continue;
                    for (m.tracks) |t| {
                        if (!state.loggedIn(t.tracker_id)) continue;
                        const reply = self.trackerCall(job, state, t.tracker_id, .{ .refresh = t }) catch |err| {
                            if (err == error.Canceled) return err;
                            try failures.append(a, .{ .manga_id = m.id, .tracker_id = t.tracker_id, .message = @errorName(err) });
                            continue;
                        };
                        const fresh = reply.track orelse return error.InvalidTrackerResponse;
                        try self.putTrack(job, m.id, t.tracker_id, fresh);
                        self.syncEnhanced(job, state, m.id, fresh) catch |err| {
                            if (err == error.Canceled) return err;
                            try failures.append(a, .{ .manga_id = m.id, .tracker_id = t.tracker_id, .message = @errorName(err) });
                        };
                    }
                }
                job.result.tracking_errors = try failures.toOwnedSlice(a);
            },
            .track_pending => |c| {
                const now = wallMillis(self.io);
                if (!c.connected or (!c.force and now < state.retry_at)) return;
                if (state.attempts > 3) return error.TrackingRetriesExhausted;
                const pending = try a.dupe(tracking.Pending, state.pending);
                for (pending) |p| {
                    const track = self.boundTrack(a, p.manga_id, p.tracker_id) catch |err| switch (err) {
                        error.UnknownManga, error.TrackNotBound => {
                            try state.remove(a, p.manga_id, p.tracker_id);
                            continue;
                        },
                        else => return err,
                    };
                    _ = track;
                    // The delayed worker calls TrackChapter for the whole manga.
                    try self.trackChapter(job, state, p.manga_id, p.chapter);
                }
                if (state.pending.len > 0) {
                    state.retry_at = now + @as(i64, 5 * 60 * 1000) * (@as(i64, 1) << @intCast(state.attempts));
                    state.attempts += 1;
                }
                try state.save(self.gpa, self.io, self.options.dir);
            },
            else => unreachable,
        }
    }

    // ---- operations ------------------------------------------------------------

    pub fn execute(self: *Engine, job: *Job) !void {
        try self.io.checkCancel();
        switch (job.request) {
            .tracker, .track_match, .track_bind, .track_unbind, .track_set, .track_refresh, .track_chapter, .track_pending => return self.executeTracking(job),
            .sources => {
                job.result.sources = (try job.call(.sources)).sources;
                try self.rememberSources(job, job.result.sources);
            },
            .extensions => |r| try self.listExtensions(job, r),
            .install => |c| {
                job.result.sources = (try job.call(.{ .install = .{ .pkg = c.pkg, .repo = c.repo } })).sources;
                job.result.message = "Extension installed";
            },
            .install_file => |path| try self.installFile(job, path),
            .uninstall => |pkg| {
                job.result.sources = (try job.call(.{ .uninstall = pkg })).sources;
                job.result.message = "Extension removed";
            },
            .update_extensions => |r| {
                job.result.extension_updates = try self.updateExtensions(job, r);
                job.result.message = "Extensions updated";
            },
            .add_store => |url| {
                const a = job.arena.allocator();
                const store = try self.fetchStore(a, url);
                const file = try stores.File.load(a, self.io, self.options.dir);
                try (try file.upsert(a, store)).save(a, self.io, self.options.dir);
                job.result.message = try std.fmt.allocPrint(a, "Added {s}", .{store.name});
            },
            .refresh_stores => try self.refreshStores(job),
            .browse => |c| job.result.page = (try job.call(.{ .browse = .{ .source = c.source, .page = c.page, .kind = c.kind } })).page,
            .filters => |id| job.result.filters = (try job.call(.{ .filters = id })).filters,
            .related => |c| job.result.mangas = (try job.call(.{ .related = .{ .source = c.source, .manga = c.manga } })).mangas,
            .preferences => |id| job.result.preferences = (try job.call(.{ .preferences = id })).preferences,
            .set_preference => |c| {
                job.result.preferences = (try job.call(.{ .set_preference = .{ .source = c.source, .key = c.key, .value = c.value } })).preferences;
                job.result.message = "Source setting saved";
            },
            .add => |c| {
                const a = job.arena.allocator();
                const current = try self.store.load(a);
                const index = current.find(try library.mangaId(a, c.source, c.manga.url));
                const existing = if (index) |i| current.manga[i].chapters else &.{};
                const fetched = try self.fetchTitle(job, c.source, c.manga, existing, .{ .manual = true });
                if (index) |i| {
                    if (!current.manga[i].favorite) try self.setFavorite(fetched.manga_id, true);
                } else {
                    // New titles start with the default chapter flags and category.
                    const s = try self.loadSettings(a);
                    const Edit = struct {
                        s: settings.Settings,
                        fn apply(edit: @This(), arena: std.mem.Allocator, m: *library.Manga) !bool {
                            m.chapter_flags = edit.s.library.default_chapter_flags;
                            if (edit.s.library.default_category) |category| m.categories = try arena.dupe(u32, &.{category});
                            return true;
                        }
                    };
                    try self.editTitle(a, fetched.manga_id, Edit{ .s = s }, Edit.apply);
                }
                self.bindEnhancedOnAdd(job, fetched.manga_id);
                job.result = .{ .library_changed = true, .manga_id = fetched.manga_id, .new_chapters = fetched.new_chapters, .message = "Added to library" };
            },
            .refresh => |id| {
                const a = job.arena.allocator();
                const current = try self.store.load(a);
                const book = current.manga[current.find(id) orelse return error.UnknownManga];
                const fetched = try self.fetchTitle(job, book.source_id orelse return error.LocalTitle, book.remote orelse return error.LocalTitle, book.chapters, .{ .manual = true });
                try self.autoDownload(job, fetched.new_chapters);
                job.result = .{ .library_changed = true, .manga_id = book.id, .new_chapters = fetched.new_chapters, .message = "Chapter list updated" };
            },
            .update_library => |c| try self.updateLibrary(job, c.category),
            .global_search => |c| try self.globalSearch(job, c.query, c.pinned_only, c.sources),
            .export_downloads => |root| try self.exportDownloads(job, root),
            .import_downloads => |root| try self.importDownloads(job, root),
            .migrate => |c| try self.migrate(job, c.from, c.source, c.manga, c.replace),
            .download => |id| try self.downloadChapter(job, id),
            .read => |r| try self.readChapter(job, r.chapter, r.page),
            .cover => |c| {
                const a = job.arena.allocator();
                if (try self.cachedCover(a, c.url)) |path| {
                    job.result = .{ .cover = path, .message = "Cover ready" };
                    return;
                }
                job.fallback_source = c.source;
                const bytes = try Job.fetchFallback(job, a, .{ .page = .{ .index = 0, .imageUrl = c.url }, .url = c.url, .method = "GET", .headers = &.{} }, "cover");
                const ext = downloads.imageExtension(bytes) orelse return error.UnsupportedImageFormat;
                const path = try std.fmt.allocPrint(a, "{s}/{x}.{s}", .{ covers_dir, std.hash.Wyhash.hash(0, c.url), ext });
                const absolute = try std.fs.path.join(a, &.{ self.options.dir, path });
                try Io.Dir.cwd().createDirPath(self.io, std.fs.path.dirname(absolute).?);
                try library.writeAtomic(a, self.io, absolute, bytes);
                job.result = .{ .cover = path, .message = "Cover ready" };
            },
            .delete_download => |id| {
                const deleted = try self.deleteDownloads(&.{id});
                job.result = .{ .library_changed = deleted > 0, .message = if (deleted > 0) "Download deleted" else "Download kept by the deletion settings" };
            },
            .remove => |id| {
                try self.setFavorite(id, false);
                job.result = .{ .library_changed = true, .manga_id = id, .message = "Removed from library" };
            },
            .import_backup => |path| {
                const a = job.arena.allocator();
                const data = try Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(256 << 20));
                const decoded = try backup.decode(a, data);
                const Edit = struct {
                    backup: backup.Backup,
                    restored: *backup.Restored,
                    fn apply(edit: @This(), arena: std.mem.Allocator, current: library.Library) !?library.Library {
                        edit.restored.* = try backup.restore(arena, current, edit.backup, .{});
                        return edit.restored.library;
                    }
                };
                var restored: backup.Restored = undefined;
                const after = try self.store.update(a, Edit{ .backup = decoded, .restored = &restored }, Edit.apply);
                // Settings name categories by the backup's ids; Mihon maps them by name.
                var mapping: std.ArrayList(preferences.CategoryMapping) = .empty;
                for (decoded.categories) |bc| for (after.categories) |c| if (std.mem.eql(u8, c.name, bc.name)) try mapping.append(a, .{ .backup_id = bc.id, .id = c.id });
                if (decoded.preferences.len > 0) try self.saveSettings(try preferences.applyToSettings(a, try self.loadSettings(a), decoded.preferences, mapping.items));
                if (decoded.extension_stores.len > 0) {
                    var file = try stores.File.load(a, self.io, self.options.dir);
                    // Mihon upserts by index URL.
                    for (decoded.extension_stores) |st| file = try file.upsert(a, .{ .index_url = st.index_url, .name = st.name, .badge_label = st.badge_label orelse st.name, .signing_key = st.signing_key, .website = st.contact_website, .discord = st.contact_discord, .legacy = st.legacy orelse true, .extension_list_url = st.extension_list_url });
                    try file.save(a, self.io, self.options.dir);
                }
                if (decoded.source_preferences.len > 0) {
                    try preferences.writeSourcePreferences(a, self.io, try self.prefsDir(a), decoded.source_preferences);
                    // A running runtime has the old values in memory; a
                    // runtime started later reads the files anyway.
                    if (self.backend.warm()) _ = job.call(.reload_preferences) catch |err| log.warn("extension settings not reloaded: {s}", .{@errorName(err)});
                }
                job.result = .{ .library_changed = true, .message = try std.fmt.allocPrint(a, "Restored {d} titles", .{restored.restored}) };
            },
            .export_backup => |c| {
                const a = job.arena.allocator();
                var b = try backup.fromLibrary(a, try self.store.load(a), c.options);
                if (c.options.app_settings) {
                    var kept: std.ArrayList(backup.Preference) = .empty;
                    for (try preferences.fromSettings(a, try self.loadSettings(a))) |p| {
                        if (preferences.isAppState(p.key) or (!c.options.private_settings and preferences.isPrivate(p.key))) continue;
                        try kept.append(a, p);
                    }
                    b.preferences = kept.items;
                }
                if (c.options.source_settings) b.source_preferences = try preferences.readSourcePreferences(a, self.io, try self.prefsDir(a), c.options.private_settings);
                if (c.options.extension_stores) {
                    const file = try stores.File.load(a, self.io, self.options.dir);
                    const out = try a.alloc(backup.ExtensionStore, file.stores.len);
                    for (file.stores, out) |st, *o| o.* = .{ .index_url = st.index_url, .name = st.name, .badge_label = st.badge_label, .signing_key = st.signing_key, .contact_website = st.website, .contact_discord = st.discord, .legacy = st.legacy, .extension_list_url = st.extension_list_url };
                    b.extension_stores = out;
                }
                const bytes = try backup.encodeFile(a, b);
                try library.writeAtomic(a, self.io, c.path, bytes);
                job.result = .{ .message = "Backup created" };
            },
            .scan_local => {
                const a = job.arena.allocator();
                const titles = try local.scan(a, self.io, self.options.dir);
                const Edit = struct {
                    titles: []const library.Manga,
                    now: i64,
                    fn apply(edit: @This(), arena: std.mem.Allocator, current: library.Library) !?library.Library {
                        var next = current;
                        for (edit.titles) |m| next = try library.merge(arena, next, m, edit.now);
                        return next;
                    }
                };
                _ = try self.store.update(a, Edit{ .titles = titles, .now = wallMillis(self.io) }, Edit.apply);
                job.result = .{ .library_changed = true, .message = "Local manga indexed" };
            },
        }
    }

    /// Queues new chapters as Mihon's auto-download does: when enabled, for
    /// library titles in the allowed categories, and optionally only when no
    /// chapter with the same number was read.
    fn autoDownload(self: *Engine, job: *Job, new_chapters: []const []const u8) !void {
        if (new_chapters.len == 0) return;
        const a = job.arena.allocator();
        const s = try self.loadSettings(a);
        if (!s.downloads.new_chapters) return;
        const lib = try self.store.load(a);
        var selected: std.ArrayList([]const u8) = .empty;
        for (new_chapters) |id| {
            const found = findChapter(lib, id) orelse continue;
            if (!found.manga.favorite) continue;
            if (!settings.categoryAllowed(found.manga.categories, s.downloads.new_categories, s.downloads.new_exclude_categories)) continue;
            if (s.downloads.new_unread_only and found.chapter.recognized()) {
                const read_before = for (found.manga.chapters) |ch| {
                    if (ch.read and ch.number == found.chapter.number) break true;
                } else false;
                if (read_before) continue;
            }
            try selected.append(a, id);
        }
        if (selected.items.len > 0) _ = try self.queue.enqueue(self, selected.items, true);
    }

    /// Remembers installed sources' names, so titles stay named in backups
    /// and lists after an extension is gone.
    fn rememberSources(self: *Engine, job: *Job, sources: []const models.SourceInfo) !void {
        const Edit = struct {
            sources: []const models.SourceInfo,
            fn apply(edit: @This(), arena: std.mem.Allocator, current: library.Library) !?library.Library {
                var names: std.ArrayList(library.SourceName) = .empty;
                try names.appendSlice(arena, current.sources);
                var changed = false;
                for (edit.sources) |s| {
                    const id = s.idInt() catch continue;
                    const name: library.SourceName = .{ .id = id, .name = s.name, .lang = s.lang, .pkg = s.extensionPkg };
                    for (names.items) |*known| {
                        if (known.id != id) continue;
                        if (!std.mem.eql(u8, known.name, s.name) or !std.mem.eql(u8, known.lang, s.lang) or !std.mem.eql(u8, known.pkg, s.extensionPkg)) {
                            known.* = name;
                            changed = true;
                        }
                        break;
                    } else {
                        try names.append(arena, name);
                        changed = true;
                    }
                }
                if (!changed) return null;
                var next = current;
                next.sources = names.items;
                return next;
            }
        };
        _ = try self.store.update(job.arena.allocator(), Edit{ .sources = sources }, Edit.apply);
    }

    /// Fetches a title's details and chapters in one source call and syncs
    /// them into the library as Mihon does; returns the title's id and the
    /// chapters that are new to the reader.
    fn fetchTitle(self: *Engine, job: *Job, source: i64, remote: models.Manga, existing: []const library.Chapter, schedule: Schedule) !Fetched {
        const a = job.arena.allocator();
        const started = millis(self.io);
        const update = try self.fetchTitleUpdate(a, source, remote, existing, schedule.details, job.status());
        return self.syncTitle(a, source, update, schedule, started, millis(self.io));
    }

    fn fetchTitleUpdate(self: *Engine, a: std.mem.Allocator, source: i64, remote: models.Manga, existing: []const library.Chapter, details: bool, status: ?be.Status) !models.MangaUpdate {
        var known: std.ArrayList(models.Chapter) = .empty;
        for (existing) |ch| if (ch.remote) |r| try known.append(a, r);
        return (try self.backend.run(a, .{ .update = .{ .source = source, .manga = remote, .chapters = known.items, .details = details } }, status)).update orelse error.InvalidReply;
    }

    // Network work can overlap; apply each result on the parent task while its
    // scratch arena is alive, under the library's existing transaction lock.
    fn syncTitle(self: *Engine, a: std.mem.Allocator, source: i64, update: models.MangaUpdate, schedule: Schedule, started: u64, fetched: u64) !Fetched {
        try self.io.checkCancel();
        const Edit = struct {
            source: i64,
            update: models.MangaUpdate,
            now: i64,
            options: library.SyncOptions,
            schedule: Schedule,
            utc_offset_s: i32,
            synced: *library.Synced,
            fn apply(edit: @This(), arena: std.mem.Allocator, current: library.Library) !?library.Library {
                edit.synced.* = try library.syncSource(arena, current, edit.source, edit.update.manga, edit.update.chapters, edit.now, edit.options);
                const lib = edit.synced.library;
                const index = lib.find(edit.synced.manga_id).?;
                const m = lib.manga[index];
                // Mihon reschedules after a change, and otherwise only when
                // asked, never estimated, or behind the update window.
                if (!edit.synced.changed and !edit.schedule.manual and m.fetch_interval != 0 and
                    !(edit.schedule.window != null and (m.next_update == 0 or m.next_update < edit.schedule.window.?.lower))) return if (edit.synced.changed) lib else null;
                const next = try fetch_interval.update(arena, .{
                    .chapters = try scheduleDates(arena, m),
                    .fetch_interval = m.fetch_interval,
                    .next_update_ms = m.next_update,
                    .last_update_ms = m.last_update,
                    .found_release = edit.synced.found_release,
                    .now_ms = edit.now,
                    .utc_offset_s = edit.utc_offset_s,
                    .fetch_window = edit.schedule.window,
                });
                if (next.fetch_interval == m.fetch_interval and next.next_update_ms == m.next_update) return if (edit.synced.changed) lib else null;
                const titles = try arena.dupe(library.Manga, lib.manga);
                titles[index].fetch_interval = next.fetch_interval;
                titles[index].next_update = next.next_update_ms;
                var result = lib;
                result.manga = titles;
                edit.synced.library = result;
                return result;
            }
        };
        const s = try self.loadSettings(a);
        var synced: library.Synced = undefined;
        _ = try self.store.update(a, Edit{
            .source = source,
            .update = update,
            .now = wallMillis(self.io),
            .options = .{ .mark_duplicate_read = s.update.mark_new_duplicates_read, .update_title = s.update.titles },
            .schedule = schedule,
            .utc_offset_s = self.options.utc_offset_s,
            .synced = &synced,
        }, Edit.apply);
        log.info("refresh chapters={d} new={d} source_ms={d} save_ms={d}", .{ update.chapters.len, synced.new_chapters.len, fetched - started, millis(self.io) - fetched });
        return .{ .manga_id = synced.manga_id, .new_chapters = synced.new_chapters };
    }

    /// Refreshes library titles as Mihon's library update does: favorites
    /// only, in the categories the settings allow (or just `category`),
    /// skipping titles that fetch once, are completed, have unread chapters,
    /// were never started, or aren't expected to release yet, as the
    /// settings say. A title that fails is reported and the rest go on.
    fn updateLibrary(self: *Engine, job: *Job, category: ?u32) !void {
        const a = job.arena.allocator();
        const current = try self.store.load(a);
        var s = try self.loadSettings(a);
        s.update.last_run = wallMillis(self.io);
        try self.saveSettings(s);
        const window = fetch_interval.window(wallMillis(self.io), self.options.utc_offset_s);
        var queue: std.ArrayList(library.Manga) = .empty;
        var skipped: usize = 0;
        for (current.manga) |book| {
            if (!book.favorite or book.local() or book.remote == null) continue;
            const allowed = if (category) |c| for (if (book.categories.len == 0) &[_]u32{0} else book.categories) |own| {
                if (own == c) break true;
            } else false else settings.categoryAllowed(book.categories, s.update.categories, s.update.exclude_categories);
            if (!allowed) continue;
            const counts = book.counts();
            const skip = (book.onlyFetchOnce() and counts.total > 0) or
                (s.update.skip_completed and book.status() == 2) or
                (s.update.skip_unread and counts.unread != 0) or
                (s.update.skip_not_started and counts.total > 0 and counts.read == 0) or
                (s.update.skip_outside_release_period and book.next_update != 0 and fetch_interval.outsideReleasePeriod(book.next_update, window));
            if (skip) {
                skipped += 1;
                continue;
            }
            try queue.append(a, book);
        }
        std.mem.sort(library.Manga, queue.items, {}, struct {
            fn less(_: void, x: library.Manga, y: library.Manga) bool {
                return std.ascii.lessThanIgnoreCase(x.title, y.title);
            }
        }.less);
        const Refresh = struct {
            job: *Job,
            books: []const library.Manga,
            schedule: Schedule,
            failures: []?UpdateError,
            updated: usize = 0,
            done: usize = 0,
            chapters: [][]const []const u8,

            const Outcome = union(enum) {
                fetched: struct { update: models.MangaUpdate, started: u64, fetched: u64 },
                failure: []const u8,
            };
            fn work(ctx: *@This(), scratch: std.mem.Allocator, i: usize) !Outcome {
                const book = ctx.books[i];
                const engine = ctx.job.engine;
                const started = millis(engine.io);
                tachi.setLastError("");
                const update = engine.fetchTitleUpdate(scratch, book.source_id.?, book.remote.?, book.chapters, ctx.schedule.details, ctx.job.status()) catch |err| switch (err) {
                    error.Canceled, error.OutOfMemory => return err,
                    else => return .{ .failure = try std.fmt.allocPrint(scratch, "{s}: {s}", .{ @errorName(err), tachi.lastError() }) },
                };
                return .{ .fetched = .{ .update = update, .started = started, .fetched = millis(engine.io) } };
            }
            fn publish(ctx: *@This(), i: usize, outcome: Outcome, _: *std.heap.ArenaAllocator) !void {
                const book = ctx.books[i];
                const allocator = ctx.job.arena.allocator();
                var failure: ?[]const u8 = null;
                switch (outcome) {
                    .failure => |message| failure = message,
                    .fetched => |result| {
                        tachi.setLastError("");
                        if (ctx.job.engine.syncTitle(allocator, book.source_id.?, result.update, ctx.schedule, result.started, result.fetched)) |fetched| {
                            ctx.updated += 1;
                            ctx.chapters[i] = fetched.new_chapters;
                        } else |err| switch (err) {
                            error.Canceled, error.OutOfMemory => return err,
                            else => failure = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ @errorName(err), tachi.lastError() }),
                        }
                    },
                }
                if (failure) |message| {
                    ctx.failures[i] = .{ .manga_id = book.id, .title = book.title, .message = try allocator.dupe(u8, message) };
                    log.warn("update {s}: {s}", .{ book.title, message });
                }
                ctx.done += 1;
                ctx.job.pages_done.store(ctx.done, .release);
            }
        };
        var refresh: Refresh = .{
            .job = job,
            .books = queue.items,
            .schedule = .{ .window = window, .details = s.update.metadata },
            .failures = try a.alloc(?UpdateError, queue.items.len),
            .chapters = try a.alloc([]const []const u8, queue.items.len),
        };
        @memset(refresh.failures, null);
        @memset(refresh.chapters, &.{});
        job.pages_total.store(queue.items.len, .release);
        try parallel.run(self.gpa, self.io, queue.items.len, self.options.parallelism, &refresh, Refresh.work, Refresh.publish);
        // Preserve title dispatch order in final reports and automatic downloads.
        var errors: std.ArrayList(UpdateError) = .empty;
        var new_chapters: std.ArrayList([]const u8) = .empty;
        for (refresh.failures, refresh.chapters) |failure, chapters| {
            if (failure) |err| try errors.append(a, err);
            try new_chapters.appendSlice(a, chapters);
        }
        try self.autoDownload(job, new_chapters.items);
        if (new_chapters.items.len > 0) {
            var latest = try self.loadSettings(a);
            latest.updates.unseen += @intCast(new_chapters.items.len);
            try self.saveSettings(latest);
        }
        job.result = .{
            .library_changed = refresh.updated > 0,
            .new_chapters = new_chapters.items,
            .update_errors = errors.items,
            .update_skipped = skipped,
            .message = if (errors.items.len == 0) "Library updated" else try std.fmt.allocPrint(a, "Library updated; {d} title(s) failed", .{errors.items.len}),
        };
    }

    const DownloadDestination = struct { sd_card: bool };

    fn downloadDestinationPath(self: *Engine, a: std.mem.Allocator, chapter_id: []const u8) ![]const u8 {
        return std.fmt.allocPrint(a, "{s}/downloads/{x}/destination.json", .{ self.options.dir, std.hash.Wyhash.hash(0, chapter_id) });
    }

    fn savedDownloadDestination(self: *Engine, a: std.mem.Allocator, chapter_id: []const u8) !?DownloadDestination {
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, try self.downloadDestinationPath(a, chapter_id), a, .limited(4096)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return try std.json.parseFromSliceLeaky(DownloadDestination, a, bytes, models.parse_options);
    }

    pub const DownloadTarget = struct { dir: []const u8, sd_card: bool };

    /// The destination of a queued or foreground download, including its original volume.
    pub fn downloadTarget(self: *Engine, a: std.mem.Allocator, chapter_id: []const u8) !DownloadTarget {
        const settings_value = try self.loadSettings(a);
        // Resume an existing partial download on its original volume.
        const internal_partial = try downloads.resumeProgress(a, self.io, self.options.dir, "downloads", chapter_id);
        const sd_partial = if (self.sdAvailable()) try downloads.resumeProgress(a, self.io, self.options.sd_dir.?, "downloads", chapter_id) else null;
        const saved_destination = try self.savedDownloadDestination(a, chapter_id);
        const use_sd = if (saved_destination) |saved| saved.sd_card else if (internal_partial != null) false else if (sd_partial != null) true else settings_value.downloads.storage == .sd_card;
        if (use_sd and !self.sdAvailable()) return error.StorageUnavailable;
        return .{ .dir = if (use_sd) self.options.sd_dir.? else self.options.dir, .sd_card = use_sd };
    }

    /// Downloads a library chapter for `job`, resuming saved pages, and
    /// records its pages in the library.
    pub fn downloadChapter(self: *Engine, job: *Job, chapter_id: []const u8) !void {
        const a = job.arena.allocator();
        const chapter_started = millis(self.io);
        const target = try self.downloadTarget(a, chapter_id);
        const use_sd = target.sd_card;
        const destination_file = try self.downloadDestinationPath(a, chapter_id);
        const current = try self.store.load(a);
        const found = findChapter(current, chapter_id) orelse return error.UnknownChapter;
        const source = found.manga.source_id orelse return error.LocalChapter;
        const remote = found.chapter.remote orelse return error.MissingChapterMetadata;
        try Io.Dir.cwd().createDirPath(self.io, std.fs.path.dirname(destination_file).?);
        // Keep the original target even when a removable card disappears before retry.
        try library.writeJsonAtomic(a, self.io, destination_file, DownloadDestination{ .sd_card = use_sd });
        job.fallback_source = source;
        const plan = (job.call(.{ .image_requests = .{ .source = source, .chapter = remote } }) catch |err| {
            if (err == error.ExtensionError and std.mem.endsWith(u8, tachi.lastError(), "HTTP error 404")) {
                job.failure = "This chapter is no longer on the source. Refresh chapters to update the list.";
                return error.ChapterRemoved;
            }
            return err;
        }).image_requests;
        const planning_ms = millis(self.io) - chapter_started;
        if (plan.len == 0) return error.EmptyChapter;
        // Native pages need no JVM; a hand-back starts it again on demand.
        if (self.options.release_jvm and downloads.allNative(plan)) self.backend.release();
        defer if (self.options.release_jvm) self.backend.release();
        job.pages_total.store(plan.len, .release);
        const chapter = try downloads.downloadChapter(self.gpa, a, self.io, plan, .{
            .dir = target.dir,
            .chapter_id = chapter_id,
            .ca_file = self.options.ca_file,
            .parallelism = try self.pageParallelism(a),
            .fallback = .{ .context = job, .fetch = Job.fetchFallback },
            .progress = .{ .context = job, .report = Job.reportPages },
            .reuse = if (use_sd) null else cache_pages,
        });
        const stored_pages = if (use_sd) blk: {
            const pages = try a.alloc([]const u8, chapter.pages.len);
            for (chapter.pages, pages) |page, *stored| stored.* = try std.fmt.allocPrint(a, "sdcard/{s}", .{page});
            break :blk pages;
        } else chapter.pages;
        const s = chapter.stats;
        log.info("chapter pages={d}/{d} resumed={d} native={d} bytes={d} network_ms={d} disk_ms={d} elapsed_ms={d} planning_ms={d} worker_start_ms={d} total_elapsed_ms={d}", .{ job.pages_done.load(.acquire), plan.len, s.resumed, s.native, s.bytes, s.network_ms, s.disk_ms, s.elapsed_ms, planning_ms, job.start_ms, millis(self.io) - chapter_started });
        const Edit = struct {
            id: []const u8,
            pages: []const []const u8,
            fn apply(edit: @This(), arena: std.mem.Allocator, lib: library.Library) !?library.Library {
                return library.setPages(arena, lib, edit.id, edit.pages);
            }
        };
        _ = try self.store.update(a, Edit{ .id = chapter_id, .pages = stored_pages }, Edit.apply);
        job.result = .{ .library_changed = true, .manga_id = found.manga.id, .message = "Chapter downloaded" };
    }
};

const Found = struct { manga: library.Manga, chapter: library.Chapter };

fn contains(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
    return false;
}

fn readingOf(ch: library.Chapter) library.Reading {
    return .{ .id = ch.id, .page = ch.last_page_read, .read = ch.read, .bookmark = ch.bookmark, .last_read = ch.last_read, .read_ms = ch.read_ms };
}

/// The chapters of `manga` Mihon's deletion settings let go: not
/// bookmarked ones unless `remove_bookmarked`, and not read ones if the
/// title is in a category in `remove_exclude_categories`.
fn deletable(a: std.mem.Allocator, s: settings.Settings, manga: library.Manga, chapters: []const library.Chapter) ![]const []const u8 {
    const protect_read = !settings.categoryAllowed(manga.categories, &.{}, s.downloads.remove_exclude_categories);
    var ids: std.ArrayList([]const u8) = .empty;
    for (chapters) |ch| {
        if (protect_read and ch.read) continue;
        if (!s.downloads.remove_bookmarked and ch.bookmark) continue;
        try ids.append(a, ch.id);
    }
    return ids.items;
}

/// The release history a title's schedule is estimated from: chapters of
/// groups not excluded that the source still lists.
fn scheduleDates(arena: std.mem.Allocator, m: library.Manga) ![]const fetch_interval.ChapterDates {
    var dates: std.ArrayList(fetch_interval.ChapterDates) = .empty;
    for (m.chapters) |ch| if (!m.excludes(ch.scanlator) and !ch.orphaned) try dates.append(arena, .{
        .upload_ms = if (ch.date_upload == 0) null else ch.date_upload,
        .fetch_ms = ch.date_fetch,
    });
    return dates.items;
}

/// Mihon's global search order: sources with results, then pinned ones,
/// then by name and language.
fn sortSearch(results: []SearchResult) void {
    std.mem.sort(SearchResult, results, {}, struct {
        fn less(_: void, a: SearchResult, b: SearchResult) bool {
            const a_hits = a.failure == null and a.mangas.len > 0;
            const b_hits = b.failure == null and b.mangas.len > 0;
            if (a_hits != b_hits) return a_hits;
            if (a.pinned != b.pinned) return a.pinned;
            return switch (std.ascii.orderIgnoreCase(a.source.name, b.source.name)) {
                .lt => true,
                .gt => false,
                .eq => std.mem.lessThan(u8, a.source.lang, b.source.lang),
            };
        }
    }.less);
}

fn sortByOrder(categories: []library.Category) void {
    std.mem.sort(library.Category, categories, {}, struct {
        fn less(_: void, x: library.Category, y: library.Category) bool {
            return x.order < y.order;
        }
    }.less);
}
const Fetched = struct { manga_id: []const u8, new_chapters: []const []const u8 };

/// How a fetch reschedules the title's next update, and what it fetches.
const Schedule = struct {
    /// Details as well as chapters; library updates fetch details only
    /// with `auto_update_metadata`.
    details: bool = true,
    /// The user asked for it, so the schedule is estimated again.
    manual: bool = false,
    /// A library update's window, kept across its titles.
    window: ?fetch_interval.Window = null,
};

fn findChapter(lib: library.Library, chapter_id: []const u8) ?Found {
    for (lib.manga) |m| for (m.chapters) |ch| {
        if (std.mem.eql(u8, ch.id, chapter_id)) return .{ .manga = m, .chapter = ch };
    };
    return null;
}

/// One operation in the background. Watch `phase`, `pages_done` and
/// `pages_total`, `join` it, then read `result` or `failure`.
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    retained_arenas: std.ArrayList(std.heap.ArenaAllocator) = .empty,
    engine: *Engine,
    request: Request,
    result: Result = .{},
    /// Why the job failed; null if it succeeded.
    failure: ?[]const u8 = null,
    future: ?Io.Future(void) = null,
    done: std.atomic.Value(bool) = .init(false),
    phase: std.atomic.Value(Phase) = .init(.operation),
    extension_lock: std.atomic.Mutex = .unlocked,
    extension_buf: [64]u8 = undefined,
    extension_len: usize = 0,
    pages_done: std.atomic.Value(usize) = .init(0),
    pages_total: std.atomic.Value(usize) = .init(0),
    /// A `read` job's pages so far; read them with `pageStates`.
    page_lock: std.atomic.Mutex = .unlocked,
    page_states: []PageState = &.{},
    /// The source pages that need the JVM are fetched through.
    fallback_source: i64 = 0,
    /// A global search's results so far; read them with `searchResults`.
    search_lock: std.atomic.Mutex = .unlocked,
    search_partial: std.ArrayList(SearchResult) = .empty,
    /// Milliseconds the JVM took to start for this job, if it had to.
    start_ms: u64 = 0,
    starting_at: u64 = 0,
    status_lock: std.atomic.Mutex = .unlocked,

    /// Copies `request`, so the caller's memory may go away.
    pub fn start(engine: *Engine, request: Request) !*Job {
        if (engine.paused.load(.acquire)) return error.EnginePaused;
        const job = try engine.gpa.create(Job);
        errdefer engine.gpa.destroy(job);
        job.* = .{ .arena = .init(engine.gpa), .engine = engine, .request = undefined };
        errdefer job.arena.deinit();
        const a = job.arena.allocator();
        const json = try std.json.Stringify.valueAlloc(a, request, .{});
        job.request = try std.json.parseFromSliceLeaky(Request, a, json, models.parse_options);
        if (engine.execute_fn == null and request.usesBackend() and !engine.backend.warm()) job.phase.store(.starting, .release);
        job.future = try engine.io.concurrent(run, .{job});
        return job;
    }

    fn run(self: *Job) void {
        defer self.done.store(true, .release);
        tachi.setLastError("");
        const execute = self.engine.execute_fn orelse Engine.execute;
        execute(self.engine, self) catch |err| {
            if (self.failure == null) {
                const detail = tachi.lastError();
                self.failure = (if (detail.len > 0 and err != error.Canceled)
                    std.fmt.allocPrint(self.arena.allocator(), "{s}: {s}", .{ @errorName(err), detail })
                else
                    std.fmt.allocPrint(self.arena.allocator(), "{s}", .{@errorName(err)})) catch "Operation failed (out of memory)";
            }
            if (!@import("builtin").is_test) log.warn("{s}", .{self.failure.?});
        };
    }

    /// Runs an extension call for this job, reporting its phases.
    pub fn call(self: *Job, c: be.Call) !be.Reply {
        return self.engine.backend.run(self.arena.allocator(), c, self.status());
    }

    fn status(self: *Job) be.Status {
        return .{ .context = self, .starting = starting, .ready = ready, .loading = loading };
    }
    fn starting(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        while (!self.status_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.status_lock.unlock();
        self.starting_at = tachi.worker.tachi_now_ms();
        self.phase.store(.starting, .release);
    }
    fn ready(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
        while (!self.status_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.status_lock.unlock();
        if (self.starting_at != 0 and self.start_ms == 0) self.start_ms = tachi.worker.tachi_now_ms() - self.starting_at;
        self.phase.store(.operation, .release);
    }
    fn loading(context: *anyopaque, extension: ?[]const u8) void {
        const self: *Job = @ptrCast(@alignCast(context));
        if (extension) |name| self.setExtensionLoading(name) else self.setPhase(.operation);
    }

    /// Sets the phase; for executors (`Engine.execute_fn`) that report their own.
    pub fn setPhase(self: *Job, phase: Phase) void {
        self.phase.store(phase, .release);
    }

    /// Reports that `name` is loading; see `extensionLoading`.
    pub fn setExtensionLoading(self: *Job, name: []const u8) void {
        while (!self.extension_lock.tryLock()) std.atomic.spinLoopHint();
        const n = @min(name.len, self.extension_buf.len);
        @memcpy(self.extension_buf[0..n], name[0..n]);
        self.extension_len = n;
        self.extension_lock.unlock();
        self.phase.store(.extension_loading, .release);
    }

    /// Fails with `Canceled` once `cancel` has been called.
    pub fn checkCancelled(self: *Job) !void {
        try self.engine.io.checkCancel();
    }

    fn fetchFallback(context: *anyopaque, gpa: std.mem.Allocator, request: models.ImageRequest, reason: []const u8) anyerror![]u8 {
        _ = reason;
        const self: *Job = @ptrCast(@alignCast(context));
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const reply = try self.engine.backend.run(arena.allocator(), .{ .image = .{ .source = self.fallback_source, .page = request.page, .url = request.url, .cookies = request.cookies } }, self.status());
        return gpa.dupe(u8, reply.image orelse return error.InvalidImageResponse);
    }

    pub const PageState = union(enum) {
        loading,
        /// Path relative to the library directory; see `Engine.pagePath`.
        ready: []const u8,
        failed: []const u8,
    };

    /// A `read` job's pages so far; valid until `deinit`.
    pub fn pageStates(self: *Job, arena: std.mem.Allocator) ![]PageState {
        while (!self.page_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.page_lock.unlock();
        return arena.dupe(PageState, self.page_states);
    }

    fn setPages(self: *Job, count: usize) void {
        const states = self.arena.allocator().alloc(PageState, count) catch return;
        @memset(states, .loading);
        while (!self.page_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.page_lock.unlock();
        self.page_states = states;
    }

    fn pageReady(self: *Job, index: usize, path: []const u8) void {
        while (!self.page_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.page_lock.unlock();
        if (index < self.page_states.len) self.page_states[index] = .{ .ready = path };
    }

    fn reportReady(context: *anyopaque, index: usize, path: []const u8) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.pageReady(index, path);
    }

    fn reportFailed(context: *anyopaque, index: usize, err: anyerror) void {
        const self: *Job = @ptrCast(@alignCast(context));
        const detail = tachi.lastError();
        const message = (if (detail.len > 0)
            std.fmt.allocPrint(self.arena.allocator(), "{s}: {s}", .{ @errorName(err), detail })
        else
            std.fmt.allocPrint(self.arena.allocator(), "{s}", .{@errorName(err)})) catch @errorName(err);
        while (!self.page_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.page_lock.unlock();
        if (index < self.page_states.len) self.page_states[index] = .{ .failed = message };
    }

    fn reportPages(context: *anyopaque, done: usize, total: usize) void {
        const self: *Job = @ptrCast(@alignCast(context));
        self.pages_total.store(total, .release);
        self.pages_done.store(done, .release);
    }

    /// The extension named while `phase` is `.extension_loading`, copied into `buf`.
    pub fn extensionLoading(self: *Job, buf: []u8) []const u8 {
        while (!self.extension_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.extension_lock.unlock();
        const n = @min(self.extension_len, buf.len);
        @memcpy(buf[0..n], self.extension_buf[0..n]);
        return buf[0..n];
    }

    /// A global search's results so far, in the order sources answered;
    /// valid until `deinit`.
    pub fn searchResults(self: *Job, arena: std.mem.Allocator) ![]SearchResult {
        while (!self.search_lock.tryLock()) std.atomic.spinLoopHint();
        defer self.search_lock.unlock();
        return arena.dupe(SearchResult, self.search_partial.items);
    }

    /// Cancels this job's Io task and waits for unwind. Foreign code must
    /// cooperate, or use a worker backend for process termination. A completed
    /// job can still succeed; downloaded pages remain available for a retry.
    pub fn cancel(self: *Job) void {
        // Backend waits translate this task's cancellation to its own JVM
        // operation (or worker). A backend-wide cancel could stop another job.
        if (self.future) |*future| future.cancel(self.engine.io);
    }

    pub fn join(self: *Job) void {
        if (self.future) |*future| future.await(self.engine.io);
        self.future = null;
    }

    /// Keeps worker output alive for this job; called only during serial publication.
    fn keepArena(self: *Job, scratch: *std.heap.ArenaAllocator) !void {
        try self.retained_arenas.append(self.arena.allocator(), scratch.*);
        scratch.* = .init(self.engine.gpa);
    }

    pub fn deinit(self: *Job) void {
        self.join();
        const gpa = self.engine.gpa;
        for (self.retained_arenas.items) |*arena| arena.deinit();
        self.arena.deinit();
        gpa.destroy(self);
    }
};

fn millis(io: Io) u64 {
    return @intCast(@divTrunc(Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
}

fn wallMillis(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}

test "engine adds, downloads, records progress and indexes local series through a fake backend" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    try tmp.dir.createDirPath(io, "local/Mine/Ch 1");
    try tmp.dir.writeFile(io, .{ .sub_path = "local/Mine/Ch 1/01.png", .data = "x" });

    const Fake = struct {
        calls: usize = 0,
        fn run(ptr: *anyopaque, a: std.mem.Allocator, c: be.Call, status: ?be.Status) anyerror!be.Reply {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (status) |s| s.ready(s.context);
            return switch (c) {
                .update => |u| .{ .update = .{ .manga = .{ .url = u.manga.url, .title = "Fetched" }, .chapters = &.{ .{ .url = "/c2", .name = "Chapter 2" }, .{ .url = "/c1", .name = "Chapter 1" } } } },
                .image_requests => .{ .image_requests = &.{
                    .{ .page = .{ .index = 0, .url = "/p1" }, .url = "jvm://only", .method = "GET", .headers = &.{} },
                } },
                .image => .{ .image = try a.dupe(u8, "\x89PNG\r\n\x1a\nfake") },
                else => error.Unexpected,
            };
        }
        fn yes(_: *anyopaque) bool {
            return true;
        }
        fn none(_: *anyopaque) void {}
    };
    var fake: Fake = .{};
    const backend: be.Backend = .{ .ptr = &fake, .vtable = &.{ .run = Fake.run, .warm = Fake.yes, .cancel = Fake.none, .release = Fake.none, .idle = Fake.none } };
    var engine: Engine = .init(std.testing.allocator, io, backend, .{ .dir = dir });

    const add = try Job.start(&engine, .{ .add = .{ .source = 7, .manga = .{ .url = "/m", .title = "M" } } });
    add.join();
    try std.testing.expect(add.failure == null);
    try std.testing.expectEqualStrings("7:/m", add.result.manga_id.?);
    add.deinit();

    const download = try Job.start(&engine, .{ .download = "7:/c1" });
    download.join();
    try std.testing.expect(download.failure == null);
    try std.testing.expectEqual(1, download.pages_done.load(.acquire));
    download.deinit();

    try engine.setProgress("7:/c1", 0, true, 0);
    const scan = try Job.start(&engine, .scan_local);
    scan.join();
    scan.deinit();

    const lib = try engine.loadLibrary(arena);
    try std.testing.expectEqual(2, lib.manga.len);
    const m = lib.manga[lib.find("7:/m").?];
    try std.testing.expectEqualStrings("Fetched", m.title);
    try std.testing.expectEqualStrings("Chapter 1", m.chapters[0].title);
    try std.testing.expect(m.chapters[0].read);
    try std.testing.expectEqual(1, m.chapters[0].pages.len);
    const page = try engine.pagePath(arena, m.chapters[0].pages[0]);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, page, arena, .limited(64));
    try std.testing.expect(std.mem.startsWith(u8, bytes, "\x89PNG"));
    try std.testing.expectEqualStrings("local:Mine", lib.manga[lib.find("local:Mine").?].id);

    // The queue downloads what is left, oldest first, and empties.
    try std.testing.expectEqual(1, try engine.queue.enqueue(&engine, &.{ "7:/c2", "7:/c1" }, true));
    var waited: usize = 0;
    while ((try engine.queue.snapshot(&engine, arena)).len > 0) : (waited += 1) {
        if (waited > 5000) return error.QueueStuck;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    engine.queue.deinit(&engine);
    const after = try engine.loadLibrary(arena);
    try std.testing.expectEqual(1, after.manga[after.find("7:/m").?].chapters[1].pages.len);
}

test "engine marks chapters, keeps history, manages categories and deletes downloads as Mihon does" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    var engine: Engine = .init(std.testing.allocator, io, be.none, .{ .dir = dir });
    defer engine.queue.deinit(&engine);

    var chapters: [4]library.Chapter = undefined;
    for (&chapters, 0..) |*ch, i| {
        const page = try std.fmt.allocPrint(a, "downloads/c{d}/p/0001.png", .{i + 1});
        try tmp.dir.createDirPath(io, std.fs.path.dirname(page).?);
        try tmp.dir.writeFile(io, .{ .sub_path = page, .data = "x" });
        ch.* = .{ .id = try std.fmt.allocPrint(a, "1:/c{d}", .{i + 1}), .title = try std.fmt.allocPrint(a, "Chapter {d}", .{i + 1}), .number = @floatFromInt(i + 1), .source_order = @intCast(3 - i), .pages = try a.dupe([]const u8, &.{page}) };
    }
    chapters[3].number = 3; // a second Chapter 3
    try engine.store.save(a, .{ .manga = &.{.{ .id = "1:/m", .title = "M", .source_id = 1, .chapters = &chapters }} });

    // Marking read changes unread chapters; unread also clears a page.
    try engine.setProgress("1:/c2", 4, false, 1000);
    try std.testing.expectEqual(2, try engine.markPreviousRead("1:/c3"));
    try std.testing.expectEqual(0, try engine.markRead(&.{"1:/c1"}, true));
    try std.testing.expectEqual(1, try engine.markRead(&.{"1:/c2"}, false));
    var lib = try engine.loadLibrary(a);
    try std.testing.expect(lib.manga[0].chapters[0].read);
    try std.testing.expect(!lib.manga[0].chapters[1].read);
    try std.testing.expectEqual(0, lib.manga[0].chapters[1].last_page_read);
    try std.testing.expectEqual(1000, lib.manga[0].chapters[1].read_ms);

    // History: removing a chapter keeps its reading time, clearing all doesn't.
    try std.testing.expectEqual(1, (try engine.history(a, "")).len);
    try engine.removeHistory(.{ .chapter = "1:/c2" });
    lib = try engine.loadLibrary(a);
    try std.testing.expectEqual(0, lib.manga[0].chapters[1].last_read);
    try std.testing.expectEqual(1000, lib.manga[0].chapters[1].read_ms);
    try engine.removeHistory(.all);
    try std.testing.expectEqual(0, (try engine.loadLibrary(a)).manga[0].chapters[1].read_ms);

    // Bookmarked chapters keep their downloads by default.
    try std.testing.expectEqual(1, try engine.setBookmark(&.{"1:/c2"}, true));
    try std.testing.expectEqual(1, try engine.deleteDownloads(&.{ "1:/c1", "1:/c2" }));
    lib = try engine.loadLibrary(a);
    try std.testing.expect(!lib.manga[0].chapters[0].downloaded());
    try std.testing.expect(lib.manga[0].chapters[1].downloaded());
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "downloads/c1", .{}));

    // Finishing chapter 3 deletes it on leaving the reader, with
    // remove_after_read_slots 0, and marks the other Chapter 3 read.
    var s = try engine.loadSettings(a);
    s.downloads.remove_after_read_slots = 0;
    s.update.mark_existing_duplicates_read = true;
    try engine.saveSettings(s);
    try engine.pageShown(.{ .chapter_id = "1:/c3", .page = 0, .pages = 2 });
    try engine.pageShown(.{ .chapter_id = "1:/c3", .page = 1, .pages = 2 });
    lib = try engine.loadLibrary(a);
    try std.testing.expect(lib.manga[0].chapters[2].downloaded());
    try std.testing.expect(lib.manga[0].chapters[3].read);
    try engine.leaveReader();
    lib = try engine.loadLibrary(a);
    try std.testing.expect(!lib.manga[0].chapters[2].downloaded());
    try std.testing.expect(!lib.manga[0].chapters[3].downloaded());

    // Categories: create, reorder, assign, delete.
    const first = try engine.createCategory("First");
    const second = try engine.createCategory("Second");
    try std.testing.expectError(error.DuplicateCategory, engine.createCategory("First"));
    try engine.moveCategory(second, 0);
    try engine.setCategories(&.{"1:/m"}, &.{ first, second });
    var groups = try engine.libraryView(a, "");
    try std.testing.expectEqual(2, groups.len);
    try std.testing.expectEqualStrings("Second", groups[0].category.name);
    try engine.deleteCategory(second);
    lib = try engine.loadLibrary(a);
    try std.testing.expectEqualSlices(u32, &.{first}, lib.manga[0].categories);
    try std.testing.expectEqual(0, lib.categories[0].order);
    try engine.setLibrarySort(0, .{ .mode = .total_chapters, .ascending = false });
    lib = try engine.loadLibrary(a);
    try std.testing.expectEqual(views.SortMode.total_chapters, views.LibrarySort.decode(lib.categories[0].flags).mode);
    try std.testing.expectEqual(0, (try engine.libraryView(a, "zzz"))[0].entries.len);

    // Removing keeps the title for its history until the database is cleared.
    const remove = try Job.start(&engine, .{ .remove = "1:/m" });
    remove.join();
    remove.deinit();
    groups = try engine.libraryView(a, "");
    try std.testing.expectEqual(0, groups[0].entries.len);
    try std.testing.expectEqual(0, try engine.clearDatabase(true));
    try std.testing.expectEqual(1, try engine.clearDatabase(false));
}

test "engine searches sources globally and migrates a title as Mihon does" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);

    const Fake = struct {
        second: Io.Event = .unset,
        fn run(ptr: *anyopaque, arena: std.mem.Allocator, c: be.Call, status: ?be.Status) anyerror!be.Reply {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (status) |s| s.ready(s.context);
            const info: models.SourceInfo = .{ .id = "", .name = "", .lang = "en", .supportsLatest = true, .isConfigurable = false, .className = "", .extensionPkg = "" };
            return switch (c) {
                .sources => blk: {
                    const list = try arena.alloc(models.SourceInfo, 3);
                    for (list, [_][]const u8{ "1", "2", "3" }, [_][]const u8{ "Old", "New", "Broken" }) |*s, id, name| {
                        s.* = info;
                        s.id = id;
                        s.name = name;
                    }
                    break :blk .{ .sources = list };
                },
                .browse => |b| switch (b.source) {
                    3 => error.ExtensionError,
                    else => blk: {
                        // Source one cannot finish until source two starts.
                        if (b.source == 1) try self.second.wait(std.testing.io);
                        if (b.source == 2) self.second.set(std.testing.io);
                        const mangas = try arena.dupe(models.Manga, &.{ .{ .url = "/x", .title = "X" }, .{ .url = "/x", .title = "X again" } });
                        mangas[0].title = try arena.dupe(u8, "X");
                        break :blk .{ .page = .{ .mangas = mangas, .hasNextPage = false } };
                    },
                },
                .update => |u| .{ .update = .{ .manga = .{ .url = u.manga.url, .title = "Target" }, .chapters = &.{
                    .{ .url = "/t3", .name = "Chapter 3" },
                    .{ .url = "/t2", .name = "Chapter 2" },
                    .{ .url = "/t1", .name = "Chapter 1" },
                } } },
                else => error.Unexpected,
            };
        }
        fn yes(_: *anyopaque) bool {
            return true;
        }
        fn none(_: *anyopaque) void {}
    };
    var state: Fake = .{};
    const backend: be.Backend = .{ .ptr = &state, .vtable = &.{ .run = Fake.run, .warm = Fake.yes, .cancel = Fake.none, .release = Fake.none, .idle = Fake.none } };
    var engine: Engine = .init(std.testing.allocator, io, backend, .{ .dir = dir });
    defer engine.queue.deinit(&engine);

    // Pinned only by default: nothing pinned, nothing searched.
    const none_pinned = try Job.start(&engine, .{ .global_search = .{ .query = "x" } });
    none_pinned.join();
    try std.testing.expectEqual(0, none_pinned.result.search.len);
    none_pinned.deinit();
    try engine.setSourcePinned(3, true);
    const search = try Job.start(&engine, .{ .global_search = .{ .query = "x", .pinned_only = false } });
    search.join();
    defer search.deinit();
    try std.testing.expect(search.failure == null);
    const results = search.result.search;
    try std.testing.expect(state.second.isSet());
    try std.testing.expectEqual(3, results.len);
    try std.testing.expectEqual(3, search.pages_done.load(.acquire));
    try std.testing.expectEqualStrings("X", results[0].mangas[0].title);
    try std.testing.expectEqualStrings("New", results[0].source.name);
    try std.testing.expectEqual(1, results[0].mangas.len);
    try std.testing.expectEqualStrings("Old", results[1].source.name);
    try std.testing.expect(results[2].failure != null);

    // Migration carries read state up to the highest read number,
    // bookmarks, categories and notes, and takes the old title out.
    var old_chapters = [_]library.Chapter{
        .{ .id = "1:/o1", .title = "Chapter 1", .number = 1, .read = true, .date_fetch = 11 },
        .{ .id = "1:/o2", .title = "Chapter 2", .number = 2, .read = true, .bookmark = true, .date_fetch = 22 },
    };
    try engine.store.save(a, .{
        .manga = &.{.{ .id = "1:/old", .title = "Old", .source_id = 1, .remote = .{ .url = "/old", .title = "Old" }, .chapters = &old_chapters, .categories = &.{5}, .notes = "mine", .date_added = 1000, .chapter_flags = 0x100 }},
        .categories = &.{.{ .id = 5, .name = "Five" }},
    });
    const job = try Job.start(&engine, .{ .migrate = .{ .from = "1:/old", .source = 2, .manga = .{ .url = "/new", .title = "New" } } });
    job.join();
    defer job.deinit();
    try std.testing.expect(job.failure == null);
    const lib = try engine.loadLibrary(a);
    const old = lib.manga[lib.find("1:/old").?];
    const new = lib.manga[lib.find("2:/new").?];
    try std.testing.expect(!old.favorite);
    try std.testing.expect(new.favorite);
    try std.testing.expectEqual(1000, new.date_added);
    try std.testing.expectEqualStrings("mine", new.notes);
    try std.testing.expectEqualSlices(u32, &.{5}, new.categories);
    try std.testing.expectEqual(0x100, new.chapter_flags);
    for (new.chapters) |ch| {
        try std.testing.expectEqual(ch.number <= 2, ch.read);
        try std.testing.expectEqual(ch.number == 2, ch.bookmark);
    }
}

test "engine reads a chapter online through the chapter cache" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);

    const Fake = struct {
        plans: usize = 0,
        images: std.atomic.Value(usize) = .init(0),
        fail_page: ?i32 = 1,
        fn run(ptr: *anyopaque, arena: std.mem.Allocator, c: be.Call, status: ?be.Status) anyerror!be.Reply {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (status) |s| s.ready(s.context);
            return switch (c) {
                .image_requests => blk: {
                    self.plans += 1;
                    const plan = try arena.alloc(models.ImageRequest, 3);
                    for (plan, 0..) |*r, i| r.* = .{ .page = .{ .index = @intCast(i), .url = try std.fmt.allocPrint(arena, "/p{d}", .{i}) }, .url = "jvm://only", .method = "GET", .headers = &.{} };
                    break :blk .{ .image_requests = plan };
                },
                .image => |img| blk: {
                    if (self.fail_page) |f| if (img.page.index == f) break :blk error.ExtensionError;
                    _ = self.images.fetchAdd(1, .monotonic);
                    break :blk .{ .image = try arena.dupe(u8, "\x89PNG\r\n\x1a\nfake") };
                },
                else => error.Unexpected,
            };
        }
        fn yes(_: *anyopaque) bool {
            return true;
        }
        fn none(_: *anyopaque) void {}
    };
    var fake: Fake = .{};
    const backend: be.Backend = .{ .ptr = &fake, .vtable = &.{ .run = Fake.run, .warm = Fake.yes, .cancel = Fake.none, .release = Fake.none, .idle = Fake.none } };
    var engine: Engine = .init(std.testing.allocator, io, backend, .{ .dir = dir });
    defer engine.queue.deinit(&engine);
    try engine.store.save(a, .{ .manga = &.{.{ .id = "7:/m", .title = "M", .source_id = 7, .remote = .{ .url = "/m", .title = "M" }, .chapters = &.{
        .{ .id = "7:/c", .title = "Chapter 1", .remote = .{ .url = "/c", .name = "Chapter 1" } },
    } }} });

    const read = try Job.start(&engine, .{ .read = .{ .chapter = "7:/c", .page = 2 } });
    read.join();
    try std.testing.expect(read.failure == null);
    const states = try read.pageStates(a);
    try std.testing.expect(states[0] == .ready and states[1] == .failed and states[2] == .ready);
    try std.testing.expectEqual(0, read.result.pages[1].len);
    try std.testing.expect(read.result.library_changed);
    const online_saved = (try engine.store.load(a)).manga[0].chapters[0];
    try std.testing.expectEqual(3, online_saved.page_count);
    try std.testing.expectEqual(0, online_saved.pages.len);
    read.deinit();
    try std.testing.expect(try engine.chapterCacheBytes() > 0);

    // The page list is cached; a retry fetches only the missing page, and
    // a download copies the cached pages.
    fake.fail_page = null;
    const again = try Job.start(&engine, .{ .read = .{ .chapter = "7:/c" } });
    again.join();
    again.deinit();
    try std.testing.expectEqual(1, fake.plans);
    try std.testing.expectEqual(3, fake.images.load(.acquire));
    const download = try Job.start(&engine, .{ .download = "7:/c" });
    download.join();
    try std.testing.expect(download.failure == null);
    download.deinit();
    try std.testing.expectEqual(3, fake.images.load(.acquire));
    try engine.clearChapterCache();
    try std.testing.expectEqual(0, try engine.chapterCacheBytes());
    try engine.setProgress("7:/c", 1, false, 0);
    try std.testing.expectEqual(1, try engine.deleteDownloads(&.{"7:/c"}));
    const deleted = (try engine.store.load(a)).manga[0].chapters[0];
    try std.testing.expectEqual(3, deleted.page_count);
    try std.testing.expectEqual(0, deleted.pages.len);
    try std.testing.expectEqual(1, deleted.last_page_read);
}

test "engine caches thumbnails and prefers a custom cover" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const Fake = struct {
        calls: usize = 0,
        fn run(ptr: *anyopaque, arena: std.mem.Allocator, c: be.Call, status: ?be.Status) anyerror!be.Reply {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (status) |s| s.ready(s.context);
            self.calls += 1;
            return switch (c) {
                .image => .{ .image = try arena.dupe(u8, "RIFF\x10\x00\x00\x00WEBPVP8 fake") },
                else => error.Unexpected,
            };
        }
        fn yes(_: *anyopaque) bool {
            return true;
        }
        fn none(_: *anyopaque) void {}
    };
    var fake: Fake = .{};
    const backend: be.Backend = .{ .ptr = &fake, .vtable = &.{ .run = Fake.run, .warm = Fake.yes, .cancel = Fake.none, .release = Fake.none, .idle = Fake.none } };
    var engine: Engine = .init(std.testing.allocator, io, backend, .{ .dir = dir });
    defer engine.queue.deinit(&engine);
    const manga: library.Manga = .{ .id = "7:/m", .title = "M", .source_id = 7, .remote = .{ .url = "/m", .title = "M", .thumbnailUrl = "https://x/c.webp" } };
    try std.testing.expect(try engine.coverPath(a, manga) == null);
    for (0..2) |_| {
        const job = try Job.start(&engine, .{ .cover = .{ .source = 7, .url = "https://x/c.webp" } });
        job.join();
        try std.testing.expect(job.failure == null);
        try std.testing.expect(std.mem.endsWith(u8, job.result.cover.?, ".webp"));
        job.deinit();
    }
    try std.testing.expectEqual(1, fake.calls);
    const cached = (try engine.coverPath(a, manga)).?;
    try engine.setCustomCover("7:/m", "\x89PNG\r\n\x1a\ncustom");
    try std.testing.expect(std.mem.indexOf(u8, (try engine.coverPath(a, manga)).?, "custom") != null);
    try engine.removeCustomCover("7:/m");
    try std.testing.expectEqualStrings(cached, (try engine.coverPath(a, manga)).?);
}

test "engine exports downloads in Mihon's layout and imports them back" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try tmp.dir.createDirPath(io, "lib/downloads/c1");
    try tmp.dir.writeFile(io, .{ .sub_path = "lib/downloads/c1/0001.png", .data = "\x89PNG\r\n\x1a\npage one" });
    const dir = try tmp.dir.realPathFileAlloc(io, "lib", a);
    const root = try std.fs.path.join(a, &.{ try tmp.dir.realPathFileAlloc(io, ".", a), "mihon" });
    var engine: Engine = .init(std.testing.allocator, io, be.none, .{ .dir = dir });
    defer engine.queue.deinit(&engine);
    try engine.store.save(a, .{
        .manga = &.{.{ .id = "1:/m", .title = "Solo: Leveling", .source_id = 1, .remote = .{ .url = "/m", .title = "Solo: Leveling" }, .chapters = &.{
            .{ .id = "1:/c1", .title = "Ch. 1", .scanlator = "G", .number = 1, .remote = .{ .url = "/c1", .name = "Ch. 1" }, .pages = &.{"downloads/c1/0001.png"} },
        } }},
        .sources = &.{.{ .id = 1, .name = "MangaDex", .lang = "en" }},
    });

    const out = try Job.start(&engine, .{ .export_downloads = root });
    out.join();
    try std.testing.expect(out.failure == null);
    out.deinit();
    try tmp.dir.access(io, "mihon/MangaDex (EN)/Solo_ Leveling/G_Ch. 1.cbz", .{});

    try std.testing.expectEqual(1, try engine.deleteDownloads(&.{"1:/c1"}));
    const in = try Job.start(&engine, .{ .import_downloads = root });
    in.join();
    try std.testing.expect(in.failure == null);
    in.deinit();
    const lib = try engine.loadLibrary(a);
    const page = lib.manga[0].chapters[0].pages[0];
    try std.testing.expect(std.mem.endsWith(u8, page, ".cbz#001.png"));
    const bytes = try Io.Dir.cwd().readFileAlloc(io, try engine.pagePath(a, page), a, .limited(64));
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\npage one", bytes);
    // Deleting an imported chapter removes its archive.
    try std.testing.expectEqual(1, try engine.deleteDownloads(&.{"1:/c1"}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, try std.fs.path.join(a, &.{ "lib", page[0..std.mem.indexOfScalar(u8, page, '#').?] }), .{}));
}

test "engine backups carry settings and extensions' settings both ways" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try tmp.dir.createDirPath(io, "one/prefs");
    try tmp.dir.createDirPath(io, "two");
    try tmp.dir.writeFile(io, .{ .sub_path = "one/prefs/source_7.json", .data = "{\"mirror\": {\"t\": \"s\", \"v\": \"b\"}}" });
    const one_dir = try tmp.dir.realPathFileAlloc(io, "one", a);
    const two_dir = try tmp.dir.realPathFileAlloc(io, "two", a);
    const file = try std.fs.path.join(a, &.{ one_dir, "backup.tachibk" });

    var one: Engine = .init(std.testing.allocator, io, be.none, .{ .dir = one_dir });
    defer one.queue.deinit(&one);
    try one.store.save(a, .{ .categories = &.{.{ .id = 4, .name = "Later" }} });
    var s = try one.loadSettings(a);
    s.reader.skip_read = true;
    s.downloads.new_categories = &.{4};
    s.mihon_preferences = &.{.{ .key = "pref_display_mode_library", .value = .{ .string = "LIST" } }};
    try one.saveSettings(s);
    try (stores.File{ .stores = &.{.{ .index_url = "https://k/index.min.json", .name = "K", .signing_key = "abcd" }} }).save(a, io, one_dir);
    const out = try Job.start(&one, .{ .export_backup = .{ .path = file } });
    out.join();
    try std.testing.expect(out.failure == null);
    out.deinit();

    // The other library already has a category, so "Later" gets another id.
    var two: Engine = .init(std.testing.allocator, io, be.none, .{ .dir = two_dir });
    defer two.queue.deinit(&two);
    try two.store.save(a, .{ .categories = &.{.{ .id = 1, .name = "First" }} });
    const in = try Job.start(&two, .{ .import_backup = file });
    in.join();
    try std.testing.expect(in.failure == null);
    in.deinit();
    const restored = try two.loadSettings(a);
    try std.testing.expect(restored.reader.skip_read);
    const lib = try two.loadLibrary(a);
    const later = for (lib.categories) |c| {
        if (std.mem.eql(u8, c.name, "Later")) break c.id;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u32, &.{later}, restored.downloads.new_categories);
    try std.testing.expectEqualStrings("LIST", restored.mihon_preferences[0].value.string);
    const prefs = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(a, &.{ two_dir, "prefs", "source_7.json" }), a, .limited(4096));
    try std.testing.expect(std.mem.indexOf(u8, prefs, "\"mirror\"") != null);
    const restored_stores = try two.extensionStores(a);
    try std.testing.expectEqual(1, restored_stores.len);
    try std.testing.expectEqualStrings("abcd", restored_stores[0].signing_key);
}

test "region reading completes only at the final edge and retains history" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    var engine: Engine = .init(std.testing.allocator, io, be.none, .{ .dir = dir });
    defer engine.queue.deinit(&engine);
    try engine.store.save(a, .{ .manga = &.{.{ .id = "m", .title = "M", .chapters = &.{.{ .id = "c", .title = "C" }} }} });
    try engine.pageShown(.{ .chapter_id = "c", .page = 1, .pages = 2, .completed = false, .read_ms = 100 });
    var chapter = (try engine.loadLibrary(a)).manga[0].chapters[0];
    try std.testing.expectEqual(@as(u32, 1), chapter.last_page_read);
    try std.testing.expect(!chapter.read);
    try std.testing.expectEqual(@as(i64, 100), chapter.read_ms);
    try std.testing.expect(chapter.last_read != 0);
    try engine.pageShown(.{ .chapter_id = "c", .page = 1, .pages = 2, .completed = true, .read_ms = 50 });
    chapter = (try engine.loadLibrary(a)).manga[0].chapters[0];
    try std.testing.expect(chapter.read);
    try std.testing.expectEqual(@as(i64, 150), chapter.read_ms);
    // Revisiting an earlier region never clears a completed chapter.
    try engine.pageShown(.{ .chapter_id = "c", .page = 0, .pages = 2, .completed = false });
    try std.testing.expect((try engine.loadLibrary(a)).manga[0].chapters[0].read);
}

test "explicit region completion respects global incognito" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    var engine: Engine = .init(std.testing.allocator, io, be.none, .{ .dir = dir });
    defer engine.queue.deinit(&engine);
    try engine.store.save(a, .{ .manga = &.{.{ .id = "m", .title = "M", .chapters = &.{.{ .id = "c", .title = "C" }} }} });
    var prefs = try engine.loadSettings(a);
    prefs.reader.incognito = true;
    try engine.saveSettings(prefs);
    try engine.pageShown(.{ .chapter_id = "c", .page = 1, .pages = 2, .completed = true, .read_ms = 100 });
    const chapter = (try engine.loadLibrary(a)).manga[0].chapters[0];
    try std.testing.expect(!chapter.read);
    try std.testing.expectEqual(@as(u32, 0), chapter.last_page_read);
    try std.testing.expectEqual(@as(i64, 0), chapter.last_read);
    try std.testing.expectEqual(@as(i64, 0), chapter.read_ms);
}

test "engine records nothing for sources of extensions read in incognito" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    var engine: Engine = .init(std.testing.allocator, io, be.none, .{ .dir = dir });
    defer engine.queue.deinit(&engine);
    try engine.store.save(a, .{
        .manga = &.{.{ .id = "7:/m", .title = "M", .source_id = 7, .chapters = &.{.{ .id = "7:/c", .title = "C" }} }},
        .sources = &.{.{ .id = 7, .name = "Seven", .pkg = "eu.kanade.seven" }},
    });
    var s = try engine.loadSettings(a);
    s.reader.incognito_extensions = &.{"eu.kanade.seven"};
    try engine.saveSettings(s);
    try engine.pageShown(.{ .chapter_id = "7:/c", .page = 1, .pages = 2, .completed = true });
    try std.testing.expectEqual(0, (try engine.loadLibrary(a)).manga[0].chapters[0].last_page_read);
    s.reader.incognito_extensions = &.{};
    try engine.saveSettings(s);
    try engine.pageShown(.{ .chapter_id = "7:/c", .page = 1, .pages = 2, .completed = true });
    try std.testing.expect((try engine.loadLibrary(a)).manga[0].chapters[0].read);
}

test "engine merges store listings and keeps only trusted extension files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const key = "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2";
    const archive = @import("archive.zig");
    try tmp.dir.writeFile(io, .{ .sub_path = "signed.jar", .data = try archive.zip(a, &.{.{ .name = "META-INF/CERT.RSA", .data = @embedFile("testdata/keiyoushi-cert.rsa") }}) });
    try tmp.dir.writeFile(io, .{ .sub_path = "unsigned.jar", .data = try archive.zip(a, &.{.{ .name = "a.txt", .data = "x" }}) });
    const signed = try std.fs.path.join(a, &.{ dir, "signed.jar" });
    const unsigned = try std.fs.path.join(a, &.{ dir, "unsigned.jar" });
    try tmp.dir.createDirPath(io, "extensions");
    try library.writeJsonAtomic(a, io, try std.fs.path.join(a, &.{ dir, "extensions", "installed.json" }), manage.Registry{ .extensions = @constCast(&[_]manage.InstalledEntry{
        .{ .pkg = "eu.signed", .path = signed, .versionCode = 3, .versionName = "1.4.3" },
        .{ .pkg = "eu.unsigned", .path = unsigned, .versionCode = 1, .versionName = "1.4.1" },
        .{ .pkg = "eu.gone", .path = "/nowhere", .versionCode = 1, .versionName = "1.4.1" },
    }) });

    const Fake = struct {
        uninstalled: usize = 0,
        second: Io.Event = .unset,
        fn entry(pkg: []const u8, code: i64, signing_key: []const u8, lang: []const u8) manage.RepoEntry {
            return .{ .pkg = pkg, .name = pkg, .versionName = "", .versionCode = code, .libVersion = "1.4", .nsfw = false, .lang = lang, .jarUrl = null, .apkUrl = "", .iconUrl = "", .supported = true, .installed = false, .installedVersionCode = null, .hasUpdate = false, .sources = &.{}, .signingKey = signing_key };
        }
        fn run(ptr: *anyopaque, arena: std.mem.Allocator, c: be.Call, status: ?be.Status) anyerror!be.Reply {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (status) |s| s.ready(s.context);
            return switch (c) {
                .extensions => |r| blk: {
                    if (std.mem.indexOf(u8, r.url.?, "one") != null) {
                        try self.second.wait(std.testing.io);
                        break :blk .{ .extensions = try arena.dupe(manage.RepoEntry, &.{ entry("eu.signed", 3, "k1", "en"), entry("eu.french", 1, "k1", "fr") }) };
                    }
                    if (std.mem.indexOf(u8, r.url.?, "two") != null) {
                        self.second.set(std.testing.io);
                        break :blk .{ .extensions = try arena.dupe(manage.RepoEntry, &.{entry("eu.signed", 4, "k1", "en")}) };
                    }
                    return error.NetworkError;
                },
                .install_file => .{},
                .uninstall => blk: {
                    self.uninstalled += 1;
                    break :blk .{};
                },
                else => error.Unexpected,
            };
        }
        fn yes(_: *anyopaque) bool {
            return true;
        }
        fn none(_: *anyopaque) void {}
    };
    var fake: Fake = .{};
    const backend: be.Backend = .{ .ptr = &fake, .vtable = &.{ .run = Fake.run, .warm = Fake.yes, .cancel = Fake.none, .release = Fake.none, .idle = Fake.none } };
    var engine: Engine = .init(std.testing.allocator, io, backend, .{ .dir = dir });
    defer engine.queue.deinit(&engine);
    try (stores.File{ .stores = &.{
        .{ .index_url = "https://one/index.min.json", .signing_key = key },
        .{ .index_url = "https://two/index.min.json", .signing_key = "k2" },
        .{ .index_url = "https://down/index.min.json", .signing_key = "k3" },
    } }).save(a, io, dir);

    // One entry per package and key, the newest; French hidden; a store
    // that fails adds nothing; what no store lists is obsolete.
    const list = try Job.start(&engine, .{ .extensions = .{} });
    list.join();
    try std.testing.expect(list.failure == null);
    try std.testing.expect(fake.second.isSet());
    try std.testing.expectEqual(1, list.result.extensions.len);
    try std.testing.expectEqual(4, list.result.extensions[0].versionCode);
    try std.testing.expectEqual(2, list.result.obsolete.len);
    list.deinit();

    const ok = try Job.start(&engine, .{ .install_file = signed });
    ok.join();
    try std.testing.expect(ok.failure == null);
    ok.deinit();
    const refused = try Job.start(&engine, .{ .install_file = unsigned });
    refused.join();
    try std.testing.expect(refused.failure != null);
    try std.testing.expectEqualStrings("eu.unsigned", refused.result.untrusted.?.pkg);
    refused.deinit();
    try std.testing.expectEqual(1, fake.uninstalled);

    // Without the store, the signed file needs trusting by hand.
    try engine.removeStore("https://one/index.min.json");
    const untrusted = try Job.start(&engine, .{ .install_file = signed });
    untrusted.join();
    const found = untrusted.result.untrusted.?;
    try std.testing.expectEqualStrings(key, found.fingerprint);
    try engine.trustExtension(.{ .pkg = try a.dupe(u8, found.pkg), .version_code = found.version_code, .fingerprint = try a.dupe(u8, found.fingerprint) });
    untrusted.deinit();
    const trusted = try Job.start(&engine, .{ .install_file = signed });
    trusted.join();
    try std.testing.expect(trusted.failure == null);
    trusted.deinit();
    // The unsigned one is still in this registry: it is listed as untrusted.
    const listed = try engine.untrustedExtensions(a);
    try std.testing.expectEqual(1, listed.len);
    try std.testing.expectEqualStrings("eu.unsigned", listed[0].pkg);
}

test "tracking jobs bind prefixes, preserve automatic semantics, retry and gate reader and mark-read" {
    const Fake = struct {
        updates: usize = 0,
        fail: bool = false,
        remote: library.Track = .{ .tracker_id = 2, .remote_id = 42, .status = 5, .total_chapters = 10 },
        fn call(ctx: ?*anyopaque, _: std.mem.Allocator, _: Io, id: i32, _: tracking.Credential, _: tracking.Formats, op: tracking.Operation) anyerror!tracking.Reply {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            switch (op) {
                .login => return .{ .credential = .{ .tracker_id = id, .username = "u", .password = "token" }, .anilist_score_type = .POINT_10_DECIMAL },
                .bind, .refresh => return .{ .track = self.remote },
                .update => |u| {
                    if (self.fail) return error.Offline;
                    self.updates += 1;
                    self.remote = if (u.did_read_chapter) tracking.didRead(u.track, 999) else u.track;
                    return .{ .track = self.remote };
                },
                .delete => return .{},
                else => return error.Unexpected,
            }
        }
        fn run(engine: *Engine, req: Request) !*Job {
            const job = try Job.start(engine, req);
            job.join();
            if (job.failure != null) {
                job.deinit();
                return error.JobFailed;
            }
            return job;
        }
    };
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    var fake: Fake = .{};
    // Undefined backend proves no tracking request touches extensions, even warm().
    var engine: Engine = .init(std.testing.allocator, io, undefined, .{ .dir = dir, .tracker_driver = .{ .context = &fake, .call = Fake.call } });
    defer engine.finishTracking();
    try engine.store.save(a, .{ .manga = &.{.{ .id = "m", .title = "M", .chapters = &.{
        .{ .id = "c3", .title = "3", .number = 3, .read = true, .last_read = 300 },
        .{ .id = "c1", .title = "1", .number = 1, .read = true, .last_read = 100 },
        .{ .id = "c2", .title = "2", .number = 2 },
        .{ .id = "c10", .title = "10", .number = 10 },
    } }} });
    (try Fake.run(&engine, .{ .tracker = .{ .id = 2, .operation = .{ .login = .{ .username = "u", .password = "t" } } } })).deinit();
    const account = try tracking.State.load(a, io, dir);
    try std.testing.expectEqual(tracking.AnilistScore.POINT_10_DECIMAL, account.formats.anilist_score_type);
    (try Fake.run(&engine, .{ .track_bind = .{ .manga_id = "m", .track = .{ .tracker_id = 2, .remote_id = 42 } } })).deinit();
    var bound = (try engine.loadLibrary(a)).manga[0].tracks[0];
    try std.testing.expectEqual(@as(f64, 1), bound.last_chapter_read);
    try std.testing.expectEqual(@as(i64, 100), bound.started);
    // Refresh ahead then request 2: deliberately overwrites remote-ahead value.
    fake.remote.last_chapter_read = 8;
    (try Fake.run(&engine, .{ .track_chapter = .{ .manga_id = "m", .chapter = 2 } })).deinit();
    try std.testing.expectEqual(@as(f64, 2), fake.remote.last_chapter_read);
    // Failure queues max requested value; success removes it.
    fake.fail = true;
    const failed = try Fake.run(&engine, .{ .track_chapter = .{ .manga_id = "m", .chapter = 4 } });
    try std.testing.expectEqual(@as(usize, 1), failed.result.tracking_errors.len);
    failed.deinit();
    try std.testing.expectEqual(@as(f64, 4), (try engine.loadTrackers(a)).pending[0].chapter);
    const offline = try Fake.run(&engine, .{ .track_pending = .{ .connected = false } });
    offline.deinit();
    try std.testing.expectEqual(@as(u8, 0), (try engine.loadTrackers(a)).attempts);
    (try Fake.run(&engine, .{ .track_pending = .{ .connected = true } })).deinit();
    try std.testing.expectEqual(@as(u8, 1), (try engine.loadTrackers(a)).attempts);
    fake.fail = false;
    (try Fake.run(&engine, .{ .track_pending = .{ .connected = true, .force = true } })).deinit();
    try std.testing.expectEqual(@as(usize, 0), (try engine.loadTrackers(a)).pending.len);
    // ASK returns a manga-level prompt without advancing remote.
    var s: settings.Settings = .{};
    s.tracking.on_mark_read = .ask;
    try engine.saveSettings(s);
    const ask = try engine.markReadTracked(a, &.{"c10"}, true);
    try std.testing.expectEqual(@as(usize, 1), ask.prompts.len);
    try std.testing.expectEqual(@as(f64, 4), fake.remote.last_chapter_read);
    try engine.applyTracking(ask.prompts);
    engine.finishTracking();
    try std.testing.expectEqual(@as(i32, 2), fake.remote.status);
    bound = (try engine.loadLibrary(a)).manga[0].tracks[0];
    try std.testing.expectEqual(@as(f64, 10), bound.last_chapter_read);
    // Domain snapshot intentionally predates automatic status/date mutation.
    try std.testing.expectEqual(@as(i32, 1), bound.status);
    (try Fake.run(&engine, .{ .track_refresh = .{} })).deinit();
    try std.testing.expectEqual(@as(i32, 2), (try engine.loadLibrary(a)).manga[0].tracks[0].status);
    (try Fake.run(&engine, .{ .track_set = .{ .manga_id = "m", .tracker_id = 2, .value = .{ .score_index = 80 } } })).deinit();
    try std.testing.expectEqual(@as(f64, 8), (try engine.stats(a)).mean_score);
    try engine.trackerLogout(2);
    try std.testing.expectEqual(@as(usize, 0), (try engine.stats(a)).tracked);
}

test "enhanced matching binds accepted sources only and updates server before local reads" {
    const test_http = @import("track/testing_enhanced.zig");
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const item = "{\"metadata\":{\"title\":\"Series\"}}";
    const progress = "{\"booksCount\":4,\"booksReadCount\":2,\"booksUnreadCount\":2,\"lastReadContinuousNumberSort\":2.5,\"maxNumberSort\":4}";
    var fixture = try test_http.Fixture.init(&.{
        try test_http.ok(a, item),                                                              try test_http.ok(a, progress),
        "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", try test_http.ok(a, item),
        try test_http.ok(a, progress),                                                          try test_http.ok(a, "{}"),
        try test_http.ok(a, item),                                                              try test_http.ok(a, progress),
    });
    defer fixture.deinit();
    fixture.expected = &.{ &.{}, &.{}, &.{"\"lastBookNumberSortRead\":2.5"}, &.{}, &.{}, &.{"\"lastBookNumberSortRead\":2.5"} };
    try fixture.start();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try fixture.url(a, "");
    const url = try fixture.url(a, "/api/v1/series/abc");
    const host = try test_http.prefs(a, tmp.dir, 123, .{ .Address = .{ .t = "s", .v = base }, .Username = .{ .t = "s", .v = "u" }, .Password = .{ .t = "s", .v = "p" } });
    var engine: Engine = .init(t.allocator, t.io, undefined, .{ .dir = host });
    defer engine.deinit();
    try engine.store.save(a, .{ .sources = &.{ .{ .id = 123, .name = "Komga", .pkg = "eu.kanade.tachiyomi.extension.all.komga" }, .{ .id = 456, .name = "Other", .pkg = "other" } }, .manga = &.{
        .{ .id = "m", .title = "Series", .source_id = 123, .remote = .{ .url = url, .title = "Series" }, .chapters = &.{
            .{ .id = "c1", .title = "1", .number = 1, .read = true },
            .{ .id = "c2", .title = "2", .number = 2 },
            .{ .id = "c3", .title = "3", .number = 3, .read = true },
            .{ .id = "c4", .title = "4", .number = 4 },
        } },
        .{ .id = "other", .title = "Other", .source_id = 456, .remote = .{ .url = url, .title = "Other" } },
    } });
    const login = try Job.start(&engine, .{ .tracker = .{ .id = 6, .operation = .{ .login = .{ .username = "", .password = "" } } } });
    defer login.deinit();
    login.join();
    try t.expect(login.failure == null);
    const rejected = try Job.start(&engine, .{ .track_match = .{ .manga_id = "m" } });
    defer rejected.deinit();
    rejected.join();
    try t.expect(rejected.failure != null);
    const unchanged = (try engine.loadLibrary(a)).manga[0];
    try t.expectEqual(@as(usize, 0), unchanged.tracks.len);
    try t.expect(!unchanged.chapters[1].read);
    const matched = try Job.start(&engine, .{ .track_match = .{ .manga_id = "m" } });
    defer matched.deinit();
    matched.join();
    try t.expect(matched.failure == null);
    const bound = (try engine.loadLibrary(a)).manga[0];
    try t.expectEqual(@as(usize, 1), bound.tracks.len);
    try t.expectEqual(@as(f64, 2.5), bound.tracks[0].last_chapter_read);
    try t.expect(bound.chapters[1].read);
    try t.expect(!bound.chapters[3].read);
    for ([_][]const u8{ "m", "other" }) |id| {
        const again = try Job.start(&engine, .{ .track_match = .{ .manga_id = id } });
        defer again.deinit();
        again.join();
        try t.expect(again.failure == null);
    }
    try fixture.finish();
}

test "canceling one engine job does not invoke backend-wide cancellation" {
    const Fake = struct {
        io: Io,
        first_started: Io.Event = .unset,
        second_started: Io.Event = .unset,
        release: Io.Event = .unset,
        global_cancels: std.atomic.Value(u32) = .init(0),

        fn run(ptr: *anyopaque, _: std.mem.Allocator, call: be.Call, _: ?be.Status) !be.Reply {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (call.filters == 1) self.first_started.set(self.io) else self.second_started.set(self.io);
            try self.release.wait(self.io);
            return .{};
        }
        fn warm(_: *anyopaque) bool {
            return true;
        }
        fn cancel(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            _ = self.global_cancels.fetchAdd(1, .monotonic);
            self.release.set(self.io);
        }
        fn quiet(_: *anyopaque) void {}
    };
    const io = std.testing.io;
    var fake: Fake = .{ .io = io };
    var engine: Engine = .init(std.testing.allocator, io, .{ .ptr = &fake, .vtable = &.{
        .run = Fake.run,
        .warm = Fake.warm,
        .cancel = Fake.cancel,
        .release = Fake.quiet,
        .idle = Fake.quiet,
    } }, .{ .dir = "unused" });
    defer engine.deinit();
    const first = try Job.start(&engine, .{ .filters = 1 });
    defer {
        first.cancel();
        first.deinit();
    }
    const second = try Job.start(&engine, .{ .filters = 2 });
    defer {
        fake.release.set(io);
        second.cancel();
        second.deinit();
    }
    try fake.first_started.wait(io);
    try fake.second_started.wait(io);
    first.cancel();
    try std.testing.expectEqualStrings("Canceled", first.failure.?);
    try std.testing.expectEqual(0, fake.global_cancels.load(.monotonic));
    try std.testing.expect(!second.done.load(.acquire));
    fake.release.set(io);
    second.join();
    try std.testing.expect(second.failure == null);
}

test "store refresh overlaps requests and retains unreachable stores" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    const Fixture = struct {
        server: *Io.net.Server,
        fn accept(self: *@This()) !Io.net.Stream {
            const stream = try self.server.accept(std.testing.io);
            errdefer stream.close(std.testing.io);
            var buffer: [4096]u8 = undefined;
            var reader = stream.reader(std.testing.io, &buffer);
            while ((try reader.interface.takeDelimiterInclusive('\n')).len > 2) {}
            return stream;
        }
        fn serve(self: *@This()) !void {
            const first = try self.accept();
            defer first.close(std.testing.io);
            const second = try self.accept();
            defer second.close(std.testing.io);
            const json = "{\"name\":\"Fresh\",\"badgeLabel\":\"F\",\"signingKey\":\"key\",\"contact\":{\"website\":\"\"}}";
            for ([_]Io.net.Stream{ second, first }) |stream| {
                var writer = stream.writer(std.testing.io, &.{});
                try writer.interface.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ json.len, json });
                try writer.interface.flush();
            }
            const failed = try self.accept();
            defer failed.close(std.testing.io);
            var writer = failed.writer(std.testing.io, &.{});
            try writer.interface.writeAll("HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            try writer.interface.flush();
        }
    };
    var fixture: Fixture = .{ .server = &server };
    var serving = try io.concurrent(Fixture.serve, .{&fixture});
    defer _ = serving.cancel(io) catch {};
    var configured: [3]stores.Store = undefined;
    for (&configured, 0..) |*store, i| store.* = .{ .index_url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/{d}.json", .{ server.socket.address.getPort(), i }), .name = "Old" };
    try (stores.File{ .stores = &configured }).save(a, io, dir);
    var engine: Engine = .init(std.testing.allocator, io, be.none, .{ .dir = dir, .parallelism = 2 });
    defer engine.deinit();
    const job = try Job.start(&engine, .refresh_stores);
    defer job.deinit();
    job.join();
    try std.testing.expect(job.failure == null);
    try serving.await(io);
    const refreshed = try stores.File.load(a, io, dir);
    try std.testing.expectEqual(3, refreshed.stores.len);
    try std.testing.expectEqualStrings("Fresh", refreshed.stores[0].name);
    try std.testing.expectEqualStrings("Fresh", refreshed.stores[1].name);
    try std.testing.expectEqualStrings("Old", refreshed.stores[2].name);
    try std.testing.expectEqualStrings("Stores refreshed; 1 could not be reached", job.result.message);
}

test "library refresh overlaps fetches and serially publishes updates, failures and skips" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const Fixture = struct {
        first: Io.Event = .unset,
        second: Io.Event = .unset,
        fn run(ptr: *anyopaque, scratch: std.mem.Allocator, call: be.Call, status: ?be.Status) !be.Reply {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (status) |s| s.ready(s.context);
            const update = switch (call) {
                .update => |u| u,
                else => return error.Unexpected,
            };
            switch (update.source) {
                1 => {
                    self.first.set(std.testing.io);
                    try self.second.wait(std.testing.io);
                },
                2 => {
                    try self.first.wait(std.testing.io);
                    self.second.set(std.testing.io);
                },
                3 => {
                    tachi.setLastError("broken source");
                    return error.ExtensionError;
                },
                else => return error.Unexpected,
            }
            const chapters = try scratch.alloc(models.Chapter, 1);
            chapters[0] = .{ .url = try scratch.dupe(u8, "/c1"), .name = try scratch.dupe(u8, "Chapter 1"), .chapterNumber = 1 };
            return .{ .update = .{ .manga = .{ .url = update.manga.url, .title = try scratch.dupe(u8, "Fresh") }, .chapters = chapters } };
        }
        fn yes(_: *anyopaque) bool {
            return true;
        }
        fn none(_: *anyopaque) void {}
    };
    var fixture: Fixture = .{};
    const backend: be.Backend = .{ .ptr = &fixture, .vtable = &.{ .run = Fixture.run, .warm = Fixture.yes, .cancel = Fixture.none, .release = Fixture.none, .idle = Fixture.none } };
    var engine: Engine = .init(std.testing.allocator, io, backend, .{ .dir = dir, .parallelism = 2 });
    defer engine.deinit();
    var titles: [4]library.Manga = undefined;
    for (&titles, 1..) |*title, id| title.* = .{
        .id = try library.mangaId(a, @intCast(id), "/m"),
        .source_id = @intCast(id),
        .title = try std.fmt.allocPrint(a, "Title {d}", .{id}),
        .remote = .{ .url = "/m", .title = "Title", .status = if (id == 4) 2 else 1 },
    };
    try engine.store.save(a, .{ .manga = &titles });
    const job = try Job.start(&engine, .{ .update_library = .{} });
    defer job.deinit();
    job.join();
    try std.testing.expect(job.failure == null);
    try std.testing.expect(fixture.first.isSet() and fixture.second.isSet());
    try std.testing.expectEqual(3, job.pages_done.load(.acquire));
    try std.testing.expectEqual(3, job.pages_total.load(.acquire));
    try std.testing.expectEqual(1, job.result.update_skipped);
    try std.testing.expectEqual(2, job.result.new_chapters.len);
    try std.testing.expectEqualStrings("1:/c1", job.result.new_chapters[0]);
    try std.testing.expectEqualStrings("2:/c1", job.result.new_chapters[1]);
    try std.testing.expectEqual(1, job.result.update_errors.len);
    try std.testing.expectEqualStrings("3:/m", job.result.update_errors[0].manga_id);
    try std.testing.expectEqualStrings("ExtensionError: broken source", job.result.update_errors[0].message);
    const updated = try engine.store.load(a);
    try std.testing.expectEqual(1, updated.manga[updated.find("1:/m").?].chapters.len);
    try std.testing.expectEqual(1, updated.manga[updated.find("2:/m").?].chapters.len);
    try std.testing.expectEqual(0, updated.manga[updated.find("3:/m").?].chapters.len);
    try std.testing.expectEqual(0, updated.manga[updated.find("4:/m").?].chapters.len);
    try std.testing.expectEqual(2, (try engine.loadSettings(a)).updates.unseen);
}

test "reader and downloader honor page preferences within the engine concurrency cap" {
    const io = std.testing.io;
    const Case = struct { pages: u8, cap: usize, expected: usize, read: bool };
    for ([_]Case{
        .{ .pages = 0, .cap = 4, .expected = 1, .read = true },
        .{ .pages = 1, .cap = 4, .expected = 1, .read = false },
        .{ .pages = 5, .cap = 2, .expected = 2, .read = true },
        .{ .pages = 2, .cap = 4, .expected = 2, .read = false },
    }) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
        const Fixture = struct {
            expected: usize,
            both: Io.Event = .unset,
            entered: std.atomic.Value(usize) = .init(0),
            active: std.atomic.Value(usize) = .init(0),
            peak: std.atomic.Value(usize) = .init(0),
            fn run(ptr: *anyopaque, scratch: std.mem.Allocator, call: be.Call, status: ?be.Status) !be.Reply {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                if (status) |s| s.ready(s.context);
                return switch (call) {
                    .image_requests => blk: {
                        const plan = try scratch.alloc(models.ImageRequest, 2);
                        for (plan, 0..) |*request, i| request.* = .{ .page = .{ .index = @intCast(i), .url = try std.fmt.allocPrint(scratch, "/{d}", .{i}) }, .url = "jvm://page", .method = "GET", .headers = &.{} };
                        break :blk .{ .image_requests = plan };
                    },
                    .image => blk: {
                        const active = self.active.fetchAdd(1, .acq_rel) + 1;
                        defer _ = self.active.fetchSub(1, .acq_rel);
                        _ = self.peak.fetchMax(active, .acq_rel);
                        const ticket = self.entered.fetchAdd(1, .acq_rel);
                        if (self.expected == 2) {
                            if (ticket == 0) try self.both.wait(std.testing.io) else self.both.set(std.testing.io);
                        }
                        break :blk .{ .image = try scratch.dupe(u8, "\x89PNG\r\n\x1a\nimage") };
                    },
                    else => error.Unexpected,
                };
            }
            fn yes(_: *anyopaque) bool {
                return true;
            }
            fn none(_: *anyopaque) void {}
        };
        var fixture: Fixture = .{ .expected = case.expected };
        const backend: be.Backend = .{ .ptr = &fixture, .vtable = &.{ .run = Fixture.run, .warm = Fixture.yes, .cancel = Fixture.none, .release = Fixture.none, .idle = Fixture.none } };
        var engine: Engine = .init(std.testing.allocator, io, backend, .{ .dir = dir, .parallelism = case.cap });
        defer engine.deinit();
        var s: settings.Settings = .{};
        s.downloads.parallel_pages = case.pages;
        try engine.saveSettings(s);
        try engine.store.save(a, .{ .manga = &.{.{ .id = "1:/m", .title = "M", .source_id = 1, .remote = .{ .url = "/m", .title = "M" }, .chapters = &.{.{ .id = "1:/c", .title = "C", .remote = .{ .url = "/c", .name = "C" } }} }} });
        const request: Request = if (case.read) .{ .read = .{ .chapter = "1:/c" } } else .{ .download = "1:/c" };
        const job = try Job.start(&engine, request);
        defer job.deinit();
        job.join();
        try std.testing.expect(job.failure == null);
        try std.testing.expectEqual(2, fixture.entered.load(.acquire));
        try std.testing.expectEqual(case.expected, fixture.peak.load(.acquire));
        try std.testing.expectEqual(2, job.pages_done.load(.acquire));
    }
}

test "SD downloads retain their volume when resuming and delete through the SD resolver" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const sd = try std.fs.path.join(a, &.{ dir, "sd", "pocketmanga" });
    try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(sd).?);
    const Fixture = struct {
        const plan: []const models.ImageRequest = &.{
            .{ .page = .{ .index = 0, .url = "/page" }, .url = "http://unused/page", .method = "GET", .headers = &.{}, .fallback = "fixture" },
        };
        images: usize = 0,
        fn run(ptr: *anyopaque, scratch: std.mem.Allocator, call: be.Call, _: ?be.Status) !be.Reply {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return switch (call) {
                .image_requests => .{ .image_requests = plan },
                .image => blk: {
                    self.images += 1;
                    break :blk .{ .image = try scratch.dupe(u8, "\x89PNG\r\n\x1a\nfixture-page") };
                },
                else => error.Unexpected,
            };
        }
        fn warm(_: *anyopaque) bool {
            return true;
        }
        fn quiet(_: *anyopaque) void {}
    };
    var fixture: Fixture = .{};
    var engine: Engine = .init(a, io, .{ .ptr = &fixture, .vtable = &.{ .run = Fixture.run, .warm = Fixture.warm, .cancel = Fixture.quiet, .release = Fixture.quiet, .idle = Fixture.quiet } }, .{ .dir = dir, .sd_dir = sd, .release_jvm = false });
    const initial: library.Library = .{ .manga = &.{.{ .id = "m", .title = "M", .source_id = 1, .chapters = &.{.{ .id = "c", .title = "C", .remote = .{ .url = "/c", .name = "C" } }} }} };
    try engine.store.save(a, initial);
    var prefs: settings.Settings = .{};
    prefs.downloads.storage = .sd_card;
    try prefs.save(a, io, dir);
    try std.testing.expectEqualStrings(sd, (try engine.downloadTarget(a, "c")).dir);
    var job: Job = .{ .arena = .init(a), .engine = &engine, .request = .{ .download = "c" } };
    try engine.downloadChapter(&job, "c");
    const downloaded = try engine.store.load(a);
    const relative = downloaded.manga[0].chapters[0].pages[0];
    try std.testing.expect(std.mem.startsWith(u8, relative, "sdcard/downloads/"));
    const absolute = try engine.pagePath(a, relative);
    const bytes = try Io.Dir.cwd().readFileAlloc(io, absolute, a, .limited(1024));
    try std.testing.expect(std.mem.startsWith(u8, bytes, "\x89PNG"));
    try std.testing.expectEqual(1, fixture.images);
    // Recreate an interrupted chapter while keeping the saved page and manifest.
    try engine.store.save(a, initial);
    prefs.downloads.storage = .internal;
    try prefs.save(a, io, dir);
    engine.options.sd_dir = null;
    var unplugged: Job = .{ .arena = .init(a), .engine = &engine, .request = .{ .download = "c" } };
    try std.testing.expectError(error.StorageUnavailable, engine.downloadTarget(a, "c"));
    try std.testing.expectError(error.StorageUnavailable, engine.downloadChapter(&unplugged, "c"));
    try std.testing.expectEqual(1, fixture.images);
    try std.testing.expectError(error.StorageUnavailable, engine.removeDownloads(a, &.{"c"}));
    try std.testing.expect((try engine.savedDownloadDestination(a, "c")).?.sd_card);
    engine.options.sd_dir = sd;
    var retry: Job = .{ .arena = .init(a), .engine = &engine, .request = .{ .download = "c" } };
    try engine.downloadChapter(&retry, "c");
    try std.testing.expectEqual(1, fixture.images);
    try std.testing.expect(std.mem.startsWith(u8, (try engine.store.load(a)).manga[0].chapters[0].pages[0], "sdcard/"));
    // A removed card must preserve the library record when deletion is requested.
    engine.options.sd_dir = null;
    try std.testing.expectError(error.StorageUnavailable, engine.removeDownloads(a, &.{"c"}));
    try std.testing.expectEqual(1, (try engine.store.load(a)).manga[0].chapters[0].pages.len);
    engine.options.sd_dir = sd;
    try std.testing.expectEqual(1, try engine.removeDownloads(a, &.{"c"}));
    try std.testing.expectEqual(0, (try engine.store.load(a)).manga[0].chapters[0].pages.len);
    try std.testing.expect(try downloads.resumeProgress(a, io, sd, "downloads", "c") == null);
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().openFile(io, absolute, .{}));
    // The newly selected destination applies after explicit deletion.
    var fresh: Job = .{ .arena = .init(a), .engine = &engine, .request = .{ .download = "c" } };
    try engine.downloadChapter(&fresh, "c");
    try std.testing.expect(!std.mem.startsWith(u8, (try engine.store.load(a)).manga[0].chapters[0].pages[0], "sdcard/"));
    prefs.downloads.storage = .sd_card;
    try prefs.save(a, io, dir);
    try engine.store.save(a, initial);
    try downloads.clearResumeProgress(a, io, dir, "downloads", "c");
    try Io.Dir.cwd().deleteFile(io, try engine.downloadDestinationPath(a, "c"));
    engine.options.sd_dir = null;
    var missing: Job = .{ .arena = .init(a), .engine = &engine, .request = .{ .download = "c" } };
    try std.testing.expectError(error.StorageUnavailable, engine.downloadChapter(&missing, "c"));
    try std.testing.expectEqualStrings("C", (try engine.store.load(a)).manga[0].chapters[0].title);
    // The old internal page is now a partial download: delete files and its manifest.
    const partial_store = try downloads.PageStore.init(a, io, dir, "c", Fixture.plan);
    _ = try partial_store.put(0, "\x89PNG\r\n\x1a\npartial-page");
    const manifest = try std.fmt.allocPrint(a, "{s}/downloads/{x}/current-plan.json", .{ dir, std.hash.Wyhash.hash(0, "c") });
    try library.writeJsonAtomic(a, io, manifest, .{ .plan = std.fs.path.basename(partial_store.folder), .total = 1 });
    try std.testing.expectEqual(1, try engine.removeDownloads(a, &.{"c"}));
    try std.testing.expect(try engine.downloadProgress(a, "c") == null);
    try std.testing.expect(try partial_store.complete(0) == null);
}

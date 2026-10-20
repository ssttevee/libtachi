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
const local = @import("local.zig");
const backup = @import("backup.zig");
const settings = @import("settings.zig");
const queue_mod = @import("queue.zig");
const be = @import("backend.zig");

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
    /// Deletes a chapter's downloaded pages.
    delete_download: []const u8,
    /// Removes a title from the library; its downloads stay.
    remove: []const u8,
    /// Adds the series in the local source to the library.
    scan_local,
    /// Restores a Mihon backup (`.tachibk`) into the library.
    import_backup: []const u8,
    /// Writes the library as a Mihon backup.
    export_backup: struct { path: []const u8, options: backup.ExportOptions = .{} },

    fn usesBackend(self: Request) bool {
        return switch (self) {
            .delete_download, .remove, .scan_local, .import_backup, .export_backup => false,
            else => true,
        };
    }
};

pub const Result = struct {
    sources: []const models.SourceInfo = &.{},
    extensions: []const manage.RepoEntry = &.{},
    extension_updates: ?manage.UpdateResult = null,
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
    message: []const u8 = "Ready",
};

pub const UpdateError = struct { manga_id: []const u8, title: []const u8, message: []const u8 };

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
    /// PEM roots for native downloads; null uses the system's.
    ca_file: ?[]const u8 = null,
    /// Let a worker backend exit while a chapter downloads natively, and after.
    release_jvm: bool = true,
    /// The user's offset from UTC in seconds, for "today" in update
    /// schedules and the updates feed.
    utc_offset_s: i32 = 0,
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
    /// Runs jobs instead of the engine, for tests without a JVM.
    execute_fn: ?*const fn (*Engine, *Job) anyerror!void = null,

    pub fn init(gpa: std.mem.Allocator, io: Io, backend: be.Backend, options: Options) Engine {
        return .{ .gpa = gpa, .io = io, .backend = backend, .store = .{ .io = io, .dir = options.dir }, .options = options };
    }

    /// The library, allocated in `arena`.
    pub fn loadLibrary(self: *Engine, arena: std.mem.Allocator) !library.Library {
        return self.store.load(arena);
    }

    /// Absolute path of a page file the library refers to.
    pub fn pagePath(self: *Engine, gpa: std.mem.Allocator, relative: []const u8) ![:0]u8 {
        return self.store.pagePath(gpa, relative);
    }

    /// Records the page shown in a chapter, marks it read once requested,
    /// and adds `read_ms` of reading time to its history. Cheap enough for
    /// every page turn: only the reading-state file is rewritten.
    pub fn setProgress(self: *Engine, chapter_id: []const u8, page: u32, read: bool, read_ms: i64) !void {
        try self.store.setProgress(self.gpa, &.{.{ .chapter_id = chapter_id, .page = page, .read = read, .now = wallMillis(self.io), .read_ms = read_ms }});
    }

    /// Records several chapters' progress in one write, as for an import.
    pub fn setProgressMany(self: *Engine, progress: []const library.Progress) !void {
        try self.store.setProgress(self.gpa, progress);
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

    // ---- operations ------------------------------------------------------------

    pub fn execute(self: *Engine, job: *Job) !void {
        try self.io.checkCancel();
        switch (job.request) {
            .sources => {
                job.result.sources = (try job.call(.sources)).sources;
                try self.rememberSources(job, job.result.sources);
            },
            .extensions => |repo| job.result.extensions = (try job.call(.{ .extensions = repo })).extensions,
            .install => |c| {
                job.result.sources = (try job.call(.{ .install = .{ .pkg = c.pkg, .repo = c.repo } })).sources;
                job.result.message = "Extension installed";
            },
            .install_file => |path| {
                job.result.sources = (try job.call(.{ .install_file = path })).sources;
                job.result.message = "Extension installed";
            },
            .uninstall => |pkg| {
                job.result.sources = (try job.call(.{ .uninstall = pkg })).sources;
                job.result.message = "Extension removed";
            },
            .update_extensions => |repo| {
                job.result.extension_updates = (try job.call(.{ .update_extensions = repo })).extension_updates;
                job.result.message = "Extensions updated";
            },
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
                const existing = if (current.find(try library.mangaId(a, c.source, c.manga.url))) |i| current.manga[i].chapters else &.{};
                const fetched = try self.fetchTitle(job, c.source, c.manga, existing);
                job.result = .{ .library_changed = true, .manga_id = fetched.manga_id, .new_chapters = fetched.new_chapters, .message = "Added to library" };
            },
            .refresh => |id| {
                const a = job.arena.allocator();
                const current = try self.store.load(a);
                const book = current.manga[current.find(id) orelse return error.UnknownManga];
                const fetched = try self.fetchTitle(job, book.source_id orelse return error.LocalTitle, book.remote orelse return error.LocalTitle, book.chapters);
                try self.autoDownload(job, fetched.new_chapters);
                job.result = .{ .library_changed = true, .manga_id = book.id, .new_chapters = fetched.new_chapters, .message = "Chapter list updated" };
            },
            .update_library => |c| try self.updateLibrary(job, c.category),
            .download => |id| try self.downloadChapter(job, id),
            .delete_download => |id| try self.deleteDownload(job, id),
            .remove => |id| {
                const Edit = struct {
                    id: []const u8,
                    fn apply(edit: @This(), a: std.mem.Allocator, current: library.Library) !?library.Library {
                        return library.remove(a, current, edit.id);
                    }
                };
                _ = try self.store.update(job.arena.allocator(), Edit{ .id = id }, Edit.apply);
                job.result = .{ .library_changed = true, .message = "Removed from library" };
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
                _ = try self.store.update(a, Edit{ .backup = decoded, .restored = &restored }, Edit.apply);
                job.result = .{ .library_changed = true, .message = try std.fmt.allocPrint(a, "Restored {d} titles", .{restored.restored}) };
            },
            .export_backup => |c| {
                const a = job.arena.allocator();
                const bytes = try backup.encodeFile(a, try backup.fromLibrary(a, try self.store.load(a), c.options));
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
                    for (names.items) |*known| {
                        if (known.id != id) continue;
                        if (!std.mem.eql(u8, known.name, s.name) or !std.mem.eql(u8, known.lang, s.lang)) {
                            known.* = .{ .id = id, .name = s.name, .lang = s.lang };
                            changed = true;
                        }
                        break;
                    } else {
                        try names.append(arena, .{ .id = id, .name = s.name, .lang = s.lang });
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
    fn fetchTitle(self: *Engine, job: *Job, source: i64, remote: models.Manga, existing: []const library.Chapter) !Fetched {
        const a = job.arena.allocator();
        const started = millis(self.io);
        var known: std.ArrayList(models.Chapter) = .empty;
        for (existing) |ch| if (ch.remote) |r| try known.append(a, r);
        const update = (try job.call(.{ .update = .{ .source = source, .manga = remote, .chapters = known.items } })).update orelse return error.InvalidReply;
        const fetched = millis(self.io);
        try self.io.checkCancel();
        const Edit = struct {
            source: i64,
            update: models.MangaUpdate,
            now: i64,
            options: library.SyncOptions,
            synced: *library.Synced,
            fn apply(edit: @This(), arena: std.mem.Allocator, current: library.Library) !?library.Library {
                edit.synced.* = try library.syncSource(arena, current, edit.source, edit.update.manga, edit.update.chapters, edit.now, edit.options);
                return edit.synced.library;
            }
        };
        const s = try self.loadSettings(a);
        var synced: library.Synced = undefined;
        _ = try self.store.update(a, Edit{ .source = source, .update = update, .now = wallMillis(self.io), .options = .{ .mark_duplicate_read = s.update.mark_new_duplicates_read, .update_title = s.update.titles }, .synced = &synced }, Edit.apply);
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
        const s = try self.loadSettings(a);
        const window_upper = dayStart(wallMillis(self.io), self.options.utc_offset_s) + std.time.ms_per_day;
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
                (s.update.skip_outside_release_period and book.next_update != 0 and book.next_update > window_upper);
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
        var errors: std.ArrayList(UpdateError) = .empty;
        var updated: usize = 0;
        var new_chapters: std.ArrayList([]const u8) = .empty;
        job.pages_total.store(queue.items.len, .release);
        for (queue.items, 1..) |book, done| {
            try self.io.checkCancel();
            if (self.fetchTitle(job, book.source_id.?, book.remote.?, book.chapters)) |fetched| {
                updated += 1;
                try new_chapters.appendSlice(a, fetched.new_chapters);
            } else |err| switch (err) {
                error.Canceled => return err,
                else => {
                    const message = try std.fmt.allocPrint(a, "{s}: {s}", .{ @errorName(err), tachi.lastError() });
                    try errors.append(a, .{ .manga_id = book.id, .title = book.title, .message = message });
                    log.warn("update {s}: {s}", .{ book.title, message });
                },
            }
            job.pages_done.store(done, .release);
        }
        try self.autoDownload(job, new_chapters.items);
        job.result = .{
            .library_changed = updated > 0,
            .new_chapters = new_chapters.items,
            .update_errors = errors.items,
            .update_skipped = skipped,
            .message = if (errors.items.len == 0) "Library updated" else try std.fmt.allocPrint(a, "Library updated; {d} title(s) failed", .{errors.items.len}),
        };
    }

    /// Downloads a library chapter for `job`, resuming saved pages, and
    /// records its pages in the library.
    pub fn downloadChapter(self: *Engine, job: *Job, chapter_id: []const u8) !void {
        const a = job.arena.allocator();
        const chapter_started = millis(self.io);
        const current = try self.store.load(a);
        const found = findChapter(current, chapter_id) orelse return error.UnknownChapter;
        const source = found.manga.source_id orelse return error.LocalChapter;
        const remote = found.chapter.remote orelse return error.MissingChapterMetadata;
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
            .dir = self.options.dir,
            .chapter_id = chapter_id,
            .ca_file = self.options.ca_file,
            .fallback = .{ .context = job, .fetch = Job.fetchFallback },
            .progress = .{ .context = job, .report = Job.reportPages },
        });
        const s = chapter.stats;
        log.info("chapter pages={d}/{d} resumed={d} native={d} bytes={d} network_ms={d} disk_ms={d} elapsed_ms={d} planning_ms={d} worker_start_ms={d} total_elapsed_ms={d}", .{ job.pages_done.load(.acquire), plan.len, s.resumed, s.native, s.bytes, s.network_ms, s.disk_ms, s.elapsed_ms, planning_ms, job.start_ms, millis(self.io) - chapter_started });
        const Edit = struct {
            id: []const u8,
            pages: []const []const u8,
            fn apply(edit: @This(), arena: std.mem.Allocator, lib: library.Library) !?library.Library {
                return library.setPages(arena, lib, edit.id, edit.pages);
            }
        };
        _ = try self.store.update(a, Edit{ .id = chapter_id, .pages = chapter.pages }, Edit.apply);
        job.result = .{ .library_changed = true, .manga_id = found.manga.id, .message = "Chapter downloaded" };
    }

    fn deleteDownload(self: *Engine, job: *Job, chapter_id: []const u8) !void {
        const a = job.arena.allocator();
        const current = try self.store.load(a);
        const found = findChapter(current, chapter_id) orelse return error.UnknownChapter;
        if (found.manga.source_id == null) return error.LocalChapter;
        const Edit = struct {
            id: []const u8,
            fn apply(edit: @This(), arena: std.mem.Allocator, lib: library.Library) !?library.Library {
                return library.setPages(arena, lib, edit.id, &.{});
            }
        };
        _ = try self.store.update(a, Edit{ .id = chapter_id }, Edit.apply);
        var folder: ?[]const u8 = null;
        for (found.chapter.pages) |page| {
            const path = try self.store.pagePath(a, page);
            Io.Dir.cwd().deleteFile(self.io, path) catch {};
            folder = std.fs.path.dirname(path);
        }
        if (folder) |dir| Io.Dir.cwd().deleteDir(self.io, dir) catch {};
        job.result = .{ .library_changed = true, .manga_id = found.manga.id, .message = "Download deleted" };
    }
};

const Found = struct { manga: library.Manga, chapter: library.Chapter };
const Fetched = struct { manga_id: []const u8, new_chapters: []const []const u8 };

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
    /// Milliseconds the JVM took to start for this job, if it had to.
    start_ms: u64 = 0,
    starting_at: u64 = 0,

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
        self.starting_at = tachi.worker.tachi_now_ms();
        self.phase.store(.starting, .release);
    }
    fn ready(context: *anyopaque) void {
        const self: *Job = @ptrCast(@alignCast(context));
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
        const source = switch (self.request) {
            .download => |id| (findChapter(try self.engine.store.load(self.arena.allocator()), id) orelse return error.UnknownChapter).manga.source_id.?,
            else => unreachable,
        };
        const reply = try self.call(.{ .image = .{ .source = source, .page = request.page, .url = request.url, .cookies = request.cookies } });
        return gpa.dupe(u8, reply.image orelse return error.InvalidImageResponse);
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

    /// Stops the job as soon as possible; it fails with `Canceled`. Pages a
    /// download saved stay for a retry.
    pub fn cancel(self: *Job) void {
        if (self.request.usesBackend() and self.engine.execute_fn == null) self.engine.backend.cancel();
        if (self.future) |*future| future.cancel(self.engine.io);
    }

    pub fn join(self: *Job) void {
        if (self.future) |*future| future.await(self.engine.io);
        self.future = null;
    }

    pub fn deinit(self: *Job) void {
        self.join();
        const gpa = self.engine.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

fn millis(io: Io) u64 {
    return @intCast(@divTrunc(Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
}

/// Midnight before `ms` in the zone `utc_offset_s` from UTC, as UTC milliseconds.
fn dayStart(ms: i64, utc_offset_s: i32) i64 {
    const offset_ms = @as(i64, utc_offset_s) * std.time.ms_per_s;
    return @divFloor(ms + offset_ms, std.time.ms_per_day) * std.time.ms_per_day - offset_ms;
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

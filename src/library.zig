//! The user's library: titles, their chapters, read progress and downloaded
//! pages, persisted as one JSON file. Nothing here needs the JVM, so a UI
//! process can own the library while extensions run elsewhere.
const std = @import("std");
const Io = std.Io;
const models = @import("models.zig");
const recognition = @import("recognition.zig");

pub const Chapter = struct {
    /// `<source id>:<url>` for source chapters, `local:<series>/<chapter>` for local ones.
    id: []const u8,
    title: []const u8,
    /// Downloaded or local page files, relative to the library directory.
    pages: []const []const u8 = &.{},
    /// The source's chapter, passed back to its extension unchanged.
    remote: ?models.Chapter = null,
    read: bool = false,
    bookmark: bool = false,
    /// Zero-based page the reader last showed.
    last_page_read: u32 = 0,
    /// Milliseconds since the epoch; 0 if never read.
    last_read: i64 = 0,
    /// Total time spent reading the chapter, in milliseconds.
    read_ms: i64 = 0,
    /// When the chapter first appeared in the library, in milliseconds since the epoch.
    date_fetch: i64 = 0,
    /// The recognized chapter number (see `recognition`); -1 if unknown.
    number: f64 = -1,
    /// Position in the source's list, newest first.
    source_order: u32 = 0,
    /// Upload time in milliseconds since the epoch, filled in by sync when
    /// the source has none.
    date_upload: i64 = 0,
    /// Scanlation group; null if none.
    scanlator: ?[]const u8 = null,
    /// The source no longer lists it; kept for its downloaded pages.
    orphaned: bool = false,

    pub fn recognized(self: Chapter) bool {
        return self.number >= 0;
    }

    pub fn downloaded(self: Chapter) bool {
        return self.pages.len > 0;
    }
};

pub const Manga = struct {
    /// `<source id>:<url>` for source titles, `local:<series>` for local ones.
    id: []const u8,
    title: []const u8,
    author: []const u8 = "",
    artist: []const u8 = "",
    genre: []const u8 = "",
    publishing_status: i32 = 0,
    web: []const u8 = "",
    /// Relative page path, including archive entries.
    cover: ?[]const u8 = null,
    description: []const u8 = "",
    chapters: []const Chapter = &.{},
    /// Null for local titles.
    source_id: ?i64 = null,
    /// The source's title, passed back to its extension unchanged.
    remote: ?models.Manga = null,
    /// Milliseconds since the epoch.
    date_added: i64 = 0,
    /// `Category.id`s; empty means the default category.
    categories: []const u32 = &.{},
    /// In the library, rather than kept only for its history or progress.
    favorite: bool = true,
    notes: []const u8 = "",
    /// Mihon's reader bitfield: reading mode in 0x7, orientation in 0x38.
    reader_flags: u32 = 0,
    /// Mihon's chapter list bitfield; see `ChapterFlags`.
    chapter_flags: u32 = 0,
    /// When the chapter list last changed, in milliseconds since the epoch.
    last_update: i64 = 0,
    /// When the next update is expected, in milliseconds since the epoch; 0 if unknown.
    next_update: i64 = 0,
    /// Days between releases: 0 not yet estimated, negative a user override.
    fetch_interval: i32 = 0,
    /// Chapters from these groups are hidden and skipped by updates.
    excluded_scanlators: []const []const u8 = &.{},
    /// Tracker entries bound to this title.
    tracks: []const Track = &.{},

    pub fn excludes(self: Manga, scanlator: ?[]const u8) bool {
        const group = scanlator orelse return false;
        for (self.excluded_scanlators) |s| if (std.mem.eql(u8, s, group)) return true;
        return false;
    }

    /// Counts Mihon's library uses, leaving out excluded groups' chapters.
    pub fn counts(self: Manga) Counts {
        var c: Counts = .{};
        for (self.chapters) |ch| {
            if (self.excludes(ch.scanlator)) continue;
            c.total += 1;
            if (ch.read) c.read += 1;
            if (ch.bookmark) c.bookmarked += 1;
            if (ch.downloaded()) c.downloaded += 1;
            c.latest_upload = @max(c.latest_upload, ch.date_upload);
            c.latest_fetch = @max(c.latest_fetch, ch.date_fetch);
            c.last_read = @max(c.last_read, ch.last_read);
        }
        c.unread = c.total - c.read;
        return c;
    }

    pub fn status(self: Manga) i32 {
        return if (self.remote) |r| r.status else self.publishing_status;
    }

    pub fn onlyFetchOnce(self: Manga) bool {
        return if (self.remote) |r| std.mem.eql(u8, r.updateStrategy, "ONLY_FETCH_ONCE") else false;
    }

    pub fn local(self: Manga) bool {
        return self.source_id == null;
    }
};

pub const Counts = struct {
    total: usize = 0,
    read: usize = 0,
    unread: usize = 0,
    bookmarked: usize = 0,
    downloaded: usize = 0,
    latest_upload: i64 = 0,
    latest_fetch: i64 = 0,
    last_read: i64 = 0,
};

/// A title's entry on a tracking service, in the service's own terms.
pub const Track = struct {
    /// Mihon's tracker id: 1 MyAnimeList, 2 AniList, 3 Kitsu, 4 Shikimori,
    /// 5 Bangumi, 6 Komga, 7 MangaUpdates, 8 Kavita, 9 Suwayomi, ...
    tracker_id: i32,
    remote_id: i64 = 0,
    /// The user's list entry on the service, if it has one.
    library_id: i64 = 0,
    title: []const u8 = "",
    url: []const u8 = "",
    last_chapter_read: f64 = 0,
    total_chapters: i32 = 0,
    /// Service-specific status and score.
    status: i32 = 0,
    score: f64 = 0,
    /// Milliseconds since the epoch; 0 if unset.
    started: i64 = 0,
    finished: i64 = 0,
    private: bool = false,
};

/// A source's name, remembered so titles from a source whose extension is
/// gone can still be named (Mihon's source stubs).
pub const SourceName = struct {
    id: i64,
    name: []const u8,
    lang: []const u8 = "",
    /// The extension package that provides it, if known.
    pkg: []const u8 = "",
};

pub const Category = struct {
    id: u32,
    name: []const u8,
    order: u32 = 0,
    /// Mihon's library sort bits: type in 0x3c, ascending in 0x40.
    flags: u32 = 0,
};

pub const Library = struct {
    version: u32 = version,
    manga: []const Manga = &.{},
    categories: []const Category = &.{},
    sources: []const SourceName = &.{},

    pub fn find(self: Library, id: []const u8) ?usize {
        for (self.manga, 0..) |m, i| if (std.mem.eql(u8, m.id, id)) return i;
        return null;
    }
};

/// Version 1 has no read state, dates or categories; it loads with defaults.
pub const version = 2;

pub const ValidateError = error{ UnsupportedLibraryVersion, InvalidManga, DuplicateManga, InvalidChapter, DuplicateChapter, UnsafePagePath, OutOfMemory };

/// Relative, forward-slash paths that stay inside the library directory.
pub fn safePath(path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, path, '#')) |i| {
        if (std.mem.indexOfScalar(u8, path[i + 1 ..], '#') != null) return false;
        return safePath(path[0..i]) and safePath(path[i + 1 ..]);
    }
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".") or part.len == 0) return false;
    return true;
}

pub fn validate(gpa: std.mem.Allocator, library: Library) ValidateError!void {
    if (library.version == 0 or library.version > version) return error.UnsupportedLibraryVersion;
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    defer ids.deinit(gpa);
    for (library.manga) |m| {
        if (m.id.len == 0 or m.title.len == 0) return error.InvalidManga;
        if (m.cover) |cover| if (!safePath(cover)) return error.UnsafePagePath;
        if ((try ids.getOrPut(gpa, m.id)).found_existing) return error.DuplicateManga;
    }
    ids.clearRetainingCapacity();
    for (library.manga) |m| for (m.chapters) |ch| {
        if (ch.id.len == 0) return error.InvalidChapter;
        if ((try ids.getOrPut(gpa, ch.id)).found_existing) return error.DuplicateChapter;
        for (ch.pages) |path| if (!safePath(path)) return error.UnsafePagePath;
    };
}

/// One chapter's reading state. Kept apart from the library's metadata, so
/// a page turn rewrites a small file rather than the whole library.
pub const Reading = struct {
    id: []const u8,
    page: u32 = 0,
    read: bool = false,
    bookmark: bool = false,
    last_read: i64 = 0,
    read_ms: i64 = 0,

    /// A chapter's state, or null if it has none.
    pub fn of(chapter: Chapter) ?Reading {
        if (chapter.last_page_read == 0 and !chapter.read and !chapter.bookmark and chapter.last_read == 0 and chapter.read_ms == 0) return null;
        return .{ .id = chapter.id, .page = chapter.last_page_read, .read = chapter.read, .bookmark = chapter.bookmark, .last_read = chapter.last_read, .read_ms = chapter.read_ms };
    }
};

const ReadingFile = struct {
    version: u32 = 1,
    chapters: []const Reading = &.{},
};

/// The library in a directory: `library.json` for titles, chapters and
/// downloaded pages, `reading.json` for each chapter's reading state, and the
/// page files. Edits from different threads are serialized; reads may run at
/// any time, because every save replaces a file atomically.
pub const Store = struct {
    io: Io,
    /// The library directory; page paths are relative to it.
    dir: []const u8,
    /// Optional removable storage root. `sdcard/` page paths resolve here.
    sd_dir: ?[]const u8 = null,
    mutex: Io.Mutex = .init,

    pub const file_name = "library.json";
    pub const reading_name = "reading.json";

    /// The library with reading state applied, allocated in `arena`; empty
    /// if there is no file yet.
    pub fn load(self: *Store, arena: std.mem.Allocator) !Library {
        const bytes = self.read(arena, file_name) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        const library = try std.json.parseFromSliceLeaky(Library, arena, bytes, models.parse_options);
        try validate(arena, library);
        const reading = try self.loadReading(arena);
        if (reading.len == 0) return library;
        var by_id: std.StringHashMapUnmanaged(Reading) = .empty;
        try by_id.ensureTotalCapacity(arena, @intCast(reading.len));
        for (reading) |r| by_id.putAssumeCapacity(r.id, r);
        for (library.manga) |m| for (@constCast(m.chapters)) |*ch| if (by_id.get(ch.id)) |r| {
            ch.last_page_read = r.page;
            ch.read = r.read;
            ch.bookmark = r.bookmark;
            ch.last_read = r.last_read;
            ch.read_ms = r.read_ms;
        };
        return library;
    }

    fn read(self: *Store, arena: std.mem.Allocator, name: []const u8) ![]u8 {
        const path = try std.fs.path.join(arena, &.{ self.dir, name });
        return Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(64 << 20));
    }

    fn loadReading(self: *Store, arena: std.mem.Allocator) ![]const Reading {
        const bytes = self.read(arena, reading_name) catch |err| switch (err) {
            error.FileNotFound => return &.{},
            else => return err,
        };
        return (try std.json.parseFromSliceLeaky(ReadingFile, arena, bytes, models.parse_options)).chapters;
    }

    fn saveReading(self: *Store, gpa: std.mem.Allocator, reading: []const Reading) !void {
        const path = try std.fs.path.join(gpa, &.{ self.dir, reading_name });
        defer gpa.free(path);
        try writeJsonAtomic(gpa, self.io, path, ReadingFile{ .chapters = reading });
    }

    /// Replaces both files atomically.
    pub fn save(self: *Store, gpa: std.mem.Allocator, library: Library) !void {
        var current = library;
        current.version = version;
        try validate(gpa, current);
        var reading: std.ArrayList(Reading) = .empty;
        defer reading.deinit(gpa);
        for (current.manga) |m| for (m.chapters) |ch| if (Reading.of(ch)) |r| try reading.append(gpa, r);
        const path = try std.fs.path.join(gpa, &.{ self.dir, file_name });
        defer gpa.free(path);
        try writeJsonAtomic(gpa, self.io, path, current);
        try self.saveReading(gpa, reading.items);
    }

    /// Loads the library, applies `edit` and saves the result, holding the
    /// store's lock throughout. `edit` returns the new library, allocated in
    /// `arena`, or null to leave the files alone.
    pub fn update(self: *Store, arena: std.mem.Allocator, context: anytype, comptime edit: fn (@TypeOf(context), std.mem.Allocator, Library) anyerror!?Library) !Library {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const current = try self.load(arena);
        const next = try edit(context, arena, current) orelse return current;
        try self.save(arena, next);
        return next;
    }

    /// Replaces chapters' reading state, as for marking them read or unread,
    /// without touching the library file.
    pub fn putReading(self: *Store, gpa: std.mem.Allocator, states: []const Reading) !void {
        if (states.len == 0) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var reading: std.ArrayList(Reading) = .empty;
        try reading.appendSlice(arena, try self.loadReading(arena));
        for (states) |state| {
            for (reading.items) |*r| {
                if (std.mem.eql(u8, r.id, state.id)) {
                    r.* = state;
                    break;
                }
            } else try reading.append(arena, state);
        }
        try self.saveReading(arena, reading.items);
    }

    /// Records reading progress without touching the library file. Unknown
    /// chapters are recorded too; they apply once the chapter is in the
    /// library. Returns how many chapters this marked read.
    pub fn setProgress(self: *Store, gpa: std.mem.Allocator, progress: []const Progress) !usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var reading: std.ArrayList(Reading) = .empty;
        try reading.appendSlice(arena, try self.loadReading(arena));
        var changed = false;
        var newly_read: usize = 0;
        for (progress) |p| {
            for (reading.items) |*r| {
                if (!std.mem.eql(u8, r.id, p.chapter_id)) continue;
                const read_now = r.read or p.read;
                if (r.page == p.page and r.read == read_now and p.read_ms == 0) break;
                if (read_now and !r.read) newly_read += 1;
                r.page = p.page;
                r.read = read_now;
                r.last_read = p.now;
                r.read_ms += p.read_ms;
                changed = true;
                break;
            } else {
                try reading.append(arena, .{ .id = p.chapter_id, .page = p.page, .read = p.read, .last_read = p.now, .read_ms = p.read_ms });
                if (p.read) newly_read += 1;
                changed = true;
            }
        }
        if (changed) try self.saveReading(arena, reading.items);
        return newly_read;
    }

    /// Absolute path of a page file the library refers to.
    pub fn pagePath(self: *const Store, gpa: std.mem.Allocator, relative: []const u8) ![:0]u8 {
        if (!safePath(relative)) return error.UnsafePagePath;
        if (std.mem.startsWith(u8, relative, "sdcard/")) {
            const dir = self.sd_dir orelse return error.StorageUnavailable;
            return @import("archive.zig").pagePath(gpa, self.io, dir, relative["sdcard/".len..]);
        }
        return @import("archive.zig").pagePath(gpa, self.io, self.dir, relative);
    }
};

pub fn writeJsonAtomic(gpa: std.mem.Allocator, io: Io, path: []const u8, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(gpa, value, .{ .emit_null_optional_fields = false });
    defer gpa.free(bytes);
    try writeAtomic(gpa, io, path, bytes);
}

/// Writes `bytes` to a temporary file, syncs it and renames it over `path`.
pub fn writeAtomic(gpa: std.mem.Allocator, io: Io, path: []const u8, bytes: []const u8) !void {
    const temp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
    defer gpa.free(temp);
    errdefer Io.Dir.cwd().deleteFile(io, temp) catch {};
    {
        const file = try Io.Dir.cwd().createFile(io, temp, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
    }
    try Io.Dir.cwd().rename(temp, Io.Dir.cwd(), path, io);
}

// ---- edits ---------------------------------------------------------------------

/// Adds `manga` or updates the title with its id. Chapters it lists replace
/// their stored copies but keep read state and downloaded pages; chapters it
/// does not list are kept. `now` stamps new titles and chapters.
pub fn merge(arena: std.mem.Allocator, library: Library, manga: Manga, now: i64) !Library {
    return apply(arena, library, manga, now, false);
}

pub const SyncOptions = struct {
    /// Mark new chapters read when a chapter with the same number already is
    /// (Mihon's `mark_duplicate_read_chapter_read` "new").
    mark_duplicate_read: bool = false,
    /// Let a library title take the source's new title (Mihon's
    /// `pref_update_library_manga_titles`).
    update_title: bool = false,
};

pub const Synced = struct {
    library: Library,
    manga_id: []const u8,
    /// Chapters that are new to the reader: not carried over from a removed
    /// chapter with the same number, not duplicates marked read, and not from
    /// an excluded group. For an updates feed and auto-downloads.
    new_chapters: []const []const u8,
    /// Anything about the chapter list changed.
    changed: bool,
    /// A genuinely new release appeared (not a first fetch or a re-upload).
    found_release: bool,
};

/// Updates a source title's details and chapters from the source, as
/// Mihon's `SyncChaptersWithSource` does, adding the title if it is new.
/// Chapters are matched by URL; read, bookmark and page state stays with
/// them. Chapters the source dropped are removed, unless they have
/// downloaded pages, and their state carries over to a chapter that comes
/// back under the same number.
pub fn syncSource(arena: std.mem.Allocator, library: Library, source_id: i64, details: models.Manga, incoming: []const models.Chapter, now: i64, options: SyncOptions) !Synced {
    const id = try mangaId(arena, source_id, details.url);
    const index = library.find(id);
    const old: ?Manga = if (index) |i| library.manga[i] else null;
    var manga = try updatedDetails(arena, old, id, source_id, details, now, options);
    const title = manga.title;

    // Distinct by URL, sanitized names, source order by position.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var fresh: std.ArrayList(Chapter) = .empty;
    for (incoming) |sc| {
        if ((try seen.getOrPut(arena, sc.url)).found_existing) continue;
        const scanlator: ?[]const u8 = if (sc.scanlator) |s| blk: {
            const trimmed = std.mem.trim(u8, s, " \t\r\n");
            break :blk if (trimmed.len == 0) null else trimmed;
        } else null;
        try fresh.append(arena, .{
            .id = try chapterId(arena, source_id, sc.url),
            .title = recognition.sanitizeName(sc.name, title),
            .remote = sc,
            .source_order = @intCast(fresh.items.len),
            .date_upload = sc.dateUpload,
            .scanlator = scanlator,
            .number = sc.chapterNumber,
        });
    }
    // Recognized from the whole list, keeping numbers the source gave.
    const inputs = try arena.alloc(recognition.Input, fresh.items.len);
    for (fresh.items, inputs) |ch, *in| in.* = .{ .name = ch.title, .number = ch.number };
    const numbering = try recognition.parseChapterNumbers(arena, title, inputs);
    for (fresh.items, numbering) |*ch, n| ch.number = if (n.chapter) |c| recognition.toDouble(c) else -1;

    const existing: []const Chapter = if (old) |m| m.chapters else &.{};
    var by_url: std.StringHashMapUnmanaged(usize) = .empty;
    for (existing, 0..) |ch, i| try by_url.put(arena, ch.id, i);
    var source_ids: std.StringHashMapUnmanaged(void) = .empty;
    var kept: std.ArrayList(Chapter) = .empty;
    var added: std.ArrayList(Chapter) = .empty;
    var updated_any = false;
    var max_upload: ?i64 = null;
    for (fresh.items) |ch| {
        try source_ids.put(arena, ch.id, {});
        if (by_url.get(ch.id)) |i| {
            const db = existing[i];
            var next = db;
            next.orphaned = false;
            next.title = ch.title;
            next.number = ch.number;
            next.source_order = ch.source_order;
            next.remote = ch.remote;
            // A source that stops giving these leaves the stored ones.
            if (ch.scanlator != null) next.scanlator = ch.scanlator;
            if (ch.date_upload != 0) next.date_upload = ch.date_upload;
            if (db.orphaned or changedChapter(db, next)) updated_any = true;
            try kept.append(arena, next);
        } else {
            var new = ch;
            // Older chapters never get a later upload date than newer ones.
            if (new.date_upload == 0) {
                new.date_upload = max_upload orelse now;
            } else max_upload = @max(max_upload orelse new.date_upload, new.date_upload);
            try added.append(arena, new);
        }
    }
    // Chapters kept from an earlier drop are not dropped again.
    var removed: std.ArrayList(Chapter) = .empty;
    for (existing) |ch| if (!source_ids.contains(ch.id)) {
        if (ch.orphaned) try kept.append(arena, ch) else try removed.append(arena, ch);
    };

    if (added.items.len == 0 and removed.items.len == 0 and !updated_any) {
        const titles = try replaced(arena, library, index, manga);
        return .{ .library = withTitles(library, titles), .manga_id = id, .new_chapters = &.{}, .changed = false, .found_release = false };
    }

    var read_numbers: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (existing) |ch| if (ch.read and ch.recognized()) try read_numbers.put(arena, @bitCast(ch.number), {});
    var deleted: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var deleted_read: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var deleted_bookmarked: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var deleted_fetch: std.AutoHashMapUnmanaged(u64, i64) = .empty;
    // Oldest fetch date wins for a number, as in Mihon.
    std.mem.sort(Chapter, removed.items, {}, struct {
        fn newestFirst(_: void, a: Chapter, b: Chapter) bool {
            return a.date_fetch > b.date_fetch;
        }
    }.newestFirst);
    for (removed.items) |ch| {
        const key: u64 = @bitCast(ch.number);
        if (ch.read) try deleted_read.put(arena, key, {});
        if (ch.bookmark) try deleted_bookmarked.put(arena, key, {});
        try deleted.put(arena, key, {});
        try deleted_fetch.put(arena, key, ch.date_fetch);
    }

    var hidden: std.StringHashMapUnmanaged(void) = .empty;
    var count: i64 = @intCast(added.items.len);
    for (added.items) |*ch| {
        // Newer chapters get later fetch times, so they sort above older ones.
        ch.date_fetch = now + count;
        count -= 1;
        const key: u64 = @bitCast(ch.number);
        if (options.mark_duplicate_read and read_numbers.contains(key)) {
            ch.read = true;
            try hidden.put(arena, ch.id, {});
        }
        if (!ch.recognized() or !deleted.contains(key)) continue;
        ch.read = deleted_read.contains(key);
        ch.bookmark = deleted_bookmarked.contains(key);
        if (deleted_fetch.get(key)) |fetched| ch.date_fetch = fetched;
        try hidden.put(arena, ch.id, {});
    }

    var found_release = false;
    if (existing.len > 0) for (added.items) |ch| {
        if (manga.excludes(ch.scanlator)) continue;
        if (ch.recognized() and deleted.contains(@bitCast(ch.number))) continue;
        found_release = true;
        break;
    };

    // Dropped chapters with downloaded pages stay readable.
    for (removed.items) |ch| if (ch.downloaded()) {
        var orphan = ch;
        orphan.orphaned = true;
        try kept.append(arena, orphan);
    };
    var chapters: std.ArrayList(Chapter) = .empty;
    try chapters.appendSlice(arena, kept.items);
    try chapters.appendSlice(arena, added.items);
    sortReadingOrder(chapters.items);
    manga.chapters = chapters.items;
    manga.last_update = now;

    var new_ids: std.ArrayList([]const u8) = .empty;
    for (added.items) |ch| if (!hidden.contains(ch.id) and !manga.excludes(ch.scanlator)) try new_ids.append(arena, ch.id);
    const titles = try replaced(arena, library, index, manga);
    return .{
        .library = withTitles(library, titles),
        .manga_id = id,
        .new_chapters = new_ids.items,
        .changed = true,
        .found_release = found_release,
    };
}

fn withTitles(library: Library, titles: []const Manga) Library {
    var result = library;
    result.manga = titles;
    return result;
}

/// Mihon's `ShouldUpdateDbChapter`.
fn changedChapter(a: Chapter, b: Chapter) bool {
    const memo_a = if (a.remote) |r| r.memo else null;
    const memo_b = if (b.remote) |r| r.memo else null;
    return !optionalEql(a.scanlator, b.scanlator) or !std.mem.eql(u8, a.title, b.title) or a.date_upload != b.date_upload or
        a.number != b.number or a.source_order != b.source_order or !jsonEql(memo_a, memo_b);
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn jsonEql(a: ?std.json.Value, b: ?std.json.Value) bool {
    if (a == null or b == null) return (a == null or isEmptyObject(a.?)) and (b == null or isEmptyObject(b.?));
    var buf_a: [4096]u8 = undefined;
    var buf_b: [4096]u8 = undefined;
    var wa: std.Io.Writer = .fixed(&buf_a);
    var wb: std.Io.Writer = .fixed(&buf_b);
    std.json.Stringify.value(a.?, .{}, &wa) catch return false;
    std.json.Stringify.value(b.?, .{}, &wb) catch return false;
    return std.mem.eql(u8, wa.buffered(), wb.buffered());
}

fn isEmptyObject(v: std.json.Value) bool {
    return v == .object and v.object.count() == 0;
}

/// A title's details after a source update. New titles take everything;
/// a library title keeps its own title unless `update_title`, and details
/// the source leaves out keep their stored values, as in Mihon.
fn updatedDetails(arena: std.mem.Allocator, old: ?Manga, id: []const u8, source_id: i64, details: models.Manga, now: i64, options: SyncOptions) !Manga {
    var remote = details;
    var manga: Manga = if (old) |m| m else .{ .id = id, .title = details.title, .source_id = source_id, .date_added = now };
    if (old) |m| if (m.remote) |previous| {
        if (remote.author == null) remote.author = previous.author;
        if (remote.artist == null) remote.artist = previous.artist;
        if (remote.description == null) remote.description = previous.description;
        if (remote.genre == null) remote.genre = previous.genre;
        if (remote.thumbnailUrl == null or remote.thumbnailUrl.?.len == 0) remote.thumbnailUrl = previous.thumbnailUrl;
    };
    if (old == null or (details.title.len > 0 and (!manga.favorite or options.update_title))) manga.title = if (details.title.len > 0) details.title else manga.title;
    manga.author = remote.author orelse manga.author;
    manga.description = remote.description orelse manga.description;
    manga.remote = remote;
    _ = arena;
    return manga;
}

fn replaced(arena: std.mem.Allocator, library: Library, index: ?usize, manga: Manga) ![]const Manga {
    if (index) |i| {
        const titles = try arena.dupe(Manga, library.manga);
        titles[i] = manga;
        return titles;
    }
    const titles = try arena.alloc(Manga, library.manga.len + 1);
    @memcpy(titles[0..library.manga.len], library.manga);
    titles[library.manga.len] = manga;
    return titles;
}

/// Oldest first: by source order (the source lists newest first), then
/// naturally by name for chapters without one.
pub fn sortReadingOrder(chapters: []Chapter) void {
    std.mem.sort(Chapter, chapters, {}, struct {
        fn less(_: void, a: Chapter, b: Chapter) bool {
            if (a.source_order != b.source_order) return a.source_order > b.source_order;
            return naturalLess({}, a.title, b.title);
        }
    }.less);
}

fn apply(arena: std.mem.Allocator, library: Library, manga: Manga, now: i64, prune: bool) !Library {
    const index = library.find(manga.id) orelse {
        const titles = try arena.alloc(Manga, library.manga.len + 1);
        @memcpy(titles[0..library.manga.len], library.manga);
        titles[library.manga.len] = manga;
        if (titles[library.manga.len].date_added == 0) titles[library.manga.len].date_added = now;
        const chapters = try arena.dupe(Chapter, manga.chapters);
        for (chapters) |*ch| if (ch.date_fetch == 0) {
            ch.date_fetch = now;
        };
        sortChapters(chapters);
        titles[library.manga.len].chapters = chapters;
        var result = library;
        result.manga = titles;
        return result;
    };
    const old = library.manga[index];
    var listed: std.StringHashMapUnmanaged(usize) = .empty;
    try listed.ensureTotalCapacity(arena, @intCast(manga.chapters.len));
    for (manga.chapters, 0..) |ch, i| listed.putAssumeCapacity(ch.id, i);
    var chapters: std.ArrayList(Chapter) = .empty;
    try chapters.ensureTotalCapacity(arena, old.chapters.len + manga.chapters.len);
    var kept: std.StringHashMapUnmanaged(void) = .empty;
    for (old.chapters) |ch| {
        if (listed.get(ch.id)) |i| {
            chapters.appendAssumeCapacity(updated(ch, manga.chapters[i]));
            try kept.put(arena, ch.id, {});
        } else if (!prune or ch.downloaded()) chapters.appendAssumeCapacity(ch);
    }
    for (manga.chapters) |ch| if (!kept.contains(ch.id)) {
        var fresh = ch;
        if (fresh.date_fetch == 0) fresh.date_fetch = now;
        chapters.appendAssumeCapacity(fresh);
    };
    sortChapters(chapters.items);
    const titles = try arena.dupe(Manga, library.manga);
    titles[index] = manga;
    titles[index].chapters = chapters.items;
    titles[index].date_added = if (old.date_added != 0) old.date_added else if (manga.date_added != 0) manga.date_added else now;
    if (manga.categories.len == 0) titles[index].categories = old.categories;
    var result = library;
    result.manga = titles;
    return result;
}

/// New chapter metadata, with the stored copy's state where the new copy has none.
fn updated(old: Chapter, new: Chapter) Chapter {
    var ch = new;
    if (ch.pages.len == 0) ch.pages = old.pages;
    ch.read = old.read or new.read;
    ch.bookmark = old.bookmark or new.bookmark;
    if (new.last_page_read == 0) ch.last_page_read = old.last_page_read;
    ch.last_read = @max(old.last_read, new.last_read);
    ch.date_fetch = if (old.date_fetch != 0) old.date_fetch else new.date_fetch;
    return ch;
}

/// By the source's chapter number when both have one, then naturally by title.
pub fn sortChapters(chapters: []Chapter) void {
    std.mem.sort(Chapter, chapters, {}, struct {
        fn less(_: void, a: Chapter, b: Chapter) bool {
            if (a.remote) |ar| if (b.remote) |br| {
                if (ar.chapterNumber >= 0 and br.chapterNumber >= 0 and ar.chapterNumber != br.chapterNumber) return ar.chapterNumber < br.chapterNumber;
            };
            return naturalLess({}, a.title, b.title);
        }
    }.less);
}

/// Removes the title with `id`; its page files are left to the caller.
pub fn remove(arena: std.mem.Allocator, library: Library, id: []const u8) !?Library {
    const index = library.find(id) orelse return null;
    const titles = try arena.alloc(Manga, library.manga.len - 1);
    @memcpy(titles[0..index], library.manga[0..index]);
    @memcpy(titles[index..], library.manga[index + 1 ..]);
    var result = library;
    result.manga = titles;
    return result;
}

pub const Progress = struct {
    chapter_id: []const u8,
    /// Zero-based page now shown.
    page: u32,
    /// Marks the chapter read; never unmarks it.
    read: bool = false,
    /// Milliseconds since the epoch.
    now: i64,
    /// Reading time to add to the chapter's history, in milliseconds.
    read_ms: i64 = 0,
};

/// Records reading progress; null if nothing changed or the chapter is unknown.
pub fn setProgress(arena: std.mem.Allocator, library: Library, progress: Progress) !?Library {
    for (library.manga, 0..) |m, mi| for (m.chapters, 0..) |ch, ci| {
        if (!std.mem.eql(u8, ch.id, progress.chapter_id)) continue;
        const read = ch.read or progress.read;
        if (ch.last_page_read == progress.page and ch.read == read and progress.read_ms == 0) return null;
        const chapters = try arena.dupe(Chapter, m.chapters);
        chapters[ci].last_page_read = progress.page;
        chapters[ci].read = read;
        chapters[ci].last_read = progress.now;
        chapters[ci].read_ms += progress.read_ms;
        const titles = try arena.dupe(Manga, library.manga);
        titles[mi].chapters = chapters;
        var result = library;
        result.manga = titles;
        return result;
    };
    return null;
}

/// Applies `edit` to the title with `id`, a copy the caller may change;
/// null if there is no such title or `edit` returns false.
pub fn editManga(arena: std.mem.Allocator, library: Library, id: []const u8, context: anytype, comptime edit: fn (@TypeOf(context), std.mem.Allocator, *Manga) anyerror!bool) !?Library {
    const index = library.find(id) orelse return null;
    const titles = try arena.dupe(Manga, library.manga);
    if (!try edit(context, arena, &titles[index])) return null;
    var result = library;
    result.manga = titles;
    return result;
}

/// Sets a chapter's downloaded pages; null if the chapter is unknown.
pub fn setPages(arena: std.mem.Allocator, library: Library, chapter_id: []const u8, pages: []const []const u8) !?Library {
    for (library.manga, 0..) |m, mi| for (m.chapters, 0..) |ch, ci| {
        if (!std.mem.eql(u8, ch.id, chapter_id)) continue;
        const chapters = try arena.dupe(Chapter, m.chapters);
        chapters[ci].pages = pages;
        const titles = try arena.dupe(Manga, library.manga);
        titles[mi].chapters = chapters;
        var result = library;
        result.manga = titles;
        return result;
    };
    return null;
}

/// Compares runs of digits by value, so "Chapter 2" sorts before "Chapter 10".
pub fn naturalLess(_: void, a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            var ai = i;
            var bj = j;
            while (ai < a.len and a[ai] == '0') : (ai += 1) {}
            while (bj < b.len and b[bj] == '0') : (bj += 1) {}
            var ae = ai;
            var be = bj;
            while (ae < a.len and std.ascii.isDigit(a[ae])) : (ae += 1) {}
            while (be < b.len and std.ascii.isDigit(b[be])) : (be += 1) {}
            if (ae - ai != be - bj) return ae - ai < be - bj;
            const order = std.mem.order(u8, a[ai..ae], b[bj..be]);
            if (order != .eq) return order == .lt;
            i = ae;
            j = be;
        } else {
            const ac = std.ascii.toLower(a[i]);
            const bc = std.ascii.toLower(b[j]);
            if (ac != bc) return ac < bc;
            i += 1;
            j += 1;
        }
    }
    if (a.len - i != b.len - j) return a.len - i < b.len - j;
    return std.mem.lessThan(u8, a, b);
}

/// Library ids for a source title and chapter.
pub fn mangaId(gpa: std.mem.Allocator, source_id: i64, url: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{d}:{s}", .{ source_id, url });
}
pub const chapterId = mangaId;

test "sync keeps state by URL, keeps downloaded drops, and carries state to re-added numbers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const details: models.Manga = .{ .url = "/m", .title = "Solo" };
    // The source lists newest first.
    const first = try syncSource(a, .{}, 1, details, &.{
        .{ .url = "/c3", .name = "Solo - Chapter 3", .dateUpload = 3000 },
        .{ .url = "/c2", .name = "Chapter 2" },
        .{ .url = "/c1", .name = "Chapter 1", .dateUpload = 1000 },
    }, 100, .{});
    try std.testing.expect(first.changed);
    // A first fetch is the back catalogue, not a release.
    try std.testing.expect(!first.found_release);
    var library = first.library;
    const m0 = library.manga[0];
    try std.testing.expectEqualStrings("1:/m", m0.id);
    try std.testing.expectEqual(100, m0.date_added);
    // Reading order is oldest first; names lose the title; numbers are recognized.
    try std.testing.expectEqualStrings("Chapter 1", m0.chapters[0].title);
    try std.testing.expectEqualStrings("Chapter 3", m0.chapters[2].title);
    try std.testing.expectEqual(3.0, m0.chapters[2].number);
    // Chapter 2 had no upload date: it takes the newest date seen above it.
    try std.testing.expectEqual(3000, m0.chapters[1].date_upload);
    library = (try setProgress(a, library, .{ .chapter_id = "1:/c1", .page = 4, .read = true, .now = 200 })).?;
    library = (try setPages(a, library, "1:/c2", &.{"downloads/a/b/0001.png"})).?;
    library = (try setProgress(a, library, .{ .chapter_id = "1:/c3", .page = 0, .read = true, .now = 210 })).?;
    // c3 is re-uploaded under a new URL, c2 and c1 vanish, c4 is new.
    const second = try syncSource(a, library, 1, details, &.{
        .{ .url = "/c4", .name = "Chapter 4" },
        .{ .url = "/c3-new", .name = "Chapter 3" },
    }, 300, .{});
    try std.testing.expect(second.found_release);
    const m = second.library.manga[0];
    // c1 (read, not downloaded) is gone; c2 stays for its pages.
    try std.testing.expect(second.library.manga[0].chapters.len == 3);
    var c3_new: ?Chapter = null;
    var has_c2 = false;
    for (m.chapters) |ch| {
        if (std.mem.eql(u8, ch.id, "1:/c3-new")) c3_new = ch;
        if (std.mem.eql(u8, ch.id, "1:/c2")) has_c2 = true;
    }
    try std.testing.expect(has_c2);
    // The re-added chapter 3 inherits the removed one's read state and fetch date.
    try std.testing.expect(c3_new.?.read);
    try std.testing.expectEqual(100 + 3, c3_new.?.date_fetch);
    // Only chapter 4 is new to the reader.
    try std.testing.expectEqual(1, second.new_chapters.len);
    try std.testing.expectEqualStrings("1:/c4", second.new_chapters[0]);
    // Nothing changed: nothing reported.
    const third = try syncSource(a, second.library, 1, details, &.{
        .{ .url = "/c4", .name = "Chapter 4" },
        .{ .url = "/c3-new", .name = "Chapter 3" },
    }, 400, .{});
    try std.testing.expect(!third.changed);
    try validate(std.testing.allocator, third.library);
}

test "merge keeps read state and pages for local titles" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var library = try merge(a, .{}, .{ .id = "local:T", .title = "T", .chapters = &.{.{ .id = "local:T/1", .title = "1", .pages = &.{"local/T/1/01.png"} }} }, 5);
    library = (try setProgress(a, library, .{ .chapter_id = "local:T/1", .page = 2, .now = 6 })).?;
    library = try merge(a, library, .{ .id = "local:T", .title = "T", .chapters = &.{.{ .id = "local:T/1", .title = "1", .pages = &.{"local/T/1/01.png"} }} }, 7);
    try std.testing.expectEqual(2, library.manga[0].chapters[0].last_page_read);
    try std.testing.expectEqual(5, library.manga[0].date_added);
}

test "version 1 libraries load with defaults; duplicates and unsafe paths are rejected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v1 =
        \\{"version":1,"manga":[{"id":"local:T","title":"T","chapters":[{"id":"local:T/1","title":"1","pages":["T/1/01.jpg"]}]}]}
    ;
    const library = try std.json.parseFromSliceLeaky(Library, a, v1, models.parse_options);
    try validate(std.testing.allocator, library);
    try std.testing.expect(!library.manga[0].chapters[0].read);
    var bad = library;
    bad.manga = &.{ library.manga[0], library.manga[0] };
    try std.testing.expectError(error.DuplicateManga, validate(std.testing.allocator, bad));
    try std.testing.expect(!safePath("../x"));
    try std.testing.expect(!safePath("/abs"));
    try std.testing.expect(safePath("downloads/a/0001.png"));
}

test "natural order compares numbers by value" {
    try std.testing.expect(naturalLess({}, "Chapter 2", "Chapter 10"));
    try std.testing.expect(naturalLess({}, "page 009", "page 10"));
    try std.testing.expect(!naturalLess({}, "b", "A"));
}

test "reading state lives in its own file and overlays the library" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var store: Store = .{ .io = io, .dir = try tmp.dir.realPathFileAlloc(io, ".", a) };
    const manga: Manga = .{ .id = "1:/m", .title = "M", .chapters = &.{ .{ .id = "1:/c1", .title = "1" }, .{ .id = "1:/c2", .title = "2" } } };
    try store.save(std.testing.allocator, try merge(a, .{}, manga, 1));
    const before = try tmp.dir.statFile(io, Store.file_name, .{});
    _ = try store.setProgress(std.testing.allocator, &.{.{ .chapter_id = "1:/c2", .page = 7, .now = 50, .read_ms = 1000 }});
    _ = try store.setProgress(std.testing.allocator, &.{.{ .chapter_id = "1:/c2", .page = 9, .read = true, .now = 60, .read_ms = 500 }});
    const after = try tmp.dir.statFile(io, Store.file_name, .{});
    try std.testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
    const loaded = try store.load(a);
    const ch = loaded.manga[0].chapters[1];
    try std.testing.expectEqual(9, ch.last_page_read);
    try std.testing.expect(ch.read);
    try std.testing.expectEqual(60, ch.last_read);
    try std.testing.expectEqual(1500, ch.read_ms);
    // A full save keeps the reading state.
    try store.save(std.testing.allocator, loaded);
    try std.testing.expectEqual(9, (try store.load(a)).manga[0].chapters[1].last_page_read);
}

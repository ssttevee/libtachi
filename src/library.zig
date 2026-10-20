//! The user's library: titles, their chapters, read progress and downloaded
//! pages, persisted as one JSON file. Nothing here needs the JVM, so a UI
//! process can own the library while extensions run elsewhere.
const std = @import("std");
const Io = std.Io;
const models = @import("models.zig");

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
    /// When the chapter first appeared in the library, in milliseconds since the epoch.
    date_fetch: i64 = 0,

    pub fn downloaded(self: Chapter) bool {
        return self.pages.len > 0;
    }
};

pub const Manga = struct {
    /// `<source id>:<url>` for source titles, `local:<series>` for local ones.
    id: []const u8,
    title: []const u8,
    author: []const u8 = "",
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
};

pub const Category = struct {
    id: u32,
    name: []const u8,
    order: u32 = 0,
};

pub const Library = struct {
    version: u32 = version,
    manga: []const Manga = &.{},
    categories: []const Category = &.{},

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
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| if (std.mem.eql(u8, part, "..") or part.len == 0) return false;
    return true;
}

pub fn validate(gpa: std.mem.Allocator, library: Library) ValidateError!void {
    if (library.version == 0 or library.version > version) return error.UnsupportedLibraryVersion;
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    defer ids.deinit(gpa);
    for (library.manga) |m| {
        if (m.id.len == 0 or m.title.len == 0) return error.InvalidManga;
        if ((try ids.getOrPut(gpa, m.id)).found_existing) return error.DuplicateManga;
    }
    ids.clearRetainingCapacity();
    for (library.manga) |m| for (m.chapters) |ch| {
        if (ch.id.len == 0) return error.InvalidChapter;
        if ((try ids.getOrPut(gpa, ch.id)).found_existing) return error.DuplicateChapter;
        for (ch.pages) |path| if (!safePath(path)) return error.UnsafePagePath;
    };
}

/// `library.json` in a directory, plus the page files it refers to.
/// Edits from different threads are serialized; reads may run at any time,
/// because every save replaces the file atomically.
pub const Store = struct {
    io: Io,
    /// The library directory; page paths are relative to it.
    dir: []const u8,
    mutex: Io.Mutex = .init,

    pub const file_name = "library.json";

    /// The library, allocated in `arena`; empty if there is no file yet.
    pub fn load(self: *Store, arena: std.mem.Allocator) !Library {
        const path = try std.fs.path.join(arena, &.{ self.dir, file_name });
        const bytes = Io.Dir.cwd().readFileAlloc(self.io, path, arena, .limited(64 << 20)) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        const library = try std.json.parseFromSliceLeaky(Library, arena, bytes, models.parse_options);
        try validate(arena, library);
        return library;
    }

    /// Replaces the library file atomically.
    pub fn save(self: *Store, gpa: std.mem.Allocator, library: Library) !void {
        var current = library;
        current.version = version;
        try validate(gpa, current);
        const path = try std.fs.path.join(gpa, &.{ self.dir, file_name });
        defer gpa.free(path);
        try writeJsonAtomic(gpa, self.io, path, current);
    }

    /// Loads the library, applies `edit` and saves the result, holding the
    /// store's lock throughout. `edit` returns the new library, allocated in
    /// `arena`, or null to leave the file alone.
    pub fn update(self: *Store, arena: std.mem.Allocator, context: anytype, comptime edit: fn (@TypeOf(context), std.mem.Allocator, Library) anyerror!?Library) !Library {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const current = try self.load(arena);
        const next = try edit(context, arena, current) orelse return current;
        try self.save(arena, next);
        return next;
    }

    /// Absolute path of a page file the library refers to.
    pub fn pagePath(self: *const Store, gpa: std.mem.Allocator, relative: []const u8) ![:0]u8 {
        if (!safePath(relative)) return error.UnsafePagePath;
        return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ self.dir, relative }, 0);
    }
};

pub fn writeJsonAtomic(gpa: std.mem.Allocator, io: Io, path: []const u8, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(gpa, value, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });
    defer gpa.free(bytes);
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

/// Like `merge`, for a source's full chapter list: chapters the source no
/// longer lists are dropped unless they have downloaded pages.
pub fn refresh(arena: std.mem.Allocator, library: Library, manga: Manga, now: i64) !Library {
    return apply(arena, library, manga, now, true);
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
};

/// Records reading progress; null if nothing changed or the chapter is unknown.
pub fn setProgress(arena: std.mem.Allocator, library: Library, progress: Progress) !?Library {
    for (library.manga, 0..) |m, mi| for (m.chapters, 0..) |ch, ci| {
        if (!std.mem.eql(u8, ch.id, progress.chapter_id)) continue;
        const read = ch.read or progress.read;
        if (ch.last_page_read == progress.page and ch.read == read) return null;
        const chapters = try arena.dupe(Chapter, m.chapters);
        chapters[ci].last_page_read = progress.page;
        chapters[ci].read = read;
        chapters[ci].last_read = progress.now;
        const titles = try arena.dupe(Manga, library.manga);
        titles[mi].chapters = chapters;
        var result = library;
        result.manga = titles;
        return result;
    };
    return null;
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

test "merge keeps read state and pages; refresh drops unlisted chapters unless downloaded" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first: Manga = .{ .id = "1:/m", .title = "M", .source_id = 1, .chapters = &.{
        .{ .id = "1:/c1", .title = "Chapter 1" },
        .{ .id = "1:/c2", .title = "Chapter 2" },
        .{ .id = "1:/c3", .title = "Chapter 3" },
    } };
    var library = try merge(a, .{}, first, 100);
    try std.testing.expectEqual(100, library.manga[0].date_added);
    library = (try setProgress(a, library, .{ .chapter_id = "1:/c1", .page = 4, .read = true, .now = 200 })).?;
    library = (try setPages(a, library, "1:/c2", &.{"downloads/a/b/0001.png"})).?;
    const listed: Manga = .{ .id = "1:/m", .title = "M renamed", .source_id = 1, .chapters = &.{
        .{ .id = "1:/c1", .title = "Chapter 1 (fixed)" },
        .{ .id = "1:/c10", .title = "Chapter 10" },
    } };
    library = try refresh(a, library, listed, 300);
    const m = library.manga[0];
    try std.testing.expectEqualStrings("M renamed", m.title);
    try std.testing.expectEqual(100, m.date_added);
    try std.testing.expectEqual(3, m.chapters.len);
    try std.testing.expectEqualStrings("Chapter 1 (fixed)", m.chapters[0].title);
    try std.testing.expect(m.chapters[0].read);
    try std.testing.expectEqual(4, m.chapters[0].last_page_read);
    try std.testing.expectEqual(100, m.chapters[0].date_fetch);
    try std.testing.expectEqualStrings("1:/c2", m.chapters[1].id);
    try std.testing.expectEqualStrings("Chapter 10", m.chapters[2].title);
    try std.testing.expectEqual(300, m.chapters[2].date_fetch);
    try validate(std.testing.allocator, library);
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

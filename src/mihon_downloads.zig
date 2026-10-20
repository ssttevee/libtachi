//! Mihon's downloads folder (mihonapp/mihon 487c313): `<source>/<title>/<chapter>`
//! under its `downloads` directory, each chapter a CBZ (the default) or a
//! folder of `001.jpg`-style pages with a ComicInfo.xml, all named by
//! Mihon's `DiskUtil.buildValidFilename`. `exportChapter` writes a chapter
//! that way; `scan` finds chapters there for an import.
const std = @import("std");
const Io = std.Io;
const library = @import("library.zig");
const archive = @import("archive.zig");
const comicinfo = @import("comicinfo.zig");
const downloads = @import("downloads.zig");

/// Mihon's longest file name, in UTF-8 bytes.
pub const max_name_bytes = 240;

/// Mihon's naming settings: `disallow_non_ascii_filenames` and
/// `pref_enable_chapter_name_hash`.
pub const Naming = struct {
    disallow_non_ascii: bool = false,
    chapter_hash: bool = false,
};

/// Mihon's `buildValidFilename`: dots and spaces trimmed from both ends,
/// FAT-invalid characters replaced with `_`, optionally non-ASCII spelled as
/// UTF-8 hex, cut to `max_bytes` without splitting a character; empty names
/// become "(invalid)".
pub fn validFilename(a: std.mem.Allocator, name: []const u8, max_bytes: usize, disallow_non_ascii: bool) ![]const u8 {
    const trimmed = std.mem.trim(u8, name, ". ");
    if (trimmed.len == 0) return "(invalid)";
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < trimmed.len) {
        const len = std.unicode.utf8ByteSequenceLength(trimmed[i]) catch 1;
        const bytes = trimmed[i..@min(trimmed.len, i + len)];
        i += bytes.len;
        if (bytes.len == 1 and bytes[0] < 0x80) {
            const c = bytes[0];
            const invalid = c <= 0x1f or c == 0x7f or std.mem.indexOfScalar(u8, "\"*/:<>?\\|", c) != null;
            try out.append(a, if (invalid) '_' else c);
        } else if (disallow_non_ascii) {
            // Kotlin hexes each UTF-16 unit: a lone surrogate encodes as '?'.
            const cp = std.unicode.utf8Decode(bytes) catch 0xfffd;
            if (cp >= 0x10000) try out.appendSlice(a, "3f3f") else for (bytes) |b| try out.print(a, "{x:0>2}", .{b});
        } else try out.appendSlice(a, bytes);
    }
    return truncate(out.items, max_bytes);
}

/// The longest prefix of `s` within `max_bytes` that ends on a character boundary.
fn truncate(s: []const u8, max_bytes: usize) []const u8 {
    if (s.len <= max_bytes) return s;
    var end = max_bytes;
    while (end > 0 and s[end] & 0xc0 == 0x80) end -= 1;
    return s[0..end];
}

/// A source's folder: its `toString()`, `name (LANG)`.
pub fn sourceDirName(a: std.mem.Allocator, name: []const u8, lang: []const u8, naming: Naming) ![]const u8 {
    const upper = try std.ascii.allocUpperString(a, lang);
    return validFilename(a, try std.fmt.allocPrint(a, "{s} ({s})", .{ name, upper }), max_name_bytes, naming.disallow_non_ascii);
}

pub fn mangaDirName(a: std.mem.Allocator, title: []const u8, naming: Naming) ![]const u8 {
    return validFilename(a, title, max_name_bytes, naming.disallow_non_ascii);
}

const Parts = struct {
    name: []const u8,
    scanlator: ?[]const u8,
    url: []const u8,

    fn init(name: []const u8, scanlator: ?[]const u8, url: []const u8) Parts {
        const blank = std.mem.trim(u8, name, " \t\r\n").len == 0;
        return .{ .name = if (blank) "Chapter" else name, .scanlator = scanlator, .url = url };
    }

    fn hasScanlator(self: Parts) bool {
        const s = self.scanlator orelse return false;
        return std.mem.trim(u8, s, " \t\r\n").len > 0;
    }

    fn hashSuffix(self: Parts, a: std.mem.Allocator) ![]const u8 {
        var digest: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(self.url, &digest, .{});
        const hex = std.fmt.bytesToHex(digest, .lower);
        return std.fmt.allocPrint(a, "_{s}", .{hex[0..6]});
    }

    /// The current name: scanlator and name made valid together, leaving
    /// room for the hash and `.cbz`.
    fn dirName(self: Parts, a: std.mem.Allocator, naming: Naming) ![]const u8 {
        const joined = if (self.hasScanlator()) try std.fmt.allocPrint(a, "{s}_{s}", .{ self.scanlator.?, self.name }) else self.name;
        const valid = try validFilename(a, joined, max_name_bytes - 11, naming.disallow_non_ascii);
        return if (naming.chapter_hash) std.mem.concat(a, u8, &.{ valid, try self.hashSuffix(a) }) else valid;
    }

    /// Mihon 0.21.0 and 0.21.1's name, which made only the chapter name valid.
    fn splitDirName(self: Parts, a: std.mem.Allocator, naming: Naming, sanitize_scanlator: bool) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        if (self.hasScanlator()) {
            try out.appendSlice(a, if (sanitize_scanlator) try validFilename(a, self.scanlator.?, max_name_bytes, false) else self.scanlator.?);
            try out.append(a, '_');
        }
        try out.appendSlice(a, try validFilename(a, self.name, max_name_bytes - 11, naming.disallow_non_ascii));
        if (naming.chapter_hash) try out.appendSlice(a, try self.hashSuffix(a));
        return out.items;
    }
};

/// A chapter's folder (or, with `.cbz`, archive) name under `naming`.
pub fn chapterDirName(a: std.mem.Allocator, name: []const u8, scanlator: ?[]const u8, url: []const u8, naming: Naming) ![]const u8 {
    return Parts.init(name, scanlator, url).dirName(a, naming);
}

/// Every name Mihon looks a chapter up by, current first, each also as a
/// `.cbz`: the current name, then every older naming scheme.
pub fn chapterDirNames(a: std.mem.Allocator, name: []const u8, scanlator: ?[]const u8, url: []const u8, naming: Naming) ![]const []const u8 {
    const parts = Parts.init(name, scanlator, url);
    var names: std.ArrayList([]const u8) = .empty;
    try names.append(a, try parts.dirName(a, naming));
    const v1 = if (parts.hasScanlator()) try std.fmt.allocPrint(a, "{s}_{s}", .{ parts.scanlator.?, parts.name }) else parts.name;
    try names.append(a, try validFilename(a, v1, max_name_bytes, false));
    const permutations = [_]Naming{ .{}, .{ .chapter_hash = true }, .{ .disallow_non_ascii = true }, .{ .disallow_non_ascii = true, .chapter_hash = true } };
    for (permutations) |n| try names.append(a, try parts.dirName(a, n));
    for (permutations) |n| try names.append(a, try parts.splitDirName(a, n, true));
    // Unsanitized scanlators: one with a "/" nested its folder, never found.
    if (parts.scanlator) |s| if (std.mem.indexOfScalar(u8, s, '/') == null) {
        for (permutations) |n| try names.append(a, try parts.splitDirName(a, n, false));
    };
    var unique: std.ArrayList([]const u8) = .empty;
    for (names.items) |n| {
        const seen = for (unique.items) |u| {
            if (std.mem.eql(u8, u, n)) break true;
        } else false;
        if (seen) continue;
        try unique.append(a, n);
        try unique.append(a, try std.mem.concat(a, u8, &.{ n, ".cbz" }));
    }
    return unique.items;
}

/// The ComicInfo.xml Mihon's downloader writes for a chapter.
pub fn comicInfoXml(a: std.mem.Allocator, manga: library.Manga, chapter: library.Chapter, source_name: []const u8, categories: []const []const u8, urls: []const []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ComicInfo xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">");
    try comicinfo.field(w, "Title", chapter.title);
    try comicinfo.field(w, "Series", manga.title);
    if (chapter.number >= 0) {
        if (@rem(chapter.number, 1) == 0) try w.print("<Number>{d}</Number>", .{@as(i64, @intFromFloat(chapter.number))}) else try w.print("<Number>{d}</Number>", .{chapter.number});
    }
    const remote = manga.remote;
    const description = if (manga.description.len > 0) manga.description else if (remote) |r| r.description orelse "" else "";
    if (description.len > 0) try comicinfo.field(w, "Summary", description);
    const author = if (manga.author.len > 0) manga.author else if (remote) |r| r.author orelse "" else "";
    if (author.len > 0) try comicinfo.field(w, "Writer", author);
    const artist = if (manga.artist.len > 0) manga.artist else if (remote) |r| r.artist orelse "" else "";
    if (artist.len > 0) try comicinfo.field(w, "Penciller", artist);
    if (chapter.scanlator) |s| try comicinfo.field(w, "Translator", s);
    const genre = if (manga.genre.len > 0) manga.genre else if (remote) |r| r.genre orelse "" else "";
    if (genre.len > 0) try comicinfo.field(w, "Genre", genre);
    try comicinfo.field(w, "Web", try std.mem.join(a, " ", urls));
    try comicinfo.dateFields(w, chapter.date_upload);
    const status: usize = @intCast(std.math.clamp(manga.status(), 0, comicinfo.statuses.len - 1));
    try w.writeAll("<ty:PublishingStatusTachiyomi xmlns:ty=\"http://www.w3.org/2001/XMLSchema\">");
    try w.writeAll(comicinfo.statuses[status]);
    try w.writeAll("</ty:PublishingStatusTachiyomi>");
    if (categories.len > 0) {
        try w.writeAll("<ty:Categories xmlns:ty=\"http://www.w3.org/2001/XMLSchema\">");
        try escaped(w, try std.mem.join(a, ", ", categories));
        try w.writeAll("</ty:Categories>");
    }
    try w.writeAll("<mh:SourceMihon xmlns:mh=\"http://www.w3.org/2001/XMLSchema\">");
    try escaped(w, source_name);
    try w.writeAll("</mh:SourceMihon></ComicInfo>");
    return out.toOwnedSlice();
}

fn escaped(w: *Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        else => try w.writeByte(c),
    };
}

/// One chapter's pages, read from wherever the library keeps them.
pub const Page = struct { bytes: []const u8 };

/// Writes a chapter as Mihon's downloader does, under `<root>/<source dir>/<title dir>/`:
/// pages named by their one-based number, zero-padded to at least three
/// digits, with a ComicInfo.xml, as a CBZ or a folder. Replaces an existing copy.
pub fn exportChapter(a: std.mem.Allocator, io: Io, manga_dir: []const u8, chapter_dir: []const u8, pages: []const []const u8, comic_info: []const u8, cbz: bool) !void {
    const width = @max(3, std.fmt.count("{d}", .{pages.len}));
    var entries: std.ArrayList(archive.Entry) = .empty;
    for (pages, 1..) |bytes, number| {
        const ext = downloads.imageExtension(bytes) orelse return error.UnsupportedImageFormat;
        const name = try std.fmt.allocPrint(a, "{d:0>[2]}.{s}", .{ number, ext, width });
        try entries.append(a, .{ .name = name, .data = bytes });
    }
    try entries.append(a, .{ .name = "ComicInfo.xml", .data = comic_info });
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, manga_dir);
    const target = try std.fs.path.join(a, &.{ manga_dir, chapter_dir });
    if (cbz) {
        const file = try std.mem.concat(a, u8, &.{ target, ".cbz" });
        const temp = try std.mem.concat(a, u8, &.{ file, "_tmp" });
        try library.writeAtomic(a, io, temp, try archive.zip(a, entries.items));
        try cwd.rename(temp, cwd, file, io);
    } else {
        const temp = try std.mem.concat(a, u8, &.{ target, "_tmp" });
        try cwd.deleteTree(io, temp);
        try cwd.createDirPath(io, temp);
        for (entries.items) |e| try library.writeAtomic(a, io, try std.fs.path.join(a, &.{ temp, e.name }), e.data);
        try cwd.deleteTree(io, target);
        try cwd.rename(temp, cwd, target, io);
    }
}

/// A chapter found in a Mihon downloads folder.
pub const Found = struct {
    /// Absolute path of the chapter's CBZ or folder.
    path: []const u8,
    cbz: bool,
};

/// Finds a chapter under `manga_dir` by any name Mihon may have given it;
/// incomplete (`_tmp`) copies don't count.
pub fn findChapter(a: std.mem.Allocator, io: Io, manga_dir: []const u8, names: []const []const u8) !?Found {
    for (names) |name| {
        const path = try std.fs.path.join(a, &.{ manga_dir, name });
        const st = Io.Dir.cwd().statFile(io, path, .{}) catch continue;
        const cbz = std.mem.endsWith(u8, name, ".cbz");
        if (cbz and st.kind == .file) return .{ .path = path, .cbz = true };
        if (!cbz and st.kind == .directory) return .{ .path = path, .cbz = false };
    }
    return null;
}

/// Page images of a found chapter in natural order, without ComicInfo.xml,
/// `.nomedia` or temporary files.
pub fn pageNames(a: std.mem.Allocator, io: Io, found: Found) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    if (found.cbz) {
        for (try archive.metadata(a, io, found.path)) |e| if (archive.isImage(e.name) and archive.visible(e.name)) try names.append(a, e.name);
    } else {
        var dir = try Io.Dir.cwd().openDir(io, found.path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |e| {
            if (e.kind != .file or e.name[0] == '.' or !archive.isImage(e.name)) continue;
            try names.append(a, try a.dupe(u8, e.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, library.naturalLess);
    return names.items;
}

// ---- tests ---------------------------------------------------------------------

const testing = std.testing;

test "file names follow Mihon's buildValidFilename" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("(invalid)", try validFilename(a, " . .", max_name_bytes, false));
    try testing.expectEqualStrings("a_b_c_d", try validFilename(a, ". a:b?c|d .", max_name_bytes, false));
    try testing.expectEqualStrings("tab_here", try validFilename(a, "tab\there", max_name_bytes, false));
    try testing.expectEqualStrings("Café", try validFilename(a, "Café", max_name_bytes, false));
    try testing.expectEqualStrings("Cafc3a9", try validFilename(a, "Café", max_name_bytes, true));
    try testing.expectEqualStrings("x3f3f", try validFilename(a, "x😀", max_name_bytes, true));
    // A cut never splits a character.
    try testing.expectEqualStrings("ab", try validFilename(a, "abé", 3, false));
    try testing.expectEqualStrings("MangaDex (EN)", try sourceDirName(a, "MangaDex", "en", .{}));
}

test "chapter folders carry the scanlator, the hash and older names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("Group_Ch. 1", try chapterDirName(a, "Ch. 1", "Group", "/c/1", .{}));
    try testing.expectEqualStrings("Chapter", try chapterDirName(a, "  ", null, "/c/1", .{}));
    const hashed = try chapterDirName(a, "Ch. 1", null, "/c/1", .{ .chapter_hash = true });
    try testing.expect(std.mem.startsWith(u8, hashed, "Ch. 1_") and hashed.len == "Ch. 1_".len + 6);
    const names = try chapterDirNames(a, ".Ch 1", "A/B", "/c/1", .{});
    try testing.expectEqualStrings("A_B_.Ch 1", names[0]);
    try testing.expectEqualStrings("A_B_.Ch 1.cbz", names[1]);
    var has_split = false;
    for (names) |n| has_split = has_split or std.mem.eql(u8, n, "A_B_Ch 1");
    try testing.expect(has_split);
}

test "exported chapters read back as Mihon lays them out" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    const manga: library.Manga = .{ .id = "1:/m", .title = "M & Co", .source_id = 1, .remote = .{ .url = "/m", .title = "M & Co", .status = 1 } };
    const chapter: library.Chapter = .{ .id = "1:/c", .title = "Ch. 2.5", .number = 2.5, .scanlator = "G" };
    const xml = try comicInfoXml(a, manga, chapter, "Dex", &.{"Reading"}, &.{"https://x/c"});
    try testing.expect(std.mem.indexOf(u8, xml, "<Series>M &amp; Co</Series>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, "<Number>2.5</Number>") != null);
    try testing.expect(std.mem.indexOf(u8, xml, ">Ongoing</ty:PublishingStatusTachiyomi>") != null);
    const manga_dir = try std.fs.path.join(a, &.{ root, "Dex (EN)", try mangaDirName(a, manga.title, .{}) });
    const pages: []const []const u8 = &.{ "\x89PNG\r\n\x1a\none", "\xff\xd8\xfftwo" };
    const dir_name = try chapterDirName(a, chapter.title, chapter.scanlator, "/c", .{});
    for ([_]bool{ true, false }) |cbz| {
        try exportChapter(a, io, manga_dir, dir_name, pages, xml, cbz);
        const found = (try findChapter(a, io, manga_dir, try chapterDirNames(a, chapter.title, chapter.scanlator, "/c", .{}))).?;
        try testing.expectEqual(cbz, found.cbz);
        const names = try pageNames(a, io, found);
        try testing.expectEqual(2, names.len);
        try testing.expectEqualStrings("001.png", names[0]);
        try testing.expectEqualStrings("002.jpg", names[1]);
        if (cbz) try Io.Dir.cwd().deleteFile(io, found.path);
    }
}

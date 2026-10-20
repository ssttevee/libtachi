//! Local series under `local/`, with folder, ZIP/CBZ, TAR/CBT and EPUB chapters.
//! RAR/CBR and 7z/CB7 are skipped: the standard library has no decoder.
//! Metadata is read without Mihon's side effects (JSON conversion and .noxml).
const std = @import("std");
const Io = std.Io;
const library = @import("library.zig");
const archive = @import("archive.zig");
const comic = @import("comicinfo.zig");
const recognition = @import("recognition.zig");

pub const folder = "local";

fn names(a: std.mem.Allocator, io: Io, dir: Io.Dir) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (!archive.visible(e.name) or (e.kind != .directory and e.kind != .file)) continue;
        try result.append(a, try a.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, result.items, {}, library.naturalLess);
    return result.items;
}

fn optionalFile(a: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8) !?[]const u8 {
    return dir.readFileAlloc(io, name, a, .limited(4 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

/// Image paths and optional ComicInfo for a folder or supported archive.
pub const Pages = struct { pages: []const []const u8, metadata: ?[]const u8 = null };
pub fn chapterPages(a: std.mem.Allocator, io: Io, dir: []const u8, relative: []const u8) !Pages {
    if (!library.safePath(relative)) return error.UnsafePagePath;
    const path = try std.fs.path.join(a, &.{ dir, relative });
    const stat = try Io.Dir.cwd().statFile(io, path, .{});
    var pages: std.ArrayList([]const u8) = .empty;
    if (stat.kind == .directory) {
        var d = try Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer d.close(io);
        for (try names(a, io, d)) |name| {
            if (!archive.isImage(name) or (try d.statFile(io, name, .{})).kind != .file) continue;
            try pages.append(a, try std.fs.path.join(a, &.{ relative, name }));
        }
        return .{ .pages = pages.items, .metadata = try optionalFile(a, io, d, "ComicInfo.xml") };
    }
    const entries = try archive.metadata(a, io, path);
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".epub")) {
        for (try epubPages(a, entries)) |name| try pages.append(a, try std.fmt.allocPrint(a, "{s}#{s}", .{ relative, name }));
    } else {
        for (entries) |e| if (archive.isImage(e.name)) {
            try pages.append(a, try std.fmt.allocPrint(a, "{s}#{s}", .{ relative, e.name }));
        };
        std.mem.sort([]const u8, pages.items, {}, library.naturalLess);
    }
    return .{ .pages = pages.items, .metadata = archive.find(entries, "ComicInfo.xml") };
}

/// Resolves EPUB links inside the archive; escaping its root is rejected.
fn resolve(a: std.mem.Allocator, base: []const u8, href: []const u8) ![]const u8 {
    if (href.len == 0 or href[0] == '/' or std.mem.indexOfScalar(u8, href, '\\') != null or std.mem.indexOfScalar(u8, href, ':') != null) return error.UnsafePagePath;
    var parts: std.ArrayList([]const u8) = .empty;
    const combined = try std.fmt.allocPrint(a, "{s}/{s}", .{ base, href[0 .. std.mem.indexOfAny(u8, href, "?#") orelse href.len] });
    var it = std.mem.splitScalar(u8, combined, '/');
    while (it.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.pop() == null) return error.UnsafePagePath;
        } else try parts.append(a, p);
    }
    const result = try std.mem.join(a, "/", parts.items);
    if (!archive.visible(result)) return error.UnsafePagePath;
    return result;
}

fn epubPages(a: std.mem.Allocator, entries: []const archive.Entry) ![][]const u8 {
    var opf: []const u8 = "OEBPS/content.opf";
    if (archive.find(entries, "META-INF/container.xml")) |xml| {
        var tags: comic.Tags = .{ .rest = xml };
        while (tags.next()) |t| if (std.mem.eql(u8, t.name, "rootfile")) {
            opf = (try t.attr(a, "full-path")) orelse opf;
            break;
        };
    }
    if (!archive.visible(opf)) return error.UnsafePagePath;
    const xml = archive.find(entries, opf) orelse return error.InvalidEpub;
    const Item = struct { href: []const u8, media: []const u8, cover: bool };
    var manifest: std.StringHashMapUnmanaged(Item) = .empty;
    var tags: comic.Tags = .{ .rest = xml };
    var cover_id: ?[]const u8 = null;
    while (tags.next()) |t| {
        if (std.mem.eql(u8, t.name, "meta") and std.mem.eql(u8, (try t.attr(a, "name")) orelse "", "cover")) cover_id = try t.attr(a, "content");
        if (!std.mem.eql(u8, t.name, "item")) continue;
        const id = (try t.attr(a, "id")) orelse continue;
        const href = (try t.attr(a, "href")) orelse continue;
        try manifest.put(a, id, .{ .href = href, .media = (try t.attr(a, "media-type")) orelse "", .cover = std.mem.indexOf(u8, (try t.attr(a, "properties")) orelse "", "cover-image") != null });
    }
    var cover: ?[]const u8 = null;
    var mit = manifest.iterator();
    while (mit.next()) |e| if (e.value_ptr.cover or (cover_id != null and std.mem.eql(u8, e.key_ptr.*, cover_id.?))) {
        cover = try resolve(a, std.fs.path.dirname(opf) orelse "", e.value_ptr.href);
    };
    var result: std.ArrayList([]const u8) = .empty;
    tags = .{ .rest = xml };
    while (tags.next()) |t| {
        if (!std.mem.eql(u8, t.name, "itemref")) continue;
        const item = manifest.get((try t.attr(a, "idref")) orelse continue) orelse continue;
        if (!std.mem.eql(u8, item.media, "application/xhtml+xml")) continue;
        const page = try resolve(a, std.fs.path.dirname(opf) orelse "", item.href);
        var images: comic.Tags = .{ .rest = archive.find(entries, page) orelse continue };
        while (images.next()) |img| {
            const href = if (std.mem.eql(u8, img.name, "img")) try img.attr(a, "src") else if (std.mem.eql(u8, img.name, "image")) (try img.attr(a, "xlink:href")) orelse (try img.attr(a, "href")) else null;
            const image = try resolve(a, std.fs.path.dirname(page) orelse "", href orelse continue);
            if (cover != null and std.mem.eql(u8, image, cover.?)) continue;
            if (archive.isImage(image) and archive.find(entries, image) != null) try result.append(a, image);
        }
    }
    return result.items;
}

fn details(a: std.mem.Allocator, data: []const u8, m: *library.Manga) !void {
    const Details = struct { title: ?[]const u8 = null, author: ?[]const u8 = null, artist: ?[]const u8 = null, description: ?[]const u8 = null, genre: ?[]const []const u8 = null, status: ?i32 = null };
    const d = try std.json.parseFromSliceLeaky(Details, a, data, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    m.title = d.title orelse m.title;
    m.author = d.author orelse m.author;
    m.artist = d.artist orelse m.artist;
    m.description = d.description orelse m.description;
    if (d.genre) |genres| m.genre = try std.mem.join(a, ", ", genres);
    m.publishing_status = d.status orelse m.publishing_status;
}

fn chapterLess(_: void, lhs: library.Chapter, rhs: library.Chapter) bool {
    return library.naturalLess({}, rhs.title, lhs.title);
}

/// Scans visible series. Local ids retain filenames even when metadata renames them.
pub fn scan(a: std.mem.Allocator, io: Io, dir: []const u8) ![]const library.Manga {
    const root = try std.fs.path.join(a, &.{ dir, folder });
    var local = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer local.close(io);
    var titles: std.ArrayList(library.Manga) = .empty;
    for (try names(a, io, local)) |series| {
        if ((try local.statFile(io, series, .{})).kind != .directory) continue;
        var sd = try local.openDir(io, series, .{ .iterate = true });
        defer sd.close(io);
        var m: library.Manga = .{ .id = try std.fmt.allocPrint(a, "local:{s}", .{series}), .title = series };
        const series_xml = try optionalFile(a, io, sd, "ComicInfo.xml");
        const json = if (series_xml == null) try optionalFile(a, io, sd, "details.json") else null;
        if (series_xml) |xml| {
            try comic.manga(a, xml, &m);
        } else if (json) |data| try details(a, data, &m);
        var chapters: std.ArrayList(library.Chapter) = .empty;
        var fallback_metadata = false;
        for (try names(a, io, sd)) |name| {
            const stat = try sd.statFile(io, name, .{});
            if (stat.kind == .file and archive.isImage(name) and std.ascii.eqlIgnoreCase(std.fs.path.stem(name), "cover")) m.cover = try std.fs.path.join(a, &.{ folder, series, name });
            if (stat.kind != .directory and (stat.kind != .file or !archive.supported(name))) continue;
            const relative = try std.fs.path.join(a, &.{ folder, series, name });
            const content = chapterPages(a, io, dir, relative) catch |err| switch (err) {
                error.OutOfMemory, error.Canceled => return err,
                else => continue,
            };
            if (content.pages.len == 0) continue;
            const title = if (stat.kind == .directory) name else std.fs.path.stem(name);
            var ch: library.Chapter = .{ .id = try std.fmt.allocPrint(a, "local:{s}/{s}", .{ series, name }), .title = title, .pages = content.pages, .date_upload = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_ms)), .number = try recognition.parseChapterNumber(a, m.title, title, -1) };
            if (content.metadata) |xml| {
                try comic.chapter(a, xml, &ch);
                if (series_xml == null and json == null and !fallback_metadata) {
                    try comic.manga(a, xml, &m);
                    fallback_metadata = true;
                }
            }
            try chapters.append(a, ch);
        }
        if (chapters.items.len == 0) continue;
        std.mem.sort(library.Chapter, chapters.items, {}, chapterLess);
        for (chapters.items, 0..) |*ch, i| ch.source_order = @intCast(i);
        m.chapters = chapters.items;
        if (m.cover == null) m.cover = chapters.items[chapters.items.len - 1].pages[0];
        try titles.append(a, m);
    }
    return titles.items;
}

test "local formats metadata covers and archive page extraction" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "local/Series/Chapter 1");
    try tmp.dir.createDirPath(io, "local/Json/Chapter 1");
    try tmp.dir.createDirPath(io, "local/.Hidden/Chapter 1");
    try tmp.dir.writeFile(io, .{ .sub_path = "local/Series/Chapter 1/1.jpg", .data = "folder" });
    try tmp.dir.writeFile(io, .{ .sub_path = "local/Series/Chapter 1/10.jpg", .data = "ten" });
    try tmp.dir.writeFile(io, .{ .sub_path = "local/Series/Chapter 1/2.jpg", .data = "two" });
    try tmp.dir.writeFile(io, .{ .sub_path = "local/Series/Chapter 1/.hidden.png", .data = "hidden" });
    try tmp.dir.writeFile(io, .{ .sub_path = "local/Series/cover.webp", .data = "cover" });
    try tmp.dir.writeFile(io, .{ .sub_path = "local/Json/Chapter 1/1.png", .data = "json page" });
    try tmp.dir.writeFile(io, .{ .sub_path = "local/Json/details.json", .data = "{\"title\":\"JSON title\",\"author\":\"Writer\",\"artist\":\"Artist\",\"description\":\"Summary\",\"genre\":[\"A\",\"B\"],\"status\":2}" });
    const xml = "<ComicInfo><Series>XML title</Series><Title>Chapter 2</Title><Number>2.5</Number><Writer>A &amp; B</Writer><Penciller>Artist</Penciller><Summary>Story</Summary><Genre>Action</Genre><Tags>Drama</Tags><Web>https://example.org</Web><Translator>Group</Translator><Year>2024</Year><Month>2</Month><Day>29</Day><ty:PublishingStatusTachiyomi xmlns:ty=\"http://www.w3.org/2001/XMLSchema\">Completed</ty:PublishingStatusTachiyomi></ComicInfo>";
    try tmp.dir.writeFile(io, .{ .sub_path = "local/Series/Chapter 2.cbz", .data = try archive.zip(a, &.{ .{ .name = "10.jpg", .data = "ten" }, .{ .name = "2.png", .data = "cbz page" }, .{ .name = "ComicInfo.xml", .data = xml }, .{ .name = ".hidden/1.png", .data = "hidden" }, .{ .name = "readme.txt", .data = "text" } }) });
    var tar: Io.Writer.Allocating = .init(a);
    var tw: std.tar.Writer = .{ .underlying_writer = &tar.writer };
    try tw.writeFileBytes("001.jpg", "tar page", .{});
    try tar.writer.splatByteAll(0, 1024);
    try tmp.dir.writeFile(io, .{ .sub_path = "local/Series/Chapter 3.cbt", .data = tar.written() });
    try tmp.dir.writeFile(io, .{ .sub_path = "local/Series/Chapter 4.epub", .data = try archive.zip(a, &.{
        .{ .name = "META-INF/container.xml", .data = "<container><rootfile full-path='OEBPS/content.opf'/></container>" },
        .{ .name = "OEBPS/content.opf", .data = "<package><manifest><item id='first' href='text/2.xhtml' media-type='application/xhtml+xml'/><item id='second' href='text/1.xhtml' media-type='application/xhtml+xml'/><item id='cover' href='images/cover.jpg' properties='cover-image'/></manifest><spine><itemref idref='first'/><itemref idref='second'/></spine></package>" },
        .{ .name = "OEBPS/text/2.xhtml", .data = "<html><img src='../images/cover.jpg'/><img src='../images/2.jpg'/></html>" },
        .{ .name = "OEBPS/text/1.xhtml", .data = "<html><svg><image xlink:href='../images/1.png'/></svg></html>" },
        .{ .name = "OEBPS/images/cover.jpg", .data = "cover" },
        .{ .name = "OEBPS/images/1.png", .data = "epub one" },
        .{ .name = "OEBPS/images/2.jpg", .data = "epub two" },
    }) });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const titles = try scan(a, io, dir);
    try std.testing.expectEqual(2, titles.len);
    try std.testing.expectEqualStrings("JSON title", titles[0].title);
    try std.testing.expectEqualStrings("A, B", titles[0].genre);
    try std.testing.expectEqualStrings("local/Json/Chapter 1/1.png", titles[0].cover.?);
    const m = titles[1];
    try std.testing.expectEqualStrings("XML title", m.title);
    try std.testing.expectEqualStrings("A & B", m.author);
    try std.testing.expectEqualStrings("Action, Drama", m.genre);
    try std.testing.expectEqual(2, m.status());
    try std.testing.expectEqualStrings("local/Series/cover.webp", m.cover.?);
    try std.testing.expectEqual(4, m.chapters.len);
    const epub = m.chapters[0];
    try std.testing.expectEqual(0, epub.source_order);
    try std.testing.expectEqual(2, epub.pages.len);
    try std.testing.expectEqualStrings("local/Series/Chapter 4.epub#OEBPS/images/2.jpg", epub.pages[0]);
    const cbz = m.chapters[2];
    try std.testing.expectEqualStrings("local:Series/Chapter 2.cbz", cbz.id);
    try std.testing.expectEqual(2.5, cbz.number);
    try std.testing.expectEqualStrings("Group", cbz.scanlator.?);
    try std.testing.expect(cbz.date_upload > 0);
    try std.testing.expectEqual(2, cbz.pages.len);
    const store: library.Store = .{ .dir = dir, .io = io };
    for ([_][]const u8{ cbz.pages[0], m.chapters[1].pages[0], epub.pages[0] }, [_][]const u8{ "cbz page", "tar page", "epub two" }) |page, expected| {
        const absolute = try store.pagePath(a, page);
        try std.testing.expect(std.mem.indexOf(u8, absolute, "/cache/pages/") != null);
        try std.testing.expectEqualStrings(expected, try Io.Dir.cwd().readFileAlloc(io, absolute, a, .limited(1024)));
    }
    try std.testing.expectEqualStrings("local/Series/Chapter 1/2.jpg", m.chapters[3].pages[1]);
    try std.testing.expect(!library.safePath("local/a.cbz#../x.png"));
    try std.testing.expect(!library.safePath("../a.cbz#x.png"));
    try std.testing.expect(!library.safePath("a.cbz#/x.png"));
    try std.testing.expect(!library.safePath("a.cbz#x#y"));
    try std.testing.expectError(error.UnsafePagePath, store.pagePath(a, "a.cbz#../x"));
    try std.testing.expectError(error.ArchivePageNotFound, store.pagePath(a, "local/Series/Chapter 2.cbz#missing.jpg"));
    try library.validate(a, .{ .manga = titles });
}

test "series ComicInfo overrides details and invalid dates preserve mtime" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ch: library.Chapter = .{ .id = "x", .title = "x", .date_upload = 123 };
    try comic.chapter(a, "<ComicInfo><Year>2023</Year><Month>2</Month><Day>31</Day></ComicInfo>", &ch);
    try std.testing.expectEqual(123, ch.date_upload);
    try comic.chapter(a, "<ComicInfo><Month>2</Month><Day>1</Day></ComicInfo>", &ch);
    try std.testing.expectEqual(123, ch.date_upload);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "local/Series/ch1");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "local/Series/ch1/1.png", .data = "one" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "local/Series/details.json", .data = "{\"title\":\"JSON\"}" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "local/Series/ComicInfo.xml", .data = "<ComicInfo><Series>XML</Series></ComicInfo>" });
    const m = (try scan(a, std.testing.io, try tmp.dir.realPathFileAlloc(std.testing.io, ".", a)))[0];
    try std.testing.expectEqualStrings("XML", m.title);
}

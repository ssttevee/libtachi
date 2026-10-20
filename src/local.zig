//! The local source: series the user put in the library directory's `local/`
//! folder, one subfolder per series and one per chapter, as Mihon lays it out.
const std = @import("std");
const Io = std.Io;
const library = @import("library.zig");

pub const folder = "local";

fn isImage(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    for ([_][]const u8{ ".jpg", ".jpeg", ".png" }) |known| if (std.ascii.eqlIgnoreCase(ext, known)) return true;
    return false;
}

/// Visible entries of `dir`: subdirectories, or image files, in natural order.
fn names(arena: std.mem.Allocator, io: Io, dir: Io.Dir, directories: bool) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.name.len == 0 or e.name[0] == '.') continue;
        if (directories) {
            if (e.kind != .directory) continue;
        } else if (e.kind != .file or !isImage(e.name)) continue;
        try result.append(arena, try arena.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, result.items, {}, library.naturalLess);
    return result.items;
}

/// Every series under `<dir>/local` with at least one chapter of images.
/// Page paths are relative to `dir`, like downloaded pages.
pub fn scan(arena: std.mem.Allocator, io: Io, dir: []const u8) ![]const library.Manga {
    const root = try std.fs.path.join(arena, &.{ dir, folder });
    var local = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer local.close(io);
    var titles: std.ArrayList(library.Manga) = .empty;
    for (try names(arena, io, local, true)) |series| {
        var series_dir = try local.openDir(io, series, .{ .iterate = true });
        defer series_dir.close(io);
        var chapters: std.ArrayList(library.Chapter) = .empty;
        for (try names(arena, io, series_dir, true)) |chapter| {
            var chapter_dir = try series_dir.openDir(io, chapter, .{ .iterate = true });
            defer chapter_dir.close(io);
            var pages: std.ArrayList([]const u8) = .empty;
            for (try names(arena, io, chapter_dir, false)) |page| try pages.append(arena, try std.fs.path.join(arena, &.{ folder, series, chapter, page }));
            if (pages.items.len == 0) continue;
            try chapters.append(arena, .{ .id = try std.fmt.allocPrint(arena, "local:{s}/{s}", .{ series, chapter }), .title = chapter, .pages = pages.items });
        }
        if (chapters.items.len == 0) continue;
        try titles.append(arena, .{ .id = try std.fmt.allocPrint(arena, "local:{s}", .{series}), .title = series, .chapters = chapters.items });
    }
    return titles.items;
}

test "scans series and chapter folders in natural order" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "local/Series/Chapter 10/01.jpg", "local/Series/Chapter 2/02.png", "local/Series/Chapter 2/1.jpg", "local/Series/Chapter 2/notes.txt", "local/Empty/Chapter 1/readme.md" }) |path| {
        try tmp.dir.createDirPath(io, std.fs.path.dirname(path).?);
        try tmp.dir.writeFile(io, .{ .sub_path = path, .data = "x" });
    }
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const titles = try scan(a, io, dir);
    try std.testing.expectEqual(1, titles.len);
    try std.testing.expectEqualStrings("local:Series", titles[0].id);
    try std.testing.expectEqualStrings("Chapter 2", titles[0].chapters[0].title);
    try std.testing.expectEqualStrings("local/Series/Chapter 2/1.jpg", titles[0].chapters[0].pages[0]);
    try std.testing.expectEqual(2, titles[0].chapters[0].pages.len);
}

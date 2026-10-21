//! ZIP/CBZ/EPUB and TAR/CBT entries, using the standard library readers.
//! RAR/CBR and 7z/CB7 are skipped because Zig has no decoder for them.
const std = @import("std");
const Io = std.Io;
const library = @import("library.zig");

pub const Entry = struct { name: []const u8, data: []const u8 };
pub const max_entry = 64 << 20;

pub fn supported(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    for ([_][]const u8{ ".zip", ".cbz", ".tar", ".cbt", ".epub" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

pub fn visible(name: []const u8) bool {
    if (!library.safePath(name)) return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |p| if (p[0] == '.') return false;
    return true;
}

pub fn isImage(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    for ([_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".avif", ".heic", ".heif", ".jxl", ".jp2", ".jpx", ".j2k", ".j2c" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// Entries are owned by the arena. Links and unsafe names are ignored.
pub fn read(a: std.mem.Allocator, io: Io, path: []const u8) ![]Entry {
    return readSelected(a, io, path, null, false);
}

/// Names and XML documents, without inflating image payloads during a scan.
pub fn metadata(a: std.mem.Allocator, io: Io, path: []const u8) ![]Entry {
    return readSelected(a, io, path, null, true);
}

fn loadEntry(name: []const u8, wanted: ?[]const u8, metadata_only: bool) bool {
    if (wanted) |w| return std.mem.eql(u8, name, w);
    return !metadata_only or !isImage(name);
}

fn readSelected(a: std.mem.Allocator, io: Io, path: []const u8, wanted: ?[]const u8, metadata_only: bool) ![]Entry {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var reader = file.reader(io, &buf);
    var entries: std.ArrayList(Entry) = .empty;
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".tar") or std.ascii.eqlIgnoreCase(ext, ".cbt")) {
        var name_buf: [4096]u8 = undefined;
        var link_buf: [4096]u8 = undefined;
        var it = std.tar.Iterator.init(&reader.interface, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
        while (try it.next()) |entry| {
            if (entry.kind != .file or !visible(entry.name)) continue;
            if (!loadEntry(entry.name, wanted, metadata_only)) {
                try entries.append(a, .{ .name = try a.dupe(u8, entry.name), .data = "" });
                continue;
            }
            if (entry.size > max_entry) return error.ArchiveEntryTooLarge;
            var out: Io.Writer.Allocating = .init(a);
            try it.streamRemaining(entry, &out.writer);
            try entries.append(a, .{ .name = try a.dupe(u8, entry.name), .data = try out.toOwnedSlice() });
        }
    } else {
        var it = try std.zip.Iterator.init(&reader);
        while (try it.next()) |entry| {
            const name = entry.getFilename(&reader, try a.alloc(u8, entry.filename_len), .{}) catch |err| switch (err) {
                error.ZipBadFilename, error.ZipFilenameHasBackslash => continue,
                else => return err,
            };
            if (!visible(name)) continue;
            if (!loadEntry(name, wanted, metadata_only)) {
                try entries.append(a, .{ .name = name, .data = "" });
                continue;
            }
            if (entry.uncompressed_size > max_entry) return error.ArchiveEntryTooLarge;
            var out: Io.Writer.Allocating = .init(a);
            try entry.extractTo(&reader, &out.writer);
            try entries.append(a, .{ .name = name, .data = try out.toOwnedSlice() });
        }
    }
    return entries.items;
}

pub fn find(entries: []const Entry, name: []const u8) ?[]const u8 {
    for (entries) |e| if (std.mem.eql(u8, e.name, name)) return e.data;
    return null;
}

/// Extracts an archive page to a cache keyed by archive path and modification time.
pub fn pagePath(gpa: std.mem.Allocator, io: Io, dir: []const u8, relative: []const u8) ![:0]u8 {
    if (!library.safePath(relative)) return error.UnsafePagePath;
    const separator = std.mem.indexOfScalar(u8, relative, '#') orelse return std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, relative }, 0);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fs.path.join(a, &.{ dir, relative[0..separator] });
    const stat = try Io.Dir.cwd().statFile(io, path, .{});
    var hash = std.hash.Wyhash.init(0);
    hash.update(relative[0..separator]);
    hash.update(std.mem.asBytes(&stat.mtime.nanoseconds));
    const entries = try readSelected(a, io, path, "", false);
    for (entries, 0..) |e, i| {
        if (!std.mem.eql(u8, e.name, relative[separator + 1 ..])) continue;
        const dest = try std.fmt.allocPrintSentinel(gpa, "{s}/cache/pages/{x}/{d}{s}", .{ dir, hash.final(), i, std.fs.path.extension(e.name) }, 0);
        errdefer gpa.free(dest);
        if (Io.Dir.cwd().openFile(io, dest, .{})) |cached| {
            cached.close(io);
            return dest;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        const selected = try readSelected(a, io, path, e.name, false);
        try Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(dest).?);
        try library.writeAtomic(a, io, dest, find(selected, e.name) orelse return error.ArchivePageNotFound);
        return dest;
    }
    return error.ArchivePageNotFound;
}

/// Writes an uncompressed ZIP, supported by Mihon and ordinary ZIP readers.
/// Zig provides a ZIP reader but no ZIP writer.
pub fn zip(a: std.mem.Allocator, entries: []const Entry) ![]u8 {
    return zipInner(a, entries) catch |err| switch (err) {
        // An allocating writer has no I/O failure beyond allocation failure.
        error.WriteFailed => error.OutOfMemory,
        else => return err,
    };
}

fn zipInner(a: std.mem.Allocator, entries: []const Entry) ![]u8 {
    const count = std.math.cast(u16, entries.len) orelse return error.ArchiveTooLarge;
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;
    const offsets = try a.alloc(u32, entries.len);
    defer a.free(offsets);
    for (entries, 0..) |e, i| {
        if (!library.safePath(e.name)) return error.UnsafePagePath;
        offsets[i] = std.math.cast(u32, w.end) orelse return error.ArchiveTooLarge;
        try w.writeInt(u32, 0x04034b50, .little);
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 0x800, .little);
        try w.splatByteAll(0, 6);
        try w.writeInt(u32, std.hash.Crc32.hash(e.data), .little);
        try w.writeInt(u32, std.math.cast(u32, e.data.len) orelse return error.ArchiveTooLarge, .little);
        try w.writeInt(u32, std.math.cast(u32, e.data.len) orelse return error.ArchiveTooLarge, .little);
        try w.writeInt(u16, std.math.cast(u16, e.name.len) orelse return error.ArchiveTooLarge, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeAll(e.name);
        try w.writeAll(e.data);
    }
    const start = std.math.cast(u32, w.end) orelse return error.ArchiveTooLarge;
    for (entries, offsets) |e, offset| {
        try w.writeInt(u32, 0x02014b50, .little);
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 0x800, .little);
        try w.splatByteAll(0, 6);
        try w.writeInt(u32, std.hash.Crc32.hash(e.data), .little);
        try w.writeInt(u32, std.math.cast(u32, e.data.len) orelse return error.ArchiveTooLarge, .little);
        try w.writeInt(u32, std.math.cast(u32, e.data.len) orelse return error.ArchiveTooLarge, .little);
        try w.writeInt(u16, std.math.cast(u16, e.name.len) orelse return error.ArchiveTooLarge, .little);
        try w.splatByteAll(0, 12);
        try w.writeInt(u32, offset, .little);
        try w.writeAll(e.name);
    }
    const size = (std.math.cast(u32, w.end) orelse return error.ArchiveTooLarge) - start;
    try w.writeInt(u32, 0x06054b50, .little);
    try w.splatByteAll(0, 4);
    try w.writeInt(u16, count, .little);
    try w.writeInt(u16, count, .little);
    try w.writeInt(u32, size, .little);
    try w.writeInt(u32, start, .little);
    try w.writeInt(u16, 0, .little);
    return out.toOwnedSlice();
}

test "deflated ZIP pages and cache invalidation" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const bytes = "\x50\x4b\x03\x04\x14\x00\x00\x00\x08\x00\x72\x1e\x54\x5d\x92\xb8\xc4\x2c\x12\x00\x00\x00\x82\x00\x00\x00\x07\x00\x00\x00\x30\x30\x31\x2e\x70\x6e\x67\x4b\x49\x4d\xcb\x49\x2c\x49\x4d\x51\x28\x48\x4c\x4f\x4d\x19\x08\x0e\x00\x50\x4b\x01\x02\x14\x03\x14\x00\x00\x00\x08\x00\x72\x1e\x54\x5d\x92\xb8\xc4\x2c\x12\x00\x00\x00\x82\x00\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x80\x01\x00\x00\x00\x00\x30\x30\x31\x2e\x70\x6e\x67\x50\x4b\x05\x06\x00\x00\x00\x00\x01\x00\x01\x00\x35\x00\x00\x00\x37\x00\x00\x00\x00\x00";
    try tmp.dir.writeFile(io, .{ .sub_path = "chapter.cbz", .data = bytes });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    const first = try pagePath(a, io, dir, "chapter.cbz#001.png");
    try std.testing.expectEqualStrings("deflated pagedeflated pagedeflated pagedeflated pagedeflated pagedeflated pagedeflated pagedeflated pagedeflated pagedeflated page", try Io.Dir.cwd().readFileAlloc(io, first, a, .limited(1024)));
    const again = try pagePath(a, io, dir, "chapter.cbz#001.png");
    try std.testing.expectEqualStrings(first, again);
    const file = try tmp.dir.openFile(io, "chapter.cbz", .{ .mode = .read_write });
    defer file.close(io);
    const stat = try file.stat(io);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = stat.mtime.nanoseconds + std.time.ns_per_s } } });
    const second = try pagePath(a, io, dir, "chapter.cbz#001.png");
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expectEqualStrings("deflated pagedeflated pagedeflated pagedeflated pagedeflated pagedeflated pagedeflated pagedeflated pagedeflated pagedeflated page", try Io.Dir.cwd().readFileAlloc(io, second, a, .limited(1024)));
}

test "ZIP writer releases temporary allocations on success and failure" {
    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            const bytes = try zip(gpa, &.{.{ .name = "page.png", .data = "image" }});
            defer gpa.free(bytes);
            try std.testing.expectEqualSlices(u8, "PK\x03\x04", bytes[0..4]);
            _ = zip(gpa, &.{.{ .name = "../page.png", .data = "image" }}) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.UnsafePagePath => return,
                else => return err,
            };
            return error.TestUnexpectedResult;
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "ZIP writer rejects names and counts beyond ZIP32 limits" {
    const gpa = std.testing.allocator;
    const name = try gpa.alloc(u8, 1 << 16);
    defer gpa.free(name);
    @memset(name, 'a');
    try std.testing.expectError(error.ArchiveTooLarge, zip(gpa, &.{.{ .name = name, .data = "" }}));
    const entries = try gpa.alloc(Entry, 1 << 16);
    defer gpa.free(entries);
    @memset(entries, .{ .name = "page.png", .data = "" });
    try std.testing.expectError(error.ArchiveTooLarge, zip(gpa, entries));
}

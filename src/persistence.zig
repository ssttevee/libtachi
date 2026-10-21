//! Small typed documents stored alongside the relational library. Legacy JSON
//! is imported exactly once, after validation; originals remain migration backups.
const std = @import("std");
const Io = std.Io;
const sqlite = @import("sqlite.zig");
const models = @import("models.zig");

pub fn load(comptime T: type, gpa: std.mem.Allocator, io: Io, dir: []const u8, key: []const u8, legacy_relative: []const u8) !?T {
    var db = try sqlite.Db.open(gpa, io, dir);
    defer db.close();
    try db.begin();
    errdefer db.rollback();
    const query = try db.prepare("SELECT value FROM documents WHERE key=?1");
    defer query.close();
    try query.bindText(1, key);
    if (try query.step()) {
        const result = try std.json.parseFromSliceLeaky(T, gpa, query.columnText(0), models.parse_options);
        try db.commit();
        return result;
    }
    if (try migrated(&db, key)) {
        try db.commit();
        return null;
    }
    const path = try std.fs.path.join(gpa, &.{ dir, legacy_relative });
    defer gpa.free(path);
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            try markMigrated(&db, key);
            try db.commit();
            return null;
        },
        else => return err,
    };
    defer gpa.free(bytes);
    // Validate before publishing either the document or the migration marker.
    const value = try std.json.parseFromSliceLeaky(T, gpa, bytes, models.parse_options);
    try put(&db, key, bytes);
    try markMigrated(&db, key);
    try db.commit();
    return value;
}

pub fn save(gpa: std.mem.Allocator, io: Io, dir: []const u8, key: []const u8, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(gpa, value, .{});
    defer gpa.free(bytes);
    var db = try sqlite.Db.open(gpa, io, dir);
    defer db.close();
    try db.begin();
    errdefer db.rollback();
    try put(&db, key, bytes);
    try markMigrated(&db, key);
    try db.commit();
}

pub fn remove(gpa: std.mem.Allocator, io: Io, dir: []const u8, key: []const u8) !void {
    var db = try sqlite.Db.open(gpa, io, dir);
    defer db.close();
    try db.begin();
    errdefer db.rollback();
    const stmt = try db.prepare("DELETE FROM documents WHERE key=?1");
    defer stmt.close();
    try stmt.bindText(1, key);
    _ = try stmt.step();
    try markMigrated(&db, key);
    try db.commit();
}

/// Remove matching documents while retaining tombstones for imported backups.
/// Callers also remove the corresponding legacy directory, including files that
/// have never been imported. Prefix comparison is literal, not SQL LIKE syntax.
pub fn removePrefix(gpa: std.mem.Allocator, io: Io, dir: []const u8, prefix: []const u8) !void {
    var db = try sqlite.Db.open(gpa, io, dir);
    defer db.close();
    try db.begin();
    errdefer db.rollback();
    const mark = try db.prepare("INSERT OR IGNORE INTO migrations(key) SELECT key FROM documents WHERE substr(key,1,length(?1))=?1");
    defer mark.close();
    try mark.bindText(1, prefix);
    _ = try mark.step();
    const remove_stmt = try db.prepare("DELETE FROM documents WHERE substr(key,1,length(?1))=?1");
    defer remove_stmt.close();
    try remove_stmt.bindText(1, prefix);
    _ = try remove_stmt.step();
    try db.commit();
}

pub fn migrated(db: *sqlite.Db, key: []const u8) !bool {
    const stmt = try db.prepare("SELECT 1 FROM migrations WHERE key=?1");
    defer stmt.close();
    try stmt.bindText(1, key);
    return stmt.step();
}

pub fn markMigrated(db: *sqlite.Db, key: []const u8) !void {
    const stmt = try db.prepare("INSERT OR IGNORE INTO migrations(key) VALUES(?1)");
    defer stmt.close();
    try stmt.bindText(1, key);
    _ = try stmt.step();
}

fn put(db: *sqlite.Db, key: []const u8, bytes: []const u8) !void {
    const stmt = try db.prepare("INSERT INTO documents(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value");
    defer stmt.close();
    try stmt.bindText(1, key);
    try stmt.bindText(2, bytes);
    _ = try stmt.step();
}

test "typed documents migrate valid JSON once and removal cannot resurrect the backup" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const Value = struct { count: u32 };
    try tmp.dir.writeFile(t.io, .{ .sub_path = "legacy.json", .data = "{\"count\":7}" });
    try t.expectEqual(7, (try load(Value, a, t.io, dir, "test", "legacy.json")).?.count);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "legacy.json", .data = "{\"count\":8}" });
    try t.expectEqual(7, (try load(Value, a, t.io, dir, "test", "legacy.json")).?.count);
    try remove(a, t.io, dir, "test");
    try t.expectEqual(null, try load(Value, a, t.io, dir, "test", "legacy.json"));
    const original = try tmp.dir.readFileAlloc(t.io, "legacy.json", a, .unlimited);
    try t.expectEqualStrings("{\"count\":8}", original);
}

test "invalid legacy documents remain retryable and absent documents stay absent" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const Value = struct { count: u32 };
    try tmp.dir.writeFile(t.io, .{ .sub_path = "legacy.json", .data = "{" });
    try t.expectError(error.UnexpectedEndOfInput, load(Value, a, t.io, dir, "test", "legacy.json"));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "legacy.json", .data = "{\"count\":9}" });
    try t.expectEqual(9, (try load(Value, a, t.io, dir, "test", "legacy.json")).?.count);
    try t.expectEqual(null, try load(Value, a, t.io, dir, "absent", "missing.json"));
    try tmp.dir.writeFile(t.io, .{ .sub_path = "missing.json", .data = "{\"count\":1}" });
    try t.expectEqual(null, try load(Value, a, t.io, dir, "absent", "missing.json"));
    try save(a, t.io, dir, "absent", Value{ .count = 3 });
    try t.expectEqual(3, (try load(Value, a, t.io, dir, "absent", "missing.json")).?.count);
}

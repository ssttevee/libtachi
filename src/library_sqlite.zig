//! Transactional library rows. Source metadata remains extensible JSON per row;
//! progress is separate SQL data so a page turn never rewrites metadata.
const std = @import("std");
const lib = @import("library.zig");
const sqlite = @import("sqlite.zig");
const models = @import("tachicore").models;
const ReadingFile = struct { version: u32 = 1, chapters: []const lib.Reading = &.{} };

pub fn open(store: *lib.Store, arena: std.mem.Allocator) !sqlite.Db {
    var db = try sqlite.Db.open(arena, store.io, store.dir);
    errdefer db.close();
    {
        var schema = try db.prepare("PRAGMA user_version");
        defer schema.close();
        if (!try schema.step() or schema.columnInt(0) < 0 or schema.columnInt(0) > 1) return error.UnsupportedSchema;
    }
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS library_manga(id TEXT PRIMARY KEY, position INTEGER NOT NULL CHECK(position>=0), metadata TEXT NOT NULL) STRICT;
        \\CREATE TABLE IF NOT EXISTS library_chapters(id TEXT PRIMARY KEY, manga_id TEXT NOT NULL REFERENCES library_manga(id) ON DELETE CASCADE, position INTEGER NOT NULL CHECK(position>=0), metadata TEXT NOT NULL) STRICT;
        \\CREATE INDEX IF NOT EXISTS library_chapters_manga ON library_chapters(manga_id,position);
        \\CREATE TABLE IF NOT EXISTS library_categories(id INTEGER PRIMARY KEY, position INTEGER NOT NULL CHECK(position>=0), metadata TEXT NOT NULL) STRICT;
        \\CREATE TABLE IF NOT EXISTS library_sources(id INTEGER PRIMARY KEY, position INTEGER NOT NULL CHECK(position>=0), metadata TEXT NOT NULL) STRICT;
        \\CREATE TABLE IF NOT EXISTS library_reading(id TEXT PRIMARY KEY CHECK(length(id)>0), page INTEGER NOT NULL CHECK(page>=0 AND page<=4294967295), read INTEGER NOT NULL CHECK(read IN(0,1)), bookmark INTEGER NOT NULL CHECK(bookmark IN(0,1)), last_read INTEGER NOT NULL, read_ms INTEGER NOT NULL CHECK(read_ms>=0)) STRICT;
    );
    // The common read path must not acquire a write reservation merely to
    // discover that migration already completed.
    {
        var ready = try db.prepare("SELECT 1 FROM migrations WHERE key='library-json-v1'");
        defer ready.close();
        if (try ready.step()) return db;
    }
    try db.begin();
    errdefer db.rollback();
    const imported = blk: {
        var marker = try db.prepare("SELECT 1 FROM migrations WHERE key='library-json-v1'");
        defer marker.close();
        break :blk try marker.step();
    };
    if (!imported) {
        const bytes = try legacy(store, arena, lib.Store.file_name);
        const library: lib.Library = if (bytes) |b| try std.json.parseFromSliceLeaky(lib.Library, arena, b, models.parse_options) else .{};
        try lib.validate(arena, library);
        try save(&db, arena, library);
        if (try legacy(store, arena, lib.Store.reading_name)) |b| {
            const reading = try std.json.parseFromSliceLeaky(ReadingFile, arena, b, models.parse_options);
            if (reading.version != 1) return error.UnsupportedReadingVersion;
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            for (reading.chapters) |state| {
                if (state.id.len == 0 or state.read_ms < 0) return error.InvalidReading;
                if ((try seen.getOrPut(arena, state.id)).found_existing) return error.DuplicateReading;
            }
            try putReading(&db, reading.chapters);
        }
        try db.exec("INSERT INTO migrations(key) VALUES('library-json-v1')");
    }
    try db.exec("PRAGMA user_version=1");
    try db.commit();
    return db;
}

fn legacy(store: *lib.Store, arena: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(arena, &.{ store.dir, name });
    return std.Io.Dir.cwd().readFileAlloc(store.io, path, arena, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

pub fn load(db: *sqlite.Db, arena: std.mem.Allocator) !lib.Library {
    var manga: std.ArrayList(lib.Manga) = .empty;
    var rows = try db.prepare("SELECT metadata,id FROM library_manga ORDER BY position");
    defer rows.close();
    while (try rows.step()) {
        var m = try std.json.parseFromSliceLeaky(lib.Manga, arena, rows.columnText(0), models.parse_options);
        if (!std.mem.eql(u8, m.id, rows.columnText(1))) return error.SqliteCorrupt;
        var chapters: std.ArrayList(lib.Chapter) = .empty;
        var chs = try db.prepare("SELECT c.metadata,r.page,r.read,r.bookmark,r.last_read,r.read_ms,c.id FROM library_chapters c LEFT JOIN library_reading r ON r.id=c.id WHERE c.manga_id=? ORDER BY c.position");
        defer chs.close();
        try chs.bindText(1, rows.columnText(1));
        while (try chs.step()) {
            var ch = try std.json.parseFromSliceLeaky(lib.Chapter, arena, chs.columnText(0), models.parse_options);
            if (!std.mem.eql(u8, ch.id, chs.columnText(6))) return error.SqliteCorrupt;
            ch.last_page_read = @intCast(chs.columnInt(1));
            ch.read = chs.columnInt(2) != 0;
            ch.bookmark = chs.columnInt(3) != 0;
            ch.last_read = chs.columnInt(4);
            ch.read_ms = chs.columnInt(5);
            try chapters.append(arena, ch);
        }
        m.chapters = try chapters.toOwnedSlice(arena);
        try manga.append(arena, m);
    }
    const result: lib.Library = .{ .manga = try manga.toOwnedSlice(arena), .categories = try loadRows(lib.Category, db, arena, "SELECT metadata,id FROM library_categories ORDER BY position"), .sources = try loadRows(lib.SourceName, db, arena, "SELECT metadata,id FROM library_sources ORDER BY position") };
    try lib.validate(arena, result);
    return result;
}

fn loadRows(comptime T: type, db: *sqlite.Db, arena: std.mem.Allocator, sql: [:0]const u8) ![]const T {
    var rows = try db.prepare(sql);
    defer rows.close();
    var list: std.ArrayList(T) = .empty;
    while (try rows.step()) {
        const value = try std.json.parseFromSliceLeaky(T, arena, rows.columnText(0), models.parse_options);
        if (value.id != rows.columnInt(1)) return error.SqliteCorrupt;
        try list.append(arena, value);
    }
    return list.toOwnedSlice(arena);
}

/// Caller owns the encompassing write transaction, including any read/edit.
/// Reading rows not represented by this snapshot deliberately survive deletion.
pub fn save(db: *sqlite.Db, arena: std.mem.Allocator, library: lib.Library) !void {
    var current = library;
    current.version = lib.version;
    try lib.validate(arena, current);
    var known: std.StringHashMapUnmanaged(void) = .empty;
    {
        var ids = try db.prepare("SELECT id FROM library_chapters");
        defer ids.close();
        while (try ids.step()) try known.put(arena, try arena.dupe(u8, ids.columnText(0)), {});
    }
    try db.exec("CREATE TEMP TABLE wanted_manga(id TEXT PRIMARY KEY); CREATE TEMP TABLE wanted_chapters(id TEXT PRIMARY KEY); CREATE TEMP TABLE wanted_categories(id INTEGER PRIMARY KEY); CREATE TEMP TABLE wanted_sources(id INTEGER PRIMARY KEY);");
    defer db.exec("DROP TABLE wanted_manga; DROP TABLE wanted_chapters; DROP TABLE wanted_categories; DROP TABLE wanted_sources;") catch {};
    var states: std.ArrayList(lib.Reading) = .empty;
    var manga = try db.prepare("INSERT INTO library_manga(id,position,metadata) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET position=excluded.position,metadata=excluded.metadata WHERE library_manga.position!=excluded.position OR library_manga.metadata!=excluded.metadata");
    defer manga.close();
    var chapter = try db.prepare("INSERT INTO library_chapters(id,manga_id,position,metadata) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET manga_id=excluded.manga_id,position=excluded.position,metadata=excluded.metadata WHERE library_chapters.manga_id!=excluded.manga_id OR library_chapters.position!=excluded.position OR library_chapters.metadata!=excluded.metadata");
    defer chapter.close();
    for (current.manga, 0..) |m, i| {
        try wanted(db, "INSERT INTO wanted_manga(id) VALUES(?)", m.id);
        var metadata = m;
        metadata.chapters = &.{};
        try manga.bindText(1, m.id);
        try manga.bindInt(2, @intCast(i));
        try manga.bindText(3, try json(arena, metadata));
        _ = try manga.step();
        try manga.reset();
        for (m.chapters, 0..) |ch, j| {
            try wanted(db, "INSERT INTO wanted_chapters(id) VALUES(?)", ch.id);
            var data = ch;
            data.last_page_read = 0;
            data.read = false;
            data.bookmark = false;
            data.last_read = 0;
            data.read_ms = 0;
            try chapter.bindText(1, ch.id);
            try chapter.bindText(2, m.id);
            try chapter.bindInt(3, @intCast(j));
            try chapter.bindText(4, try json(arena, data));
            _ = try chapter.step();
            try chapter.reset();
            if (known.contains(ch.id) or lib.Reading.of(ch) != null) try states.append(arena, .{ .id = ch.id, .page = ch.last_page_read, .read = ch.read, .bookmark = ch.bookmark, .last_read = ch.last_read, .read_ms = ch.read_ms });
        }
    }
    try putReading(db, states.items);
    try saveRows(lib.Category, db, arena, current.categories, "INSERT INTO library_categories(id,position,metadata) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET position=excluded.position,metadata=excluded.metadata WHERE library_categories.position!=excluded.position OR library_categories.metadata!=excluded.metadata", "INSERT INTO wanted_categories(id) VALUES(?)");
    try saveRows(lib.SourceName, db, arena, current.sources, "INSERT INTO library_sources(id,position,metadata) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET position=excluded.position,metadata=excluded.metadata WHERE library_sources.position!=excluded.position OR library_sources.metadata!=excluded.metadata", "INSERT INTO wanted_sources(id) VALUES(?)");
    try db.exec("DELETE FROM library_chapters WHERE id NOT IN(SELECT id FROM wanted_chapters); DELETE FROM library_manga WHERE id NOT IN(SELECT id FROM wanted_manga); DELETE FROM library_categories WHERE id NOT IN(SELECT id FROM wanted_categories); DELETE FROM library_sources WHERE id NOT IN(SELECT id FROM wanted_sources);");
}

fn wanted(db: *sqlite.Db, sql: [:0]const u8, id: []const u8) !void {
    var row = try db.prepare(sql);
    defer row.close();
    try row.bindText(1, id);
    _ = try row.step();
}

fn json(arena: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{ .emit_null_optional_fields = false });
}

fn saveRows(comptime T: type, db: *sqlite.Db, arena: std.mem.Allocator, values: []const T, sql: [:0]const u8, wanted_sql: [:0]const u8) !void {
    var row = try db.prepare(sql);
    defer row.close();
    var ids = try db.prepare(wanted_sql);
    defer ids.close();
    for (values, 0..) |value, i| {
        try ids.bindInt(1, value.id);
        _ = try ids.step();
        try ids.reset();
        try row.bindInt(1, value.id);
        try row.bindInt(2, @intCast(i));
        try row.bindText(3, try json(arena, value));
        _ = try row.step();
        try row.reset();
    }
}

pub fn putReading(db: *sqlite.Db, states: []const lib.Reading) !void {
    var row = try db.prepare("INSERT INTO library_reading(id,page,read,bookmark,last_read,read_ms) VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET page=excluded.page,read=excluded.read,bookmark=excluded.bookmark,last_read=excluded.last_read,read_ms=excluded.read_ms WHERE library_reading.page!=excluded.page OR library_reading.read!=excluded.read OR library_reading.bookmark!=excluded.bookmark OR library_reading.last_read!=excluded.last_read OR library_reading.read_ms!=excluded.read_ms");
    defer row.close();
    for (states) |state| {
        try row.bindText(1, state.id);
        try row.bindInt(2, state.page);
        try row.bindInt(3, @intFromBool(state.read));
        try row.bindInt(4, @intFromBool(state.bookmark));
        try row.bindInt(5, state.last_read);
        try row.bindInt(6, state.read_ms);
        _ = try row.step();
        try row.reset();
    }
}

pub fn progress(db: *sqlite.Db, values: []const lib.Progress) !usize {
    var previous = try db.prepare("SELECT page,read FROM library_reading WHERE id=?");
    defer previous.close();
    var row = try db.prepare("INSERT INTO library_reading(id,page,read,bookmark,last_read,read_ms) VALUES(?,?,?,0,?,?) ON CONFLICT(id) DO UPDATE SET page=excluded.page,read=MAX(library_reading.read,excluded.read),last_read=MAX(library_reading.last_read,excluded.last_read),read_ms=library_reading.read_ms+excluded.read_ms");
    defer row.close();
    var newly_read: usize = 0;
    for (values) |p| {
        if (p.chapter_id.len == 0 or p.read_ms < 0) return error.InvalidReading;
        try previous.bindText(1, p.chapter_id);
        const exists = try previous.step();
        const was_read = exists and previous.columnInt(1) != 0;
        const unchanged = exists and previous.columnInt(0) == p.page and (was_read or !p.read) and p.read_ms == 0;
        try previous.reset();
        if (unchanged) continue;
        if (p.read and !was_read) newly_read += 1;
        try row.bindText(1, p.chapter_id);
        try row.bindInt(2, p.page);
        try row.bindInt(3, @intFromBool(p.read));
        try row.bindInt(4, p.now);
        try row.bindInt(5, p.read_ms);
        _ = try row.step();
        try row.reset();
    }
    return newly_read;
}

test "legacy metadata and unknown progress import once without altering JSON" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const metadata =
        \\{"version":1,"manga":[{"id":"m","title":"Original","chapters":[{"id":"c","title":"First","read":true}]}]}
    ;
    const reading =
        \\{"chapters":[{"id":"c","page":3,"bookmark":true,"read_ms":20},{"id":"future","page":7,"read":true,"read_ms":50}]}
    ;
    try tmp.dir.writeFile(t.io, .{ .sub_path = lib.Store.file_name, .data = metadata });
    try tmp.dir.writeFile(t.io, .{ .sub_path = lib.Store.reading_name, .data = reading });
    var store: lib.Store = .{ .io = t.io, .dir = root };
    const imported = try store.load(a);
    try t.expectEqualStrings("Original", imported.manga[0].title);
    const ch = imported.manga[0].chapters[0];
    try t.expectEqual(3, ch.last_page_read);
    try t.expect(ch.bookmark);
    try t.expect(!ch.read); // The separate reading file was authoritative.
    try t.expectEqualStrings(metadata, try tmp.dir.readFileAlloc(t.io, lib.Store.file_name, a, .unlimited));
    try t.expectEqualStrings(reading, try tmp.dir.readFileAlloc(t.io, lib.Store.reading_name, a, .unlimited));
    try store.save(t.allocator, .{}); // Removing metadata must retain unknown reading state.
    try tmp.dir.writeFile(t.io, .{ .sub_path = lib.Store.file_name, .data = "corrupted stale JSON" });
    var reopened: lib.Store = .{ .io = t.io, .dir = root };
    try t.expectEqual(0, (try reopened.load(a)).manga.len);
    try reopened.save(t.allocator, .{ .manga = &.{.{ .id = "new", .title = "New", .chapters = &.{.{ .id = "future", .title = "Later" }} }} });
    const future = (try reopened.load(a)).manga[0].chapters[0];
    try t.expectEqual(7, future.last_page_read);
    try t.expect(future.read);
    try t.expectEqual(50, future.read_ms);
}

test "invalid reading import rolls back metadata and can be retried" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    try tmp.dir.writeFile(t.io, .{ .sub_path = lib.Store.file_name, .data = "{\"manga\":[{\"id\":\"m\",\"title\":\"M\"}]}" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = lib.Store.reading_name, .data = "{\"chapters\":[{\"id\":\"\"}]}" });
    var store: lib.Store = .{ .io = t.io, .dir = root };
    try t.expectError(error.InvalidReading, store.load(a));
    {
        var db = try sqlite.Db.open(a, t.io, root);
        defer db.close();
        var rows = try db.prepare("SELECT (SELECT count(*) FROM library_manga),(SELECT count(*) FROM migrations WHERE key='library-json-v1')");
        defer rows.close();
        try t.expect(try rows.step());
        try t.expectEqual(0, rows.columnInt(0));
        try t.expectEqual(0, rows.columnInt(1));
    }
    try tmp.dir.writeFile(t.io, .{ .sub_path = lib.Store.reading_name, .data = "{\"chapters\":[{\"id\":\"unknown\",\"read\":true}]}" });
    try t.expectEqual(1, (try store.load(a)).manga.len);
}

test "metadata and reading changes roll back together on a SQL failure" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var store: lib.Store = .{ .io = t.io, .dir = root };
    const initial: lib.Library = .{ .manga = &.{.{ .id = "m", .title = "Before", .chapters = &.{.{ .id = "c", .title = "C", .last_page_read = 4 }} }} };
    try store.save(t.allocator, initial);
    {
        var db = try sqlite.Db.open(a, t.io, root);
        defer db.close();
        try db.exec("CREATE TRIGGER reject_bad BEFORE INSERT ON library_reading WHEN NEW.id='bad' BEGIN SELECT RAISE(ABORT,'test write failure'); END");
    }
    const replacement: lib.Library = .{ .manga = &.{.{ .id = "m", .title = "After", .chapters = &.{ .{ .id = "c", .title = "C", .last_page_read = 9 }, .{ .id = "bad", .title = "Bad", .read = true } } }} };
    try t.expectError(error.SqliteConstraint, store.save(t.allocator, replacement));
    const after = try store.load(a);
    try t.expectEqualStrings("Before", after.manga[0].title);
    try t.expectEqual(1, after.manga[0].chapters.len);
    try t.expectEqual(4, after.manga[0].chapters[0].last_page_read);
    try t.expectError(error.FileNotFound, tmp.dir.statFile(t.io, lib.Store.file_name, .{}));
}

test "progress batches are atomic and completion and time remain monotonic" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var store: lib.Store = .{ .io = t.io, .dir = try tmp.dir.realPathFileAlloc(t.io, ".", a) };
    try store.save(t.allocator, .{ .manga = &.{.{ .id = "m", .title = "M", .chapters = &.{.{ .id = "c", .title = "C" }} }} });
    try t.expectEqual(1, try store.setProgress(t.allocator, &.{.{ .chapter_id = "c", .page = 8, .read = true, .read_ms = 10, .now = 100 }}));
    try t.expectEqual(0, try store.setProgress(t.allocator, &.{.{ .chapter_id = "c", .page = 2, .read_ms = 5, .now = 90 }}));
    try t.expectError(error.InvalidReading, store.setProgress(t.allocator, &.{ .{ .chapter_id = "c", .page = 7, .read_ms = 50, .now = 200 }, .{ .chapter_id = "", .page = 0, .now = 300 } }));
    const ch = (try store.load(a)).manga[0].chapters[0];
    try t.expect(ch.read);
    try t.expectEqual(2, ch.last_page_read);
    try t.expectEqual(15, ch.read_ms);
    try t.expectEqual(100, ch.last_read);
    try store.putReading(t.allocator, &.{.{ .id = "c" }});
    try t.expect(!(try store.load(a)).manga[0].chapters[0].read);
}

test "independent stores serialize complete read edit write transactions" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var first: lib.Store = .{ .io = t.io, .dir = root };
    var second: lib.Store = .{ .io = t.io, .dir = root };
    try first.save(t.allocator, .{ .manga = &.{.{ .id = "m", .title = "M" }} });
    const Worker = struct {
        fn edit(_: void, _: std.mem.Allocator, current: lib.Library) !?lib.Library {
            @constCast(current.manga)[0].reader_flags += 1;
            return current;
        }
        fn run(store: *lib.Store) !void {
            for (0..12) |_| {
                var arena: std.heap.ArenaAllocator = .init(t.allocator);
                defer arena.deinit();
                _ = try store.update(arena.allocator(), {}, edit);
            }
        }
    };
    var work = try t.io.concurrent(Worker.run, .{&first});
    defer work.cancel(t.io) catch {};
    try Worker.run(&second);
    try work.await(t.io);
    try t.expectEqual(24, (try first.load(a)).manga[0].reader_flags);
}

test "read snapshot sees only committed metadata and progress" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var store: lib.Store = .{ .io = t.io, .dir = root };
    try store.save(t.allocator, .{ .manga = &.{.{ .id = "m", .title = "M", .chapters = &.{.{ .id = "c", .title = "C", .last_page_read = 2 }} }} });
    var writer = try sqlite.Db.open(a, t.io, root);
    defer writer.close();
    try writer.begin();
    defer writer.rollback();
    try writer.exec("UPDATE library_manga SET metadata='{\"id\":\"m\",\"title\":\"Uncommitted\"}'; UPDATE library_reading SET page=99;");
    const snapshot = try store.load(a);
    try t.expectEqualStrings("M", snapshot.manga[0].title);
    try t.expectEqual(2, snapshot.manga[0].chapters[0].last_page_read);
}

test "no op metadata saves preserve rows and future schema versions are rejected" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var store: lib.Store = .{ .io = t.io, .dir = root };
    const initial: lib.Library = .{ .manga = &.{.{ .id = "m", .title = "M", .chapters = &.{.{ .id = "c", .title = "C" }} }} };
    try store.save(t.allocator, initial);
    {
        var db = try sqlite.Db.open(a, t.io, root);
        defer db.close();
        try db.exec("CREATE TRIGGER detect_metadata_update BEFORE UPDATE ON library_manga BEGIN SELECT RAISE(ABORT,'unexpected rewrite'); END; CREATE TRIGGER detect_chapter_update BEFORE UPDATE ON library_chapters BEGIN SELECT RAISE(ABORT,'unexpected rewrite'); END; CREATE TRIGGER detect_delete BEFORE DELETE ON library_manga BEGIN SELECT RAISE(ABORT,'unexpected deletion'); END;");
        try store.save(t.allocator, initial);
        _ = try store.setProgress(t.allocator, &.{.{ .chapter_id = "c", .page = 1, .now = 2 }});
        try db.exec("PRAGMA user_version=999");
    }
    try t.expectError(error.UnsupportedSchema, store.load(a));
}

test "mismatched SQL metadata identities are rejected as corrupt" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    var store: lib.Store = .{ .io = t.io, .dir = root };
    const initial: lib.Library = .{ .manga = &.{.{ .id = "m", .title = "M", .chapters = &.{.{ .id = "c", .title = "C" }} }}, .categories = &.{.{ .id = 1, .name = "Cat" }}, .sources = &.{.{ .id = 2, .name = "Source" }} };
    var db = try sqlite.Db.open(a, t.io, root);
    defer db.close();
    for ([_][:0]const u8{
        "UPDATE library_manga SET metadata='{\"id\":\"wrong\",\"title\":\"M\"}'",
        "UPDATE library_chapters SET metadata='{\"id\":\"wrong\",\"title\":\"C\"}'",
        "UPDATE library_categories SET metadata='{\"id\":99,\"name\":\"Cat\"}'",
        "UPDATE library_sources SET metadata='{\"id\":99,\"name\":\"Source\"}'",
    }) |damage| {
        try store.save(t.allocator, initial);
        try db.exec(damage);
        try t.expectError(error.SqliteCorrupt, store.load(a));
    }
}

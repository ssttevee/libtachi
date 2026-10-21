//! Small owning wrappers around the statically linked SQLite C interface.
//! Statements borrow their connection; finalize them before closing it.
const std = @import("std");
// The narrow ABI is declared explicitly: Zig 0.17 no longer supports
// @cImport, and these declarations do not depend on platform header layout.
const c = struct {
    const sqlite3 = opaque {};
    const sqlite3_stmt = opaque {};
    const sqlite3_destructor_type = ?*align(1) const fn (?*anyopaque) callconv(.c) void;
    extern "c" fn sqlite3_open_v2([*:0]const u8, *?*sqlite3, c_int, ?[*:0]const u8) c_int;
    extern "c" fn sqlite3_close_v2(*sqlite3) c_int;
    extern "c" fn sqlite3_busy_timeout(*sqlite3, c_int) c_int;
    extern "c" fn sqlite3_exec(*sqlite3, [*:0]const u8, ?*const fn (?*anyopaque, c_int, ?[*]?[*:0]u8, ?[*]?[*:0]u8) callconv(.c) c_int, ?*anyopaque, ?*?[*:0]u8) c_int;
    extern "c" fn sqlite3_prepare_v2(*sqlite3, [*:0]const u8, c_int, *?*sqlite3_stmt, ?*?[*:0]const u8) c_int;
    extern "c" fn sqlite3_finalize(*sqlite3_stmt) c_int;
    extern "c" fn sqlite3_bind_text(*sqlite3_stmt, c_int, [*]const u8, c_int, sqlite3_destructor_type) c_int;
    extern "c" fn sqlite3_bind_int64(*sqlite3_stmt, c_int, i64) c_int;
    extern "c" fn sqlite3_bind_null(*sqlite3_stmt, c_int) c_int;
    extern "c" fn sqlite3_step(*sqlite3_stmt) c_int;
    extern "c" fn sqlite3_reset(*sqlite3_stmt) c_int;
    extern "c" fn sqlite3_clear_bindings(*sqlite3_stmt) c_int;
    extern "c" fn sqlite3_column_text(*sqlite3_stmt, c_int) ?[*]const u8;
    extern "c" fn sqlite3_column_bytes(*sqlite3_stmt, c_int) c_int;
    extern "c" fn sqlite3_column_int64(*sqlite3_stmt, c_int) i64;
    extern "c" fn sqlite3_column_type(*sqlite3_stmt, c_int) c_int;
    const SQLITE_OK = 0;
    const SQLITE_NOMEM = 7;
    const SQLITE_BUSY = 5;
    const SQLITE_LOCKED = 6;
    const SQLITE_CORRUPT = 11;
    const SQLITE_NOTADB = 26;
    const SQLITE_CONSTRAINT = 19;
    const SQLITE_READONLY = 8;
    const SQLITE_FULL = 13;
    const SQLITE_IOERR = 10;
    const SQLITE_CANTOPEN = 14;
    const SQLITE_TOOBIG = 18;
    const SQLITE_ROW = 100;
    const SQLITE_DONE = 101;
    const SQLITE_NULL = 5;
    const SQLITE_OPEN_READWRITE = 0x00000002;
    const SQLITE_OPEN_CREATE = 0x00000004;
    const SQLITE_OPEN_FULLMUTEX = 0x00010000;
};

pub const Error = error{
    UnsupportedSchema,
    SqliteError,
    SqliteBusy,
    SqliteCorrupt,
    SqliteConstraint,
    SqliteReadOnly,
    SqliteFull,
    SqliteIo,
    OutOfMemory,
    ValueTooLarge,
};

fn check(code: c_int) Error!void {
    switch (code & 0xff) {
        c.SQLITE_OK, c.SQLITE_ROW, c.SQLITE_DONE => {},
        c.SQLITE_NOMEM => return error.OutOfMemory,
        c.SQLITE_BUSY, c.SQLITE_LOCKED => return error.SqliteBusy,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB => return error.SqliteCorrupt,
        c.SQLITE_CONSTRAINT => return error.SqliteConstraint,
        c.SQLITE_READONLY => return error.SqliteReadOnly,
        c.SQLITE_FULL => return error.SqliteFull,
        c.SQLITE_IOERR, c.SQLITE_CANTOPEN => return error.SqliteIo,
        c.SQLITE_TOOBIG => return error.ValueTooLarge,
        else => return error.SqliteError,
    }
}

pub const Db = struct {
    handle: *c.sqlite3,

    /// The database always lives in the internal data root; image files may
    /// live on removable storage. Rollback journalling avoids WAL sidecars and
    /// shared-memory requirements on the reader's FAT filesystem.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !Db {
        try std.Io.Dir.cwd().createDirPath(io, dir);
        const root = try std.Io.Dir.cwd().realPathFileAlloc(io, dir, gpa);
        defer gpa.free(root);
        const path = try std.fs.path.joinZ(gpa, &.{ root, "tachi.sqlite3" });
        defer gpa.free(path);
        var handle: ?*c.sqlite3 = null;
        const code = c.sqlite3_open_v2(path, &handle, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null);
        errdefer if (handle) |h| {
            _ = c.sqlite3_close_v2(h);
        };
        try check(code);
        const db: Db = .{ .handle = handle.? };
        try check(c.sqlite3_busy_timeout(db.handle, 5000));
        // Inspect identity/version before changing even the journal mode. An
        // older binary must leave a newer database untouched.
        const app_id = try db.pragmaInt("PRAGMA application_id");
        if (app_id != 0 and app_id != 0x54414348) return error.SqliteCorrupt;
        if (try db.pragmaInt("PRAGMA user_version") > 1) return error.UnsupportedSchema;
        if (app_id == 0) try db.exec("PRAGMA application_id=1413563208");
        try db.exec("PRAGMA foreign_keys=ON; PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA trusted_schema=OFF;");
        try db.exec("CREATE TABLE IF NOT EXISTS documents(key TEXT PRIMARY KEY NOT NULL,value TEXT NOT NULL) STRICT; CREATE TABLE IF NOT EXISTS migrations(key TEXT PRIMARY KEY NOT NULL) STRICT;");
        return db;
    }

    fn pragmaInt(db: Db, sql: [:0]const u8) Error!i64 {
        var query = try db.prepare(sql);
        defer query.close();
        if (!try query.step()) return error.SqliteCorrupt;
        return query.columnInt(0);
    }

    pub fn close(db: Db) void {
        // close_v2 keeps a zombie connection alive until outstanding statements
        // are finalized, avoiding leaked resources on an error cleanup path.
        _ = c.sqlite3_close_v2(db.handle);
    }

    pub fn exec(db: Db, sql: [:0]const u8) Error!void {
        try check(c.sqlite3_exec(db.handle, sql, null, null, null));
    }

    pub fn prepare(db: Db, sql: [:0]const u8) Error!Stmt {
        var handle: ?*c.sqlite3_stmt = null;
        try check(c.sqlite3_prepare_v2(db.handle, sql, -1, &handle, null));
        return .{ .handle = handle orelse return error.SqliteError };
    }

    pub fn begin(db: Db) Error!void {
        try db.exec("BEGIN IMMEDIATE");
    }
    pub fn commit(db: Db) Error!void {
        try db.exec("COMMIT");
    }
    pub fn rollback(db: Db) void {
        db.exec("ROLLBACK") catch {};
    }
};

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    pub fn close(stmt: Stmt) void {
        _ = c.sqlite3_finalize(stmt.handle);
    }
    pub fn deinit(stmt: Stmt) void {
        stmt.close();
    }

    /// SQLite takes its own copy, so callers may immediately release value.
    pub fn bindText(stmt: Stmt, index: c_int, value: []const u8) Error!void {
        if (value.len > std.math.maxInt(c_int)) return error.ValueTooLarge;
        const transient: c.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));
        try check(c.sqlite3_bind_text(stmt.handle, index, value.ptr, @intCast(value.len), transient));
    }
    pub fn bindInt(stmt: Stmt, index: c_int, value: i64) Error!void {
        try check(c.sqlite3_bind_int64(stmt.handle, index, value));
    }
    pub fn bindNull(stmt: Stmt, index: c_int) Error!void {
        try check(c.sqlite3_bind_null(stmt.handle, index));
    }

    /// true means a row is available; false means the statement has completed.
    pub fn step(stmt: Stmt) Error!bool {
        const code = c.sqlite3_step(stmt.handle);
        try check(code);
        return code == c.SQLITE_ROW;
    }
    pub fn reset(stmt: Stmt) Error!void {
        try check(c.sqlite3_reset(stmt.handle));
        try check(c.sqlite3_clear_bindings(stmt.handle));
    }
    /// Borrowed until step/reset/close; NULL is represented by an empty slice.
    pub fn columnText(stmt: Stmt, column: c_int) []const u8 {
        const pointer = c.sqlite3_column_text(stmt.handle, column) orelse return "";
        const len: usize = @intCast(c.sqlite3_column_bytes(stmt.handle, column));
        return pointer[0..len];
    }
    pub fn columnInt(stmt: Stmt, column: c_int) i64 {
        return c.sqlite3_column_int64(stmt.handle, column);
    }
    pub fn columnIsNull(stmt: Stmt, column: c_int) bool {
        return c.sqlite3_column_type(stmt.handle, column) == c.SQLITE_NULL;
    }
};

test "SQLite persists committed rows and rolls back partial writes" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    {
        const db = try Db.open(t.allocator, t.io, root);
        defer db.close();
        try db.begin();
        var insert = try db.prepare("INSERT INTO documents(key,value) VALUES(?1,?2)");
        defer insert.close();
        try insert.bindText(1, "progress");
        try insert.bindText(2, "chapter\x00one");
        try t.expect(!try insert.step());
        try db.commit();
        try db.begin();
        try db.exec("UPDATE documents SET value='lost' WHERE key='progress'");
        db.rollback();
    }
    const db = try Db.open(t.allocator, t.io, root);
    defer db.close();
    var query = try db.prepare("SELECT value FROM documents WHERE key=?1");
    defer query.close();
    try query.bindText(1, "progress");
    try t.expect(try query.step());
    try t.expectEqualStrings("chapter\x00one", query.columnText(0));
    try t.expect(!try query.step());
    try query.reset();
    try query.bindText(1, "missing");
    try t.expect(!try query.step());
    const bytes = try tmp.dir.readFileAlloc(t.io, "tachi.sqlite3", t.allocator, .limited(1024 * 1024));
    defer t.allocator.free(bytes);
    try t.expect(std.mem.startsWith(u8, bytes, "SQLite format 3\x00"));
}

test "SQLite connection enforces foreign keys and full durability" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    const db = try Db.open(t.allocator, t.io, root);
    defer db.close();
    try db.exec("CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(parent_id INTEGER REFERENCES parent(id));");
    try t.expectError(error.SqliteConstraint, db.exec("INSERT INTO child VALUES(42)"));
    var pragma = try db.prepare("PRAGMA synchronous");
    defer pragma.close();
    try t.expect(try pragma.step());
    try t.expectEqual(@as(i64, 2), pragma.columnInt(0));
}

test "SQLite rejects corrupt and future databases without replacing them" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(root);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "tachi.sqlite3", .data = "not a sqlite database" });
    try t.expectError(error.SqliteCorrupt, Db.open(t.allocator, t.io, root));
    const original = try tmp.dir.readFileAlloc(t.io, "tachi.sqlite3", t.allocator, .limited(1024));
    defer t.allocator.free(original);
    try t.expectEqualStrings("not a sqlite database", original);
    try tmp.dir.deleteFile(t.io, "tachi.sqlite3");
    {
        const db = try Db.open(t.allocator, t.io, root);
        defer db.close();
        try db.exec("PRAGMA user_version=999");
    }
    try t.expectError(error.UnsupportedSchema, Db.open(t.allocator, t.io, root));
}

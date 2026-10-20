//! Mihon backups (`.tachibk`): a gzip stream around one protobuf `Backup`,
//! as Mihon writes it with kotlinx.serialization (mihonapp/mihon 487c313).
//! `decode` and `encode` handle the format; `fromLibrary` and `restore` map
//! it to and from the library with Mihon's restore rules, so a backup moves
//! between Mihon and a libtachi app in either direction.
//!
//! Encoding follows kotlinx.serialization's ProtoBuf: integers are
//! two's-complement varints (not ZigZag), floats are little-endian fixed32,
//! repeated fields are unpacked, and fields equal to their default are left
//! out. Preference values are kotlinx's polymorphic form: a message with
//! the value's class name and the value message, which is always written.
//! Unknown fields are skipped; extension stores are kept as encoded messages.
const std = @import("std");
const library = @import("library.zig");
const models = @import("models.zig");

// ---- model ------------------------------------------------------------------------

pub const Backup = struct {
    manga: []const Manga = &.{},
    categories: []const Category = &.{},
    sources: []const Source = &.{},
    /// App settings (field 104).
    preferences: []const Preference = &.{},
    /// Each configurable source's settings (field 105).
    source_preferences: []const SourcePreferences = &.{},
    /// Extension stores (field 106).
    extension_stores: []const ExtensionStore = &.{},
};

/// Mihon's `BackupExtensionStore`.
pub const ExtensionStore = struct {
    index_url: []const u8,
    name: []const u8 = "",
    badge_label: ?[]const u8 = null,
    signing_key: []const u8 = "",
    contact_website: []const u8 = "",
    contact_discord: ?[]const u8 = null,
    legacy: ?bool = null,
    extension_list_url: ?[]const u8 = null,
};

/// One Android SharedPreferences entry.
pub const Preference = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        int: i32,
        long: i64,
        float: f32,
        string: []const u8,
        boolean: bool,
        string_set: []const []const u8,

        /// kotlinx's serial name for the value's class in Mihon.
        fn className(self: Value) []const u8 {
            return switch (self) {
                inline else => |_, tag| comptime class_prefix ++ class_names.get(tag),
            };
        }
    };

    const class_prefix = "eu.kanade.tachiyomi.data.backup.models.";
    const class_names: std.EnumArray(std.meta.Tag(Value), []const u8) = .init(.{
        .int = "IntPreferenceValue",
        .long = "LongPreferenceValue",
        .float = "FloatPreferenceValue",
        .string = "StringPreferenceValue",
        .boolean = "BooleanPreferenceValue",
        .string_set = "StringSetPreferenceValue",
    });
};

/// A source's settings: `source_<id>` and its entries.
pub const SourcePreferences = struct {
    key: []const u8,
    prefs: []const Preference = &.{},
};

pub const Manga = struct {
    /// Mihon's local source is 0.
    source: i64,
    url: []const u8,
    title: []const u8 = "",
    artist: ?[]const u8 = null,
    author: ?[]const u8 = null,
    description: ?[]const u8 = null,
    genre: []const []const u8 = &.{},
    status: i32 = 0,
    thumbnail_url: ?[]const u8 = null,
    /// Milliseconds since the epoch.
    date_added: i64 = 0,
    viewer: i32 = 0,
    chapters: []const Chapter = &.{},
    /// Orders of the backup's categories, not category ids.
    categories: []const i64 = &.{},
    tracking: []const Tracking = &.{},
    favorite: bool = true,
    chapter_flags: i32 = 0,
    viewer_flags: ?i32 = null,
    history: []const History = &.{},
    /// 0 always update, 1 only fetch once.
    update_strategy: i32 = 0,
    /// Seconds since the epoch (legacy).
    favorite_modified_at: ?i64 = null,
    excluded_scanlators: []const []const u8 = &.{},
    notes: []const u8 = "",
    initialized: bool = false,
    /// A JSON object, as UTF-8.
    memo: []const u8 = "{}",
    next_update: i64 = 0,
};

pub const Chapter = struct {
    url: []const u8,
    name: []const u8,
    scanlator: ?[]const u8 = null,
    read: bool = false,
    bookmark: bool = false,
    /// Zero-based.
    last_page_read: i64 = 0,
    date_fetch: i64 = 0,
    date_upload: i64 = 0,
    chapter_number: f32 = 0,
    source_order: i64 = 0,
    memo: []const u8 = "{}",
};

pub const Category = struct {
    name: []const u8,
    order: i64 = 0,
    id: i64 = 0,
    flags: i64 = 0,
};

pub const History = struct {
    /// The chapter's URL within its manga.
    url: []const u8,
    last_read: i64,
    /// Milliseconds.
    read_duration: i64 = 0,
};

pub const Source = struct {
    name: []const u8 = "",
    source_id: i64,
};

pub const Tracking = struct {
    sync_id: i32,
    library_id: i64,
    media_id_int: i32 = 0,
    tracking_url: []const u8 = "",
    title: []const u8 = "",
    last_chapter_read: f32 = 0,
    total_chapters: i32 = 0,
    score: f32 = 0,
    status: i32 = 0,
    started_reading_date: i64 = 0,
    finished_reading_date: i64 = 0,
    private: bool = false,
    media_id: i64 = 0,
};

// ---- protobuf ---------------------------------------------------------------------

const Wire = enum(u3) { varint = 0, fixed64 = 1, len = 2, fixed32 = 5, _ };

const Field = struct {
    number: u32,
    value: union(Wire) {
        varint: u64,
        fixed64: u64,
        len: []const u8,
        fixed32: u32,
    },

    fn int64(self: Field) !i64 {
        return switch (self.value) {
            .varint => |v| @bitCast(v),
            else => error.InvalidBackup,
        };
    }
    fn int32(self: Field) !i32 {
        return @truncate(try self.int64());
    }
    fn boolean(self: Field) !bool {
        return (try self.int64()) != 0;
    }
    fn float(self: Field) !f32 {
        return switch (self.value) {
            .fixed32 => |v| @bitCast(v),
            else => error.InvalidBackup,
        };
    }
    fn bytes(self: Field) ![]const u8 {
        return switch (self.value) {
            .len => |b| b,
            else => error.InvalidBackup,
        };
    }
};

const Reader = struct {
    input: std.Io.Reader,

    fn init(bytes: []const u8) Reader {
        return .{ .input = .fixed(bytes) };
    }

    fn varint(self: *Reader) !u64 {
        // Protobuf varints occupy at most ten bytes, including sign extension.
        const remaining = self.input.buffered();
        var input: std.Io.Reader = .fixed(remaining[0..@min(10, remaining.len)]);
        defer self.input.toss(input.seek);
        return input.takeLeb128(u64) catch return error.InvalidBackup;
    }

    fn next(self: *Reader) !?Field {
        return self.nextAllowZero(false);
    }

    fn nextAllowZero(self: *Reader, legacy: bool) !?Field {
        if (self.input.bufferedLen() == 0) return null;
        const key = try self.varint();
        // Protobuf field numbers are 29 bits, even on a 64-bit host.
        const number = std.math.cast(u29, key >> 3) orelse return error.InvalidBackup;
        if (number == 0 and !legacy) return error.InvalidBackup;
        const wire: Wire = @fromBackingInt(@as(u3, @truncate(key)));
        if (number == 0 and wire != .len) return error.InvalidBackup;
        return .{ .number = number, .value = switch (wire) {
            .varint => .{ .varint = try self.varint() },
            .fixed64 => .{ .fixed64 = self.input.takeInt(u64, .little) catch return error.InvalidBackup },
            .fixed32 => .{ .fixed32 = self.input.takeInt(u32, .little) catch return error.InvalidBackup },
            .len => blk: {
                const n = std.math.cast(usize, try self.varint()) orelse return error.InvalidBackup;
                break :blk .{ .len = self.input.take(n) catch return error.InvalidBackup };
            },
            _ => return error.InvalidBackup,
        } };
    }
};

/// A repeated numeric field, unpacked as Mihon writes it or packed.
fn appendInt64(arena: std.mem.Allocator, list: *std.ArrayList(i64), field: Field) !void {
    switch (field.value) {
        .varint => |v| try list.append(arena, @bitCast(v)),
        .len => |b| {
            var r: Reader = .init(b);
            while (r.input.bufferedLen() > 0) try list.append(arena, @bitCast(try r.varint()));
        },
        else => return error.InvalidBackup,
    }
}

const Writer = struct {
    arena: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    fn varint(self: *Writer, value: u64) !void {
        var v = value;
        while (v >= 0x80) : (v >>= 7) try self.out.append(self.arena, @as(u8, @truncate(v)) | 0x80);
        try self.out.append(self.arena, @truncate(v));
    }
    fn key(self: *Writer, number: u32, wire: Wire) !void {
        try self.varint(@as(u64, number) << 3 | @backingInt(wire));
    }
    fn int64(self: *Writer, number: u32, value: i64) !void {
        try self.key(number, .varint);
        try self.varint(@bitCast(value));
    }
    /// Negative 32-bit values are sign-extended to ten bytes, as protobuf does.
    fn int32(self: *Writer, number: u32, value: i32) !void {
        try self.int64(number, value);
    }
    fn boolean(self: *Writer, number: u32, value: bool) !void {
        try self.key(number, .varint);
        try self.varint(@intFromBool(value));
    }
    fn float(self: *Writer, number: u32, value: f32) !void {
        try self.key(number, .fixed32);
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, @bitCast(value), .little);
        try self.out.appendSlice(self.arena, &buf);
    }
    fn bytes(self: *Writer, number: u32, value: []const u8) !void {
        try self.key(number, .len);
        try self.varint(value.len);
        try self.out.appendSlice(self.arena, value);
    }
    // Defaults are left out, as kotlinx.serialization does with encodeDefaults off.
    fn int64Opt(self: *Writer, number: u32, value: i64, default: i64) !void {
        if (value != default) try self.int64(number, value);
    }
    fn int32Opt(self: *Writer, number: u32, value: i32, default: i32) !void {
        if (value != default) try self.int32(number, value);
    }
    fn boolOpt(self: *Writer, number: u32, value: bool, default: bool) !void {
        if (value != default) try self.boolean(number, value);
    }
    fn floatOpt(self: *Writer, number: u32, value: f32) !void {
        if (value != 0) try self.float(number, value);
    }
    fn stringOpt(self: *Writer, number: u32, value: []const u8, default: []const u8) !void {
        if (!std.mem.eql(u8, value, default)) try self.bytes(number, value);
    }
    fn nullable(self: *Writer, number: u32, value: ?[]const u8) !void {
        if (value) |v| try self.bytes(number, v);
    }
    fn message(self: *Writer, number: u32, value: anytype, comptime encodeFn: anytype) !void {
        var inner: Writer = .{ .arena = self.arena };
        try encodeFn(&inner, value);
        try self.bytes(number, inner.out.items);
    }
};

// ---- decoding ---------------------------------------------------------------------

/// A backup from `.tachibk` bytes: gzip-compressed or raw protobuf. Strings
/// point into `arena` copies.
pub fn decode(arena: std.mem.Allocator, data: []const u8) !Backup {
    if (data.len >= 2 and data[0] == '{' and (data[1] == '}' or data[1] == '"' or data[1] == '\n')) return error.JsonBackupUnsupported;
    const raw = if (data.len >= 2 and data[0] == 0x1f and data[1] == 0x8b) try gunzip(arena, data) else try arena.dupe(u8, data);
    return decodeBackup(arena, raw);
}

fn gunzip(arena: std.mem.Allocator, data: []const u8) ![]u8 {
    var input: std.Io.Reader = .fixed(data);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var decompress: std.compress.flate.Decompress = .init(&input, .gzip, window);
    var out: std.Io.Writer.Allocating = .init(arena);
    _ = decompress.reader.streamRemaining(&out.writer) catch |err| switch (err) {
        error.ReadFailed => return decompress.err orelse error.InvalidBackup,
        else => |e| return e,
    };
    return out.toOwnedSlice();
}

fn decodeBackup(arena: std.mem.Allocator, bytes: []const u8) !Backup {
    var r: Reader = .init(bytes);
    var manga: std.ArrayList(Manga) = .empty;
    var categories: std.ArrayList(Category) = .empty;
    var sources: std.ArrayList(Source) = .empty;
    var preferences: std.ArrayList(Preference) = .empty;
    var source_preferences: std.ArrayList(SourcePreferences) = .empty;
    var stores: std.ArrayList(ExtensionStore) = .empty;
    while (try r.next()) |f| switch (f.number) {
        1 => try manga.append(arena, try decodeManga(arena, try f.bytes())),
        2 => try categories.append(arena, try decodeCategory(try f.bytes())),
        // 100 held the broken legacy source list; 101 replaced it.
        100, 101 => try sources.append(arena, try decodeSource(try f.bytes(), f.number == 100)),
        104 => if (try decodePreference(arena, try f.bytes())) |p| try preferences.append(arena, p),
        105 => try source_preferences.append(arena, try decodeSourcePreferences(arena, try f.bytes())),
        106 => try stores.append(arena, try decodeExtensionStore(try f.bytes())),
        else => {},
    };
    return .{ .manga = manga.items, .categories = categories.items, .sources = sources.items, .preferences = preferences.items, .source_preferences = source_preferences.items, .extension_stores = stores.items };
}

fn decodeExtensionStore(bytes: []const u8) !ExtensionStore {
    var r: Reader = .init(bytes);
    var store: ExtensionStore = .{ .index_url = "" };
    while (try r.next()) |f| switch (f.number) {
        1 => store.index_url = try f.bytes(),
        2 => store.name = try f.bytes(),
        3 => store.badge_label = try f.bytes(),
        4 => store.contact_website = try f.bytes(),
        5 => store.signing_key = try f.bytes(),
        6 => store.contact_discord = try f.bytes(),
        7 => store.legacy = try f.boolean(),
        8 => store.extension_list_url = try f.bytes(),
        else => {},
    };
    return store;
}

/// A preference, or null for a value class this doesn't know.
fn decodePreference(arena: std.mem.Allocator, bytes: []const u8) !?Preference {
    var r: Reader = .init(bytes);
    var key: []const u8 = "";
    var class: []const u8 = "";
    var value_bytes: []const u8 = "";
    while (try r.next()) |f| switch (f.number) {
        1 => key = try f.bytes(),
        2 => {
            var poly: Reader = .init(try f.bytes());
            while (try poly.next()) |pf| switch (pf.number) {
                1 => class = try pf.bytes(),
                2 => value_bytes = try pf.bytes(),
                else => {},
            };
        },
        else => {},
    };
    if (!std.mem.startsWith(u8, class, Preference.class_prefix)) return null;
    const name = class[Preference.class_prefix.len..];
    const tag = for (std.enums.values(std.meta.Tag(Preference.Value))) |t| {
        if (std.mem.eql(u8, Preference.class_names.get(t), name)) break t;
    } else return null;
    var v: Reader = .init(value_bytes);
    var set: std.ArrayList([]const u8) = .empty;
    var value: Preference.Value = switch (tag) {
        .int => .{ .int = 0 },
        .long => .{ .long = 0 },
        .float => .{ .float = 0 },
        .string => .{ .string = "" },
        .boolean => .{ .boolean = false },
        .string_set => .{ .string_set = &.{} },
    };
    while (try v.next()) |f| if (f.number == 1) switch (value) {
        .int => value = .{ .int = try f.int32() },
        .long => value = .{ .long = try f.int64() },
        .float => value = .{ .float = try f.float() },
        .string => value = .{ .string = try f.bytes() },
        .boolean => value = .{ .boolean = try f.boolean() },
        .string_set => try set.append(arena, try f.bytes()),
    };
    if (value == .string_set) value = .{ .string_set = set.items };
    return .{ .key = key, .value = value };
}

fn decodeSourcePreferences(arena: std.mem.Allocator, bytes: []const u8) !SourcePreferences {
    var r: Reader = .init(bytes);
    var result: SourcePreferences = .{ .key = "" };
    var prefs: std.ArrayList(Preference) = .empty;
    while (try r.next()) |f| switch (f.number) {
        1 => result.key = try f.bytes(),
        2 => if (try decodePreference(arena, try f.bytes())) |p| try prefs.append(arena, p),
        else => {},
    };
    result.prefs = prefs.items;
    return result;
}

fn decodeManga(arena: std.mem.Allocator, bytes: []const u8) !Manga {
    var r: Reader = .init(bytes);
    var m: Manga = .{ .source = 0, .url = "" };
    var source_seen = false;
    var url_seen = false;
    var genre: std.ArrayList([]const u8) = .empty;
    var chapters: std.ArrayList(Chapter) = .empty;
    var categories: std.ArrayList(i64) = .empty;
    var tracking: std.ArrayList(Tracking) = .empty;
    var history: std.ArrayList(History) = .empty;
    var excluded: std.ArrayList([]const u8) = .empty;
    while (try r.next()) |f| switch (f.number) {
        1 => {
            m.source = try f.int64();
            source_seen = true;
        },
        2 => {
            m.url = try f.bytes();
            url_seen = true;
        },
        3 => m.title = try f.bytes(),
        4 => m.artist = try f.bytes(),
        5 => m.author = try f.bytes(),
        6 => m.description = try f.bytes(),
        7 => try genre.append(arena, try f.bytes()),
        8 => m.status = try f.int32(),
        9 => m.thumbnail_url = try f.bytes(),
        13 => m.date_added = try f.int64(),
        14 => m.viewer = try f.int32(),
        16 => try chapters.append(arena, try decodeChapter(try f.bytes())),
        17 => try appendInt64(arena, &categories, f),
        18 => try tracking.append(arena, try decodeTracking(try f.bytes())),
        100 => m.favorite = try f.boolean(),
        101 => m.chapter_flags = try f.int32(),
        // 102: legacy history with a field numbered 0.
        102 => try history.append(arena, try decodeHistory(try f.bytes(), true)),
        103 => m.viewer_flags = try f.int32(),
        104 => try history.append(arena, try decodeHistory(try f.bytes(), false)),
        105 => m.update_strategy = try f.int32(),
        107 => m.favorite_modified_at = try f.int64(),
        108 => try excluded.append(arena, try f.bytes()),
        110 => m.notes = try f.bytes(),
        111 => m.initialized = try f.boolean(),
        112 => m.memo = try f.bytes(),
        113 => m.next_update = try f.int64(),
        else => {},
    };
    if (!source_seen or !url_seen) return error.InvalidBackup;
    m.genre = genre.items;
    m.chapters = chapters.items;
    m.categories = categories.items;
    m.tracking = tracking.items;
    m.history = history.items;
    m.excluded_scanlators = excluded.items;
    return m;
}

fn decodeChapter(bytes: []const u8) !Chapter {
    var r: Reader = .init(bytes);
    var c: Chapter = .{ .url = "", .name = "" };
    while (try r.next()) |f| switch (f.number) {
        1 => c.url = try f.bytes(),
        2 => c.name = try f.bytes(),
        3 => c.scanlator = try f.bytes(),
        4 => c.read = try f.boolean(),
        5 => c.bookmark = try f.boolean(),
        6 => c.last_page_read = try f.int64(),
        7 => c.date_fetch = try f.int64(),
        8 => c.date_upload = try f.int64(),
        9 => c.chapter_number = try f.float(),
        10 => c.source_order = try f.int64(),
        13 => c.memo = try f.bytes(),
        else => {},
    };
    return c;
}

fn decodeCategory(bytes: []const u8) !Category {
    var r: Reader = .init(bytes);
    var c: Category = .{ .name = "" };
    while (try r.next()) |f| switch (f.number) {
        1 => c.name = try f.bytes(),
        2 => c.order = try f.int64(),
        3 => c.id = try f.int64(),
        100 => c.flags = try f.int64(),
        else => {},
    };
    return c;
}

fn decodeHistory(bytes: []const u8, legacy: bool) !History {
    var r: Reader = .init(bytes);
    var h: History = .{ .url = "", .last_read = 0 };
    // Legacy messages numbered their fields from 0.
    const base: u32 = if (legacy) 0 else 1;
    while (try nextLegacy(&r, legacy)) |f| {
        if (f.number == base) h.url = try f.bytes() else if (f.number == base + 1) h.last_read = try f.int64() else if (f.number == base + 2) h.read_duration = try f.int64();
    }
    return h;
}

fn decodeSource(bytes: []const u8, legacy: bool) !Source {
    var r: Reader = .init(bytes);
    var s: Source = .{ .source_id = 0 };
    while (try nextLegacy(&r, legacy)) |f| {
        if (legacy) {
            if (f.number == 0) s.name = try f.bytes() else if (f.number == 1) s.source_id = try f.int64();
        } else if (f.number == 1) s.name = try f.bytes() else if (f.number == 2) s.source_id = try f.int64();
    }
    return s;
}

/// `Reader.next`, accepting field number 0 inside legacy messages only.
fn nextLegacy(r: *Reader, legacy: bool) !?Field {
    return r.nextAllowZero(legacy);
}

fn decodeTracking(bytes: []const u8) !Tracking {
    var r: Reader = .init(bytes);
    var t: Tracking = .{ .sync_id = 0, .library_id = 0 };
    while (try r.next()) |f| switch (f.number) {
        1 => t.sync_id = try f.int32(),
        2 => t.library_id = try f.int64(),
        3 => t.media_id_int = try f.int32(),
        4 => t.tracking_url = try f.bytes(),
        5 => t.title = try f.bytes(),
        6 => t.last_chapter_read = try f.float(),
        7 => t.total_chapters = try f.int32(),
        8 => t.score = try f.float(),
        9 => t.status = try f.int32(),
        10 => t.started_reading_date = try f.int64(),
        11 => t.finished_reading_date = try f.int64(),
        12 => t.private = try f.boolean(),
        100 => t.media_id = try f.int64(),
        else => {},
    };
    return t;
}

// ---- encoding ---------------------------------------------------------------------

/// The backup as protobuf, without compression.
pub fn encode(arena: std.mem.Allocator, backup: Backup) ![]const u8 {
    var w: Writer = .{ .arena = arena };
    for (backup.manga) |m| try w.message(1, m, encodeManga);
    for (backup.categories) |c| try w.message(2, c, encodeCategory);
    for (backup.sources) |s| try w.message(101, s, encodeSource);
    for (backup.preferences) |p| try w.message(104, p, encodePreference);
    for (backup.source_preferences) |p| try w.message(105, p, encodeSourcePreferences);
    for (backup.extension_stores) |p| try w.message(106, p, encodeExtensionStore);
    return w.out.items;
}

/// The backup as a `.tachibk` file: gzip around the protobuf.
pub fn encodeFile(arena: std.mem.Allocator, backup: Backup) ![]const u8 {
    const raw = try encode(arena, backup);
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.ensureUnusedCapacity(64);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var compress: std.compress.flate.Compress = try .init(&out.writer, window, .gzip, .default);
    try compress.writer.writeAll(raw);
    try compress.finish();
    return out.toOwnedSlice();
}

/// In the class's declaration order, which kotlinx writes: the signing
/// key (5) comes before the website (4).
fn encodeExtensionStore(w: *Writer, s: ExtensionStore) !void {
    try w.bytes(1, s.index_url);
    try w.bytes(2, s.name);
    try w.nullable(3, s.badge_label);
    try w.bytes(5, s.signing_key);
    try w.bytes(4, s.contact_website);
    try w.nullable(6, s.contact_discord);
    if (s.legacy) |legacy| try w.boolean(7, legacy);
    try w.nullable(8, s.extension_list_url);
}

fn encodePreference(w: *Writer, p: Preference) !void {
    try w.bytes(1, p.key);
    try w.message(2, p.value, encodePolymorphic);
}

fn encodePolymorphic(w: *Writer, value: Preference.Value) !void {
    try w.bytes(1, value.className());
    try w.message(2, value, encodeValue);
}

/// The value has no default, so it is always written.
fn encodeValue(w: *Writer, value: Preference.Value) !void {
    switch (value) {
        .int => |v| try w.int32(1, v),
        .long => |v| try w.int64(1, v),
        .float => |v| try w.float(1, v),
        .string => |v| try w.bytes(1, v),
        .boolean => |v| try w.boolean(1, v),
        .string_set => |set| for (set) |v| try w.bytes(1, v),
    }
}

fn encodeSourcePreferences(w: *Writer, p: SourcePreferences) !void {
    try w.bytes(1, p.key);
    for (p.prefs) |pref| try w.message(2, pref, encodePreference);
}

fn encodeManga(w: *Writer, m: Manga) !void {
    try w.int64(1, m.source);
    try w.bytes(2, m.url);
    try w.stringOpt(3, m.title, "");
    try w.nullable(4, m.artist);
    try w.nullable(5, m.author);
    try w.nullable(6, m.description);
    for (m.genre) |g| try w.bytes(7, g);
    try w.int32Opt(8, m.status, 0);
    try w.nullable(9, m.thumbnail_url);
    try w.int64Opt(13, m.date_added, 0);
    try w.int32Opt(14, m.viewer, 0);
    for (m.chapters) |c| try w.message(16, c, encodeChapter);
    for (m.categories) |c| try w.int64(17, c);
    for (m.tracking) |t| try w.message(18, t, encodeTracking);
    try w.boolOpt(100, m.favorite, true);
    try w.int32Opt(101, m.chapter_flags, 0);
    if (m.viewer_flags) |v| try w.int32(103, v);
    for (m.history) |h| try w.message(104, h, encodeHistory);
    try w.int32Opt(105, m.update_strategy, 0);
    if (m.favorite_modified_at) |v| try w.int64(107, v);
    for (m.excluded_scanlators) |s| try w.bytes(108, s);
    try w.stringOpt(110, m.notes, "");
    try w.boolOpt(111, m.initialized, false);
    try w.stringOpt(112, m.memo, "{}");
    try w.int64Opt(113, m.next_update, 0);
}

fn encodeChapter(w: *Writer, c: Chapter) !void {
    try w.bytes(1, c.url);
    try w.bytes(2, c.name);
    try w.nullable(3, c.scanlator);
    try w.boolOpt(4, c.read, false);
    try w.boolOpt(5, c.bookmark, false);
    try w.int64Opt(6, c.last_page_read, 0);
    try w.int64Opt(7, c.date_fetch, 0);
    try w.int64Opt(8, c.date_upload, 0);
    try w.floatOpt(9, c.chapter_number);
    try w.int64Opt(10, c.source_order, 0);
    try w.stringOpt(13, c.memo, "{}");
}

fn encodeCategory(w: *Writer, c: Category) !void {
    try w.bytes(1, c.name);
    try w.int64Opt(2, c.order, 0);
    try w.int64Opt(3, c.id, 0);
    try w.int64Opt(100, c.flags, 0);
}

fn encodeHistory(w: *Writer, h: History) !void {
    try w.bytes(1, h.url);
    // Required, so written even when zero.
    try w.int64(2, h.last_read);
    try w.int64Opt(3, h.read_duration, 0);
}

fn encodeSource(w: *Writer, s: Source) !void {
    try w.stringOpt(1, s.name, "");
    try w.int64(2, s.source_id);
}

fn encodeTracking(w: *Writer, t: Tracking) !void {
    try w.int32(1, t.sync_id);
    try w.int64(2, t.library_id);
    try w.int32Opt(3, t.media_id_int, 0);
    try w.stringOpt(4, t.tracking_url, "");
    try w.stringOpt(5, t.title, "");
    try w.floatOpt(6, t.last_chapter_read);
    try w.int32Opt(7, t.total_chapters, 0);
    try w.floatOpt(8, t.score);
    try w.int32Opt(9, t.status, 0);
    try w.int64Opt(10, t.started_reading_date, 0);
    try w.int64Opt(11, t.finished_reading_date, 0);
    try w.boolOpt(12, t.private, false);
    try w.int64Opt(100, t.media_id, 0);
}

// ---- library mapping --------------------------------------------------------------

/// Mihon's local source id; its titles are `local:<url>` in the library.
pub const local_source: i64 = 0;

fn ids(arena: std.mem.Allocator, source: i64, url: []const u8) ![]const u8 {
    return if (source == local_source) std.fmt.allocPrint(arena, "local:{s}", .{url}) else library.mangaId(arena, source, url);
}

pub const ExportOptions = struct {
    categories: bool = true,
    chapters: bool = true,
    tracking: bool = true,
    history: bool = true,
    /// Also titles outside the library that have reading progress.
    read_entries: bool = true,
    /// The engine adds these: app settings, extensions' settings, and
    /// private values (tokens, passwords) in either.
    app_settings: bool = true,
    source_settings: bool = true,
    extension_stores: bool = true,
    private_settings: bool = false,
};

/// The library as a backup.
pub fn fromLibrary(arena: std.mem.Allocator, lib: library.Library, options: ExportOptions) !Backup {
    var manga: std.ArrayList(Manga) = .empty;
    var source_ids: std.AutoArrayHashMapUnmanaged(i64, void) = .empty;
    for (lib.manga) |m| {
        if (!m.favorite) {
            if (!options.read_entries) continue;
            const progressed = for (m.chapters) |ch| {
                if (ch.read or ch.last_page_read != 0) break true;
            } else false;
            if (!progressed) continue;
        }
        const source = m.source_id orelse local_source;
        try source_ids.put(arena, source, {});
        const remote = m.remote;
        const url = if (remote) |r| r.url else if (std.mem.startsWith(u8, m.id, "local:")) m.id["local:".len..] else m.id;
        var chapters: std.ArrayList(Chapter) = .empty;
        var history: std.ArrayList(History) = .empty;
        for (m.chapters) |ch| {
            const chapter_url = if (ch.remote) |r| r.url else if (std.mem.startsWith(u8, ch.id, "local:")) ch.id["local:".len..] else ch.id;
            if (options.chapters) try chapters.append(arena, .{
                .url = chapter_url,
                .name = ch.title,
                .scanlator = ch.scanlator,
                .read = ch.read,
                .bookmark = ch.bookmark,
                .last_page_read = ch.last_page_read,
                .date_fetch = ch.date_fetch,
                .date_upload = ch.date_upload,
                .chapter_number = @floatCast(ch.number),
                .source_order = ch.source_order,
                .memo = try memoJson(arena, if (ch.remote) |r| r.memo else null),
            });
            if (options.history and ch.last_read != 0) try history.append(arena, .{ .url = chapter_url, .last_read = ch.last_read, .read_duration = ch.read_ms });
        }
        var categories: std.ArrayList(i64) = .empty;
        if (options.categories) for (m.categories) |id| {
            for (lib.categories) |c| if (c.id == id) try categories.append(arena, c.order);
        };
        var tracking: std.ArrayList(Tracking) = .empty;
        if (options.tracking) for (m.tracks) |t| try tracking.append(arena, .{
            .sync_id = t.tracker_id,
            .library_id = t.library_id,
            .tracking_url = t.url,
            .title = t.title,
            .last_chapter_read = @floatCast(t.last_chapter_read),
            .total_chapters = t.total_chapters,
            .score = @floatCast(t.score),
            .status = t.status,
            .started_reading_date = t.started,
            .finished_reading_date = t.finished,
            .private = t.private,
            .media_id = t.remote_id,
        });
        try manga.append(arena, .{
            .source = source,
            .url = url,
            .title = m.title,
            .artist = if (remote) |r| r.artist else null,
            .author = if (remote) |r| r.author else if (m.author.len > 0) m.author else null,
            .description = if (remote) |r| r.description else if (m.description.len > 0) m.description else null,
            .genre = if (remote) |r| try splitGenre(arena, r.genre) else &.{},
            .status = if (remote) |r| r.status else 0,
            .thumbnail_url = if (remote) |r| r.thumbnailUrl else null,
            .date_added = m.date_added,
            .viewer = @intCast(m.reader_flags & 7),
            .chapters = chapters.items,
            .categories = categories.items,
            .tracking = tracking.items,
            .favorite = m.favorite,
            .chapter_flags = @bitCast(m.chapter_flags),
            .viewer_flags = @bitCast(m.reader_flags),
            .history = history.items,
            .update_strategy = if (remote) |r| @intFromBool(std.mem.eql(u8, r.updateStrategy, "ONLY_FETCH_ONCE")) else 0,
            .excluded_scanlators = m.excluded_scanlators,
            .notes = m.notes,
            .initialized = if (remote) |r| r.initialized else false,
            .memo = try memoJson(arena, if (remote) |r| r.memo else null),
            .next_update = m.next_update,
        });
    }
    var categories: std.ArrayList(Category) = .empty;
    if (options.categories) for (lib.categories) |c| try categories.append(arena, .{ .name = c.name, .order = c.order, .id = c.id, .flags = c.flags });
    var sources: std.ArrayList(Source) = .empty;
    for (source_ids.keys()) |id| {
        var name: []const u8 = "";
        for (lib.sources) |s| if (s.id == id) {
            name = s.name;
        };
        try sources.append(arena, .{ .source_id = id, .name = name });
    }
    return .{ .manga = manga.items, .categories = categories.items, .sources = sources.items };
}

fn memoJson(arena: std.mem.Allocator, memo: ?std.json.Value) ![]const u8 {
    const value = memo orelse return "{}";
    return std.json.Stringify.valueAlloc(arena, value, .{});
}

fn splitGenre(arena: std.mem.Allocator, genre: ?[]const u8) ![]const []const u8 {
    const text = genre orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitSequence(u8, text, ", ");
    while (it.next()) |g| {
        const trimmed = std.mem.trim(u8, g, " ");
        if (trimmed.len > 0) try out.append(arena, trimmed);
    }
    return out.items;
}

fn parseMemo(arena: std.mem.Allocator, bytes: []const u8) !?std.json.Value {
    if (bytes.len == 0 or std.mem.eql(u8, bytes, "{}")) return null;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{}) catch return error.InvalidBackupMemo;
    if (value != .object) return error.InvalidBackupMemo;
    return value;
}

/// Shallow union, keys in `keep` winning.
fn unionMemo(arena: std.mem.Allocator, keep: ?std.json.Value, add: ?std.json.Value) !?std.json.Value {
    const a = keep orelse return add;
    const b = add orelse return keep;
    if (a != .object or b != .object) return keep;
    var merged: std.json.ObjectMap = .empty;
    var it = b.object.iterator();
    while (it.next()) |e| try merged.put(arena, e.key_ptr.*, e.value_ptr.*);
    var it2 = a.object.iterator();
    while (it2.next()) |e| try merged.put(arena, e.key_ptr.*, e.value_ptr.*);
    return .{ .object = merged };
}

pub const RestoreOptions = struct {
    library_entries: bool = true,
    categories: bool = true,
};

pub const Restored = struct {
    library: library.Library,
    /// Titles added or merged.
    restored: usize,
    /// Backup entries skipped as invalid.
    skipped: usize,
};

/// Merges a backup into the library with Mihon's restore rules: titles match
/// by source and URL, chapters by URL; library membership and read and
/// bookmark state only ever gain, page progress takes the furthest, history
/// the latest time and the longer duration; a title's own reader settings
/// and notes stay. Categories match by name.
pub fn restore(arena: std.mem.Allocator, lib: library.Library, backup: Backup, options: RestoreOptions) !Restored {
    var result = lib;
    var categories: std.ArrayList(library.Category) = .empty;
    try categories.appendSlice(arena, lib.categories);
    // Backup category order -> library category id, through the name.
    var by_order: std.AutoHashMapUnmanaged(i64, u32) = .empty;
    if (options.categories) {
        const sorted = try arena.dupe(Category, backup.categories);
        std.mem.sort(Category, sorted, {}, struct {
            fn less(_: void, a: Category, b: Category) bool {
                return a.order < b.order;
            }
        }.less);
        for (sorted) |c| {
            const id = for (categories.items) |existing| {
                if (std.mem.eql(u8, existing.name, c.name)) break existing.id;
            } else blk: {
                var next_id: u32 = 1;
                var next_order: u32 = 0;
                for (categories.items) |existing| {
                    next_id = @max(next_id, existing.id + 1);
                    next_order = @max(next_order, existing.order + 1);
                }
                try categories.append(arena, .{ .id = next_id, .name = c.name, .order = next_order, .flags = @truncate(@as(u64, @bitCast(c.flags))) });
                break :blk next_id;
            };
            try by_order.put(arena, c.order, id);
        }
        result.categories = categories.items;
    }
    // Source names for stubs.
    var sources: std.ArrayList(library.SourceName) = .empty;
    try sources.appendSlice(arena, lib.sources);
    for (backup.sources) |s| {
        if (s.name.len == 0) continue;
        const known = for (sources.items) |existing| {
            if (existing.id == s.source_id) break true;
        } else false;
        if (!known) try sources.append(arena, .{ .id = s.source_id, .name = s.name });
    }
    result.sources = sources.items;
    if (!options.library_entries) return .{ .library = result, .restored = 0, .skipped = 0 };

    var titles: std.ArrayList(library.Manga) = .empty;
    try titles.appendSlice(arena, lib.manga);
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    for (titles.items, 0..) |m, i| try index.put(arena, m.id, i);
    var restored: usize = 0;
    var skipped: usize = 0;
    for (backup.manga) |bm| {
        const merged = restoreManga(arena, bm, by_order, if (index.get(try ids(arena, bm.source, bm.url))) |i| titles.items[i] else null) catch {
            skipped += 1;
            continue;
        };
        if (index.get(merged.id)) |i| titles.items[i] = merged else {
            try index.put(arena, merged.id, titles.items.len);
            try titles.append(arena, merged);
        }
        restored += 1;
    }
    result.manga = titles.items;
    return .{ .library = result, .restored = restored, .skipped = skipped };
}

fn restoreManga(arena: std.mem.Allocator, bm: Manga, by_order: std.AutoHashMapUnmanaged(i64, u32), existing: ?library.Manga) !library.Manga {
    const id = try ids(arena, bm.source, bm.url);
    const favorite_at: i64 = if (!bm.favorite) 0 else if (bm.date_added > 0) bm.date_added else if (bm.favorite_modified_at) |s| s * 1000 else 0;
    const remote: models.Manga = .{
        .url = bm.url,
        .title = bm.title,
        .artist = bm.artist,
        .author = bm.author,
        .description = bm.description,
        .genre = if (bm.genre.len > 0) try std.mem.join(arena, ", ", bm.genre) else null,
        .status = bm.status,
        .thumbnailUrl = bm.thumbnail_url,
        .updateStrategy = if (bm.update_strategy == 1) "ONLY_FETCH_ONCE" else "ALWAYS_UPDATE",
        .initialized = bm.initialized,
        .memo = try parseMemo(arena, bm.memo),
    };
    var categories: std.ArrayList(u32) = .empty;
    for (bm.categories) |order| if (by_order.get(order)) |cid| try categories.append(arena, cid);
    const local = bm.source == local_source;

    var m: library.Manga = existing orelse .{
        .id = id,
        .title = if (bm.title.len > 0) bm.title else bm.url,
        .author = bm.author orelse "",
        .description = bm.description orelse "",
        .source_id = if (local) null else bm.source,
        .remote = if (local) null else remote,
        .date_added = favorite_at,
        .favorite = bm.favorite,
        .notes = bm.notes,
        .reader_flags = @bitCast(bm.viewer_flags orelse bm.viewer),
        .chapter_flags = @bitCast(bm.chapter_flags),
        .next_update = bm.next_update,
    };
    if (existing) |e| {
        m.favorite = e.favorite or bm.favorite;
        if (bm.favorite and favorite_at > 0 and (e.date_added == 0 or favorite_at < e.date_added)) m.date_added = favorite_at;
        const keep_existing = if (e.remote) |r| r.initialized or !bm.initialized else false;
        if (!local and !keep_existing) {
            var r = remote;
            r.memo = try unionMemo(arena, if (e.remote) |er| er.memo else null, remote.memo);
            m.remote = r;
            m.title = if (bm.title.len > 0) bm.title else e.title;
            m.author = bm.author orelse e.author;
            m.description = bm.description orelse e.description;
        } else if (e.remote) |er| {
            var r = er;
            r.initialized = er.initialized or bm.initialized;
            r.memo = try unionMemo(arena, er.memo, remote.memo);
            m.remote = r;
        }
        if (e.next_update == 0) m.next_update = bm.next_update;
    }
    if (categories.items.len > 0) m.categories = categories.items;
    // Excluded groups only ever gain.
    var excluded: std.ArrayList([]const u8) = .empty;
    try excluded.appendSlice(arena, m.excluded_scanlators);
    for (bm.excluded_scanlators) |s| {
        const known = for (excluded.items) |x| {
            if (std.mem.eql(u8, x, s)) break true;
        } else false;
        if (!known) try excluded.append(arena, s);
    }
    m.excluded_scanlators = excluded.items;
    m.chapters = try restoreChapters(arena, bm, m.chapters, local);
    m.tracks = try restoreTracks(arena, bm.tracking, m.tracks);
    library.sortReadingOrder(@constCast(m.chapters));
    return m;
}

fn restoreChapters(arena: std.mem.Allocator, bm: Manga, existing: []const library.Chapter, local: bool) ![]const library.Chapter {
    var chapters: std.ArrayList(library.Chapter) = .empty;
    try chapters.appendSlice(arena, existing);
    var by_url: std.StringHashMapUnmanaged(usize) = .empty;
    for (chapters.items, 0..) |ch, i| try by_url.put(arena, if (ch.remote) |r| r.url else ch.id, i);
    for (bm.chapters) |bc| {
        const id = if (local) try std.fmt.allocPrint(arena, "local:{s}", .{bc.url}) else try library.chapterId(arena, bm.source, bc.url);
        const key = if (local) id else bc.url;
        if (by_url.get(key)) |i| {
            const ch = &chapters.items[i];
            ch.read = ch.read or bc.read;
            ch.bookmark = ch.bookmark or bc.bookmark;
            ch.last_page_read = @max(ch.last_page_read, clampPage(bc.last_page_read));
            if (ch.remote) |*r| r.memo = try unionMemo(arena, r.memo, try parseMemo(arena, bc.memo));
            continue;
        }
        try by_url.put(arena, key, chapters.items.len);
        try chapters.append(arena, .{
            .id = id,
            .title = bc.name,
            .remote = if (local) null else .{ .url = bc.url, .name = bc.name, .chapterNumber = bc.chapter_number, .scanlator = bc.scanlator, .dateUpload = bc.date_upload, .memo = try parseMemo(arena, bc.memo) },
            .read = bc.read,
            .bookmark = bc.bookmark,
            .last_page_read = clampPage(bc.last_page_read),
            .date_fetch = bc.date_fetch,
            .date_upload = bc.date_upload,
            .number = bc.chapter_number,
            .source_order = @intCast(std.math.clamp(bc.source_order, 0, std.math.maxInt(u32))),
            .scanlator = bc.scanlator,
        });
    }
    // History: the latest time and the longer total, duplicates summed.
    var durations: std.StringHashMapUnmanaged(struct { last: i64, total: i64 }) = .empty;
    for (bm.history) |h| {
        const entry = try durations.getOrPut(arena, h.url);
        if (entry.found_existing) {
            entry.value_ptr.last = @max(entry.value_ptr.last, h.last_read);
            entry.value_ptr.total += h.read_duration;
        } else entry.value_ptr.* = .{ .last = h.last_read, .total = h.read_duration };
    }
    var it = durations.iterator();
    while (it.next()) |e| {
        const key = if (local) try std.fmt.allocPrint(arena, "local:{s}", .{e.key_ptr.*}) else e.key_ptr.*;
        const i = by_url.get(key) orelse continue;
        const ch = &chapters.items[i];
        ch.last_read = @max(ch.last_read, e.value_ptr.last);
        ch.read_ms = @max(ch.read_ms, e.value_ptr.total);
    }
    return chapters.items;
}

fn clampPage(page: i64) u32 {
    return @intCast(std.math.clamp(page, 0, std.math.maxInt(i32)));
}

fn restoreTracks(arena: std.mem.Allocator, backup: []const Tracking, existing: []const library.Track) ![]const library.Track {
    var tracks: std.ArrayList(library.Track) = .empty;
    try tracks.appendSlice(arena, existing);
    for (backup) |t| {
        const media: i64 = if (t.media_id_int != 0) t.media_id_int else t.media_id;
        for (tracks.items) |*known| if (known.tracker_id == t.sync_id) {
            // Only progress advances.
            if (t.last_chapter_read > known.last_chapter_read) known.last_chapter_read = t.last_chapter_read;
            break;
        } else try tracks.append(arena, .{
            .tracker_id = t.sync_id,
            .remote_id = media,
            .library_id = t.library_id,
            .title = t.title,
            .url = t.tracking_url,
            .last_chapter_read = t.last_chapter_read,
            .total_chapters = t.total_chapters,
            .status = t.status,
            .score = t.score,
            .started = t.started_reading_date,
            .finished = t.finished_reading_date,
            .private = t.private,
        });
    }
    return tracks.items;
}

/// Mihon's file name for a backup made at `date` (YYYY-MM-DD_HH-mm).
pub fn fileName(arena: std.mem.Allocator, app_id: []const u8, date: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}_{s}.tachibk", .{ app_id, date });
}

// ---- tests ------------------------------------------------------------------------

test "fields encode as kotlinx.serialization does" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // source=1 (varint), url="/m"; favorite defaults true and is omitted.
    const bytes = try encode(a, .{ .manga = &.{.{ .source = 1, .url = "/m" }} });
    try std.testing.expectEqualSlices(u8, &.{ 0x0a, 0x06, 0x08, 0x01, 0x12, 0x02, '/', 'm' }, bytes);
    // Negative ints are ten-byte two's complement; a non-default favorite is written.
    const negative = try encode(a, .{ .manga = &.{.{ .source = -1, .url = "", .favorite = false }} });
    try std.testing.expectEqualSlices(u8, &.{ 0x0a, 0x10, 0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x12, 0x00, 0xa0, 0x06, 0x00 }, negative);
}

test "a backup survives encode and decode, gzipped" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const original: Backup = .{
        .manga = &.{.{
            .source = 2499283573021220255,
            .url = "/title/abc",
            .title = "Solo",
            .genre = &.{ "Action", "Fantasy" },
            .status = 1,
            .chapters = &.{.{ .url = "/c/1", .name = "Chapter 1", .read = true, .last_page_read = 7, .chapter_number = 1, .source_order = 3, .memo = "{\"k\":1}" }},
            .categories = &.{ 0, 2 },
            .history = &.{.{ .url = "/c/1", .last_read = 1700000000000, .read_duration = 60000 }},
            .tracking = &.{.{ .sync_id = 2, .library_id = 9, .media_id = 77, .last_chapter_read = 1.5 }},
            .viewer_flags = 2,
            .notes = "note",
        }},
        .categories = &.{.{ .name = "Reading", .order = 2, .id = 5 }},
        .sources = &.{.{ .name = "MangaDex", .source_id = 2499283573021220255 }},
        .preferences = &.{.{ .key = "skip_read", .value = .{ .boolean = true } }},
    };
    const file = try encodeFile(a, original);
    try std.testing.expect(file[0] == 0x1f and file[1] == 0x8b);
    const back = try decode(a, file);
    try std.testing.expectEqualStrings("Solo", back.manga[0].title);
    try std.testing.expectEqual(2499283573021220255, back.manga[0].source);
    try std.testing.expectEqualStrings("Fantasy", back.manga[0].genre[1]);
    try std.testing.expectEqual(7, back.manga[0].chapters[0].last_page_read);
    try std.testing.expectEqual(1.0, back.manga[0].chapters[0].chapter_number);
    try std.testing.expectEqualSlices(i64, &.{ 0, 2 }, back.manga[0].categories);
    try std.testing.expectEqual(60000, back.manga[0].history[0].read_duration);
    try std.testing.expectEqual(1.5, back.manga[0].tracking[0].last_chapter_read);
    try std.testing.expectEqual(2, back.manga[0].viewer_flags.?);
    try std.testing.expectEqualStrings("Reading", back.categories[0].name);
    try std.testing.expectEqualStrings("MangaDex", back.sources[0].name);
    try std.testing.expectEqualStrings("skip_read", back.preferences[0].key);
    try std.testing.expect(back.preferences[0].value.boolean);
    // Raw protobuf decodes too; JSON is refused.
    _ = try decode(a, try encode(a, original));
    try std.testing.expectError(error.JsonBackupUnsupported, decode(a, "{\"a\":1}"));
}

test "packed repeated numbers and legacy messages decode" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // manga { source 1, url "u", categories packed [1, 2], broken history { 0:"c" 1:5 } }
    const manga = [_]u8{ 0x08, 0x01, 0x12, 0x01, 'u', 0x8a, 0x01, 0x02, 0x01, 0x02, 0xb2, 0x06, 0x05, 0x02, 0x01, 'c', 0x08, 0x05 };
    var bytes: [manga.len + 2]u8 = undefined;
    bytes[0] = 0x0a;
    bytes[1] = manga.len;
    @memcpy(bytes[2..], &manga);
    const backup = try decode(a, &bytes);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2 }, backup.manga[0].categories);
    try std.testing.expectEqualStrings("c", backup.manga[0].history[0].url);
    try std.testing.expectEqual(5, backup.manga[0].history[0].last_read);
}

test "library export and restore round-trip with Mihon's merge rules" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lib: library.Library = .{
        .manga = &.{
            .{ .id = "7:/m", .title = "M", .source_id = 7, .remote = .{ .url = "/m", .title = "M", .genre = "A, B", .initialized = true }, .date_added = 50, .categories = &.{1}, .notes = "mine", .reader_flags = 2, .chapters = &.{
                .{ .id = "7:/c1", .title = "Chapter 1", .remote = .{ .url = "/c1", .name = "Chapter 1" }, .read = true, .last_page_read = 3, .last_read = 900, .read_ms = 1000, .number = 1, .source_order = 1 },
                .{ .id = "7:/c2", .title = "Chapter 2", .remote = .{ .url = "/c2", .name = "Chapter 2" }, .number = 2 },
            } },
            .{ .id = "local:Mine", .title = "Mine", .chapters = &.{.{ .id = "local:Mine/1", .title = "1", .pages = &.{"local/Mine/1/1.png"}, .last_page_read = 1 }} },
        },
        .categories = &.{.{ .id = 1, .name = "Reading", .order = 4 }},
        .sources = &.{.{ .id = 7, .name = "Seven" }},
    };
    const backup = try decode(a, try encodeFile(a, try fromLibrary(a, lib, .{})));
    try std.testing.expectEqual(2, backup.manga.len);
    try std.testing.expectEqual(local_source, backup.manga[1].source);
    try std.testing.expectEqualStrings("Mine", backup.manga[1].url);
    try std.testing.expectEqualStrings("Mine/1", backup.manga[1].chapters[0].url);
    try std.testing.expectEqualStrings("Seven", backup.sources[0].name);
    // Into an empty library: everything comes back.
    const fresh = try restore(a, .{}, backup, .{});
    const m = fresh.library.manga[0];
    try std.testing.expectEqualStrings("7:/m", m.id);
    try std.testing.expectEqualStrings("A, B", m.remote.?.genre.?);
    try std.testing.expectEqual(50, m.date_added);
    try std.testing.expectEqualStrings("mine", m.notes);
    try std.testing.expectEqualStrings("Reading", fresh.library.categories[0].name);
    try std.testing.expectEqual(fresh.library.categories[0].id, m.categories[0]);
    try std.testing.expect(m.chapters[0].read);
    try std.testing.expectEqual(1000, m.chapters[0].read_ms);
    try std.testing.expectEqualStrings("local:Mine/1", fresh.library.manga[1].chapters[0].id);
    // Into a library that moved on: state only gains, notes stay ours.
    var ahead = lib;
    var titles = try a.dupe(library.Manga, lib.manga);
    var chapters = try a.dupe(library.Chapter, titles[0].chapters);
    chapters[0].last_page_read = 9;
    chapters[0].read = false;
    chapters[1].bookmark = true;
    titles[0].chapters = chapters;
    titles[0].notes = "changed";
    ahead.manga = titles;
    const merged = (try restore(a, ahead, backup, .{})).library.manga[0];
    try std.testing.expect(merged.chapters[0].read);
    try std.testing.expectEqual(9, merged.chapters[0].last_page_read);
    try std.testing.expect(merged.chapters[1].bookmark);
    try std.testing.expectEqualStrings("changed", merged.notes);
    try library.validate(std.testing.allocator, (try restore(a, ahead, backup, .{})).library);
}

test "Mihon's own encoding decodes and re-encodes byte for byte" {
    // Written by host/src/test/kotlin/dev/tachi/host/MihonBackupGolden.kt with
    // Mihon's model classes and kotlinx.serialization (gradlew testMihonBackup).
    const golden = @embedFile("testdata/mihon-backup.bin");
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const backup = try decode(a, golden);
    const m = backup.manga[0];
    try std.testing.expectEqual(2499283573021220255, m.source);
    try std.testing.expectEqualStrings("Solo Leveling ☆", m.title);
    try std.testing.expectEqualStrings("Dubu", m.artist.?);
    try std.testing.expect(m.author == null);
    try std.testing.expectEqual(2, m.status);
    try std.testing.expectEqual(1700000000000, m.date_added);
    try std.testing.expectEqual(2, m.chapters.len);
    try std.testing.expectEqualStrings("Group", m.chapters[0].scanlator.?);
    try std.testing.expectEqual(2.5, m.chapters[1].chapter_number);
    try std.testing.expectEqualStrings("{\"k\":1}", m.chapters[1].memo);
    try std.testing.expectEqualSlices(i64, &.{ 0, 2 }, m.categories);
    try std.testing.expectEqual(8.5, m.tracking[0].score);
    try std.testing.expectEqual(105398, m.tracking[0].media_id);
    try std.testing.expect(m.tracking[0].private);
    try std.testing.expectEqual(0x100, m.chapter_flags);
    try std.testing.expectEqual(2, m.viewer_flags.?);
    try std.testing.expectEqual(60000, m.history[0].read_duration);
    try std.testing.expectEqual(1, m.update_strategy);
    try std.testing.expectEqualStrings("Bad", m.excluded_scanlators[0]);
    try std.testing.expect(m.initialized);
    try std.testing.expectEqual(-1, m.next_update);
    try std.testing.expect(!backup.manga[1].favorite);
    try std.testing.expect(backup.manga[1].viewer_flags == null);
    try std.testing.expectEqual(64, backup.categories[0].flags);
    try std.testing.expectEqualStrings("MangaDex", backup.sources[0].name);
    const prefs = backup.preferences;
    try std.testing.expectEqual(9, prefs.len);
    try std.testing.expectEqual(-1, prefs[0].value.int);
    try std.testing.expectEqual(256, prefs[2].value.long);
    try std.testing.expectEqual(1.5, prefs[3].value.float);
    try std.testing.expectEqualStrings("UNREAD_COUNT,DESCENDING", prefs[4].value.string);
    try std.testing.expect(!prefs[5].value.boolean);
    try std.testing.expectEqualStrings("manga_started", prefs[7].value.string_set[1]);
    try std.testing.expectEqual(0, prefs[8].value.string_set.len);
    try std.testing.expectEqualStrings("source_2499283573021220255", backup.source_preferences[0].key);
    try std.testing.expect(backup.source_preferences[0].prefs[0].value.boolean);
    try std.testing.expectEqualStrings("9add655a", backup.extension_stores[0].signing_key);
    try std.testing.expect(!backup.extension_stores[0].legacy.?);
    try std.testing.expect(backup.extension_stores[1].badge_label == null and backup.extension_stores[1].legacy == null);
    try std.testing.expectEqualSlices(u8, golden, try encode(a, backup));
}

test "protobuf reader rejects overflow, truncation and invalid field numbers" {
    const t = std.testing;
    for ([_][]const u8{
        "\x08\xff\xff\xff\xff\xff\xff\xff\xff\xff\x02", // u64 overflow
        "\x08\x80\x80\x80\x80\x80\x80\x80\x80\x80\x80\x00", // eleven bytes
        "\x80", // truncated key
        "\x09\x00", // truncated fixed64
        "\x0d\x00", // truncated fixed32
        "\x0a\x02x", // truncated bytes
        "\x00", // field zero outside legacy messages
        "\x80\x80\x80\x80\x10\x00", // field 2^29
        "\x80\x80\x80\x80\x80\x01\x00", // field 2^32
    }) |bytes| {
        var reader: Reader = .init(bytes);
        try t.expectError(error.InvalidBackup, reader.next());
    }
    var reader: Reader = .init("\x08\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01");
    try t.expectEqual(@as(i64, -1), try (try reader.next()).?.int64());
    try t.expectEqual(@as(?Field, null), try reader.next());
    var legacy: Reader = .init("\x02\x01x");
    try t.expectEqualStrings("x", try (try nextLegacy(&legacy, true)).?.bytes());
}

//! Mihon's library search grammar (mihonapp/mihon 487c313).
const std = @import("std");

/// What a query is matched against: one library title.
pub const Subject = struct {
    title: []const u8 = "",
    author: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    description: ?[]const u8 = null,
    genres: []const []const u8 = &.{},
    source_name: []const u8 = "",
    /// 0 is the local source.
    source_id: i64 = 0,
    notes: []const u8 = "",
    language: []const u8 = "",
    /// Numeric id for `id` comparisons; null makes them false.
    id: ?i64 = null,
    /// Milliseconds since the epoch; null if unknown.
    added: ?i64 = null,
    next_update: ?i64 = null,
    fetch_interval: i32 = 0,
    unread: i64 = 0,
    read: i64 = 0,
    total: i64 = 0,
};

pub const Query = struct {
    root: *const Node,

    /// Whether `subject` matches. `utc_offset_s` turns timestamps into local dates.
    pub fn matches(self: Query, subject: Subject, utc_offset_s: i32) bool {
        return self.root.matches(subject, utc_offset_s);
    }
};

const Field = enum { title, author, artist, description, genre, source, notes, language, source_id };
const Comparison = enum { id, added, fetch_interval, next_update, unread, read, total };
const Operator = enum {
    gte,
    lte,
    gt,
    lt,
    eq,

    fn apply(self: Operator, a: i64, b: i64) bool {
        return switch (self) {
            .gte => a >= b,
            .lte => a <= b,
            .gt => a > b,
            .lt => a < b,
            .eq => a == b,
        };
    }
};

pub const Node = struct {
    negated: bool = false,
    kind: union(enum) {
        empty,
        not: *const Node,
        general: []const u8,
        field: struct { field: Field, value: []const u8 },
        comparison: struct { field: Comparison, op: Operator, value: []const u8 },
        both: struct { left: *const Node, right: *const Node },
        either: struct { left: *const Node, right: *const Node },
    },

    fn matches(self: *const Node, s: Subject, offset: i32) bool {
        const result = switch (self.kind) {
            .empty => true,
            .not => |child| !child.matches(s, offset),
            .general => |v| contains(s.title, v) or optionalContains(s.author, v) or optionalContains(s.artist, v) or
                optionalContains(s.description, v) or genresContain(s.genres, v) or sourceContains(s, v) or contains(s.notes, v),
            .field => |f| fieldMatches(f.field, f.value, s),
            .comparison => |c| comparisonMatches(c.field, c.op, c.value, s, offset),
            .both => |b| b.left.matches(s, offset) and b.right.matches(s, offset),
            .either => |b| b.left.matches(s, offset) or b.right.matches(s, offset),
        };
        return result != self.negated;
    }
};

fn equal(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// ASCII case folding; non-ASCII UTF-8 bytes match literally.
fn contains(text: []const u8, value: []const u8) bool {
    if (value.len > text.len) return false;
    for (0..text.len - value.len + 1) |i| if (equal(text[i..][0..value.len], value)) return true;
    return false;
}

fn optionalContains(text: ?[]const u8, value: []const u8) bool {
    return contains(text orelse return false, value);
}

fn genresContain(genres: []const []const u8, value: []const u8) bool {
    for (genres) |genre| if (contains(genre, value)) return true;
    return false;
}

fn sourceContains(s: Subject, value: []const u8) bool {
    return contains(s.source_name, value) or (equal(value, "local") and s.source_id == 0);
}

fn fieldMatches(field: Field, value: []const u8, s: Subject) bool {
    switch (field) {
        .genre => return if (value.len == 0) s.genres.len == 0 else genresContain(s.genres, value),
        .source => return if (value.len == 0) s.source_name.len == 0 else sourceContains(s, value),
        .source_id => return s.source_id == (integer(i64, value) orelse return false),
        else => {},
    }
    const text: ?[]const u8 = switch (field) {
        .title => s.title,
        .author => s.author,
        .artist => s.artist,
        .description => s.description,
        .notes => s.notes,
        .language => s.language,
        else => unreachable,
    };
    if (value.len == 0) return if (text) |t| t.len == 0 else true;
    return optionalContains(text, value);
}

fn integer(comptime T: type, value: []const u8) ?T {
    if (value.len == 0) return null;
    const start: usize = if (value[0] == '+' or value[0] == '-') 1 else 0;
    if (start == value.len) return null;
    for (value[start..]) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(T, value, 10) catch null;
}

fn comparisonMatches(field: Comparison, op: Operator, value: []const u8, s: Subject, offset: i32) bool {
    const expected = switch (field) {
        .added, .next_update => dateDays(value),
        .fetch_interval => if (integer(i32, value)) |n| @as(i64, n) else null,
        else => integer(i64, value),
    } orelse return false;
    const actual: i64 = switch (field) {
        .id => s.id orelse return false,
        .added, .next_update => blk: {
            const ms = (if (field == .added) s.added else s.next_update) orelse return false;
            break :blk @intCast(@divFloor(@as(i128, ms) + @as(i128, offset) * 1000, 86_400_000));
        },
        // Kotlin's abs(Int.MIN_VALUE) is still Int.MIN_VALUE.
        .fetch_interval => if (s.fetch_interval < 0) -%s.fetch_interval else s.fetch_interval,
        .unread => s.unread,
        .read => s.read,
        .total => s.total,
    };
    return op.apply(actual, expected);
}

/// ISO calendar date to days since 1970-01-01, using Gregorian eras.
fn dateDays(value: []const u8) ?i64 {
    const signed = value.len > 0 and (value[0] == '-' or value[0] == '+');
    const start: usize = if (signed) 1 else 0;
    const end = (std.mem.indexOfScalarPos(u8, value, start, '-') orelse return null);
    if (end - start < 4 or (!signed and end != 4) or value.len != end + 6 or value[end + 3] != '-') return null;
    const year = integer(i32, value[0..end]) orelse return null;
    if (year < -999999999 or year > 999999999 or (value[0] == '+' and year <= 9999)) return null;
    for (value[end + 1 .. end + 3]) |c| if (!std.ascii.isDigit(c)) return null;
    for (value[end + 4 ..]) |c| if (!std.ascii.isDigit(c)) return null;
    const month = integer(i64, value[end + 1 .. end + 3]) orelse return null;
    const day = integer(i64, value[end + 4 ..]) orelse return null;
    if (month < 1 or month > 12) return null;
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const lengths = [_]i64{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day < 1 or day > lengths[@intCast(month - 1)]) return null;
    const y = @as(i64, year) - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = month + @as(i64, if (month > 2) -3 else 9);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    return era * 146097 + yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy - 719468;
}

fn fieldNamed(name: []const u8) ?Field {
    const aliases = .{ .{ "title", Field.title }, .{ "author", Field.author }, .{ "artist", Field.artist }, .{ "description", Field.description }, .{ "desc", Field.description }, .{ "genre", Field.genre }, .{ "tag", Field.genre }, .{ "source", Field.source }, .{ "src", Field.source }, .{ "notes", Field.notes }, .{ "note", Field.notes }, .{ "language", Field.language }, .{ "lang", Field.language }, .{ "source_id", Field.source_id }, .{ "sourceid", Field.source_id }, .{ "src_id", Field.source_id }, .{ "srcid", Field.source_id } };
    inline for (aliases) |a| if (equal(name, a[0])) return a[1];
    return null;
}

fn comparisonNamed(name: []const u8) ?Comparison {
    const aliases = .{ .{ "id", Comparison.id }, .{ "added", Comparison.added }, .{ "fetchinterval", Comparison.fetch_interval }, .{ "fi", Comparison.fetch_interval }, .{ "nextupdate", Comparison.next_update }, .{ "nu", Comparison.next_update }, .{ "unread", Comparison.unread }, .{ "read", Comparison.read }, .{ "total", Comparison.total } };
    inline for (aliases) |a| if (equal(name, a[0])) return a[1];
    return null;
}

const Token = struct {
    kind: enum { end, left, right, not, either, both, general, field, comparison },
    name: []const u8 = "",
    value: []const u8 = "",
    symbol: []const u8 = "",
    op: Operator = .eq,
};

fn separator(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == ',';
}

const Lexer = struct {
    text: []const u8,
    pos: usize = 0,

    fn value(self: *Lexer) ?[]const u8 {
        const start = self.pos;
        if (start == self.text.len or separator(self.text[start]) or self.text[start] == '(' or self.text[start] == ')') return null;
        if (self.text[start] == '"' or self.text[start] == '\'') {
            if (std.mem.indexOfScalarPos(u8, self.text, start + 1, self.text[start])) |end| {
                self.pos = end + 1;
                return self.text[start + 1 .. end];
            }
        }
        while (self.pos < self.text.len and !separator(self.text[self.pos]) and self.text[self.pos] != '(' and self.text[self.pos] != ')') self.pos += 1;
        return self.text[start..self.pos];
    }

    fn next(self: *Lexer) Token {
        while (self.pos < self.text.len and separator(self.text[self.pos])) self.pos += 1;
        const start = self.pos;
        if (start == self.text.len) return .{ .kind = .end };
        const c = self.text[start];
        if (c == '(' or c == ')' or (c == '-' and (start + 1 == self.text.len or !separator(self.text[start + 1])))) {
            self.pos += 1;
            return .{ .kind = if (c == '(') .left else if (c == ')') .right else .not };
        }
        if (std.mem.startsWith(u8, self.text[start..], "||") or std.mem.startsWith(u8, self.text[start..], "&&")) {
            self.pos += 2;
            return .{ .kind = if (c == '|') .either else .both };
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            var end = start + 1;
            while (end < self.text.len and (std.ascii.isAlphanumeric(self.text[end]) or self.text[end] == '_')) end += 1;
            if (end < self.text.len) {
                const marker = self.text[end];
                if (marker == ':' or marker == '>' or marker == '<' or marker == '=') {
                    var op_end = end + 1;
                    if ((marker == '>' or marker == '<') and op_end < self.text.len and self.text[op_end] == '=') op_end += 1;
                    self.pos = op_end;
                    if (self.value()) |v| return .{
                        .kind = if (marker == ':') .field else .comparison,
                        .name = self.text[start..end],
                        .value = v,
                        .symbol = self.text[end..op_end],
                        .op = if (marker == '>') (if (op_end - end == 2) .gte else .gt) else if (marker == '<') (if (op_end - end == 2) .lte else .lt) else .eq,
                    };
                }
            }
        }
        self.pos = start;
        return .{ .kind = .general, .value = self.value().? };
    }
};

const Parser = struct {
    arena: std.mem.Allocator,
    lexer: Lexer,
    token: Token,

    fn advance(self: *Parser) Token {
        const t = self.token;
        self.token = self.lexer.next();
        return t;
    }

    fn node(self: *Parser, n: Node) std.mem.Allocator.Error!*Node {
        const out = try self.arena.create(Node);
        out.* = n;
        return out;
    }

    fn parseOr(self: *Parser) std.mem.Allocator.Error!*Node {
        var left = try self.parseAnd();
        while (self.token.kind == .either) {
            _ = self.advance();
            left = try self.node(.{ .kind = .{ .either = .{ .left = left, .right = try self.parseAnd() } } });
        }
        return left;
    }

    fn parseAnd(self: *Parser) std.mem.Allocator.Error!*Node {
        var left: ?*Node = null;
        while (self.token.kind != .end and self.token.kind != .either and self.token.kind != .right) {
            if (self.token.kind == .both) _ = self.advance();
            const right = try self.term();
            if (right.kind == .empty and !right.negated) continue;
            left = if (left) |l| try self.node(.{ .kind = .{ .both = .{ .left = l, .right = right } } }) else right;
        }
        return left orelse self.node(.{ .kind = .empty });
    }

    fn term(self: *Parser) std.mem.Allocator.Error!*Node {
        var negated = false;
        while (self.token.kind == .not) {
            _ = self.advance();
            negated = !negated;
        }
        if (self.token.kind == .left) {
            _ = self.advance();
            const sub = try self.parseOr();
            if (self.token.kind == .right) _ = self.advance();
            if (negated) return self.node(.{ .kind = .{ .not = sub } });
            return sub;
        }
        const t = self.advance();
        switch (t.kind) {
            .general => return self.node(.{ .negated = negated, .kind = .{ .general = t.value } }),
            .field => if (fieldNamed(t.name)) |f| return self.node(.{ .negated = negated, .kind = .{ .field = .{ .field = f, .value = t.value } } }),
            .comparison => if (comparisonNamed(t.name)) |f| return self.node(.{ .negated = negated, .kind = .{ .comparison = .{ .field = f, .op = t.op, .value = t.value } } }),
            else => return self.node(.{ .kind = .empty }),
        }
        return self.node(.{ .negated = negated, .kind = .{ .general = try std.mem.concat(self.arena, u8, &.{ t.name, t.symbol, t.value }) } });
    }
};

/// Parses `text`; bad syntax is tolerated. The query and its text live in `arena`.
pub fn parse(arena: std.mem.Allocator, text: []const u8) !Query {
    var lexer: Lexer = .{ .text = try arena.dupe(u8, text) };
    const first = lexer.next();
    var parser: Parser = .{ .arena = arena, .lexer = lexer, .token = first };
    return .{ .root = try parser.parseOr() };
}

fn check(text: []const u8, subject: Subject, offset: i32, expected: bool) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const q = try parse(arena.allocator(), text);
    if (q.matches(subject, offset) != expected) {
        std.debug.print("query: {s}\n", .{text});
        return error.TestUnexpectedResult;
    }
}

test "precedence, implicit AND and toggled negation" {
    const s: Subject = .{ .title = "alpha beta" };
    for ([_][]const u8{
        "alpha beta",              "alpha,beta",           "alpha && beta", "missing || alpha beta", "alpha || missing && absent",
        "(alpha || missing) beta", "-(missing || absent)", "--alpha",       "---missing",            "-(-alpha)",
        "alpha -(missing beta)",
    }) |text| try check(text, s, 0, true);
    for ([_][]const u8{ "alpha missing", "alpha && missing || absent", "(alpha || missing) absent", "-(alpha beta)", "---alpha", "--missing" }) |text| try check(text, s, 0, false);
}

test "lexer follows regex alternative order and leaves adjacent operators in words" {
    var lexer: Lexer = .{ .text = "( --title:'a b',fi>=\"3\" || a&&b && c||d - x -" };
    const kinds = [_]@TypeOf(lexer.next().kind){ .left, .not, .not, .field, .comparison, .either, .general, .both, .general, .general, .general, .not, .end };
    for (kinds) |kind| try std.testing.expectEqual(kind, lexer.next().kind);
    try check("a&&b", .{ .title = "a b" }, 0, false);
    try check("a||b", .{ .title = "a||b" }, 0, true);
    try check("||alpha", .{}, 0, true);
    try check("alpha&& beta", .{ .title = "alpha beta" }, 0, false);
    try check("title: alpha", .{ .title = "alpha" }, 0, false);
    try check("read >=3", .{ .read = 4 }, 0, false);
    try check("- alpha", .{ .title = "alpha" }, 0, false);
}

test "quoted values strip delimiters without interpreting escapes" {
    const s: Subject = .{ .title = "Alpha Beta", .author = "Oda Eiichiro", .notes = "a\\b" };
    try check("\"alpha beta\" author:'oda eiichiro'", s, 0, true);
    try check("title:\"ALPHA BETA\"", s, 0, true);
    try check("note:'a\\b'", s, 0, true);
    try check("title:'alpha beta", s, 0, false);
    try check("title:\"alpha\"beta", s, 0, true);
    try check("\"\"", .{}, 0, true);
    try check("-''", .{}, 0, false);
    try check("title:'(alpha,beta)'", .{ .title = "(alpha,beta)" }, 0, true);
}

test "all text fields and aliases, with language and source ID field only" {
    const s: Subject = .{
        .title = "One Piece",
        .author = "Eiichiro Oda",
        .artist = "Artist Name",
        .description = "Pirate adventure",
        .genres = &.{ "Action", "Shounen" },
        .source_name = "Manga Source",
        .source_id = 123,
        .notes = "Remember this",
        .language = "zz",
    };
    for ([_][]const u8{
        "piece",         "oda",        "artist",         "pirate",             "shounen",        "manga source", "remember",
        "TITLE:piece",   "author:oda", "artist:name",    "description:pirate", "desc:adventure", "genre:act",    "tag:shou",
        "source:manga",  "src:source", "notes:remember", "note:this",          "language:ZZ",    "lang:zz",      "source_id:123",
        "sourceid:+123", "src_id:123", "srcid:123",
    }) |text| try check(text, s, 0, true);
    for ([_][]const u8{ "zz", "123", "local", "srcid:12", "srcid:invalid", "language:en", "-author:oda", "genre:romance" }) |text| try check(text, s, 0, false);
    try check("-srcid:invalid", s, 0, true);
    try check("artist", .{ .artist = "Artist" }, 0, true);
    try check("description", .{ .description = "Description" }, 0, true);
    try check("genre", .{ .genres = &.{"Genre"} }, 0, true);
    try check("source", .{ .source_name = "Source" }, 0, true);
    try check("notes", .{ .notes = "Notes" }, 0, true);
}

test "empty fields match only missing or empty values" {
    for ([_][]const u8{ "title:''", "author:''", "artist:\"\"", "desc:''", "genre:''", "src:''", "note:''", "lang:''" }) |text| {
        try check(text, .{}, 0, true);
    }
    try check("author:''", .{ .author = "" }, 0, true);
    try check("-author:''", .{}, 0, false);
    try check("author:''", .{ .author = "Oda" }, 0, false);
    try check("genre:''", .{ .genres = &.{""} }, 0, false);
    try check("source:''", .{ .source_name = "Source" }, 0, false);
    try check("srcid:''", .{}, 0, false);
}

test "unknown fields and comparisons fall back to general text" {
    try check("unknown:'a b'", .{ .title = "unknown:a b" }, 0, true);
    try check("odd>=\"a b\"", .{ .notes = "odd>=a b" }, 0, true);
    try check("title=piece", .{ .title = "title=piece" }, 0, true);
    try check("read:3", .{ .title = "read:3" }, 0, true);
    try check("-unknown:value", .{}, 0, true);
    try check("unknown:value", .{ .title = "value" }, 0, false);
}

test "local source matches general and source queries" {
    try check("LOCAL", .{ .source_id = 0, .source_name = "Disk" }, 0, true);
    try check("src:LoCaL", .{ .source_id = 0, .source_name = "Disk" }, 0, true);
    try check("local", .{ .source_id = 1, .source_name = "Disk" }, 0, false);
    try check("local", .{ .source_id = 1, .source_name = "Local catalog" }, 0, true);
    try check("loc", .{ .source_id = 0, .source_name = "Disk" }, 0, false);
}

test "numeric comparisons use Long counts and absolute Int fetch intervals" {
    const s: Subject = .{ .id = 9223372036854775807, .fetch_interval = -7, .unread = 8, .read = 12, .total = 20 };
    for ([_][]const u8{
        "id=9223372036854775807", "unread>=8", "unread>7", "read<=12", "read<13", "total=20",  "total>=+20",
        "fetchinterval=7",        "fi>=7",     "fi<8",     "fi>6",     "fi<=7",   "-unread=7", "unread='8'",
        "READ=12",
    }) |text| try check(text, s, 0, true);
    for ([_][]const u8{ "unread>8", "read<12", "total=19", "fi=-7", "id=9223372036854775808", "fi=2147483648", "unread=1_0", "read=0xC", "total=''", "total=nope" }) |text| try check(text, s, 0, false);
    try check("id=0", .{}, 0, false);
    try check("-id=0", .{}, 0, true);
    try check("-fi=2147483648", s, 0, true);
    try check("fi=-2147483648", .{ .fetch_interval = std.math.minInt(i32) }, 0, true);
    try check("srcid:-9223372036854775808", .{ .source_id = std.math.minInt(i64) }, 0, true);
}

test "calendar dates use local days, floor negative timestamps and validate leap years" {
    const s: Subject = .{ .added = 1706659200000, .next_update = 1709164800000 };
    for ([_][]const u8{ "added=2024-01-31", "added>=2024-01-31", "added>2024-01-30", "added<2024-02-01", "added<=2024-01-31", "nextupdate=2024-02-29", "nu>2024-02-28", "nu='2024-02-29'" }) |text| try check(text, s, 0, true);
    try check("added=2024-01-30", s, -1, true);
    try check("nu=2024-03-01", .{ .next_update = 1709251199999 }, 1, true);
    try check("added=1969-12-31", .{ .added = -1 }, 0, true);
    try check("added=1970-01-01", .{ .added = -1 }, 1, true);
    for ([_][]const u8{ "added=2023-02-29", "added=1900-02-29", "added=2024-04-31", "added=2024-00-01", "added=2024-13-01", "added=2024-01-00", "added=2024-1-31", "added=2024-01-31x", "added=nope", "added=''" }) |text| {
        try check(text, s, 0, false);
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const negated = try std.mem.concat(arena.allocator(), u8, &.{ "-", text });
        try check(negated, s, 0, true);
    }
    try check("added=2024-01-31", .{}, 0, false);
    try check("-nu=2024-01-31", .{}, 0, true);
    try std.testing.expectEqual(@as(?i64, 0), dateDays("1970-01-01"));
    try std.testing.expect(dateDays("2000-02-29") != null);
    try std.testing.expect(dateDays("0000-02-29") != null);
    try std.testing.expect(dateDays("-0001-01-01") != null);
    try std.testing.expect(dateDays("+10000-01-01") != null);
    try check("added>0000-01-01", .{ .added = std.math.maxInt(i64) }, std.math.maxInt(i32), true);
    try check("added<0000-01-01", .{ .added = std.math.minInt(i64) }, std.math.minInt(i32), true);
}

test "empty and malformed terms retain Mihon's forgiving parser behavior" {
    for ([_][]const u8{ "", " , \t\r\n", "()", "(", ") ignored", "&&", "-", "-&&", "alpha ||", "|| alpha", "alpha &&", "alpha && &&", "(alpha", "alpha ) missing" }) |text| try check(text, .{ .title = "alpha" }, 0, true);
    try check("-()", .{}, 0, false);
    try check("-() alpha", .{ .title = "alpha" }, 0, false);
    try check("missing || ()", .{}, 0, true);
    try check("missing && ()", .{}, 0, false);
    try check("missing && || alpha", .{ .title = "alpha" }, 0, false);
}

test "query owns its input and only allocation errors escape parsing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var input = [_]u8{ 'a', 'l', 'p', 'h', 'a' };
    const q = try parse(arena.allocator(), &input);
    @memset(&input, 'x');
    try std.testing.expect(q.matches(.{ .title = "alpha" }, 0));
    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            var a: std.heap.ArenaAllocator = .init(gpa);
            defer a.deinit();
            _ = try parse(a.allocator(), "-(author:'name' || unknown:'a b') total>=3 && (genre:action missing)");
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

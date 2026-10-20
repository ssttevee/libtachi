//! ComicInfo metadata and the small XML vocabulary used by local EPUBs.
//! External entities and DTDs are never expanded.
const std = @import("std");
const library = @import("library.zig");
extern fn tachi_local_date(year: c_int, month: c_int, day: c_int) i64;
extern fn tachi_date_parts(milliseconds: i64, parts: *[3]c_int) c_int;

pub const Tag = struct {
    name: []const u8,
    attributes: []const u8,
    content: []const u8,
    cdata: bool = false,

    pub fn attr(self: Tag, a: std.mem.Allocator, key: []const u8) !?[]const u8 {
        var rest = self.attributes;
        while (rest.len > 0) {
            rest = std.mem.trimStart(u8, rest, " \t\r\n/");
            const end = std.mem.indexOfAny(u8, rest, "= \t\r\n") orelse return null;
            const name = rest[0..end];
            rest = std.mem.trimStart(u8, rest[end..], " \t\r\n");
            if (rest.len == 0 or rest[0] != '=') return null;
            rest = std.mem.trimStart(u8, rest[1..], " \t\r\n");
            if (rest.len == 0 or (rest[0] != '\'' and rest[0] != '"')) return null;
            const quote = rest[0];
            rest = rest[1..];
            const close = std.mem.indexOfScalar(u8, rest, quote) orelse return null;
            if (std.mem.eql(u8, name, key)) return try decode(a, rest[0..close]);
            rest = rest[close + 1 ..];
        }
        return null;
    }
};

pub const Tags = struct {
    rest: []const u8,
    pub fn next(self: *Tags) ?Tag {
        while (std.mem.indexOfScalar(u8, self.rest, '<')) |start| {
            self.rest = self.rest[start + 1 ..];
            if (std.mem.startsWith(u8, self.rest, "!--")) {
                const end = std.mem.indexOf(u8, self.rest, "-->") orelse return null;
                self.rest = self.rest[end + 3 ..];
                continue;
            }
            var end: usize = 0;
            var quote: u8 = 0;
            while (end < self.rest.len) : (end += 1) {
                const ch = self.rest[end];
                if (quote != 0) {
                    if (ch == quote) quote = 0;
                } else if (ch == '\'' or ch == '"') {
                    quote = ch;
                } else if (ch == '>') break;
            }
            if (end == self.rest.len) return null;
            const raw = self.rest[0..end];
            self.rest = self.rest[end + 1 ..];
            if (raw.len == 0 or raw[0] == '/' or raw[0] == '?' or raw[0] == '!') continue;
            const name_end = std.mem.indexOfAny(u8, raw, " \r\n\t/") orelse raw.len;
            const full_name = raw[0..name_end];
            const name = full_name[if (std.mem.lastIndexOfScalar(u8, full_name, ':')) |i| i + 1 else 0..];
            if (std.mem.startsWith(u8, self.rest, "<![CDATA[")) {
                const close = std.mem.indexOf(u8, self.rest, "]]>") orelse return null;
                return .{ .name = name, .attributes = raw[name_end..], .content = self.rest[9..close], .cdata = true };
            }
            return .{ .name = name, .attributes = raw[name_end..], .content = self.rest[0 .. std.mem.indexOfScalar(u8, self.rest, '<') orelse self.rest.len] };
        }
        return null;
    }
};

pub fn decode(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    return decodeInner(a, text) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => return err,
    };
}

const entities = std.StaticStringMap(u21).initComptime(.{
    .{ "amp", '&' },
    .{ "lt", '<' },
    .{ "gt", '>' },
    .{ "quot", '"' },
    .{ "apos", '\'' },
});

fn decodeInner(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            if (std.mem.indexOfScalarPos(u8, text, i, ';')) |end| {
                const entity = text[i + 1 .. end];
                var cp = entities.get(entity);
                if (entity.len > 1 and entity[0] == '#') cp = std.fmt.parseInt(u21, entity[if (entity.len > 2 and entity[1] == 'x') @as(usize, 2) else 1..], if (entity.len > 2 and entity[1] == 'x') 16 else 10) catch null;
                if (cp) |code| {
                    var bytes: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(code, &bytes) catch return error.InvalidXmlEntity;
                    try out.writer.writeAll(bytes[0..n]);
                    i = end + 1;
                    continue;
                }
            }
        }
        try out.writer.writeByte(text[i]);
        i += 1;
    }
    return out.toOwnedSlice();
}

pub fn value(a: std.mem.Allocator, xml: []const u8, name: []const u8) !?[]const u8 {
    var tags: Tags = .{ .rest = xml };
    while (tags.next()) |t| if (std.mem.eql(u8, t.name, name)) {
        if (t.cdata) return try a.dupe(u8, t.content);
        return try decode(a, std.mem.trim(u8, t.content, " \t\r\n"));
    };
    return null;
}

pub const statuses = [_][]const u8{ "Unknown", "Ongoing", "Completed", "Licensed", "Publishing finished", "Cancelled", "On hiatus" };

pub fn manga(a: std.mem.Allocator, xml: []const u8, m: *library.Manga) !void {
    if (try value(a, xml, "Series")) |v| if (v.len > 0) {
        m.title = v;
    };
    if (try value(a, xml, "Writer")) |v| m.author = v;
    if (try value(a, xml, "Summary")) |v| m.description = v;
    if (try value(a, xml, "Web")) |v| m.web = v;
    for ([_][]const u8{ "Penciller", "Inker", "Colorist", "Letterer", "CoverArtist" }) |key| {
        if (try value(a, xml, key)) |v| m.artist = try joinedUnique(a, m.artist, v);
    }
    for ([_][]const u8{ "Genre", "Tags", "Categories" }) |key| {
        if (try value(a, xml, key)) |v| m.genre = try joinedUnique(a, m.genre, v);
    }
    const status = (try value(a, xml, "PublishingStatusTachiyomi")) orelse (try value(a, xml, "PublishingStatus")) orelse "Unknown";
    m.publishing_status = 0;
    for (statuses, 0..) |s, i| if (std.mem.eql(u8, s, status)) {
        m.publishing_status = @intCast(i);
        break;
    };
}

fn joinedUnique(a: std.mem.Allocator, old: []const u8, text: []const u8) ![]const u8 {
    var result = old;
    var parts = std.mem.splitSequence(u8, text, ", ");
    while (parts.next()) |part| {
        const v = std.mem.trim(u8, part, " \r\n\t");
        var existing = std.mem.splitSequence(u8, result, ", ");
        const found = while (existing.next()) |e| {
            if (std.mem.eql(u8, v, e)) break true;
        } else false;
        if (!found and v.len > 0) result = if (result.len == 0) v else try std.fmt.allocPrint(a, "{s}, {s}", .{ result, v });
    }
    return result;
}

fn integer(a: std.mem.Allocator, xml: []const u8, name: []const u8) !?i32 {
    return std.fmt.parseInt(i32, (try value(a, xml, name)) orelse return null, 10) catch null;
}

pub fn chapter(a: std.mem.Allocator, xml: []const u8, ch: *library.Chapter) !void {
    if (try value(a, xml, "Title")) |v| ch.title = v;
    if (try value(a, xml, "Number")) |v| ch.number = std.fmt.parseFloat(f64, v) catch ch.number;
    ch.scanlator = (try value(a, xml, "Translator")) orelse (try value(a, xml, "ScanInformation")) orelse ch.scanlator;
    const year = (try integer(a, xml, "Year")) orelse return;
    if (year <= 0 or year > 9999) return;
    const month = std.math.clamp((try integer(a, xml, "Month")) orelse 1, 1, 12);
    const day = std.math.clamp((try integer(a, xml, "Day")) orelse 1, 1, 31);
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const days = [_]i32{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day > days[@intCast(month - 1)]) return;
    ch.date_upload = tachi_local_date(year, month, day);
}

pub fn field(w: *std.Io.Writer, name: []const u8, text: []const u8) !void {
    try w.print("<{s}>", .{name});
    for (text) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&apos;"),
        else => try w.writeByte(ch),
    };
    try w.print("</{s}>", .{name});
}

pub fn dateFields(w: *std.Io.Writer, milliseconds: i64) !void {
    if (milliseconds == 0) return;
    var parts: [3]c_int = undefined;
    if (tachi_date_parts(milliseconds, &parts) == 0) return;
    try w.print("<Year>{d}</Year><Month>{d}</Month><Day>{d}</Day>", .{ parts[0], parts[1], parts[2] });
}

test "XML decoding releases buffers on invalid entities and allocation failure" {
    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            const decoded = try decode(gpa, "text &amp;&lt;&gt;&quot;&apos; &#65; &#x1f600; &unknown; &AMP;");
            defer gpa.free(decoded);
            try std.testing.expectEqualStrings("text &<>\"' A 😀 &unknown; &AMP;", decoded);
            _ = decode(gpa, "allocated prefix &#xD800;") catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.InvalidXmlEntity => return,
                else => return err,
            };
            return error.TestUnexpectedResult;
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

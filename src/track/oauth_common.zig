//! Wire helpers shared by AniList, MyAnimeList and Kitsu.
const std = @import("std");
const driver = @import("driver.zig");
const tracking = @import("../tracking.zig");
const Http = @import("http.zig").Http;
pub const Value = std.json.Value;

pub fn field(v: Value, key: []const u8) Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn string(v: Value) []const u8 {
    return if (v == .string) v.string else "";
}
pub fn number(v: Value) f64 {
    return switch (v) {
        .integer => @floatFromInt(v.integer),
        .float => v.float,
        .number_string, .string => |text| std.fmt.parseFloat(f64, text) catch 0,
        else => 0,
    };
}
pub fn integer(v: Value) i64 {
    return switch (v) {
        .integer => |value| value,
        .number_string, .string => |text| std.fmt.parseInt(i64, text, 10) catch std.math.lossyCast(i64, number(v)),
        else => std.math.lossyCast(i64, number(v)),
    };
}
pub fn boolean(v: Value) bool {
    return v == .bool and v.bool;
}
pub fn array(v: Value) []const Value {
    return if (v == .array) v.array.items else &.{};
}
pub fn eq(v: Value, text: []const u8) bool {
    return std.mem.eql(u8, string(v), text);
}
pub fn json(ctx: *driver.Context, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(ctx.arena, value, .{});
}
pub fn now(ctx: *driver.Context) i64 {
    return std.Io.Clock.real.now(ctx.io).toMilliseconds();
}
pub fn ok(response: Http.Response) !void {
    if (!response.ok()) return error.TrackerRequestFailed;
}
pub fn send(ctx: *driver.Context, method: std.http.Method, url: []const u8, body: Http.Body) !Http.Response {
    if (!ctx.credential.loggedIn()) return error.NotAuthenticated;
    if (ctx.credential.auth_expired) return error.AuthenticationExpired;
    var headers: std.ArrayList(std.http.Header) = .empty;
    try headers.append(ctx.arena, .{ .name = "Authorization", .value = try std.fmt.allocPrint(ctx.arena, "Bearer {s}", .{ctx.credential.password}) });
    if (ctx.tracker_id == 3) try headers.appendSlice(ctx.arena, &.{ .{ .name = "Accept", .value = "application/vnd.api+json" }, .{ .name = "Content-Type", .value = "application/vnd.api+json" } });
    return ctx.http.send(ctx.arena, method, url, headers.items, body);
}
pub fn graphql(ctx: *driver.Context, url: []const u8, query: []const u8, variables: anytype) !Value {
    const response = try send(ctx, .POST, url, .{ .json = try json(ctx, .{ .query = query, .variables = variables }) });
    try ok(response);
    const root = try response.json(Value, ctx.arena);
    const data = field(root, "data");
    if (data == .null or array(field(root, "errors")).len > 0) return error.GraphqlResponseErrors;
    return data;
}
pub const OAuth = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    expires_in: i64 = 0,
    created_at: i64 = 0,
};
pub const mal_client = "c46c9e24640a64dad5be5ca7a1a53a0f";
pub const kitsu_client = "dd031b32d2f56c990b1425efe6c42ad847e7fe3ab46bf1299f05ecd856bdb7dd";
pub const kitsu_secret = "54d7307928f63414defd96399fc31ba847961ceaecef3a5fd93144e960c0e151";
pub fn tokenUrl(ctx: *driver.Context) ![]const u8 {
    const default = if (ctx.tracker_id == 1) "https://api.myanimelist.net/v2" else "https://kitsu.app";
    if (!std.mem.eql(u8, ctx.base_url, default)) return std.mem.concat(ctx.arena, u8, &.{ ctx.base_url, if (ctx.tracker_id == 1) "/v1/oauth2/token" else "/api/oauth/token" });
    return if (ctx.tracker_id == 1) "https://myanimelist.net/v1/oauth2/token" else "https://kitsu.app/api/oauth/token";
}
pub fn saveToken(ctx: *driver.Context, response: Http.Response) !void {
    try ok(response);
    var token = try response.json(OAuth, ctx.arena);
    if (token.access_token.len == 0) return error.InvalidTrackerResponse;
    if (token.created_at == 0) token.created_at = @divTrunc(now(ctx), 1000);
    ctx.credential.password = token.access_token;
    ctx.credential.token = try json(ctx, token);
    ctx.credential.auth_expired = false;
}
/// Refresh before the request, with Mihon's one-minute/one-hour margins.
pub fn prepare(ctx: *driver.Context) !bool {
    if (!ctx.credential.loggedIn()) return error.NotAuthenticated;
    if (ctx.credential.auth_expired) return error.AuthenticationExpired;
    const token = std.json.parseFromSliceLeaky(OAuth, ctx.arena, ctx.credential.token, .{ .ignore_unknown_fields = true }) catch return error.NotAuthenticated;
    const margin: i64 = if (ctx.tracker_id == 1) 60 else 3600;
    if (@divTrunc(now(ctx), 1000) + margin <= token.created_at + token.expires_in) return false;
    const refresh = token.refresh_token orelse return error.AuthenticationExpired;
    var fields: std.ArrayList([2][]const u8) = .empty;
    try fields.appendSlice(ctx.arena, &.{ .{ "grant_type", "refresh_token" }, .{ "refresh_token", refresh }, .{ "client_id", if (ctx.tracker_id == 1) mal_client else kitsu_client } });
    if (ctx.tracker_id == 3) try fields.append(ctx.arena, .{ "client_secret", kitsu_secret });
    const headers: []const std.http.Header = if (ctx.tracker_id == 1) &.{.{ .name = "Authorization", .value = try std.fmt.allocPrint(ctx.arena, "Bearer {s}", .{token.access_token}) }} else &.{};
    const response = ctx.http.send(ctx.arena, .POST, try tokenUrl(ctx), headers, .{ .form = try Http.form(ctx.arena, fields.items) }) catch |err| {
        if (ctx.tracker_id == 3 and err == error.AuthenticationExpired) return false;
        return err;
    };
    if (ctx.tracker_id == 3 and !response.ok()) return false;
    try saveToken(ctx, response);
    return true;
}
pub fn personal(track: tracking.Track, remote: tracking.Track, copy_private: bool) tracking.Track {
    var out = track;
    out.status = remote.status;
    out.score = remote.score;
    out.last_chapter_read = remote.last_chapter_read;
    out.started = remote.started;
    out.finished = remote.finished;
    if (copy_private) out.private = remote.private;
    return out;
}
extern fn tachi_local_date(c_int, c_int, c_int) i64;
extern fn tachi_date_parts(i64, *[3]c_int) c_int;
pub const Fuzzy = struct { year: ?i32 = null, month: ?i32 = null, day: ?i32 = null };
pub fn fuzzy(ms: i64) Fuzzy {
    if (ms == 0) return .{};
    var parts: [3]c_int = undefined;
    if (tachi_date_parts(ms, &parts) == 0) return .{};
    return .{ .year = parts[0], .month = parts[1], .day = parts[2] };
}
pub fn fuzzyMs(v: Value) i64 {
    const y = integer(field(v, "year"));
    const m = integer(field(v, "month"));
    const d = integer(field(v, "day"));
    if (y == 0 or m == 0 or d == 0) return 0;
    return tachi_local_date(@intCast(y), @intCast(m), @intCast(d));
}
pub fn date(ctx: *driver.Context, ms: i64) ![]const u8 {
    if (ms == 0) return "";
    const f = fuzzy(ms);
    return std.fmt.allocPrint(ctx.arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(f.year orelse return error.InvalidDate)), @as(u32, @intCast(f.month.?)), @as(u32, @intCast(f.day.?)) });
}
pub fn dateMs(text: []const u8) !i64 {
    if (text.len == 0) return 0;
    if (text.len != 4 and text.len != 7 and text.len != 10) return error.InvalidDate;
    return tachi_local_date(try std.fmt.parseInt(c_int, text[0..4], 10), if (text.len >= 7) try std.fmt.parseInt(c_int, text[5..7], 10) else 1, if (text.len == 10) try std.fmt.parseInt(c_int, text[8..10], 10) else 1);
}
/// Kitsu instants carry their own offset; calendar-only providers use local time.
pub fn instantMs(text: []const u8) !i64 {
    if (text.len == 0) return 0;
    if (text.len < 20) return error.InvalidDate;
    const y = try std.fmt.parseInt(i64, text[0..4], 10);
    const m = try std.fmt.parseInt(u8, text[5..7], 10);
    const d = try std.fmt.parseInt(u8, text[8..10], 10);
    const h = try std.fmt.parseInt(i64, text[11..13], 10);
    const min = try std.fmt.parseInt(i64, text[14..16], 10);
    const sec = try std.fmt.parseInt(i64, text[17..19], 10);
    var ms = (@import("../views.zig").daysFromCivil(.{ .year = y, .month = m, .day = d }) * 86400 + h * 3600 + min * 60 + sec) * 1000;
    var i: usize = 19;
    if (text[i] == '.') {
        i += 1;
        var scale: i64 = 100;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            ms += (text[i] - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
    }
    if (i >= text.len) return error.InvalidDate;
    if (text[i] == '+' or text[i] == '-') {
        if (text.len < i + 6) return error.InvalidDate;
        const offset = ((try std.fmt.parseInt(i64, text[i + 1 .. i + 3], 10)) * 60 + try std.fmt.parseInt(i64, text[i + 4 .. i + 6], 10)) * 60000;
        ms += if (text[i] == '+') -offset else offset;
    } else if (text[i] != 'Z') return error.InvalidDate;
    return ms;
}
pub fn instant(ctx: *driver.Context, ms: i64) !?[]const u8 {
    if (ms <= 0) return null;
    const civil = @import("../views.zig").civilFromDays(@divFloor(ms, 86400000));
    const seconds = @divFloor(@mod(ms, 86400000), 1000);
    return try std.fmt.allocPrint(ctx.arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ @as(u32, @intCast(civil.year)), civil.month, civil.day, @as(u32, @intCast(@divTrunc(seconds, 3600))), @as(u32, @intCast(@divTrunc(@mod(seconds, 3600), 60))), @as(u32, @intCast(@mod(seconds, 60))), @as(u32, @intCast(@mod(ms, 1000))) });
}
/// Plain text from AniList's HTML descriptions, including paragraph breaks.
pub fn html(ctx: *driver.Context, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '<') {
            if (std.mem.indexOfScalarPos(u8, text, i, '>')) |end| {
                var tag = std.mem.trim(u8, text[i + 1 .. end], " /\t\r\n");
                tag = tag[0 .. std.mem.indexOfAny(u8, tag, " /\t\r\n") orelse tag.len];
                if (std.ascii.eqlIgnoreCase(tag, "br")) {
                    try out.append(ctx.arena, '\n');
                } else {
                    const block = for ([_][]const u8{ "p", "div", "blockquote", "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6" }) |name| {
                        if (std.ascii.eqlIgnoreCase(tag, name)) break true;
                    } else false;
                    if (block and out.items.len > 0) {
                        var trailing: usize = 0;
                        while (trailing < out.items.len and out.items[out.items.len - 1 - trailing] == '\n') : (trailing += 1) {}
                        while (trailing < 2) : (trailing += 1) try out.append(ctx.arena, '\n');
                    }
                }
                i = end + 1;
                continue;
            }
        }
        if (text[i] == '&') {
            if (std.mem.indexOfScalarPos(u8, text, i, ';')) |end| {
                const entity = text[i + 1 .. end];
                var cp = @import("html_entities.zig").entities.get(entity);
                if (entity.len > 1 and entity[0] == '#') {
                    const hex = entity.len > 2 and (entity[1] == 'x' or entity[1] == 'X');
                    cp = std.fmt.parseInt(u21, entity[if (hex) @as(usize, 2) else 1..], if (hex) 16 else 10) catch null;
                }
                if (cp) |value| {
                    var bytes: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(value, &bytes) catch 0;
                    if (len > 0) {
                        try out.appendSlice(ctx.arena, bytes[0..len]);
                        i = end + 1;
                        continue;
                    }
                }
            }
        }
        if (text[i] == ' ' or text[i] == '\n' or text[i] == '\t' or text[i] == '\r') {
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ' and out.items[out.items.len - 1] != '\n') try out.append(ctx.arena, ' ');
        } else try out.append(ctx.arena, text[i]);
        i += 1;
    }
    return out.items;
}

test "JSON integer conversion preserves IDs and handles floating-point limits" {
    const t = std.testing;
    const large_id: i64 = 9_007_199_254_740_993;
    try t.expectEqual(large_id, integer(.{ .integer = large_id }));
    try t.expectEqual(large_id, integer(.{ .string = "9007199254740993" }));
    try t.expectEqual(std.math.maxInt(i64), integer(.{ .number_string = "9223372036854775807" }));
    try t.expectEqual(std.math.minInt(i64), integer(.{ .integer = std.math.minInt(i64) }));
    try t.expectEqual(@as(i64, -3), integer(.{ .float = -3.9 }));
    try t.expectEqual(@as(i64, 12), integer(.{ .string = "12.9" }));
    try t.expectEqual(@as(i64, 0), integer(.{ .float = std.math.nan(f64) }));
    try t.expectEqual(std.math.maxInt(i64), integer(.{ .float = std.math.inf(f64) }));
    try t.expectEqual(std.math.minInt(i64), integer(.{ .float = -std.math.inf(f64) }));
    try t.expectEqual(@as(i64, 0), integer(.{ .string = "invalid" }));
}

//! Kavita progress using the extension's APIURL and APIKEY settings.
const std = @import("std");
const driver = @import("driver.zig");
const tracking = @import("../tracking.zig");
const Http = @import("http.zig").Http;
const enhanced = @import("enhanced.zig");
pub const default_base_url = "";

pub fn call(ctx: *driver.Context, op: tracking.Operation) !tracking.Reply {
    return switch (op) {
        .login_url => error.PasswordLogin,
        .login => enhanced.login(8),
        .search => |url| .{ .matches = try match(ctx, url) },
        .bind => |b| .{ .track = b.track },
        .refresh => |t| blk: {
            const session = try Session.init(ctx, t.url);
            break :blk .{ .track = enhanced.personal(t, (try session.fetch(ctx, t.url)).track) };
        },
        .update => |u| blk: {
            if (!std.math.isFinite(u.track.last_chapter_read) or u.track.last_chapter_read < 0) return error.InvalidProgress;
            const session = try Session.init(ctx, u.track.url);
            const path = try std.fmt.allocPrint(ctx.arena, "/Tachiyomi/mark-chapter-until-as-read?seriesId={d}&chapterNumber={d}", .{ try enhanced.lastId(u.track.url), u.track.last_chapter_read });
            try enhanced.expectOk(try session.send(ctx, .POST, try std.mem.concat(ctx.arena, u8, &.{ session.base, path }), .{ .json = "{}" }));
            break :blk .{ .track = (try session.fetch(ctx, u.track.url)).track };
        },
        .delete => error.UnsupportedDelete,
    };
}

pub fn match(ctx: *driver.Context, url: []const u8) ![]const tracking.Search {
    const session = try Session.init(ctx, url);
    const out = try ctx.arena.alloc(tracking.Search, 1);
    out[0] = try session.fetch(ctx, url);
    return out;
}

const Session = struct {
    base: []const u8,
    authorization: []const u8,

    fn init(ctx: *driver.Context, url: []const u8) !Session {
        const api = std.mem.indexOf(u8, url, "/api/") orelse return error.UnsupportedSearch;
        _ = try enhanced.lastId(url);
        const base = url[0 .. api + 4];
        const prefs = try enhanced.settings(ctx, url, "APIURL");
        if (!std.mem.eql(u8, base, enhanced.trim(enhanced.string(prefs, "APIURL")))) return error.SourceNotConfigured;
        const key = enhanced.string(prefs, "APIKEY");
        if (key.len == 0) return error.SourceNotConfigured;
        const query = try Http.form(ctx.arena, &.{ .{ "apiKey", key }, .{ "pluginName", "Tachiyomi-Kavita" } });
        const auth_url = try std.fmt.allocPrint(ctx.arena, "{s}/Plugin/authenticate?{s}", .{ base, query });
        const response = try ctx.http.sendPrivate(ctx.arena, .POST, auth_url, &.{}, .{ .json = "{}" });
        try enhanced.expectOk(response);
        const auth = try response.json(struct { token: []const u8 }, ctx.arena);
        if (auth.token.len == 0) return error.AuthenticationExpired;
        return .{ .base = base, .authorization = try std.mem.concat(ctx.arena, u8, &.{ "Bearer ", auth.token }) };
    }

    fn send(self: Session, ctx: *driver.Context, method: std.http.Method, url: []const u8, body: Http.Body) !Http.Response {
        return ctx.http.sendPrivate(ctx.arena, method, url, &.{.{ .name = "Authorization", .value = self.authorization }}, body);
    }

    fn fetch(self: Session, ctx: *driver.Context, url: []const u8) !tracking.Search {
        const response = try self.send(ctx, .GET, url, .none);
        try enhanced.expectOk(response);
        const item = try response.json(struct { name: []const u8, thumbnailUrl: ?[]const u8 = null, pages: i32, pagesRead: i32 }, ctx.arena);
        const id = try enhanced.lastId(url);
        const volumes_response = try self.send(ctx, .GET, try std.fmt.allocPrint(ctx.arena, "{s}/Series/volumes?seriesId={d}", .{ self.base, id }), .none);
        try enhanced.expectOk(volumes_response);
        const Volume = struct { chapters: []const struct { number: []const u8 } = &.{} };
        const volumes = try volumes_response.json([]const Volume, ctx.arena);
        var volume_number: i32 = 0;
        var max_chapter: i32 = 0;
        for (volumes) |volume| {
            var max: f64 = -std.math.inf(f64);
            for (volume.chapters) |chapter| max = @max(max, try number(ctx, chapter.number));
            if (max == 0) {
                volume_number += 1;
            } else if (std.math.isFinite(max)) {
                if (max > std.math.maxInt(i32) or max < std.math.minInt(i32)) return error.InvalidTrackerResponse;
                max_chapter = @max(max_chapter, @as(i32, @intFromFloat(max)));
            }
        }
        const latest = try self.send(ctx, .GET, try std.fmt.allocPrint(ctx.arena, "{s}/Tachiyomi/latest-chapter?seriesId={d}", .{ self.base, id }), .none);
        try enhanced.expectOk(latest);
        const progress = if (latest.status == .no_content) 0 else try number(ctx, (try latest.json(struct { number: []const u8 }, ctx.arena)).number);
        return .{ .track = .{ .tracker_id = 8, .title = item.name, .url = url, .total_chapters = @max(volume_number, max_chapter), .last_chapter_read = progress, .status = if (item.pagesRead == item.pages) 3 else if (item.pagesRead == 0) 1 else 2 }, .cover_url = item.thumbnailUrl orelse "null" };
    }
};

fn number(ctx: *driver.Context, value: []const u8) !f64 {
    const normalized = try std.mem.replaceOwned(u8, ctx.arena, value, ",", ".");
    const n = std.fmt.parseFloat(f64, normalized) catch return error.InvalidTrackerResponse;
    if (!std.math.isFinite(n)) return error.InvalidTrackerResponse;
    return n;
}

test "Kavita authenticates with API prefs, maps volumes, updates and refreshes" {
    const test_http = @import("testing_enhanced.zig");
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const item = "{\"name\":\"Kavita series\",\"pages\":100,\"pagesRead\":30,\"thumbnailUrl\":\"cover\"}";
    const volumes = "[{\"chapters\":[{\"number\":\"0\"}]},{\"chapters\":[{\"number\":\"0\"}]},{\"chapters\":[{\"number\":\"7.9\"},{\"number\":\"3\"}]}]";
    var fixture = try test_http.Fixture.init(&.{
        try test_http.ok(a, "{\"token\":\"jwt\"}"),                                  try test_http.ok(a, item),                                                     try test_http.ok(a, volumes),                                          try test_http.ok(a, "{\"number\":\"3,5\"}"),
        try test_http.ok(a, "{\"token\":\"jwt\"}"),                                  try test_http.ok(a, "{}"),                                                     try test_http.ok(a, item),                                             try test_http.ok(a, volumes),
        try test_http.ok(a, "{\"number\":\"3,5\"}"),                                 try test_http.ok(a, "{\"token\":\"jwt\"}"),                                    try test_http.ok(a, "{\"name\":\"New\",\"pages\":0,\"pagesRead\":0}"), try test_http.ok(a, "[{\"chapters\":[{\"number\":\"0\"}]},{\"chapters\":[{\"number\":\"0\"}]}]"),
        "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    });
    defer fixture.deinit();
    fixture.expected = &.{
        &.{ "POST /api/Plugin/authenticate?apiKey=a%26b&pluginName=Tachiyomi-Kavita ", "{}" },
        &.{ "GET /api/Series/7 ", "Authorization: Bearer jwt" },
        &.{"GET /api/Series/volumes?seriesId=7 "},
        &.{"GET /api/Tachiyomi/latest-chapter?seriesId=7 "},
        &.{},
        &.{ "POST /api/Tachiyomi/mark-chapter-until-as-read?seriesId=7&chapterNumber=3.5 ", "{}" },
    };
    try fixture.start();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const api = try fixture.url(a, "/api");
    const host = try test_http.prefs(a, tmp.dir, 777, .{ .APIURL = .{ .t = "s", .v = api }, .APIKEY = .{ .t = "s", .v = "a&b" } });
    var http: Http = .{ .gpa = t.allocator, .io = t.io };
    defer http.deinit();
    var ctx = test_http.context(a, &http, 8, host);
    try test_http.common(&ctx, @This());
    const track = (try call(&ctx, .{ .search = try fixture.url(a, "/api/Series/7") })).matches[0].track;
    try t.expectEqual(@as(i32, 7), track.total_chapters);
    try t.expectEqual(@as(f64, 3.5), track.last_chapter_read);
    try t.expectEqual(@as(i32, 2), track.status);
    _ = try call(&ctx, .{ .update = .{ .track = track } });
    const fresh = (try call(&ctx, .{ .refresh = track })).track.?;
    try t.expectEqual(@as(f64, 0), fresh.last_chapter_read);
    try t.expectEqual(@as(i32, 2), fresh.total_chapters);
    try t.expectEqual(@as(i32, 3), fresh.status);
    try t.expectEqualStrings("Kavita series", fresh.title);
    try t.expectError(error.AuthenticationExpired, call(&ctx, .{ .refresh = track }));
    try fixture.finish();
}

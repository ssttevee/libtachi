//! Komga series and readlist progress, authenticated with extension settings.
const std = @import("std");
const driver = @import("driver.zig");
const tracking = @import("../tracking.zig");
const Http = @import("http.zig").Http;
const enhanced = @import("enhanced.zig");
pub const default_base_url = "";

pub fn call(ctx: *driver.Context, op: tracking.Operation) !tracking.Reply {
    return switch (op) {
        .login_url => error.PasswordLogin,
        .login => enhanced.login(6),
        // Enhanced search is URL matching only; textual search is unsupported.
        .search => |url| .{ .matches = try match(ctx, url) },
        .bind => |b| .{ .track = b.track },
        .refresh => |t| .{ .track = enhanced.personal(t, (try fetch(ctx, t.url)).track) },
        .update => |u| blk: {
            if (!std.math.isFinite(u.track.last_chapter_read) or u.track.last_chapter_read < 0) return error.InvalidProgress;
            if (!series(u.track.url) and u.track.last_chapter_read > std.math.maxInt(i32)) return error.InvalidProgress;
            const body = if (series(u.track.url))
                try std.json.Stringify.valueAlloc(ctx.arena, .{ .lastBookNumberSortRead = u.track.last_chapter_read }, .{})
            else
                try std.json.Stringify.valueAlloc(ctx.arena, .{ .lastBookRead = @as(i32, @intFromFloat(u.track.last_chapter_read)) }, .{});
            try enhanced.expectOk(try send(ctx, .PUT, try progressUrl(ctx, u.track.url), u.track.url, .{ .json = body }));
            break :blk .{ .track = (try fetch(ctx, u.track.url)).track };
        },
        .delete => error.UnsupportedDelete,
    };
}

fn series(url: []const u8) bool {
    return std.mem.indexOf(u8, url, "/api/v1/series/") != null;
}

fn progressUrl(ctx: *driver.Context, url: []const u8) ![]const u8 {
    const base = try std.mem.replaceOwned(u8, ctx.arena, enhanced.trim(url), "/api/v1/series/", "/api/v2/series/");
    return std.mem.concat(ctx.arena, u8, &.{ base, "/read-progress/tachiyomi" });
}

fn send(ctx: *driver.Context, method: std.http.Method, url: []const u8, track_url: []const u8, body: Http.Body) !Http.Response {
    const prefs = try enhanced.settings(ctx, track_url, "Address");
    const api_key = enhanced.string(prefs, "API key");
    const header: std.http.Header = if (api_key.len > 0)
        .{ .name = "X-API-Key", .value = api_key }
    else
        .{ .name = "Authorization", .value = try enhanced.basic(ctx, enhanced.string(prefs, "Username"), enhanced.string(prefs, "Password")) };
    return ctx.http.sendPrivate(ctx.arena, method, url, &.{header}, body);
}

pub fn match(ctx: *driver.Context, url: []const u8) ![]const tracking.Search {
    if (std.mem.indexOf(u8, url, "/api/v1/series/") == null and std.mem.indexOf(u8, url, "/api/v1/readlists/") == null) return error.UnsupportedSearch;
    const out = try ctx.arena.alloc(tracking.Search, 1);
    out[0] = try fetch(ctx, url);
    return out;
}

fn fetch(ctx: *driver.Context, url: []const u8) !tracking.Search {
    const response = try send(ctx, .GET, url, url, .none);
    try enhanced.expectOk(response);
    const Item = struct { name: []const u8 = "", metadata: ?struct { title: []const u8, summary: []const u8 = "", status: []const u8 = "" } = null };
    const item = try response.json(Item, ctx.arena);
    const progress = try send(ctx, .GET, try progressUrl(ctx, url), url, .none);
    try enhanced.expectOk(progress);
    const Progress = struct { booksCount: i32, booksReadCount: i32, booksUnreadCount: i32, lastReadContinuousNumberSort: f64 = 0, maxNumberSort: f64 = 0, lastReadContinuousIndex: f64 = 0 };
    const p = try progress.json(Progress, ctx.arena);
    const total = if (series(url)) p.maxNumberSort else @as(f64, @floatFromInt(p.booksCount));
    if (!std.math.isFinite(total) or total < 0 or total > std.math.maxInt(i32)) return error.InvalidTrackerResponse;
    return .{
        .track = .{ .tracker_id = 6, .url = url, .title = if (item.metadata) |m| m.title else item.name, .total_chapters = @intFromFloat(total), .last_chapter_read = if (series(url)) p.lastReadContinuousNumberSort else p.lastReadContinuousIndex, .status = if (p.booksCount == p.booksUnreadCount) 1 else if (p.booksCount == p.booksReadCount) 3 else 2 },
        .cover_url = try std.mem.concat(ctx.arena, u8, &.{ url, "/thumbnail" }),
        .summary = if (item.metadata) |m| m.summary else "",
        .publishing_status = if (item.metadata) |m| m.status else "",
    };
}

test "Komga authenticates from source prefs and maps series and readlist progress" {
    const test_http = @import("testing_enhanced.zig");
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const item = "{\"metadata\":{\"title\":\"Series\",\"summary\":\"About\",\"status\":\"ONGOING\"}}";
    const progress = "{\"booksCount\":4,\"booksReadCount\":2,\"booksUnreadCount\":2,\"lastReadContinuousNumberSort\":2.5,\"maxNumberSort\":8.9}";
    const readlist = "{\"name\":\"List\"}";
    const legacy = "{\"booksCount\":4,\"booksReadCount\":4,\"booksUnreadCount\":0,\"lastReadContinuousIndex\":4}";
    var fixture = try test_http.Fixture.init(&.{
        try test_http.ok(a, item),                                                     try test_http.ok(a, progress),
        try test_http.ok(a, "{}"),                                                     try test_http.ok(a, item),
        try test_http.ok(a, progress),                                                 try test_http.ok(a, item),
        try test_http.ok(a, progress),                                                 try test_http.ok(a, readlist),
        try test_http.ok(a, legacy),                                                   try test_http.ok(a, "{}"),
        try test_http.ok(a, readlist),                                                 try test_http.ok(a, legacy),
        "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    });
    defer fixture.deinit();
    fixture.expected = &.{
        &.{ "GET /api/v1/series/abc ", "Authorization: Basic dTpw" },
        &.{"GET /api/v2/series/abc/read-progress/tachiyomi "},
        &.{ "PUT /api/v2/series/abc/read-progress/tachiyomi ", "\"lastBookNumberSortRead\":2.5" },
        &.{},
        &.{},
        &.{},
        &.{},
        &.{"GET /api/v1/readlists/list "},
        &.{"GET /api/v1/readlists/list/read-progress/tachiyomi "},
        &.{ "PUT /api/v1/readlists/list/read-progress/tachiyomi ", "\"lastBookRead\":4" },
        &.{},
        &.{},
        &.{},
    };
    try fixture.start();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try fixture.url(a, "");
    const host = try test_http.prefs(a, tmp.dir, 123, .{ .Address = .{ .t = "s", .v = base }, .Username = .{ .t = "s", .v = "u" }, .Password = .{ .t = "s", .v = "p" } });
    var http: Http = .{ .gpa = t.allocator, .io = t.io };
    defer http.deinit();
    var ctx = test_http.context(a, &http, 6, host);
    try test_http.common(&ctx, @This());
    const url = try fixture.url(a, "/api/v1/series/abc");
    const result = (try call(&ctx, .{ .search = url })).matches[0];
    try t.expectEqual(@as(i32, 8), result.track.total_chapters);
    try t.expectEqual(@as(f64, 2.5), result.track.last_chapter_read);
    try t.expectEqual(@as(i32, 2), result.track.status);
    try t.expectEqualStrings("About", result.summary);
    _ = try call(&ctx, .{ .update = .{ .track = result.track, .did_read_chapter = true } });
    var old = result.track;
    old.title = "Keep title";
    try t.expectEqualStrings("Keep title", (try call(&ctx, .{ .refresh = old })).track.?.title);
    const list = (try call(&ctx, .{ .search = try fixture.url(a, "/api/v1/readlists/list") })).matches[0].track;
    try t.expectEqual(@as(i32, 3), list.status);
    try t.expectEqual(@as(i32, 4), list.total_chapters);
    _ = try call(&ctx, .{ .update = .{ .track = list } });
    try t.expectError(error.AuthenticationExpired, call(&ctx, .{ .refresh = old }));
    try fixture.finish();
}

test "Komga API key overrides basic credentials" {
    const test_http = @import("testing_enhanced.zig");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try test_http.Fixture.init(&.{try test_http.ok(a, "{}")});
    defer fixture.deinit();
    fixture.expected = &.{&.{"X-API-Key: secret"}};
    try fixture.start();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try fixture.url(a, "");
    const host = try test_http.prefs(a, tmp.dir, 321, .{ .Address = .{ .t = "s", .v = base }, .@"API key" = .{ .t = "s", .v = "secret" } });
    var http: Http = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer http.deinit();
    var ctx = test_http.context(a, &http, 6, host);
    try enhanced.expectOk(try send(&ctx, .GET, base, base, .none));
    try fixture.finish();
}

test "enhanced HTTP keeps credentials on the configured URL" {
    const test_http = @import("testing_enhanced.zig");
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try test_http.Fixture.init(&.{"HTTP/1.1 302 Found\r\nLocation: /redirected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"});
    defer fixture.deinit();
    fixture.expected = &.{&.{"Authorization: Basic dTpw"}};
    try fixture.start();
    var http: Http = .{ .gpa = t.allocator, .io = t.io };
    defer http.deinit();
    const response = try http.sendPrivate(a, .GET, try fixture.url(a, "/original"), &.{.{ .name = "Authorization", .value = "Basic dTpw" }}, .none);
    try t.expectEqual(std.http.Status.found, response.status);
    try fixture.finish();
}

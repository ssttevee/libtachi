//! MangaUpdates (tracker 7), as Mihon talks to it (MangaUpdates.kt,
//! MangaUpdatesApi.kt): a username and password exchanged for a session
//! token, list items, and a separate rating.
const std = @import("std");
const driver = @import("driver.zig");
const tracking = @import("../tracking.zig");
const Http = @import("http.zig").Http;

pub const default_base_url = "https://api.mangaupdates.com";

const reading_list = 0;
const wish_list = 1;
const complete_list = 2;

pub fn call(ctx: *driver.Context, op: tracking.Operation) !tracking.Reply {
    return switch (op) {
        .login_url => error.PasswordLogin,
        .login => |l| login(ctx, l.username, l.password),
        .search => |query| .{ .matches = try search(ctx, query) },
        .bind => |b| .{ .track = try bind(ctx, b.track, b.has_read_chapters) },
        .update => |u| .{ .track = try update(ctx, u.track, u.did_read_chapter) },
        .refresh => |t| .{ .track = try refresh(ctx, t) },
        .delete => |t| blk: {
            const body = try std.fmt.allocPrint(ctx.arena, "[{d}]", .{t.remote_id});
            try expectOk(try send(ctx, .POST, "/v1/lists/series/delete", .{ .json = body }));
            break :blk .{};
        },
    };
}

fn url(ctx: *driver.Context, path: []const u8) ![]const u8 {
    return std.mem.concat(ctx.arena, u8, &.{ ctx.base_url, path });
}

/// Calls with the session token, as Mihon's interceptor adds it; the
/// credential's password holds the token.
fn send(ctx: *driver.Context, method: std.http.Method, path: []const u8, body: Http.Body) !Http.Response {
    if (ctx.credential.password.len == 0) return error.NotAuthenticated;
    const auth = try std.fmt.allocPrint(ctx.arena, "Bearer {s}", .{ctx.credential.password});
    return ctx.http.send(ctx.arena, method, try url(ctx, path), &.{.{ .name = "Authorization", .value = auth }}, body);
}

fn expectOk(response: Http.Response) !void {
    if (!response.ok()) return error.TrackerRequestFailed;
}

fn login(ctx: *driver.Context, username: []const u8, password: []const u8) !tracking.Reply {
    const body = try std.json.Stringify.valueAlloc(ctx.arena, .{ .username = username, .password = password }, .{});
    const response = try ctx.http.send(ctx.arena, .PUT, try url(ctx, "/v1/account/login"), &.{}, .{ .json = body });
    try expectOk(response);
    const Login = struct { context: struct { session_token: []const u8, uid: i64 } };
    const session = (try response.json(Login, ctx.arena)).context;
    // Mihon saves the uid as the username and the token as the password.
    var credential: tracking.Credential = .{ .tracker_id = ctx.tracker_id, .username = try std.fmt.allocPrint(ctx.arena, "{d}", .{session.uid}), .password = session.session_token };
    ctx.credential = credential;
    const profile = try send(ctx, .GET, "/v1/account/profile", .none);
    try expectOk(profile);
    credential.display_name = (try profile.json(struct { username: []const u8 }, ctx.arena)).username;
    return .{ .credential = credential };
}

const Record = struct {
    series_id: ?i64 = null,
    title: ?[]const u8 = null,
    url: ?[]const u8 = null,
    description: ?[]const u8 = null,
    image: ?struct { url: ?struct { original: ?[]const u8 = null } = null } = null,
    type: ?[]const u8 = null,
    year: ?[]const u8 = null,
    bayesian_rating: ?f64 = null,
    authors: []const struct { name: []const u8 = "", type: []const u8 = "" } = &.{},

    fn toSearch(self: Record, ctx: *driver.Context) !tracking.Search {
        var authors: std.ArrayList([]const u8) = .empty;
        var artists: std.ArrayList([]const u8) = .empty;
        for (self.authors) |a| {
            if (std.mem.eql(u8, a.type, "Author")) try authors.append(ctx.arena, a.name);
            if (std.mem.eql(u8, a.type, "Artist")) try artists.append(ctx.arena, a.name);
        }
        return .{
            .track = .{ .tracker_id = ctx.tracker_id, .remote_id = self.series_id orelse 0, .title = try htmlDecode(ctx.arena, self.title orelse ""), .url = self.url orelse "" },
            .cover_url = if (self.image) |i| if (i.url) |u| u.original orelse "" else "" else "",
            .summary = try htmlDecode(ctx.arena, self.description orelse ""),
            .publishing_type = self.type orelse "null",
            .start_date = self.year orelse "null",
            .authors = authors.items,
            .artists = artists.items,
            .score = if (self.bayesian_rating) |r| if (r > 0) r else -1 else -1,
        };
    }
};

/// The few entities MangaUpdates puts in titles and descriptions.
fn htmlDecode(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const pairs = [_][2][]const u8{ .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&quot;", "\"" }, .{ "&#039;", "'" }, .{ "&#39;", "'" } };
    var out = text;
    for (pairs) |p| out = try std.mem.replaceOwned(u8, arena, out, p[0], p[1]);
    return out;
}

fn search(ctx: *driver.Context, query: []const u8) ![]const tracking.Search {
    // "id:<number>", decimal or base 36, looks a series up directly.
    if (std.mem.startsWith(u8, query, "id:")) {
        const text = std.mem.trim(u8, query["id:".len..], " ");
        const id = std.fmt.parseInt(i64, text, 10) catch std.fmt.parseInt(i64, text, 36) catch return &.{};
        const response = try ctx.http.send(ctx.arena, .GET, try url(ctx, try std.fmt.allocPrint(ctx.arena, "/v1/series/{d}", .{id})), &.{}, .none);
        if (response.status == .not_found) return &.{};
        try expectOk(response);
        const out = try ctx.arena.alloc(tracking.Search, 1);
        out[0] = try (try response.json(Record, ctx.arena)).toSearch(ctx);
        return out;
    }
    const body = try std.json.Stringify.valueAlloc(ctx.arena, .{ .search = query, .filter_types = &[_][]const u8{ "drama cd", "novel" } }, .{});
    const response = try ctx.http.send(ctx.arena, .POST, try url(ctx, "/v1/series/search"), &.{}, .{ .json = body });
    try expectOk(response);
    const results = (try response.json(struct { results: []const struct { record: Record } }, ctx.arena)).results;
    const out = try ctx.arena.alloc(tracking.Search, results.len);
    for (results, out) |r, *o| o.* = try r.record.toSearch(ctx);
    return out;
}

const ListItem = struct {
    list_id: ?i64 = null,
    status: ?struct { chapter: ?i64 = null } = null,
};

/// The list entry and rating, copied onto `track`.
fn refresh(ctx: *driver.Context, track: tracking.Track) !tracking.Track {
    const item_response = try send(ctx, .GET, try std.fmt.allocPrint(ctx.arena, "/v1/lists/series/{d}", .{track.remote_id}), .none);
    try expectOk(item_response);
    const item = try item_response.json(ListItem, ctx.arena);
    var out = track;
    out.status = @intCast(item.list_id orelse reading_list);
    out.last_chapter_read = @floatFromInt(if (item.status) |s| s.chapter orelse 0 else 0);
    // Mihon reads the rating separately and treats failure as none.
    out.score = 0;
    if (send(ctx, .GET, try std.fmt.allocPrint(ctx.arena, "/v1/series/{d}/rating", .{track.remote_id}), .none)) |rating| {
        const Rating = struct { rating: ?f64 = null };
        if (rating.ok()) out.score = (rating.json(Rating, ctx.arena) catch Rating{}).rating orelse 0;
    } else |_| {}
    return out;
}

fn bind(ctx: *driver.Context, track: tracking.Track, has_read_chapters: bool) !tracking.Track {
    if (refresh(ctx, track)) |found| return found else |_| {}
    var out = track;
    out.score = 0;
    const status: i64 = if (has_read_chapters) reading_list else wish_list;
    const body = try std.fmt.allocPrint(ctx.arena, "[{{\"series\":{{\"id\":{d}}},\"list_id\":{d}}}]", .{ track.remote_id, status });
    const response = try send(ctx, .POST, "/v1/lists/series", .{ .json = body });
    if (!response.ok()) return error.TrackerRequestFailed;
    if (response.status == .ok) {
        out.status = @intCast(status);
        out.last_chapter_read = 1;
    }
    return out;
}

fn update(ctx: *driver.Context, track: tracking.Track, did_read_chapter: bool) !tracking.Track {
    var out = track;
    if (out.status != complete_list and did_read_chapter) out.status = reading_list;
    const chapter: i64 = @intFromFloat(@trunc(out.last_chapter_read));
    const body = try std.fmt.allocPrint(ctx.arena, "[{{\"series\":{{\"id\":{d}}},\"list_id\":{d},\"status\":{{\"chapter\":{d}}}}}]", .{ out.remote_id, out.status, chapter });
    try expectOk(try send(ctx, .POST, "/v1/lists/series/update", .{ .json = body }));
    // The rating: set, or removed when zero; negative leaves it alone.
    const path = try std.fmt.allocPrint(ctx.arena, "/v1/series/{d}/rating", .{out.remote_id});
    if (out.score > 0) {
        try expectOk(try send(ctx, .PUT, path, .{ .json = try std.fmt.allocPrint(ctx.arena, "{{\"rating\":{d}}}", .{out.score}) }));
    } else if (out.score == 0) {
        try expectOk(try send(ctx, .DELETE, path, .none));
    }
    return out;
}

// ---- tests ---------------------------------------------------------------------

test "MangaUpdates logs in, searches, binds, updates and refreshes as Mihon does" {
    const Fixture = @import("../testing_http.zig").Fixture;
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = struct {
        fn r(alloc: std.mem.Allocator, body: []const u8) ![]const u8 {
            return std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
        }
    }.r;
    var fixture = try Fixture.init(&.{
        try ok(a, "{\"context\":{\"session_token\":\"tok\",\"uid\":77}}"),
        try ok(a, "{\"username\":\"reader\"}"),
        try ok(a, "{\"results\":[{\"record\":{\"series_id\":5,\"title\":\"Tom &amp; Jerry\",\"bayesian_rating\":7.5,\"authors\":[{\"name\":\"A\",\"type\":\"Author\"}]}}]}"),
        // bind: not on a list yet, then added
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        try ok(a, "{}"),
        // update: list item, then the rating set
        try ok(a, "{}"),
        try ok(a, "{}"),
        // refresh: list item and rating
        try ok(a, "{\"list_id\":0,\"status\":{\"chapter\":12}}"),
        try ok(a, "{\"rating\":8.5}"),
    });
    defer fixture.deinit();
    try fixture.start();
    var http: Http = .{ .gpa = testing.allocator, .io = testing.io };
    defer http.deinit();
    var ctx: driver.Context = .{ .arena = a, .io = testing.io, .http = &http, .base_url = try fixture.url(a, ""), .tracker_id = 7, .credential = .{ .tracker_id = 7 }, .formats = .{}, .host_dir = null };
    const credential = (try call(&ctx, .{ .login = .{ .username = "u", .password = "p" } })).credential.?;
    try testing.expectEqualStrings("77", credential.username);
    try testing.expectEqualStrings("tok", credential.password);
    try testing.expectEqualStrings("reader", credential.display_name);
    ctx.credential = credential;
    const found = (try call(&ctx, .{ .search = "tom" })).matches;
    try testing.expectEqualStrings("Tom & Jerry", found[0].track.title);
    try testing.expectEqual(7.5, found[0].score);
    const bound = (try call(&ctx, .{ .bind = .{ .track = found[0].track, .has_read_chapters = true } })).track.?;
    try testing.expectEqual(0, bound.status);
    try testing.expectEqual(1, bound.last_chapter_read);
    var changed = bound;
    changed.last_chapter_read = 12;
    changed.score = 8.5;
    _ = try call(&ctx, .{ .update = .{ .track = changed, .did_read_chapter = true } });
    const fresh = (try call(&ctx, .{ .refresh = bound })).track.?;
    try testing.expectEqual(12, fresh.last_chapter_read);
    try testing.expectEqual(8.5, fresh.score);
    try fixture.finish();
}

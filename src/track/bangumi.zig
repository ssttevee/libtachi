//! Bangumi's OAuth and v0 collections API, as Mihon uses them.
const std = @import("std");
const driver = @import("driver.zig");
const tracking = @import("../tracking.zig");
const Http = @import("http.zig").Http;

pub const default_base_url = "https://api.bgm.tv";
const client_id = "bgm291665acbd06a4c28";
const client_secret = "43e5ce36b207de16e5d3cfd3e79118db";
const redirect = "mihon://bangumi-auth";
const OAuth = struct { access_token: []const u8, created_at: i64 = 0, expires_in: i64, refresh_token: ?[]const u8 = null };

pub fn call(ctx: *driver.Context, op: tracking.Operation) !tracking.Reply {
    if (op == .login_url) return .{ .login_url = try std.mem.concat(ctx.arena, u8, &.{ "https://bgm.tv/oauth/authorize?", try Http.form(ctx.arena, &.{ .{ "client_id", client_id }, .{ "response_type", "code" }, .{ "redirect_uri", if (op.login_url.redirect_uri.len > 0) op.login_url.redirect_uri else redirect } }) }) };
    if (op == .login) return login(ctx, op.login.password, op.login.redirect_uri);
    const old_token = ctx.credential.token;
    try refreshToken(ctx);
    var reply: tracking.Reply = switch (op) {
        .search => |q| .{ .matches = try search(ctx, q) },
        .bind => |b| .{ .track = try bind(ctx, b.track, b.has_read_chapters) },
        .refresh => |t| .{ .track = (try status(ctx, t)) orelse return error.TrackNotFound },
        .update => |u| .{ .track = try update(ctx, if (u.did_read_chapter) tracking.didRead(u.track, now(ctx) * 1000) else u.track, false) },
        .delete => return error.UnsupportedDelete,
        else => unreachable,
    };
    if (!std.mem.eql(u8, old_token, ctx.credential.token)) reply.credential = ctx.credential;
    return reply;
}

fn now(ctx: *driver.Context) i64 {
    return std.Io.Clock.real.now(ctx.io).toSeconds();
}
fn endpoint(ctx: *driver.Context, path: []const u8) ![]const u8 {
    return std.mem.concat(ctx.arena, u8, &.{ ctx.base_url, path });
}
fn checked(r: Http.Response) !Http.Response {
    if (!r.ok()) return error.TrackerRequestFailed;
    return r;
}
fn send(ctx: *driver.Context, method: std.http.Method, path: []const u8, body: Http.Body) !Http.Response {
    if (ctx.credential.password.len == 0) return error.NotAuthenticated;
    return ctx.http.send(ctx.arena, method, try endpoint(ctx, path), &.{ .{ .name = "Authorization", .value = try std.fmt.allocPrint(ctx.arena, "Bearer {s}", .{ctx.credential.password}) }, .{ .name = "User-Agent", .value = "antsylich/Mihon/v0.21.2 (Android) (http://github.com/mihonapp/mihon)" } }, body);
}
fn tokenUrl(ctx: *driver.Context) ![]const u8 {
    return if (std.mem.eql(u8, ctx.base_url, default_base_url)) "https://bgm.tv/oauth/access_token" else endpoint(ctx, "/oauth/access_token");
}
fn saveToken(ctx: *driver.Context, value: OAuth) !void {
    var token = value;
    if (token.created_at == 0) token.created_at = now(ctx);
    ctx.credential.password = token.access_token;
    ctx.credential.token = try std.json.Stringify.valueAlloc(ctx.arena, token, .{});
    ctx.credential.auth_expired = false;
}
fn refreshToken(ctx: *driver.Context) !void {
    if (ctx.credential.token.len == 0) return;
    const token = try std.json.parseFromSliceLeaky(OAuth, ctx.arena, ctx.credential.token, .{ .ignore_unknown_fields = true });
    if (now(ctx) + 3600 <= token.created_at + token.expires_in) return;
    const body = try Http.form(ctx.arena, &.{ .{ "grant_type", "refresh_token" }, .{ "client_id", client_id }, .{ "client_secret", client_secret }, .{ "refresh_token", token.refresh_token orelse return error.AuthenticationExpired }, .{ "redirect_uri", redirect } });
    const response = ctx.http.send(ctx.arena, .POST, try tokenUrl(ctx), &.{}, .{ .form = body }) catch |err| switch (err) {
        error.AuthenticationExpired => return,
        else => return err,
    };
    if (response.ok()) try saveToken(ctx, try response.json(OAuth, ctx.arena));
}
fn login(ctx: *driver.Context, code: []const u8, redirect_uri: []const u8) !tracking.Reply {
    const body = try Http.form(ctx.arena, &.{ .{ "grant_type", "authorization_code" }, .{ "client_id", client_id }, .{ "client_secret", client_secret }, .{ "code", code }, .{ "redirect_uri", if (redirect_uri.len > 0) redirect_uri else redirect } });
    const response = try checked(try ctx.http.send(ctx.arena, .POST, try tokenUrl(ctx), &.{}, .{ .form = body }));
    ctx.credential = .{ .tracker_id = ctx.tracker_id };
    try saveToken(ctx, try response.json(OAuth, ctx.arena));
    const user = try (try checked(try send(ctx, .GET, "/v0/me", .none))).json(struct { username: []const u8, nickname: ?[]const u8 = null }, ctx.arena);
    ctx.credential.username = user.username;
    ctx.credential.display_name = if (user.nickname) |n| if (std.mem.trim(u8, n, " \t\r\n").len > 0) n else user.username else user.username;
    return .{ .credential = ctx.credential };
}
const Subject = struct {
    id: i64,
    name: []const u8 = "",
    name_cn: []const u8 = "",
    summary: ?[]const u8 = null,
    date: ?[]const u8 = null,
    images: ?struct { common: ?[]const u8 = null } = null,
    eps: i32 = 0,
    rating: ?struct { score: ?f64 = null } = null,
    platform: ?[]const u8 = null,
    fn isManga(s: Subject) bool {
        return s.platform == null or std.mem.eql(u8, s.platform.?, "漫画");
    }
    fn mapped(s: Subject, ctx: *driver.Context) !tracking.Search {
        const chinese = std.mem.trim(u8, s.name_cn, " \t\r\n").len > 0;
        const summary = if (s.summary) |v| std.mem.trim(u8, v, " \t\r\n") else "";
        return .{ .track = .{ .tracker_id = ctx.tracker_id, .remote_id = s.id, .title = if (chinese) s.name_cn else s.name, .total_chapters = s.eps, .url = try std.fmt.allocPrint(ctx.arena, "https://bangumi.tv/subject/{d}", .{s.id}) }, .cover_url = if (s.images) |i| i.common orelse "" else "", .summary = if (chinese) try std.mem.concat(ctx.arena, u8, &.{ "作品原名：", s.name, if (s.summary != null) "\n" else "", summary }) else summary, .start_date = s.date orelse "", .score = if (s.rating) |r| r.score orelse -1 else -1 };
    }
};
fn search(ctx: *driver.Context, query: []const u8) ![]const tracking.Search {
    var subjects: []const Subject = undefined;
    if (std.mem.startsWith(u8, query, "id:") and (std.fmt.parseInt(i32, std.mem.trim(u8, query[3..], " "), 10) catch null) != null) {
        const id = try std.fmt.parseInt(i32, std.mem.trim(u8, query[3..], " "), 10);
        const response = try checked(try send(ctx, .GET, try std.fmt.allocPrint(ctx.arena, "/v0/subjects/{d}", .{id}), .none));
        const one = try ctx.arena.alloc(Subject, 1);
        one[0] = try response.json(Subject, ctx.arena);
        subjects = one;
    } else {
        const body = try std.json.Stringify.valueAlloc(ctx.arena, .{ .keyword = query, .sort = "match", .filter = .{ .type = [_]i32{1} } }, .{});
        const response = try checked(try send(ctx, .POST, "/v0/search/subjects?limit=20", .{ .json = body }));
        subjects = (try response.json(struct { data: []const Subject = &.{} }, ctx.arena)).data;
    }
    var out: std.ArrayList(tracking.Search) = .empty;
    for (subjects) |s| if (s.isManga()) try out.append(ctx.arena, try s.mapped(ctx));
    return out.items;
}
fn status(ctx: *driver.Context, track: tracking.Track) !?tracking.Track {
    const response = try send(ctx, .GET, try std.fmt.allocPrint(ctx.arena, "/v0/users/{s}/collections/{d}", .{ ctx.credential.username, track.remote_id }), .none);
    if (response.status == .not_found) return null;
    const item = try (try checked(response)).json(struct { type: i32, ep_status: ?i32 = null, rate: ?f64 = null, subject: ?struct { eps: ?i32 = null } = null }, ctx.arena);
    if (item.type < 1 or item.type > 5) return error.InvalidStatus;
    var out = track;
    out.status = item.type;
    out.last_chapter_read = @floatFromInt(item.ep_status orelse 0);
    out.score = item.rate orelse 0;
    out.total_chapters = if (item.subject) |s| s.eps orelse 0 else 0;
    // Mihon's mapper does not copy the response's private field.
    return out;
}
fn update(ctx: *driver.Context, track: tracking.Track, add: bool) !tracking.Track {
    if (track.status < 1 or track.status > 5) return error.InvalidStatus;
    const body = try std.json.Stringify.valueAlloc(ctx.arena, .{ .type = track.status, .rate = @as(i32, @intFromFloat(std.math.clamp(@trunc(track.score), 0, 10))), .ep_status = @as(i32, @intFromFloat(@trunc(track.last_chapter_read))), .private = track.private }, .{});
    _ = try checked(try send(ctx, if (add) .POST else .PATCH, try std.fmt.allocPrint(ctx.arena, "/v0/users/-/collections/{d}", .{track.remote_id}), .{ .json = body }));
    return track;
}
fn bind(ctx: *driver.Context, track: tracking.Track, has_read: bool) !tracking.Track {
    if (try status(ctx, track)) |found| {
        var out = found;
        if (out.status != 2 and has_read) out.status = 3;
        return update(ctx, out, false);
    }
    var out = track;
    out.status = if (has_read) 3 else 1;
    out.score = 0;
    return update(ctx, out, true);
}

test "Bangumi OAuth, searches, both bind paths, update, refresh and unsupported delete" {
    const Fixture = @import("../testing_http.zig").Fixture;
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const R = struct {
        fn ok(alloc: std.mem.Allocator, body: []const u8) ![]const u8 {
            return std.fmt.allocPrint(alloc, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
        }
    }.ok;
    const subject = "{\"id\":9,\"name\":\"Original\",\"name_cn\":\"中文\",\"summary\":\" text \",\"eps\":12,\"images\":{\"common\":\"cover\"},\"date\":\"2020-01-01\",\"rating\":{\"score\":8.2}}";
    const entry = "{\"type\":4,\"ep_status\":3,\"rate\":7,\"private\":true,\"subject\":{\"eps\":12}}";
    var f = try Fixture.init(&.{
        try R(a, "{\"access_token\":\"old\",\"created_at\":1,\"expires_in\":1,\"refresh_token\":\"refresh\"}"),
        try R(a, "{\"username\":\"reader\",\"nickname\":\"Name\"}"),
        try R(a, "{\"access_token\":\"new\",\"created_at\":4000000000,\"expires_in\":7200,\"refresh_token\":\"refresh2\"}"),
        try R(a, try std.mem.concat(a, u8, &.{ "{\"data\":[", subject, ",{\"id\":10,\"platform\":\"小说\"}]}" })),
        try R(a, subject),
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        try R(a, entry),
        try R(a, ""),
        try R(a, ""),
        try R(a, entry),
    });
    defer f.deinit();
    f.expected = &.{
        &.{ "POST /oauth/access_token", "grant_type=authorization_code", "code=code", "redirect_uri=mihon%3A%2F%2Fbangumi-auth" },
        &.{ "GET /v0/me", "Bearer old" },
        &.{ "grant_type=refresh_token", "refresh_token=refresh" },
        &.{ "POST /v0/search/subjects?limit=20", "Bearer new", "\"keyword\":\"word\"", "\"type\":[1]" },
        &.{"GET /v0/subjects/9"},
        &.{"GET /v0/users/reader/collections/9"},
        &.{ "POST /v0/users/-/collections/9", "\"type\":1", "\"rate\":0" },
        &.{"GET /v0/users/reader/collections/9"},
        &.{ "PATCH /v0/users/-/collections/9", "\"type\":3", "\"private\":false" },
        &.{ "PATCH /v0/users/-/collections/9", "\"type\":2", "\"rate\":10", "\"ep_status\":12" },
        &.{"GET /v0/users/reader/collections/9"},
    };
    try f.start();
    var http: Http = .{ .gpa = t.allocator, .io = t.io };
    defer http.deinit();
    var ctx: driver.Context = .{ .arena = a, .io = t.io, .http = &http, .base_url = try f.url(a, ""), .tracker_id = 5, .credential = .{ .tracker_id = 5 }, .formats = .{}, .host_dir = null };
    const auth = (try call(&ctx, .{ .login_url = .{ .redirect_uri = "", .state = "" } })).login_url.?;
    try t.expect(std.mem.indexOf(u8, auth, "client_id=" ++ client_id) != null);
    const logged = (try call(&ctx, .{ .login = .{ .username = "", .password = "code" } })).credential.?;
    try t.expectEqualStrings("reader", logged.username);
    try t.expectEqualStrings("Name", logged.display_name);
    const reply = try call(&ctx, .{ .search = "word" });
    try t.expectEqualStrings("new", reply.credential.?.password);
    try t.expectEqual(@as(usize, 1), reply.matches.len);
    try t.expectEqualStrings("中文", reply.matches[0].track.title);
    try t.expectEqualStrings("作品原名：Original\ntext", reply.matches[0].summary);
    try t.expectEqual(@as(f64, 8.2), reply.matches[0].score);
    try t.expectEqualStrings("2020-01-01", reply.matches[0].start_date);
    const track = (try call(&ctx, .{ .search = "id: 9" })).matches[0].track;
    const added = (try call(&ctx, .{ .bind = .{ .track = track, .has_read_chapters = false } })).track.?;
    try t.expectEqual(@as(i32, 1), added.status);
    const bound = (try call(&ctx, .{ .bind = .{ .track = track, .has_read_chapters = true } })).track.?;
    try t.expectEqual(@as(i32, 3), bound.status);
    try t.expectEqual(@as(f64, 3), bound.last_chapter_read);
    var changed = bound;
    changed.last_chapter_read = 12.9;
    changed.score = 20;
    const updated = (try call(&ctx, .{ .update = .{ .track = changed, .did_read_chapter = true } })).track.?;
    try t.expectEqual(@as(i32, 2), updated.status);
    const fresh = (try call(&ctx, .{ .refresh = track })).track.?;
    try t.expectEqual(@as(i32, 4), fresh.status);
    try t.expectEqual(@as(f64, 7), fresh.score);
    try t.expect(!fresh.private);
    try t.expectError(error.UnsupportedDelete, call(&ctx, .{ .delete = track }));
    try f.finish();
}

test "Bangumi keeps an old token after a rejected refresh and reports missing collections" {
    const Fixture = @import("../testing_http.zig").Fixture;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(&.{
        "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"data\":[]}",
        "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    });
    defer f.deinit();
    f.expected = &.{ &.{"grant_type=refresh_token"}, &.{ "Bearer old", "\"keyword\":\"id:invalid\"" }, &.{"GET /v0/subjects/9"}, &.{"GET /v0/users/user/collections/9"} };
    try f.start();
    var http: Http = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer http.deinit();
    var ctx: driver.Context = .{ .arena = a, .io = std.testing.io, .http = &http, .base_url = try f.url(a, ""), .tracker_id = 5, .credential = .{ .tracker_id = 5, .username = "user", .password = "old", .token = "{\"access_token\":\"old\",\"created_at\":1,\"expires_in\":1,\"refresh_token\":\"r\"}" }, .formats = .{}, .host_dir = null };
    const result = try call(&ctx, .{ .search = "id:invalid" });
    try std.testing.expectEqual(@as(usize, 0), result.matches.len);
    try std.testing.expect(result.credential == null);
    ctx.credential.token = "";
    try std.testing.expectError(error.AuthenticationExpired, call(&ctx, .{ .search = "id:9" }));
    try std.testing.expectError(error.TrackNotFound, call(&ctx, .{ .refresh = .{ .tracker_id = 5, .remote_id = 9 } }));
    try f.finish();
}

//! Comick's OAuth, title search and library entries.
const std = @import("std");
const driver = @import("driver.zig");
const tracking = @import("../tracking.zig");
const auth = @import("pkce.zig");
const Http = @import("http.zig").Http;
pub const default_base_url = "https://api.comick.dev";
const config: auth.Config = .{ .client = "SGrUojDvbgqfhSCQbwfCjUPIccYMJdBH", .oauth = "https://comick.dev/api/auth/oauth2", .redirect = "app.mihon://comick-auth", .scope = "library:read library:write offline_access", .resource = "https://api.comick.dev/integrations/v1" };
pub fn call(ctx: *driver.Context, op: tracking.Operation) !tracking.Reply {
    const previous = ctx.credential.token;
    var reply: tracking.Reply = switch (op) {
        .login_url => |l| try auth.authorize(ctx, config, l.redirect_uri, l.state),
        .login => |l| blk: {
            const token = try auth.exchange(ctx, config, l.password, l.redirect_uri, l.verifier);
            if (token.refresh_token.len == 0 or std.mem.indexOf(u8, token.scope, "library:write") == null) return error.MissingScopes;
            try auth.save(ctx, token);
            ctx.credential.username = "user";
            const response = try send(ctx, .GET, "/integrations/v1/me", .none);
            try auth.ok(response);
            const user = try response.json(struct { id: []const u8, username: ?[]const u8 = null }, ctx.arena);
            ctx.credential.username = user.id;
            ctx.credential.display_name = user.username orelse user.id;
            break :blk .{ .credential = ctx.credential };
        },
        .search => |q| .{ .matches = try search(ctx, q) },
        .bind => |b| blk: {
            var t = b.track;
            if (try find(ctx, t)) |remote| {
                t = remote;
                break :blk .{ .track = try write(ctx, t, false) };
            }
            t.status = if (b.has_read_chapters) 1 else 5;
            t.score = 0;
            break :blk .{ .track = try write(ctx, t, true) };
        },
        .update => |u| blk: {
            var t = u.track;
            if (u.did_read_chapter and t.status != 1 and t.status != 2) {
                t.status = 1;
                if (t.last_chapter_read == 1) t.started = auth.now(ctx);
            }
            break :blk .{ .track = try write(ctx, t, false) };
        },
        .refresh => |t| .{ .track = (try find(ctx, t)) orelse return error.TrackNotFound },
        .delete => |t| blk: {
            try auth.ok(try send(ctx, .DELETE, try path(ctx, t), .none));
            break :blk .{};
        },
    };
    if (!std.mem.eql(u8, previous, ctx.credential.token)) reply.credential = ctx.credential;
    return reply;
}
fn send(ctx: *driver.Context, method: std.http.Method, p: []const u8, body: Http.Body) !Http.Response {
    return auth.send(ctx, config, method, p, body);
}
fn decode(hid: []const u8) !i64 {
    if (hid.len != 8) return error.InvalidHid;
    var bytes: [6]u8 = undefined;
    try std.base64.url_safe_no_pad.Decoder.decode(&bytes, hid);
    var id: i64 = 0;
    for (bytes) |b| id = (id << 8) | b;
    return id;
}
fn path(ctx: *driver.Context, t: tracking.Track) ![]const u8 {
    if (t.remote_id < 0 or t.remote_id >= (1 << 48)) return error.InvalidHid;
    var bytes: [6]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @truncate(@as(u64, @intCast(t.remote_id)) >> @as(u6, @intCast(8 * (5 - i))));
    var hid: [8]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&hid, &bytes);
    return std.mem.concat(ctx.arena, u8, &.{ "/integrations/v1/me/library/", &hid });
}
const Item = struct {
    hid: []const u8,
    title: []const u8,
    url: []const u8,
    year: ?i32 = null,
    description: ?[]const u8 = null,
    status: ?i32 = null,
    bayesian_rating: ?f64 = null,
    cover_url: ?[]const u8 = null,
    country: ?[]const u8 = null,
    fn map(self: Item, ctx: *driver.Context) !tracking.Search {
        return .{ .track = .{ .tracker_id = 12, .remote_id = try decode(self.hid), .title = self.title, .url = self.url }, .summary = self.description orelse "", .start_date = if (self.year) |y| try std.fmt.allocPrint(ctx.arena, "{d}", .{y}) else "", .score = self.bayesian_rating orelse -1, .cover_url = self.cover_url orelse "", .publishing_status = if (self.status) |s| switch (s) {
            1 => "Ongoing",
            2 => "Completed",
            3 => "Cancelled",
            4 => "Hiatus",
            else => return error.InvalidStatus,
        } else "", .publishing_type = if (std.mem.eql(u8, self.country orelse "", "kr")) "Manhwa" else if (std.mem.eql(u8, self.country orelse "", "cn")) "Manhua" else if (std.mem.eql(u8, self.country orelse "", "fr")) "Manfra" else "Manga" };
    }
};
fn search(ctx: *driver.Context, q: []const u8) ![]const tracking.Search {
    const direct = std.mem.startsWith(u8, q, "id:");
    const p = if (direct) try std.mem.concat(ctx.arena, u8, &.{ "/integrations/v1/titles/", try Http.form(ctx.arena, &.{.{ "", std.mem.trim(u8, q[3..], " \t\r\n") }}) }) else try std.mem.concat(ctx.arena, u8, &.{ "/integrations/v1/titles?", try Http.form(ctx.arena, &.{ .{ "q", truncateQuery(q) }, .{ "media_type", "manga" }, .{ "limit", "20" } }) });
    // Form encoding has a leading '=' for an empty key.
    const request_path = if (direct) try std.mem.replaceOwned(u8, ctx.arena, p, "/titles/=", "/titles/") else p;
    const response = try send(ctx, .GET, request_path, .none);
    if (direct and response.status == .not_found) return &.{};
    try auth.ok(response);
    const items = if (direct) &[_]Item{(try response.json(struct { data: Item }, ctx.arena)).data} else (try response.json(struct { data: []const Item }, ctx.arena)).data;
    const out = try ctx.arena.alloc(tracking.Search, items.len);
    for (items, out) |item, *o| o.* = try item.map(ctx);
    return out;
}
fn truncateQuery(q: []const u8) []const u8 {
    var i: usize = 0;
    var units: usize = 0;
    while (i < q.len and units < 100) {
        const n = std.unicode.utf8ByteSequenceLength(q[i]) catch 1;
        const count: usize = if (n == 4) 2 else 1;
        if (units + count > 100) break;
        i = @min(i + n, q.len);
        units += count;
    }
    return q[0..i];
}
fn find(ctx: *driver.Context, track: tracking.Track) !?tracking.Track {
    const response = try send(ctx, .GET, try path(ctx, track), .none);
    if (response.status == .not_found) return null;
    try auth.ok(response);
    const item = (try response.json(struct { data: struct { hid: []const u8, title: []const u8, status: i32, progress: ?struct { number: ?[]const u8 = null } = null, rating: ?f64 = null } }, ctx.arena)).data;
    _ = try decode(item.hid);
    if (item.status < 1 or item.status > 5) return error.InvalidStatus;
    var t = track;
    t.status = item.status;
    t.last_chapter_read = if (item.progress) |p| if (p.number) |n| try std.fmt.parseFloat(f64, n) else 0 else 0;
    t.score = item.rating orelse 0;
    t.started = 0;
    t.finished = 0;
    t.private = false;
    return t;
}
fn write(ctx: *driver.Context, t: tracking.Track, add: bool) !tracking.Track {
    if (t.status < 1 or t.status > 5) return error.InvalidStatus;
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("status");
    try json.write(t.status);
    if (!add) {
        try json.objectField("rating");
        try json.write(if (t.score > 0) @as(?i32, @intFromFloat(t.score)) else null);
    }
    try json.objectField("progress");
    if (add and t.last_chapter_read <= 0) try json.write(null) else {
        try json.beginObject();
        try json.objectField("number");
        const rounded = @round(t.last_chapter_read * 100) / 100;
        try json.write(try std.fmt.allocPrint(ctx.arena, "{d}", .{rounded}));
        try json.endObject();
    }
    try json.endObject();
    try auth.ok(try send(ctx, if (add) .PUT else .PATCH, try path(ctx, t), .{ .json = out.written() }));
    return t;
}

test "Comick OAuth, search, library operations and refresh use local fixtures" {
    const testing = std.testing;
    const Fixture = @import("../testing_http.zig").Fixture;
    const helper = @import("service_test.zig");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const title = "{\"hid\":\"AAAAAAAF\",\"title\":\"Title\",\"url\":\"https://comick.dev/title\",\"year\":2020,\"status\":4,\"country\":\"kr\",\"bayesian_rating\":8.25}";
    const entry = "{\"data\":{\"hid\":\"AAAAAAAF\",\"title\":\"Remote\",\"status\":3,\"progress\":{\"number\":\"12.25\"},\"rating\":8}}";
    var fixture = try Fixture.init(&.{
        try helper.response(a, "{\"access_token\":\"token\",\"refresh_token\":\"refresh\",\"expires_at\":9999999999,\"scope\":\"library:write offline_access\"}"),
        try helper.response(a, "{\"id\":\"uid\",\"username\":\"reader\"}"),
        try helper.response(a, try std.fmt.allocPrint(a, "{{\"data\":[{s}]}}", .{title})),
        try helper.response(a, try std.fmt.allocPrint(a, "{{\"data\":{s}}}", .{title})),
        helper.missing,
        helper.missing,
        try helper.response(a, "{}"),
        try helper.response(a, entry),
        try helper.response(a, "{}"),
        try helper.response(a, "{}"),
        try helper.response(a, entry),
        try helper.response(a, "{}"),
        // Expired credentials are replaced before the next authorized request.
        try helper.response(a, "{\"access_token\":\"new\",\"refresh_token\":\"next\",\"expires_at\":9999999999,\"scope\":\"library:write\"}"),
        try helper.response(a, "{\"data\":[]}"),
    });
    defer fixture.deinit();
    try fixture.start();
    var http: Http = .{ .gpa = testing.allocator, .io = testing.io };
    defer http.deinit();
    var ctx: driver.Context = .{ .arena = a, .io = testing.io, .http = &http, .base_url = try fixture.url(a, ""), .tracker_id = 12, .credential = .{ .tracker_id = 12 }, .formats = .{}, .host_dir = null };
    const authorization = try call(&ctx, .{ .login_url = .{ .redirect_uri = "app://callback", .state = "state" } });
    try helper.contains(authorization.login_url.?, "code_challenge_method=S256");
    try helper.contains(authorization.login_url.?, "state=state");
    try testing.expectEqual(43, authorization.verifier.?.len);
    const credential = (try call(&ctx, .{ .login = .{ .username = "", .password = "code", .redirect_uri = "app://callback", .verifier = authorization.verifier.? } })).credential.?;
    try testing.expectEqualStrings("uid", credential.username);
    try testing.expectEqualStrings("reader", credential.display_name);
    const matches = (try call(&ctx, .{ .search = "a & b" })).matches;
    try testing.expectEqual(5, matches[0].track.remote_id);
    try testing.expectEqualStrings("Manhwa", matches[0].publishing_type);
    try testing.expectEqualStrings("Hiatus", matches[0].publishing_status);
    try testing.expectEqual(8.25, matches[0].score);
    _ = try call(&ctx, .{ .search = "id: AAAAAAAF " });
    try testing.expectEqual(0, (try call(&ctx, .{ .search = "id:missing" })).matches.len);
    const bound = (try call(&ctx, .{ .bind = .{ .track = matches[0].track, .has_read_chapters = false } })).track.?;
    try testing.expectEqual(5, bound.status);
    const existing = (try call(&ctx, .{ .bind = .{ .track = bound, .has_read_chapters = true } })).track.?;
    try testing.expectEqual(3, existing.status);
    try testing.expectEqualStrings("Title", existing.title);
    try testing.expectEqual(12.25, existing.last_chapter_read);
    var changed = existing;
    changed.last_chapter_read = 1;
    changed.score = 0;
    const updated = (try call(&ctx, .{ .update = .{ .track = changed, .did_read_chapter = true } })).track.?;
    try testing.expectEqual(1, updated.status);
    try testing.expect(updated.started > 0);
    try testing.expectEqual(8, (try call(&ctx, .{ .refresh = bound })).track.?.score);
    _ = try call(&ctx, .{ .delete = bound });
    try auth.save(&ctx, .{ .access_token = "old", .refresh_token = "refresh", .expires_at = 0 });
    const refreshed = try call(&ctx, .{ .search = "refresh" });
    try testing.expectEqualStrings("new", refreshed.credential.?.password);
    try fixture.finish();
    const requests = fixture.captured.items;
    try helper.contains(requests[0], "POST /token ");
    try helper.contains(requests[0], "code_verifier=");
    try helper.contains(requests[0], "resource=https%3A%2F%2Fapi.comick.dev%2Fintegrations%2Fv1");
    try helper.contains(requests[2], "q=a%20%26%20b&media_type=manga&limit=20");
    try helper.contains(requests[2], "Bearer token");
    try helper.contains(requests[3], "GET /integrations/v1/titles/AAAAAAAF ");
    try helper.contains(requests[6], "PUT /integrations/v1/me/library/AAAAAAAF ");
    try helper.contains(requests[6], "\"progress\":null");
    try helper.contains(requests[9], "PATCH /integrations/v1/me/library/AAAAAAAF ");
    try helper.contains(requests[9], "\"rating\":null");
    try helper.contains(requests[9], "\"number\":\"1\"");
    try helper.contains(requests[11], "DELETE /integrations/v1/me/library/AAAAAAAF ");
    try helper.contains(requests[12], "grant_type=refresh_token");
    try helper.contains(requests[13], "Bearer new");
}

test "Comick validates HIDs and preserves UTF-8 when limiting search" {
    try std.testing.expectEqual(@as(i64, (1 << 48) - 1), try decode("________"));
    try std.testing.expectError(error.InvalidHid, decode("bad"));
    try std.testing.expectError(error.InvalidCharacter, decode("!!!!!!!!"));
    var q: [202]u8 = undefined;
    for (0..101) |i| {
        q[2 * i] = 0xc3;
        q[2 * i + 1] = 0xa9;
    }
    try std.testing.expectEqual(200, truncateQuery(&q).len);
}

test "Comick rejects missing scopes, retains completed status and reports missing entries" {
    const testing = std.testing;
    const Fixture = @import("../testing_http.zig").Fixture;
    const helper = @import("service_test.zig");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try Fixture.init(&.{
        try helper.response(a, "{\"access_token\":\"token\",\"expires_at\":9999999999,\"scope\":\"library:write\"}"),
        try helper.response(a, "{\"access_token\":\"token\",\"refresh_token\":\"refresh\",\"expires_at\":9999999999,\"scope\":\"library:read offline_access\"}"),
        try helper.response(a, "{}"),
        helper.missing,
        // A rejected refresh retains the old token, just as the interceptor does.
        "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        try helper.response(a, "{\"data\":[]}"),
    });
    defer fixture.deinit();
    try fixture.start();
    var http: Http = .{ .gpa = testing.allocator, .io = testing.io };
    defer http.deinit();
    var ctx: driver.Context = .{ .arena = a, .io = testing.io, .http = &http, .base_url = try fixture.url(a, ""), .tracker_id = 12, .credential = .{ .tracker_id = 12 }, .formats = .{}, .host_dir = null };
    try testing.expectError(error.NotAuthenticated, call(&ctx, .{ .search = "test" }));
    try testing.expectError(error.MissingPkceVerifier, call(&ctx, .{ .login = .{ .username = "", .password = "code" } }));
    const login_op: tracking.Operation = .{ .login = .{ .username = "", .password = "code", .verifier = "verifier" } };
    try testing.expectError(error.MissingScopes, call(&ctx, login_op));
    try testing.expectError(error.MissingScopes, call(&ctx, login_op));
    ctx.credential = .{ .tracker_id = 12, .username = "u", .password = "token" };
    const completed = (try call(&ctx, .{ .update = .{ .track = .{ .tracker_id = 12, .remote_id = 5, .status = 2, .score = 8.9, .last_chapter_read = 12.345 }, .did_read_chapter = true } })).track.?;
    try testing.expectEqual(2, completed.status);
    try testing.expectError(error.TrackNotFound, call(&ctx, .{ .refresh = completed }));
    try auth.save(&ctx, .{ .access_token = "old", .refresh_token = "refresh", .expires_at = 0 });
    const reply = try call(&ctx, .{ .search = "test" });
    try testing.expect(reply.credential == null);
    try fixture.finish();
    try helper.contains(fixture.captured.items[2], "\"rating\":8");
    try helper.contains(fixture.captured.items[2], "\"number\":\"12.35\"");
    try helper.contains(fixture.captured.items[5], "Bearer old");
}

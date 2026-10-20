//! MangaBaka's OAuth, series search and private library entries.
const std = @import("std");
const driver = @import("driver.zig");
const tracking = @import("../tracking.zig");
const auth = @import("pkce.zig");
const Http = @import("http.zig").Http;
pub const default_base_url = "https://api.mangabaka.org";
const config: auth.Config = .{ .client = "zEZYMHXLWsLsafgbvJHXqzGvqQNOdkpo", .oauth = "https://mangabaka.org/auth/oauth2", .redirect = "mihon://mangabaka-auth", .scope = "library.read library.write offline_access openid" };
const states = [_][]const u8{ "reading", "completed", "paused", "dropped", "plan_to_read", "rereading", "considering" };
pub fn call(ctx: *driver.Context, op: tracking.Operation) !tracking.Reply {
    const previous = ctx.credential.token;
    var reply: tracking.Reply = switch (op) {
        .login_url => |l| try auth.authorize(ctx, config, l.redirect_uri, l.state),
        .login => |l| blk: {
            try auth.save(ctx, try auth.exchange(ctx, config, l.password, l.redirect_uri, l.verifier));
            ctx.credential.username = "user";
            const response = try send(ctx, .GET, "/v1/my/profile", .none);
            try auth.ok(response);
            const user = (try response.json(struct { data: struct { id: []const u8, nickname: ?[]const u8 = null, preferred_username: ?[]const u8 = null, rating_steps: u8 } }, ctx.arena)).data;
            const format: tracking.MangaBakaScore = switch (user.rating_steps) {
                1 => .STEP_1,
                5 => .STEP_5,
                10 => .STEP_10,
                20 => .STEP_20,
                25 => .STEP_25,
                else => return error.InvalidScoreStep,
            };
            ctx.credential.username = user.id;
            ctx.credential.display_name = user.nickname orelse user.preferred_username orelse user.id;
            break :blk .{ .credential = ctx.credential, .mangabaka_score_type = format };
        },
        .search => |q| .{ .matches = try search(ctx, q) },
        .bind => |b| blk: {
            var t = b.track;
            if (try find(ctx, t)) |remote| {
                const private = t.private;
                t = remote;
                t.private = private;
                if (t.status != 2 and t.status != 6 and b.has_read_chapters) t.status = 1;
                break :blk .{ .track = try write(ctx, t, false) };
            }
            t.status = if (b.has_read_chapters) 1 else 5;
            t.score = 0;
            break :blk .{ .track = try write(ctx, t, true) };
        },
        .update => |u| blk: {
            var t = u.track;
            if (u.did_read_chapter and t.status != 2) {
                if (t.total_chapters > 0 and @trunc(t.last_chapter_read) == @as(f64, @floatFromInt(t.total_chapters))) {
                    t.status = 2;
                    t.finished = auth.now(ctx);
                } else if (t.status != 6) {
                    t.status = 1;
                    if (t.last_chapter_read == 1) t.started = auth.now(ctx);
                }
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
fn path(ctx: *driver.Context, t: tracking.Track) ![]const u8 {
    return std.fmt.allocPrint(ctx.arena, "/v1/my/library/{d}", .{t.remote_id});
}
const Item = struct {
    id: i64,
    cover: struct { x250: struct { x1: ?[]const u8 = null } = .{} } = .{},
    authors: ?[]const []const u8 = null,
    artists: ?[]const []const u8 = null,
    description: ?[]const u8 = null,
    published: struct { start_date: ?[]const u8 = null } = .{},
    status: []const u8 = "",
    type: []const u8 = "",
    rating: ?f64 = null,
    titles: ?[]const struct { language: []const u8, traits: []const []const u8 = &.{}, title: []const u8, is_primary: bool = false } = null,
    fn title(self: Item, ctx: *driver.Context) ![]const u8 {
        if (self.titles) |titles| {
            for ([_][]const u8{ "en", "ja-Latn", "ja", "ko-Latn", "ko", "zh-Latn", "zh" }) |language| {
                var best: ?[]const u8 = null;
                var rank: u8 = 4;
                for (titles) |t| {
                    if (!std.mem.eql(u8, language, t.language)) continue;
                    var r: u8 = if (t.is_primary) 0 else 3;
                    for (t.traits) |trait| {
                        if (std.mem.eql(u8, trait, "official")) r = @min(r, 1);
                        if (std.mem.eql(u8, trait, "native")) r = @min(r, 2);
                    }
                    if (r < rank) {
                        rank = r;
                        best = t.title;
                    }
                }
                if (best) |b| return b;
            }
            if (titles.len > 0) return titles[0].title;
        }
        return std.fmt.allocPrint(ctx.arena, "ID: {d} - Could not find name! (report on the MangaBaka Discord)", .{self.id});
    }
    fn map(self: Item, ctx: *driver.Context) !tracking.Search {
        const kind = try ctx.arena.dupe(u8, self.type);
        if (kind.len > 0) kind[0] = std.ascii.toUpper(kind[0]);
        return .{ .track = .{ .tracker_id = 11, .remote_id = self.id, .title = try self.title(ctx), .url = try std.fmt.allocPrint(ctx.arena, "https://mangabaka.org/{d}", .{self.id}) }, .summary = std.mem.trim(u8, self.description orelse "", " \t\r\n"), .score = if (self.rating) |r| @round(r * 100) / 100 else -1, .cover_url = self.cover.x250.x1 orelse "", .start_date = self.published.start_date orelse "", .publishing_status = self.status, .publishing_type = kind, .authors = self.authors orelse &.{}, .artists = self.artists orelse &.{} };
    }
};
fn search(ctx: *driver.Context, q: []const u8) ![]const tracking.Search {
    const id: ?i32 = if (std.mem.startsWith(u8, q, "id:")) std.fmt.parseInt(i32, std.mem.trim(u8, q[3..], " \t\r\n"), 10) catch null else null;
    const p = if (id) |n| try std.fmt.allocPrint(ctx.arena, "/v1/series/{d}", .{n}) else try std.mem.concat(ctx.arena, u8, &.{ "/v1/series/search?", try Http.form(ctx.arena, &.{ .{ "q", q }, .{ "type_not", "novel" } }) });
    const response = if (id != null) try send(ctx, .GET, p, .none) else try ctx.http.send(ctx.arena, .GET, try std.mem.concat(ctx.arena, u8, &.{ ctx.base_url, p }), &.{}, .none);
    if (id != null and response.status == .not_found) return &.{};
    try auth.ok(response);
    const items = if (id != null) &[_]Item{(try response.json(struct { data: Item }, ctx.arena)).data} else (try response.json(struct { data: []const Item }, ctx.arena)).data;
    const out = try ctx.arena.alloc(tracking.Search, items.len);
    for (items, out) |item, *o| o.* = try item.map(ctx);
    return out;
}
fn find(ctx: *driver.Context, track: tracking.Track) !?tracking.Track {
    const response = try send(ctx, .GET, try path(ctx, track), .none);
    if (response.status == .not_found) return null;
    try auth.ok(response);
    const item = (try response.json(struct { data: struct { state: []const u8, start_date: ?[]const u8 = null, finish_date: ?[]const u8 = null, is_private: bool, progress_chapter: ?f64 = null, rating: ?f64 = null } }, ctx.arena)).data;
    const details = try send(ctx, .GET, try std.fmt.allocPrint(ctx.arena, "/v1/series/{d}", .{track.remote_id}), .none);
    if (details.status == .not_found) return null;
    try auth.ok(details);
    var t = track;
    t.title = try (try details.json(struct { data: Item }, ctx.arena)).data.title(ctx);
    t.status = 0;
    for (states, 1..) |s, i| if (std.mem.eql(u8, s, item.state)) {
        t.status = @intCast(i);
        break;
    };
    if (t.status == 0) return error.InvalidStatus;
    t.score = item.rating orelse 0;
    t.private = item.is_private;
    t.last_chapter_read = item.progress_chapter orelse 0;
    t.started = try parseDate(item.start_date);
    t.finished = try parseDate(item.finish_date);
    return t;
}
fn write(ctx: *driver.Context, t: tracking.Track, add: bool) !tracking.Track {
    if (t.status < 1 or t.status > 7) return error.InvalidStatus;
    var out: std.Io.Writer.Allocating = .init(ctx.arena);
    var json: std.json.Stringify = .{ .writer = &out.writer };
    try json.beginObject();
    try json.objectField("state");
    try json.write(states[@intCast(t.status - 1)]);
    try json.objectField("is_private");
    try json.write(t.private);
    if (!add or t.last_chapter_read > 0) {
        try json.objectField("progress_chapter");
        try json.write(if (t.last_chapter_read > 0) @as(?f64, t.last_chapter_read) else null);
    }
    if (!add or t.score > 0) {
        try json.objectField("rating");
        try json.write(if (t.score > 0) @as(?i32, @intFromFloat(std.math.clamp(t.score, 0, 100))) else null);
    }
    if (!add or t.started > 0) {
        try json.objectField("start_date");
        try json.write(try formatDate(ctx, t.started));
    }
    if (!add or t.finished > 0) {
        try json.objectField("finish_date");
        try json.write(try formatDate(ctx, t.finished));
    }
    try json.endObject();
    try auth.ok(try send(ctx, if (add) .POST else .PUT, try path(ctx, t), .{ .json = out.written() }));
    return t;
}
// Use the same local calendar conversion as the engine's reading dates.
extern "c" fn tachi_local_date(year: c_int, month: c_int, day: c_int) i64;
extern "c" fn tachi_date_parts(milliseconds: i64, parts: *[3]c_int) c_int;
fn parseDate(text: ?[]const u8) !i64 {
    const s = text orelse return 0;
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return error.InvalidDate;
    const year = try std.fmt.parseInt(u16, s[0..4], 10);
    const month = try std.fmt.parseInt(u8, s[5..7], 10);
    const day = try std.fmt.parseInt(u8, s[8..10], 10);
    if (month < 1 or month > 12 or day < 1 or day > std.time.epoch.getDaysInMonth(year, @fromBackingInt(@intCast(month)))) return error.InvalidDate;
    return tachi_local_date(year, month, day);
}
fn formatDate(ctx: *driver.Context, ms: i64) !?[]const u8 {
    if (ms <= 0) return null;
    var parts: [3]c_int = undefined;
    if (tachi_date_parts(ms, &parts) == 0) return error.InvalidDate;
    return try std.fmt.allocPrint(ctx.arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(parts[0])), @as(u32, @intCast(parts[1])), @as(u32, @intCast(parts[2])) });
}

test "MangaBaka OAuth, search, library operations and refresh use local fixtures" {
    const testing = std.testing;
    const Fixture = @import("../testing_http.zig").Fixture;
    const helper = @import("service_test.zig");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const title = "{\"id\":5,\"titles\":[{\"language\":\"ja\",\"title\":\"Japanese\"},{\"language\":\"en\",\"title\":\"Alias\"},{\"language\":\"en\",\"title\":\"Official\",\"traits\":[\"official\"]},{\"language\":\"en\",\"title\":\"Primary\",\"is_primary\":true}],\"description\":\"  Summary  \",\"type\":\"manga\",\"status\":\"releasing\",\"rating\":80.126,\"cover\":{\"x250\":{\"x1\":\"cover\"}},\"published\":{\"start_date\":\"2020-01-01\"},\"authors\":[\"Author\"],\"artists\":[\"Artist\"]}";
    const details = try std.fmt.allocPrint(a, "{{\"data\":{s}}}", .{title});
    const entry = "{\"data\":{\"state\":\"paused\",\"is_private\":true,\"progress_chapter\":12.5,\"rating\":85,\"start_date\":\"2024-02-29T00:00:00Z\",\"finish_date\":null}}";
    var fixture = try Fixture.init(&.{
        try helper.response(a, "{\"access_token\":\"token\",\"refresh_token\":\"refresh\",\"expires_at\":9999999999}"),
        try helper.response(a, "{\"data\":{\"id\":\"uid\",\"nickname\":\"reader\",\"rating_steps\":25}}"),
        try helper.response(a, try std.fmt.allocPrint(a, "{{\"data\":[{s}]}}", .{title})),
        try helper.response(a, details),
        helper.missing,
        helper.missing,
        try helper.response(a, "{}"),
        try helper.response(a, entry),
        try helper.response(a, details),
        try helper.response(a, "{}"),
        try helper.response(a, "{}"),
        try helper.response(a, entry),
        try helper.response(a, details),
        try helper.response(a, "{}"),
        try helper.response(a, "{\"access_token\":\"new\",\"refresh_token\":\"next\",\"expires_at\":9999999999}"),
        try helper.response(a, details),
    });
    defer fixture.deinit();
    try fixture.start();
    var http: Http = .{ .gpa = testing.allocator, .io = testing.io };
    defer http.deinit();
    var ctx: driver.Context = .{ .arena = a, .io = testing.io, .http = &http, .base_url = try fixture.url(a, ""), .tracker_id = 11, .credential = .{ .tracker_id = 11 }, .formats = .{}, .host_dir = null };
    const authorization = try call(&ctx, .{ .login_url = .{ .redirect_uri = "app://callback", .state = "state" } });
    try helper.contains(authorization.login_url.?, "code_challenge_method=S256");
    try helper.contains(authorization.login_url.?, "state=state");
    const logged = try call(&ctx, .{ .login = .{ .username = "", .password = "code", .redirect_uri = "app://callback", .verifier = authorization.verifier.? } });
    try testing.expectEqualStrings("uid", logged.credential.?.username);
    try testing.expectEqualStrings("reader", logged.credential.?.display_name);
    try testing.expectEqual(tracking.MangaBakaScore.STEP_25, logged.mangabaka_score_type.?);
    const found = (try call(&ctx, .{ .search = "a & b" })).matches[0];
    try testing.expectEqualStrings("Primary", found.track.title);
    try testing.expectEqualStrings("Summary", found.summary);
    try testing.expectEqualStrings("Manga", found.publishing_type);
    try testing.expectEqualStrings("releasing", found.publishing_status);
    try testing.expectEqualStrings("cover", found.cover_url);
    try testing.expectEqualStrings("Author", found.authors[0]);
    try testing.expectEqual(80.13, found.score);
    _ = try call(&ctx, .{ .search = "id: 5 " });
    try testing.expectEqual(0, (try call(&ctx, .{ .search = "id:404" })).matches.len);
    const bound = (try call(&ctx, .{ .bind = .{ .track = found.track, .has_read_chapters = false } })).track.?;
    try testing.expectEqual(5, bound.status);
    const existing = (try call(&ctx, .{ .bind = .{ .track = bound, .has_read_chapters = true } })).track.?;
    try testing.expectEqual(1, existing.status);
    try testing.expect(!existing.private);
    try testing.expectEqual(12.5, existing.last_chapter_read);
    var changed = existing;
    changed.total_chapters = 13;
    changed.last_chapter_read = 13.5;
    const updated = (try call(&ctx, .{ .update = .{ .track = changed, .did_read_chapter = true } })).track.?;
    try testing.expectEqual(2, updated.status);
    try testing.expect(updated.finished > 0);
    const fresh = (try call(&ctx, .{ .refresh = bound })).track.?;
    try testing.expect(fresh.private);
    try testing.expectEqual(3, fresh.status);
    try testing.expectEqual(85, fresh.score);
    try testing.expectEqual(try parseDate("2024-02-29"), fresh.started);
    _ = try call(&ctx, .{ .delete = bound });
    try auth.save(&ctx, .{ .access_token = "old", .refresh_token = "refresh", .expires_at = 0 });
    const refreshed = try call(&ctx, .{ .search = "id:5" });
    try testing.expectEqualStrings("new", refreshed.credential.?.password);
    try fixture.finish();
    const requests = fixture.captured.items;
    try helper.contains(requests[0], "POST /token ");
    try helper.contains(requests[0], "code_verifier=");
    try helper.contains(requests[0], "code_challenge_method=S256");
    try helper.contains(requests[2], "q=a%20%26%20b&type_not=novel");
    try testing.expect(std.mem.indexOf(u8, requests[2], "Authorization:") == null);
    try helper.contains(requests[3], "GET /v1/series/5 ");
    try helper.contains(requests[3], "Bearer token");
    try helper.contains(requests[6], "POST /v1/my/library/5 ");
    try helper.contains(requests[6], "\"state\":\"plan_to_read\"");
    try testing.expect(std.mem.indexOf(u8, requests[6], "rating") == null);
    try helper.contains(requests[9], "PUT /v1/my/library/5 ");
    try helper.contains(requests[9], "\"start_date\":\"2024-02-29\"");
    try helper.contains(requests[9], "\"finish_date\":null");
    try helper.contains(requests[9], "\"is_private\":false");
    try helper.contains(requests[10], "\"state\":\"completed\"");
    try helper.contains(requests[13], "DELETE /v1/my/library/5 ");
    try helper.contains(requests[14], "grant_type=refresh_token");
    try helper.contains(requests[15], "Bearer new");
}

test "MangaBaka dates and title fallback" {
    const testing = std.testing;
    try testing.expectEqual(0, try parseDate(null));
    try testing.expectError(error.InvalidDate, parseDate("2023-02-29"));
    try testing.expectEqual(tachi_local_date(1970, 1, 2), try parseDate("1970-01-02"));
}

test "MangaBaka writes every status, clears unset fields and preserves rereading" {
    const testing = std.testing;
    const Fixture = @import("../testing_http.zig").Fixture;
    const helper = @import("service_test.zig");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const response = try helper.response(a, "{}");
    var fixture = try Fixture.init(&.{ response, response, response, response, response, response, response, helper.missing, try helper.response(a, "{\"data\":[]}") });
    defer fixture.deinit();
    try fixture.start();
    var http: Http = .{ .gpa = testing.allocator, .io = testing.io };
    defer http.deinit();
    var ctx: driver.Context = .{ .arena = a, .io = testing.io, .http = &http, .base_url = try fixture.url(a, ""), .tracker_id = 11, .credential = .{ .tracker_id = 11, .username = "u", .password = "token" }, .formats = .{}, .host_dir = null };
    for (1..8) |status| {
        const t: tracking.Track = .{ .tracker_id = 11, .remote_id = 5, .status = @intCast(status), .score = if (status == 7) 123 else 0, .last_chapter_read = if (status == 6) 1 else 0 };
        const updated = (try call(&ctx, .{ .update = .{ .track = t, .did_read_chapter = status == 6 } })).track.?;
        try testing.expectEqual(t.status, updated.status);
        try testing.expectEqual(0, updated.started);
    }
    try testing.expectError(error.TrackNotFound, call(&ctx, .{ .refresh = .{ .tracker_id = 11, .remote_id = 5 } }));
    _ = try call(&ctx, .{ .search = "id:not-a-number" });
    try fixture.finish();
    for (states, 0..) |state, i| try helper.contains(fixture.captured.items[i], try std.fmt.allocPrint(a, "\"state\":\"{s}\"", .{state}));
    try helper.contains(fixture.captured.items[0], "\"rating\":null");
    try helper.contains(fixture.captured.items[0], "\"progress_chapter\":null");
    try helper.contains(fixture.captured.items[0], "\"start_date\":null");
    try helper.contains(fixture.captured.items[6], "\"rating\":100");
    try helper.contains(fixture.captured.items[8], "q=id%3Anot-a-number&type_not=novel");
}

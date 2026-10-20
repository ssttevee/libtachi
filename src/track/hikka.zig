//! Hikka's reference login, manga search and read lists, as Mihon uses them.
const std = @import("std");
const driver = @import("driver.zig");
const tracking = @import("../tracking.zig");
const Http = @import("http.zig").Http;
pub const default_base_url = "https://api.hikka.io";
const client_secret = "OKwzrNOZxq40psFgfcCUYddnvaeZWDnd34rt7fdcB5GmHoBBQuNTWX" ++ "61sZs8KECEWVXtMUDtq8QC4t9WX4DwWWYLXEVlgnlUXGT1fWCb-18c" ++ "Zd2m8Co-8HN6JQcjoP-B";
const OAuth = struct { secret: []const u8, expiration: i64, created: i64 };

pub fn call(ctx: *driver.Context, op: tracking.Operation) !tracking.Reply {
    if (op == .login_url) return .{ .login_url = "https://hikka.io/oauth?reference=598ef1f5-b9d2-4e66-8b65-06949d5e14fc&scope=readlist%2Cread%3Auser-details" };
    if (op == .login) return login(ctx, op.login.password);
    const old_token = ctx.credential.token;
    try refreshToken(ctx);
    var reply: tracking.Reply = switch (op) {
        .search => |q| .{ .matches = try search(ctx, q) },
        .bind => |b| .{ .track = try bind(ctx, b.track, b.has_read_chapters) },
        .refresh => |t| .{ .track = try refresh(ctx, t) },
        .update => |u| .{ .track = try update(ctx, automatic(ctx, u.track, u.did_read_chapter)) },
        .delete => |t| blk: {
            _ = try checked(try send(ctx, .DELETE, try readPath(ctx, t), .none));
            break :blk .{};
        },
        else => unreachable,
    };
    if (!std.mem.eql(u8, old_token, ctx.credential.token)) reply.credential = ctx.credential;
    return reply;
}
fn now(ctx: *driver.Context) i64 {
    return std.Io.Clock.real.now(ctx.io).toSeconds();
}
fn automatic(ctx: *driver.Context, track: tracking.Track, did_read: bool) tracking.Track {
    // Hikka starts dates only when transitioning to reading, not rereading.
    if (!did_read or track.status == 1) return track;
    var out = track;
    if (out.total_chapters > 0 and @trunc(out.last_chapter_read) == @as(f64, @floatFromInt(out.total_chapters))) {
        out.status = 1;
        out.finished = std.Io.Clock.real.now(ctx.io).toMilliseconds();
    } else if (out.status != 5) {
        out.status = 0;
        if (out.last_chapter_read == 1) out.started = std.Io.Clock.real.now(ctx.io).toMilliseconds();
    }
    return out;
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
    return ctx.http.send(ctx.arena, method, try endpoint(ctx, path), &.{ .{ .name = "auth", .value = ctx.credential.password }, .{ .name = "accept", .value = "application/json" } }, body);
}
fn saveToken(ctx: *driver.Context, token: OAuth) !void {
    ctx.credential.password = token.secret;
    ctx.credential.token = try std.json.Stringify.valueAlloc(ctx.arena, token, .{});
    ctx.credential.auth_expired = false;
}
fn refreshToken(ctx: *driver.Context) !void {
    if (ctx.credential.token.len == 0) return;
    const token = try std.json.parseFromSliceLeaky(OAuth, ctx.arena, ctx.credential.token, .{ .ignore_unknown_fields = true });
    if (now(ctx) + 300 < token.expiration) return;
    _ = try checked(try send(ctx, .GET, "/user/me", .none));
    const info = try (try checked(try send(ctx, .GET, "/auth/token/info", .none))).json(struct { expiration: i64, created: i64 }, ctx.arena);
    try saveToken(ctx, .{ .secret = token.secret, .expiration = info.expiration, .created = info.created });
}
fn login(ctx: *driver.Context, reference: []const u8) !tracking.Reply {
    const body = try std.json.Stringify.valueAlloc(ctx.arena, .{ .request_reference = reference, .client_secret = client_secret }, .{});
    const response = try checked(try ctx.http.send(ctx.arena, .POST, try endpoint(ctx, "/auth/token"), &.{}, .{ .json = body }));
    ctx.credential = .{ .tracker_id = ctx.tracker_id };
    try saveToken(ctx, try response.json(OAuth, ctx.arena));
    try refreshToken(ctx);
    const user = try (try checked(try send(ctx, .GET, "/user/me", .none))).json(struct { reference: []const u8, username: []const u8 }, ctx.arena);
    ctx.credential.username = user.reference;
    ctx.credential.display_name = user.username;
    return .{ .credential = ctx.credential };
}
const states = [_][]const u8{ "reading", "completed", "on_hold", "dropped", "planned", "reading" };
fn localStatus(value: []const u8) !i32 {
    for (states[0..5], 0..) |s, i| if (std.mem.eql(u8, value, s)) return @intCast(i);
    return error.InvalidStatus;
}
/// Java's UUID.nameUUIDFromBytes, with the signed high half masked positive.
fn slugId(text: []const u8) i64 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(text, &digest, .{});
    digest[6] = (digest[6] & 0x0f) | 0x30;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    return @intCast(std.mem.readInt(u64, digest[0..8], .big) & 0x7fff_ffff_ffff_ffff);
}
extern fn tachi_date_parts(milliseconds: i64, parts: *[3]c_int) c_int;
fn date(ctx: *driver.Context, seconds: i64) ![]const u8 {
    if (seconds == 0) return "";
    var parts: [3]c_int = undefined;
    const milliseconds = std.math.mul(i64, seconds, 1000) catch return "";
    if (tachi_date_parts(milliseconds, &parts) == 0) return "";
    return std.fmt.allocPrint(ctx.arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(@max(0, parts[0]))), @as(u32, @intCast(parts[1])), @as(u32, @intCast(parts[2])) });
}
const Manga = struct {
    title_original: []const u8 = "",
    title_ua: ?[]const u8 = null,
    title_en: ?[]const u8 = null,
    chapters: ?i32 = null,
    image: []const u8 = "",
    status: []const u8 = "",
    media_type: ?[]const u8 = null,
    score: f64 = 0,
    slug: []const u8,
    start_date: ?i64 = null,
    read: ?[]const Read = null,
    fn mapped(m: Manga, ctx: *driver.Context) !tracking.Search {
        var out: tracking.Search = .{ .track = .{ .tracker_id = ctx.tracker_id, .remote_id = slugId(m.slug), .title = m.title_ua orelse m.title_en orelse m.title_original, .total_chapters = m.chapters orelse 0, .url = try std.mem.concat(ctx.arena, u8, &.{ "https://hikka.io/manga/", m.slug }), .score = m.score }, .cover_url = m.image, .score = m.score, .publishing_status = m.status, .publishing_type = try std.mem.replaceOwned(u8, ctx.arena, m.media_type orelse "", "_", " "), .start_date = try date(ctx, m.start_date orelse 0) };
        if (m.read) |reads| if (reads.len > 0) {
            out.track = try reads[0].personal(out.track);
            out.score = out.track.score;
        };
        return out;
    }
};
const Read = struct {
    status: []const u8,
    chapters: i32,
    score: f64,
    rereads: i32 = 0,
    start_date: ?i64 = null,
    end_date: ?i64 = null,
    content: ?Manga = null,
    fn personal(r: Read, track: tracking.Track) !tracking.Track {
        var out = track;
        out.status = try localStatus(r.status);
        out.last_chapter_read = @floatFromInt(r.chapters);
        out.score = r.score;
        out.started = (r.start_date orelse 0) * 1000;
        out.finished = (r.end_date orelse 0) * 1000;
        return out;
    }
    fn mapped(r: Read, ctx: *driver.Context) !tracking.Track {
        var track: tracking.Track = .{ .tracker_id = ctx.tracker_id };
        if (r.content) |m| {
            track = (try m.mapped(ctx)).track;
            track.library_id = slugId(m.slug);
        }
        return r.personal(track);
    }
};
fn slug(track: tracking.Track) ![]const u8 {
    const prefix = "https://hikka.io/manga/";
    if (!std.mem.startsWith(u8, track.url, prefix) or track.url.len == prefix.len) return error.InvalidTrackingUrl;
    return track.url[prefix.len..];
}
fn readPath(ctx: *driver.Context, track: tracking.Track) ![]const u8 {
    return std.mem.concat(ctx.arena, u8, &.{ "/read/manga/", try slug(track) });
}
fn manga(ctx: *driver.Context, track: tracking.Track) !Manga {
    return (try checked(try send(ctx, .GET, try std.mem.concat(ctx.arena, u8, &.{ "/manga/", try slug(track) }), .none))).json(Manga, ctx.arena);
}
fn read(ctx: *driver.Context, track: tracking.Track) !?Read {
    const response = try send(ctx, .GET, try readPath(ctx, track), .none);
    if (response.status == .not_found) return null;
    return try (try checked(response)).json(Read, ctx.arena);
}
fn search(ctx: *driver.Context, query: []const u8) ![]const tracking.Search {
    var records: []const Manga = undefined;
    if (std.mem.startsWith(u8, query, "id:")) {
        const response = try send(ctx, .GET, try std.mem.concat(ctx.arena, u8, &.{ "/manga/", std.mem.trim(u8, query[3..], " ") }), .none);
        if (response.status == .not_found) return &.{};
        const one = try ctx.arena.alloc(Manga, 1);
        one[0] = try (try checked(response)).json(Manga, ctx.arena);
        records = one;
    } else {
        const body = try std.json.Stringify.valueAlloc(ctx.arena, .{ .media_type = [_]i32{}, .status = [_]i32{}, .only_translated = false, .magazines = [_]i32{}, .genres = [_]i32{}, .score = [_]i32{ 0, 10 }, .query = query, .sort = [_][]const u8{ "score:desc", "scored_by:desc" } }, .{});
        records = (try (try checked(try send(ctx, .POST, "/manga?page=1&size=50", .{ .json = body }))).json(struct { list: []const Manga }, ctx.arena)).list;
    }
    const out = try ctx.arena.alloc(tracking.Search, records.len);
    for (records, out) |m, *o| o.* = try m.mapped(ctx);
    return out;
}
fn update(ctx: *driver.Context, track: tracking.Track) !tracking.Track {
    if (track.status < 0 or track.status > 5) return error.InvalidStatus;
    const previous = try read(ctx, track);
    var rereads: i32 = if (previous) |r| r.rereads else 0;
    if (track.status == 5 and rereads == 0) rereads = 1;
    const body = try std.json.Stringify.valueAlloc(ctx.arena, .{ .note = "", .chapters = @as(i32, @intFromFloat(@trunc(track.last_chapter_read))), .volumes = @as(i32, 0), .rereads = rereads, .score = @as(i32, @intFromFloat(@trunc(track.score))), .status = states[@intCast(track.status)], .start_date = if (track.started > 0) @as(?i64, @divTrunc(track.started, 1000)) else null, .end_date = if (track.finished > 0) @as(?i64, @divTrunc(track.finished, 1000)) else null }, .{});
    const response = try checked(try send(ctx, .PUT, try readPath(ctx, track), .{ .json = body }));
    return (try response.json(Read, ctx.arena)).mapped(ctx);
}
fn bind(ctx: *driver.Context, track: tracking.Track, has_read: bool) !tracking.Track {
    const previous = try read(ctx, track);
    const remote = (try (try manga(ctx, track)).mapped(ctx)).track;
    var out = track;
    out.status = remote.status;
    out.score = remote.score;
    out.last_chapter_read = remote.last_chapter_read;
    out.started = remote.started;
    out.finished = remote.finished;
    out.remote_id = remote.remote_id;
    out.library_id = remote.library_id;
    if (out.status != 1 and out.status != 5 and has_read) out.status = 0;
    if (previous) |r| {
        // Mihon keeps the manga response's status here, then copies read fields.
        out.score = r.score;
        out.last_chapter_read = @floatFromInt(r.chapters);
        out.started = (r.start_date orelse 0) * 1000;
        out.finished = (r.end_date orelse 0) * 1000;
    } else {
        out.status = if (has_read) 0 else 4;
        out.score = 0;
    }
    return update(ctx, out);
}
fn refresh(ctx: *driver.Context, track: tracking.Track) !tracking.Track {
    const remote = (try (try manga(ctx, track)).mapped(ctx)).track;
    const r = (try read(ctx, track)) orelse return error.TrackNotFound;
    var out = try r.personal(track);
    out.total_chapters = remote.total_chapters;
    return out;
}

test "Hikka reference login, expiration renewal, searches, binds, rereads, dates and delete" {
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
    const book = "{\"slug\":\"title\",\"title_original\":\"Original\",\"title_en\":\"English\",\"title_ua\":\"Українська\",\"chapters\":12,\"media_type\":\"one_shot\",\"status\":\"finished\",\"image\":\"cover\",\"score\":8.1,\"start_date\":1577836800}";
    const reading = "{\"status\":\"reading\",\"chapters\":3,\"score\":7,\"rereads\":0,\"start_date\":1000,\"end_date\":null}";
    const returned = try std.mem.concat(a, u8, &.{ "{\"status\":\"reading\",\"chapters\":3,\"score\":7,\"rereads\":1,\"start_date\":1000,\"content\":", book, "}" });
    const absent = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    var f = try Fixture.init(&.{
        try R(a, "{\"secret\":\"tok\",\"expiration\":4000000000,\"created\":1}"),
        try R(a, "{\"reference\":\"user-ref\",\"username\":\"Name\"}"),
        try R(a, "{}"),
        try R(a, "{\"expiration\":4000000001,\"created\":2}"),
        try R(a, try std.mem.concat(a, u8, &.{ "{\"list\":[", book, "]}" })),
        try R(a, book),
        absent,
        absent,
        try R(a, book),
        absent,
        try R(a, returned),
        try R(a, reading),
        try R(a, book),
        try R(a, reading),
        try R(a, returned),
        try R(a, reading),
        try R(a, returned),
        try R(a, book),
        try R(a, reading),
        try R(a, ""),
    });
    defer f.deinit();
    f.expected = &.{
        &.{ "POST /auth/token", "\"request_reference\":\"reference\"", client_secret },
        &.{ "GET /user/me", "auth: tok" },
        &.{ "GET /user/me", "auth: tok" },
        &.{"GET /auth/token/info"},
        &.{ "POST /manga?page=1&size=50", "\"query\":\"word\"", "\"only_translated\":false", "\"media_type\":[]", "\"status\":[]", "\"magazines\":[]", "\"genres\":[]", "\"score\":[0,10]", "\"sort\":[\"score:desc\",\"scored_by:desc\"]" },
        &.{"GET /manga/title"},
        &.{"GET /manga/missing"},
        &.{"GET /read/manga/title"},
        &.{"GET /manga/title"},
        &.{"GET /read/manga/title"},
        &.{ "PUT /read/manga/title", "\"status\":\"planned\"", "\"score\":0", "\"start_date\":null" },
        &.{"GET /read/manga/title"},
        &.{"GET /manga/title"},
        &.{"GET /read/manga/title"},
        &.{ "PUT /read/manga/title", "\"status\":\"reading\"", "\"chapters\":3", "\"start_date\":1000" },
        &.{"GET /read/manga/title"},
        &.{ "PUT /read/manga/title", "\"rereads\":1", "\"status\":\"reading\"", "\"start_date\":1000", "\"end_date\":2000" },
        &.{"GET /manga/title"},
        &.{"GET /read/manga/title"},
        &.{"DELETE /read/manga/title"},
    };
    try f.start();
    var http: Http = .{ .gpa = t.allocator, .io = t.io };
    defer http.deinit();
    var ctx: driver.Context = .{ .arena = a, .io = t.io, .http = &http, .base_url = try f.url(a, ""), .tracker_id = 10, .credential = .{ .tracker_id = 10 }, .formats = .{}, .host_dir = null };
    try t.expectEqualStrings("https://hikka.io/oauth?reference=598ef1f5-b9d2-4e66-8b65-06949d5e14fc&scope=readlist%2Cread%3Auser-details", (try call(&ctx, .{ .login_url = .{ .redirect_uri = "", .state = "" } })).login_url.?);
    const logged = (try call(&ctx, .{ .login = .{ .username = "", .password = "reference" } })).credential.?;
    try t.expectEqualStrings("user-ref", logged.username);
    try t.expectEqualStrings("Name", logged.display_name);
    ctx.credential.token = "{\"secret\":\"tok\",\"expiration\":1,\"created\":1}";
    const reply = try call(&ctx, .{ .search = "word" });
    try t.expect(std.mem.indexOf(u8, reply.credential.?.token, "4000000001") != null);
    const s = reply.matches[0];
    try t.expectEqualStrings("Українська", s.track.title);
    try t.expectEqualStrings("one shot", s.publishing_type);
    try t.expectEqualStrings(try date(&ctx, 1577836800), s.start_date);
    try t.expectEqual(@as(usize, 10), s.start_date.len);
    try t.expectEqual(@as(f64, 8.1), s.score);
    const track = (try call(&ctx, .{ .search = "id: title" })).matches[0].track;
    try t.expectEqual(slugId("title"), track.remote_id);
    try t.expectEqual(@as(usize, 0), (try call(&ctx, .{ .search = "id:missing" })).matches.len);
    const added = (try call(&ctx, .{ .bind = .{ .track = track, .has_read_chapters = false } })).track.?;
    try t.expectEqual(track.remote_id, added.library_id);
    const bound = (try call(&ctx, .{ .bind = .{ .track = track, .has_read_chapters = true } })).track.?;
    try t.expectEqual(@as(f64, 3), bound.last_chapter_read);
    try t.expectEqual(@as(i64, 1000000), bound.started);
    var changed = bound;
    changed.status = 5;
    changed.finished = 2000000;
    const updated = (try call(&ctx, .{ .update = .{ .track = changed } })).track.?;
    try t.expectEqual(@as(i32, 0), updated.status);
    const fresh = (try call(&ctx, .{ .refresh = track })).track.?;
    try t.expectEqual(@as(i32, 12), fresh.total_chapters);
    try t.expectEqual(@as(f64, 7), fresh.score);
    try t.expectEqual(@as(i64, 1000000), fresh.started);
    _ = try call(&ctx, .{ .delete = fresh });
    try f.finish();
}

test "Hikka Java UUID identity and chapter completion dates" {
    const t = std.testing;
    // MD5('title') starts d5d3db1765287eef; UUID v3 changes byte 6 to 3e.
    try t.expectEqual(@as(i64, 6184527606837690095), slugId("title"));
    var ctx: driver.Context = undefined;
    ctx.io = t.io;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    ctx.arena = arena.allocator();
    try t.expect(std.mem.startsWith(u8, try date(&ctx, -301752000), "1960-06-"));
    const complete = automatic(&ctx, .{ .tracker_id = 10, .total_chapters = 2, .last_chapter_read = 2.9, .status = 5 }, true);
    try t.expectEqual(@as(i32, 1), complete.status);
    try t.expect(complete.finished > 0);
    const reread = automatic(&ctx, .{ .tracker_id = 10, .last_chapter_read = 1, .status = 5 }, true);
    try t.expectEqual(@as(i32, 5), reread.status);
    try t.expectEqual(@as(i64, 0), reread.started);
}

test "Hikka reports expired authorization and missing read records" {
    const Fixture = @import("../testing_http.zig").Fixture;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(&.{
        "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 16\r\nConnection: close\r\n\r\n{\"slug\":\"title\"}",
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    });
    defer f.deinit();
    f.expected = &.{ &.{ "GET /user/me", "auth: old" }, &.{"GET /manga/title"}, &.{"GET /read/manga/title"} };
    try f.start();
    var http: Http = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer http.deinit();
    var ctx: driver.Context = .{ .arena = a, .io = std.testing.io, .http = &http, .base_url = try f.url(a, ""), .tracker_id = 10, .credential = .{ .tracker_id = 10, .username = "user", .password = "old", .token = "{\"secret\":\"old\",\"expiration\":1,\"created\":1}" }, .formats = .{}, .host_dir = null };
    try std.testing.expectError(error.AuthenticationExpired, call(&ctx, .{ .search = "title" }));
    ctx.credential.token = "";
    try std.testing.expectError(error.TrackNotFound, call(&ctx, .{ .refresh = .{ .tracker_id = 10, .url = "https://hikka.io/manga/title" } }));
    try f.finish();
}

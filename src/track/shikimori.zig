//! Shikimori's GraphQL reads and REST user rates, as Mihon uses them.
const std = @import("std");
const driver = @import("driver.zig");
const tracking = @import("../tracking.zig");
const Http = @import("http.zig").Http;
pub const default_base_url = "https://shikimori.io";
const client_id = "PB9dq8DzI405s7wdtwTdirYqHiyVMh--djnP7lBUqSA";
const client_secret = "NajpZcOBKB9sJtgNcejf8OB9jBN1OYYoo-k4h2WWZus";
const redirect = "mihon://shikimori-auth";
const OAuth = struct { access_token: []const u8, created_at: i64, expires_in: i64, refresh_token: ?[]const u8 = null };

pub fn call(ctx: *driver.Context, op: tracking.Operation) !tracking.Reply {
    if (op == .login_url) return .{ .login_url = try std.mem.concat(ctx.arena, u8, &.{ "https://shikimori.io/oauth/authorize?", try Http.form(ctx.arena, &.{ .{ "client_id", client_id }, .{ "redirect_uri", if (op.login_url.redirect_uri.len > 0) op.login_url.redirect_uri else redirect }, .{ "response_type", "code" } }) }) };
    if (op == .login) return login(ctx, op.login.password, op.login.redirect_uri);
    const old_token = ctx.credential.token;
    try refreshToken(ctx);
    var reply: tracking.Reply = switch (op) {
        .search => |q| .{ .matches = try search(ctx, q) },
        .bind => |b| .{ .track = try bind(ctx, b.track, b.has_read_chapters) },
        .refresh => |t| .{ .track = try refresh(ctx, t) },
        .update => |u| .{ .track = try update(ctx, if (u.did_read_chapter) tracking.didRead(u.track, now(ctx) * 1000) else u.track, false) },
        .delete => |t| blk: {
            _ = try checked(try send(ctx, .DELETE, try std.fmt.allocPrint(ctx.arena, "/api/v2/user_rates/{d}", .{t.library_id}), .none));
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
fn endpoint(ctx: *driver.Context, path: []const u8) ![]const u8 {
    return std.mem.concat(ctx.arena, u8, &.{ ctx.base_url, path });
}
fn checked(r: Http.Response) !Http.Response {
    if (!r.ok()) return error.TrackerRequestFailed;
    return r;
}
fn send(ctx: *driver.Context, method: std.http.Method, path: []const u8, body: Http.Body) !Http.Response {
    if (ctx.credential.password.len == 0) return error.NotAuthenticated;
    return ctx.http.send(ctx.arena, method, try endpoint(ctx, path), &.{ .{ .name = "Authorization", .value = try std.fmt.allocPrint(ctx.arena, "Bearer {s}", .{ctx.credential.password}) }, .{ .name = "User-Agent", .value = "Mihon v0.21.2 (app.mihon)" } }, body);
}
fn tokenUrl(ctx: *driver.Context) ![]const u8 {
    return endpoint(ctx, "/oauth/token");
}
fn saveToken(ctx: *driver.Context, value: OAuth) !void {
    const token = value;
    ctx.credential.password = token.access_token;
    ctx.credential.token = try std.json.Stringify.valueAlloc(ctx.arena, token, .{});
    ctx.credential.auth_expired = false;
}
fn refreshToken(ctx: *driver.Context) !void {
    if (ctx.credential.token.len == 0) return;
    const token = try std.json.parseFromSliceLeaky(OAuth, ctx.arena, ctx.credential.token, .{ .ignore_unknown_fields = true });
    if (now(ctx) + 3600 <= token.created_at + token.expires_in) return;
    const body = try Http.form(ctx.arena, &.{ .{ "grant_type", "refresh_token" }, .{ "client_id", client_id }, .{ "client_secret", client_secret }, .{ "refresh_token", token.refresh_token orelse return error.AuthenticationExpired } });
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
    const data = try checked(try graphql(ctx, "query ShikimoriGetCurrentUser { currentUser { id nickname } }", .{}));
    const user = (try data.json(struct { data: struct { currentUser: ?struct { id: []const u8, nickname: []const u8 } } }, ctx.arena)).data.currentUser orelse return error.InvalidTrackerResponse;
    ctx.credential.username = user.id;
    ctx.credential.display_name = user.nickname;
    return .{ .credential = ctx.credential };
}
fn graphql(ctx: *driver.Context, query: []const u8, variables: anytype) !Http.Response {
    const body = try std.json.Stringify.valueAlloc(ctx.arena, .{ .query = query, .variables = variables }, .{});
    return send(ctx, .POST, "/api/graphql", .{ .json = body });
}
const states = [_][]const u8{ "", "watching", "completed", "on_hold", "dropped", "planned", "rewatching" };
fn localStatus(value: []const u8) !i32 {
    for (states, 0..) |s, i| if (i > 0 and std.mem.eql(u8, s, value)) return @intCast(i);
    return error.InvalidStatus;
}
const Manga = struct {
    id: []const u8,
    name: []const u8,
    chapters: i32 = 0,
    url: []const u8 = "",
    kind: ?[]const u8 = null,
    status: ?[]const u8 = null,
    poster: ?struct { mainUrl: []const u8 = "" } = null,
    description: ?[]const u8 = null,
    score: ?f64 = null,
    airedOn: ?struct { date: ?[]const u8 = null } = null,
    personRoles: ?[]const struct { rolesEn: []const []const u8, person: struct { name: []const u8 } } = null,
    userRate: ?struct { id: []const u8, chapters: i32, score: f64, status: []const u8 } = null,
    fn mapped(m: Manga, ctx: *driver.Context) !tracking.Search {
        var authors: std.ArrayList([]const u8) = .empty;
        var artists: std.ArrayList([]const u8) = .empty;
        for (m.personRoles orelse &.{}) |r| {
            for (r.rolesEn) |role| {
                if (std.mem.eql(u8, role, "Story")) try authors.append(ctx.arena, r.person.name);
                if (std.mem.eql(u8, role, "Art")) try artists.append(ctx.arena, r.person.name);
            }
        }
        return .{ .track = .{ .tracker_id = ctx.tracker_id, .remote_id = try std.fmt.parseInt(i64, m.id, 10), .title = m.name, .total_chapters = m.chapters, .url = m.url }, .cover_url = if (m.poster) |v| v.mainUrl else "", .summary = m.description orelse "", .score = if (m.score) |s| if (s > 0) s else -1 else -1, .publishing_type = mappedText(m.kind, &.{ "manga", "manhwa", "manhua", "one_shot", "doujin" }, &.{ "Manga", "Manhwa", "Manhua", "Oneshot", "Doujin" }), .publishing_status = mappedText(m.status, &.{ "anons", "ongoing", "released", "paused", "discontinued" }, &.{ "Planned", "Ongoing", "Released", "Paused", "Discontinued" }), .start_date = if (m.airedOn) |v| v.date orelse "" else "", .authors = authors.items, .artists = artists.items };
    }
};
fn mappedText(value: ?[]const u8, keys: []const []const u8, values: []const []const u8) []const u8 {
    for (keys, values) |k, v| if (std.mem.eql(u8, value orelse "", k)) return v;
    return "";
}
const fragment = "fragment MangaFragment on Manga { id name chapters kind poster { mainUrl } score url status airedOn { date } description personRoles { person { name } rolesEn } }";
fn search(ctx: *driver.Context, query: []const u8) ![]const tracking.Search {
    const id = if (std.mem.startsWith(u8, query, "id:")) std.fmt.parseInt(i32, std.mem.trim(u8, query[3..], " "), 10) catch null else null;
    const response = if (id) |n|
        try graphql(ctx, "query ShikimoriGetMangaDetails($query: String!) { mangas(ids: $query, limit: 1, kind: \"!light_novel,!novel\") { ...MangaFragment } } " ++ fragment, .{ .query = try std.fmt.allocPrint(ctx.arena, "{d}", .{n}) })
    else
        try graphql(ctx, "query ShikimoriSearchManga($search: String!) { mangas(search: $search, limit: 20, kind: \"!light_novel,!novel\") { ...MangaFragment } } " ++ fragment, .{ .search = query });
    if (!response.ok()) return &.{};
    const result = (try response.json(struct { data: ?struct { mangas: []const Manga } = null }, ctx.arena)).data orelse return &.{};
    const out = try ctx.arena.alloc(tracking.Search, result.mangas.len);
    for (result.mangas, out) |m, *o| o.* = try m.mapped(ctx);
    return out;
}
fn find(ctx: *driver.Context, track: tracking.Track) !?Manga {
    const response = try graphql(ctx, "query ShikimoriGetLibManga($remote_id: String!) { mangas(ids: $remote_id, limit: 1) { id url name chapters userRate { id chapters status score } } }", .{ .remote_id = try std.fmt.allocPrint(ctx.arena, "{d}", .{track.remote_id}) });
    if (!response.ok()) return null;
    const result = (try response.json(struct { data: ?struct { mangas: []const Manga } = null }, ctx.arena)).data orelse return null;
    if (result.mangas.len == 0 or result.mangas[0].userRate == null) return null;
    return result.mangas[0];
}
fn personal(track: tracking.Track, manga: Manga) !tracking.Track {
    var out = track;
    const rate = manga.userRate.?;
    out.library_id = try std.fmt.parseInt(i64, rate.id, 10);
    out.last_chapter_read = @floatFromInt(rate.chapters);
    out.score = rate.score;
    out.status = try localStatus(rate.status);
    return out;
}
fn refresh(ctx: *driver.Context, track: tracking.Track) !tracking.Track {
    const manga = (try find(ctx, track)) orelse return error.TrackNotFound;
    var out = try personal(track, manga);
    out.total_chapters = manga.chapters;
    return out;
}
fn update(ctx: *driver.Context, track: tracking.Track, add: bool) !tracking.Track {
    if (track.status < 1 or track.status > 6) return error.InvalidStatus;
    const Rate = struct { user_id: ?[]const u8 = null, target_id: ?i64 = null, target_type: ?[]const u8 = null, chapters: i32, score: i32, status: []const u8 };
    const body = try std.json.Stringify.valueAlloc(ctx.arena, .{ .user_rate = Rate{ .user_id = if (add) ctx.credential.username else null, .target_id = if (add) track.remote_id else null, .target_type = if (add) "Manga" else null, .chapters = @intFromFloat(@trunc(track.last_chapter_read)), .score = @intFromFloat(@trunc(track.score)), .status = states[@intCast(track.status)] } }, .{ .emit_null_optional_fields = false });
    const path = if (add) "/api/v2/user_rates" else try std.fmt.allocPrint(ctx.arena, "/api/v2/user_rates/{d}", .{track.library_id});
    const response = try checked(try send(ctx, if (add) .POST else .PUT, path, .{ .json = body }));
    var out = track;
    out.library_id = (try response.json(struct { id: i64 }, ctx.arena)).id;
    return out;
}
fn bind(ctx: *driver.Context, track: tracking.Track, has_read: bool) !tracking.Track {
    if (try find(ctx, track)) |m| {
        var out = try personal(track, m);
        if (out.status != 2 and out.status != 6 and has_read) out.status = 1;
        return update(ctx, out, false);
    }
    var out = track;
    out.status = if (has_read) 1 else 5;
    out.score = 0;
    return update(ctx, out, true);
}

test "Shikimori OAuth refresh, GraphQL mappings, both binds, update, refresh and delete" {
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
    const found = "{\"data\":{\"mangas\":[{\"id\":\"9\",\"name\":\"Title\",\"chapters\":12,\"kind\":\"one_shot\",\"status\":\"released\",\"poster\":{\"mainUrl\":\"cover\"},\"description\":\"summary\",\"score\":8.3,\"airedOn\":{\"date\":\"2020-01-01\"},\"personRoles\":[{\"person\":{\"name\":\"Author\"},\"rolesEn\":[\"Story\",\"Art\"]}]}]}}";
    const entry = "{\"data\":{\"mangas\":[{\"id\":\"9\",\"name\":\"Title\",\"chapters\":15,\"userRate\":{\"id\":\"71\",\"chapters\":3,\"score\":7,\"status\":\"rewatching\"}}]}}";
    var f = try Fixture.init(&.{
        try R(a, "{\"access_token\":\"old\",\"created_at\":1,\"expires_in\":1,\"refresh_token\":\"r\"}"),
        try R(a, "{\"data\":{\"currentUser\":{\"id\":\"42\",\"nickname\":\"Name\"}}}"),
        try R(a, "{\"access_token\":\"new\",\"created_at\":4000000000,\"expires_in\":7200,\"refresh_token\":\"r2\"}"),
        try R(a, found),
        try R(a, found),
        try R(a, "{\"data\":{\"mangas\":[{\"id\":\"9\",\"name\":\"Title\",\"userRate\":null}]}}"),
        try R(a, "{\"id\":71}"),
        try R(a, entry),
        try R(a, "{\"id\":71}"),
        try R(a, "{\"id\":71}"),
        try R(a, entry),
        try R(a, ""),
    });
    defer f.deinit();
    f.expected = &.{
        &.{ "POST /oauth/token", "grant_type=authorization_code", "code=code" },
        &.{ "POST /api/graphql", "Bearer old", "ShikimoriGetCurrentUser" },
        &.{ "grant_type=refresh_token", "refresh_token=r" },
        &.{ "Bearer new", "ShikimoriSearchManga", "!light_novel,!novel", "\"search\":\"word\"" },
        &.{ "ShikimoriGetMangaDetails", "\"query\":\"9\"" },
        &.{ "ShikimoriGetLibManga", "\"remote_id\":\"9\"" },
        &.{ "POST /api/v2/user_rates", "\"user_id\":\"42\"", "\"target_type\":\"Manga\"", "\"status\":\"planned\"" },
        &.{"ShikimoriGetLibManga"},
        &.{ "PUT /api/v2/user_rates/71", "\"status\":\"rewatching\"", "\"chapters\":3" },
        &.{ "PUT /api/v2/user_rates/71", "\"status\":\"completed\"", "\"chapters\":12" },
        &.{"ShikimoriGetLibManga"},
        &.{"DELETE /api/v2/user_rates/71"},
    };
    try f.start();
    var http: Http = .{ .gpa = t.allocator, .io = t.io };
    defer http.deinit();
    var ctx: driver.Context = .{ .arena = a, .io = t.io, .http = &http, .base_url = try f.url(a, ""), .tracker_id = 4, .credential = .{ .tracker_id = 4 }, .formats = .{}, .host_dir = null };
    try t.expect(std.mem.indexOf(u8, (try call(&ctx, .{ .login_url = .{ .redirect_uri = "", .state = "" } })).login_url.?, "response_type=code") != null);
    const logged = (try call(&ctx, .{ .login = .{ .username = "", .password = "code" } })).credential.?;
    try t.expectEqualStrings("42", logged.username);
    try t.expectEqualStrings("Name", logged.display_name);
    const reply = try call(&ctx, .{ .search = "word" });
    try t.expectEqualStrings("new", reply.credential.?.password);
    const s = reply.matches[0];
    try t.expectEqualStrings("Oneshot", s.publishing_type);
    try t.expectEqualStrings("Released", s.publishing_status);
    try t.expectEqualStrings("Author", s.authors[0]);
    try t.expectEqualStrings("Author", s.artists[0]);
    try t.expectEqualStrings("cover", s.cover_url);
    try t.expectEqual(@as(f64, 8.3), s.score);
    const track = (try call(&ctx, .{ .search = "id:9" })).matches[0].track;
    const added = (try call(&ctx, .{ .bind = .{ .track = track, .has_read_chapters = false } })).track.?;
    try t.expectEqual(@as(i64, 71), added.library_id);
    try t.expectEqual(@as(i32, 5), added.status);
    const bound = (try call(&ctx, .{ .bind = .{ .track = track, .has_read_chapters = true } })).track.?;
    try t.expectEqual(@as(i32, 6), bound.status);
    var changed = bound;
    changed.last_chapter_read = 12.9;
    const updated = (try call(&ctx, .{ .update = .{ .track = changed, .did_read_chapter = true } })).track.?;
    try t.expectEqual(@as(i32, 2), updated.status);
    const fresh = (try call(&ctx, .{ .refresh = track })).track.?;
    try t.expectEqual(@as(i32, 15), fresh.total_chapters);
    try t.expectEqual(@as(f64, 7), fresh.score);
    _ = try call(&ctx, .{ .delete = fresh });
    try f.finish();
}

test "Shikimori handles GraphQL errors, missing rates and rejected token refresh" {
    const Fixture = @import("../testing_http.zig").Fixture;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try Fixture.init(&.{
        "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: close\r\n\r\n{\"data\":null}",
        "HTTP/1.1 200 OK\r\nContent-Length: 22\r\nConnection: close\r\n\r\n{\"data\":{\"mangas\":[]}}",
        "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
    });
    defer f.deinit();
    f.expected = &.{ &.{"grant_type=refresh_token"}, &.{ "Bearer old", "ShikimoriSearchManga", "\"search\":\"id:invalid\"" }, &.{"ShikimoriGetLibManga"}, &.{"ShikimoriGetMangaDetails"}, &.{"DELETE /api/v2/user_rates/71"} };
    try f.start();
    var http: Http = .{ .gpa = std.testing.allocator, .io = std.testing.io };
    defer http.deinit();
    var ctx: driver.Context = .{ .arena = a, .io = std.testing.io, .http = &http, .base_url = try f.url(a, ""), .tracker_id = 4, .credential = .{ .tracker_id = 4, .username = "user", .password = "old", .token = "{\"access_token\":\"old\",\"created_at\":1,\"expires_in\":1,\"refresh_token\":\"r\"}" }, .formats = .{}, .host_dir = null };
    const result = try call(&ctx, .{ .search = "id:invalid" });
    try std.testing.expectEqual(@as(usize, 0), result.matches.len);
    try std.testing.expect(result.credential == null);
    ctx.credential.token = "";
    try std.testing.expectError(error.TrackNotFound, call(&ctx, .{ .refresh = .{ .tracker_id = 4, .remote_id = 9 } }));
    try std.testing.expectEqual(@as(usize, 0), (try call(&ctx, .{ .search = "id:9" })).matches.len);
    try std.testing.expectError(error.AuthenticationExpired, call(&ctx, .{ .delete = .{ .tracker_id = 4, .library_id = 71 } }));
    try f.finish();
}

//! Suwayomi GraphQL progress using Tachidesk's server settings.
const std = @import("std");
const driver = @import("driver.zig");
const tracking = @import("../tracking.zig");
const enhanced = @import("enhanced.zig");
pub const default_base_url = "";

const manga_query = "query SuwayomiGetManga($mangaId:Int!){manga(id:$mangaId){id title description status thumbnailUrl chapters{totalCount} latestReadChapter{chapterNumber} unreadCount}}";
const unread_query = "query SuwayomiGetMangaUnreadChapters($mangaId:Int!,$chapterNumber:Float!){chapters(condition:{mangaId:$mangaId,isRead:false},filter:{and:[{chapterNumber:{lessThanOrEqualTo:$chapterNumber}},{chapterNumber:{greaterThan:0}}]}){nodes{id chapterNumber}}}";
const mark_query = "mutation SuwayomiMarkChaptersRead($chapters:[Int!]!){updateChapters(input:{ids:$chapters,patch:{isRead:true}}){__typename}}";
const delete_query = "mutation SuwayomiMarkAndDeleteChapters($chapters:[Int!]!){updateChapters(input:{ids:$chapters,patch:{isRead:true}}){__typename} deleteDownloadedChapters(input:{ids:$chapters}){__typename}}";
const progress_query = "mutation SuwayomiUpdateMangaProgress($mangaId:Int!){trackProgress(input:{mangaId:$mangaId}){__typename}}";

pub fn call(ctx: *driver.Context, op: tracking.Operation) !tracking.Reply {
    return switch (op) {
        .login_url => error.PasswordLogin,
        .login => enhanced.login(9),
        .search => |url| .{ .matches = try match(ctx, url) },
        .bind => |b| .{ .track = b.track },
        .refresh => |t| blk: {
            const session = try Session.init(ctx, t.url);
            break :blk .{ .track = enhanced.personal(t, (try session.fetch(ctx, t.remote_id)).track) };
        },
        .update => |u| blk: {
            if (!std.math.isFinite(u.track.last_chapter_read) or u.track.last_chapter_read < 0) return error.InvalidProgress;
            const session = try Session.init(ctx, u.track.url);
            const Unread = struct { chapters: struct { nodes: []const struct { id: i32 } } };
            const unread = try session.graphql(ctx, Unread, unread_query, .{ .mangaId = u.track.remote_id, .chapterNumber = u.track.last_chapter_read });
            if (unread.chapters.nodes.len > 0) {
                const ids = try ctx.arena.alloc(i32, unread.chapters.nodes.len);
                for (unread.chapters.nodes, ids) |node, *id| id.* = node.id;
                _ = try session.graphql(ctx, std.json.Value, if (session.delete_downloads) delete_query else mark_query, .{ .chapters = ids });
                _ = try session.graphql(ctx, std.json.Value, progress_query, .{ .mangaId = u.track.remote_id });
            }
            break :blk .{ .track = (try session.fetch(ctx, u.track.remote_id)).track };
        },
        .delete => error.UnsupportedDelete,
    };
}

pub fn match(ctx: *driver.Context, url: []const u8) ![]const tracking.Search {
    const id = enhanced.lastId(url) catch return error.UnsupportedSearch;
    const session = try Session.init(ctx, url);
    const out = try ctx.arena.alloc(tracking.Search, 1);
    out[0] = try session.fetch(ctx, id);
    return out;
}

const Session = struct {
    base: []const u8,
    headers: []const std.http.Header,
    delete_downloads: bool,

    fn init(ctx: *driver.Context, url: []const u8) !Session {
        const prefs = if (std.mem.indexOfScalar(u8, url, '/') == null)
            try enhanced.tachideskSettings(ctx)
        else
            try enhanced.settings(ctx, url, "Server URL Address");
        const base = enhanced.trim(enhanced.string(prefs, "Server URL Address"));
        if (base.len == 0) return error.SourceNotConfigured;
        var headers: std.ArrayList(std.http.Header) = .empty;
        const mode = enhanced.string(prefs, "Login Mode");
        const user = enhanced.string(prefs, "Login (Basic Auth)");
        const pass = enhanced.string(prefs, "Password (Basic Auth)");
        if (std.mem.eql(u8, mode, "BASIC_AUTH") or (mode.len == 0 and user.len > 0 and pass.len > 0)) {
            try headers.append(ctx.arena, .{ .name = "Authorization", .value = try enhanced.basic(ctx, user, pass) });
        } else if (std.mem.eql(u8, mode, "SIMPLE_LOGIN")) {
            const body = try @import("http.zig").Http.form(ctx.arena, &.{ .{ "user", user }, .{ "pass", pass } });
            const cookies = try ctx.http.loginCookies(ctx.arena, try std.mem.concat(ctx.arena, u8, &.{ base, "/login.html" }), body);
            try headers.append(ctx.arena, .{ .name = "Cookie", .value = cookies });
        } else if (std.mem.eql(u8, mode, "UI_LOGIN")) {
            const body = try std.json.Stringify.valueAlloc(ctx.arena, .{ .query = "mutation Login($username:String!,$password:String!){login(input:{username:$username,password:$password}){accessToken refreshToken}}", .variables = .{ .username = user, .password = pass } }, .{});
            const response = try ctx.http.sendPrivate(ctx.arena, .POST, try std.mem.concat(ctx.arena, u8, &.{ base, "/api/graphql" }), &.{}, .{ .json = body });
            try enhanced.expectOk(response);
            const auth = try response.json(struct { data: ?struct { login: struct { accessToken: []const u8 } } = null }, ctx.arena);
            const token = (auth.data orelse return error.AuthenticationExpired).login.accessToken;
            try headers.append(ctx.arena, .{ .name = "Authorization", .value = try std.mem.concat(ctx.arena, u8, &.{ "Bearer ", token }) });
        } else if (mode.len > 0 and !std.mem.eql(u8, mode, "NONE")) return error.UnsupportedAuthenticationMode;
        var lines = std.mem.splitScalar(u8, enhanced.string(prefs, "Custom HTTP headers"), '\n');
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t\r");
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
            if (name.len == 0 or std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidSourceSettings;
            for (name) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "!#$%&'*+-.^_`|~", c) == null) return error.InvalidSourceSettings;
            // Custom headers override the extension's authentication headers.
            for (headers.items) |*h| {
                if (std.ascii.eqlIgnoreCase(h.name, name)) {
                    h.value = value;
                    break;
                }
            } else try headers.append(ctx.arena, .{ .name = name, .value = value });
        }
        return .{ .base = base, .headers = headers.items, .delete_downloads = enhanced.boolean(prefs, "Tracker Delete") };
    }

    fn graphql(self: Session, ctx: *driver.Context, comptime T: type, query: []const u8, variables: anytype) !T {
        const body = try std.json.Stringify.valueAlloc(ctx.arena, .{ .query = query, .variables = variables }, .{});
        const response = try ctx.http.sendPrivate(ctx.arena, .POST, try std.mem.concat(ctx.arena, u8, &.{ self.base, "/api/graphql" }), self.headers, .{ .json = body });
        try enhanced.expectOk(response);
        const envelope = try response.json(struct { data: ?T = null, errors: []const struct { message: []const u8 = "" } = &.{} }, ctx.arena);
        if (envelope.errors.len > 0) {
            for (envelope.errors) |err| if (std.mem.indexOf(u8, err.message, "Unauthorized") != null) return error.AuthenticationExpired;
            return error.TrackerRequestFailed;
        }
        return envelope.data orelse error.InvalidTrackerResponse;
    }

    fn fetch(self: Session, ctx: *driver.Context, id: i64) !tracking.Search {
        const Manga = struct { id: i64, title: []const u8, description: ?[]const u8 = null, status: []const u8 = "", thumbnailUrl: []const u8 = "", chapters: struct { totalCount: i32 }, latestReadChapter: ?struct { chapterNumber: f64 } = null, unreadCount: i32 };
        const result = try self.graphql(ctx, struct { manga: ?Manga = null }, manga_query, .{ .mangaId = id });
        const m = result.manga orelse return error.TrackNotFound;
        return .{ .track = .{ .tracker_id = 9, .remote_id = m.id, .title = m.title, .url = try std.fmt.allocPrint(ctx.arena, "{s}/manga/{d}", .{ self.base, m.id }), .total_chapters = m.chapters.totalCount, .last_chapter_read = if (m.latestReadChapter) |ch| ch.chapterNumber else 0, .status = if (m.unreadCount == m.chapters.totalCount) 1 else if (m.unreadCount == 0) 3 else 2 }, .cover_url = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{ self.base, m.thumbnailUrl }), .summary = m.description orelse "", .publishing_status = m.status };
    }
};

test "Suwayomi matches, marks unread chapters, optionally deletes downloads and refreshes" {
    const test_http = @import("testing_enhanced.zig");
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const manga = "{\"data\":{\"manga\":{\"id\":12,\"title\":\"Suwayomi manga\",\"description\":\"About\",\"status\":\"ONGOING\",\"thumbnailUrl\":\"cover\",\"chapters\":{\"totalCount\":6},\"latestReadChapter\":{\"chapterNumber\":2.5},\"unreadCount\":3}}}";
    const unread = "{\"data\":{\"chapters\":{\"nodes\":[{\"id\":42}]}}}";
    var fixture = try test_http.Fixture.init(&.{
        try test_http.ok(a, manga),
        try test_http.ok(a, unread),
        try test_http.ok(a, "{\"data\":{}}"),
        try test_http.ok(a, "{\"data\":{}}"),
        try test_http.ok(a, manga),
        try test_http.ok(a, manga),
        try test_http.ok(a, "{\"data\":{\"chapters\":{\"nodes\":[]}}}"),
        try test_http.ok(a, manga),
        try test_http.ok(a, unread),
        try test_http.ok(a, "{\"data\":{}}"),
        try test_http.ok(a, "{\"data\":{}}"),
        try test_http.ok(a, manga),
        try test_http.ok(a, "{\"errors\":[{\"message\":\"Unauthorized\"}]}"),
    });
    defer fixture.deinit();
    fixture.expected = &.{
        &.{ "POST /api/graphql ", "Authorization: Basic dTpw", "SuwayomiGetManga", "\"mangaId\":12", "X-Test: custom" },
        &.{ "SuwayomiGetMangaUnreadChapters", "lessThanOrEqualTo", "greaterThan:0", "\"chapterNumber\":2.5" },
        &.{ "SuwayomiMarkAndDeleteChapters", "deleteDownloadedChapters", "\"chapters\":[42]" },
        &.{"SuwayomiUpdateMangaProgress"},
        &.{},
        &.{},
        &.{},
        &.{},
        &.{},
        &.{"SuwayomiMarkChaptersRead"},
        &.{},
        &.{},
        &.{},
    };
    try fixture.start();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try fixture.url(a, "");
    const values = .{ .@"Server URL Address" = .{ .t = "s", .v = base }, .@"Login (Basic Auth)" = .{ .t = "s", .v = "u" }, .@"Password (Basic Auth)" = .{ .t = "s", .v = "p" }, .@"Tracker Delete" = @as(struct { t: []const u8, v: bool }, .{ .t = "b", .v = true }), .@"Custom HTTP headers" = .{ .t = "s", .v = "X-Test: custom" } };
    const host = try test_http.prefs(a, tmp.dir, 888, values);
    var http: @import("http.zig").Http = .{ .gpa = t.allocator, .io = t.io };
    defer http.deinit();
    var ctx = test_http.context(a, &http, 9, host);
    try test_http.common(&ctx, @This());
    const result = (try call(&ctx, .{ .search = try fixture.url(a, "/manga/12") })).matches[0];
    try t.expectEqual(@as(i32, 6), result.track.total_chapters);
    try t.expectEqual(@as(f64, 2.5), result.track.last_chapter_read);
    try t.expectEqual(@as(i32, 2), result.track.status);
    try t.expectEqualStrings("About", result.summary);
    _ = try call(&ctx, .{ .update = .{ .track = result.track } });
    _ = try call(&ctx, .{ .refresh = result.track });
    _ = try call(&ctx, .{ .update = .{ .track = result.track } });
    const without_delete = try std.mem.replaceOwned(u8, a, try std.json.Stringify.valueAlloc(a, values, .{}), "\"v\":true", "\"v\":false");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "prefs/source_888.json", .data = without_delete });
    _ = try call(&ctx, .{ .update = .{ .track = result.track } });
    try t.expectError(error.AuthenticationExpired, call(&ctx, .{ .refresh = result.track }));
    try fixture.finish();
}

test "Suwayomi authenticates simple and UI login from extension settings" {
    const test_http = @import("testing_enhanced.zig");
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const manga = "{\"data\":{\"manga\":{\"id\":3,\"title\":\"M\",\"chapters\":{\"totalCount\":0},\"unreadCount\":0}}}";
    var fixture = try test_http.Fixture.init(&.{
        "HTTP/1.1 302 Found\r\nSet-Cookie: session=abc; HttpOnly; Path=/\r\nSet-Cookie: other=def; Path=/\r\nLocation: /\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        try test_http.ok(a, manga),
        try test_http.ok(a, "{\"data\":{\"login\":{\"accessToken\":\"token\"}}}"),
        try test_http.ok(a, manga),
    });
    defer fixture.deinit();
    fixture.expected = &.{
        &.{ "POST /login.html ", "user=u&pass=p" },                         &.{"Cookie: session=abc; other=def"},
        &.{ "mutation Login", "\"username\":\"u\"", "\"password\":\"p\"" }, &.{"Authorization: Bearer token"},
    };
    try fixture.start();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try fixture.url(a, "");
    const values = .{ .@"Server URL Address" = .{ .t = "s", .v = base }, .@"Login Mode" = .{ .t = "s", .v = "SIMPLE_LOGIN" }, .@"Login (Basic Auth)" = .{ .t = "s", .v = "u" }, .@"Password (Basic Auth)" = .{ .t = "s", .v = "p" } };
    const host = try test_http.prefs(a, tmp.dir, 888, values);
    var http: @import("http.zig").Http = .{ .gpa = t.allocator, .io = t.io };
    defer http.deinit();
    var ctx = test_http.context(a, &http, 9, host);
    const url = try fixture.url(a, "/manga/3");
    const simple = (try call(&ctx, .{ .search = url })).matches[0].track;
    // Empty libraries are unread (unread comparison precedes completed).
    try t.expectEqual(@as(i32, 1), simple.status);
    try t.expectEqual(@as(f64, 0), simple.last_chapter_read);
    const ui = try std.mem.replaceOwned(u8, a, try std.json.Stringify.valueAlloc(a, values, .{}), "SIMPLE_LOGIN", "UI_LOGIN");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "prefs/source_888.json", .data = ui });
    _ = try call(&ctx, .{ .search = url });
    try fixture.finish();
}

test "Suwayomi resolves a bare manga id through Tachidesk's retained source id" {
    const test_http = @import("testing_enhanced.zig");
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = try test_http.Fixture.init(&.{try test_http.ok(a, "{\"data\":{\"manga\":{\"id\":12,\"title\":\"M\",\"chapters\":{\"totalCount\":6},\"latestReadChapter\":{\"chapterNumber\":6},\"unreadCount\":0}}}")});
    defer fixture.deinit();
    fixture.expected = &.{&.{"\"mangaId\":12"}};
    try fixture.start();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const base = try fixture.url(a, "");
    const host = try test_http.prefs(a, tmp.dir, 3100117499901280806, .{ .@"Server URL Address" = .{ .t = "s", .v = base } });
    var http: @import("http.zig").Http = .{ .gpa = t.allocator, .io = t.io };
    defer http.deinit();
    var ctx = test_http.context(a, &http, 9, host);
    const track = (try call(&ctx, .{ .search = "12" })).matches[0].track;
    try t.expectEqual(@as(i32, 3), track.status);
    try t.expectEqualStrings(try fixture.url(a, "/manga/12"), track.url);
    try fixture.finish();
}

//! Kitsu's password grant and GraphQL library (Mihon 487c313).
const std = @import("std");
const driver = @import("driver.zig");
const tracking = @import("../tracking.zig");
const Http = @import("http.zig").Http;
const c = @import("oauth_common.zig");
const f = c.field;
const s = c.string;
const n = c.integer;
const fragment = @embedFile("graphql/KitsuMangaFragment.graphql");
pub const default_base_url = "https://kitsu.app";
const statuses = [_][]const u8{ "", "CURRENT", "COMPLETED", "ON_HOLD", "DROPPED", "PLANNED" };

pub fn call(ctx: *driver.Context, op: tracking.Operation) !tracking.Reply {
    switch (op) {
        .login_url => return error.PasswordLogin,
        .login => |l| {
            const body = try Http.form(ctx.arena, &.{ .{ "username", l.username }, .{ "password", l.password }, .{ "grant_type", "password" }, .{ "client_id", c.kitsu_client }, .{ "client_secret", c.kitsu_secret } });
            ctx.credential = .{ .tracker_id = 3, .username = "pending" };
            try c.saveToken(ctx, try ctx.http.send(ctx.arena, .POST, try c.tokenUrl(ctx), &.{}, .{ .form = body }));
            const account = f(try gql(ctx, @embedFile("graphql/KitsuGetCurrentAccount.graphql"), .{}), "currentAccount");
            if (s(f(account, "id")).len == 0) return error.InvalidTrackerResponse;
            ctx.credential.username = s(f(account, "id"));
            ctx.credential.display_name = s(f(f(account, "profile"), "name"));
            const format = try std.ascii.allocLowerString(ctx.arena, s(f(account, "ratingSystem")));
            return .{ .credential = ctx.credential, .kitsu_score_type = std.meta.stringToEnum(tracking.KitsuScore, format) orelse .advanced };
        },
        else => {},
    }
    const renewed = try c.prepare(ctx);
    var reply: tracking.Reply = switch (op) {
        .search => |q| .{ .matches = search(ctx, q) catch |err| switch (err) {
            error.GraphqlResponseErrors => &.{},
            else => return err,
        } },
        .bind => |b| blk: {
            var out = b.track;
            if (try find(ctx, out)) |remote| {
                out = c.personal(out, remote, false);
                out.library_id = remote.library_id;
                if (out.status != 2 and b.has_read_chapters) out.status = 1;
                out = try write(ctx, out, false);
            } else {
                out.status = if (b.has_read_chapters) 1 else 5;
                out.score = 0;
                out = try write(ctx, out, true);
            }
            break :blk .{ .track = out };
        },
        .update => |u| .{ .track = try write(ctx, if (u.did_read_chapter) tracking.didRead(u.track, c.now(ctx)) else u.track, false) },
        .refresh => |t| blk: {
            const remote = (try find(ctx, t)) orelse return error.TrackNotFound;
            var out = c.personal(t, remote, true);
            out.total_chapters = remote.total_chapters;
            break :blk .{ .track = out };
        },
        .delete => |t| blk: {
            if (t.library_id == 0) return error.TrackNotFound;
            const query = @embedFile("graphql/KitsuDeleteLibEntry.graphql");
            const body = try c.json(ctx, .{ .query = query, .variables = .{ .library_id = try std.fmt.allocPrint(ctx.arena, "{d}", .{t.library_id}) } });
            const response = try c.send(ctx, .POST, try graphqlUrl(ctx), .{ .json = body });
            if (@backingInt(response.status) == 500 and std.mem.indexOf(u8, response.body, "Couldn't find LibraryEntry with 'id'=") != null) break :blk .{};
            try c.ok(response);
            break :blk .{};
        },
        else => unreachable,
    };
    if (renewed) reply.credential = ctx.credential;
    return reply;
}
fn graphqlUrl(ctx: *driver.Context) ![]const u8 {
    return std.mem.concat(ctx.arena, u8, &.{ ctx.base_url, "/api/graphql" });
}
fn gql(ctx: *driver.Context, query: []const u8, variables: anytype) !c.Value {
    return c.graphql(ctx, try graphqlUrl(ctx), query, variables);
}
fn apiStatus(status: i32) ![]const u8 {
    if (status < 1 or status > 5) return error.InvalidStatus;
    return statuses[@intCast(status)];
}
fn search(ctx: *driver.Context, query: []const u8) ![]const tracking.Search {
    var list: std.ArrayList(tracking.Search) = .empty;
    if (std.mem.startsWith(u8, query, "id:")) {
        const text = std.mem.trim(u8, query[3..], " \t\r\n");
        const numeric = text.len > 0 and for (text) |ch| {
            if (!std.ascii.isDigit(ch)) break false;
        } else true;
        const data = if (numeric) try gql(ctx, @embedFile("graphql/KitsuGetMangaDetailsById.graphql") ++ fragment, .{ .id = text }) else try gql(ctx, @embedFile("graphql/KitsuGetMangaDetailsBySlug.graphql") ++ fragment, .{ .slug = text });
        const manga = f(data, if (numeric) "findMangaById" else "findMangaBySlug");
        if (manga != .null) try list.append(ctx.arena, try toSearch(ctx, manga));
    } else {
        const data = try gql(ctx, @embedFile("graphql/KitsuSearchMangaByTitle.graphql") ++ fragment, .{ .query = query });
        for (c.array(f(f(data, "searchMangaByTitle"), "nodes"))) |m| {
            if (m != .null and !c.eq(f(m, "subtype"), "NOVEL")) try list.append(ctx.arena, try toSearch(ctx, m));
        }
    }
    return list.items;
}
fn label(ctx: *driver.Context, value: c.Value, special: []const u8) ![]const u8 {
    if (c.eq(value, special)) return special;
    const out = try std.ascii.allocLowerString(ctx.arena, s(value));
    if (out.len > 0) out[0] = std.ascii.toUpper(out[0]);
    return out;
}
fn toSearch(ctx: *driver.Context, m: c.Value) !tracking.Search {
    var authors: std.ArrayList([]const u8) = .empty;
    var artists: std.ArrayList([]const u8) = .empty;
    for (c.array(f(f(m, "staff"), "nodes"))) |node| {
        if (node == .null) continue;
        const role = s(f(node, "role"));
        const name = s(f(f(node, "person"), "name"));
        if (std.mem.indexOf(u8, role, "Story") != null) try authors.append(ctx.arena, name);
        if (std.mem.indexOf(u8, role, "Art") != null) try artists.append(ctx.arena, name);
    }
    const image = f(m, "posterImage");
    const views = c.array(f(image, "views"));
    return .{ .track = .{ .tracker_id = 3, .remote_id = n(f(m, "id")), .title = s(f(f(m, "titles"), "preferred")), .total_chapters = @intCast(n(f(m, "chapterCount"))), .url = try std.mem.concat(ctx.arena, u8, &.{ "https://kitsu.app/manga/", s(f(m, "slug")) }) }, .cover_url = if (views.len > 0 and f(views[0], "url") != .null) s(f(views[0], "url")) else s(f(f(image, "original"), "url")), .summary = s(f(f(m, "description"), "en")), .score = if (f(m, "averageRating") == .null) -1 else c.number(f(m, "averageRating")), .publishing_status = try label(ctx, f(m, "status"), "TBA"), .publishing_type = try label(ctx, f(m, "subtype"), "OEL"), .start_date = s(f(m, "startDate")), .authors = authors.items, .artists = artists.items };
}
fn find(ctx: *driver.Context, track: tracking.Track) !?tracking.Track {
    const data = gql(ctx, @embedFile("graphql/KitsuFindLibManga.graphql") ++ fragment, .{ .remote_id = try std.fmt.allocPrint(ctx.arena, "{d}", .{track.remote_id}) }) catch |err| switch (err) {
        error.GraphqlResponseErrors => return null,
        else => return err,
    };
    const manga = f(data, "findMangaById");
    const entry = f(manga, "myLibraryEntry");
    if (entry == .null) return null;
    var out = (try toSearch(ctx, manga)).track;
    out.library_id = n(f(entry, "id"));
    out.status = 0;
    for (statuses[1..], 1..) |status, i| if (c.eq(f(entry, "status"), status)) {
        out.status = @intCast(i);
        break;
    };
    if (out.status == 0) return error.InvalidStatus;
    out.score = c.number(f(entry, "rating"));
    out.last_chapter_read = c.number(f(entry, "progress"));
    out.private = c.boolean(f(entry, "private"));
    out.started = try c.instantMs(s(f(entry, "startedAt")));
    out.finished = try c.instantMs(s(f(entry, "finishedAt")));
    return out;
}
fn write(ctx: *driver.Context, track: tracking.Track, add: bool) !tracking.Track {
    if (!add and track.library_id == 0) return error.TrackNotFound;
    const rating: ?i32 = if (track.score > 0) @intFromFloat(track.score) else null;
    const data = if (add) try gql(ctx, @embedFile("graphql/KitsuAddLibManga.graphql"), .{ .media_id = try std.fmt.allocPrint(ctx.arena, "{d}", .{track.remote_id}), .status = try apiStatus(track.status), .progress = @as(i32, @intFromFloat(track.last_chapter_read)), .private = track.private, .rating = rating }) else try gql(ctx, @embedFile("graphql/KitsuUpdateLibManga.graphql"), .{ .library_id = try std.fmt.allocPrint(ctx.arena, "{d}", .{track.library_id}), .status = try apiStatus(track.status), .progress = @as(i32, @intFromFloat(track.last_chapter_read)), .private = track.private, .rating = rating, .startedAt = try c.instant(ctx, track.started), .finishedAt = try c.instant(ctx, track.finished) });
    const result = f(f(data, "libraryEntry"), if (add) "create" else "update");
    var out = track;
    out.library_id = n(f(f(result, "libraryEntry"), "id"));
    if (out.library_id == 0) return error.InvalidTrackerResponse;
    return out;
}

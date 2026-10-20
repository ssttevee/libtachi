//! AniList's implicit OAuth login and GraphQL list entries (Mihon 487c313).
const std = @import("std");
const driver = @import("driver.zig");
const tracking = @import("../tracking.zig");
const c = @import("oauth_common.zig");
const f = c.field;
const s = c.string;
const n = c.integer;
const fragment = @embedFile("graphql/AnilistMangaFragment.graphql");
pub const default_base_url = "https://graphql.anilist.co";
const statuses = [_][]const u8{ "", "CURRENT", "COMPLETED", "PAUSED", "DROPPED", "PLANNING", "REPEATING" };

pub fn call(ctx: *driver.Context, op: tracking.Operation) !tracking.Reply {
    switch (op) {
        .login_url => return .{ .login_url = "https://anilist.co/api/v2/oauth/authorize?client_id=16329&response_type=token" },
        .login => |l| {
            ctx.credential = .{ .tracker_id = 2, .username = "pending", .password = l.password, .token = try c.json(ctx, .{ .access_token = l.password, .expires = c.now(ctx) + 365 * 86400000 }) };
            const viewer = f(try gql(ctx, @embedFile("graphql/AniListGetCurrentUser.graphql"), .{}), "Viewer");
            if (n(f(viewer, "id")) == 0) return error.InvalidTrackerResponse;
            ctx.credential.username = try std.fmt.allocPrint(ctx.arena, "{d}", .{n(f(viewer, "id"))});
            ctx.credential.display_name = s(f(viewer, "name"));
            const format = std.meta.stringToEnum(tracking.AnilistScore, s(f(f(viewer, "mediaListOptions"), "scoreFormat"))) orelse .POINT_10_DECIMAL;
            return .{ .credential = ctx.credential, .anilist_score_type = format };
        },
        else => {},
    }
    if (!ctx.credential.loggedIn()) return error.NotAuthenticated;
    if (ctx.credential.auth_expired) return error.AuthenticationExpired;
    const token = std.json.parseFromSliceLeaky(struct { expires: i64 }, ctx.arena, ctx.credential.token, .{ .ignore_unknown_fields = true }) catch return error.NotAuthenticated;
    if (c.now(ctx) + 60000 > token.expires) return error.AuthenticationExpired;
    return switch (op) {
        .search => |q| .{ .matches = search(ctx, q) catch |err| switch (err) {
            error.GraphqlResponseErrors => &.{},
            else => return err,
        } },
        .bind => |b| blk: {
            var out = b.track;
            if (try find(ctx, out)) |remote| {
                out = c.personal(out, remote, false);
                out.library_id = remote.library_id;
                if (out.status != 2 and out.status != 6 and b.has_read_chapters) out.status = 1;
                out = try update(ctx, out, false);
            } else {
                out.status = if (b.has_read_chapters) 1 else 5;
                out.score = 0;
                const data = try gql(ctx, @embedFile("graphql/AniListAddManga.graphql"), .{ .manga_id = out.remote_id, .progress = @as(i32, @intFromFloat(out.last_chapter_read)), .status = try apiStatus(out.status), .private = out.private });
                out.library_id = n(f(f(data, "SaveMediaListEntry"), "id"));
                if (out.library_id == 0) return error.InvalidTrackerResponse;
            }
            break :blk .{ .track = out };
        },
        .update => |u| .{ .track = try update(ctx, u.track, u.did_read_chapter) },
        .refresh => |t| blk: {
            const remote = (try find(ctx, t)) orelse return error.TrackNotFound;
            var out = c.personal(t, remote, true);
            out.title = remote.title;
            out.total_chapters = remote.total_chapters;
            break :blk .{ .track = out };
        },
        .delete => |t| blk: {
            const id = if (t.library_id != 0) t.library_id else if (try find(ctx, t)) |remote| remote.library_id else break :blk .{};
            const data = try gql(ctx, @embedFile("graphql/AniListDeleteManga.graphql"), .{ .library_id = id });
            if (f(f(data, "DeleteMediaListEntry"), "deleted") == .null) return error.InvalidTrackerResponse;
            break :blk .{};
        },
        else => unreachable,
    };
}
fn gql(ctx: *driver.Context, query: []const u8, variables: anytype) !c.Value {
    return c.graphql(ctx, ctx.base_url, query, variables);
}
fn apiStatus(status: i32) ![]const u8 {
    if (status < 1 or status > 6) return error.InvalidStatus;
    return statuses[@intCast(status)];
}
fn search(ctx: *driver.Context, query: []const u8) ![]const tracking.Search {
    var data: c.Value = undefined;
    const id = if (std.mem.startsWith(u8, query, "id:")) std.fmt.parseInt(i32, std.mem.trim(u8, query[3..], " \r\n\t"), 10) catch null else null;
    if (id) |value| {
        data = try gql(ctx, @embedFile("graphql/AniListGetMangaDetails.graphql") ++ fragment, .{ .manga_id = value });
    } else {
        data = try gql(ctx, @embedFile("graphql/AniListSearchManga.graphql") ++ fragment, .{ .search = query });
    }
    var list: std.ArrayList(tracking.Search) = .empty;
    for (c.array(f(f(data, "Page"), "media"))) |m| if (m != .null) {
        try list.append(ctx.arena, try toSearch(ctx, m));
    };
    return list.items;
}
fn toSearch(ctx: *driver.Context, m: c.Value) !tracking.Search {
    const id = n(f(m, "id"));
    var authors: std.ArrayList([]const u8) = .empty;
    var artists: std.ArrayList([]const u8) = .empty;
    for (c.array(f(f(m, "staff"), "edges"))) |e| {
        const name = f(f(f(e, "node"), "name"), "userPreferred");
        if (name == .null) continue;
        const role = s(f(e, "role"));
        if (std.mem.indexOf(u8, role, "Story") != null) try authors.append(ctx.arena, s(name));
        if (std.mem.indexOf(u8, role, "Art") != null) try artists.append(ctx.arena, s(name));
    }
    var start: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "year", "month", "day" }) |part| {
        const value = f(f(m, "startDate"), part);
        if (value != .null) {
            if (start.items.len > 0) try start.append(ctx.arena, '-');
            try start.print(ctx.arena, "{d}", .{n(value)});
        }
    }
    const format = f(m, "format");
    const origin = f(m, "countryOfOrigin");
    const kind = if (format == .null) "Manga" else if (!c.eq(format, "MANGA")) try std.mem.replaceOwned(u8, ctx.arena, s(format), "_", "-") else if (c.eq(origin, "KR")) "Manhwa" else if (c.eq(origin, "CN") or c.eq(origin, "TW")) "Manhua" else "Manga";
    return .{ .track = .{ .tracker_id = 2, .remote_id = id, .title = if (f(f(m, "title"), "userPreferred") == .null) "(no title)" else s(f(f(m, "title"), "userPreferred")), .total_chapters = @intCast(n(f(m, "chapters"))), .url = try std.fmt.allocPrint(ctx.arena, "https://anilist.co/manga/{d}", .{id}) }, .cover_url = s(f(f(m, "coverImage"), "large")), .summary = try c.html(ctx, s(f(m, "description"))), .score = if (f(m, "averageScore") == .null) -1 else c.number(f(m, "averageScore")), .publishing_status = s(f(m, "status")), .publishing_type = kind, .start_date = start.items, .authors = authors.items, .artists = artists.items };
}
fn find(ctx: *driver.Context, track: tracking.Track) !?tracking.Track {
    const data = gql(ctx, @embedFile("graphql/AniListGetLibManga.graphql") ++ fragment, .{ .user_id = try std.fmt.parseInt(i64, ctx.credential.username, 10), .manga_id = track.remote_id }) catch |err| switch (err) {
        error.GraphqlResponseErrors => return null,
        else => return err,
    };
    const list = c.array(f(f(data, "Page"), "mediaList"));
    if (list.len == 0 or list[0] == .null) return null;
    const entry = list[0];
    if (f(entry, "media") == .null) return error.InvalidTrackerResponse;
    var out = (try toSearch(ctx, f(entry, "media"))).track;
    out.library_id = n(f(entry, "id"));
    out.status = 0;
    for (statuses[1..], 1..) |status, i| if (c.eq(f(entry, "status"), status)) {
        out.status = @intCast(i);
        break;
    };
    if (out.status == 0) return error.InvalidStatus;
    out.score = c.number(f(entry, "scoreRaw"));
    out.last_chapter_read = c.number(f(entry, "progress"));
    out.private = c.boolean(f(entry, "private"));
    out.started = c.fuzzyMs(f(entry, "startedAt"));
    out.finished = c.fuzzyMs(f(entry, "completedAt"));
    return out;
}
fn update(ctx: *driver.Context, track: tracking.Track, did_read: bool) !tracking.Track {
    var out = track;
    if (out.library_id == 0) out.library_id = ((try find(ctx, out)) orelse return error.TrackNotFound).library_id;
    if (did_read) {
        const started = out.started;
        out = tracking.didRead(out, c.now(ctx));
        // Mihon leaves the start date alone while rereading.
        if (track.status == 6 and out.status != 2) out.started = started;
    }
    const data = try gql(ctx, @embedFile("graphql/AniListUpdateManga.graphql"), .{ .library_id = out.library_id, .progress = @as(i32, @intFromFloat(out.last_chapter_read)), .status = try apiStatus(out.status), .private = out.private, .score = @as(i32, @intFromFloat(out.score)), .startedAt = c.fuzzy(out.started), .completedAt = c.fuzzy(out.finished) });
    out.library_id = n(f(f(data, "SaveMediaListEntry"), "id"));
    if (out.library_id == 0) return error.InvalidTrackerResponse;
    return out;
}

test {
    _ = @import("oauth_tests.zig");
}

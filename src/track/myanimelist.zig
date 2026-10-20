//! MyAnimeList's PKCE login and REST v2 manga list (Mihon 487c313).
const std = @import("std");
const driver = @import("driver.zig");
const tracking = @import("../tracking.zig");
const Http = @import("http.zig").Http;
const c = @import("oauth_common.zig");
const f = c.field;
const s = c.string;
const n = c.integer;
pub const default_base_url = "https://api.myanimelist.net/v2";
const search_fields = "id,title,synopsis,num_chapters,mean,main_picture,status,media_type,start_date,authors{first_name,last_name}";
const statuses = [_][]const u8{ "", "reading", "completed", "on_hold", "dropped", "", "plan_to_read", "reading" };

pub fn call(ctx: *driver.Context, op: tracking.Operation) !tracking.Reply {
    switch (op) {
        .login_url => |l| {
            // MAL uses the plain PKCE method. Return the verifier for the app's callback.
            var bytes: [48]u8 = undefined;
            std.Io.random(ctx.io, &bytes);
            const verifier = try ctx.arena.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len));
            _ = std.base64.url_safe_no_pad.Encoder.encode(verifier, &bytes);
            const query = try Http.form(ctx.arena, &.{ .{ "client_id", c.mal_client }, .{ "code_challenge", verifier }, .{ "response_type", "code" }, .{ "redirect_uri", l.redirect_uri }, .{ "state", l.state } });
            return .{ .login_url = try std.mem.concat(ctx.arena, u8, &.{ "https://myanimelist.net/v1/oauth2/authorize?", query }), .verifier = verifier };
        },
        .login => |l| {
            if (l.verifier.len == 0) return error.MissingVerifier;
            var fields: std.ArrayList([2][]const u8) = .empty;
            try fields.appendSlice(ctx.arena, &.{ .{ "client_id", c.mal_client }, .{ "code", l.password }, .{ "code_verifier", l.verifier }, .{ "grant_type", "authorization_code" } });
            if (l.redirect_uri.len > 0) try fields.append(ctx.arena, .{ "redirect_uri", l.redirect_uri });
            const body = try Http.form(ctx.arena, fields.items);
            ctx.credential = .{ .tracker_id = 1, .username = "pending" };
            try c.saveToken(ctx, try ctx.http.send(ctx.arena, .POST, try c.tokenUrl(ctx), &.{}, .{ .form = body }));
            const user = try get(ctx, "/users/@me");
            const username = s(f(user, "name"));
            if (username.len == 0) return error.InvalidTrackerResponse;
            // Mihon stores the MAL username, not a numeric user id.
            ctx.credential.username = username;
            ctx.credential.display_name = username;
            return .{ .credential = ctx.credential };
        },
        else => {},
    }
    const renewed = try c.prepare(ctx);
    var reply: tracking.Reply = switch (op) {
        .search => |q| .{ .matches = try search(ctx, q) },
        .bind => |b| blk: {
            const found = try find(ctx, b.track);
            var out = found.track;
            if (found.exists) {
                if (out.status != 2 and out.status != 7 and b.has_read_chapters) out.status = 1;
            } else {
                out.status = if (b.has_read_chapters) 1 else 6;
                out.score = 0;
            }
            break :blk .{ .track = try update(ctx, out) };
        },
        .update => |u| blk: {
            var out = u.track;
            if (u.did_read_chapter) {
                out = tracking.didRead(out, c.now(ctx));
                if (u.track.status == 7 and out.status != 2) out.started = u.track.started;
            }
            break :blk .{ .track = try update(ctx, out) };
        },
        .refresh => |t| blk: {
            const found = try find(ctx, t);
            break :blk .{ .track = if (found.exists) found.track else try update(ctx, found.track) };
        },
        .delete => |t| blk: {
            try c.ok(try c.send(ctx, .DELETE, try url(ctx, try std.fmt.allocPrint(ctx.arena, "/manga/{d}/my_list_status", .{t.remote_id})), .none));
            break :blk .{};
        },
        else => unreachable,
    };
    if (renewed) reply.credential = ctx.credential;
    return reply;
}
fn url(ctx: *driver.Context, path: []const u8) ![]const u8 {
    return std.mem.concat(ctx.arena, u8, &.{ ctx.base_url, path });
}
fn get(ctx: *driver.Context, path: []const u8) !c.Value {
    const response = try c.send(ctx, .GET, try url(ctx, path), .none);
    try c.ok(response);
    return response.json(c.Value, ctx.arena);
}
fn search(ctx: *driver.Context, query: []const u8) ![]const tracking.Search {
    var list: std.ArrayList(tracking.Search) = .empty;
    const id = if (std.mem.startsWith(u8, query, "id:")) std.fmt.parseInt(i32, std.mem.trim(u8, query[3..], " \t\r\n"), 10) catch null else null;
    if (id) |value| {
        const params = try Http.form(ctx.arena, &.{.{ "fields", search_fields }});
        try list.append(ctx.arena, try toSearch(ctx, try get(ctx, try std.fmt.allocPrint(ctx.arena, "/manga/{d}?{s}", .{ value, params }))));
        return list.items;
    }
    if (std.mem.startsWith(u8, query, "my:")) {
        var offset: usize = 0;
        const needle = try std.ascii.allocLowerString(ctx.arena, query[3..]);
        while (true) : (offset += 250) {
            const params = try Http.form(ctx.arena, &.{ .{ "fields", search_fields }, .{ "limit", "250" } });
            const path = if (offset == 0) try std.fmt.allocPrint(ctx.arena, "/users/@me/mangalist?{s}", .{params}) else try std.fmt.allocPrint(ctx.arena, "/users/@me/mangalist?{s}&offset={d}", .{ params, offset });
            const data = try get(ctx, path);
            for (c.array(f(data, "data"))) |entry| {
                const node = f(entry, "node");
                const title = try std.ascii.allocLowerString(ctx.arena, s(f(node, "title")));
                if (std.mem.indexOf(u8, title, needle) != null) try list.append(ctx.arena, try toSearch(ctx, node));
            }
            if (std.mem.trim(u8, s(f(f(data, "paging"), "next")), " \r\n\t").len == 0) break;
        }
        return list.items;
    }
    // Bound by characters, keeping UTF-8 sequences intact.
    var end: usize = 0;
    var count: usize = 0;
    while (end < query.len and count < 64) : (count += 1) end += std.unicode.utf8ByteSequenceLength(query[end]) catch 1;
    const params = try Http.form(ctx.arena, &.{ .{ "q", query[0..@min(end, query.len)] }, .{ "nsfw", "true" }, .{ "fields", search_fields } });
    const data = try get(ctx, try std.mem.concat(ctx.arena, u8, &.{ "/manga?", params }));
    for (c.array(f(data, "data"))) |entry| {
        const node = f(entry, "node");
        if (std.mem.indexOf(u8, s(f(node, "media_type")), "novel") == null) try list.append(ctx.arena, try toSearch(ctx, node));
    }
    return list.items;
}
fn toSearch(ctx: *driver.Context, manga: c.Value) !tracking.Search {
    var authors: std.ArrayList([]const u8) = .empty;
    var artists: std.ArrayList([]const u8) = .empty;
    for (c.array(f(manga, "authors"))) |a| {
        const node = f(a, "node");
        const name = std.mem.trim(u8, try std.fmt.allocPrint(ctx.arena, "{s} {s}", .{ s(f(node, "first_name")), s(f(node, "last_name")) }), " ");
        if (name.len == 0) continue;
        if (c.eq(f(a, "role"), "Art")) try artists.append(ctx.arena, name);
        if (std.mem.indexOf(u8, s(f(a, "role")), "Story") != null) try authors.append(ctx.arena, name);
    }
    const id = n(f(manga, "id"));
    return .{ .track = .{ .tracker_id = 1, .remote_id = id, .title = s(f(manga, "title")), .total_chapters = @intCast(n(f(manga, "num_chapters"))), .url = try std.fmt.allocPrint(ctx.arena, "https://myanimelist.net/manga/{d}", .{id}) }, .summary = s(f(manga, "synopsis")), .score = if (f(manga, "mean") == .null) -1 else c.number(f(manga, "mean")), .cover_url = s(f(f(manga, "main_picture"), "large")), .publishing_status = try std.mem.replaceOwned(u8, ctx.arena, s(f(manga, "status")), "_", " "), .publishing_type = try std.mem.replaceOwned(u8, ctx.arena, s(f(manga, "media_type")), "_", " "), .start_date = s(f(manga, "start_date")), .authors = authors.items, .artists = artists.items };
}
fn personal(track: tracking.Track, status: c.Value) !tracking.Track {
    var out = track;
    out.status = 1;
    if (c.boolean(f(status, "is_rereading"))) {
        out.status = 7;
    } else {
        for (statuses[1..7], 1..) |text, i| if (text.len > 0 and c.eq(f(status, "status"), text)) {
            out.status = @intCast(i);
            break;
        };
    }
    out.last_chapter_read = c.number(f(status, "num_chapters_read"));
    out.score = c.number(f(status, "score"));
    if (f(status, "start_date") != .null) out.started = try c.dateMs(s(f(status, "start_date")));
    if (f(status, "finish_date") != .null) out.finished = try c.dateMs(s(f(status, "finish_date")));
    return out;
}
fn find(ctx: *driver.Context, track: tracking.Track) !struct { track: tracking.Track, exists: bool } {
    const params = try Http.form(ctx.arena, &.{.{ "fields", "num_chapters,my_list_status{start_date,finish_date}" }});
    const data = try get(ctx, try std.fmt.allocPrint(ctx.arena, "/manga/{d}?{s}", .{ track.remote_id, params }));
    var out = track;
    out.total_chapters = @intCast(n(f(data, "num_chapters")));
    const status = f(data, "my_list_status");
    return .{ .track = if (status == .null) out else try personal(out, status), .exists = status != .null };
}
fn update(ctx: *driver.Context, track: tracking.Track) !tracking.Track {
    const status = if (track.status >= 1 and track.status <= 7 and track.status != 5) statuses[@intCast(track.status)] else "reading";
    const body = try Http.form(ctx.arena, &.{ .{ "status", status }, .{ "is_rereading", if (track.status == 7) "true" else "false" }, .{ "score", try std.fmt.allocPrint(ctx.arena, "{d:.1}", .{track.score}) }, .{ "num_chapters_read", try std.fmt.allocPrint(ctx.arena, "{d}", .{@as(i32, @intFromFloat(track.last_chapter_read))}) }, .{ "start_date", try c.date(ctx, track.started) }, .{ "finish_date", try c.date(ctx, track.finished) } });
    const response = try c.send(ctx, .PUT, try url(ctx, try std.fmt.allocPrint(ctx.arena, "/manga/{d}/my_list_status", .{track.remote_id})), .{ .form = body });
    if (!response.ok() and std.mem.indexOf(u8, response.body, "invalid_content") != null) return error.MALTitleNotApproved;
    try c.ok(response);
    return personal(track, try response.json(c.Value, ctx.arena));
}

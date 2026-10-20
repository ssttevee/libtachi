//! Shared source settings and identity rules for enhanced trackers.
const std = @import("std");
const driver = @import("driver.zig");
const tracking = @import("../tracking.zig");
const library = @import("../library.zig");
const backup = @import("../backup.zig");

/// Library sources retain package names rather than Android class names.
pub fn accepts(id: i32, pkg: []const u8) bool {
    const package = switch (id) {
        6 => "eu.kanade.tachiyomi.extension.all.komga",
        8 => "eu.kanade.tachiyomi.extension.all.kavita",
        9 => "eu.kanade.tachiyomi.extension.all.tachidesk",
        else => return false,
    };
    return std.mem.eql(u8, pkg, package);
}

pub fn sourcePackage(lib: library.Library, manga: library.Manga) []const u8 {
    for (lib.sources) |s| if (s.id == manga.source_id) return s.pkg;
    return "";
}

pub fn isTrackFrom(track: tracking.Track, manga: library.Manga, pkg: []const u8) bool {
    return accepts(track.tracker_id, pkg) and std.mem.eql(u8, track.url, (manga.remote orelse return false).url);
}

pub fn migrate(track: tracking.Track, manga: library.Manga, pkg: []const u8) ?tracking.Track {
    if (!accepts(track.tracker_id, pkg)) return null;
    var out = track;
    out.url = (manga.remote orelse return null).url;
    if (out.tracker_id == 9) out.remote_id = lastId(out.url) catch return null;
    return out;
}

pub fn login(id: i32) tracking.Reply {
    return .{ .credential = .{ .tracker_id = id, .username = "user", .password = "pass" } };
}

pub fn string(prefs: backup.SourcePreferences, key: []const u8) []const u8 {
    for (prefs.prefs) |p| if (std.mem.eql(u8, p.key, key) and p.value == .string) return p.value.string;
    return "";
}

pub fn boolean(prefs: backup.SourcePreferences, key: []const u8) bool {
    for (prefs.prefs) |p| if (std.mem.eql(u8, p.key, key) and p.value == .boolean) return p.value.boolean;
    return false;
}

pub fn trim(url: []const u8) []const u8 {
    return std.mem.trimEnd(u8, url, "/");
}

/// Match the entire server base path, never an origin prefix such as host.evil.
pub fn belongs(url: []const u8, base: []const u8) bool {
    const b = trim(base);
    return b.len > 0 and std.mem.startsWith(u8, url, b) and (url.len == b.len or url[b.len] == '/');
}

pub fn settings(ctx: *driver.Context, url: []const u8, key: []const u8) !backup.SourcePreferences {
    const host = ctx.host_dir orelse return error.SourceNotConfigured;
    const dir = try std.fs.path.join(ctx.arena, &.{ host, "prefs" });
    const sources = try @import("../preferences.zig").readSourcePreferences(ctx.arena, ctx.io, dir, true);
    var found: ?backup.SourcePreferences = null;
    for (sources) |s| {
        if (!belongs(url, string(s, key))) continue;
        // A track has no source id. Refuse ambiguous accounts on one server.
        if (found != null) return error.AmbiguousSourceSettings;
        found = s;
    }
    return found orelse error.SourceNotConfigured;
}

/// Tachidesk retains MD5("tachidesk/en/1") even though its language is now all.
pub fn tachideskSettings(ctx: *driver.Context) !backup.SourcePreferences {
    const host = ctx.host_dir orelse return error.SourceNotConfigured;
    const path = try std.fs.path.join(ctx.arena, &.{ host, "prefs" });
    const sources = try @import("../preferences.zig").readSourcePreferences(ctx.arena, ctx.io, path, true);
    for (sources) |source| if (std.mem.eql(u8, source.key, "source_3100117499901280806")) return source;
    return error.SourceNotConfigured;
}

pub fn basic(ctx: *driver.Context, username: []const u8, password: []const u8) ![]const u8 {
    const plain = try std.fmt.allocPrint(ctx.arena, "{s}:{s}", .{ username, password });
    const encoder = std.base64.standard.Encoder;
    const buf = try ctx.arena.alloc(u8, encoder.calcSize(plain.len));
    return std.mem.concat(ctx.arena, u8, &.{ "Basic ", encoder.encode(buf, plain) });
}

pub fn expectOk(response: @import("http.zig").Http.Response) !void {
    if (!response.ok()) return error.TrackerRequestFailed;
}

pub fn lastId(url: []const u8) !i64 {
    const start = if (std.mem.lastIndexOfScalar(u8, url, '/')) |index| index + 1 else 0;
    const id = std.fmt.parseInt(i64, url[start..], 10) catch return error.InvalidTrackUrl;
    if (id < 0 or id > std.math.maxInt(i32)) return error.InvalidTrackUrl;
    return id;
}

pub fn personal(old: tracking.Track, remote: tracking.Track) tracking.Track {
    var out = old;
    out.status = remote.status;
    out.last_chapter_read = remote.last_chapter_read;
    out.total_chapters = remote.total_chapters;
    out.score = remote.score;
    out.started = remote.started;
    out.finished = remote.finished;
    return out;
}

test "enhanced acceptance and migration use package and server-aware identity" {
    const t = std.testing;
    const komga = "eu.kanade.tachiyomi.extension.all.komga";
    try t.expect(accepts(6, komga));
    try t.expect(!accepts(8, komga));
    try t.expect(!accepts(6, "eu.kanade.tachiyomi.extension.all.komga.other"));
    const old: tracking.Track = .{ .tracker_id = 6, .url = "http://old/api/v1/series/a", .last_chapter_read = 7 };
    const manga: library.Manga = .{ .id = "m", .title = "M", .remote = .{ .url = old.url, .title = "M" } };
    try t.expect(isTrackFrom(old, manga, komga));
    var target = manga;
    target.remote.?.url = "http://new/api/v1/series/b";
    try t.expect(!isTrackFrom(old, target, komga));
    const moved = migrate(old, target, komga).?;
    try t.expectEqualStrings(target.remote.?.url, moved.url);
    try t.expectEqual(@as(f64, 7), moved.last_chapter_read);
    try t.expect(migrate(old, target, "other") == null);
    const suwayomi: tracking.Track = .{ .tracker_id = 9, .remote_id = 1 };
    target.remote.?.url = "http://new/manga/42";
    try t.expectEqual(@as(i64, 42), migrate(suwayomi, target, "eu.kanade.tachiyomi.extension.all.tachidesk").?.remote_id);
    try t.expect(belongs("http://server/sub/api/v1/series/a", "http://server/sub/"));
    try t.expect(!belongs("http://server.evil/api/v1/series/a", "http://server"));
    try t.expect(!belongs("http://server/submarine/api/v1/series/a", "http://server/sub"));
}

test "source settings reject missing, ambiguous and prefix-only matches" {
    const test_http = @import("testing_enhanced.zig");
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const values = .{ .Address = .{ .t = "s", .v = "http://server/sub" } };
    const host = try test_http.prefs(a, tmp.dir, 1, values);
    var http: test_http.Http = .{ .gpa = t.allocator, .io = t.io };
    defer http.deinit();
    var ctx = test_http.context(a, &http, 6, host);
    try t.expectError(error.SourceNotConfigured, settings(&ctx, "http://server/submarine/api/v1/series/a", "Address"));
    try t.expectEqualStrings("source_1", (try settings(&ctx, "http://server/sub/api/v1/series/a", "Address")).key);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "prefs/source_2.json", .data = try std.json.Stringify.valueAlloc(a, values, .{}) });
    try t.expectError(error.AmbiguousSourceSettings, settings(&ctx, "http://server/sub/api/v1/series/a", "Address"));
}

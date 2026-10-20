//! Tracking services, provider-native scores and durable credentials/retries.
//! Network adapters implement `Driver`; the engine owns all library edits.
const std = @import("std");
const Io = std.Io;
const library = @import("library.zig");
const models = @import("models.zig");
pub const Track = library.Track;
pub const Status = struct { value: i32, name: []const u8 };
pub const AnilistScore = enum { POINT_100, POINT_10_DECIMAL, POINT_10, POINT_5, POINT_3 };
pub const KitsuScore = enum { simple, regular, advanced };
pub const MangaBakaScore = enum(u8) { STEP_1 = 1, STEP_5 = 5, STEP_10 = 10, STEP_20 = 20, STEP_25 = 25 };
pub const Formats = struct {
    anilist_score_type: AnilistScore = .POINT_10,
    kitsu_score_type: KitsuScore = .advanced,
    mangabaka_score_type: MangaBakaScore = .STEP_1,
};

pub const Tracker = struct {
    id: i32,
    name: []const u8,
    reading_dates: bool = false,
    private: bool = false,
    enhanced: bool = false,
    deletable: bool = false,
    reading: i32 = 1,
    completed: i32 = 2,
    planned: i32 = 5,
    rereading: ?i32 = null,
    statuses: []const Status,

    pub fn get10PointScore(self: Tracker, score: f64) f64 {
        return switch (self.id) {
            2, 11 => score / 10,
            3 => score / 2,
            else => score,
        };
    }

    pub fn scoreCount(self: Tracker, f: Formats) usize {
        if (self.enhanced) return 0;
        return switch (self.id) {
            2 => switch (f.anilist_score_type) {
                .POINT_100, .POINT_10_DECIMAL => 101,
                .POINT_10 => 11,
                .POINT_5 => 6,
                .POINT_3 => 4,
            },
            3 => switch (f.kitsu_score_type) {
                .simple => 5,
                .regular => 11,
                .advanced => 20,
            },
            7 => 92,
            11 => 100 / @as(usize, @backingInt(f.mangabaka_score_type)) + 1,
            else => 11,
        };
    }

    pub fn indexToScore(self: Tracker, f: Formats, index: usize) !f64 {
        if (index >= self.scoreCount(f)) return error.InvalidScore;
        const n: f64 = @floatFromInt(index);
        if (index == 0) return 0;
        return switch (self.id) {
            2 => switch (f.anilist_score_type) {
                .POINT_100, .POINT_10_DECIMAL => n,
                .POINT_10 => n * 10,
                .POINT_5 => n * 20 - 10,
                .POINT_3 => n * 25 + 10,
            },
            3 => switch (f.kitsu_score_type) {
                .simple => @as(f64, @floatFromInt(([_]u8{ 2, 8, 14, 20 })[index - 1])),
                .regular => n * 2,
                .advanced => n + 1,
            },
            7 => (n + 9) / 10,
            11 => n * @as(f64, @floatFromInt(@backingInt(f.mangabaka_score_type))),
            else => n,
        };
    }

    pub fn displayScore(self: Tracker, a: std.mem.Allocator, f: Formats, score: f64) ![]const u8 {
        if (self.enhanced) return "";
        if (score <= 0 or !std.math.isFinite(score)) return "-";
        if (self.id == 3) {
            var index: usize = 0;
            for (1..self.scoreCount(f)) |i| {
                if (try self.indexToScore(f, i) > score) break;
                index = i;
            }
            if (index == 0) return "-";
            const native = try self.indexToScore(f, index);
            return switch (f.kitsu_score_type) {
                .simple => ([_][]const u8{ "Awful", "Meh", "Good", "Great" })[index - 1],
                .regular => std.fmt.allocPrint(a, "{d:.1} ★", .{native / 4}),
                .advanced => std.fmt.allocPrint(a, "{d:.1}", .{native / 2}),
            };
        }
        if (self.id == 2) return switch (f.anilist_score_type) {
            .POINT_5 => std.fmt.allocPrint(a, "{d} ★", .{@as(i32, @intFromFloat((score + 10) / 20))}),
            .POINT_3 => if (score >= 60) "☺" else if (score >= 35) "😐" else "☹",
            .POINT_100 => std.fmt.allocPrint(a, "{d:.0}", .{score}),
            .POINT_10 => std.fmt.allocPrint(a, "{d:.0}", .{score / 10}),
            .POINT_10_DECIMAL => std.fmt.allocPrint(a, "{d:.1}", .{score / 10}),
        };
        return if (self.id == 7) std.fmt.allocPrint(a, "{d:.1}", .{score}) else std.fmt.allocPrint(a, "{d:.0}", .{score});
    }

    pub fn scoreList(self: Tracker, a: std.mem.Allocator, f: Formats) ![]const []const u8 {
        const result = try a.alloc([]const u8, self.scoreCount(f));
        for (result, 0..) |*s, i| s.* = try self.displayScore(a, f, try self.indexToScore(f, i));
        return result;
    }

    pub fn validStatus(self: Tracker, status: i32) bool {
        for (self.statuses) |s| if (s.value == status) return true;
        return false;
    }
};

const regular = [_]Status{ .{ .value = 1, .name = "Reading" }, .{ .value = 2, .name = "Completed" }, .{ .value = 3, .name = "On hold" }, .{ .value = 4, .name = "Dropped" }, .{ .value = 5, .name = "Plan to read" }, .{ .value = 6, .name = "Rereading" } };
const mal = regular[0..4].* ++ [_]Status{ .{ .value = 6, .name = "Plan to read" }, .{ .value = 7, .name = "Rereading" } };
const server = [_]Status{ .{ .value = 1, .name = "Unread" }, .{ .value = 2, .name = "Reading" }, .{ .value = 3, .name = "Completed" } };
const bangumi = [_]Status{ .{ .value = 1, .name = "Plan to read" }, .{ .value = 2, .name = "Completed" }, .{ .value = 3, .name = "Reading" }, .{ .value = 4, .name = "On hold" }, .{ .value = 5, .name = "Dropped" } };
const updates = [_]Status{ .{ .value = 0, .name = "Reading list" }, .{ .value = 1, .name = "Wish list" }, .{ .value = 2, .name = "Complete list" }, .{ .value = 3, .name = "Unfinished list" }, .{ .value = 4, .name = "On hold list" } };
const hikka = [_]Status{ .{ .value = 0, .name = "Reading" }, .{ .value = 1, .name = "Completed" }, .{ .value = 2, .name = "On hold" }, .{ .value = 3, .name = "Dropped" }, .{ .value = 4, .name = "Plan to read" }, .{ .value = 5, .name = "Rereading" } };
const baka = regular[0..2].* ++ [_]Status{.{ .value = 3, .name = "Paused" }} ++ regular[3..].* ++ [_]Status{.{ .value = 7, .name = "Considering" }};
pub const trackers = [_]Tracker{
    .{ .id = 1, .name = "MyAnimeList", .reading_dates = true, .planned = 6, .rereading = 7, .deletable = true, .statuses = &mal },
    .{ .id = 2, .name = "AniList", .reading_dates = true, .private = true, .rereading = 6, .deletable = true, .statuses = &regular },
    .{ .id = 3, .name = "Kitsu", .reading_dates = true, .private = true, .deletable = true, .statuses = regular[0..5] },
    .{ .id = 4, .name = "Shikimori", .rereading = 6, .deletable = true, .statuses = &regular },
    .{ .id = 5, .name = "Bangumi", .private = true, .reading = 3, .planned = 1, .statuses = &bangumi },
    .{ .id = 6, .name = "Komga", .enhanced = true, .reading = 2, .completed = 3, .planned = 1, .statuses = &server },
    .{ .id = 7, .name = "MangaUpdates", .reading = 0, .planned = 1, .deletable = true, .statuses = &updates },
    .{ .id = 8, .name = "Kavita", .enhanced = true, .reading = 2, .completed = 3, .planned = 1, .statuses = &server },
    .{ .id = 9, .name = "Suwayomi", .enhanced = true, .reading = 2, .completed = 3, .planned = 1, .statuses = &server },
    .{ .id = 10, .name = "Hikka", .reading_dates = true, .reading = 0, .completed = 1, .planned = 4, .rereading = 5, .deletable = true, .statuses = &hikka },
    .{ .id = 11, .name = "MangaBaka", .reading_dates = true, .private = true, .rereading = 6, .deletable = true, .statuses = &baka },
    .{ .id = 12, .name = "Comick", .deletable = true, .statuses = regular[0..5] },
};
pub fn get(id: i32) ?Tracker {
    for (trackers) |t| if (t.id == id) return t;
    return null;
}

pub const Credential = struct {
    tracker_id: i32,
    username: []const u8 = "",
    display_name: []const u8 = "",
    password: []const u8 = "",
    token: []const u8 = "",
    auth_expired: bool = false,
    pub fn loggedIn(self: Credential) bool {
        return self.username.len > 0 and self.password.len > 0;
    }
};
/// Composite identity replaces Mihon's database track row id.
pub const Pending = struct { manga_id: []const u8, tracker_id: i32, chapter: f64 };
pub const State = struct {
    credentials: []const Credential = &.{},
    formats: Formats = .{},
    pending: []const Pending = &.{},
    /// Android's worker attempt count and next connected-network retry.
    attempts: u8 = 0,
    retry_at: i64 = 0,

    pub fn credential(self: State, id: i32) Credential {
        for (self.credentials) |c| if (c.tracker_id == id) return c;
        return .{ .tracker_id = id };
    }
    pub fn loggedIn(self: State, id: i32) bool {
        return get(id) != null and self.credential(id).loggedIn();
    }
    pub fn putCredential(self: *State, a: std.mem.Allocator, c: Credential) !void {
        const copy = try a.dupe(Credential, self.credentials);
        for (copy) |*old| if (old.tracker_id == c.tracker_id) {
            old.* = c;
            self.credentials = copy;
            return;
        };
        self.credentials = try std.mem.concat(a, Credential, &.{ copy, &.{c} });
    }
    pub fn enqueue(self: *State, a: std.mem.Allocator, p: Pending) !void {
        if (!std.math.isFinite(p.chapter) or p.chapter <= 0) return;
        const copy = try a.dupe(Pending, self.pending);
        for (copy) |*old| if (old.tracker_id == p.tracker_id and std.mem.eql(u8, old.manga_id, p.manga_id)) {
            old.chapter = @max(old.chapter, p.chapter);
            self.pending = copy;
            return;
        };
        self.pending = try std.mem.concat(a, Pending, &.{ copy, &.{p} });
    }
    pub fn remove(self: *State, a: std.mem.Allocator, manga_id: []const u8, id: i32) !void {
        var list: std.ArrayList(Pending) = .empty;
        for (self.pending) |p| if (p.tracker_id != id or !std.mem.eql(u8, p.manga_id, manga_id)) try list.append(a, p);
        self.pending = try list.toOwnedSlice(a);
        if (self.pending.len == 0) {
            self.attempts = 0;
            self.retry_at = 0;
        }
    }
    pub fn load(a: std.mem.Allocator, io: Io, dir: []const u8) !State {
        const path = try std.fs.path.join(a, &.{ dir, "trackers.json" });
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 << 20)) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        return std.json.parseFromSliceLeaky(State, a, bytes, models.parse_options);
    }
    pub fn save(self: State, a: std.mem.Allocator, io: Io, dir: []const u8) !void {
        const path = try std.fs.path.join(a, &.{ dir, "trackers.json" });
        defer a.free(path);
        try library.writeJsonAtomic(a, io, path, self);
    }
};

/// Logged-out services contribute neither scores nor tracked-title counts.
pub fn scoreView(state: *const State) @import("views.zig").TrackScore {
    return .{ .context = state, .get_fn = struct {
        fn convert(context: *const anyopaque, track: Track) ?f64 {
            const self: *const State = @ptrCast(@alignCast(context));
            if (!self.loggedIn(track.tracker_id)) return null;
            return (get(track.tracker_id) orelse return null).get10PointScore(track.score);
        }
    }.convert };
}

/// All adapter results belong to the call's arena. Io cancellation propagates.
pub const Operation = union(enum) {
    login_url: struct { redirect_uri: []const u8, state: []const u8 },
    login: struct { username: []const u8, password: []const u8, redirect_uri: []const u8 = "", verifier: []const u8 = "" },
    /// Enhanced trackers match source URLs; they do not support textual search.
    search: []const u8,
    bind: struct { track: Track, has_read_chapters: bool },
    update: struct { track: Track, did_read_chapter: bool = false },
    refresh: Track,
    delete: Track,
};
pub const Reply = struct {
    track: ?Track = null,
    matches: []const Search = &.{},
    credential: ?Credential = null,
    login_url: ?[]const u8 = null,
    /// Keep this with the OAuth request and pass it to login on callback.
    verifier: ?[]const u8 = null,
    /// Score formats read from the account at login.
    anilist_score_type: ?AnilistScore = null,
    kitsu_score_type: ?KitsuScore = null,
    mangabaka_score_type: ?MangaBakaScore = null,
};

/// A search result, as Mihon's `TrackSearch`: the track to bind, and what
/// to show to choose it.
pub const Search = struct {
    track: Track,
    cover_url: []const u8 = "",
    summary: []const u8 = "",
    publishing_status: []const u8 = "",
    publishing_type: []const u8 = "",
    start_date: []const u8 = "",
    authors: []const []const u8 = &.{},
    artists: []const []const u8 = &.{},
    /// The service's mean score on its own scale; -1 if none.
    score: f64 = -1,
};
pub const Driver = struct {
    context: ?*anyopaque = null,
    call: *const fn (?*anyopaque, std.mem.Allocator, Io, i32, Credential, Formats, Operation) anyerror!Reply,
};

pub const Setter = union(enum) { status: i32, progress: i32, score_index: usize, started: i64, finished: i64, private: bool };
/// BaseTracker's explicit setters, before update(didReadChapter=false).
pub fn set(track: Track, setter: Setter, formats: Formats, now: i64) !Track {
    const t = get(track.tracker_id) orelse return error.UnknownTracker;
    var out = track;
    switch (setter) {
        .status => |value| {
            if (!t.validStatus(value)) return error.InvalidStatus;
            out.status = value;
            if (value == t.completed and out.total_chapters != 0) out.last_chapter_read = @floatFromInt(out.total_chapters);
        },
        .progress => |value| {
            if (value < 0) return error.InvalidProgress;
            const n: f64 = @floatFromInt(value);
            if (out.last_chapter_read == 0 and n > 0 and out.status != t.rereading) out.status = t.reading;
            out.last_chapter_read = n;
            if (value == out.total_chapters and value != 0) {
                out.status = t.completed;
                out.finished = now;
            }
        },
        .score_index => |value| out.score = try t.indexToScore(formats, value),
        .started => |value| {
            if (!t.reading_dates) return error.UnsupportedReadingDates;
            out.started = value;
        },
        .finished => |value| {
            if (!t.reading_dates) return error.UnsupportedReadingDates;
            out.finished = value;
        },
        .private => |value| {
            if (!t.private) return error.UnsupportedPrivate;
            out.private = value;
        },
    }
    return out;
}

/// Provider update rules for automatic chapter completion.
pub fn didRead(track: Track, now: i64) Track {
    const t = get(track.tracker_id) orelse return track;
    var out = track;
    if (out.status == t.completed) return out;
    if (t.id == 7 or t.id == 12) {
        out.status = t.reading;
        return out;
    }
    if (out.total_chapters > 0 and std.math.isFinite(out.last_chapter_read) and @trunc(out.last_chapter_read) == @as(f64, @floatFromInt(out.total_chapters))) {
        out.status = t.completed;
        if (t.reading_dates) out.finished = now;
    } else {
        if (out.status != t.rereading) out.status = t.reading;
        if (t.reading_dates and out.last_chapter_read == 1) out.started = now;
    }
    return out;
}

/// The ascending read prefix; gaps in chapter numbers are not missing rows.
pub fn continuousRead(a: std.mem.Allocator, chapters: []const library.Chapter, recognized_only: bool) !f64 {
    var sorted: std.ArrayList(library.Chapter) = .empty;
    for (chapters) |ch| if (!recognized_only or ch.recognized()) try sorted.append(a, ch);
    std.mem.sort(library.Chapter, sorted.items, {}, struct {
        fn less(_: void, x: library.Chapter, y: library.Chapter) bool {
            return x.number < y.number;
        }
    }.less);
    var last: f64 = if (recognized_only) 0 else -1;
    for (sorted.items) |ch| {
        if (!ch.read) break;
        last = ch.number;
    }
    return last;
}

/// Transactional upsert by manga and tracker, preserving other titles' tracks.
pub const Edit = struct {
    manga_id: []const u8,
    tracker_id: i32,
    track: ?Track,
    pub fn apply(self: Edit, a: std.mem.Allocator, lib: library.Library) !?library.Library {
        return library.editManga(a, lib, self.manga_id, self, edit);
    }
    fn edit(self: Edit, a: std.mem.Allocator, manga: *library.Manga) !bool {
        var list: std.ArrayList(Track) = .empty;
        for (manga.tracks) |t| if (t.tracker_id != self.tracker_id) try list.append(a, t);
        if (self.track) |t| try list.append(a, t);
        manga.tracks = try list.toOwnedSlice(a);
        return true;
    }
};

test "provider namespaces and score selections preserve native values" {
    try std.testing.expectEqual(@as(i32, 6), get(1).?.planned);
    try std.testing.expectEqual(@as(i32, 0), get(7).?.reading);
    try std.testing.expectEqual(@as(f64, 10), try get(2).?.indexToScore(.{ .anilist_score_type = .POINT_5 }, 1));
    try std.testing.expectEqual(@as(f64, 85), try get(2).?.indexToScore(.{ .anilist_score_type = .POINT_3 }, 3));
    try std.testing.expectEqual(@as(f64, 2), try get(3).?.indexToScore(.{}, 1));
    try std.testing.expectEqual(@as(f64, 20), try get(3).?.indexToScore(.{}, 19));
    try std.testing.expectEqual(@as(f64, 10), try get(7).?.indexToScore(.{}, 91));
    try std.testing.expectEqual(@as(f64, 7), get(3).?.get10PointScore(14));
    try std.testing.expectError(error.InvalidScore, get(6).?.indexToScore(.{}, 0));
}

test "automatic completion truncates and uses equality; setters differ" {
    const track: Track = .{ .tracker_id = 2, .total_chapters = 10, .status = 5, .last_chapter_read = 10.9 };
    try std.testing.expectEqual(@as(i32, 2), didRead(track, 123).status);
    var ahead = track;
    ahead.last_chapter_read = 11;
    try std.testing.expectEqual(@as(i32, 1), didRead(ahead, 123).status);
    try std.testing.expectEqual(@as(f64, 10), (try set(track, .{ .status = 2 }, .{}, 123)).last_chapter_read);
    try std.testing.expectEqual(@as(i64, 123), (try set(track, .{ .progress = 10 }, .{}, 123)).finished);
}

test "queue keeps maximum and persists credentials, formats and retries" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    var state: State = .{};
    try state.putCredential(a, .{ .tracker_id = 2, .username = "user", .password = "token", .token = "json" });
    try state.enqueue(a, .{ .manga_id = "m", .tracker_id = 2, .chapter = 5 });
    try state.enqueue(a, .{ .manga_id = "m", .tracker_id = 2, .chapter = 3 });
    try state.save(a, io, dir);
    const loaded = try State.load(a, io, dir);
    try std.testing.expect(loaded.loggedIn(2));
    try std.testing.expectEqual(@as(f64, 5), loaded.pending[0].chapter);
    try std.testing.expectEqualStrings("json", loaded.credential(2).token);
    try state.remove(a, "m", 2);
    try std.testing.expectEqual(@as(usize, 0), state.pending.len);
}

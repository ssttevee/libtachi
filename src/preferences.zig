//! Mihon's preferences in backups (mihonapp/mihon 487c313), mapped to and
//! from libtachi's `Settings`, and source preferences read from and written
//! to the host's preference files (`<data dir>/prefs/source_<id>.json`).
//! Mihon preferences libtachi has no setting for are kept in
//! `Settings.mihon_preferences`, so a backup going back to Mihon still has
//! them.
const std = @import("std");
const Io = std.Io;
const backup = @import("backup.zig");
const settings_mod = @import("settings.zig");
const views = @import("views.zig");
const library = @import("library.zig");

const Settings = settings_mod.Settings;
const Preference = backup.Preference;
const Value = Preference.Value;

/// Keys Mihon never backs up: app state and, unless asked, private values.
pub fn isAppState(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "__APP_STATE_");
}

pub fn isPrivate(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "__PRIVATE_");
}

const tri_names = [_][]const u8{ "DISABLED", "ENABLED_IS", "ENABLED_NOT" };

fn triName(state: views.TriState) []const u8 {
    return tri_names[@backingInt(state)];
}

fn triState(name: []const u8) views.TriState {
    for (tri_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @fromBackingInt(@intCast(i));
    return .disabled;
}

const sort_names = [_]struct { []const u8, views.SortMode }{
    .{ "ALPHABETICAL", .alphabetical },             .{ "LAST_READ", .last_read },
    .{ "LAST_MANGA_UPDATE", .last_update },         .{ "UNREAD_COUNT", .unread_count },
    .{ "TOTAL_CHAPTERS", .total_chapters },         .{ "LATEST_CHAPTER", .latest_chapter },
    .{ "CHAPTER_FETCH_DATE", .chapter_fetch_date }, .{ "DATE_ADDED", .date_added },
    .{ "TRACKER_MEAN", .tracker_mean },             .{ "RANDOM", .random },
};

/// Mihon's `LibrarySort` string, e.g. "ALPHABETICAL,ASCENDING".
fn sortString(a: std.mem.Allocator, flags: u32) ![]const u8 {
    const sort: views.LibrarySort = .decode(flags);
    const name = for (sort_names) |entry| {
        if (entry[1] == sort.mode) break entry[0];
    } else "ALPHABETICAL";
    return std.fmt.allocPrint(a, "{s},{s}", .{ name, if (sort.ascending) "ASCENDING" else "DESCENDING" });
}

fn sortFlags(text: []const u8) u32 {
    var parts = std.mem.splitScalar(u8, text, ',');
    const type_name = parts.next() orelse "";
    const direction = parts.next() orelse "";
    const mode = for (sort_names) |entry| {
        if (std.mem.eql(u8, entry[0], type_name)) break entry[1];
    } else .alphabetical;
    return (views.LibrarySort{ .mode = mode, .ascending = std.mem.eql(u8, direction, "ASCENDING") }).encode(0);
}

const update_restrictions = [_]struct { []const u8, []const u8 }{
    .{ "manga_ongoing", "skip_completed" },
    .{ "manga_fully_read", "skip_unread" },
    .{ "manga_started", "skip_not_started" },
    .{ "manga_outside_release_period", "skip_outside_release_period" },
};

const device_restrictions = [_]struct { []const u8, []const u8 }{
    .{ "wifi", "only_wifi" },
    .{ "network_not_metered", "only_unmetered" },
    .{ "ac", "only_charging" },
};

// Mihon's chapter display defaults are six longs that make up the bits of
// a title's chapter flags.
const chapter_defaults = [_]struct { []const u8, u32 }{
    .{ "default_chapter_filter_by_read", 0x6 },
    .{ "default_chapter_filter_by_downloaded", 0x18 },
    .{ "default_chapter_filter_by_bookmarked", 0x60 },
    .{ "default_chapter_sort_by_source_or_number", 0x300 },
    .{ "default_chapter_display_by_name_or_number", 0x100000 },
    .{ "default_chapter_sort_by_ascending_or_descending", 0x1 },
};

const migration_bits = struct {
    const chapters: i32 = 0b1;
    const categories: i32 = 0b10;
    const custom_cover: i32 = 0b1000;
    const remove_downloads: i32 = 0b10000;
    const notes: i32 = 0b100000;
};

fn idSet(a: std.mem.Allocator, ids: []const u32) ![]const []const u8 {
    const out = try a.alloc([]const u8, ids.len);
    for (ids, out) |id, *s| s.* = try std.fmt.allocPrint(a, "{d}", .{id});
    return out;
}

fn idSetI64(a: std.mem.Allocator, ids: []const i64) ![]const []const u8 {
    const out = try a.alloc([]const u8, ids.len);
    for (ids, out) |id, *s| s.* = try std.fmt.allocPrint(a, "{d}", .{id});
    return out;
}

fn longList(a: std.mem.Allocator, ids: []const u32) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (ids, 0..) |id, i| {
        if (i > 0) try out.append(a, ',');
        try out.print(a, "{d}", .{id});
    }
    return out.items;
}

/// libtachi's settings as Mihon's preferences, then the Mihon preferences
/// libtachi only keeps.
pub fn fromSettings(a: std.mem.Allocator, s: Settings) ![]const Preference {
    var out: std.ArrayList(Preference) = .empty;
    const P = struct {
        fn add(list: *std.ArrayList(Preference), arena: std.mem.Allocator, key: []const u8, value: Value) !void {
            try list.append(arena, .{ .key = key, .value = value });
        }
    };
    const u = s.update;
    var restrictions: std.ArrayList([]const u8) = .empty;
    inline for (update_restrictions) |entry| if (@field(u, entry[1])) try restrictions.append(a, entry[0]);
    try P.add(&out, a, "library_update_manga_restriction", .{ .string_set = restrictions.items });
    var device: std.ArrayList([]const u8) = .empty;
    inline for (device_restrictions) |entry| if (@field(u, entry[1])) try device.append(a, entry[0]);
    try P.add(&out, a, "library_update_restriction", .{ .string_set = device.items });
    try P.add(&out, a, "pref_library_update_interval_key", .{ .int = u.interval_hours });
    try P.add(&out, a, "library_update_categories", .{ .string_set = try idSet(a, u.categories) });
    try P.add(&out, a, "library_update_categories_exclude", .{ .string_set = try idSet(a, u.exclude_categories) });
    try P.add(&out, a, "auto_update_metadata", .{ .boolean = u.metadata });
    try P.add(&out, a, "pref_update_library_manga_titles", .{ .boolean = u.titles });
    var duplicates: std.ArrayList([]const u8) = .empty;
    if (u.mark_new_duplicates_read) try duplicates.append(a, "new");
    if (u.mark_existing_duplicates_read) try duplicates.append(a, "existing");
    try P.add(&out, a, "mark_duplicate_read_chapter_read", .{ .string_set = duplicates.items });

    const d = s.downloads;
    try P.add(&out, a, "download_new", .{ .boolean = d.new_chapters });
    try P.add(&out, a, "download_new_unread_chapters_only", .{ .boolean = d.new_unread_only });
    try P.add(&out, a, "download_new_categories", .{ .string_set = try idSet(a, d.new_categories) });
    try P.add(&out, a, "download_new_categories_exclude", .{ .string_set = try idSet(a, d.new_exclude_categories) });
    try P.add(&out, a, "pref_remove_after_marked_as_read_key", .{ .boolean = d.remove_after_marked_read });
    try P.add(&out, a, "remove_after_read_slots", .{ .int = d.remove_after_read_slots });
    try P.add(&out, a, "pref_remove_bookmarked", .{ .boolean = d.remove_bookmarked });
    try P.add(&out, a, "remove_exclude_categories", .{ .string_set = try idSet(a, d.remove_exclude_categories) });
    try P.add(&out, a, "download_parallel_source_limit", .{ .int = d.parallel_sources });
    try P.add(&out, a, "download_parallel_page_limit", .{ .int = d.parallel_pages });
    try P.add(&out, a, "auto_download_while_reading", .{ .int = d.ahead });
    try P.add(&out, a, "disallow_non_ascii_filenames", .{ .boolean = d.disallow_non_ascii_filenames });
    try P.add(&out, a, "pref_enable_chapter_name_hash", .{ .boolean = d.chapter_name_hash });
    try P.add(&out, a, "save_chapter_as_cbz", .{ .boolean = d.cbz });

    const r = s.reader;
    try P.add(&out, a, "skip_read", .{ .boolean = r.skip_read });
    try P.add(&out, a, "skip_filtered", .{ .boolean = r.skip_filtered });
    try P.add(&out, a, "skip_dupe", .{ .boolean = r.skip_duplicates });
    try P.add(&out, a, "incognito_extensions", .{ .string_set = r.incognito_extensions });

    const b = s.browse;
    try P.add(&out, a, "source_languages", .{ .string_set = b.languages });
    try P.add(&out, a, "hidden_catalogues", .{ .string_set = try idSetI64(a, b.hidden_sources) });
    try P.add(&out, a, "pinned_catalogues", .{ .string_set = try idSetI64(a, b.pinned_sources) });
    const m = b.migration;
    const flags: i32 = (if (m.chapters) migration_bits.chapters else 0) | (if (m.categories) migration_bits.categories else 0) |
        migration_bits.custom_cover | (if (m.remove_downloads) migration_bits.remove_downloads else 0) | (if (m.notes) migration_bits.notes else 0);
    try P.add(&out, a, "migration_flags", .{ .int = flags });

    const l = s.library;
    try P.add(&out, a, "pref_filter_library_downloaded_v2", .{ .string = triName(l.filters.downloaded) });
    try P.add(&out, a, "pref_filter_library_unread_v2", .{ .string = triName(l.filters.unread) });
    try P.add(&out, a, "pref_filter_library_started_v2", .{ .string = triName(l.filters.started) });
    try P.add(&out, a, "pref_filter_library_bookmarked_v2", .{ .string = triName(l.filters.bookmarked) });
    try P.add(&out, a, "pref_filter_library_completed_v2", .{ .string = triName(l.filters.completed) });
    try P.add(&out, a, "pref_filter_library_interval_custom", .{ .string = triName(l.filters.interval_custom) });
    for (l.filters.tracked) |t| try P.add(&out, a, try std.fmt.allocPrint(a, "pref_filter_library_tracked_{d}_v2", .{t.tracker_id}), .{ .string = triName(t.state) });
    try P.add(&out, a, "library_sorting_mode", .{ .string = try sortString(a, l.sort) });
    try P.add(&out, a, "categorized_display", .{ .boolean = l.per_category_sort });
    try P.add(&out, a, "library_random_sort_seed", .{ .int = @truncate(@as(i64, @bitCast(l.random_seed))) });
    try P.add(&out, a, "default_category", .{ .int = if (l.default_category) |c| @intCast(c) else -1 });
    try P.add(&out, a, "auto_clear_chapter_cache", .{ .boolean = l.auto_clear_chapter_cache });
    for (chapter_defaults) |entry| try P.add(&out, a, entry[0], .{ .long = l.default_chapter_flags & entry[1] });

    const up = s.updates;
    try P.add(&out, a, "pref_filter_updates_downloaded", .{ .string = triName(up.downloaded) });
    try P.add(&out, a, "pref_filter_updates_unread", .{ .string = triName(up.unread) });
    try P.add(&out, a, "pref_filter_updates_started", .{ .string = triName(up.started) });
    try P.add(&out, a, "pref_filter_updates_bookmarked", .{ .string = triName(up.bookmarked) });
    try P.add(&out, a, "pref_filter_updates_hide_excluded_scanlators", .{ .boolean = up.hide_excluded_scanlators });
    try P.add(&out, a, "pref_filter_updates_included_categories", .{ .string = try longList(a, up.categories) });
    try P.add(&out, a, "pref_filter_updates_excluded_categories", .{ .string = try longList(a, up.exclude_categories) });
    try P.add(&out, a, "pref_filter_upcoming_included_categories", .{ .string = try longList(a, up.upcoming_categories) });
    try P.add(&out, a, "pref_filter_upcoming_excluded_categories", .{ .string = try longList(a, up.upcoming_exclude_categories) });

    for (s.mihon_preferences) |extra| {
        const mapped = for (out.items) |p| {
            if (std.mem.eql(u8, p.key, extra.key)) break true;
        } else false;
        if (!mapped) try out.append(a, extra);
    }
    return out.items;
}

/// A category id in a backup and the library's category it became.
pub const CategoryMapping = struct { backup_id: i64, id: u32 };

/// Applies Mihon preferences to `base`, as Mihon's restore does: category
/// ids through `categories` (by name, as Mihon matches them), values of the
/// wrong type ignored. Preferences libtachi has no setting for go to
/// `mihon_preferences`.
pub fn applyToSettings(a: std.mem.Allocator, base: Settings, prefs: []const Preference, categories: []const CategoryMapping) !Settings {
    var s = base;
    var extras: std.ArrayList(Preference) = .empty;
    try extras.appendSlice(a, base.mihon_preferences);
    var tracked: std.ArrayList(views.TrackerFilter) = .empty;
    try tracked.appendSlice(a, base.library.filters.tracked);
    for (prefs) |p| {
        if (isAppState(p.key)) continue;
        if (!try applyOne(a, &s, p, categories, &tracked)) {
            for (extras.items) |*e| {
                if (std.mem.eql(u8, e.key, p.key)) {
                    e.* = p;
                    break;
                }
            } else try extras.append(a, p);
        }
    }
    s.library.filters.tracked = tracked.items;
    s.mihon_preferences = extras.items;
    return s;
}

fn mapIds(a: std.mem.Allocator, set: []const []const u8, categories: []const CategoryMapping) ![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    for (set) |text| {
        const id = std.fmt.parseInt(i64, text, 10) catch continue;
        // 0 is the default category, which every library has.
        if (id == 0) {
            try out.append(a, 0);
            continue;
        }
        for (categories) |c| if (c.backup_id == id) try out.append(a, c.id);
    }
    return out.items;
}

fn parseIds(a: std.mem.Allocator, set: []const []const u8) ![]const i64 {
    var out: std.ArrayList(i64) = .empty;
    for (set) |text| try out.append(a, std.fmt.parseInt(i64, text, 10) catch continue);
    return out.items;
}

fn parseLongList(a: std.mem.Allocator, text: []const u8) ![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| try out.append(a, std.fmt.parseInt(u32, std.mem.trim(u8, part, " "), 10) catch continue);
    return out.items;
}

fn has(set: []const []const u8, value: []const u8) bool {
    for (set) |v| if (std.mem.eql(u8, v, value)) return true;
    return false;
}

/// Applies one preference; false if libtachi has no setting for it.
fn applyOne(a: std.mem.Allocator, s: *Settings, p: Preference, categories: []const CategoryMapping, tracked: *std.ArrayList(views.TrackerFilter)) !bool {
    const key = p.key;
    const v = p.value;
    const eql = std.mem.eql;
    if (eql(u8, key, "library_update_manga_restriction")) {
        if (v != .string_set) return true;
        inline for (update_restrictions) |entry| @field(s.update, entry[1]) = has(v.string_set, entry[0]);
    } else if (eql(u8, key, "library_update_restriction")) {
        if (v != .string_set) return true;
        inline for (device_restrictions) |entry| @field(s.update, entry[1]) = has(v.string_set, entry[0]);
    } else if (eql(u8, key, "pref_library_update_interval_key")) {
        if (v == .int) s.update.interval_hours = std.math.cast(u16, v.int) orelse 0;
    } else if (eql(u8, key, "library_update_categories")) {
        if (v == .string_set) s.update.categories = try mapIds(a, v.string_set, categories);
    } else if (eql(u8, key, "library_update_categories_exclude")) {
        if (v == .string_set) s.update.exclude_categories = try mapIds(a, v.string_set, categories);
    } else if (eql(u8, key, "auto_update_metadata")) {
        if (v == .boolean) s.update.metadata = v.boolean;
    } else if (eql(u8, key, "pref_update_library_manga_titles")) {
        if (v == .boolean) s.update.titles = v.boolean;
    } else if (eql(u8, key, "mark_duplicate_read_chapter_read")) {
        if (v != .string_set) return true;
        s.update.mark_new_duplicates_read = has(v.string_set, "new");
        s.update.mark_existing_duplicates_read = has(v.string_set, "existing");
    } else if (eql(u8, key, "download_new")) {
        if (v == .boolean) s.downloads.new_chapters = v.boolean;
    } else if (eql(u8, key, "download_new_unread_chapters_only")) {
        if (v == .boolean) s.downloads.new_unread_only = v.boolean;
    } else if (eql(u8, key, "download_new_categories")) {
        if (v == .string_set) s.downloads.new_categories = try mapIds(a, v.string_set, categories);
    } else if (eql(u8, key, "download_new_categories_exclude")) {
        if (v == .string_set) s.downloads.new_exclude_categories = try mapIds(a, v.string_set, categories);
    } else if (eql(u8, key, "pref_remove_after_marked_as_read_key")) {
        if (v == .boolean) s.downloads.remove_after_marked_read = v.boolean;
    } else if (eql(u8, key, "remove_after_read_slots")) {
        if (v == .int) s.downloads.remove_after_read_slots = v.int;
    } else if (eql(u8, key, "pref_remove_bookmarked")) {
        if (v == .boolean) s.downloads.remove_bookmarked = v.boolean;
    } else if (eql(u8, key, "remove_exclude_categories")) {
        if (v == .string_set) s.downloads.remove_exclude_categories = try mapIds(a, v.string_set, categories);
    } else if (eql(u8, key, "download_parallel_source_limit")) {
        if (v == .int) s.downloads.parallel_sources = std.math.cast(u8, v.int) orelse s.downloads.parallel_sources;
    } else if (eql(u8, key, "download_parallel_page_limit")) {
        if (v == .int) s.downloads.parallel_pages = std.math.cast(u8, v.int) orelse s.downloads.parallel_pages;
    } else if (eql(u8, key, "auto_download_while_reading")) {
        if (v == .int) s.downloads.ahead = std.math.cast(u8, v.int) orelse 0;
    } else if (eql(u8, key, "disallow_non_ascii_filenames")) {
        if (v == .boolean) s.downloads.disallow_non_ascii_filenames = v.boolean;
    } else if (eql(u8, key, "pref_enable_chapter_name_hash")) {
        if (v == .boolean) s.downloads.chapter_name_hash = v.boolean;
    } else if (eql(u8, key, "save_chapter_as_cbz")) {
        if (v == .boolean) s.downloads.cbz = v.boolean;
    } else if (eql(u8, key, "skip_read")) {
        if (v == .boolean) s.reader.skip_read = v.boolean;
    } else if (eql(u8, key, "skip_filtered")) {
        if (v == .boolean) s.reader.skip_filtered = v.boolean;
    } else if (eql(u8, key, "skip_dupe")) {
        if (v == .boolean) s.reader.skip_duplicates = v.boolean;
    } else if (eql(u8, key, "incognito_extensions")) {
        if (v == .string_set) s.reader.incognito_extensions = v.string_set;
    } else if (eql(u8, key, "source_languages")) {
        if (v == .string_set) s.browse.languages = v.string_set;
    } else if (eql(u8, key, "hidden_catalogues")) {
        if (v == .string_set) s.browse.hidden_sources = try parseIds(a, v.string_set);
    } else if (eql(u8, key, "pinned_catalogues")) {
        if (v == .string_set) s.browse.pinned_sources = try parseIds(a, v.string_set);
    } else if (eql(u8, key, "migration_flags")) {
        if (v != .int) return true;
        s.browse.migration = .{
            .chapters = v.int & migration_bits.chapters != 0,
            .categories = v.int & migration_bits.categories != 0,
            .remove_downloads = v.int & migration_bits.remove_downloads != 0,
            .notes = v.int & migration_bits.notes != 0,
        };
    } else if (eql(u8, key, "pref_filter_library_downloaded_v2")) {
        if (v == .string) s.library.filters.downloaded = triState(v.string);
    } else if (eql(u8, key, "pref_filter_library_unread_v2")) {
        if (v == .string) s.library.filters.unread = triState(v.string);
    } else if (eql(u8, key, "pref_filter_library_started_v2")) {
        if (v == .string) s.library.filters.started = triState(v.string);
    } else if (eql(u8, key, "pref_filter_library_bookmarked_v2")) {
        if (v == .string) s.library.filters.bookmarked = triState(v.string);
    } else if (eql(u8, key, "pref_filter_library_completed_v2")) {
        if (v == .string) s.library.filters.completed = triState(v.string);
    } else if (eql(u8, key, "pref_filter_library_interval_custom")) {
        if (v == .string) s.library.filters.interval_custom = triState(v.string);
    } else if (std.mem.startsWith(u8, key, "pref_filter_library_tracked_") and std.mem.endsWith(u8, key, "_v2")) {
        const id = std.fmt.parseInt(i32, key["pref_filter_library_tracked_".len .. key.len - "_v2".len], 10) catch return false;
        if (v != .string) return true;
        for (tracked.items) |*t| {
            if (t.tracker_id == id) {
                t.state = triState(v.string);
                break;
            }
        } else try tracked.append(a, .{ .tracker_id = id, .state = triState(v.string) });
    } else if (eql(u8, key, "library_sorting_mode")) {
        if (v == .string) s.library.sort = sortFlags(v.string);
    } else if (eql(u8, key, "auto_clear_chapter_cache")) {
        if (v == .boolean) s.library.auto_clear_chapter_cache = v.boolean;
    } else if (eql(u8, key, "categorized_display")) {
        if (v == .boolean) s.library.per_category_sort = v.boolean;
    } else if (eql(u8, key, "library_random_sort_seed")) {
        if (v == .int) s.library.random_seed = @bitCast(@as(i64, v.int));
    } else if (eql(u8, key, "default_category")) {
        if (v != .int) return true;
        s.library.default_category = null;
        if (v.int == 0) s.library.default_category = 0;
        for (categories) |c| if (c.backup_id == v.int) {
            s.library.default_category = c.id;
        };
    } else if (eql(u8, key, "pref_filter_updates_downloaded")) {
        if (v == .string) s.updates.downloaded = triState(v.string);
    } else if (eql(u8, key, "pref_filter_updates_unread")) {
        if (v == .string) s.updates.unread = triState(v.string);
    } else if (eql(u8, key, "pref_filter_updates_started")) {
        if (v == .string) s.updates.started = triState(v.string);
    } else if (eql(u8, key, "pref_filter_updates_bookmarked")) {
        if (v == .string) s.updates.bookmarked = triState(v.string);
    } else if (eql(u8, key, "pref_filter_updates_hide_excluded_scanlators")) {
        if (v == .boolean) s.updates.hide_excluded_scanlators = v.boolean;
    } else if (eql(u8, key, "pref_filter_updates_included_categories")) {
        if (v == .string) s.updates.categories = try parseLongList(a, v.string);
    } else if (eql(u8, key, "pref_filter_updates_excluded_categories")) {
        if (v == .string) s.updates.exclude_categories = try parseLongList(a, v.string);
    } else if (eql(u8, key, "pref_filter_upcoming_included_categories")) {
        if (v == .string) s.updates.upcoming_categories = try parseLongList(a, v.string);
    } else if (eql(u8, key, "pref_filter_upcoming_excluded_categories")) {
        if (v == .string) s.updates.upcoming_exclude_categories = try parseLongList(a, v.string);
    } else {
        for (chapter_defaults) |entry| if (eql(u8, key, entry[0])) {
            if (v == .long) s.library.default_chapter_flags = (s.library.default_chapter_flags & ~entry[1]) | (@as(u32, @truncate(@as(u64, @bitCast(v.long)))) & entry[1]);
            return true;
        };
        return false;
    }
    return true;
}

// ---- source preferences ------------------------------------------------------------

/// The host's file form of one value: `{"t": type, "v": value}`.
const FileValue = struct {
    t: []const u8,
    v: std.json.Value,
};

/// Every source's preferences in `prefs_dir` (`source_<id>.json` files),
/// private ones only if `private`.
pub fn readSourcePreferences(a: std.mem.Allocator, io: Io, prefs_dir: []const u8, private: bool) ![]const backup.SourcePreferences {
    var dir = Io.Dir.cwd().openDir(io, prefs_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var out: std.ArrayList(backup.SourcePreferences) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.startsWith(u8, e.name, "source_") or !std.mem.endsWith(u8, e.name, ".json")) continue;
        const bytes = try dir.readFileAlloc(io, e.name, a, .limited(4 << 20));
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch continue;
        if (parsed != .object) continue;
        var prefs: std.ArrayList(Preference) = .empty;
        var fields = parsed.object.iterator();
        while (fields.next()) |field| {
            if (isAppState(field.key_ptr.*) or (!private and isPrivate(field.key_ptr.*))) continue;
            const value = fileValue(a, field.value_ptr.*) catch continue;
            try prefs.append(a, .{ .key = field.key_ptr.*, .value = value });
        }
        if (prefs.items.len == 0) continue;
        try out.append(a, .{ .key = try a.dupe(u8, e.name[0 .. e.name.len - ".json".len]), .prefs = prefs.items });
    }
    std.mem.sort(backup.SourcePreferences, out.items, {}, struct {
        fn less(_: void, x: backup.SourcePreferences, y: backup.SourcePreferences) bool {
            return std.mem.lessThan(u8, x.key, y.key);
        }
    }.less);
    return out.items;
}

fn fileValue(a: std.mem.Allocator, json: std.json.Value) !Value {
    const parsed = try std.json.parseFromValueLeaky(FileValue, a, json, .{ .ignore_unknown_fields = true });
    const t = parsed.t;
    const v = parsed.v;
    if (std.mem.eql(u8, t, "s") and v == .string) return .{ .string = v.string };
    if (std.mem.eql(u8, t, "b") and v == .bool) return .{ .boolean = v.bool };
    if (std.mem.eql(u8, t, "i") and v == .integer) return .{ .int = std.math.cast(i32, v.integer) orelse return error.InvalidValue };
    if (std.mem.eql(u8, t, "l") and v == .integer) return .{ .long = v.integer };
    if (std.mem.eql(u8, t, "f")) return .{ .float = switch (v) {
        .float => |f| @floatCast(f),
        .integer => |n| @floatFromInt(n),
        else => return error.InvalidValue,
    } };
    if (std.mem.eql(u8, t, "ss") and v == .array) {
        const set = try a.alloc([]const u8, v.array.items.len);
        for (v.array.items, set) |item, *s| s.* = if (item == .string) item.string else return error.InvalidValue;
        return .{ .string_set = set };
    }
    return error.InvalidValue;
}

/// Writes restored source preferences into `prefs_dir`, over the values
/// already there, as Mihon's restore does; the host reads them the next
/// time it starts.
pub fn writeSourcePreferences(a: std.mem.Allocator, io: Io, prefs_dir: []const u8, all: []const backup.SourcePreferences) !void {
    for (all) |source| {
        if (!std.mem.startsWith(u8, source.key, "source_") or std.mem.indexOfAny(u8, source.key, "/\\.") != null) continue;
        const path = try std.fs.path.join(a, &.{ prefs_dir, try std.fmt.allocPrint(a, "{s}.json", .{source.key}) });
        var object: std.json.ObjectMap = .empty;
        if (Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 << 20))) |bytes| {
            if (std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch null) |existing| if (existing == .object) {
                object = existing.object;
            };
        } else |_| {}
        for (source.prefs) |p| {
            if (isAppState(p.key)) continue;
            var entry: std.json.ObjectMap = .empty;
            switch (p.value) {
                .string => |s| {
                    try entry.put(a, "t", .{ .string = "s" });
                    try entry.put(a, "v", .{ .string = s });
                },
                .boolean => |b| {
                    try entry.put(a, "t", .{ .string = "b" });
                    try entry.put(a, "v", .{ .bool = b });
                },
                .int => |n| {
                    try entry.put(a, "t", .{ .string = "i" });
                    try entry.put(a, "v", .{ .integer = n });
                },
                .long => |n| {
                    try entry.put(a, "t", .{ .string = "l" });
                    try entry.put(a, "v", .{ .integer = n });
                },
                .float => |f| {
                    try entry.put(a, "t", .{ .string = "f" });
                    try entry.put(a, "v", .{ .float = f });
                },
                .string_set => |set| {
                    var array: std.json.Array = .init(a);
                    for (set) |s| try array.append(.{ .string = s });
                    try entry.put(a, "t", .{ .string = "ss" });
                    try entry.put(a, "v", .{ .array = array });
                },
            }
            try object.put(a, p.key, .{ .object = entry });
        }
        try Io.Dir.cwd().createDirPath(io, prefs_dir);
        try library.writeJsonAtomic(a, io, path, std.json.Value{ .object = object });
    }
}

// ---- tests ---------------------------------------------------------------------

const testing = std.testing;

test "settings survive a trip through Mihon's preferences" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var s: Settings = .{};
    s.update.skip_unread = false;
    s.update.categories = &.{ 3, 0 };
    s.downloads.remove_after_read_slots = 2;
    s.downloads.new_categories = &.{3};
    s.reader.skip_duplicates = true;
    s.browse.pinned_sources = &.{-42};
    s.browse.migration.notes = false;
    s.library.sort = (views.LibrarySort{ .mode = .unread_count, .ascending = false }).encode(0);
    s.library.filters.unread = .exclude;
    s.library.default_category = 3;
    s.library.default_chapter_flags = 0x1 | 0x4 | 0x100;
    s.updates.categories = &.{ 1, 2 };
    s.mihon_preferences = &.{.{ .key = "pref_display_mode_library", .value = .{ .string = "LIST" } }};
    const prefs = try fromSettings(a, s);
    // The backup's category 3 is the library's category 7 now.
    const back = try applyToSettings(a, .{}, prefs, &.{.{ .backup_id = 3, .id = 7 }});
    try testing.expect(!back.update.skip_unread and back.update.skip_completed);
    try testing.expectEqualSlices(u32, &.{ 7, 0 }, back.update.categories);
    try testing.expectEqualSlices(u32, &.{7}, back.downloads.new_categories);
    try testing.expectEqual(2, back.downloads.remove_after_read_slots);
    try testing.expect(back.reader.skip_duplicates);
    try testing.expectEqualSlices(i64, &.{-42}, back.browse.pinned_sources);
    try testing.expect(!back.browse.migration.notes and back.browse.migration.chapters);
    try testing.expectEqual(s.library.sort, back.library.sort);
    try testing.expectEqual(views.TriState.exclude, back.library.filters.unread);
    try testing.expectEqual(7, back.library.default_category.?);
    try testing.expectEqual(s.library.default_chapter_flags, back.library.default_chapter_flags);
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, back.updates.categories);
    try testing.expectEqual(1, back.mihon_preferences.len);
    try testing.expectEqualStrings("LIST", back.mihon_preferences[0].value.string);
    // App state never comes back.
    const ignored = try applyToSettings(a, .{}, &.{.{ .key = "__APP_STATE_incognito_mode", .value = .{ .boolean = true } }}, &.{});
    try testing.expectEqual(0, ignored.mihon_preferences.len);
}

test "source preferences read from and write to the host's files" {
    const io = testing.io;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "prefs");
    try tmp.dir.writeFile(io, .{ .sub_path = "prefs/source_7.json", .data =
        \\{"mirror": {"t": "s", "v": "b"}, "pages": {"t": "i", "v": 3}, "__PRIVATE_token": {"t": "s", "v": "x"}, "langs": {"t": "ss", "v": ["en", "fr"]}}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "prefs/app.json", .data = "{}" });
    const dir = try tmp.dir.realPathFileAlloc(io, "prefs", a);
    const read = try readSourcePreferences(a, io, dir, false);
    try testing.expectEqual(1, read.len);
    try testing.expectEqualStrings("source_7", read[0].key);
    try testing.expectEqual(3, read[0].prefs.len);
    try writeSourcePreferences(a, io, dir, &.{
        .{ .key = "source_7", .prefs = &.{.{ .key = "pages", .value = .{ .int = 5 } }} },
        .{ .key = "source_9", .prefs = &.{.{ .key = "dataSaver", .value = .{ .boolean = true } }} },
        .{ .key = "../escape", .prefs = &.{.{ .key = "x", .value = .{ .boolean = true } }} },
    });
    const again = try readSourcePreferences(a, io, dir, true);
    try testing.expectEqual(2, again.len);
    for (again[0].prefs) |p| if (std.mem.eql(u8, p.key, "pages")) try testing.expectEqual(5, p.value.int);
    try testing.expectEqual(4, again[0].prefs.len);
    try testing.expect(again[1].prefs[0].value.boolean);
}

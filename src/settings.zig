//! Engine settings, with Mihon's defaults (mihonapp/mihon 487c313, the
//! LibraryPreferences, DownloadPreferences and ReaderPreferences an engine
//! applies). Stored as a typed SQLite document, importing `settings.json`
//! once; a missing setting means the default. Display-only preferences are the app's.
const std = @import("std");
const Io = std.Io;
const persistence = @import("persistence.zig");
const views = @import("views.zig");
const backup = @import("backup.zig");

pub const Settings = struct {
    update: Update = .{},
    downloads: Downloads = .{},
    reader: Reader = .{},
    browse: Browse = .{},
    library: Library = .{},
    updates: Updates = .{},
    /// Mihon preferences from a restored backup that libtachi has no
    /// setting for, kept for the next backup.
    mihon_preferences: []const backup.Preference = &.{},
    tracking: Tracking = .{},

    pub const Tracking = struct {
        /// Reader completion (`pref_auto_update_manga_sync_key`).
        auto_update: bool = true,
        /// Manga-screen mark read (`pref_auto_update_manga_on_mark_read`).
        on_mark_read: enum { always, ask, never } = .always,
    };

    pub const Update = struct {
        /// Skip completed titles (`manga_ongoing`).
        skip_completed: bool = true,
        /// Skip titles with unread chapters (`manga_fully_read`).
        skip_unread: bool = true,
        /// Skip titles never read (`manga_started`).
        skip_not_started: bool = true,
        /// Skip titles not expected to release yet (`manga_outside_release_period`).
        skip_outside_release_period: bool = true,
        /// Only these categories, if any (`library_update_categories`); 0 is uncategorized.
        categories: []const u32 = &.{},
        /// Never these categories (`library_update_categories_exclude`).
        exclude_categories: []const u32 = &.{},
        /// Refresh details too, not just chapters (`auto_update_metadata`).
        metadata: bool = false,
        /// Let library titles take a source's new title (`pref_update_library_manga_titles`).
        titles: bool = false,
        /// Mark new chapters read when one with the same number is
        /// (`mark_duplicate_read_chapter_read` "new").
        mark_new_duplicates_read: bool = false,
        /// Mark other chapters with a just-read chapter's number read
        /// (`mark_duplicate_read_chapter_read` "existing").
        mark_existing_duplicates_read: bool = false,
        /// Hours between automatic library updates; 0 never (`pref_library_update_interval_key`).
        interval_hours: u16 = 0,
        /// Automatic updates only on Wi-Fi, an unmetered network, or while
        /// charging (`library_update_restriction`).
        only_wifi: bool = true,
        only_unmetered: bool = false,
        only_charging: bool = false,
        /// When the last library update started (`library_update_last_timestamp`).
        last_run: i64 = 0,
    };

    pub const Downloads = struct {
        /// Destination for new chapter downloads; existing pages retain their location.
        storage: enum { internal, sd_card } = .internal,
        /// Download new chapters a library update finds (`download_new`).
        new_chapters: bool = false,
        /// ...unless a chapter with the same number was read (`download_new_unread_chapters_only`).
        new_unread_only: bool = false,
        new_categories: []const u32 = &.{},
        new_exclude_categories: []const u32 = &.{},
        /// Delete a chapter's download when it is marked read (`pref_remove_after_marked_as_read_key`).
        remove_after_marked_read: bool = false,
        /// Delete the download this many chapters behind the one just
        /// finished; -1 never (`remove_after_read_slots`).
        remove_after_read_slots: i32 = -1,
        /// Keep bookmarked chapters' downloads (`pref_remove_bookmarked` off).
        remove_bookmarked: bool = false,
        /// Titles in these categories keep their read downloads (`remove_exclude_categories`).
        remove_exclude_categories: []const u32 = &.{},
        /// Download only on Wi-Fi (`pref_download_only_over_wifi_key`); the
        /// app reports the network with `Engine.setNetwork`.
        only_wifi: bool = true,
        /// Sources downloading at once (`download_parallel_source_limit`).
        parallel_sources: u8 = 5,
        /// Pages downloading at once per source (`download_parallel_page_limit`).
        parallel_pages: u8 = 5,
        /// Mihon's downloads layout names for import and export
        /// (`disallow_non_ascii_filenames`, `pref_enable_chapter_name_hash`).
        disallow_non_ascii_filenames: bool = false,
        chapter_name_hash: bool = false,
        /// Export chapters as CBZ archives rather than folders (`save_chapter_as_cbz`).
        cbz: bool = true,
        /// Unread chapters to queue once a quarter of a downloaded chapter
        /// is read, if the next is downloaded too; 0 never (`auto_download_while_reading`).
        ahead: u8 = 0,
    };

    pub const Reader = struct {
        /// Record no progress or history (`__APP_STATE_incognito_mode`).
        incognito: bool = false,
        /// Packages read in incognito regardless (`incognito_extensions`).
        incognito_extensions: []const []const u8 = &.{},
        /// Skip read chapters when moving to the next (`skip_read`).
        skip_read: bool = false,
        /// Skip chapters the chapter list filters hide (`skip_filtered`).
        skip_filtered: bool = true,
        /// Skip other chapters with the same number (`skip_dupe`).
        skip_duplicates: bool = false,
    };

    pub const Browse = struct {
        /// Languages whose sources are shown (`source_languages`).
        languages: []const []const u8 = &.{ "all", "en" },
        /// Hidden source ids (`hidden_catalogues`).
        hidden_sources: []const i64 = &.{},
        /// Pinned source ids (`pinned_catalogues`).
        pinned_sources: []const i64 = &.{},
        /// The source last browsed (`last_catalogue_source`); -1 none, 0 is local.
        last_source: i64 = -1,
        /// Global search only searches pinned sources.
        search_pinned_only: bool = true,
        /// Extensions shown by content warning (`enabled_content_warnings`):
        /// any of "safe", "mixed", "nsfw".
        content_warnings: []const []const u8 = &.{ "safe", "mixed", "nsfw" },
        /// What a migration carries over (`migration_flags`).
        migration: Migration = .{},
    };

    /// Mihon's migration flags, all on by default.
    pub const Migration = struct {
        /// Read state up to the highest chapter read, bookmarks and fetch dates.
        chapters: bool = true,
        categories: bool = true,
        notes: bool = true,
        /// Delete the old title's downloads.
        remove_downloads: bool = true,
    };

    pub const Library = struct {
        filters: views.LibraryFilters = .{},
        /// Only downloaded and local titles and chapters (`pref_downloaded_only`).
        downloaded_only: bool = false,
        /// The sort for new categories and titles in none, as `Category.flags`
        /// (`library_sorting_mode`); alphabetical, ascending.
        sort: u32 = 0x40,
        /// Each category keeps its own sort (`categorized_display`); otherwise
        /// a sort applies to all.
        per_category_sort: bool = false,
        /// Seed of the random sort (`library_random_sort_seed`).
        random_seed: u64 = 0,
        /// Category new titles go into; null none (`default_category`).
        default_category: ?u32 = null,
        /// Chapter list flags new titles start with (`default_chapter_*`).
        default_chapter_flags: u32 = 0,
        /// Empty the chapter cache when the app starts (`auto_clear_chapter_cache`).
        auto_clear_chapter_cache: bool = false,
    };

    pub const Updates = struct {
        downloaded: views.TriState = .disabled,
        unread: views.TriState = .disabled,
        started: views.TriState = .disabled,
        bookmarked: views.TriState = .disabled,
        hide_excluded_scanlators: bool = false,
        categories: []const u32 = &.{},
        exclude_categories: []const u32 = &.{},
        /// Categories for the upcoming feed (`pref_filter_upcoming_*_categories`).
        upcoming_categories: []const u32 = &.{},
        upcoming_exclude_categories: []const u32 = &.{},
        /// New chapters found since the feed was last seen
        /// (`library_unseen_updates_count`).
        unseen: u32 = 0,
    };

    pub const file_name = "settings.json";

    /// The settings in `dir`, allocated in `arena`; defaults if there are none.
    pub fn load(arena: std.mem.Allocator, io: Io, dir: []const u8) !Settings {
        return try persistence.load(Settings, arena, io, dir, "settings", file_name) orelse .{};
    }

    pub fn save(self: Settings, gpa: std.mem.Allocator, io: Io, dir: []const u8) !void {
        try persistence.save(gpa, io, dir, "settings", self);
    }
};

/// Whether `categories` (a title's; empty is uncategorized, 0) pass an
/// include list and an exclude list, exclusion winning, as Mihon filters
/// updates and auto-downloads.
pub fn categoryAllowed(categories: []const u32, include: []const u32, exclude: []const u32) bool {
    const own: []const u32 = if (categories.len == 0) &.{0} else categories;
    for (own) |c| for (exclude) |x| if (c == x) return false;
    if (include.len == 0) return true;
    for (own) |c| for (include) |i| if (c == i) return true;
    return false;
}

test "settings default to Mihon's and survive a round trip" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    var s = try Settings.load(a, io, dir);
    try std.testing.expect(s.update.skip_completed);
    try std.testing.expectEqual(-1, s.downloads.remove_after_read_slots);
    s.downloads.new_chapters = true;
    try s.save(std.testing.allocator, io, dir);
    try std.testing.expect((try Settings.load(a, io, dir)).downloads.new_chapters);
}

test "category filters treat uncategorized as 0 and let exclusion win" {
    try std.testing.expect(categoryAllowed(&.{}, &.{}, &.{}));
    try std.testing.expect(categoryAllowed(&.{}, &.{0}, &.{}));
    try std.testing.expect(!categoryAllowed(&.{}, &.{1}, &.{}));
    try std.testing.expect(!categoryAllowed(&.{ 1, 2 }, &.{1}, &.{2}));
    try std.testing.expect(categoryAllowed(&.{ 1, 3 }, &.{1}, &.{2}));
}

test "settings migrate legacy fields once without changing the backup" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", a);
    const original = "{\"downloads\":{\"storage\":\"sd_card\",\"parallel_pages\":3},\"reader\":{\"incognito\":true},\"future_field\":true}";
    try tmp.dir.writeFile(t.io, .{ .sub_path = Settings.file_name, .data = original });
    const first = try Settings.load(a, t.io, dir);
    try t.expectEqual(.sd_card, first.downloads.storage);
    try t.expectEqual(3, first.downloads.parallel_pages);
    try t.expect(first.reader.incognito);
    try t.expect(first.update.skip_completed);
    try (Settings{}).save(a, t.io, dir);
    const restored = try Settings.load(a, t.io, dir);
    try t.expectEqual(.internal, restored.downloads.storage);
    try t.expect(!restored.reader.incognito);
    try t.expectEqualStrings(original, try tmp.dir.readFileAlloc(t.io, Settings.file_name, a, .unlimited));
}

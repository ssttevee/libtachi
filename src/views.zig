//! Mihon's views of the library (mihonapp/mihon 487c313): the library with
//! its filters, sorts and categories; a title's chapter list and the
//! reader's; the updates, history and upcoming feeds; and library stats.
//! Pure functions over a loaded `Library`, cheap enough for every redraw.
const std = @import("std");
const library = @import("library.zig");
const settings = @import("settings.zig");

const Library = library.Library;
const Manga = library.Manga;
const Chapter = library.Chapter;
const ms_per_day = std.time.ms_per_day;

/// Mihon's three-way filter: off, only matching, or only not matching.
pub const TriState = enum {
    disabled,
    include,
    exclude,

    fn passes(self: TriState, value: bool) bool {
        return switch (self) {
            .disabled => true,
            .include => value,
            .exclude => !value,
        };
    }
};

// ---- chapter lists -------------------------------------------------------------

pub const ChapterSort = enum(u32) {
    /// The source's order.
    source = 0,
    number = 0x100,
    upload = 0x200,
    alphabetical = 0x300,
};

/// Mihon's per-title chapter list bitfield (`Manga.chapter_flags`), decoded.
pub const ChapterFlags = struct {
    /// Oldest first; newest first is the default.
    ascending: bool = false,
    /// `include` shows only unread chapters, `exclude` only read ones.
    unread: TriState = .disabled,
    downloaded: TriState = .disabled,
    bookmarked: TriState = .disabled,
    sort: ChapterSort = .source,
    /// List chapters by number rather than by name.
    display_number: bool = false,

    const direction_mask = 0x1;
    const unread_mask = 0x6;
    const downloaded_mask = 0x18;
    const bookmarked_mask = 0x60;
    const sort_mask = 0x300;
    const display_mask = 0x100000;
    const mask = direction_mask | unread_mask | downloaded_mask | bookmarked_mask | sort_mask | display_mask;

    pub fn decode(bits: u32) ChapterFlags {
        return .{
            .ascending = bits & direction_mask != 0,
            .unread = tri(bits & unread_mask, 0x2, 0x4),
            .downloaded = tri(bits & downloaded_mask, 0x8, 0x10),
            .bookmarked = tri(bits & bookmarked_mask, 0x20, 0x40),
            .sort = @enumFromInt(bits & sort_mask),
            .display_number = bits & display_mask != 0,
        };
    }

    /// The bits for these flags, keeping bits of `old` they don't cover.
    pub fn encode(self: ChapterFlags, old: u32) u32 {
        return (old & ~@as(u32, mask)) |
            @as(u32, @intFromBool(self.ascending)) |
            untri(self.unread, 0x2, 0x4) |
            untri(self.downloaded, 0x8, 0x10) |
            untri(self.bookmarked, 0x20, 0x40) |
            @intFromEnum(self.sort) |
            (if (self.display_number) @as(u32, display_mask) else 0);
    }

    /// Picks a sort as Mihon's chapter settings do: a different sort
    /// starts ascending, the same one flips direction.
    pub fn selectSort(self: ChapterFlags, sort: ChapterSort) ChapterFlags {
        var next = self;
        next.ascending = if (sort == self.sort) !self.ascending else true;
        next.sort = sort;
        return next;
    }

    fn tri(bits: u32, include: u32, exclude: u32) TriState {
        return if (bits == include) .include else if (bits == exclude) .exclude else .disabled;
    }

    fn untri(state: TriState, include: u32, exclude: u32) u32 {
        return switch (state) {
            .disabled => 0,
            .include => include,
            .exclude => exclude,
        };
    }
};

/// Local chapters count as downloaded.
fn available(manga: Manga, chapter: Chapter) bool {
    return manga.local() or chapter.downloaded();
}

fn chapterPasses(manga: Manga, chapter: Chapter, flags: ChapterFlags, downloaded_only: bool) bool {
    const downloaded: TriState = if (downloaded_only) .include else flags.downloaded;
    return flags.unread.passes(!chapter.read) and
        downloaded.passes(available(manga, chapter)) and
        flags.bookmarked.passes(chapter.bookmark);
}

/// Sorts as Mihon's chapter list does; the sort is stable, so ties keep
/// their order.
pub fn sortChapters(chapters: []Chapter, sort: ChapterSort, ascending: bool) void {
    const Context = struct { sort: ChapterSort, ascending: bool };
    std.mem.sort(Chapter, chapters, Context{ .sort = sort, .ascending = ascending }, struct {
        fn less(c: Context, a: Chapter, b: Chapter) bool {
            // Each comparison is for newest first; ascending swaps it.
            const x, const y = if (c.ascending) .{ b, a } else .{ a, b };
            return switch (c.sort) {
                .source => x.source_order < y.source_order,
                .number => x.number > y.number,
                .upload => x.date_upload > y.date_upload,
                .alphabetical => std.ascii.orderIgnoreCase(x.title, y.title) == .gt,
            };
        }
    }.less);
}

/// A title's chapter list as its flags show it: excluded groups hidden,
/// filtered, then sorted. `downloaded_only` is Mihon's global
/// downloaded-only mode.
pub fn chapterList(arena: std.mem.Allocator, manga: Manga, downloaded_only: bool) ![]Chapter {
    const flags: ChapterFlags = .decode(manga.chapter_flags);
    var list: std.ArrayList(Chapter) = .empty;
    for (manga.chapters) |ch| {
        if (manga.excludes(ch.scanlator) or !chapterPasses(manga, ch, flags, downloaded_only)) continue;
        try list.append(arena, ch);
    }
    sortChapters(list.items, flags.sort, flags.ascending);
    return list.items;
}

/// The chapters before `chapter_id` in reading order as the chapter list
/// shows them, for Mihon's "mark previous as read".
pub fn previousChapters(arena: std.mem.Allocator, manga: Manga, chapter_id: []const u8, downloaded_only: bool) ![]const []const u8 {
    const list = try chapterList(arena, manga, downloaded_only);
    if (!ChapterFlags.decode(manga.chapter_flags).ascending) std.mem.reverse(Chapter, list);
    const at = for (list, 0..) |ch, i| {
        if (std.mem.eql(u8, ch.id, chapter_id)) break i;
    } else return &.{};
    const ids = try arena.alloc([]const u8, at);
    for (list[0..at], ids) |ch, *id| id.* = ch.id;
    return ids;
}

pub const ReaderChapters = struct {
    /// In reading order.
    chapters: []Chapter,
    /// Index of the chapter being read.
    current: usize,

    pub fn next(self: ReaderChapters) ?Chapter {
        return if (self.current + 1 < self.chapters.len) self.chapters[self.current + 1] else null;
    }

    pub fn previous(self: ReaderChapters) ?Chapter {
        return if (self.current > 0) self.chapters[self.current - 1] else null;
    }
};

/// The chapters the reader moves through from `chapter_id`, as Mihon's
/// reader builds them: excluded groups left out, read or filtered chapters
/// skipped if the settings say so, one chapter per number if duplicates are
/// skipped, in reading order by the title's sort. The current chapter always
/// stays. Null if the title has no such chapter.
pub fn readerChapters(arena: std.mem.Allocator, manga: Manga, chapter_id: []const u8, reader: settings.Settings.Reader, downloaded_only: bool) !?ReaderChapters {
    const flags: ChapterFlags = .decode(manga.chapter_flags);
    const current = for (manga.chapters) |ch| {
        if (std.mem.eql(u8, ch.id, chapter_id)) break ch;
    } else return null;
    var list: std.ArrayList(Chapter) = .empty;
    for (manga.chapters) |ch| {
        const is_current = std.mem.eql(u8, ch.id, chapter_id);
        if (!is_current) {
            if (manga.excludes(ch.scanlator)) continue;
            if (reader.skip_read and ch.read) continue;
            if (reader.skip_filtered and !chapterPasses(manga, ch, flags, false)) continue;
            if (downloaded_only and !available(manga, ch)) continue;
        }
        try list.append(arena, ch);
    }
    sortChapters(list.items, flags.sort, true);
    const chapters = if (reader.skip_duplicates) try removeDuplicates(arena, list.items, current) else list.items;
    const at = for (chapters, 0..) |ch, i| {
        if (std.mem.eql(u8, ch.id, chapter_id)) break i;
    } else unreachable;
    return .{ .chapters = chapters, .current = at };
}

/// One chapter per exact number, unrecognized ones counting as one number,
/// in order of first appearance: `current` itself, else one from its group,
/// else the first (Mihon's `removeDuplicates`).
pub fn removeDuplicates(arena: std.mem.Allocator, chapters: []const Chapter, current: Chapter) ![]Chapter {
    var kept: std.ArrayList(Chapter) = .empty;
    for (chapters, 0..) |ch, i| {
        const seen = for (chapters[0..i]) |earlier| {
            if (earlier.number == ch.number) break true;
        } else false;
        if (seen) continue;
        var pick = ch;
        var rank: u2 = 0;
        for (chapters[i..]) |other| {
            if (other.number != ch.number) continue;
            const r: u2 = if (std.mem.eql(u8, other.id, current.id)) 2 else if (sameGroup(other.scanlator, current.scanlator)) 1 else 0;
            if (r > rank) {
                pick = other;
                rank = r;
            }
        }
        try kept.append(arena, pick);
    }
    return kept.items;
}

/// Mihon's `GetNextChapters` from `from`: unread chapters of groups not
/// excluded, in reading order by the title's sort, starting at `from` (or
/// the first if it isn't among them).
pub fn nextUnread(arena: std.mem.Allocator, manga: Manga, from: []const u8) ![]Chapter {
    var list: std.ArrayList(Chapter) = .empty;
    for (manga.chapters) |ch| if (!ch.read and !manga.excludes(ch.scanlator)) try list.append(arena, ch);
    sortChapters(list.items, ChapterFlags.decode(manga.chapter_flags).sort, true);
    const start = for (list.items, 0..) |ch, i| {
        if (std.mem.eql(u8, ch.id, from)) break i;
    } else 0;
    return list.items[start..];
}

fn sameGroup(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

// ---- the library ---------------------------------------------------------------

pub const SortMode = enum(u32) {
    alphabetical = 0,
    last_read = 4,
    last_update = 8,
    unread_count = 12,
    total_chapters = 16,
    latest_chapter = 20,
    chapter_fetch_date = 24,
    date_added = 28,
    tracker_mean = 32,
    random = 60,
};

/// A library sort, as Mihon packs it in `Category.flags`.
pub const LibrarySort = struct {
    mode: SortMode = .alphabetical,
    ascending: bool = true,

    const mode_mask = 0x3c;
    const ascending_bit = 0x40;

    pub fn decode(flags: u32) LibrarySort {
        const mode = std.enums.fromInt(SortMode, flags & mode_mask) orelse .alphabetical;
        return .{ .mode = mode, .ascending = flags & ascending_bit != 0 };
    }

    /// The flags for this sort, keeping bits of `old` it doesn't cover.
    pub fn encode(self: LibrarySort, old: u32) u32 {
        return (old & ~@as(u32, mode_mask | ascending_bit)) | @intFromEnum(self.mode) | (if (self.ascending) @as(u32, ascending_bit) else 0);
    }
};

pub const TrackerFilter = struct { tracker_id: i32, state: TriState };

pub const LibraryFilters = struct {
    /// Local titles and titles with any downloaded chapter.
    downloaded: TriState = .disabled,
    unread: TriState = .disabled,
    /// Any chapter read.
    started: TriState = .disabled,
    bookmarked: TriState = .disabled,
    completed: TriState = .disabled,
    /// A user-set update interval; only applies while updates skip titles
    /// outside their release period.
    interval_custom: TriState = .disabled,
    /// One per logged-in tracker; titles must be on any included tracker and
    /// on no excluded one.
    tracked: []const TrackerFilter = &.{},
};

pub const LibraryOptions = struct {
    filters: LibraryFilters = .{},
    /// Mihon's global downloaded-only mode.
    downloaded_only: bool = false,
    /// From `Settings.update`; gates the custom interval filter.
    skip_outside_release_period: bool = true,
    /// The sort of titles in no category; others sort by their own flags.
    default_sort: LibrarySort = .{},
    /// Seed for the random sort.
    random_seed: u64 = 0,
    /// Only titles this accepts, as for a search; null accepts all.
    match: ?Matcher = null,
    /// A track's score on a 10-point scale, or null if its tracker isn't
    /// logged in. Null leaves every title unscored for the tracker sort.
    track_score: ?*const fn (library.Track) ?f64 = null,
};

pub const Matcher = struct {
    context: *const anyopaque,
    matches: *const fn (context: *const anyopaque, manga: *const Manga, counts: library.Counts) bool,
};

pub const Entry = struct {
    manga: *const Manga,
    counts: library.Counts,
};

pub const Group = struct {
    /// Id 0 is the default category, for titles in no other.
    category: library.Category,
    entries: []Entry,
};

/// The library as Mihon shows it: favorites, filtered, grouped by category
/// in category order (a title in several categories is in each), and sorted
/// by each category's flags. The default category is left out when it would
/// be empty and other categories exist.
pub fn libraryView(arena: std.mem.Allocator, lib: Library, options: LibraryOptions) ![]Group {
    var categories: std.ArrayList(library.Category) = .empty;
    try categories.append(arena, .{ .id = 0, .name = "", .flags = options.default_sort.encode(0) });
    const user = try arena.dupe(library.Category, lib.categories);
    std.mem.sort(library.Category, user, {}, struct {
        fn less(_: void, a: library.Category, b: library.Category) bool {
            return a.order < b.order;
        }
    }.less);
    try categories.appendSlice(arena, user);

    var any_default = false;
    for (lib.manga) |m| if (m.favorite and m.categories.len == 0) {
        any_default = true;
    };
    const favorites = for (lib.manga) |m| {
        if (m.favorite) break true;
    } else false;
    const shown = if (favorites and !any_default and categories.items.len > 1) categories.items[1..] else categories.items;

    const groups = try arena.alloc(Group, shown.len);
    for (shown, groups) |category, *group| {
        var entries: std.ArrayList(Entry) = .empty;
        for (lib.manga) |*m| {
            if (!m.favorite or !inCategory(m.*, category.id)) continue;
            const counts = m.counts();
            if (!libraryPasses(m.*, counts, options)) continue;
            if (options.match) |matcher| if (!matcher.matches(matcher.context, m, counts)) continue;
            try entries.append(arena, .{ .manga = m, .counts = counts });
        }
        sortLibrary(entries.items, .decode(category.flags), options);
        group.* = .{ .category = category, .entries = entries.items };
    }
    return groups;
}

fn inCategory(manga: Manga, id: u32) bool {
    if (manga.categories.len == 0) return id == 0;
    return std.mem.indexOfScalar(u32, manga.categories, id) != null;
}

fn libraryPasses(manga: Manga, counts: library.Counts, options: LibraryOptions) bool {
    const f = options.filters;
    const downloaded: TriState = if (options.downloaded_only) .include else f.downloaded;
    const interval: TriState = if (options.skip_outside_release_period) f.interval_custom else .disabled;
    if (!downloaded.passes(manga.local() or counts.downloaded > 0)) return false;
    if (!f.unread.passes(counts.unread > 0)) return false;
    if (!f.started.passes(counts.read > 0)) return false;
    if (!f.bookmarked.passes(counts.bookmarked > 0)) return false;
    if (!f.completed.passes(manga.status() == 2)) return false;
    if (!interval.passes(manga.fetch_interval < 0)) return false;
    var included = false;
    var any_include = false;
    for (f.tracked) |t| {
        const on = for (manga.tracks) |track| {
            if (track.tracker_id == t.tracker_id) break true;
        } else false;
        switch (t.state) {
            .disabled => {},
            .include => {
                any_include = true;
                included = included or on;
            },
            .exclude => if (on) return false,
        }
    }
    return !any_include or included;
}

fn sortLibrary(entries: []Entry, sort: LibrarySort, options: LibraryOptions) void {
    if (sort.mode == .random) {
        var prng: std.Random.DefaultPrng = .init(options.random_seed);
        prng.random().shuffle(Entry, entries);
        return;
    }
    const Context = struct { sort: LibrarySort, options: LibraryOptions };
    std.mem.sort(Entry, entries, Context{ .sort = sort, .options = options }, struct {
        fn less(c: Context, a: Entry, b: Entry) bool {
            const primary = order(c, a, b);
            if (primary != .eq) return primary == .lt;
            return std.ascii.orderIgnoreCase(a.manga.title, b.manga.title) == .lt;
        }

        /// The primary order, direction applied; titles break ties ascending.
        fn order(c: Context, a: Entry, b: Entry) std.math.Order {
            if (c.sort.mode == .unread_count) {
                // Titles with nothing unread come last either way.
                if ((a.counts.unread == 0) != (b.counts.unread == 0)) return if (a.counts.unread == 0) .gt else .lt;
            }
            const o: std.math.Order = switch (c.sort.mode) {
                .alphabetical => std.ascii.orderIgnoreCase(a.manga.title, b.manga.title),
                .last_read => std.math.order(a.counts.last_read, b.counts.last_read),
                .last_update => std.math.order(a.manga.last_update, b.manga.last_update),
                .unread_count => std.math.order(a.counts.unread, b.counts.unread),
                .total_chapters => std.math.order(a.counts.total, b.counts.total),
                .latest_chapter => std.math.order(a.counts.latest_upload, b.counts.latest_upload),
                .chapter_fetch_date => std.math.order(a.counts.latest_fetch, b.counts.latest_fetch),
                .date_added => std.math.order(a.manga.date_added, b.manga.date_added),
                .tracker_mean => orderFloat(trackerMean(a.manga.*, c.options.track_score), trackerMean(b.manga.*, c.options.track_score)),
                .random => .eq,
            };
            return if (c.sort.ascending) o else o.invert();
        }
    }.less);
}

fn orderFloat(a: f64, b: f64) std.math.Order {
    // NaN, a mean of no scores, sorts first.
    if (std.math.isNan(a) or std.math.isNan(b)) return std.math.order(@intFromBool(!std.math.isNan(a)), @intFromBool(!std.math.isNan(b)));
    return std.math.order(a, b);
}

/// The mean of a title's logged-in trackers' scores, zeros included; -1
/// if it has none.
fn trackerMean(manga: Manga, score: ?*const fn (library.Track) ?f64) f64 {
    const convert = score orelse return -1;
    var sum: f64 = 0;
    var n: usize = 0;
    for (manga.tracks) |t| if (convert(t)) |s| {
        sum += s;
        n += 1;
    };
    return if (n == 0) -1 else sum / @as(f64, @floatFromInt(n));
}

// ---- feeds ---------------------------------------------------------------------

pub const FeedItem = struct {
    manga: *const Manga,
    chapter: *const Chapter,
};

pub const UpdatesOptions = struct {
    downloaded: TriState = .disabled,
    unread: TriState = .disabled,
    /// Partly read: a page past the first but not finished.
    started: TriState = .disabled,
    bookmarked: TriState = .disabled,
    hide_excluded_scanlators: bool = false,
    categories: []const u32 = &.{},
    exclude_categories: []const u32 = &.{},
    downloaded_only: bool = false,
    /// Milliseconds since the epoch.
    now: i64,
    utc_offset_s: i32 = 0,
};

/// Mihon's updates feed: chapters that arrived after their title joined
/// the library, uploaded in the last three months, newest arrival first,
/// at most 500 before the downloaded filter.
pub fn updates(arena: std.mem.Allocator, lib: Library, options: UpdatesOptions) ![]FeedItem {
    const since = minusMonths(options.now, 3, options.utc_offset_s);
    var items: std.ArrayList(FeedItem) = .empty;
    for (lib.manga) |*m| {
        if (!m.favorite) continue;
        if (!settings.categoryAllowed(m.categories, options.categories, options.exclude_categories)) continue;
        for (m.chapters) |*ch| {
            if (ch.date_fetch <= m.date_added or ch.date_upload <= since) continue;
            if (options.hide_excluded_scanlators and m.excludes(ch.scanlator)) continue;
            if (!options.unread.passes(!ch.read) or !options.bookmarked.passes(ch.bookmark)) continue;
            switch (options.started) {
                .disabled => {},
                .include => if (ch.read or ch.last_page_read == 0) continue,
                .exclude => if (ch.read or ch.last_page_read != 0) continue,
            }
            try items.append(arena, .{ .manga = m, .chapter = ch });
        }
    }
    std.mem.sort(FeedItem, items.items, {}, struct {
        fn less(_: void, a: FeedItem, b: FeedItem) bool {
            return a.chapter.date_fetch > b.chapter.date_fetch;
        }
    }.less);
    const limited = items.items[0..@min(items.items.len, 500)];
    const downloaded: TriState = if (options.downloaded_only) .include else options.downloaded;
    var out: std.ArrayList(FeedItem) = .empty;
    for (limited) |item| if (downloaded.passes(available(item.manga.*, item.chapter.*))) try out.append(arena, item);
    return out.items;
}

/// Mihon's history: each title's most recently read chapter, latest first,
/// titles containing `search` (any case) only. Includes titles no longer in
/// the library.
pub fn history(arena: std.mem.Allocator, lib: Library, search: []const u8) ![]FeedItem {
    var items: std.ArrayList(FeedItem) = .empty;
    for (lib.manga) |*m| {
        if (search.len > 0 and std.ascii.findIgnoreCase(m.title, search) == null) continue;
        var latest: ?*const Chapter = null;
        for (m.chapters) |*ch| {
            if (ch.last_read == 0) continue;
            if (latest == null or ch.last_read > latest.?.last_read) latest = ch;
        }
        if (latest) |ch| try items.append(arena, .{ .manga = m, .chapter = ch });
    }
    std.mem.sort(FeedItem, items.items, {}, struct {
        fn less(_: void, a: FeedItem, b: FeedItem) bool {
            return a.chapter.last_read > b.chapter.last_read;
        }
    }.less);
    return items.items;
}

/// Mihon's upcoming: ongoing or publishing-finished library titles expected
/// to update today or later, soonest first.
pub fn upcoming(arena: std.mem.Allocator, lib: Library, categories: []const u32, exclude_categories: []const u32, now: i64, utc_offset_s: i32) ![]*const Manga {
    const today = dayStart(now, utc_offset_s);
    var items: std.ArrayList(*const Manga) = .empty;
    for (lib.manga) |*m| {
        const status = m.status();
        if (!m.favorite or (status != 1 and status != 4) or m.next_update == 0 or m.next_update < today) continue;
        if (!settings.categoryAllowed(m.categories, categories, exclude_categories)) continue;
        try items.append(arena, m);
    }
    std.mem.sort(*const Manga, items.items, {}, struct {
        fn less(_: void, a: *const Manga, b: *const Manga) bool {
            return a.next_update < b.next_update;
        }
    }.less);
    return items.items;
}

// ---- stats ---------------------------------------------------------------------

pub const Stats = struct {
    titles: usize = 0,
    /// Completed by the source and fully read.
    completed: usize = 0,
    started: usize = 0,
    local: usize = 0,
    chapters: usize = 0,
    read_chapters: usize = 0,
    /// Downloaded chapters of every title, in the library or not.
    downloaded_chapters: usize = 0,
    /// All reading time ever recorded, in milliseconds.
    read_ms: i64 = 0,
    /// Titles on a logged-in tracker.
    tracked: usize = 0,
    /// Mean of each scored title's mean tracker score; NaN if none is scored.
    mean_score: f64 = std.math.nan(f64),
    /// Titles a library update would consider, before release-period and
    /// fetch-once rules (as Mihon counts them).
    update_candidates: usize = 0,
};

/// Mihon's library stats. `track_score` is as in `LibraryOptions`.
pub fn stats(lib: Library, update: settings.Settings.Update, track_score: ?*const fn (library.Track) ?f64) Stats {
    var s: Stats = .{};
    var score_sum: f64 = 0;
    var scored: usize = 0;
    for (lib.manga) |m| {
        for (m.chapters) |ch| {
            s.read_ms += ch.read_ms;
            if (ch.downloaded() and !m.local()) s.downloaded_chapters += 1;
        }
        if (!m.favorite) continue;
        const c = m.counts();
        s.titles += 1;
        if (m.status() == 2 and c.unread == 0) s.completed += 1;
        if (c.read > 0) s.started += 1;
        if (m.local()) s.local += 1;
        s.chapters += c.total;
        s.read_chapters += c.read;
        if (track_score) |convert| {
            var on_tracker = false;
            var sum: f64 = 0;
            var n: usize = 0;
            for (m.tracks) |t| if (convert(t)) |score| {
                on_tracker = true;
                if (score > 0) {
                    sum += score;
                    n += 1;
                }
            };
            if (on_tracker) s.tracked += 1;
            if (n > 0) {
                score_sum += sum / @as(f64, @floatFromInt(n));
                scored += 1;
            }
        }
        if (settings.categoryAllowed(m.categories, update.categories, update.exclude_categories) and
            !(update.skip_completed and m.status() == 2) and
            !(update.skip_unread and c.unread != 0) and
            !(update.skip_not_started and c.total > 0 and c.read == 0)) s.update_candidates += 1;
    }
    if (scored > 0) s.mean_score = score_sum / @as(f64, @floatFromInt(scored));
    return s;
}

// ---- dates ---------------------------------------------------------------------

/// Midnight before `ms` in the zone `utc_offset_s` from UTC, as UTC milliseconds.
pub fn dayStart(ms: i64, utc_offset_s: i32) i64 {
    const offset_ms = @as(i64, utc_offset_s) * std.time.ms_per_s;
    return @divFloor(ms + offset_ms, ms_per_day) * ms_per_day - offset_ms;
}

pub const Date = struct { year: i64, month: u8, day: u8 };

/// Days since 1970-01-01 of a proleptic Gregorian date.
pub fn daysFromCivil(date: Date) i64 {
    const y = if (date.month <= 2) date.year - 1 else date.year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = date.month;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + date.day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn civilFromDays(days: i64) Date {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .year = yoe + era * 400 + @intFromBool(m <= 2), .month = @intCast(m), .day = @intCast(d) };
}

fn daysInMonth(year: i64, month: u8) u8 {
    const next: Date = if (month == 12) .{ .year = year + 1, .month = 1, .day = 1 } else .{ .year = year, .month = month + 1, .day = 1 };
    return @intCast(daysFromCivil(next) - daysFromCivil(.{ .year = year, .month = month, .day = 1 }));
}

/// `ms` moved back `months` calendar months in local time, the day clamped
/// to the month's length.
pub fn minusMonths(ms: i64, months: u32, utc_offset_s: i32) i64 {
    const offset_ms = @as(i64, utc_offset_s) * std.time.ms_per_s;
    const local = ms + offset_ms;
    const days = @divFloor(local, ms_per_day);
    const time = local - days * ms_per_day;
    const date = civilFromDays(days);
    const index = date.year * 12 + (date.month - 1) - months;
    const year = @divFloor(index, 12);
    const month: u8 = @intCast(index - year * 12 + 1);
    const day = @min(date.day, daysInMonth(year, month));
    return daysFromCivil(.{ .year = year, .month = month, .day = day }) * ms_per_day + time - offset_ms;
}

// ---- tests ---------------------------------------------------------------------

const testing = std.testing;

fn testChapter(id: []const u8, order: u32, number: f64) Chapter {
    return .{ .id = id, .title = id, .source_order = order, .number = number };
}

test "chapter flags round-trip Mihon's bits and keep the rest" {
    const bits: u32 = 0x1 | 0x4 | 0x8 | 0x40 | 0x300 | 0x100000 | 0x8000_0000;
    const flags: ChapterFlags = .decode(bits);
    try testing.expect(flags.ascending);
    try testing.expectEqual(TriState.exclude, flags.unread);
    try testing.expectEqual(TriState.include, flags.downloaded);
    try testing.expectEqual(TriState.exclude, flags.bookmarked);
    try testing.expectEqual(ChapterSort.alphabetical, flags.sort);
    try testing.expect(flags.display_number);
    try testing.expectEqual(bits, flags.encode(0x8000_0000));
    const by_number = flags.selectSort(.number);
    try testing.expect(by_number.ascending and by_number.sort == .number);
    try testing.expect(!by_number.selectSort(.number).ascending);
}

test "chapter list filters, sorts and marks previous in display order" {
    var a_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    var chapters = [_]Chapter{ testChapter("c1", 2, 1), testChapter("c2", 1, 2), testChapter("c3", 0, 3) };
    chapters[0].read = true;
    chapters[1].pages = &.{"p"};
    var m: Manga = .{ .id = "m", .title = "M", .source_id = 1, .chapters = &chapters };
    const newest = try chapterList(a, m, false);
    try testing.expectEqualStrings("c3", newest[0].id);
    try testing.expectEqualStrings("c1", newest[2].id);
    m.chapter_flags = (ChapterFlags{ .unread = .include }).encode(0);
    try testing.expectEqual(2, (try chapterList(a, m, false)).len);
    try testing.expectEqual(1, (try chapterList(a, m, true)).len);
    m.chapter_flags = (ChapterFlags{ .sort = .number, .ascending = true }).encode(0);
    try testing.expectEqualStrings("c1", (try chapterList(a, m, false))[0].id);
    const previous = try previousChapters(a, m, "c3", false);
    try testing.expectEqual(2, previous.len);
    try testing.expectEqualStrings("c1", previous[0]);
}

test "reader chapters skip read and duplicates but keep the current chapter" {
    var a_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    var chapters = [_]Chapter{ testChapter("1a", 4, 1), testChapter("2a", 3, 2), testChapter("2b", 2, 2), testChapter("3b", 1, 3), testChapter("x", 0, -1) };
    chapters[0].read = true;
    chapters[1].scanlator = "A";
    chapters[2].scanlator = "B";
    chapters[3].scanlator = "B";
    const m: Manga = .{ .id = "m", .title = "M", .source_id = 1, .chapters = &chapters };
    const r = (try readerChapters(a, m, "3b", .{ .skip_read = true, .skip_duplicates = true }, false)).?;
    try testing.expectEqual(3, r.chapters.len);
    try testing.expectEqualStrings("2b", r.previous().?.id);
    try testing.expectEqualStrings("x", r.next().?.id);
    const from_read = (try readerChapters(a, m, "1a", .{ .skip_read = true }, false)).?;
    try testing.expectEqual(0, from_read.current);
    try testing.expectEqual(5, from_read.chapters.len);
}

test "library view filters, groups by category and sorts by each category's flags" {
    var a_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    var read = [_]Chapter{testChapter("r", 0, 1)};
    read[0].read = true;
    const unread = [_]Chapter{ testChapter("u1", 0, 1), testChapter("u2", 1, 2) };
    const lib: Library = .{
        .manga = &.{
            .{ .id = "b", .title = "beta", .source_id = 1, .chapters = &read, .categories = &.{1} },
            .{ .id = "a", .title = "Alpha", .source_id = 1, .chapters = &unread, .categories = &.{ 1, 2 } },
            .{ .id = "c", .title = "Gamma", .source_id = 1, .favorite = false },
        },
        .categories = &.{
            .{ .id = 2, .name = "Two", .order = 1, .flags = (LibrarySort{ .mode = .unread_count, .ascending = false }).encode(0) },
            .{ .id = 1, .name = "One", .order = 0, .flags = (LibrarySort{}).encode(0) },
        },
    };
    const groups = try libraryView(a, lib, .{});
    try testing.expectEqual(2, groups.len);
    try testing.expectEqualStrings("One", groups[0].category.name);
    try testing.expectEqualStrings("Alpha", groups[0].entries[0].manga.title);
    try testing.expectEqualStrings("beta", groups[0].entries[1].manga.title);
    try testing.expectEqual(1, groups[1].entries.len);
    const unread_only = try libraryView(a, lib, .{ .filters = .{ .unread = .include } });
    try testing.expectEqual(1, unread_only[0].entries.len);
    var counts_sorted = [_]Entry{
        .{ .manga = &lib.manga[0], .counts = lib.manga[0].counts() },
        .{ .manga = &lib.manga[1], .counts = lib.manga[1].counts() },
    };
    sortLibrary(&counts_sorted, .{ .mode = .unread_count, .ascending = true }, .{});
    try testing.expectEqualStrings("Alpha", counts_sorted[0].manga.title);
}

test "updates feed shows chapters fetched after a title was added, newest first" {
    var a_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    const now: i64 = 1_700_000_000_000;
    var chapters = [_]Chapter{ testChapter("old", 2, 1), testChapter("new1", 1, 2), testChapter("new2", 0, 3) };
    for (&chapters, [_]i64{ 50, 200, 300 }) |*ch, fetched| {
        ch.date_fetch = now - 1000 + fetched;
        ch.date_upload = now - ms_per_day;
    }
    chapters[1].last_page_read = 3;
    const lib: Library = .{ .manga = &.{.{ .id = "m", .title = "M", .source_id = 1, .chapters = &chapters, .date_added = now - 1000 + 100 }} };
    const feed = try updates(a, lib, .{ .now = now });
    try testing.expectEqual(2, feed.len);
    try testing.expectEqualStrings("new2", feed[0].chapter.id);
    const started = try updates(a, lib, .{ .now = now, .started = .include });
    try testing.expectEqual(1, started.len);
    try testing.expectEqualStrings("new1", started[0].chapter.id);
}

test "history keeps each title's latest read chapter" {
    var a_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();
    var one = [_]Chapter{ testChapter("a1", 1, 1), testChapter("a2", 0, 2) };
    one[0].last_read = 10;
    one[1].last_read = 30;
    var two = [_]Chapter{testChapter("b1", 0, 1)};
    two[0].last_read = 20;
    const lib: Library = .{ .manga = &.{ .{ .id = "a", .title = "Alpha", .chapters = &one }, .{ .id = "b", .title = "Beta", .chapters = &two, .favorite = false } } };
    const items = try history(a, lib, "");
    try testing.expectEqual(2, items.len);
    try testing.expectEqualStrings("a2", items[0].chapter.id);
    try testing.expectEqual(1, (try history(a, lib, "BET")).len);
}

test "calendar months back clamp the day" {
    const march31 = daysFromCivil(.{ .year = 2024, .month = 3, .day = 31 }) * ms_per_day + 5;
    const back = minusMonths(march31, 1, 0);
    try testing.expectEqual(daysFromCivil(.{ .year = 2024, .month = 2, .day = 29 }) * ms_per_day + 5, back);
    try testing.expectEqual(Date{ .year = 2023, .month = 12, .day = 31 }, civilFromDays(daysFromCivil(.{ .year = 2023, .month = 12, .day = 31 })));
    const jan = daysFromCivil(.{ .year = 2024, .month = 1, .day = 15 }) * ms_per_day;
    try testing.expectEqual(daysFromCivil(.{ .year = 2023, .month = 10, .day = 15 }) * ms_per_day, minusMonths(jan, 3, 0));
}

test "stats count favorites, all downloads and all reading time" {
    var one = [_]Chapter{ testChapter("a1", 1, 1), testChapter("a2", 0, 2) };
    one[0].read = true;
    one[0].read_ms = 100;
    one[1].pages = &.{"p"};
    var two = [_]Chapter{testChapter("b1", 0, 1)};
    two[0].read_ms = 50;
    two[0].pages = &.{"p"};
    const lib: Library = .{ .manga = &.{ .{ .id = "a", .title = "A", .source_id = 1, .chapters = &one }, .{ .id = "b", .title = "B", .source_id = 1, .chapters = &two, .favorite = false } } };
    const s = stats(lib, .{}, null);
    try testing.expectEqual(1, s.titles);
    try testing.expectEqual(1, s.started);
    try testing.expectEqual(2, s.downloaded_chapters);
    try testing.expectEqual(150, s.read_ms);
    try testing.expectEqual(0, s.update_candidates);
    try testing.expect(std.math.isNan(s.mean_score));
}

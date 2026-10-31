//! Paged root reads. Temporary SQL rows retain candidates, never chapter snapshots.
const std = @import("std");
const lib = @import("library.zig");
const sqlite = @import("sqlite.zig");
const views = @import("views.zig");
const settings = @import("settings.zig");
const parse_options = @import("tachicore").models.parse_options;
const A = std.mem.Allocator;

fn parse(comptime T: type, a: A, bytes: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, bytes, parse_options);
}
fn menus(comptime T: type, db: *sqlite.Db, a: A, comptime table: []const u8) ![]const T {
    var list: std.ArrayList(T) = .empty;
    var row = try db.prepare("SELECT metadata,id FROM " ++ table ++ " ORDER BY position LIMIT 64 OFFSET ?1");
    defer row.close();
    var offset: usize = 0;
    while (true) {
        try row.bindInt(1, @intCast(offset));
        var n: usize = 0;
        while (try row.step()) {
            const value = try parse(T, a, row.columnText(0));
            if (value.id != row.columnInt(1)) return error.SqliteCorrupt;
            try list.append(a, value);
            n += 1;
        }
        if (n < 64) break;
        offset += n;
        try row.reset();
    }
    return list.toOwnedSlice(a);
}
pub fn metadata(db: *sqlite.Db, a: A) !lib.Library {
    return .{ .categories = try menus(lib.Category, db, a, "library_categories"), .sources = try menus(lib.SourceName, db, a, "library_sources") };
}
pub fn categoryTabs(db: *sqlite.Db, a: A, sort: u32) ![]const lib.Category {
    const metadata_rows = try metadata(db, a);
    const user = try a.dupe(lib.Category, metadata_rows.categories);
    std.mem.sort(lib.Category, user, {}, struct {
        fn less(_: void, x: lib.Category, y: lib.Category) bool {
            return x.order < y.order;
        }
    }.less);
    var state = try db.prepare("SELECT count(*),coalesce(sum(coalesce(json_array_length(metadata,'$.categories'),0)=0),0) FROM library_manga WHERE coalesce(json_extract(metadata,'$.favorite'),1)!=0");
    defer state.close();
    _ = try state.step();
    const show_default = state.columnInt(0) == 0 or state.columnInt(1) > 0 or user.len == 0;
    const out = try a.alloc(lib.Category, user.len + @intFromBool(show_default));
    if (show_default) out[0] = .{ .id = 0, .name = "Default", .flags = sort };
    @memcpy(out[@intFromBool(show_default)..], user);
    return out;
}
fn manga(db: *sqlite.Db, a: A, id: []const u8) !lib.Manga {
    var row = try db.prepare("SELECT metadata FROM library_manga WHERE id=?1 LIMIT 1");
    defer row.close();
    try row.bindText(1, id);
    if (!try row.step()) return error.UnknownManga;
    var m = try parse(lib.Manga, a, row.columnText(0));
    if (!std.mem.eql(u8, m.id, id)) return error.SqliteCorrupt;
    m.chapters = &.{};
    return m;
}
const chapter_columns = "c.metadata,coalesce(r.page,0),coalesce(r.read,0),coalesce(r.bookmark,0),coalesce(r.last_read,0),coalesce(r.read_ms,0),c.id";
fn chapter(row: sqlite.Stmt, a: A) !lib.Chapter {
    var ch = try parse(lib.Chapter, a, row.columnText(0));
    if (!std.mem.eql(u8, ch.id, row.columnText(6))) return error.SqliteCorrupt;
    ch.last_page_read = @intCast(row.columnInt(1));
    ch.read = row.columnInt(2) != 0;
    ch.bookmark = row.columnInt(3) != 0;
    ch.last_read = row.columnInt(4);
    ch.read_ms = row.columnInt(5);
    return ch;
}
pub fn chapterPreview(db: *sqlite.Db, a: A, id: []const u8) !lib.Manga {
    var row = try db.prepare("SELECT " ++ chapter_columns ++ ",c.manga_id FROM library_chapters c LEFT JOIN library_reading r ON r.id=c.id WHERE c.id=?1 LIMIT 1");
    defer row.close();
    try row.bindText(1, id);
    if (!try row.step()) return error.UnknownChapter;
    var m = try manga(db, a, row.columnText(7));
    const chapters = try a.alloc(lib.Chapter, 1);
    chapters[0] = try chapter(row, a);
    m.chapters = chapters;
    return m;
}
pub fn title(db: *sqlite.Db, a: A, id: []const u8) !lib.Manga {
    var m = try manga(db, a, id);
    var list: std.ArrayList(lib.Chapter) = .empty;
    var row = try db.prepare("SELECT " ++ chapter_columns ++ " FROM library_chapters c LEFT JOIN library_reading r ON r.id=c.id WHERE c.manga_id=?1 ORDER BY c.position LIMIT 64 OFFSET ?2");
    defer row.close();
    var offset: usize = 0;
    while (true) {
        try row.bindText(1, id);
        try row.bindInt(2, @intCast(offset));
        var n: usize = 0;
        while (try row.step()) {
            try list.append(a, try chapter(row, a));
            n += 1;
        }
        if (n < 64) break;
        offset += n;
        try row.reset();
    }
    m.chapters = try list.toOwnedSlice(a);
    return m;
}
const visible = " NOT EXISTS(SELECT 1 FROM json_each(m.metadata,'$.excluded_scanlators') e WHERE e.value=json_extract(c.metadata,'$.scanlator'))";
fn counts(db: *sqlite.Db, id: []const u8) !lib.Counts {
    var row = try db.prepare("SELECT count(*),coalesce(sum(coalesce(r.read,0)),0),coalesce(sum(coalesce(r.bookmark,0)),0),coalesce(sum(coalesce(json_array_length(c.metadata,'$.pages'),0)>0),0),coalesce(max(json_extract(c.metadata,'$.date_upload')),0),coalesce(max(json_extract(c.metadata,'$.date_fetch')),0),coalesce(max(r.last_read),0) FROM library_chapters c JOIN library_manga m ON m.id=c.manga_id LEFT JOIN library_reading r ON r.id=c.id WHERE m.id=?1 AND" ++ visible);
    defer row.close();
    try row.bindText(1, id);
    _ = try row.step();
    const total: usize = @intCast(row.columnInt(0));
    const read: usize = @intCast(row.columnInt(1));
    return .{ .total = total, .read = read, .unread = total - read, .bookmarked = @intCast(row.columnInt(2)), .downloaded = @intCast(row.columnInt(3)), .latest_upload = row.columnInt(4), .latest_fetch = row.columnInt(5), .last_read = row.columnInt(6) };
}
fn tri(state: views.TriState, value: bool) bool {
    return switch (state) {
        .disabled => true,
        .include => value,
        .exclude => !value,
    };
}
pub fn page(db: *sqlite.Db, a: A, o: lib.RootOptions) !lib.RootPage {
    var result = try metadata(db, a);
    // SQL owns the candidate set, so scans use a reusable arena per title.
    try db.exec("CREATE TEMP TABLE root_candidates(mid TEXT NOT NULL,cid TEXT,rank INTEGER NOT NULL,title TEXT NOT NULL,key INTEGER NOT NULL,zero INTEGER NOT NULL)");
    defer db.exec("DROP TABLE root_candidates") catch {};
    var add = try db.prepare("INSERT INTO root_candidates VALUES(?1,?2,?3,?4,?5,?6)");
    defer add.close();
    const opts = try views.libraryOptions(a, result, o.settings, "", 0);
    var sort = opts.default_sort;
    for (result.categories) |cat| if (cat.id == o.category_id) {
        sort = .decode(cat.flags);
    };
    const f = o.settings.library.filters;
    const direct = o.kind == .library and o.query.len == 0 and !o.settings.library.downloaded_only and
        f.downloaded == .disabled and f.unread == .disabled and f.started == .disabled and
        f.bookmarked == .disabled and f.completed == .disabled and f.interval_custom == .disabled and f.tracked.len == 0 and
        (sort.mode == .alphabetical or sort.mode == .date_added or sort.mode == .last_update or sort.mode == .tracker_mean);
    if (direct) {
        const key = switch (sort.mode) {
            .date_added => "coalesce(json_extract(metadata,'$.date_added'),0)",
            .last_update => "coalesce(json_extract(metadata,'$.last_update'),0)",
            else => "0",
        };
        var insert = try db.prepare(try std.fmt.allocPrintSentinel(a, "INSERT INTO root_candidates SELECT id,'',position,json_extract(metadata,'$.title'),{s},0 FROM library_manga WHERE coalesce(json_extract(metadata,'$.favorite'),1)!=0 AND ((?1=0 AND coalesce(json_array_length(metadata,'$.categories'),0)=0) OR EXISTS(SELECT 1 FROM json_each(metadata,'$.categories') WHERE value=?1))", .{key}, 0));
        defer insert.close();
        try insert.bindInt(1, o.category_id);
        _ = try insert.step();
    }
    var scan = try db.prepare("SELECT id FROM library_manga ORDER BY position LIMIT 64 OFFSET ?1");
    defer scan.close();
    var scan_offset: usize = 0;
    var rank: i64 = 0;
    while (!direct) {
        try scan.bindInt(1, @intCast(scan_offset));
        var n: usize = 0;
        while (try scan.step()) {
            n += 1;
            var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer scratch.deinit();
            const sa = scratch.allocator();
            const m = try manga(db, sa, scan.columnText(0));
            const c = try counts(db, m.id);
            if (o.kind == .library) {
                if (!m.favorite or (if (m.categories.len == 0) o.category_id != 0 else std.mem.indexOfScalar(u32, m.categories, o.category_id) == null)) continue;
                if (!views.libraryPasses(m, c, opts)) continue;
                if (try views.search(sa, result, o.query, 0)) |matcher| if (!matcher.matches(matcher.context, &m, c)) continue;
            }
            if (o.kind == .upcoming) {
                if (!m.favorite or (m.status() != 1 and m.status() != 4) or m.next_update == 0 or m.next_update < views.dayStart(o.now, 0)) continue;
                if (!settings.categoryAllowed(m.categories, o.settings.updates.upcoming_categories, o.settings.updates.upcoming_exclude_categories)) continue;
            }
            if (o.kind == .history and o.query.len > 0 and std.ascii.findIgnoreCase(m.title, o.query) == null) continue;
            if (o.kind == .updates and (!m.favorite or !settings.categoryAllowed(m.categories, o.settings.updates.categories, o.settings.updates.exclude_categories))) continue;
            if (o.kind == .history or o.kind == .updates) {
                var chapters = try db.prepare("SELECT c.id,coalesce(r.read,0),coalesce(r.bookmark,0),coalesce(r.page,0),coalesce(r.last_read,0),coalesce(json_extract(c.metadata,'$.date_fetch'),0),coalesce(json_extract(c.metadata,'$.date_upload'),0),json_extract(c.metadata,'$.scanlator'),coalesce(json_array_length(c.metadata,'$.pages'),0) FROM library_chapters c LEFT JOIN library_reading r ON r.id=c.id WHERE c.manga_id=?1 AND (?2=0 OR coalesce(r.last_read,0)!=0) ORDER BY CASE WHEN ?2=1 THEN r.last_read ELSE json_extract(c.metadata,'$.date_fetch') END DESC,c.position LIMIT ?3 OFFSET ?4");
                defer chapters.close();
                var off: usize = 0;
                while (true) {
                    try chapters.bindText(1, m.id);
                    try chapters.bindInt(2, @intFromBool(o.kind == .history));
                    try chapters.bindInt(3, if (o.kind == .history) 1 else 64);
                    try chapters.bindInt(4, @intCast(off));
                    var cn: usize = 0;
                    while (try chapters.step()) {
                        cn += 1;
                        const ch: lib.Chapter = .{
                            .id = chapters.columnText(0),
                            .title = "",
                            .read = chapters.columnInt(1) != 0,
                            .bookmark = chapters.columnInt(2) != 0,
                            .last_page_read = @intCast(chapters.columnInt(3)),
                            .last_read = chapters.columnInt(4),
                            .date_fetch = chapters.columnInt(5),
                            .date_upload = chapters.columnInt(6),
                            .scanlator = if (chapters.columnText(7).len == 0) null else chapters.columnText(7),
                            .pages = if (chapters.columnInt(8) > 0) &.{"downloaded"} else &.{},
                        };
                        const u = o.settings.updates;
                        if (o.kind == .updates) {
                            if (ch.date_fetch <= m.date_added or ch.date_upload <= views.minusMonths(o.now, 3, 0)) continue;
                            if (u.hide_excluded_scanlators and m.excludes(ch.scanlator)) continue;
                            if (!tri(u.unread, !ch.read) or !tri(u.bookmarked, ch.bookmark)) continue;
                            if (u.started == .include and (ch.read or ch.last_page_read == 0)) continue;
                            if (u.started == .exclude and (ch.read or ch.last_page_read != 0)) continue;
                        }
                        try add.bindText(1, m.id);
                        try add.bindText(2, ch.id);
                        try add.bindInt(3, rank);
                        try add.bindText(4, m.title);
                        try add.bindInt(5, if (o.kind == .history) ch.last_read else ch.date_fetch);
                        try add.bindInt(6, @intFromBool(m.local() or ch.downloaded()));
                        _ = try add.step();
                        try add.reset();
                        rank += 1;
                    }
                    if (o.kind == .history or cn < 64) break;
                    off += cn;
                    try chapters.reset();
                }
            } else {
                const key: i64 = if (o.kind == .upcoming) m.next_update else switch (sort.mode) {
                    .last_read => c.last_read,
                    .last_update => m.last_update,
                    .unread_count => @intCast(c.unread),
                    .total_chapters => @intCast(c.total),
                    .latest_chapter => c.latest_upload,
                    .chapter_fetch_date => c.latest_fetch,
                    .date_added => m.date_added,
                    else => 0,
                };
                try add.bindText(1, m.id);
                try add.bindText(2, "");
                try add.bindInt(3, rank);
                try add.bindText(4, m.title);
                try add.bindInt(5, key);
                try add.bindInt(6, @intFromBool(c.unread == 0));
                _ = try add.step();
                try add.reset();
                rank += 1;
            }
        }
        if (n < 64) break;
        scan_offset += n;
        try scan.reset();
    }
    if (o.kind == .updates) {
        try db.exec("DELETE FROM root_candidates WHERE rank NOT IN(SELECT rank FROM root_candidates ORDER BY key DESC,rank LIMIT 500)");
        const d = if (o.settings.library.downloaded_only) views.TriState.include else o.settings.updates.downloaded;
        if (d != .disabled) try db.exec(if (d == .include) "DELETE FROM root_candidates WHERE zero=0" else "DELETE FROM root_candidates WHERE zero!=0");
    }
    if (o.kind == .library and sort.mode == .random) {
        try db.exec("UPDATE root_candidates SET key=rank");
        var prng: std.Random.DefaultPrng = .init(opts.random_seed);
        var swap = try db.prepare("UPDATE root_candidates SET key=CASE key WHEN ?1 THEN ?2 ELSE ?1 END WHERE key IN(?1,?2)");
        defer swap.close();
        const size: usize = @intCast(rank);
        var i: usize = 0;
        while (size > 1 and i < size - 1) : (i += 1) {
            const j = prng.random().intRangeLessThan(usize, i, size);
            try swap.bindInt(1, @intCast(i));
            try swap.bindInt(2, @intCast(j));
            _ = try swap.step();
            try swap.reset();
        }
    }
    var count = try db.prepare("SELECT count(*) FROM root_candidates");
    defer count.close();
    _ = try count.step();
    const total: usize = @intCast(count.columnInt(0));
    const offset = if (total == 0) 0 else @min(o.offset / o.limit, (total - 1) / o.limit) * o.limit;
    const direction = if (sort.ascending) "ASC" else "DESC";
    const order = if (o.kind == .history or o.kind == .updates) "key DESC,rank" else if (o.kind == .upcoming or sort.mode == .random) "key ASC,rank" else if (sort.mode == .alphabetical) try std.fmt.allocPrint(a, "title COLLATE NOCASE {s},rank", .{direction}) else try std.fmt.allocPrint(a, "{s}key {s},title COLLATE NOCASE ASC,rank", .{ if (sort.mode == .unread_count) "zero ASC," else "", direction });
    var rows = try db.prepare(try std.fmt.allocPrintSentinel(a, "SELECT mid,cid FROM root_candidates ORDER BY {s} LIMIT ?1 OFFSET ?2", .{order}, 0));
    defer rows.close();
    try rows.bindInt(1, @intCast(o.limit));
    try rows.bindInt(2, @intCast(offset));
    var titles: std.ArrayList(lib.Manga) = .empty;
    var cs: std.ArrayList(lib.Counts) = .empty;
    var feed: std.ArrayList(lib.RootFeed) = .empty;
    while (try rows.step()) {
        var m = try manga(db, a, rows.columnText(0));
        try cs.append(a, try counts(db, m.id));
        if (o.kind == .history or o.kind == .updates) {
            var chrow = try db.prepare("SELECT " ++ chapter_columns ++ " FROM library_chapters c LEFT JOIN library_reading r ON r.id=c.id WHERE c.id=?1 LIMIT 1");
            defer chrow.close();
            try chrow.bindText(1, rows.columnText(1));
            _ = try chrow.step();
            const chs = try a.alloc(lib.Chapter, 1);
            chs[0] = try chapter(chrow, a);
            m.chapters = chs;
            try feed.append(a, .{ .manga = titles.items.len, .chapter = 0 });
        }
        try titles.append(a, m);
    }
    result.manga = try titles.toOwnedSlice(a);
    return .{ .tabs = try categoryTabs(db, a, o.settings.library.sort), .library = result, .total = total, .offset = offset, .counts = try cs.toOwnedSlice(a), .feed = try feed.toOwnedSlice(a) };
}

test "large root pages agree with views and explicit title loads all chapters" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store: lib.Store = .{ .io = t.io, .dir = try tmp.dir.realPathFileAlloc(t.io, ".", a) };
    const titles = try a.alloc(lib.Manga, 120);
    for (titles, 0..) |*m, i| {
        const chs = try a.alloc(lib.Chapter, 80);
        for (chs, 0..) |*ch, j| ch.* = .{
            .id = try std.fmt.allocPrint(a, "m{d}/c{d}", .{ i, j }),
            .title = "Chapter",
            .read = j % 2 == 0,
            .last_read = @intCast(i * 100 + j),
            .date_fetch = @intCast(i * 100 + j + 2),
            .date_upload = 1700000000000,
            .scanlator = if (j % 3 == 0) "hidden" else null,
            .pages = if (j % 5 == 0) &.{"downloads/a.png"} else &.{},
        };
        m.* = .{ .id = try std.fmt.allocPrint(a, "m{d}", .{i}), .title = try std.fmt.allocPrint(a, "Title {d:0>3}", .{i}), .favorite = i % 7 != 0, .source_id = 1, .chapters = chs, .date_added = 1, .next_update = 1700000000000 + @as(i64, @intCast(i)), .publishing_status = 1, .excluded_scanlators = &.{"hidden"} };
    }
    const original: lib.Library = .{ .manga = titles, .categories = &.{.{ .id = 1, .name = "Menu" }}, .sources = &.{.{ .id = 1, .name = "Source" }} };
    try store.save(a, original);
    try t.expectEqual(0, (try store.metadata(a)).manga.len);
    try t.expectEqual(80, (try store.loadTitle(a, "m1")).chapters.len);
    try t.expectError(error.UnknownManga, store.loadTitle(a, "missing"));
    for ([_]views.SortMode{ .alphabetical, .last_read, .unread_count, .total_chapters, .date_added, .random }) |mode| {
        var s: settings.Settings = .{};
        s.library.sort = (views.LibrarySort{ .mode = mode, .ascending = false }).encode(0);
        s.library.filters.unread = .include;
        const opts = try views.libraryOptions(a, original, s, "", 0);
        const groups = try views.libraryView(a, original, opts);
        const expected = groups[0].entries;
        const got = try store.rootPage(a, .{ .kind = .library, .offset = 8, .limit = 6, .settings = s });
        try t.expectEqual(expected.len, got.total);
        try t.expectEqual(6, got.offset);
        try t.expectEqual(6, got.library.manga.len);
        for (got.library.manga, got.counts, 6..) |m, c, i| {
            try t.expectEqualStrings(expected[i].manga.id, m.id);
            try t.expectEqualDeep(expected[i].counts, c);
            try t.expectEqual(0, m.chapters.len);
        }
    }
    var storage: [65536]u8 = undefined;
    var bounded: std.heap.FixedBufferAllocator = .init(&storage);
    var bounded_settings: settings.Settings = .{};
    bounded_settings.library.sort = (views.LibrarySort{ .mode = .total_chapters }).encode(0);
    const bounded_page = try store.rootPage(bounded.allocator(), .{ .kind = .library, .settings = bounded_settings });
    try t.expectEqual(6, bounded_page.library.manga.len);
    try t.expectEqual(0, bounded_page.library.manga[0].chapters.len);
    const history = try views.history(a, original, "Title");
    const hp = try store.rootPage(a, .{ .kind = .history, .query = "Title", .offset = 12 });
    try t.expectEqual(history.len, hp.total);
    for (hp.feed, 12..) |f, i| {
        const m = hp.library.manga[f.manga];
        try t.expectEqual(1, m.chapters.len);
        try t.expectEqualStrings(history[i].chapter.id, m.chapters[f.chapter].id);
    }
    var s: settings.Settings = .{};
    s.updates.hide_excluded_scanlators = true;
    s.updates.downloaded = .include;
    const updates = try views.updates(a, original, .{ .now = 1700000000000, .hide_excluded_scanlators = true, .downloaded = .include });
    const up = try store.rootPage(a, .{ .kind = .updates, .settings = s, .now = 1700000000000 });
    try t.expectEqual(updates.len, up.total);
    for (up.feed, 0..) |f, i| try t.expectEqualStrings(updates[i].chapter.id, up.library.manga[f.manga].chapters[f.chapter].id);
    const upcoming = try views.upcoming(a, original, &.{}, &.{}, 1700000000000, 0);
    const next = try store.rootPage(a, .{ .kind = .upcoming, .now = 1700000000000 });
    try t.expectEqual(upcoming.len, next.total);
    for (next.library.manga, 0..) |m, i| try t.expectEqualStrings(upcoming[i].id, m.id);
    const search = try store.rootPage(a, .{ .kind = .library, .query = "Title 001", .offset = 99999 });
    try t.expectEqual(1, search.total);
    try t.expectEqual(0, search.offset);
}

test "root category tabs retain Default and follow category order" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var store: lib.Store = .{ .io = t.io, .dir = try tmp.dir.realPathFileAlloc(t.io, ".", a) };
    const categories: []const lib.Category = &.{ .{ .id = 1, .name = "Later", .order = 9 }, .{ .id = 2, .name = "First", .order = 1 } };
    try store.save(a, .{ .categories = categories, .manga = &.{ .{ .id = "default", .title = "Default title" }, .{ .id = "custom", .title = "Custom", .categories = &.{2} } } });
    const tabs = try store.categoryTabs(a, 64);
    try t.expectEqual(@as(usize, 3), tabs.len);
    try t.expectEqual(@as(u32, 0), tabs[0].id);
    try t.expectEqual(@as(u32, 2), tabs[1].id);
    const page_default = try store.rootPage(a, .{ .kind = .library });
    try t.expectEqual(@as(usize, 1), page_default.total);
    try t.expectEqualStrings("default", page_default.library.manga[0].id);
    try store.save(a, .{ .categories = categories, .manga = &.{.{ .id = "custom", .title = "Custom", .categories = &.{2} }} });
    try t.expectEqual(@as(usize, 2), (try store.categoryTabs(a, 64)).len);
}

//! Extension stores as Mihon keeps them (mihonapp/mihon 487c313): any
//! number of repositories, each known by its index URL and trusted for the
//! signing key it publishes, kept in `stores.json` in the library
//! directory with the extensions trusted by hand. Listings from every store
//! are merged and filtered here; fetching an index is `repo`'s job.
const std = @import("std");
const Io = std.Io;
const repo = @import("repo.zig");
const manage = @import("manage.zig");
const library = @import("library.zig");
const models = @import("models.zig");

pub const Store = struct {
    /// The index URL after legacy redirects, as Mihon stores it.
    index_url: []const u8,
    name: []const u8 = "",
    badge_label: []const u8 = "",
    /// SHA-256 of the signing certificate, lower-case hex.
    signing_key: []const u8 = "",
    website: []const u8 = "",
    discord: ?[]const u8 = null,
    legacy: bool = false,
    extension_list_url: ?[]const u8 = null,

    pub fn fromIndex(index: repo.Store, requested_url: []const u8) Store {
        return .{
            .index_url = if (index.index_url.len > 0) index.index_url else requested_url,
            .name = index.name,
            .badge_label = if (index.badge.len > 0) index.badge else index.name,
            .signing_key = index.signing_key,
            .website = index.website,
            .discord = index.discord,
            .legacy = index.legacy,
            .extension_list_url = index.extension_list_url,
        };
    }
};

pub const File = struct {
    stores: []const Store = &.{},
    /// Extensions trusted by hand, `<pkg>:<versionCode>:<fingerprint>`.
    trusted: []const []const u8 = &.{},

    pub const name = "stores.json";

    pub fn load(arena: std.mem.Allocator, io: Io, dir: []const u8) !File {
        const path = try std.fs.path.join(arena, &.{ dir, name });
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 << 20)) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        return std.json.parseFromSliceLeaky(File, arena, bytes, models.parse_options);
    }

    pub fn save(self: File, arena: std.mem.Allocator, io: Io, dir: []const u8) !void {
        try library.writeJsonAtomic(arena, io, try std.fs.path.join(arena, &.{ dir, name }), self);
    }

    /// The file with `store` added, or replacing the one with its URL.
    pub fn upsert(self: File, arena: std.mem.Allocator, store: Store) !File {
        var list: std.ArrayList(Store) = .empty;
        var replaced = false;
        for (self.stores) |s| {
            if (std.mem.eql(u8, s.index_url, store.index_url)) {
                try list.append(arena, store);
                replaced = true;
            } else try list.append(arena, s);
        }
        if (!replaced) try list.append(arena, store);
        var next = self;
        next.stores = list.items;
        return next;
    }

    pub fn remove(self: File, arena: std.mem.Allocator, index_url: []const u8) !File {
        var list: std.ArrayList(Store) = .empty;
        for (self.stores) |s| if (!std.mem.eql(u8, s.index_url, index_url)) try list.append(arena, s);
        var next = self;
        next.stores = list.items;
        return next;
    }

    /// Whether a package signed with `fingerprint` (lower-case hex) is
    /// trusted: a store publishes that key, or this exact version was
    /// trusted by hand.
    pub fn trusts(self: File, pkg: []const u8, version_code: i64, fingerprint: []const u8) bool {
        for (self.stores) |s| if (std.ascii.eqlIgnoreCase(s.signing_key, fingerprint)) return true;
        var buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}:{d}:{s}", .{ pkg, version_code, fingerprint }) catch return false;
        for (self.trusted) |t| if (std.mem.eql(u8, t, key)) return true;
        return false;
    }

    /// The file trusting one version of a package; older versions' trust
    /// goes, as Mihon's trust is per version.
    pub fn trust(self: File, arena: std.mem.Allocator, pkg: []const u8, version_code: i64, fingerprint: []const u8) !File {
        var list: std.ArrayList([]const u8) = .empty;
        const prefix = try std.fmt.allocPrint(arena, "{s}:", .{pkg});
        for (self.trusted) |t| if (!std.mem.startsWith(u8, t, prefix)) try list.append(arena, t);
        try list.append(arena, try std.fmt.allocPrint(arena, "{s}:{d}:{s}", .{ pkg, version_code, fingerprint }));
        var next = self;
        next.trusted = list.items;
        return next;
    }
};

fn libVersion(text: []const u8) f64 {
    return std.fmt.parseFloat(f64, text) catch 0;
}

/// Mihon's merge of every store's listing: one entry per package and
/// signing key, the highest version code (then library version); the same
/// package from stores with different keys stays as alternatives.
pub fn merge(arena: std.mem.Allocator, listings: []const []const manage.RepoEntry) ![]const manage.RepoEntry {
    var out: std.ArrayList(manage.RepoEntry) = .empty;
    for (listings) |listing| for (listing) |entry| {
        for (out.items) |*kept| {
            if (!std.mem.eql(u8, kept.pkg, entry.pkg) or !std.ascii.eqlIgnoreCase(kept.signingKey, entry.signingKey)) continue;
            const newer = entry.versionCode > kept.versionCode or
                (entry.versionCode == kept.versionCode and libVersion(entry.libVersion) > libVersion(kept.libVersion));
            if (newer) kept.* = entry;
            break;
        } else try out.append(arena, entry);
    };
    std.mem.sort(manage.RepoEntry, out.items, {}, struct {
        fn less(_: void, a: manage.RepoEntry, b: manage.RepoEntry) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.less);
    return out.items;
}

/// Entries Mihon would show: in an enabled language ("all" multi-language
/// extensions when "all" is enabled) and with an enabled content warning.
pub fn filter(arena: std.mem.Allocator, entries: []const manage.RepoEntry, languages: []const []const u8, warnings: []const []const u8) ![]const manage.RepoEntry {
    var out: std.ArrayList(manage.RepoEntry) = .empty;
    for (entries) |e| {
        const lang_ok = for (languages) |l| {
            if (std.mem.eql(u8, l, e.lang)) break true;
        } else false;
        const warning_ok = for (warnings) |w| {
            if (std.ascii.eqlIgnoreCase(w, e.contentWarning)) break true;
        } else false;
        if (lang_ok and warning_ok) try out.append(arena, e);
    }
    return out.items;
}

/// Installed packages no store lists any more; only when the listing has
/// anything at all, as an unreachable store must not make them look gone.
pub fn obsolete(arena: std.mem.Allocator, listing: []const manage.RepoEntry, installed: []const []const u8) ![]const []const u8 {
    if (listing.len == 0) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (installed) |pkg| {
        const listed = for (listing) |e| {
            if (std.mem.eql(u8, e.pkg, pkg)) break true;
        } else false;
        if (!listed) try out.append(arena, pkg);
    }
    return out.items;
}

// ---- tests ---------------------------------------------------------------------

const testing = std.testing;

fn testEntry(pkg: []const u8, code: i64, key: []const u8, lang: []const u8, warning: []const u8) manage.RepoEntry {
    return .{ .pkg = pkg, .name = pkg, .versionName = "", .versionCode = code, .libVersion = "1.4", .nsfw = false, .lang = lang, .jarUrl = null, .apkUrl = "", .iconUrl = "", .supported = true, .installed = false, .installedVersionCode = null, .hasUpdate = false, .sources = &.{}, .signingKey = key, .contentWarning = warning };
}

test "listings merge by package and key, newest first, and filter like Mihon" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const merged = try merge(a, &.{
        &.{ testEntry("dex", 3, "aa", "all", "safe"), testEntry("ero", 1, "aa", "en", "nsfw") },
        &.{ testEntry("dex", 5, "AA", "all", "safe"), testEntry("dex", 2, "bb", "all", "safe") },
    });
    try testing.expectEqual(3, merged.len);
    try testing.expectEqual(5, merged[0].versionCode);
    try testing.expectEqualStrings("bb", merged[1].signingKey);
    const shown = try filter(a, merged, &.{ "all", "en" }, &.{ "safe", "mixed" });
    try testing.expectEqual(2, shown.len);
    try testing.expectEqual(0, (try filter(a, merged, &.{"fr"}, &.{"safe"})).len);
    try testing.expectEqualSlices([]const u8, &.{"gone"}, try obsolete(a, merged, &.{ "dex", "gone" }));
    try testing.expectEqual(0, (try obsolete(a, &.{}, &.{"gone"})).len);
}

test "trust follows store keys and one version of a package" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var file: File = .{ .stores = &.{.{ .index_url = "https://x/index.min.json", .signing_key = "abcd" }} };
    try testing.expect(file.trusts("p", 1, "ABCD"));
    try testing.expect(!file.trusts("p", 1, "ffff"));
    file = try file.trust(a, "p", 1, "ffff");
    try testing.expect(file.trusts("p", 1, "ffff"));
    file = try file.trust(a, "p", 2, "ffff");
    try testing.expect(!file.trusts("p", 1, "ffff"));
    try testing.expect(file.trusts("p", 2, "ffff"));
    file = try file.upsert(a, .{ .index_url = "https://y", .signing_key = "1" });
    file = try file.upsert(a, .{ .index_url = "https://y", .signing_key = "2" });
    try testing.expectEqual(2, file.stores.len);
    file = try file.remove(a, "https://x/index.min.json");
    try testing.expectEqualStrings("2", file.stores[0].signing_key);
}

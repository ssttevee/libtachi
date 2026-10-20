//! Extension management on top of the bare JVM loader: a persisted registry
//! of installed packages, and install/update from a repository index.
//!
//! The JVM only ever sees `install(path)` / `uninstall(pkg)`. Everything else
//! (index download, signature check, file placement, bookkeeping) is done
//! here with `std.Io`, so the host jar stays a pure extension interface.
//!
//! Layout under `data_dir`:
//!   extensions/installed.json      registry (see `Registry`)
//!   extensions/<pkg>-<code>.jar    packages downloaded from a repo
//!   repo/index-<hash>.pb           cached indexes (refetched after `index_ttl`)
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const tachi = @import("tachi.zig");
const repo = @import("repo.zig");
const models = @import("models.zig");
const Runtime = tachi.Runtime;
const Error = tachi.Error;

const registry_name = "extensions/installed.json";
const packages_dir = "extensions";
const index_dir = "repo";
/// A cached index is reused for this long before being refetched.
pub const index_ttl: Io.Duration = .fromSeconds(60 * 60);

// ---- registry --------------------------------------------------------------------

/// One line of `installed.json`.
pub const InstalledEntry = struct {
    pkg: []const u8,
    /// Absolute path of the package file.
    path: []const u8,
    versionCode: i64,
    versionName: []const u8,
    /// Index URL this was installed from; null for files the caller supplied.
    repo: ?[]const u8 = null,
    /// The `ExtensionInfo` the host reported at install. With it, `restore`
    /// registers the package and the host loads it when a source is first used.
    info: ?std.json.Value = null,
};

pub const Registry = struct {
    extensions: []InstalledEntry = &.{},

    fn find(r: Registry, pkg: []const u8) ?*InstalledEntry {
        for (r.extensions) |*e| if (std.mem.eql(u8, e.pkg, pkg)) return e;
        return null;
    }

    fn remove(r: *Registry, pkg: []const u8) ?InstalledEntry {
        const idx = for (r.extensions, 0..) |e, i| {
            if (std.mem.eql(u8, e.pkg, pkg)) break i;
        } else return null;
        // The parsed slice is arena-owned; only its logical length changes.
        var entries = std.ArrayList(InstalledEntry).fromOwnedSlice(r.extensions);
        const removed = entries.orderedRemove(idx);
        r.extensions = entries.items;
        return removed;
    }
};

fn loadRegistry(rt: *Runtime, arena: Allocator) Error!Registry {
    const path = try dataPath(rt, arena, registry_name);
    const bytes = Io.Dir.cwd().readFileAlloc(rt.io, path, arena, .limited(16 << 20)) catch |e| switch (e) {
        error.FileNotFound => return .{},
        error.OutOfMemory => return error.OutOfMemory,
        else => return fsError(e, path),
    };
    const parsed = std.json.parseFromSliceLeaky(Registry, arena, bytes, models.parse_options) catch |e| {
        tachi.setLastErrorFmt("{s}: {s}", .{ path, @errorName(e) });
        return error.InvalidResponse;
    };
    return parsed;
}

fn saveRegistry(rt: *Runtime, arena: Allocator, reg: Registry) Error!void {
    const path = try dataPath(rt, arena, registry_name);
    const tmp = try std.mem.concat(arena, u8, &.{ path, ".tmp" });
    const json = std.json.Stringify.valueAlloc(arena, reg, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    const cwd = Io.Dir.cwd();
    cwd.createDirPath(rt.io, std.fs.path.dirname(path).?) catch |e| return fsError(e, path);
    cwd.writeFile(rt.io, .{ .sub_path = tmp, .data = json }) catch |e| return fsError(e, tmp);
    cwd.rename(tmp, cwd, path, rt.io) catch |e| return fsError(e, path);
}

/// Records (or replaces) the registry line for a freshly installed package.
fn record(rt: *Runtime, arena: Allocator, info: models.ExtensionInfo, raw: std.json.Value, index_url: ?[]const u8) Error!void {
    var reg = try loadRegistry(rt, arena);
    const entry: InstalledEntry = .{
        .pkg = info.pkg,
        .path = info.path,
        .versionCode = info.versionCode,
        .versionName = info.versionName,
        .repo = index_url,
        .info = raw,
    };
    if (reg.find(info.pkg)) |e| {
        e.* = entry;
    } else {
        reg.extensions = try std.mem.concat(arena, InstalledEntry, &.{ reg.extensions, &.{entry} });
    }
    try saveRegistry(rt, arena, reg);
}

/// Drops the registry line for `pkg`, returning it so the file can be removed.
fn forget(rt: *Runtime, arena: Allocator, pkg: []const u8) Error!?InstalledEntry {
    var reg = try loadRegistry(rt, arena);
    const removed = reg.remove(pkg) orelse return null;
    try saveRegistry(rt, arena, reg);
    return removed;
}

// ---- install / uninstall / restore ----------------------------------------------------

/// Loads a `.jar`/`.apk` from `path` and remembers it for `restore`.
/// Returns the `ExtensionInfo` JSON (owned by caller).
pub fn installExtension(rt: *Runtime, path: []const u8) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    rt.lock.lockUncancelable(rt.io);
    defer rt.lock.unlock(rt.io);
    return installAndRecord(rt, arena, path, null);
}

/// Caller holds `rt.lock`.
fn installAndRecord(rt: *Runtime, arena: Allocator, path: []const u8, index_url: ?[]const u8) Error![]u8 {
    const abs = Io.Dir.cwd().realPathFileAlloc(rt.io, path, arena) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fsError(e, path),
    };
    const json = try rt.loadPackage(abs);
    errdefer rt.gpa.free(json);
    const info = std.json.parseFromSliceLeaky(models.ExtensionInfo, arena, json, models.parse_options) catch {
        return error.InvalidResponse;
    };
    const raw = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return error.InvalidResponse;
    try record(rt, arena, info, raw, index_url);
    return json;
}

/// Unloads `pkg`, forgets it, and deletes its file if we downloaded it.
pub fn uninstallExtension(rt: *Runtime, pkg: []const u8) Error!bool {
    var arena_state = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    rt.lock.lockUncancelable(rt.io);
    defer rt.lock.unlock(rt.io);

    const was_loaded = try rt.unloadPackage(pkg);
    const entry = try forget(rt, arena, pkg) orelse return was_loaded;
    if (try isManagedFile(rt, arena, entry.path)) {
        Io.Dir.cwd().deleteFile(rt.io, entry.path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return fsError(e, entry.path),
        };
    }
    return true;
}

/// Outcome of `restore`.
pub const RestoreResult = struct {
    loaded: usize,
    /// Packages whose file vanished or failed to load. The registry keeps
    /// them so a later `repoUpdate` can repair the install.
    failed: []const Failure,

    pub const Failure = struct { pkg: []const u8, @"error": []const u8 };
};

/// Makes every package in the registry available again. Call once after
/// `Runtime.init`. Packages with recorded info load when a source is first
/// used; older entries load now and gain that info. Returns the result as
/// JSON (owned by caller).
pub fn restore(rt: *Runtime) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    rt.lock.lockUncancelable(rt.io);
    defer rt.lock.unlock(rt.io);

    const reg = try loadRegistry(rt, arena);
    var failed: std.ArrayList(RestoreResult.Failure) = .empty;
    var loaded: usize = 0;
    var changed = false;
    for (reg.extensions) |*e| {
        const result = if (e.info) |info|
            rt.registerPackage(arena, e.path, info)
        else
            rt.loadPackage(e.path);
        if (result) |json| {
            defer rt.gpa.free(json);
            loaded += 1;
            // Entries recorded before `info` existed, or without source
            // classes, were loaded eagerly; remember what that reported.
            const known = if (e.info) |info| info == .object and info.object.contains("sourceClasses") else false;
            if (!known) {
                e.info = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch null;
                changed = changed or e.info != null;
            }
        } else |err| {
            const msg = try std.fmt.allocPrint(arena, "{s}: {s}", .{ @errorName(err), tachi.lastError() });
            tachi.log(.warn, "restore: {s} failed: {s}", .{ e.pkg, msg });
            try failed.append(arena, .{ .pkg = e.pkg, .@"error" = msg });
        }
    }
    if (changed) saveRegistry(rt, arena, reg) catch |err| tachi.log(.warn, "restore: registry not updated: {s}", .{@errorName(err)});
    return std.json.Stringify.valueAlloc(rt.gpa, RestoreResult{ .loaded = loaded, .failed = failed.items }, .{}) catch
        return error.OutOfMemory;
}

// ---- repository -----------------------------------------------------------------------

/// A repo entry joined with local state. Mirrors the JSON `repoList` returns.
pub const RepoEntry = struct {
    pkg: []const u8,
    name: []const u8,
    versionName: []const u8,
    versionCode: i64,
    libVersion: []const u8,
    nsfw: bool,
    lang: []const u8,
    jarUrl: ?[]const u8,
    apkUrl: []const u8,
    iconUrl: []const u8,
    /// extensions-lib version is one the host implements.
    supported: bool,
    installed: bool,
    installedVersionCode: ?i64,
    hasUpdate: bool,
    sources: []const RepoSource,
};

pub const RepoSource = struct {
    /// Decimal string, as in `SourceInfo`.
    id: []const u8,
    name: []const u8,
    lang: []const u8,
    baseUrl: []const u8,
};

pub const RepoOptions = struct {
    /// Index URL; defaults to keiyoushi.
    url: ?[]const u8 = null,
    /// Ignore the on-disk index cache.
    refresh: bool = false,
};

/// Every extension in the index, with `installed`/`hasUpdate` filled in from
/// the registry. Slices live in `arena`.
pub fn repoList(rt: *Runtime, arena: Allocator, opts: RepoOptions) Error![]RepoEntry {
    var http: repo.Http = .init(rt.gpa, rt.io);
    defer http.deinit();
    if (rt.ca_file) |path| try http.useCaFile(path);
    const store = try fetchStore(rt, &http, arena, opts);

    rt.lock.lockUncancelable(rt.io);
    defer rt.lock.unlock(rt.io);
    const reg = try loadRegistry(rt, arena);

    const out = try arena.alloc(RepoEntry, store.extensions.len);
    for (out, store.extensions) |*dst, e| dst.* = try toEntry(rt, arena, e, reg.find(e.pkg));
    return out;
}

/// `repoList` as a JSON array (owned by caller).
pub fn repoListJson(rt: *Runtime, opts: RepoOptions) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena_state.deinit();
    const list = try repoList(rt, arena_state.allocator(), opts);
    return std.json.Stringify.valueAlloc(rt.gpa, list, .{}) catch return error.OutOfMemory;
}

/// Downloads `pkg` from the index, checks its signer against the store's
/// key, loads it and records it. Already-current installs are just reloaded.
/// Returns the `ExtensionInfo` JSON (owned by caller).
pub fn repoInstall(rt: *Runtime, pkg: []const u8, opts: RepoOptions) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var http: repo.Http = .init(rt.gpa, rt.io);
    defer http.deinit();
    if (rt.ca_file) |path| try http.useCaFile(path);
    const store = try fetchStore(rt, &http, arena, opts);
    const ext = store.find(pkg) orelse {
        tachi.setLastErrorFmt("{s} is not in {s}", .{ pkg, opts.url orelse repo.default_index_url });
        return error.ExtensionNotInRepo;
    };

    rt.lock.lockUncancelable(rt.io);
    defer rt.lock.unlock(rt.io);
    return installFromStore(rt, arena, &http, store, ext, opts.url orelse repo.default_index_url);
}

pub const UpdateResult = struct {
    /// Packages that were upgraded, as `ExtensionInfo`.
    updated: []const models.ExtensionInfo,
    /// Packages that failed to download or load; the old version stays loaded.
    failed: []const RestoreResult.Failure,
    /// Registry packages absent from the index (removed upstream).
    missing: []const []const u8,
};

/// Upgrades every repo-installed package the index lists at a higher
/// version code. Returns an `UpdateResult` as JSON (owned by caller).
pub fn repoUpdate(rt: *Runtime, opts: RepoOptions) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var http: repo.Http = .init(rt.gpa, rt.io);
    defer http.deinit();
    if (rt.ca_file) |path| try http.useCaFile(path);
    const url = opts.url orelse repo.default_index_url;
    const store = try fetchStore(rt, &http, arena, opts);

    rt.lock.lockUncancelable(rt.io);
    defer rt.lock.unlock(rt.io);
    const reg = try loadRegistry(rt, arena);

    var updated: std.ArrayList(models.ExtensionInfo) = .empty;
    var failed: std.ArrayList(RestoreResult.Failure) = .empty;
    var missing: std.ArrayList([]const u8) = .empty;
    for (reg.extensions) |e| {
        const from_repo = e.repo orelse continue;
        if (!std.mem.eql(u8, from_repo, url)) continue;
        const ext = store.find(e.pkg) orelse {
            try missing.append(arena, e.pkg);
            continue;
        };
        if (ext.version_code <= e.versionCode) continue;
        if (installFromStore(rt, arena, &http, store, ext, url)) |json| {
            defer rt.gpa.free(json);
            const info = std.json.parseFromSliceLeaky(models.ExtensionInfo, arena, json, models.parse_options) catch
                return error.InvalidResponse;
            try updated.append(arena, info);
        } else |err| {
            const msg = try std.fmt.allocPrint(arena, "{s}: {s}", .{ @errorName(err), tachi.lastError() });
            tachi.log(.warn, "update: {s} failed: {s}", .{ e.pkg, msg });
            try failed.append(arena, .{ .pkg = e.pkg, .@"error" = msg });
        }
    }
    const result: UpdateResult = .{ .updated = updated.items, .failed = failed.items, .missing = missing.items };
    return std.json.Stringify.valueAlloc(rt.gpa, result, .{}) catch return error.OutOfMemory;
}

// ---- helpers (methods on Runtime) ---------------------------------------------------------

fn dataPath(rt: *Runtime, arena: Allocator, sub: []const u8) Error![]u8 {
    return std.fs.path.join(arena, &.{ rt.data_dir, sub });
}

/// True when `path` lies in the directory we download packages into.
fn isManagedFile(rt: *Runtime, arena: Allocator, path: []const u8) Error!bool {
    const dir = try dataPath(rt, arena, packages_dir);
    return std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == std.fs.path.sep;
}

/// Index for `opts.url`, from the disk cache when fresh enough.
fn fetchStore(rt: *Runtime, http: *repo.Http, arena: Allocator, opts: RepoOptions) Error!repo.Store {
    const url = opts.url orelse repo.default_index_url;
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &digest, .{});
    const name = try std.fmt.allocPrint(arena, "{s}/index-{s}.pb", .{ index_dir, std.fmt.bytesToHex(digest[0..8], .lower) });
    const cache_path = try dataPath(rt, arena, name);
    const cwd = Io.Dir.cwd();

    if (!opts.refresh) if (readCachedIndex(rt, arena, cache_path)) |store| return store;

    const store = try repo.fetchIndex(http, arena, url);
    // Best-effort cache; a failure here must not fail the listing.
    if (cwd.createDirPath(rt.io, std.fs.path.dirname(cache_path).?)) {
        http.getToFile(cwd, cache_path, url) catch {};
    } else |_| {}
    return store;
}

/// The cached index at `path` if it is younger than `index_ttl` and decodes.
fn readCachedIndex(rt: *Runtime, arena: Allocator, path: []const u8) ?repo.Store {
    const cwd = Io.Dir.cwd();
    const st = cwd.statFile(rt.io, path, .{}) catch return null;
    const age = st.mtime.durationTo(Io.Timestamp.now(rt.io, .real));
    if (age.nanoseconds < 0 or age.nanoseconds >= index_ttl.nanoseconds) return null;
    const bytes = cwd.readFileAlloc(rt.io, path, arena, .limited(64 << 20)) catch return null;
    const store = repo.parseIndex(arena, bytes) catch return null; // corrupt cache: refetch
    return if (store.extensions.len > 0) store else null;
}

fn toEntry(rt: *Runtime, arena: Allocator, e: repo.Extension, installed: ?*InstalledEntry) Error!RepoEntry {
    const sources = try arena.alloc(RepoSource, e.sources.len);
    for (sources, e.sources) |*dst, s| dst.* = .{
        .id = try std.fmt.allocPrint(arena, "{d}", .{s.id}),
        .name = s.name,
        .lang = s.lang,
        .baseUrl = s.base_url,
    };
    return .{
        .pkg = e.pkg,
        .name = e.name,
        .versionName = e.version_name,
        .versionCode = e.version_code,
        .libVersion = e.lib_version,
        .nsfw = e.nsfw(),
        .lang = e.lang(),
        .jarUrl = e.jar_url,
        .apkUrl = e.apk_url,
        .iconUrl = e.icon_url,
        .supported = supportsLib(rt, e.lib_version),
        .installed = installed != null,
        .installedVersionCode = if (installed) |i| i.versionCode else null,
        .hasUpdate = if (installed) |i| e.version_code > i.versionCode else false,
        .sources = sources,
    };
}

fn supportsLib(rt: *Runtime, lib: []const u8) bool {
    for (rt.supported_lib_versions) |v| if (std.mem.eql(u8, v, lib)) return true;
    return false;
}

/// Download → verify → load → record. Caller holds `rt.lock`.
fn installFromStore(
    rt: *Runtime,
    arena: Allocator,
    http: *repo.Http,
    store: repo.Store,
    ext: repo.Extension,
    index_url: []const u8,
) Error![]u8 {
    if (!supportsLib(rt, ext.lib_version)) {
        tachi.setLastErrorFmt("{s} targets extensions-lib {s}; this host supports {s}", .{
            ext.pkg, ext.lib_version, std.mem.join(arena, ", ", rt.supported_lib_versions) catch "?",
        });
        return error.UnsupportedExtension;
    }
    const url = ext.downloadUrl() orelse {
        tachi.setLastErrorFmt("{s} has no download URL in the index", .{ext.pkg});
        return error.ExtensionNotInRepo;
    };
    const suffix = std.fs.path.extension(url);
    const file_name = try std.fmt.allocPrint(arena, "{s}/{s}-{d}{s}", .{ packages_dir, ext.pkg, ext.version_code, suffix });
    const path = try dataPath(rt, arena, file_name);
    const cwd = Io.Dir.cwd();

    // Reuse a file we already fetched for this exact version.
    const present = if (cwd.access(rt.io, path, .{})) true else |_| false;
    if (!present) {
        tachi.log(.info, "downloading {s}", .{url});
        cwd.createDirPath(rt.io, std.fs.path.dirname(path).?) catch |e| return fsError(e, path);
        const part = try std.mem.concat(arena, u8, &.{ path, ".part" });
        try http.getToFile(cwd, part, url);
        errdefer cwd.deleteFile(rt.io, part) catch {};
        try verifySigner(rt, part, store, ext);
        cwd.rename(part, cwd, path, rt.io) catch |e| return fsError(e, path);
    }

    const json = try installAndRecord(rt, arena, path, index_url);
    errdefer rt.gpa.free(json);

    try pruneOldVersions(rt, arena, ext.pkg, path);
    return json;
}

/// Rejects a download whose signer is not the store's `signing_key`.
/// Files without any signature block (APKs signed only with the v2/v3
/// scheme) are rejected too, unless the store publishes no key.
fn verifySigner(rt: *Runtime, path: []const u8, store: repo.Store, ext: repo.Extension) Error!void {
    if (store.signing_key.len == 0) return;
    const fps = repo.signerFingerprints(rt.gpa, rt.io, path) catch |e| {
        tachi.setLastErrorFmt("{s}: cannot read signature: {s}", .{ ext.pkg, @errorName(e) });
        return error.SignatureMismatch;
    };
    defer rt.gpa.free(fps);
    if (fps.len == 0) {
        tachi.setLastErrorFmt("{s}: package has no JAR signature block to check against the repo key", .{ext.pkg});
        return error.SignatureMismatch;
    }
    if (!repo.signedBy(fps, store.signing_key)) {
        tachi.setLastErrorFmt("{s}: signed by {s}, repo key is {s}", .{ ext.pkg, &repo.hex(fps[0]), store.signing_key });
        return error.SignatureMismatch;
    }
}

/// Deletes other `<pkg>-*.jar|apk` files in the packages directory.
fn pruneOldVersions(rt: *Runtime, arena: Allocator, pkg: []const u8, keep: []const u8) Error!void {
    const dir_path = try dataPath(rt, arena, packages_dir);
    var dir = Io.Dir.cwd().openDir(rt.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(rt.io);
    const prefix = try std.mem.concat(arena, u8, &.{ pkg, "-" });
    var it = dir.iterate();
    while (it.next(rt.io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, prefix)) continue;
        if (std.mem.eql(u8, entry.name, std.fs.path.basename(keep))) continue;
        const ext = std.fs.path.extension(entry.name);
        if (!std.mem.eql(u8, ext, ".jar") and !std.mem.eql(u8, ext, ".apk")) continue;
        dir.deleteFile(rt.io, entry.name) catch {};
    }
}

fn fsError(e: anyerror, path: []const u8) Error {
    tachi.setLastErrorFmt("{s}: {s}", .{ path, @errorName(e) });
    return error.FileSystemError;
}

// ---- tests ------------------------------------------------------------------------------

test "registry round-trips through JSON" {
    const gpa = std.testing.allocator;
    const reg: Registry = .{ .extensions = @constCast(&[_]InstalledEntry{
        .{ .pkg = "a.b", .path = "/x/a.jar", .versionCode = 3, .versionName = "1.6.3", .repo = "https://r" },
        .{ .pkg = "c.d", .path = "/x/c.jar", .versionCode = 1, .versionName = "1.6.1" },
    }) };
    const json = try std.json.Stringify.valueAlloc(gpa, reg, .{});
    defer gpa.free(json);
    const back = try std.json.parseFromSlice(Registry, gpa, json, models.parse_options);
    defer back.deinit();
    try std.testing.expectEqual(2, back.value.extensions.len);
    try std.testing.expectEqualStrings("https://r", back.value.find("a.b").?.repo.?);
    try std.testing.expectEqual(null, back.value.find("c.d").?.repo);
    try std.testing.expectEqual(null, back.value.find("zz"));
}

test "registry removal preserves order at every position" {
    const original = [_]InstalledEntry{
        .{ .pkg = "a", .path = "/a.jar", .versionCode = 1, .versionName = "1" },
        .{ .pkg = "b", .path = "/b.jar", .versionCode = 2, .versionName = "2" },
        .{ .pkg = "c", .path = "/c.jar", .versionCode = 3, .versionName = "3" },
    };
    for (original, 0..) |entry, removed_index| {
        var entries = original;
        var reg: Registry = .{ .extensions = &entries };
        try std.testing.expectEqualStrings(entry.pkg, reg.remove(entry.pkg).?.pkg);
        try std.testing.expectEqual(2, reg.extensions.len);
        var i: usize = 0;
        for (original, 0..) |expected, index| {
            if (index == removed_index) continue;
            try std.testing.expectEqualStrings(expected.pkg, reg.extensions[i].pkg);
            i += 1;
        }
        try std.testing.expectEqual(null, reg.remove("missing"));
        try std.testing.expectEqual(2, reg.extensions.len);
    }
    var empty: Registry = .{};
    try std.testing.expectEqual(null, empty.remove("a"));
    var single = [_]InstalledEntry{original[0]};
    var reg: Registry = .{ .extensions = &single };
    _ = reg.remove("a");
    try std.testing.expectEqual(0, reg.extensions.len);
    try std.testing.expectEqual(null, reg.remove("a"));
}

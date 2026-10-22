//! libtachi's persistent package-management adapter over the extension core.
const std = @import("std");
const tachi = @import("tachi.zig");
const core = @import("tachicore");
const manage = @import("manage.zig");
const models = core.models;
const Error = tachi.Error;
const Options = core.Options;
const Result = core.Result;
const Image = core.Image;

pub const Runtime = struct {
    /// Independent raw extension runtime; owns the host sandbox and JVM.
    core: *core.Runtime,
    // Borrowed views retained for the managed API and its storage adapters.
    gpa: std.mem.Allocator,
    io: std.Io,
    data_dir: [:0]u8,
    cache_dir: [:0]u8,
    supported_lib_versions: []const []const u8,
    ca_file: ?[]u8,
    /// Serializes this integrator's registry transactions, outside the core.
    lock: std.Io.Mutex = .init,

    pub const installExtension = manage.installExtension;
    pub const uninstallExtension = manage.uninstallExtension;
    pub const restore = manage.restore;
    pub const repoList = manage.repoList;
    pub const repoListJson = manage.repoListJson;
    pub const repoInstall = manage.repoInstall;
    pub const repoUpdate = manage.repoUpdate;
    pub const RepoOptions = manage.RepoOptions;
    pub const RepoEntry = manage.RepoEntry;
    pub const Browse = core.Runtime.Browse;
    pub const UpdateParts = core.Runtime.UpdateParts;

    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) Error!*Runtime {
        const self = try gpa.create(Runtime);
        errdefer gpa.destroy(self);
        const raw = try core.Runtime.init(gpa, io, opts);
        self.* = .{ .core = raw, .gpa = gpa, .io = io, .data_dir = raw.data_dir, .cache_dir = raw.cache_dir, .supported_lib_versions = raw.supported_lib_versions, .ca_file = raw.ca_file };
        return self;
    }

    pub fn deinit(self: *Runtime) void {
        const gpa = self.gpa;
        self.core.deinit();
        gpa.destroy(self);
    }

    pub fn installExtensionParsed(self: *Runtime, path: []const u8) Error!Result(models.ExtensionInfo) {
        const json = try self.installExtension(path);
        defer self.gpa.free(json);
        return Result(models.ExtensionInfo).fromJson(self.gpa, json);
    }

    pub fn detachThread(self: *Runtime) void {
        return self.core.detachThread();
    }

    pub fn saveStartupCache(self: *Runtime) !void {
        return self.core.saveStartupCache();
    }

    pub fn startupCachePending(self: *const Runtime) bool {
        return self.core.startupCachePending();
    }

    pub fn loadPackage(self: *Runtime, path: []const u8) Error![]u8 {
        return self.core.loadPackage(path);
    }

    pub fn registerPackage(self: *Runtime, arena: std.mem.Allocator, path: []const u8, info: std.json.Value) Error![]u8 {
        return self.core.registerPackage(arena, path, info);
    }

    pub fn unloadPackage(self: *Runtime, pkg: []const u8) Error!bool {
        return self.core.unloadPackage(pkg);
    }

    pub fn listExtensions(self: *Runtime) Error![]u8 {
        return self.core.listExtensions();
    }

    pub fn reloadPreferences(self: *Runtime) Error!void {
        return self.core.reloadPreferences();
    }

    pub fn listExtensionsParsed(self: *Runtime) Error!Result([]const models.ExtensionInfo) {
        return self.core.listExtensionsParsed();
    }

    pub fn extensionToLoad(self: *Runtime, gpa: std.mem.Allocator, source_id: i64) Error!?[]u8 {
        return self.core.extensionToLoad(gpa, source_id);
    }

    pub fn loadSource(self: *Runtime, source_id: i64) Error!void {
        return self.core.loadSource(source_id);
    }

    pub fn call(self: *Runtime, source_id: i64, method: []const u8, args_json: []const u8) Error![]u8 {
        return self.core.call(source_id, method, args_json);
    }

    pub fn callParsed(self: *Runtime, comptime T: type, source_id: i64, method: []const u8, args_json: []const u8) Error!Result(T) {
        return self.core.callParsed(T, source_id, method, args_json);
    }

    pub fn browse(self: *Runtime, source_id: i64, page: i32, kind: Browse) Error!Result(models.MangasPage) {
        return self.core.browse(source_id, page, kind);
    }

    pub fn mangaUpdate(self: *Runtime, source_id: i64, manga: models.Manga, chapters: []const models.Chapter, parts: UpdateParts) Error!Result(models.MangaUpdate) {
        return self.core.mangaUpdate(source_id, manga, chapters, parts);
    }

    pub fn pageList(self: *Runtime, source_id: i64, chapter: models.Chapter) Error!Result([]const models.Page) {
        return self.core.pageList(source_id, chapter);
    }

    pub fn imageRequests(self: *Runtime, source_id: i64, chapter: models.Chapter) Error!Result([]const models.ImageRequest) {
        return self.core.imageRequests(source_id, chapter);
    }

    pub fn restoreImageCookies(self: *Runtime, source_id: i64, url: []const u8, cookies: []const []const u8) Error!void {
        return self.core.restoreImageCookies(source_id, url, cookies);
    }

    pub fn cancelRequests(self: *Runtime, source_id: i64) Error!void {
        return self.core.cancelRequests(source_id);
    }

    pub fn filters(self: *Runtime, source_id: i64) Error!Result([]const models.Filter) {
        return self.core.filters(source_id);
    }

    pub fn preferences(self: *Runtime, source_id: i64) Error!Result([]const models.Preference) {
        return self.core.preferences(source_id);
    }

    pub fn setPreference(self: *Runtime, source_id: i64, key: []const u8, value: std.json.Value) Error!Result([]const models.Preference) {
        return self.core.setPreference(source_id, key, value);
    }

    pub fn related(self: *Runtime, source_id: i64, manga: models.Manga) Error!Result([]const models.Manga) {
        return self.core.related(source_id, manga);
    }

    pub fn fetchImage(self: *Runtime, source_id: i64, page_json: []const u8) Error!Image {
        return self.core.fetchImage(source_id, page_json);
    }

    pub fn supportsCancellation(self: *const Runtime) bool {
        return self.core.supportsCancellation();
    }
};

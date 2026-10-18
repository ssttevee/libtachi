//! Typed views of the JSON the host returns. Field names match the Kotlin
//! DTOs in host/src/main/kotlin/dev/tachi/host/Dto.kt one-to-one so that
//! `std.json.parseFromSlice` can decode them directly.
const std = @import("std");

pub const Manga = struct {
    url: []const u8,
    title: []const u8,
    thumbnailUrl: ?[]const u8 = null,
    artist: ?[]const u8 = null,
    author: ?[]const u8 = null,
    status: i32 = 0,
    description: ?[]const u8 = null,
    genre: ?[]const u8 = null,
    updateStrategy: []const u8 = "ALWAYS_UPDATE",
    initialized: bool = false,
    memo: ?std.json.Value = null,

    pub const Status = enum(i32) {
        unknown = 0,
        ongoing = 1,
        completed = 2,
        licensed = 3,
        publishing_finished = 4,
        cancelled = 5,
        on_hiatus = 6,
        _,
    };

    pub fn statusEnum(self: Manga) Status {
        return @fromBackingInt(@intCast(self.status));
    }
};

pub const Chapter = struct {
    url: []const u8,
    name: []const u8,
    chapterNumber: f32 = -1,
    scanlator: ?[]const u8 = null,
    dateUpload: i64 = 0,
    memo: ?std.json.Value = null,
};

pub const Page = struct {
    index: i32,
    url: []const u8 = "",
    imageUrl: ?[]const u8 = null,
};

pub const MangasPage = struct {
    mangas: []const Manga,
    hasNextPage: bool,
};

pub const MangaUpdate = struct {
    manga: Manga,
    chapters: []const Chapter,
};

pub const SourceInfo = struct {
    /// Decimal string; use `idInt` to get the numeric source id.
    id: []const u8,
    name: []const u8,
    lang: []const u8,
    baseUrl: ?[]const u8 = null,
    supportsLatest: bool,
    isConfigurable: bool,
    supportsRelatedMangas: bool = false,
    className: []const u8,
    extensionPkg: []const u8,

    pub fn idInt(self: SourceInfo) !i64 {
        return std.fmt.parseInt(i64, self.id, 10);
    }
};

pub const ExtensionInfo = struct {
    pkg: []const u8,
    name: []const u8,
    versionName: []const u8,
    versionCode: i32,
    libVersion: []const u8,
    nsfw: bool,
    lang: []const u8,
    path: []const u8,
    sources: []const SourceInfo,
};

pub const Filter = struct {
    type: []const u8,
    name: []const u8,
    state: ?std.json.Value = null,
    values: ?[]const []const u8 = null,
    filters: ?[]const Filter = null,
};

pub const Preference = struct {
    type: []const u8,
    key: ?[]const u8 = null,
    title: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    defaultValue: ?std.json.Value = null,
    value: ?std.json.Value = null,
    entries: ?[]const []const u8 = null,
    entryValues: ?[]const []const u8 = null,
    dialogTitle: ?[]const u8 = null,
    dialogMessage: ?[]const u8 = null,
    enabled: bool = true,
    visible: bool = true,
};

pub const ErrorInfo = struct {
    type: []const u8,
    message: ?[]const u8 = null,
    stack: ?[]const u8 = null,
};

/// Envelope every bridge call returns: exactly one of `ok` / `error` is set.
pub fn Envelope(comptime T: type) type {
    return struct {
        ok: ?T = null,
        @"error": ?ErrorInfo = null,
    };
}

pub const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
};

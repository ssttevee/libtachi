//! zig-tachi: run Mihon/Tachiyomi extensions in-process.
//!
//! ```zig
//! var rt = try tachi.Runtime.init(gpa, io, .{ .data_dir = "/tmp/tachi", .environ = environ });
//! defer rt.deinit();
//! const ext = try rt.installExtensionParsed("tachiyomi-en.weebcentral-v1.6.25.jar");
//! defer ext.deinit();
//! const id = try ext.value().sources[0].idInt();
//! const page = try rt.callParsed(tachi.models.MangasPage, id, "popular", "{\"page\":1}");
//! defer page.deinit();
//! ```
const std = @import("std");
const Io = std.Io;
const Environ = std.process.Environ;
pub const core = @import("tachicore");
pub const jvm = core.jvm;
pub const jni = jvm.jni;
pub const models = core.models;
pub const repo = @import("repo.zig");
pub const manage = @import("manage.zig");
pub const library = @import("library.zig");
pub const recognition = @import("recognition.zig");
pub const fetch_interval = @import("fetch_interval.zig");
pub const query = @import("query.zig");
pub const backup = @import("backup.zig");
pub const settings = @import("settings.zig");
pub const queue = @import("queue.zig");
pub const views = @import("views.zig");
pub const mihon_downloads = @import("mihon_downloads.zig");
pub const preferences = @import("preferences.zig");
pub const stores = @import("stores.zig");
pub const track = @import("track/driver.zig");
pub const downloads = @import("downloads.zig");
pub const backend = @import("backend.zig");
pub const worker = @import("worker.zig");
pub const local = @import("local.zig");
pub const tracking = @import("tracking.zig");
pub const engine = @import("engine.zig");
pub const Engine = engine.Engine;
pub const Job = engine.Job;
pub const Error = core.Error || repo.Error || error{ ExtensionNotInRepo, SignatureMismatch, UnsupportedExtension };
pub const LogLevel = core.LogLevel;
pub const LogFn = core.LogFn;
pub const Options = core.Options;
pub const Image = core.Image;
pub const Result = core.Result;
pub const lastError = core.lastError;
pub const setLastError = core.setLastError;
pub const setLastErrorFmt = core.setLastErrorFmt;
pub const log = core.log;
pub const Runtime = @import("managed_runtime.zig").Runtime;

test {
    _ = @import("parallel.zig");
    _ = core;
    _ = repo;
    _ = manage;
    _ = library;
    _ = recognition;
    _ = fetch_interval;
    _ = query;
    _ = backup;
    _ = settings;
    _ = queue;
    _ = views;
    _ = mihon_downloads;
    _ = preferences;
    _ = stores;
    std.testing.refAllDecls(track);
    _ = downloads;
    std.testing.refAllDecls(backend.InProcess);
    std.testing.refAllDecls(worker);
    std.testing.refAllDecls(worker.Client);
    _ = local;
    _ = tracking;
    _ = engine;
    std.testing.refAllDecls(Engine);
    std.testing.refAllDecls(Runtime);
}

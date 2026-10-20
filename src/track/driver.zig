//! The built-in tracking services behind `tracking.Driver`: one file per
//! service, each with `default_base_url` and `call`, Mihon's wire formats
//! and rules (mihonapp/mihon 487c313, app/.../data/track/<service>).
const std = @import("std");
/// Enhanced source acceptance, identity and migration helpers.
pub const enhanced = @import("enhanced.zig");
const Io = std.Io;
const tracking = @import("../tracking.zig");
const Http = @import("http.zig").Http;
const myanimelist = @import("myanimelist.zig");
const anilist = @import("anilist.zig");
const kitsu = @import("kitsu.zig");
const shikimori = @import("shikimori.zig");
const bangumi = @import("bangumi.zig");
const komga = @import("komga.zig");
const mangaupdates = @import("mangaupdates.zig");
const kavita = @import("kavita.zig");
const suwayomi = @import("suwayomi.zig");
const hikka = @import("hikka.zig");
const mangabaka = @import("mangabaka.zig");
const comick = @import("comick.zig");

/// What a service's `call` gets: HTTP, its base URL (overridable for
/// tests), the user's credential and score formats, and the runtime's data
/// directory, whose `prefs/source_<id>.json` hold extensions' settings
/// (enhanced trackers read their server's there).
pub const Context = struct {
    arena: std.mem.Allocator,
    io: Io,
    http: *Http,
    base_url: []const u8,
    tracker_id: i32,
    credential: tracking.Credential,
    formats: tracking.Formats,
    host_dir: ?[]const u8,
};

pub const Drivers = struct {
    http: Http,
    /// Every service's base URL, for tests against a local server.
    base_url: ?[]const u8 = null,
    host_dir: ?[]const u8 = null,
    lock: Io.Mutex = .init,

    pub fn init(gpa: std.mem.Allocator, io: Io, ca_file: ?[]const u8, host_dir: ?[]const u8) Drivers {
        return .{ .http = .{ .gpa = gpa, .io = io, .ca_file = ca_file }, .host_dir = host_dir };
    }

    pub fn deinit(self: *Drivers) void {
        self.http.deinit();
    }

    pub fn driver(self: *Drivers) tracking.Driver {
        return .{ .context = self, .call = call };
    }

    fn call(context: ?*anyopaque, arena: std.mem.Allocator, io: Io, id: i32, credential: tracking.Credential, formats: tracking.Formats, op: tracking.Operation) anyerror!tracking.Reply {
        const self: *Drivers = @ptrCast(@alignCast(context.?));
        // One HTTP client for every call.
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        var ctx: Context = .{ .arena = arena, .io = io, .http = &self.http, .base_url = self.base_url orelse defaultBaseUrl(id), .tracker_id = id, .credential = credential, .formats = formats, .host_dir = self.host_dir };
        return switch (id) {
            1 => myanimelist.call(&ctx, op),
            2 => anilist.call(&ctx, op),
            3 => kitsu.call(&ctx, op),
            4 => shikimori.call(&ctx, op),
            5 => bangumi.call(&ctx, op),
            6 => komga.call(&ctx, op),
            7 => mangaupdates.call(&ctx, op),
            8 => kavita.call(&ctx, op),
            9 => suwayomi.call(&ctx, op),
            10 => hikka.call(&ctx, op),
            11 => mangabaka.call(&ctx, op),
            12 => comick.call(&ctx, op),
            else => error.UnknownTracker,
        };
    }
};

fn defaultBaseUrl(id: i32) []const u8 {
    return switch (id) {
        1 => myanimelist.default_base_url,
        2 => anilist.default_base_url,
        3 => kitsu.default_base_url,
        4 => shikimori.default_base_url,
        5 => bangumi.default_base_url,
        6 => komga.default_base_url,
        7 => mangaupdates.default_base_url,
        8 => kavita.default_base_url,
        9 => suwayomi.default_base_url,
        10 => hikka.default_base_url,
        11 => mangabaka.default_base_url,
        12 => comick.default_base_url,
        else => "",
    };
}

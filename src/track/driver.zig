//! The built-in tracking services behind `tracking.Driver`: one file per
//! service, each with `default_base_url` and `call`, Mihon's wire formats
//! and rules (mihonapp/mihon 487c313, app/.../data/track/<service>).
const std = @import("std");
/// Enhanced source acceptance, identity and migration helpers.
pub const enhanced = @import("enhanced.zig");
const Io = std.Io;
const tracking = @import("../tracking.zig");
const Http = @import("http.zig").Http;
// Numeric values are Mihon's durable tracker IDs; tags name adapter declarations.
const Service = enum(i32) {
    myanimelist = 1,
    anilist = 2,
    kitsu = 3,
    shikimori = 4,
    bangumi = 5,
    komga = 6,
    mangaupdates = 7,
    kavita = 8,
    suwayomi = 9,
    hikka = 10,
    mangabaka = 11,
    comick = 12,
};

const adapters = struct {
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
};

comptime {
    if (std.enums.values(Service).len != tracking.trackers.len)
        @compileError("every tracker needs one service adapter");
    for (tracking.trackers) |tracker| {
        if (std.enums.fromInt(Service, tracker.id) == null)
            @compileError("tracker has no service adapter");
    }
}

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
        const service = std.enums.fromInt(Service, id) orelse return error.UnknownTracker;
        return switch (service) {
            inline else => |tag| blk: {
                const adapter = @field(adapters, @tagName(tag));
                var ctx: Context = .{ .arena = arena, .io = io, .http = &self.http, .base_url = self.base_url orelse adapter.default_base_url, .tracker_id = id, .credential = credential, .formats = formats, .host_dir = self.host_dir };
                break :blk adapter.call(&ctx, op);
            },
        };
    }
};

test "driver rejects unknown tracker IDs before making requests" {
    const t = std.testing;
    var drivers: Drivers = .init(t.allocator, t.io, null, null);
    defer drivers.deinit();
    const driver = drivers.driver();
    for ([_]i32{ -1, 0, 13, std.math.maxInt(i32) }) |id| {
        try t.expectError(error.UnknownTracker, driver.call(driver.context, t.allocator, t.io, id, .{ .tracker_id = id }, .{}, .{ .search = "title" }));
    }
    try t.expect(drivers.http.client == null);
}

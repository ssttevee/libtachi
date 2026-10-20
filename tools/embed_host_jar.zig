//! Build-time helper: `embed_host_jar <tachi-host.jar> <host_jar.zig>`.
//! Writes the module the library imports as "host_jar" when the jar is
//! embedded. The hash names the extracted copy and its CDS archive, so a
//! rebuilt jar never collides with a stale cache entry.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) std.process.fatal("usage: {s} <jar> <out.zig>", .{args[0]});
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const jar = try cwd.openFile(io, args[1], .{});
    defer jar.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var reader = jar.reader(io, &buf);
    var hasher: std.hash.Wyhash = .init(0);
    while (true) {
        const chunk = reader.interface.peekGreedy(1) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return reader.err orelse e,
        };
        hasher.update(chunk);
        reader.interface.toss(chunk.len);
    }

    var out: [128]u8 = undefined;
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = try std.fmt.bufPrint(&out,
        \\pub const bytes: ?[]const u8 = @embedFile("tachi-host.jar");
        \\pub const hash = "{x:0>16}";
        \\
    , .{hasher.final()}) });
}

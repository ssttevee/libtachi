//! Run the extension core on its own, with no libtachi module or database.
const std = @import("std");
const core = @import("tachicore");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.ExpectedHostJar;
    var random: [8]u8 = undefined;
    io.random(&random);
    const dir = try std.fmt.allocPrint(gpa, "zig-out/test-core-jvm-{x}", .{std.mem.readInt(u64, &random, .little)});
    defer gpa.free(dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const rt = try core.Runtime.init(gpa, io, .{ .data_dir = dir, .host_jar = args[1], .environ = init.minimal.environ, .class_data_sharing = false });
    defer rt.deinit();
    try std.testing.expect(rt.supportsCancellation());
    const installed = try rt.listExtensionsParsed();
    defer installed.deinit();
    try std.testing.expectEqual(0, installed.value().len);
    const missing = try std.fs.path.join(gpa, &.{ rt.data_dir, "integrator-owned.jar" });
    defer gpa.free(missing);
    try std.testing.expectError(error.ExtensionError, rt.loadPackage(missing));
    for ([_][]const u8{ "extensions/installed.json", "tachi.sqlite3", "library.json", "reading.json", "downloads" }) |name| {
        const path = try std.fs.path.join(gpa, &.{ rt.data_dir, name });
        defer gpa.free(path);
        try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, path, .{}));
    }
    std.debug.print("PASS: standalone extension core starts, calls the host and leaves integrator stores absent\n", .{});
}

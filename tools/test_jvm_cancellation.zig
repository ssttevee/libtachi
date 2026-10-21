//! Opt-in real-JVM test; `zig build test-jvm` supplies the host and fixture jars.
const std = @import("std");
const tachi = @import("tachi");
const jni = tachi.jni;

const Fixture = struct {
    rt: *tachi.Runtime,
    cls: jni.jclass,

    fn init(rt: *tachi.Runtime) !Fixture {
        const env = try rt.vm.env();
        const local = env.f.FindClass(env, "dev/tachi/host/CancellationFixture") orelse return error.FixtureNotFound;
        defer env.f.DeleteLocalRef(env, local);
        return .{ .rt = rt, .cls = env.f.NewGlobalRef(env, local) orelse return error.OutOfMemory };
    }
    fn deinit(self: Fixture) void {
        const env = self.rt.vm.env() catch return;
        env.f.DeleteGlobalRef(env, self.cls);
    }
    fn command(self: Fixture, name: [*:0]const u8) !void {
        const env = try self.rt.vm.env();
        const method = env.f.GetStaticMethodID(env, self.cls, name, "()V") orelse return error.FixtureMethodMissing;
        env.f.CallStaticVoidMethodA(env, self.cls, method, &.{});
        if (env.f.ExceptionCheck(env) != 0) {
            env.f.ExceptionDescribe(env);
            env.f.ExceptionClear(env);
            return error.FixtureFailed;
        }
    }
    fn flag(self: Fixture, name: [*:0]const u8, id: i64) !bool {
        const env = try self.rt.vm.env();
        const method = env.f.GetStaticMethodID(env, self.cls, name, "(J)Z") orelse return error.FixtureMethodMissing;
        const value = env.f.CallStaticBooleanMethodA(env, self.cls, method, &.{.{ .j = id }});
        if (env.f.ExceptionCheck(env) != 0) return error.FixtureFailed;
        return value != 0;
    }
    fn waitStarted(self: Fixture, id: i64) !void {
        const io = self.rt.io;
        const until = std.Io.Clock.awake.now(io).toMilliseconds() + 5000;
        while (!try self.flag("started", id)) {
            if (std.Io.Clock.awake.now(io).toMilliseconds() > until) return error.JvmCallDidNotStart;
            try io.sleep(.fromMilliseconds(1), .awake);
        }
    }
    fn checkEmpty(self: Fixture) !void {
        const env = try self.rt.vm.env();
        const method = env.f.GetStaticMethodID(env, self.cls, "activeCount", "()I") orelse return error.FixtureMethodMissing;
        try std.testing.expectEqual(0, env.f.CallStaticIntMethodA(env, self.cls, method, &.{}));
    }
};

fn popular(rt: *tachi.Runtime, id: i64) ![]u8 {
    return rt.call(id, "popular", "{\"page\":1}");
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.ExpectedHostAndFixtureJars;
    var random: [8]u8 = undefined;
    io.random(&random);
    const relative = try std.fmt.allocPrint(gpa, "zig-out/test-jvm-{x}", .{std.mem.readInt(u64, &random, .little)});
    defer gpa.free(relative);
    try std.Io.Dir.cwd().createDirPath(io, relative);
    defer std.Io.Dir.cwd().deleteTree(io, relative) catch {};
    const dir = try std.Io.Dir.cwd().realPathFileAlloc(io, relative, gpa);
    defer gpa.free(dir);
    const rt = try tachi.Runtime.init(gpa, io, .{
        .data_dir = dir,
        .host_jar = args[1],
        .extra_classpath = &.{args[2]},
        .environ = init.minimal.environ,
        .class_data_sharing = false,
    });
    defer rt.deinit();
    try std.testing.expect(rt.supportsCancellation());
    const fixture = try Fixture.init(rt);
    defer fixture.deinit();
    try fixture.command("install");
    defer fixture.command("cleanup") catch {};
    var first = try io.concurrent(popular, .{ rt, @as(i64, 101) });
    defer {
        if (first.cancel(io)) |bytes| gpa.free(bytes) else |_| {}
    }
    var second = try io.concurrent(popular, .{ rt, @as(i64, 102) });
    var second_taken = false;
    defer {
        fixture.command("releaseSecond") catch {};
        if (second.cancel(io)) |bytes| {
            if (!second_taken) gpa.free(bytes);
        } else |_| {}
    }
    try fixture.waitStarted(101);
    try fixture.waitStarted(102);
    try std.testing.expectError(error.Canceled, first.cancel(io));
    try std.testing.expect(try fixture.flag("ended", 101));
    try std.testing.expect(!try fixture.flag("ended", 102));
    try fixture.command("releaseSecond");
    const response = try second.await(io);
    second_taken = true;
    defer gpa.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "mangas") != null);
    try std.testing.expectError(error.ExtensionError, popular(rt, 103));
    try std.testing.expect(std.mem.indexOf(u8, tachi.lastError(), "fixture diagnostic") != null);
    const image = try rt.fetchImage(104, "{\"index\":0,\"imageUrl\":\"http://fixture/image\"}");
    defer image.deinit(gpa);
    try std.testing.expectEqualStrings("fixture image", image.bytes);
    try std.testing.expectEqualStrings("image/png", image.mime.?);
    try fixture.checkEmpty();
    std.debug.print("PASS: real JNI targeted cancellation, independent operation, diagnostics, image metadata and registry cleanup\n", .{});
}

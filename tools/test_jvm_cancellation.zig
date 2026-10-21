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

const WorkerProbe = struct {
    io: std.Io,
    entered: std.Io.Event = .unset,
    ready: std.Io.Event = .unset,
    done: std.Io.Event = .unset,

    fn run(client: *tachi.worker.Client, source: i64, probe: *@This()) !void {
        probe.entered.set(probe.io);
        defer probe.done.set(probe.io);
        var arena: std.heap.ArenaAllocator = .init(client.gpa);
        defer arena.deinit();
        const call: tachi.backend.Call = if (source == 104) .{ .filters = source } else .{ .browse = .{ .source = source } };
        _ = try client.run(arena.allocator(), call, .{
            .context = probe,
            .starting = starting,
            .ready = isReady,
            .loading = loading,
        });
    }
    fn starting(_: *anyopaque) void {}
    fn isReady(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.ready.set(self.io);
    }
    fn loading(_: *anyopaque, _: ?[]const u8) void {}
};

fn testWorker(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, dir: []const u8) !void {
    const exe = try std.Io.Dir.cwd().realPathFileAlloc(io, args[0], gpa);
    defer gpa.free(exe);
    const child_dir = try std.fs.path.join(gpa, &.{ dir, "worker" });
    defer gpa.free(child_dir);
    var client: tachi.worker.Client = undefined;
    try client.init(gpa, io, .{ .exe = exe, .args = &.{ "--worker", args[1], args[2], child_dir } });
    defer client.deinit();
    var active_probe: WorkerProbe = .{ .io = io };
    var queued_probe: WorkerProbe = .{ .io = io };
    var active = try io.concurrent(WorkerProbe.run, .{ &client, @as(i64, 105), &active_probe });
    defer active.cancel(io) catch {};
    try active_probe.ready.wait(io);
    const marker = try std.fs.path.join(gpa, &.{ child_dir, "uncooperative.started" });
    defer gpa.free(marker);
    const until = std.Io.Clock.awake.now(io).toMilliseconds() + 5000;
    while (true) {
        if (std.Io.Dir.cwd().access(io, marker, .{})) break else |err| {
            if (err != error.FileNotFound) return err;
        }
        if (std.Io.Clock.awake.now(io).toMilliseconds() > until) return error.UncooperativeCallDidNotStart;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    const pid = client.workerPid();
    try std.testing.expect(pid > 0);
    var queued = try io.concurrent(WorkerProbe.run, .{ &client, @as(i64, 102), &queued_probe });
    defer queued.cancel(io) catch {};
    try queued_probe.entered.wait(io);
    try std.testing.expectError(error.Canceled, queued.cancel(io));
    try std.testing.expectEqual(pid, client.workerPid());
    try std.testing.expect(!active_probe.done.isSet());
    try std.testing.expectError(error.Canceled, active.cancel(io));
    try std.testing.expectEqual(-1, client.workerPid());
    var restarted: WorkerProbe = .{ .io = io };
    try WorkerProbe.run(&client, 104, &restarted);
    std.debug.print("PASS: queued worker cancellation isolation, uncooperative worker termination and restart\n", .{});
    const SearchProbe = struct {
        io: std.Io,
        dir: []const u8,
        count: usize = 0,
        successful: usize = 0,
        failed: usize = 0,
        fn starting(_: *anyopaque) void {}
        fn ready(_: *anyopaque) void {}
        fn loading(_: *anyopaque, _: ?[]const u8) void {}
        fn result(ptr: *anyopaque, value: tachi.backend.SourceSearch) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.count += 1;
            if (value.failure) |failure| {
                try std.testing.expectEqual(108, value.source);
                try std.testing.expect(std.mem.indexOf(u8, failure, "search fixture diagnostic") != null);
                self.failed += 1;
            } else {
                try std.testing.expectEqualStrings("Parallel query", value.mangas[0].title);
                self.successful += 1;
            }
            if (value.source == 107) {
                var root = try std.Io.Dir.cwd().openDir(self.io, self.dir, .{});
                defer root.close(self.io);
                try root.writeFile(self.io, .{ .sub_path = "search.release", .data = "release" });
            }
        }
    };
    var search: SearchProbe = .{ .io = io, .dir = child_dir };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try client.backend().search(gpa, io, arena.allocator(), .{ .sources = &.{ 106, 107, 108 }, .query = "Parallel query", .parallelism = 2 }, .{
        .context = &search,
        .starting = SearchProbe.starting,
        .ready = SearchProbe.ready,
        .loading = SearchProbe.loading,
        .search_result = SearchProbe.result,
    });
    try std.testing.expectEqual(3, search.count);
    try std.testing.expectEqual(2, search.successful);
    try std.testing.expectEqual(1, search.failed);
    std.debug.print("PASS: concurrent single-JVM worker searches, streamed partial results and isolated source failure\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 5 and std.mem.eql(u8, args[1], "--worker")) {
        var backend: tachi.backend.InProcess = .init(gpa, io, .{
            .data_dir = args[4],
            .host_jar = args[2],
            .extra_classpath = &.{args[3]},
            .environ = init.minimal.environ,
            .class_data_sharing = false,
        });
        const rt = try backend.runtime();
        const fixture = try Fixture.init(rt);
        try fixture.command("install");
        tachi.worker.serve(gpa, &backend, .{});
    }
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
    try testWorker(gpa, io, args, dir);
}

//! Bounded independent work with task-local allocation and serial publication.
const std = @import("std");
const Io = std.Io;

pub const default_limit = 4;

// Resource bookkeeping must not acknowledge cancellation through incidental
// allocator I/O (e.g. SafeAllocator's best-effort diagnostic stack capture).
// Keep cancellation on the coordinator until an explicit cancellation point;
// work and publication callbacks still run with the caller's protection.
fn uncancelable(io: Io, comptime function: anytype, args: anytype) @TypeOf(@call(.auto, function, args)) {
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    return @call(.auto, function, args);
}

/// Starts items in index order, publishing in completion order on the caller's
/// task. `work(context, scratch, index)` returns an error union; all its output
/// must belong to `scratch` or be borrowed. `publish(context, index, value,
/// arena)` must copy retained output or move `arena` and reinitialize it.
/// On any error or cancellation, all outstanding work is canceled and joined
/// before its arenas or borrowed inputs are released. Zero limits mean one.
pub fn run(gpa: std.mem.Allocator, io: Io, count: usize, limit: usize, context: anytype, comptime work: anytype, comptime publish: anytype) !void {
    try io.checkCancel();
    if (count == 0) return;
    const Result = @typeInfo(@TypeOf(work(context, gpa, 0))).error_union.payload;
    const Slot = struct {
        arena: std.heap.ArenaAllocator,
        index: usize,
        result: anyerror!Result = undefined,
        future: ?Io.Future(void) = null,

        fn execute(self: *@This(), ctx: @TypeOf(context), slot: usize, task_io: Io, completions: *Io.Queue(usize)) void {
            self.result = work(ctx, self.arena.allocator(), self.index);
            completions.putOneUncancelable(task_io, slot) catch |err| switch (err) {
                error.Closed => {},
            };
        }
    };
    const width = @min(count, @max(1, limit));
    const slots = try uncancelable(io, std.mem.Allocator.alloc, .{ gpa, Slot, width });
    defer uncancelable(io, std.mem.Allocator.free, .{ gpa, slots });
    for (slots, 0..) |*slot, i| slot.* = .{ .arena = .init(gpa), .index = i };
    defer for (slots) |*slot| uncancelable(io, std.heap.ArenaAllocator.deinit, .{slot.arena});
    const buffer = try uncancelable(io, std.mem.Allocator.alloc, .{ gpa, usize, width });
    defer uncancelable(io, std.mem.Allocator.free, .{ gpa, buffer });
    var completions: Io.Queue(usize) = .init(buffer);
    defer {
        completions.close(io);
        for (slots) |*slot| if (slot.future) |*future| future.cancel(io);
    }
    for (slots, 0..) |*slot, i| slot.future = try uncancelable(io, Io.concurrent, .{ io, Slot.execute, .{ slot, context, i, io, &completions } });
    var next = width;
    for (0..count) |_| {
        const i = completions.getOne(io) catch |err| switch (err) {
            error.Canceled => return err,
            error.Closed => unreachable,
        };
        try io.checkCancel();
        const slot = &slots[i];
        // A completion fixes result, but the future still owns task storage.
        // Await can free that storage using an allocator whose diagnostic I/O
        // silently consumes Canceled. Do not lose the coordinator's one-shot
        // cancellation here and then park forever waiting for live siblings.
        uncancelable(io, Io.Future(void).await, .{ &slot.future.?, io });
        slot.future = null;
        try io.checkCancel();
        try publish(context, slot.index, try slot.result, &slot.arena);
        _ = uncancelable(io, std.heap.ArenaAllocator.reset, .{ &slot.arena, .free_all });
        if (next < count) {
            slot.index = next;
            next += 1;
            slot.future = try uncancelable(io, Io.concurrent, .{ io, Slot.execute, .{ slot, context, i, io, &completions } });
        }
    }
}

test "bounded work overlaps and publishes scratch output serially in completion order" {
    const Context = struct {
        io: Io,
        second: Io.Event = .unset,
        release: Io.Event = .unset,
        active: std.atomic.Value(usize) = .init(0),
        peak: std.atomic.Value(usize) = .init(0),
        order: [6]usize = undefined,
        done: usize = 0,

        fn work(self: *@This(), scratch: std.mem.Allocator, i: usize) ![]const u8 {
            const active = self.active.fetchAdd(1, .acq_rel) + 1;
            defer _ = self.active.fetchSub(1, .acq_rel);
            _ = self.peak.fetchMax(active, .acq_rel);
            if (i == 0) try self.release.wait(self.io);
            if (i == 1) {
                self.second.set(self.io);
                // Item zero is still active, proving actual overlap.
                try std.testing.expectEqual(2, self.active.load(.acquire));
            }
            return std.fmt.allocPrint(scratch, "{d}", .{i});
        }
        fn publish(self: *@This(), i: usize, value: []const u8, _: *std.heap.ArenaAllocator) !void {
            try std.testing.expectEqual(i, try std.fmt.parseInt(usize, value, 10));
            self.order[self.done] = i;
            self.done += 1;
            if (i == 1) self.release.set(self.io);
        }
    };
    var ctx: Context = .{ .io = std.testing.io };
    try run(std.testing.allocator, ctx.io, 6, 2, &ctx, Context.work, Context.publish);
    try std.testing.expect(ctx.second.isSet());
    try std.testing.expectEqual(1, ctx.order[0]);
    try std.testing.expectEqual(6, ctx.done);
    try std.testing.expectEqual(2, ctx.peak.load(.acquire));
    try std.testing.expectEqual(0, ctx.active.load(.acquire));
}

test "bounded work cancels and joins siblings on failure and caller cancellation" {
    const Context = struct {
        io: Io,
        started: Io.Event = .unset,
        ended: Io.Event = .unset,
        parked: Io.Event = .unset,
        fail: bool,
        published: usize = 0,

        fn work(self: *@This(), scratch: std.mem.Allocator, i: usize) !void {
            _ = try scratch.alloc(u8, 100);
            if (i == 0 and self.fail) {
                try self.started.wait(self.io);
                return error.TestFailure;
            }
            defer self.ended.set(self.io);
            self.started.set(self.io);
            try self.parked.wait(self.io);
        }
        fn publish(self: *@This(), _: usize, _: void, _: *std.heap.ArenaAllocator) !void {
            self.published += 1;
        }
        fn call(self: *@This()) !void {
            try run(std.testing.allocator, self.io, 2, 2, self, work, publish);
        }
    };
    const io = std.testing.io;
    var failure: Context = .{ .io = io, .fail = true };
    try std.testing.expectError(error.TestFailure, failure.call());
    try std.testing.expect(failure.ended.isSet());
    try std.testing.expectEqual(0, failure.published);
    var canceled: Context = .{ .io = io, .fail = false };
    var future = try io.concurrent(Context.call, .{&canceled});
    defer _ = future.cancel(io) catch {};
    try canceled.started.wait(io);
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try std.testing.expect(canceled.ended.isSet());
    try std.testing.expectEqual(0, canceled.published);
}

test "bounded work handles empty input and a zero limit" {
    const Context = struct {
        done: usize = 0,
        fn work(_: *@This(), _: std.mem.Allocator, i: usize) !usize {
            return i;
        }
        fn publish(self: *@This(), i: usize, value: usize, _: *std.heap.ArenaAllocator) !void {
            try std.testing.expectEqual(self.done, i);
            try std.testing.expectEqual(i, value);
            self.done += 1;
        }
    };
    var ctx: Context = .{};
    try run(std.testing.allocator, std.testing.io, 0, 0, &ctx, Context.work, Context.publish);
    try std.testing.expectEqual(0, ctx.done);
    try run(std.testing.allocator, std.testing.io, 3, 0, &ctx, Context.work, Context.publish);
    try std.testing.expectEqual(3, ctx.done);
}

// Inject the allocator-diagnostic cancellation point in Future.await teardown.
// Real SafeAllocator stack capture can acknowledge Canceled and discard it.
// Gate it after the completed result is fixed, with nested siblings parked.
test "completed task teardown cannot consume cancellation with nested downloads parked" {
    const t = std.testing;
    const Context = struct {
        io: Io,
        at_teardown: Io.Event = .unset,
        parked: Io.Event = .unset,
        pages_started: Io.Event = .unset,
        active: std.atomic.Value(usize) = .init(0),
        ended: std.atomic.Value(usize) = .init(0),
        swallowed: bool = false,
        published: usize = 0,
        var current: *@This() = undefined;

        fn awaitTask(userdata: ?*anyopaque, future: *Io.AnyFuture, result: []u8, alignment: std.mem.Alignment) void {
            t.io.vtable.await(userdata, future, result, alignment);
            const ctx = current;
            ctx.at_teardown.set(t.io);
            // Deliver and re-arm a real cancellation at this exact boundary.
            // Temporarily unblock solely for the test gate, then restore the
            // caller's protection before simulating allocator diagnostics.
            const protection = t.io.swapCancelProtection(.unblocked);
            ctx.parked.wait(t.io) catch {};
            t.io.recancel();
            _ = t.io.swapCancelProtection(protection);
            t.io.checkCancel() catch {
                ctx.swallowed = true;
            };
        }
        fn page(ctx: *@This(), _: std.mem.Allocator, _: usize) !void {
            if (ctx.active.fetchAdd(1, .acq_rel) + 1 == 2) ctx.pages_started.set(t.io);
            defer _ = ctx.ended.fetchAdd(1, .acq_rel);
            try ctx.parked.wait(t.io);
        }
        fn chapter(ctx: *@This(), _: std.mem.Allocator, i: usize) !void {
            if (i == 0) return ctx.pages_started.wait(t.io);
            try run(t.allocator, ctx.io, 2, 2, ctx, page, publish);
        }
        fn publish(ctx: *@This(), _: usize, _: void, _: *std.heap.ArenaAllocator) !void {
            ctx.published += 1;
        }
        fn call(ctx: *@This()) !void {
            try run(t.allocator, ctx.io, 2, 2, ctx, chapter, publish);
        }
    };
    var vtable = t.io.vtable.*;
    vtable.await = Context.awaitTask;
    var ctx: Context = .{ .io = .{ .userdata = t.io.userdata, .vtable = &vtable } };
    Context.current = &ctx;
    var future = try t.io.concurrent(Context.call, .{&ctx});
    try ctx.at_teardown.wait(t.io);
    try t.expectError(error.Canceled, future.cancel(t.io));
    try t.expect(!ctx.swallowed);
    try t.expectEqual(2, ctx.ended.load(.acquire));
    try t.expectEqual(0, ctx.published);
}

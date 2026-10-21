//! Adapts foreign blocking work to a cancelable wait without abandoning its memory.
const std = @import("std");
const Io = std.Io;

/// `cancel` must ask the foreign operation to unwind. Its task is always joined
/// before returning, so `context` and all borrowed inputs remain alive. A late
/// successful result is passed to `discard` when the caller was canceled.
pub fn run(comptime T: type, io: Io, context: anytype, comptime work: anytype, comptime cancel: anytype, comptime discard: anytype) !T {
    try io.checkCancel();
    const State = struct {
        io: Io,
        context: @TypeOf(context),
        done: Io.Event = .unset,
        result: @TypeOf(work(context)) = undefined,

        fn execute(self: *@This()) void {
            defer self.done.set(self.io);
            self.result = work(self.context);
        }
    };
    var state: State = .{ .io = io, .context = context };
    var future = try io.concurrent(State.execute, .{&state});
    defer future.await(io);
    // Event.wait can take a completed fast path; checkCancel also covers a
    // cancellation racing completion, without losing a successful allocation.
    const waited = blk: {
        state.done.wait(io) catch |err| break :blk @as(Io.Cancelable!void, err);
        break :blk io.checkCancel();
    };
    waited catch |err| {
        cancel(context);
        state.done.waitUncancelable(io);
        if (state.result) |value| discard(context, value) else |_| {}
        return err;
    };
    return state.result;
}

test "cancelable foreign waits target one operation and discard late successful output" {
    const Context = struct {
        io: Io,
        started: Io.Event = .unset,
        release: Io.Event = .unset,
        ended: Io.Event = .unset,
        canceled: bool = false,
        discarded: bool = false,

        fn work(self: *@This()) !u32 {
            self.started.set(self.io);
            self.release.waitUncancelable(self.io);
            self.ended.set(self.io);
            return 42;
        }
        fn cancel(self: *@This()) void {
            self.canceled = true;
            self.release.set(self.io);
        }
        fn discard(self: *@This(), value: u32) void {
            std.debug.assert(value == 42);
            self.discarded = true;
        }
        fn call(self: *@This()) !u32 {
            return run(u32, self.io, self, work, cancel, discard);
        }
    };
    const io = std.testing.io;
    var first: Context = .{ .io = io };
    var second: Context = .{ .io = io };
    var a = try io.concurrent(Context.call, .{&first});
    defer _ = a.cancel(io) catch {};
    var b = try io.concurrent(Context.call, .{&second});
    defer {
        second.release.set(io);
        _ = b.cancel(io) catch {};
    }
    try first.started.wait(io);
    try second.started.wait(io);
    try std.testing.expectError(error.Canceled, a.cancel(io));
    try std.testing.expect(first.canceled and first.discarded and first.ended.isSet());
    try std.testing.expect(!second.canceled and !second.ended.isSet());
    second.release.set(io);
    try std.testing.expectEqual(42, try b.await(io));
    try std.testing.expect(!second.discarded);
}

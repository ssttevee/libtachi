//! Shikimori (tracker 4), as Mihon talks to it. Not implemented yet.
const driver = @import("driver.zig");
const tracking = @import("../tracking.zig");

pub const default_base_url = "";

pub fn call(ctx: *driver.Context, op: tracking.Operation) !tracking.Reply {
    _ = ctx;
    _ = op;
    return error.TrackerNotImplemented;
}

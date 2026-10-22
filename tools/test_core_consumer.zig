//! A standalone integrator: its only project module import is tachicore.
const std = @import("std");
const core = @import("tachicore");

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const index = try core.discovery.parseIndex(arena.allocator(), "\x0a\x04Test");
    if (!std.mem.eql(u8, index.name, "Test")) return error.InvalidDiscoveryResult;
    comptime {
        if (@hasDecl(core, "Engine") or @hasDecl(core, "downloads") or @hasDecl(core, "library")) @compileError("application policy leaked into the core");
    }
    const result = try core.Result(core.models.MangasPage).fromJson(init.gpa, "{\"mangas\":[],\"hasNextPage\":false}");
    defer result.deinit();
    if (result.value().mangas.len != 0) return error.InvalidSourceResult;
}

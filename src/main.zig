//! tachi-cli: exercise extensions from the command line.
//!
//!   tachi-cli [--data-dir DIR] [--host-jar JAR] [--java-home DIR] [--ext FILE]... [-v] <command> [args]
//!
//! See `Command` for the list of commands and their arguments.
const std = @import("std");
const Io = std.Io;
const tachi = @import("tachi");

/// Every CLI command, with the bridge method it maps to and how its
/// positional arguments become the JSON argument object.
const Command = enum {
    install,
    list,
    popular,
    latest,
    search,
    details,
    chapters,
    pages,
    image,
    filters,
    prefs,
    setpref,
    call,
    mangaUrl,
    chapterUrl,
    info,

    fn help(c: Command) []const u8 {
        return switch (c) {
            .install => "install FILE                 load an extension and print its info",
            .list => "list                         list loaded extensions (use --ext to load some first)",
            .popular => "popular ID [PAGE]            popular manga",
            .latest => "latest ID [PAGE]             latest updates",
            .search => "search ID QUERY [PAGE]       search by text",
            .details => "details ID MANGA_URL         manga details",
            .chapters => "chapters ID MANGA_URL        chapter list",
            .pages => "pages ID CHAPTER_URL         page list",
            .image => "image ID IMAGE_URL OUTFILE   download one page image",
            .filters => "filters ID                   filter list",
            .prefs => "prefs ID                     preferences of a configurable source",
            .setpref => "setpref ID KEY JSON_VALUE    change a preference",
            .call => "call ID METHOD [ARGS_JSON]   raw bridge call",
            .mangaUrl => "mangaUrl ID MANGA_URL        browser URL for a manga",
            .chapterUrl => "chapterUrl ID CHAPTER_URL    browser URL for a chapter",
            .info => "info ID                      source info",
        };
    }

    /// Bridge method name; most commands share their own name.
    fn method(c: Command) []const u8 {
        return switch (c) {
            .prefs => "preferences",
            .setpref => "setPreference",
            else => @tagName(c),
        };
    }

    /// Minimum positional arguments after the source id.
    fn minArgs(c: Command) usize {
        return switch (c) {
            .search, .details, .chapters, .pages, .mangaUrl, .chapterUrl, .call => 1,
            .setpref => 2,
            .image => 2,
            else => 0,
        };
    }
};

const Flags = struct {
    data_dir: []const u8 = ".tachi-data",
    host_jar: ?[]const u8 = null,
    java_home: ?[]const u8 = null,
    verbose: bool = false,
};

fn logFn(level: tachi.LogLevel, tag: [*:0]const u8, message: [*:0]const u8, _: ?*anyopaque) callconv(.c) void {
    const letter: u8 = switch (level) {
        .verbose => 'V',
        .debug => 'D',
        .info => 'I',
        .warn => 'W',
        .err => 'E',
        else => 'A',
    };
    std.debug.print("{c}/{s}: {s}\n", .{ letter, tag, message });
}

fn usage() noreturn {
    std.debug.print("usage: tachi-cli [--data-dir DIR] [--host-jar JAR] [--java-home DIR] [--ext FILE]... [-v] <command> [args]\n\ncommands:\n", .{});
    inline for (comptime std.enums.values(Command)) |c| std.debug.print("  {s}\n", .{c.help()});
    std.process.exit(2);
}

fn fail(e: anyerror) noreturn {
    std.debug.print("error: {s}: {s}\n", .{ @errorName(e), tachi.lastError() });
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var flags: Flags = .{};
    var exts: std.ArrayList([]const u8) = .empty;
    var positional: std.ArrayList([]const u8) = .empty;

    var it = init.minimal.args.iterate();
    _ = it.next(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--data-dir")) {
            flags.data_dir = it.next() orelse usage();
        } else if (std.mem.eql(u8, arg, "--host-jar")) {
            flags.host_jar = it.next() orelse usage();
        } else if (std.mem.eql(u8, arg, "--java-home")) {
            flags.java_home = it.next() orelse usage();
        } else if (std.mem.eql(u8, arg, "--ext")) {
            try exts.append(arena, it.next() orelse usage());
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            flags.verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            usage();
        } else {
            try positional.append(arena, arg);
        }
    }
    if (positional.items.len == 0) usage();
    const cmd = std.meta.stringToEnum(Command, positional.items[0]) orelse usage();
    const args = positional.items[1..];

    const rt = tachi.Runtime.init(gpa, io, .{
        .data_dir = flags.data_dir,
        .host_jar = flags.host_jar,
        .java_home = flags.java_home,
        .verbose = flags.verbose,
        .log_fn = logFn,
        .environ = init.minimal.environ,
    }) catch |e| {
        std.debug.print("error: failed to start runtime: {s}: {s}\n", .{ @errorName(e), tachi.lastError() });
        std.process.exit(1);
    };
    defer rt.deinit();

    for (exts.items) |path| gpa.free(rt.installExtension(path) catch |e| fail(e));

    var out_buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    switch (cmd) {
        .install => {
            if (args.len < 1) usage();
            const json = rt.installExtension(args[0]) catch |e| fail(e);
            defer gpa.free(json);
            try printJson(gpa, w, json);
        },
        .list => {
            const json = rt.listExtensions() catch |e| fail(e);
            defer gpa.free(json);
            try printJson(gpa, w, json);
        },
        else => {
            if (args.len < 1 + cmd.minArgs()) usage();
            const id = parseId(args[0]);
            const rest = args[1..];
            if (cmd == .image) {
                const page = try std.json.Stringify.valueAlloc(arena, .{ .index = 0, .url = "", .imageUrl = rest[0] }, .{});
                const img = rt.fetchImage(id, page) catch |e| fail(e);
                defer img.deinit(gpa);
                try Io.Dir.cwd().writeFile(io, .{ .sub_path = rest[1], .data = img.bytes });
                try w.print("wrote {d} bytes ({s}) to {s}\n", .{ img.bytes.len, img.mime orelse "unknown type", rest[1] });
                return;
            }
            const call_args = try buildArgs(arena, cmd, rest);
            const method = if (cmd == .call) rest[0] else cmd.method();
            const json = rt.call(id, method, call_args) catch |e| fail(e);
            defer gpa.free(json);
            try printJson(gpa, w, json);
        },
    }
}

/// JSON argument object for a source call, from the positional args after the id.
fn buildArgs(arena: std.mem.Allocator, cmd: Command, rest: []const []const u8) ![]const u8 {
    const S = std.json.Stringify;
    return switch (cmd) {
        .popular, .latest => try S.valueAlloc(arena, .{ .page = pageArg(rest, 0) }, .{}),
        .search => try S.valueAlloc(arena, .{ .page = pageArg(rest, 1), .query = rest[0] }, .{}),
        .details, .chapters, .mangaUrl => try S.valueAlloc(arena, .{ .manga = .{ .url = rest[0], .title = "" } }, .{}),
        .pages, .chapterUrl => try S.valueAlloc(arena, .{ .chapter = .{ .url = rest[0], .name = "" } }, .{}),
        .setpref => try std.fmt.allocPrint(arena, "{{\"key\":{f},\"value\":{s}}}", .{ std.json.fmt(rest[0], .{}), rest[1] }),
        .call => if (rest.len > 1) rest[1] else "{}",
        .filters, .info, .prefs => "{}",
        .install, .list, .image => unreachable, // handled by the caller
    };
}

fn parseId(s: []const u8) i64 {
    return std.fmt.parseInt(i64, s, 10) catch {
        std.debug.print("error: source id must be an integer, got '{s}'\n", .{s});
        std.process.exit(2);
    };
}

fn pageArg(rest: []const []const u8, idx: usize) i32 {
    if (rest.len <= idx) return 1;
    return std.fmt.parseInt(i32, rest[idx], 10) catch 1;
}

fn printJson(gpa: std.mem.Allocator, w: *Io.Writer, json: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch {
        try w.print("{s}\n", .{json});
        return;
    };
    defer parsed.deinit();
    try w.print("{f}\n", .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })});
}

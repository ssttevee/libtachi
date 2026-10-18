//! tachi-cli: exercise extensions from the command line.
//!
//!   tachi-cli [--data-dir DIR] [--host-jar JAR] [--ext FILE]... [-v] <command> [args]
//!
//! Commands:
//!   install FILE                 load an extension and print its info
//!   list                         list loaded extensions (use --ext to load some first)
//!   popular ID [PAGE]            popular manga
//!   latest ID [PAGE]             latest updates
//!   search ID QUERY [PAGE]       search by text
//!   details ID MANGA_URL         manga details
//!   chapters ID MANGA_URL        chapter list
//!   pages ID CHAPTER_URL         page list
//!   image ID IMAGE_URL OUTFILE   download one page image
//!   filters ID                   filter list
//!   prefs ID                     preferences of a configurable source
//!   setpref ID KEY JSON_VALUE    change a preference
//!   call ID METHOD [ARGS_JSON]   raw bridge call
const std = @import("std");
const tachi = @import("tachi");

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
    std.debug.print(
        \\usage: tachi-cli [--data-dir DIR] [--host-jar JAR] [--java-home DIR] [--ext FILE]... [-v] <command> [args]
        \\
        \\commands:
        \\  install FILE               list                    popular ID [PAGE]
        \\  latest ID [PAGE]           search ID QUERY [PAGE]  details ID MANGA_URL
        \\  chapters ID MANGA_URL      pages ID CHAPTER_URL    image ID IMAGE_URL OUTFILE
        \\  filters ID                 prefs ID                setpref ID KEY JSON_VALUE
        \\  call ID METHOD [ARGS_JSON]
        \\
    , .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var data_dir: []const u8 = ".tachi-data";
    var host_jar: ?[]const u8 = null;
    var java_home: ?[]const u8 = null;
    var verbose = false;
    var exts: std.ArrayList([]const u8) = .empty;
    var positional: std.ArrayList([]const u8) = .empty;

    var it = init.minimal.args.iterate();
    _ = it.next(); // argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--data-dir")) {
            data_dir = it.next() orelse usage();
        } else if (std.mem.eql(u8, arg, "--host-jar")) {
            host_jar = it.next() orelse usage();
        } else if (std.mem.eql(u8, arg, "--java-home")) {
            java_home = it.next() orelse usage();
        } else if (std.mem.eql(u8, arg, "--ext")) {
            try exts.append(arena, it.next() orelse usage());
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            usage();
        } else {
            try positional.append(arena, arg);
        }
    }
    if (positional.items.len == 0) usage();
    const cmd = positional.items[0];
    const args = positional.items[1..];

    const rt = tachi.Runtime.init(gpa, .{
        .data_dir = data_dir,
        .host_jar = host_jar,
        .java_home = java_home,
        .verbose = verbose,
        .log_fn = logFn,
    }) catch |e| {
        std.debug.print("error: failed to start runtime: {s}: {s}\n", .{ @errorName(e), tachi.lastError() });
        std.process.exit(1);
    };
    defer rt.deinit();

    for (exts.items) |path| {
        const info = rt.installExtension(path) catch |e| fail(e);
        gpa.free(info);
    }

    var out_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;

    if (std.mem.eql(u8, cmd, "install")) {
        if (args.len < 1) usage();
        const json = rt.installExtension(args[0]) catch |e| fail(e);
        defer gpa.free(json);
        try printJson(gpa, w, json);
    } else if (std.mem.eql(u8, cmd, "list")) {
        const json = rt.listExtensions() catch |e| fail(e);
        defer gpa.free(json);
        try printJson(gpa, w, json);
    } else if (std.mem.eql(u8, cmd, "image")) {
        if (args.len < 3) usage();
        const id = parseId(args[0]);
        const page = try std.json.Stringify.valueAlloc(arena, .{ .index = 0, .url = "", .imageUrl = args[1] }, .{});
        const img = rt.fetchImage(id, page) catch |e| fail(e);
        defer img.deinit(gpa);
        const file = try std.Io.Dir.cwd().createFile(io, args[2], .{});
        defer file.close(io);
        try file.writeStreamingAll(io, img.bytes);
        try w.print("wrote {d} bytes ({s}) to {s}\n", .{ img.bytes.len, img.mime orelse "unknown type", args[2] });
    } else {
        if (args.len < 1) usage();
        const id = parseId(args[0]);
        const rest = args[1..];
        var method: []const u8 = cmd;
        var call_args: []const u8 = "{}";

        if (std.mem.eql(u8, cmd, "popular") or std.mem.eql(u8, cmd, "latest")) {
            call_args = try std.json.Stringify.valueAlloc(arena, .{ .page = pageArg(rest, 0) }, .{});
        } else if (std.mem.eql(u8, cmd, "search")) {
            if (rest.len < 1) usage();
            call_args = try std.json.Stringify.valueAlloc(arena, .{ .page = pageArg(rest, 1), .query = rest[0] }, .{});
        } else if (std.mem.eql(u8, cmd, "details") or std.mem.eql(u8, cmd, "chapters") or std.mem.eql(u8, cmd, "mangaUrl")) {
            if (rest.len < 1) usage();
            call_args = try std.json.Stringify.valueAlloc(arena, .{ .manga = .{ .url = rest[0], .title = "" } }, .{});
        } else if (std.mem.eql(u8, cmd, "pages") or std.mem.eql(u8, cmd, "chapterUrl")) {
            if (rest.len < 1) usage();
            call_args = try std.json.Stringify.valueAlloc(arena, .{ .chapter = .{ .url = rest[0], .name = "" } }, .{});
        } else if (std.mem.eql(u8, cmd, "filters") or std.mem.eql(u8, cmd, "info")) {
            // no args
        } else if (std.mem.eql(u8, cmd, "prefs")) {
            method = "preferences";
        } else if (std.mem.eql(u8, cmd, "setpref")) {
            if (rest.len < 2) usage();
            method = "setPreference";
            call_args = try std.fmt.allocPrint(arena, "{{\"key\":{f},\"value\":{s}}}", .{ std.json.fmt(rest[0], .{}), rest[1] });
        } else if (std.mem.eql(u8, cmd, "call")) {
            if (rest.len < 1) usage();
            method = rest[0];
            if (rest.len > 1) call_args = rest[1];
        } else {
            usage();
        }

        const json = rt.call(id, method, call_args) catch |e| fail(e);
        defer gpa.free(json);
        try printJson(gpa, w, json);
    }
    try w.flush();
}

fn fail(e: anyerror) noreturn {
    std.debug.print("error: {s}: {s}\n", .{ @errorName(e), tachi.lastError() });
    std.process.exit(1);
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

fn printJson(gpa: std.mem.Allocator, w: *std.Io.Writer, json: []const u8) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, json, .{}) catch {
        try w.writeAll(json);
        try w.writeAll("\n");
        return;
    };
    defer parsed.deinit();
    try w.print("{f}\n", .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })});
}

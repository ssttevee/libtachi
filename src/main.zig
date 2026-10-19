//! tachi-cli: exercise extensions from the command line.
//!
//!   tachi-cli [--data-dir DIR] [--host-jar JAR] [--java-home DIR] [--ext FILE]... [-v] <command> [args]
//!
//! Extensions installed with `install` or `repo install` are remembered in
//! the data dir and reloaded on every run, so `--ext` is only needed for
//! one-off files. See `Command` for the list of commands and their arguments.
const std = @import("std");
const Io = std.Io;
const tachi = @import("tachi");

/// Every CLI command, with the bridge method it maps to and how its
/// positional arguments become the JSON argument object.
const Command = enum {
    install,
    uninstall,
    list,
    repo,
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
            .install => "install FILE                 install an extension file and print its info",
            .uninstall => "uninstall PKG                unload and forget an extension",
            .list => "list                         list installed extensions",
            .repo => "repo list|install|update     browse and install from a repository (see --repo, --lang, --grep)",
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
    /// Skip reloading the installed extensions at startup.
    no_restore: bool = false,
    // `repo` options
    repo_url: ?[]const u8 = null,
    refresh: bool = false,
    lang: ?[]const u8 = null,
    grep: ?[]const u8 = null,
    json: bool = false,
};

const RepoCommand = enum {
    list,
    install,
    update,

    fn help(c: RepoCommand) []const u8 {
        return switch (c) {
            .list => "repo list [--lang L] [--grep S] [--json]   extensions in the index (* installed, ^ update available)",
            .install => "repo install PKG...                        download, verify and install packages",
            .update => "repo update                                upgrade every repo-installed package",
        };
    }
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
    std.debug.print(
        \\usage: tachi-cli [options] <command> [args]
        \\
        \\options:
        \\  --data-dir DIR   registry, downloads, preferences (default .tachi-data)
        \\  --host-jar JAR   tachi-host.jar (default $TACHI_HOST_JAR)
        \\  --java-home DIR  JDK to load libjvm from
        \\  --ext FILE       load an extension file for this run only
        \\  --no-restore     do not reload installed extensions
        \\  --repo URL       index URL (default keiyoushi)
        \\  --refresh        ignore the cached index
        \\  -v               verbose logging
        \\
        \\commands:
        \\
    , .{});
    inline for (comptime std.enums.values(Command)) |c| std.debug.print("  {s}\n", .{c.help()});
    inline for (comptime std.enums.values(RepoCommand)) |c| std.debug.print("  {s}\n", .{c.help()});
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
        } else if (std.mem.eql(u8, arg, "--no-restore")) {
            flags.no_restore = true;
        } else if (std.mem.eql(u8, arg, "--repo")) {
            flags.repo_url = it.next() orelse usage();
        } else if (std.mem.eql(u8, arg, "--refresh")) {
            flags.refresh = true;
        } else if (std.mem.eql(u8, arg, "--lang")) {
            flags.lang = it.next() orelse usage();
        } else if (std.mem.eql(u8, arg, "--grep")) {
            flags.grep = it.next() orelse usage();
        } else if (std.mem.eql(u8, arg, "--json")) {
            flags.json = true;
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

    if (!flags.no_restore) {
        const json = rt.restore() catch |e| fail(e);
        defer gpa.free(json);
        const r = try std.json.parseFromSlice(tachi.manage.RestoreResult, arena, json, tachi.models.parse_options);
        for (r.value.failed) |f| std.debug.print("warning: {s} not restored: {s}\n", .{ f.pkg, f.@"error" });
    }
    // One-off files bypass the registry.
    for (exts.items) |path| gpa.free(rt.loadPackage(path) catch |e| fail(e));

    var out_buf: [8192]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    defer w.flush() catch {};

    const repo_opts: tachi.Runtime.RepoOptions = .{ .url = flags.repo_url, .refresh = flags.refresh };

    switch (cmd) {
        .install => {
            if (args.len < 1) usage();
            const json = rt.installExtension(args[0]) catch |e| fail(e);
            defer gpa.free(json);
            try printJson(gpa, w, json);
        },
        .uninstall => {
            if (args.len < 1) usage();
            const removed = rt.uninstallExtension(args[0]) catch |e| fail(e);
            try w.print("{s}\n", .{if (removed) "removed" else "not installed"});
        },
        .repo => {
            if (args.len < 1) usage();
            switch (std.meta.stringToEnum(RepoCommand, args[0]) orelse usage()) {
                .list => try repoList(rt, arena, w, flags, repo_opts),
                .install => {
                    if (args.len < 2) usage();
                    for (args[1..]) |pkg| {
                        const json = rt.repoInstall(pkg, repo_opts) catch |e| fail(e);
                        defer gpa.free(json);
                        try printJson(gpa, w, json);
                    }
                },
                .update => {
                    const json = rt.repoUpdate(repo_opts) catch |e| fail(e);
                    defer gpa.free(json);
                    try printJson(gpa, w, json);
                },
            }
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

/// `repo list`: a filtered table, or the raw entries with `--json`.
fn repoList(rt: *tachi.Runtime, arena: std.mem.Allocator, w: *Io.Writer, flags: Flags, opts: tachi.Runtime.RepoOptions) !void {
    const all = rt.repoList(arena, opts) catch |e| fail(e);
    var shown: std.ArrayList(tachi.Runtime.RepoEntry) = .empty;
    for (all) |e| {
        if (flags.lang) |l| if (!std.mem.eql(u8, e.lang, l) and !std.mem.eql(u8, e.lang, "all")) continue;
        if (flags.grep) |g| if (std.ascii.findIgnoreCase(e.name, g) == null and std.ascii.findIgnoreCase(e.pkg, g) == null) continue;
        try shown.append(arena, e);
    }
    if (flags.json) {
        try std.json.Stringify.value(shown.items, .{ .whitespace = .indent_2 }, w);
        try w.writeByte('\n');
        return;
    }
    for (shown.items) |e| {
        const mark: u8 = if (e.hasUpdate) '^' else if (e.installed) '*' else ' ';
        try w.print("{c} {s: <56} {s: <8} {s: <4} {s}{s}\n", .{
            mark,                         e.pkg,  e.versionName, e.lang,
            if (e.nsfw) "[18+] " else "", e.name,
        });
    }
    try w.print("{d} of {d} extension(s)\n", .{ shown.items.len, all.len });
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
        .install, .uninstall, .list, .repo, .image => unreachable, // handled by the caller
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

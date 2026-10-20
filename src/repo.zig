//! Extension repository client: fetches a Mihon-style `index.pb`, decodes it,
//! downloads extension packages and checks who signed them.
//!
//! Everything here is pure Zig on `std.Io`; the JVM is never involved. The
//! index format is the "v2" protobuf Mihon and Suwayomi read (see
//! `NetworkExtensionStore` in Mihon); keiyoushi adds field 501 with a `.jar`
//! URL next to every `.apk`, which lets us skip dex2jar.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const default_index_url = "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb";

/// Largest index / package we are willing to hold in memory.
const max_index_len = 64 << 20;
const max_package_len = 256 << 20;

pub const Error = error{
    NetworkError,
    InvalidIndex,
    FileSystemError,
    OutOfMemory,
};

pub const ContentWarning = enum(u8) { unspecified = 0, safe = 1, mixed = 2, nsfw = 3, _ };

pub const Source = struct {
    id: i64,
    name: []const u8 = "",
    lang: []const u8 = "",
    base_url: []const u8 = "",
};

pub const Extension = struct {
    name: []const u8 = "",
    pkg: []const u8 = "",
    apk_url: []const u8 = "",
    icon_url: []const u8 = "",
    /// keiyoushi-specific: prebuilt JVM jar (index field 3.501).
    jar_url: ?[]const u8 = null,
    lib_version: []const u8 = "",
    version_code: i64 = 0,
    version_name: []const u8 = "",
    content_warning: ContentWarning = .unspecified,
    sources: []const Source = &.{},

    pub fn nsfw(e: Extension) bool {
        return e.content_warning == .nsfw or e.content_warning == .mixed;
    }

    /// "en" when every source shares a language, "all" otherwise.
    pub fn lang(e: Extension) []const u8 {
        if (e.sources.len == 0) return "";
        const first = e.sources[0].lang;
        for (e.sources[1..]) |s| if (!std.mem.eql(u8, s.lang, first)) return "all";
        return first;
    }

    /// URL to install from: the jar when the repo ships one, else the apk.
    pub fn downloadUrl(e: Extension) ?[]const u8 {
        if (e.jar_url) |u| if (u.len > 0) return u;
        return if (e.apk_url.len > 0) e.apk_url else null;
    }
};

pub const Store = struct {
    name: []const u8 = "",
    badge: []const u8 = "",
    /// SHA-256 of the signing certificate, lower-case hex, as Mihon stores it.
    signing_key: []const u8 = "",
    website: []const u8 = "",
    /// Set when the extension list lives at a separate URL (index field 102).
    extension_list_url: ?[]const u8 = null,
    extensions: []const Extension = &.{},

    pub fn find(s: Store, pkg: []const u8) ?Extension {
        for (s.extensions) |e| if (std.mem.eql(u8, e.pkg, pkg)) return e;
        return null;
    }
};

// ---- protobuf wire format ------------------------------------------------------

const Field = struct {
    num: u32,
    value: union(enum) { varint: u64, fixed64: u64, bytes: []const u8, fixed32: u32 },

    fn str(f: Field) []const u8 {
        return switch (f.value) {
            .bytes => |b| b,
            else => "",
        };
    }

    fn int(f: Field) i64 {
        return switch (f.value) {
            .varint => |v| @bitCast(v),
            .fixed64 => |v| @bitCast(v),
            .fixed32 => |v| v,
            .bytes => 0,
        };
    }
};

/// Schema-less walker over one protobuf message.
const Decoder = struct {
    bytes: []const u8,
    i: usize = 0,

    fn init(bytes: []const u8) Decoder {
        return .{ .bytes = bytes };
    }

    fn varint(d: *Decoder) Error!u64 {
        var shift: u6 = 0;
        var result: u64 = 0;
        while (true) {
            if (d.i >= d.bytes.len) return error.InvalidIndex;
            const c = d.bytes[d.i];
            d.i += 1;
            if (shift == 63 and c > 1) return error.InvalidIndex;
            result |= @as(u64, c & 0x7f) << shift;
            if (c & 0x80 == 0) return result;
            if (shift >= 63) return error.InvalidIndex;
            shift += 7;
        }
    }

    fn take(d: *Decoder, n: usize) Error![]const u8 {
        if (n > d.bytes.len - d.i) return error.InvalidIndex;
        defer d.i += n;
        return d.bytes[d.i..][0..n];
    }

    fn next(d: *Decoder) Error!?Field {
        if (d.i >= d.bytes.len) return null;
        const key = try d.varint();
        const num = std.math.cast(u29, key >> 3) orelse return error.InvalidIndex;
        if (num == 0) return error.InvalidIndex;
        return .{
            .num = num,
            .value = switch (@as(u3, @truncate(key))) {
                0 => .{ .varint = try d.varint() },
                1 => .{ .fixed64 = std.mem.readInt(u64, (try d.take(8))[0..8], .little) },
                2 => .{ .bytes = try d.take(std.math.cast(usize, try d.varint()) orelse return error.InvalidIndex) },
                5 => .{ .fixed32 = std.mem.readInt(u32, (try d.take(4))[0..4], .little) },
                else => return error.InvalidIndex, // groups (3/4) never appear in this format
            },
        };
    }
};

/// Decodes an index. Accepts gzip or raw protobuf. All slices point into
/// `arena` allocations or into `bytes` (strings are not copied), so keep
/// `bytes` alive as long as the `Store`.
pub fn parseIndex(arena: Allocator, bytes: []const u8) Error!Store {
    const raw = if (isGzip(bytes)) try gunzip(arena, bytes) else bytes;
    var store: Store = .{};
    var exts: std.ArrayList(Extension) = .empty;
    var d: Decoder = .init(raw);
    while (try d.next()) |f| switch (f.num) {
        1 => store.name = f.str(),
        2 => store.badge = f.str(),
        3 => store.signing_key = f.str(),
        4 => {
            var c: Decoder = .init(f.str());
            while (try c.next()) |cf| if (cf.num == 1) {
                store.website = cf.str();
            };
        },
        101 => {
            var list: Decoder = .init(f.str());
            while (try list.next()) |ef| if (ef.num == 1) {
                try exts.append(arena, try parseExtension(arena, ef.str()));
            };
        },
        102 => store.extension_list_url = f.str(),
        else => {},
    };
    store.extensions = exts.items;
    return store;
}

/// Decodes a bare extension list (what `extension_list_url` points at).
pub fn parseExtensionList(arena: Allocator, bytes: []const u8) Error![]const Extension {
    const raw = if (isGzip(bytes)) try gunzip(arena, bytes) else bytes;
    var exts: std.ArrayList(Extension) = .empty;
    var d: Decoder = .init(raw);
    while (try d.next()) |f| if (f.num == 1) {
        try exts.append(arena, try parseExtension(arena, f.str()));
    };
    return exts.items;
}

fn parseExtension(arena: Allocator, bytes: []const u8) Error!Extension {
    var e: Extension = .{};
    var sources: std.ArrayList(Source) = .empty;
    var d: Decoder = .init(bytes);
    while (try d.next()) |f| switch (f.num) {
        1 => e.name = f.str(),
        2 => e.pkg = f.str(),
        3 => {
            var r: Decoder = .init(f.str());
            while (try r.next()) |rf| switch (rf.num) {
                1 => e.apk_url = rf.str(),
                2 => e.icon_url = rf.str(),
                501 => e.jar_url = rf.str(),
                else => {},
            };
        },
        4 => e.lib_version = f.str(),
        5 => e.version_code = f.int(),
        6 => e.version_name = f.str(),
        7 => e.content_warning = @fromBackingInt(std.math.cast(u8, f.int()) orelse return error.InvalidIndex),
        8 => {
            var s: Source = .{ .id = 0 };
            var sd: Decoder = .init(f.str());
            while (try sd.next()) |sf| switch (sf.num) {
                1 => s.id = sf.int(),
                2 => s.name = sf.str(),
                3 => s.lang = sf.str(),
                4 => s.base_url = sf.str(),
                else => {},
            };
            try sources.append(arena, s);
        },
        else => {},
    };
    e.sources = sources.items;
    return e;
}

fn isGzip(bytes: []const u8) bool {
    return bytes.len >= 2 and bytes[0] == 0x1f and bytes[1] == 0x8b;
}

fn gunzip(gpa: Allocator, bytes: []const u8) Error![]u8 {
    var in: Io.Reader = .fixed(bytes);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var d: std.compress.flate.Decompress = .init(&in, .gzip, window);
    return d.reader.allocRemaining(gpa, .limited(max_index_len)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidIndex,
    };
}

// ---- HTTP ------------------------------------------------------------------------

/// One connection pool (and one CA-bundle scan) shared by every request.
pub const Http = struct {
    client: std.http.Client,
    user_agent: []const u8 = "zig-tachi",

    pub fn init(gpa: Allocator, io: Io) Http {
        return .{ .client = .{ .allocator = gpa, .io = io } };
    }

    /// Use explicit PEM roots without changing system files or disabling TLS.
    pub fn useCaFile(h: *Http, path: []const u8) Error!void {
        const now = Io.Clock.real.now(h.client.io);
        h.client.ca_bundle.addCertsFromFilePath(h.client.allocator, h.client.io, now, Io.Dir.cwd(), path) catch return error.NetworkError;
        h.client.now = now;
    }

    pub fn deinit(h: *Http) void {
        h.client.deinit();
    }

    /// GETs `url` into memory. Follows redirects; non-2xx is `NetworkError`.
    pub fn getAlloc(h: *Http, gpa: Allocator, url: []const u8, limit: usize) Error![]u8 {
        const uri = std.Uri.parse(url) catch return error.NetworkError;
        var request = h.client.request(.GET, uri, .{
            .headers = .{ .user_agent = .{ .override = h.user_agent } },
        }) catch |err| return httpError(err);
        defer request.deinit();
        request.sendBodiless() catch |err| return httpError(err);
        var redirect_buffer: [8 << 10]u8 = undefined;
        var response = request.receiveHead(&redirect_buffer) catch |err| return httpError(err);
        if (response.head.status.class() != .success) return error.NetworkError;

        const window_len: usize = switch (response.head.content_encoding) {
            .identity => 0,
            .gzip, .deflate => std.compress.flate.max_window_len,
            .zstd => std.compress.zstd.default_window_len,
            .compress => return error.NetworkError,
        };
        const window = try gpa.alloc(u8, window_len);
        defer gpa.free(window);
        var transfer_buffer: [64]u8 = undefined;
        var decompress: std.http.Decompress = undefined;
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, window);
        return reader.allocRemaining(gpa, .limited(limit)) catch |err| return httpError(err);
    }

    /// GETs `url` straight into `dir/sub_path`, replacing any existing file.
    pub fn getToFile(h: *Http, dir: Io.Dir, sub_path: []const u8, url: []const u8) Error!void {
        const io = h.client.io;
        const file = dir.createFile(io, sub_path, .{}) catch return error.FileSystemError;
        defer file.close(io);
        var buf: [64 << 10]u8 = undefined;
        var fw = file.writer(io, &buf);
        try h.get(url, &fw.interface);
        fw.interface.flush() catch return error.FileSystemError;
    }

    fn get(h: *Http, url: []const u8, w: *Io.Writer) Error!void {
        const res = h.client.fetch(.{
            .location = .{ .url = url },
            .response_writer = w,
            .headers = .{ .user_agent = .{ .override = h.user_agent } },
        }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.WriteFailed => return error.FileSystemError,
            else => return error.NetworkError,
        };
        if (res.status.class() != .success) return error.NetworkError;
    }
};

/// Fetches and decodes an index, following `extension_list_url` when the
/// repo splits its list out. `bytes_out` receives the buffers the store's
/// strings point into; free them after the store.
pub fn fetchIndex(h: *Http, arena: Allocator, url: []const u8) Error!Store {
    const bytes = try h.getAlloc(arena, url, max_index_len);
    var store = try parseIndex(arena, bytes);
    if (store.extensions.len == 0) if (store.extension_list_url) |list_url| {
        const list_bytes = try h.getAlloc(arena, list_url, max_index_len);
        store.extensions = try parseExtensionList(arena, list_bytes);
    };
    return store;
}

fn httpError(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.NetworkError,
    };
}

// ---- signature ---------------------------------------------------------------------

pub const Fingerprint = [std.crypto.hash.sha2.Sha256.digest_length]u8;

/// SHA-256 fingerprints of every certificate in the package's JAR signature
/// block (`META-INF/*.RSA|DSA|EC`), or an empty list for an unsigned file.
/// Both keiyoushi jars and APKs (v1 signature) carry one; Mihon compares the
/// same hash against the store's `signing_key`.
///
/// This identifies the signer; it does not verify the signature over every
/// entry (the JVM does that when it opens the jar with verification on).
pub fn signerFingerprints(gpa: Allocator, io: Io, path: []const u8) ![]Fingerprint {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [16 << 10]u8 = undefined;
    var reader = file.reader(io, &buf);

    var out: std.ArrayList(Fingerprint) = .empty;
    errdefer out.deinit(gpa);

    var it = try std.zip.Iterator.init(&reader);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try it.next()) |entry| {
        const name = try entry.getFilename(&reader, &name_buf, .{});
        if (!isSignatureBlock(name)) continue;
        var block: Io.Writer.Allocating = .init(gpa);
        defer block.deinit();
        try entry.extractTo(&reader, &block.writer);
        try certificateFingerprints(gpa, block.written(), &out);
    }
    return out.toOwnedSlice(gpa);
}

fn isSignatureBlock(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "META-INF/")) return false;
    if (std.mem.indexOfScalarPos(u8, name, "META-INF/".len, '/') != null) return false;
    inline for (.{ ".RSA", ".DSA", ".EC" }) |ext| if (std.mem.endsWith(u8, name, ext)) return true;
    return false;
}

/// Walks a PKCS#7 `SignedData` DER blob and hashes each embedded certificate.
///
/// ContentInfo ::= SEQUENCE { contentType OID, content [0] EXPLICIT SignedData }
/// SignedData  ::= SEQUENCE { version, digestAlgorithms SET, encapContentInfo SEQUENCE,
///                            certificates [0] IMPLICIT SET OF Certificate OPTIONAL, ... }
pub fn certificateFingerprints(gpa: Allocator, der: []const u8, out: *std.ArrayList(Fingerprint)) !void {
    const E = std.crypto.Certificate.der.Element;
    const content_info = try E.parse(der, 0);
    const content_type = try E.parse(der, content_info.slice.start);
    const explicit = try E.parse(der, content_type.slice.end);
    const signed_data = try E.parse(der, explicit.slice.start);
    const version = try E.parse(der, signed_data.slice.start);
    const digest_algorithms = try E.parse(der, version.slice.end);
    const encap = try E.parse(der, digest_algorithms.slice.end);
    const certs = try E.parse(der, encap.slice.end);
    if (certs.identifier.class != .context_specific or @backingInt(certs.identifier.tag) != 0) {
        return error.NoCertificates;
    }
    var i = certs.slice.start;
    while (i < certs.slice.end) {
        const cert = try E.parse(der, i);
        var fp: Fingerprint = undefined;
        std.crypto.hash.sha2.Sha256.hash(der[i..cert.slice.end], &fp, .{});
        try out.append(gpa, fp);
        i = cert.slice.end;
    }
}

/// Lower-case hex of a fingerprint, the form the index uses.
pub fn hex(fp: Fingerprint) [2 * fp.len]u8 {
    return std.fmt.bytesToHex(fp, .lower);
}

/// True when any fingerprint matches `signing_key` (hex, any case).
pub fn signedBy(fps: []const Fingerprint, signing_key: []const u8) bool {
    for (fps) |fp| if (std.ascii.eqlIgnoreCase(&hex(fp), signing_key)) return true;
    return false;
}

// ---- tests -----------------------------------------------------------------------------

const testing = std.testing;

/// Builds protobuf messages for tests.
const Pb = struct {
    buf: std.ArrayList(u8) = .empty,

    fn varint(p: *Pb, v: u64) !void {
        var x = v;
        while (x >= 0x80) : (x >>= 7) try p.buf.append(testing.allocator, @as(u8, @truncate(x)) | 0x80);
        try p.buf.append(testing.allocator, @truncate(x));
    }
    fn int(p: *Pb, num: u32, v: u64) !void {
        try p.varint(num << 3);
        try p.varint(v);
    }
    fn bytes(p: *Pb, num: u32, b: []const u8) !void {
        try p.varint(num << 3 | 2);
        try p.varint(b.len);
        try p.buf.appendSlice(testing.allocator, b);
    }
    fn deinit(p: *Pb) void {
        p.buf.deinit(testing.allocator);
    }
};

test "parseIndex decodes a store with one extension" {
    var src: Pb = .{};
    defer src.deinit();
    try src.int(1, 2131019126180322627);
    try src.bytes(2, "Weeb Central");
    try src.bytes(3, "en");
    try src.bytes(4, "https://weebcentral.com");

    var res: Pb = .{};
    defer res.deinit();
    try res.bytes(1, "https://x/apk/a.apk");
    try res.bytes(2, "https://x/icon/a.png");
    try res.bytes(501, "https://x/jar/a.jar");

    var ext: Pb = .{};
    defer ext.deinit();
    try ext.bytes(1, "Weeb Central");
    try ext.bytes(2, "eu.kanade.tachiyomi.extension.en.weebcentral");
    try ext.bytes(3, res.buf.items);
    try ext.bytes(4, "1.6");
    try ext.int(5, 106025);
    try ext.bytes(6, "1.6.25");
    try ext.int(7, 3);
    try ext.bytes(8, src.buf.items);

    var list: Pb = .{};
    defer list.deinit();
    try list.bytes(1, ext.buf.items);

    var store: Pb = .{};
    defer store.deinit();
    try store.bytes(1, "Keiyoushi");
    try store.bytes(2, "KEI");
    try store.bytes(3, "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2");
    try store.bytes(101, list.buf.items);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try parseIndex(arena.allocator(), store.buf.items);
    try testing.expectEqualStrings("Keiyoushi", s.name);
    try testing.expectEqual(1, s.extensions.len);
    const e = s.find("eu.kanade.tachiyomi.extension.en.weebcentral").?;
    try testing.expectEqualStrings("https://x/jar/a.jar", e.downloadUrl().?);
    try testing.expectEqual(106025, e.version_code);
    try testing.expect(e.nsfw());
    try testing.expectEqualStrings("en", e.lang());
    try testing.expectEqual(2131019126180322627, e.sources[0].id);
    try testing.expectEqualStrings("https://weebcentral.com", e.sources[0].base_url);
}

test "parseIndex rejects truncated input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // field 1, length-delimited, claims 10 bytes but only 2 follow
    try testing.expectError(error.InvalidIndex, parseIndex(arena.allocator(), &.{ 0x0a, 0x0a, 'a', 'b' }));
}

test "signature block names" {
    try testing.expect(isSignatureBlock("META-INF/CERT.RSA"));
    try testing.expect(isSignatureBlock("META-INF/KEY.EC"));
    try testing.expect(!isSignatureBlock("META-INF/CERT.SF"));
    try testing.expect(!isSignatureBlock("META-INF/sub/CERT.RSA"));
    try testing.expect(!isSignatureBlock("CERT.RSA"));
}

test "signedBy is case-insensitive" {
    const fp: Fingerprint = @splat(0xab);
    const upper: [64]u8 = @splat('A');
    var key = upper;
    for (&key, 0..) |*c, i| c.* = if (i % 2 == 0) 'A' else 'B';
    try testing.expect(signedBy(&.{fp}, &key));
    key[63] = 'C';
    try testing.expect(!signedBy(&.{fp}, &key));
}

test "certificateFingerprints hashes the keiyoushi signing certificate" {
    // META-INF/CERT.RSA from a keiyoushi jar; the store's signing_key is the SHA-256 of its certificate.
    const block = @embedFile("testdata/keiyoushi-cert.rsa");
    var fps: std.ArrayList(Fingerprint) = .empty;
    defer fps.deinit(testing.allocator);
    try certificateFingerprints(testing.allocator, block, &fps);
    try testing.expectEqual(1, fps.items.len);
    try testing.expect(signedBy(fps.items, "9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2"));
}

test "Decoder rejects overflowing varints and invalid field numbers" {
    const invalid = [_][]const u8{
        &.{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 2 },
        &.{0}, // field zero is never valid
        &.{ 0x80, 0x80, 0x80, 0x80, 0x10, 0 }, // field number exceeds 29 bits
        &.{ 0x0a, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 1 }, // length exceeds addressable input
    };
    for (invalid) |bytes| {
        var d: Decoder = .init(bytes);
        try testing.expectError(error.InvalidIndex, d.next());
    }
    var d: Decoder = .init(&.{ 8, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 1 });
    const field = (try d.next()).?;
    try testing.expectEqual(std.math.maxInt(u64), field.value.varint);
    try testing.expectEqual(-1, field.int());
    try testing.expectEqual(null, try d.next());
}

test "parseExtension preserves unknown content warnings within the backing type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ext = try parseExtension(arena.allocator(), &.{ 0x38, 0xff, 1 });
    try testing.expectEqual(@as(u8, 255), @backingInt(ext.content_warning));
    try testing.expect(!ext.nsfw());
    try testing.expectError(error.InvalidIndex, parseExtension(arena.allocator(), &.{ 0x38, 0x80, 2 }));
}

test "HTTP allocation limits apply to decoded bodies and preserve redirects" {
    const Fixture = @import("testing_http.zig").Fixture;
    const gzip = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\x4b\x4c\x4a\x06\x00\xc2\x41\x24\x35\x03\x00\x00\x00";
    const cases = .{
        .{ "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc", 3, "abc" },
        .{ "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc", 2, null },
        .{ "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n", 0, "" },
        .{ "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\na", 0, null },
        .{ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n", 2, null },
        .{ "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 23\r\n\r\n" ++ gzip, 3, "abc" },
        .{ "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 23\r\n\r\n" ++ gzip, 2, null },
        .{ "HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\n\r\nabc", 3, null },
    };
    inline for (cases) |case| {
        var fixture = try Fixture.init(&.{case[0]});
        defer fixture.deinit();
        try fixture.start();
        var http = Http.init(testing.allocator, testing.io);
        defer http.deinit();
        const url = try fixture.url(testing.allocator, "/");
        defer testing.allocator.free(url);
        if (@as(?[]const u8, case[2])) |expected| {
            const body = try http.getAlloc(testing.allocator, url, case[1]);
            defer testing.allocator.free(body);
            try testing.expectEqualStrings(expected, body);
        } else {
            try testing.expectError(error.NetworkError, http.getAlloc(testing.allocator, url, case[1]));
        }
        try fixture.finish();
    }
    var fixture = try Fixture.init(&.{
        "HTTP/1.1 302 Found\r\nLocation: /final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc",
    });
    defer fixture.deinit();
    try fixture.start();
    var http = Http.init(testing.allocator, testing.io);
    defer http.deinit();
    const url = try fixture.url(testing.allocator, "/redirect");
    defer testing.allocator.free(url);
    const body = try http.getAlloc(testing.allocator, url, 3);
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("abc", body);
    try fixture.finish();
}

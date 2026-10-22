//! Repository formats and signature metadata decoded from caller-owned bytes.
//! Network acquisition, package files and persistence belong to the integrator.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const default_index_url = "https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.pb";

/// Maximum decoded index size accepted by the codecs.
pub const max_index_len = 64 << 20;

pub const Error = error{ InvalidIndex, OutOfMemory };

pub const ContentWarning = enum(u8) { unspecified = 0, safe = 1, mixed = 2, nsfw = 3, _ };

pub const Source = struct {
    id: i64,
    name: []const u8 = "",
    lang: []const u8 = "",
    base_url: []const u8 = "",
    mirror_urls: []const []const u8 = &.{},
    message: ?[]const u8 = null,
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
        if (e.sources.len == 0) return "all";
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
    index_url: []const u8 = "",
    legacy: bool = false,
    name: []const u8 = "",
    badge: []const u8 = "",
    /// SHA-256 of the signing certificate, lower-case hex, as Mihon stores it.
    signing_key: []const u8 = "",
    website: []const u8 = "",
    discord: ?[]const u8 = null,
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
    input: Io.Reader,

    fn init(bytes: []const u8) Decoder {
        return .{ .input = .fixed(bytes) };
    }

    fn varint(d: *Decoder) Error!u64 {
        const remaining = d.input.buffered();
        var input: Io.Reader = .fixed(remaining[0..@min(10, remaining.len)]);
        defer d.input.toss(input.seek);
        return input.takeLeb128(u64) catch return error.InvalidIndex;
    }

    fn take(d: *Decoder, n: usize) Error![]const u8 {
        if (n > d.input.bufferedLen()) return error.InvalidIndex;
        return d.input.take(n) catch return error.InvalidIndex;
    }

    fn next(d: *Decoder) Error!?Field {
        if (d.input.bufferedLen() == 0) return null;
        const key = try d.varint();
        const num = std.math.cast(u29, key >> 3) orelse return error.InvalidIndex;
        if (num == 0) return error.InvalidIndex;
        return .{
            .num = num,
            .value = switch (@as(u3, @truncate(key))) {
                0 => .{ .varint = try d.varint() },
                1 => .{ .fixed64 = d.input.takeInt(u64, .little) catch return error.InvalidIndex },
                2 => .{ .bytes = try d.take(std.math.cast(usize, try d.varint()) orelse return error.InvalidIndex) },
                5 => .{ .fixed32 = d.input.takeInt(u32, .little) catch return error.InvalidIndex },
                else => return error.InvalidIndex, // groups (3/4) never appear in this format
            },
        };
    }
};

/// Decodes a modern JSON or protobuf index, optionally gzipped. All slices point into
/// `arena` allocations or into `bytes` (strings are not copied), so keep
/// `bytes` alive as long as the `Store`.
pub fn parseIndex(arena: Allocator, bytes: []const u8) Error!Store {
    const raw = if (isGzip(bytes)) try gunzip(arena, bytes) else bytes;
    if (raw.len == 0) return error.InvalidIndex;
    if (raw[0] == '{') return (try jsonDecode(JsonStore, arena, raw)).store(arena);
    var store: Store = .{};
    var exts: std.ArrayList(Extension) = .empty;
    var d: Decoder = .init(raw);
    while (try d.next()) |f| switch (f.num) {
        1 => store.name = f.str(),
        2 => store.badge = f.str(),
        3 => store.signing_key = f.str(),
        4 => {
            var c: Decoder = .init(f.str());
            while (try c.next()) |cf| switch (cf.num) {
                1 => store.website = cf.str(),
                2 => store.discord = cf.str(),
                else => {},
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
    if (raw.len == 0) return error.InvalidIndex;
    if (raw[0] == '{') return (try jsonDecode(JsonList, arena, raw)).extensionsInto(arena);
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
            var mirrors: std.ArrayList([]const u8) = .empty;
            var sd: Decoder = .init(f.str());
            while (try sd.next()) |sf| switch (sf.num) {
                1 => s.id = sf.int(),
                2 => s.name = sf.str(),
                3 => s.lang = sf.str(),
                4 => s.base_url = sf.str(),
                5 => try mirrors.append(arena, sf.str()),
                7 => s.message = sf.str(),
                else => {},
            };
            s.mirror_urls = mirrors.items;
            try sources.append(arena, s);
        },
        else => {},
    };
    e.sources = sources.items;
    return e;
}

// ---- JSON formats --------------------------------------------------------------

fn jsonDecode(comptime T: type, arena: Allocator, bytes: []const u8) Error!T {
    return std.json.parseFromSliceLeaky(T, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidIndex,
    };
}

const JsonSource = struct {
    id: i64,
    name: []const u8,
    language: []const u8,
    homeUrl: []const u8 = "",
    mirrorUrls: []const []const u8 = &.{},
    message: ?[]const u8 = null,
};

const JsonExtension = struct {
    name: []const u8,
    packageName: []const u8,
    resources: struct { apkUrl: []const u8, iconUrl: []const u8, jarUrl: ?[]const u8 = null },
    extensionLib: []const u8,
    versionCode: i64,
    versionName: []const u8,
    contentWarning: []const u8,
    sources: []const JsonSource,

    fn extension(e: JsonExtension, arena: Allocator) Error!Extension {
        const warning = std.mem.startsWith(u8, e.contentWarning, "CONTENT_WARNING_");
        const name = if (warning) e.contentWarning["CONTENT_WARNING_".len..] else e.contentWarning;
        const cw: ContentWarning = if (std.mem.eql(u8, name, "SAFE") or std.mem.eql(u8, name, "UNSPECIFIED")) .safe else if (std.mem.eql(u8, name, "MIXED")) .mixed else if (std.mem.eql(u8, name, "NSFW")) .nsfw else return error.InvalidIndex;
        const sources = try arena.alloc(Source, e.sources.len);
        for (sources, e.sources) |*dst, src| dst.* = .{ .id = src.id, .name = src.name, .lang = src.language, .base_url = src.homeUrl, .mirror_urls = src.mirrorUrls, .message = src.message };
        return .{ .name = e.name, .pkg = e.packageName, .apk_url = e.resources.apkUrl, .icon_url = e.resources.iconUrl, .jar_url = e.resources.jarUrl, .lib_version = e.extensionLib, .version_code = e.versionCode, .version_name = e.versionName, .content_warning = cw, .sources = sources };
    }
};

const JsonList = struct {
    extensions: []const JsonExtension,

    fn extensionsInto(list: JsonList, arena: Allocator) Error![]const Extension {
        const extensions = try arena.alloc(Extension, list.extensions.len);
        for (extensions, list.extensions) |*dst, e| dst.* = try e.extension(arena);
        return extensions;
    }
};

const JsonStore = struct {
    name: []const u8,
    badgeLabel: []const u8,
    signingKey: []const u8,
    contact: struct { website: []const u8, discord: ?[]const u8 = null },
    extensionList: ?JsonList = null,
    extensionListUrl: ?[]const u8 = null,

    fn store(s: JsonStore, arena: Allocator) Error!Store {
        return .{ .name = s.name, .badge = s.badgeLabel, .signing_key = s.signingKey, .website = s.contact.website, .discord = s.contact.discord, .extension_list_url = s.extensionListUrl, .extensions = if (s.extensionList) |list| try list.extensionsInto(arena) else &.{} };
    }
};

pub const LegacyRepo = struct {
    index_v2: ?[]const u8 = null,
    meta: struct { name: []const u8, shortName: ?[]const u8 = null, website: []const u8, signingKeyFingerprint: []const u8 },
};

const LegacyExtension = struct {
    name: []const u8,
    pkg: []const u8,
    apk: []const u8,
    lang: []const u8,
    code: i64,
    version: []const u8,
    nsfw: i32,
    sources: ?[]const struct { id: i64, lang: []const u8, name: []const u8, baseUrl: []const u8 } = null,
};

pub fn parseLegacyList(arena: Allocator, bytes: []const u8, base: []const u8) Error![]const Extension {
    const raw = if (isGzip(bytes)) try gunzip(arena, bytes) else bytes;
    const list = try jsonDecode([]const LegacyExtension, arena, raw);
    const extensions = try arena.alloc(Extension, list.len);
    for (extensions, list) |*dst, e| {
        const sources = try arena.alloc(Source, if (e.sources) |ss| @max(1, ss.len) else 1);
        if (e.sources != null and e.sources.?.len > 0) {
            for (sources, e.sources.?) |*out, src| out.* = .{ .id = src.id, .name = src.name, .lang = src.lang, .base_url = src.baseUrl };
        } else sources[0] = .{ .id = 0, .name = e.name, .lang = e.lang };
        dst.* = .{
            // Kotlin's substringAfter: from the first "Tachiyomi: " anywhere.
            .name = if (std.mem.indexOf(u8, e.name, "Tachiyomi: ")) |at| e.name[at + "Tachiyomi: ".len ..] else e.name,
            .pkg = e.pkg,
            .apk_url = try std.fmt.allocPrint(arena, "{s}/apk/{s}", .{ base, e.apk }),
            .icon_url = try std.fmt.allocPrint(arena, "{s}/icon/{s}.png", .{ base, e.pkg }),
            .lib_version = e.version[0 .. std.mem.lastIndexOfScalar(u8, e.version, '.') orelse e.version.len],
            .version_code = e.code,
            .version_name = e.version,
            .content_warning = if (e.nsfw == 1) .nsfw else .safe,
            .sources = sources,
        };
    }
    return extensions;
}

pub fn isGzip(bytes: []const u8) bool {
    return bytes.len >= 2 and bytes[0] == 0x1f and bytes[1] == 0x8b;
}

pub fn gunzip(gpa: Allocator, bytes: []const u8) Error![]u8 {
    var in: Io.Reader = .fixed(bytes);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var d: std.compress.flate.Decompress = .init(&in, .gzip, window);
    return d.reader.allocRemaining(gpa, .limited(max_index_len)) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidIndex,
    };
}

pub fn parseLegacyRepo(arena: Allocator, bytes: []const u8) Error!LegacyRepo {
    return jsonDecode(LegacyRepo, arena, bytes);
}

pub const Fingerprint = [std.crypto.hash.sha2.Sha256.digest_length]u8;

pub fn isSignatureBlock(name: []const u8) bool {
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
    try src.bytes(5, "https://mirror-one.example");
    try src.bytes(5, "https://mirror-two.example");
    try src.bytes(5, "https://mirror-one.example");

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
    try testing.expectEqual(3, e.sources[0].mirror_urls.len);
    try testing.expectEqualStrings("https://mirror-one.example", e.sources[0].mirror_urls[0]);
    try testing.expectEqualStrings("https://mirror-two.example", e.sources[0].mirror_urls[1]);
    try testing.expectEqualStrings("https://mirror-one.example", e.sources[0].mirror_urls[2]);
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

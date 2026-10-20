//! Chapter numbers recognized from chapter names, as Mihon does it
//! (`ChapterRecognition`, mihonapp/mihon 487c313). Each name is read on its
//! own: the volume or season is taken out, a part becomes a sub-chapter
//! letter, and the number is the one after "ch." or else the first one left.
//! Reading the whole list then fills in what single names don't tell.
//!
//! Mihon matches with Java regexes; the patterns are hand-written here with
//! the same ASCII `\b`, `\w` and `\s` semantics and the same backtracking
//! order, and Mihon's own test cases are below.
const std = @import("std");

/// A recognized volume and chapter number, as Mihon formats them, e.g.
/// "10.5" or "19a"; null when there is none.
pub const Numbering = struct {
    volume: ?[]const u8,
    chapter: ?[]const u8,
};

const Recognized = struct {
    value: f64,
    letter: ?u8 = null,

    fn format(self: Recognized, arena: std.mem.Allocator) ![]const u8 {
        var buf: [64]u8 = undefined;
        const number = formatNumber(&buf, self.value);
        return if (self.letter) |l| std.fmt.allocPrint(arena, "{s}{c}", .{ number, l }) else arena.dupe(u8, number);
    }
};

/// Java's `DecimalFormat("#.###")`: no trailing zeros, at most three decimals.
fn formatNumber(buf: []u8, value: f64) []const u8 {
    const scaled = roundHalfEven(value * 1000);
    const negative = scaled < 0;
    const magnitude: u64 = @intFromFloat(@abs(scaled));
    const whole = magnitude / 1000;
    var fraction = magnitude % 1000;
    var w: std.Io.Writer = .fixed(buf);
    if (negative and magnitude != 0) w.writeByte('-') catch unreachable;
    w.print("{d}", .{whole}) catch unreachable;
    if (fraction != 0) {
        var digits: usize = 3;
        while (fraction % 10 == 0) : (digits -= 1) fraction /= 10;
        w.print(".{d:0>[1]}", .{ fraction, digits }) catch unreachable;
    }
    return w.buffered();
}

/// Kotlin's `round`: halves go to the even neighbour.
fn roundHalfEven(x: f64) f64 {
    const floor = @floor(x);
    const diff = x - floor;
    if (diff < 0.5) return floor;
    if (diff > 0.5) return floor + 1;
    return if (@mod(floor, 2) == 0) floor else floor + 1;
}

/// A number of a `Numbering` as a double. A letter only counts without
/// decimals, from .1 for a up to .9 for i: 19a is 19.1, 1.5a is 1.5.
pub fn toDouble(number: []const u8) f64 {
    if (number.len == 0) return -1;
    const last = number[number.len - 1];
    const letter: ?u8 = if (std.ascii.isAlphabetic(last)) last else null;
    const digits = if (letter != null) number[0 .. number.len - 1] else number;
    const value = std.fmt.parseFloat(f64, digits) catch return -1;
    if (letter) |l| {
        const tenths = @as(i32, l) - 'a' + 1;
        if (tenths >= 1 and tenths < 10 and std.mem.indexOfScalar(u8, number, '.') == null) return value + @as(f64, @floatFromInt(tenths)) / 10.0;
    }
    return value;
}

/// Whether a source gave a number: -1 and below mean it didn't, except -2,
/// which some sources use on purpose.
pub fn isKnown(number: f64) bool {
    return number == -2.0 or number > -1.0;
}

// ---- matching -------------------------------------------------------------------

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}
fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}
fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0b or c == 0x0c or c == '\r';
}
/// Java's `\b`: between a word character and anything else.
fn boundary(s: []const u8, i: usize) bool {
    const before = i > 0 and isWord(s[i - 1]);
    const after = i < s.len and isWord(s[i]);
    return before != after;
}
fn digitsEnd(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
    return j;
}
fn lowerEnd(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and isLower(s[j])) j += 1;
    return j;
}

const Range = struct { start: usize, end: usize };

/// `([0-9]+)(\.[0-9]+)?(\.?[a-z]+)?` at `i`.
const NumberMatch = struct {
    start: usize,
    end: usize,
    whole: []const u8,
    /// With its dot, or empty.
    decimal: []const u8,
    /// With its dot if any, or empty.
    alpha: []const u8,

    fn recognized(self: NumberMatch) Recognized {
        const whole = std.fmt.parseFloat(f64, self.whole) catch 0;
        const decimal = if (self.decimal.len > 0) std.fmt.parseFloat(f64, self.decimal) catch 0 else 0;
        const value = whole + decimal;
        if (self.decimal.len == 0) {
            if (std.mem.indexOf(u8, self.alpha, "extra") != null) return .{ .value = value + 0.99 };
            if (std.mem.indexOf(u8, self.alpha, "omake") != null) return .{ .value = value + 0.98 };
            if (std.mem.indexOf(u8, self.alpha, "special") != null) return .{ .value = value + 0.97 };
        }
        // Only up to i, like the decimals they stood for; others are words like 5v2.
        const letters = std.mem.trimStart(u8, self.alpha, ".");
        const letter: ?u8 = if (letters.len == 1 and letters[0] >= 'a' and letters[0] <= 'i') letters[0] else null;
        return .{ .value = value, .letter = letter };
    }
};

fn numberAt(s: []const u8, i: usize) ?NumberMatch {
    const whole_end = digitsEnd(s, i);
    if (whole_end == i) return null;
    var end = whole_end;
    var decimal: []const u8 = "";
    if (end + 1 < s.len and s[end] == '.' and std.ascii.isDigit(s[end + 1])) {
        const decimal_end = digitsEnd(s, end + 1);
        decimal = s[end..decimal_end];
        end = decimal_end;
    }
    var alpha: []const u8 = "";
    if (end + 1 < s.len and s[end] == '.' and isLower(s[end + 1])) {
        const alpha_end = lowerEnd(s, end + 1);
        alpha = s[end..alpha_end];
        end = alpha_end;
    } else if (end < s.len and isLower(s[end])) {
        const alpha_end = lowerEnd(s, end);
        alpha = s[end..alpha_end];
        end = alpha_end;
    }
    return .{ .start = i, .end = end, .whole = s[i..whole_end], .decimal = decimal, .alpha = alpha };
}

fn findNumber(s: []const u8) ?NumberMatch {
    for (0..s.len) |i| if (numberAt(s, i)) |m| return m;
    return null;
}

fn countNumbers(s: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (numberAt(s, i)) |m| {
            count += 1;
            i = m.end;
        } else i += 1;
    }
    return count;
}

/// `(?<=ch\.) *NUMBER`
fn findBasic(s: []const u8) ?NumberMatch {
    var p: usize = 3;
    while (p <= s.len) : (p += 1) {
        if (!std.mem.eql(u8, s[p - 3 .. p], "ch.")) continue;
        var q = p;
        while (q < s.len and s[q] == ' ') q += 1;
        if (numberAt(s, q)) |m| return m;
    }
    return null;
}

/// `\b(?:ver|version)[^a-z]?[0-9]+`
fn unwantedAt(s: []const u8, i: usize) ?usize {
    if (!boundary(s, i)) return null;
    for ([_][]const u8{ "ver", "version" }) |tag| {
        if (!std.mem.startsWith(u8, s[i..], tag)) continue;
        const p = i + tag.len;
        if (p < s.len and !isLower(s[p])) {
            const e = digitsEnd(s, p + 1);
            if (e > p + 1) return e;
        }
        const e = digitsEnd(s, p);
        if (e > p) return e;
    }
    return null;
}

/// `([0-9]+(?:\.[0-9]+)?)\b` at `q`: the end of the group.
fn volumeNumberAt(s: []const u8, q: usize) ?usize {
    const d = digitsEnd(s, q);
    if (d == q) return null;
    if (d + 1 < s.len and s[d] == '.' and std.ascii.isDigit(s[d + 1])) {
        const e = digitsEnd(s, d + 1);
        if (boundary(s, e)) return e;
    }
    return if (boundary(s, d)) d else null;
}

const VolumeMatch = struct { start: usize, end: usize, number: []const u8 };

/// `\b(?:(?:vol(?:ume)?|season)[^a-z0-9]? *|[vs]\.?)([0-9]+(?:\.[0-9]+)?)\b`
fn volumeAt(s: []const u8, i: usize) ?VolumeMatch {
    if (!boundary(s, i)) return null;
    for ([_][]const u8{ "volume", "vol", "season" }) |word| {
        if (!std.mem.startsWith(u8, s[i..], word)) continue;
        const p = i + word.len;
        for ([_]bool{ true, false }) |consume| {
            var q = p;
            if (consume) {
                if (q < s.len and !isLower(s[q]) and !std.ascii.isDigit(s[q])) q += 1 else continue;
            }
            while (q < s.len and s[q] == ' ') q += 1;
            if (volumeNumberAt(s, q)) |e| return .{ .start = i, .end = e, .number = s[q..e] };
        }
    }
    if (i < s.len and (s[i] == 'v' or s[i] == 's')) {
        for ([_]bool{ true, false }) |dot| {
            var q = i + 1;
            if (dot) {
                if (q < s.len and s[q] == '.') q += 1 else continue;
            }
            if (volumeNumberAt(s, q)) |e| return .{ .start = i, .end = e, .number = s[q..e] };
        }
    }
    return null;
}

fn findVolume(s: []const u8) ?VolumeMatch {
    for (0..s.len) |i| if (volumeAt(s, i)) |m| return m;
    return null;
}

const PartMatch = struct { start: usize, end: usize, number: []const u8 };

/// `\bpart\.? *([0-9]+|i{1,3}|iv|vi{0,3}|ix|x)\b`
fn partAt(s: []const u8, i: usize) ?PartMatch {
    if (!boundary(s, i) or !std.mem.startsWith(u8, s[i..], "part")) return null;
    for ([_]bool{ true, false }) |dot| {
        var q = i + 4;
        if (dot) {
            if (q < s.len and s[q] == '.') q += 1 else continue;
        }
        while (q < s.len and s[q] == ' ') q += 1;
        if (partNumberAt(s, q)) |e| return .{ .start = i, .end = e, .number = s[q..e] };
    }
    return null;
}

fn partNumberAt(s: []const u8, q: usize) ?usize {
    const d = digitsEnd(s, q);
    if (d > q and boundary(s, d)) return d;
    // i{1,3}, greedy
    var n: usize = 3;
    while (n >= 1) : (n -= 1) {
        if (q + n <= s.len and allChar(s[q .. q + n], 'i') and boundary(s, q + n)) return q + n;
    }
    if (std.mem.startsWith(u8, s[q..], "iv") and boundary(s, q + 2)) return q + 2;
    if (q < s.len and s[q] == 'v') {
        // vi{0,3}, greedy
        var m: usize = 4;
        while (m > 0) {
            m -= 1;
            if (q + 1 + m <= s.len and allChar(s[q + 1 .. q + 1 + m], 'i') and boundary(s, q + 1 + m)) return q + 1 + m;
        }
    }
    if (std.mem.startsWith(u8, s[q..], "ix") and boundary(s, q + 2)) return q + 2;
    if (q < s.len and s[q] == 'x' and boundary(s, q + 1)) return q + 1;
    return null;
}

fn allChar(s: []const u8, c: u8) bool {
    for (s) |x| if (x != c) return false;
    return true;
}

fn findPart(s: []const u8) ?PartMatch {
    for (0..s.len) |i| if (partAt(s, i)) |m| return m;
    return null;
}

const roman = [_][]const u8{ "i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x" };

fn parsePart(part: []const u8) i64 {
    if (std.fmt.parseInt(i64, part, 10)) |n| return n else |_| {}
    for (roman, 1..) |r, n| if (std.mem.eql(u8, r, part)) return @intCast(n);
    return 0;
}

/// `[0-9]+(?:\.[0-9]+)?`
fn anyNumberAt(s: []const u8, i: usize) ?Range {
    const d = digitsEnd(s, i);
    if (d == i) return null;
    if (d + 1 < s.len and s[d] == '.' and std.ascii.isDigit(s[d + 1])) return .{ .start = i, .end = digitsEnd(s, d + 1) };
    return .{ .start = i, .end = d };
}

fn allAnyNumbers(arena: std.mem.Allocator, s: []const u8) ![]Range {
    var list: std.ArrayList(Range) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (anyNumberAt(s, i)) |m| {
            try list.append(arena, m);
            i = m.end;
        } else i += 1;
    }
    return list.items;
}

/// `(?:\b(?:ch|chap|chapter|ep|episode)\.? *|#)$` anywhere in `s`.
fn endsWithChapterPrefix(s: []const u8) bool {
    if (std.mem.endsWith(u8, s, "#")) return true;
    var t = std.mem.trimEnd(u8, s, " ");
    if (std.mem.endsWith(u8, t, ".")) t = t[0 .. t.len - 1];
    for ([_][]const u8{ "ch", "chap", "chapter", "ep", "episode" }) |word| {
        if (std.mem.endsWith(u8, t, word) and boundary(t, t.len - word.len)) return true;
    }
    return false;
}

/// `\b(?:extra|bonus|omake|special|side ?story|afterword|interlude)`
fn isBonus(s: []const u8) bool {
    for (0..s.len) |i| {
        if (!boundary(s, i)) continue;
        for ([_][]const u8{ "extra", "bonus", "omake", "special", "side story", "sidestory", "afterword", "interlude" }) |word| {
            if (std.mem.startsWith(u8, s[i..], word)) return true;
        }
    }
    return false;
}

/// `\b(?:prologue|one.?shot|pilot)\b`
fn isPrologue(s: []const u8) bool {
    for (0..s.len) |i| {
        if (!boundary(s, i)) continue;
        for ([_][]const u8{ "prologue", "pilot" }) |word| {
            if (std.mem.startsWith(u8, s[i..], word) and boundary(s, i + word.len)) return true;
        }
        if (std.mem.startsWith(u8, s[i..], "one")) {
            const p = i + 3;
            if (p < s.len and s[p] != '\n' and std.mem.startsWith(u8, s[p + 1 ..], "shot") and boundary(s, p + 5)) return true;
            if (std.mem.startsWith(u8, s[p..], "shot") and boundary(s, p + 4)) return true;
        }
    }
    return false;
}

// ---- recognition ----------------------------------------------------------------

/// The chapter name in lower case with every occurrence of the title removed.
fn cleanName(arena: std.mem.Allocator, title: []const u8, name: []const u8) ![]const u8 {
    const lower_name = try std.ascii.allocLowerString(arena, name);
    if (title.len == 0) return lower_name;
    const lower_title = try std.ascii.allocLowerString(arena, title);
    return std.mem.replaceOwned(u8, arena, lower_name, lower_title, "");
}

/// Replaces each range with a space, from the last so earlier ones stay put.
fn replaceRanges(arena: std.mem.Allocator, s: []const u8, ranges: []const Range) ![]const u8 {
    const sorted = try arena.dupe(Range, ranges);
    std.mem.sort(Range, sorted, {}, struct {
        fn desc(_: void, a: Range, b: Range) bool {
            return a.start > b.start;
        }
    }.desc);
    var out = s;
    for (sorted) |r| out = try std.mem.concat(arena, u8, &.{ out[0..r.start], " ", out[r.end..] });
    return out;
}

fn replaceVolumes(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (volumeAt(s, i)) |m| {
            try out.append(arena, ' ');
            i = m.end;
        } else {
            try out.append(arena, s[i]);
            i += 1;
        }
    }
    return out.items;
}

fn removeUnwanted(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (unwantedAt(s, i)) |end| {
            i = end;
        } else {
            try out.append(arena, s[i]);
            i += 1;
        }
    }
    return out.items;
}

/// The number after "ch." or else the first one, leaving out version tags
/// when there are several.
fn parseNumber(arena: std.mem.Allocator, name: []const u8) !?Recognized {
    const trimmed = std.mem.trim(u8, name, " \t\n\r\x0b\x0c");
    var clean: std.ArrayList(u8) = .empty;
    // Some sources write decimals and letters with these, e.g. 300,a and 122-a.
    for (trimmed, 0..) |c, i| {
        const d: u8 = if (c == ',' or c == '-') '.' else c;
        if (isSpace(d)) {
            const rest = trimmed[i + 1 ..];
            if (std.mem.startsWith(u8, rest, "extra") or std.mem.startsWith(u8, rest, "special") or std.mem.startsWith(u8, rest, "omake")) continue;
        }
        try clean.append(arena, d);
    }
    const s = clean.items;
    if (countNumbers(s) > 1) {
        const without_tags = try removeUnwanted(arena, s);
        if (findBasic(without_tags) orelse findNumber(without_tags)) |m| return m.recognized();
    }
    return if (findNumber(s)) |m| m.recognized() else null;
}

/// The chapter number in `name`, a lower-case chapter name without the
/// title. A part after the number becomes its letter: Chapter 1.5 Part I is 1.5a.
fn parseName(arena: std.mem.Allocator, name: []const u8) !?Recognized {
    // The volume can't also be the chapter number.
    const without_volume = try replaceVolumes(arena, name);
    if (findPart(without_volume)) |part| {
        const n = parsePart(part.number);
        if (n >= 1 and n <= 26) {
            const letter: u8 = @intCast('a' + n - 1);
            const rest = try std.mem.concat(arena, u8, &.{ without_volume[0..part.start], without_volume[part.end..] });
            if (try parseNumber(arena, rest)) |number| {
                // A letter written in the number is what the source numbers by.
                return if (number.letter == null) .{ .value = number.value, .letter = letter } else number;
            }
        }
    }
    // Without another number, e.g. "Part 3", the part is the chapter number.
    return parseNumber(arena, without_volume);
}

/// Recognizes the chapter number of a single chapter, keeping `number` when
/// the source gave one; -1 when there is none.
pub fn parseChapterNumber(arena: std.mem.Allocator, manga_title: []const u8, chapter_name: []const u8, number: f64) !f64 {
    if (isKnown(number)) return number;
    const recognized = try parseName(arena, try cleanName(arena, manga_title, chapter_name)) orelse return number;
    return toDouble(try recognized.format(arena));
}

pub const Input = struct {
    name: []const u8,
    /// The source's number; -1 if it gave none.
    number: f64 = -1,
};

/// Recognizes the numbers of `chapters`, listed from the most to the least
/// recent, using the whole list for what a name alone doesn't tell: numbers
/// every similar name shares aren't the chapter number, and chapters without
/// a number are numbered after the chapters around them. Source numbers stay.
pub fn parseChapterNumbers(arena: std.mem.Allocator, manga_title: []const u8, chapters: []const Input) ![]Numbering {
    const n = chapters.len;
    const names = try arena.alloc([]const u8, n);
    for (chapters, names) |ch, *name| name.* = try cleanName(arena, manga_title, ch.name);
    // Taken out first, so a number like the 2 in "Group 2 Chapter 386" can't be picked.
    const shared = try findSharedNumbers(arena, names, chapters);
    const numbers = try arena.alloc(?Recognized, n);
    for (numbers, 0..) |*number, i| {
        number.* = if (isKnown(chapters[i].number)) .{ .value = chapters[i].number } else try parseName(arena, try replaceRanges(arena, names[i], shared[i]));
    }
    // Only from the name: newer chapters may not be in a volume yet.
    const volumes = try arena.alloc(?f64, n);
    for (volumes, names) |*volume, name| volume.* = if (findVolume(name)) |m| std.fmt.parseFloat(f64, m.number) catch null else null;
    fillChapterNumbers(names, numbers, volumes);
    const out = try arena.alloc(Numbering, n);
    for (out, numbers, volumes) |*o, number, volume| {
        var buf: [64]u8 = undefined;
        o.* = .{
            .volume = if (volume) |v| try arena.dupe(u8, formatNumber(&buf, v)) else null,
            .chapter = if (number) |r| try r.format(arena) else null,
        };
    }
    return out;
}

/// Numbers that are the same in every name of a group of at least three
/// names differing only in their numbers, e.g. the 2 in "Group 2 Chapter 385".
fn findSharedNumbers(arena: std.mem.Allocator, names: []const []const u8, chapters: []const Input) ![][]const Range {
    const matches = try arena.alloc([]Range, names.len);
    for (names, matches) |name, *m| m.* = try allAnyNumbers(arena, name);
    const shared = try arena.alloc([]const Range, names.len);
    @memset(shared, &.{});
    var groups: std.StringArrayHashMapUnmanaged(std.ArrayList(usize)) = .empty;
    for (names, 0..) |name, i| {
        if (isKnown(chapters[i].number)) continue;
        // Grouped by all but their numbers, so the nth number means the same thing.
        var key: std.ArrayList(u8) = .empty;
        var at: usize = 0;
        for (matches[i]) |r| {
            try key.appendSlice(arena, name[at..r.start]);
            try key.append(arena, '#');
            at = r.end;
        }
        try key.appendSlice(arena, name[at..]);
        const entry = try groups.getOrPut(arena, key.items);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(arena, i);
    }
    for (groups.values()) |group| {
        // Fewer names could share a number by chance.
        if (group.items.len < 3) continue;
        const first_index = group.items[0];
        const first = matches[first_index];
        var shared_slots: std.ArrayList(usize) = .empty;
        var other_slots: usize = 0;
        for (first, 0..) |r, slot| {
            const value = names[first_index][r.start..r.end];
            const same = for (group.items) |member| {
                const m = matches[member][slot];
                if (!std.mem.eql(u8, names[member][m.start..m.end], value)) break false;
            } else true;
            if (same) try shared_slots.append(arena, slot) else other_slots += 1;
        }
        // Something has to be left to tell the chapters apart.
        if (other_slots == 0) continue;
        // Parts of a chapter share its number, e.g. "Chapter 5 Part 1" and "Part 2".
        var removable: std.ArrayList(usize) = .empty;
        for (shared_slots.items) |slot| {
            if (!endsWithChapterPrefix(names[first_index][0..first[slot].start])) try removable.append(arena, slot);
        }
        for (group.items) |member| {
            const ranges = try arena.alloc(Range, removable.items.len);
            for (removable.items, ranges) |slot, *r| r.* = matches[member][slot];
            shared[member] = ranges;
        }
    }
    return shared;
}

/// Numbers runs of chapters without a number after the chapters around them,
/// only within a volume, since numbers may start over in the next one.
fn fillChapterNumbers(names: []const []const u8, numbers: []?Recognized, volumes: []?f64) void {
    var start: usize = 0;
    while (start < numbers.len) {
        if (numbers[start] != null) {
            start += 1;
            continue;
        }
        var end = start;
        while (end < numbers.len and numbers[end] == null) end += 1;
        fillRun(names, numbers, volumes, start, end);
        start = end;
    }
}

fn fillRun(names: []const []const u8, numbers: []?Recognized, volumes: []?f64, first: usize, end: usize) void {
    const last = end - 1;
    const count = end - first;
    // A -2 from the source says nothing about where a chapter is.
    const newer: ?Recognized = if (first > 0) if (numbers[first - 1]) |r| (if (r.value >= 0) r else null) else null else null;
    const older: ?Recognized = if (end < numbers.len) if (numbers[end]) |r| (if (r.value >= 0) r else null) else null else null;
    const older_volume: ?f64 = if (end < volumes.len) volumes[end] else null;
    var bonuses: usize = 0;
    for (first..end) |i| {
        if (isBonus(names[i])) bonuses += 1;
    }
    if (newer != null and older != null) {
        const nv = newer.?;
        const ov = older.?;
        const same_volume = eqlVolume(volumes[first - 1], older_volume) and withinVolume(volumes, first, end, older_volume);
        // Out of order chapters tell nothing about the ones between them.
        if (nv.value <= ov.value or !same_volume) return;
        const whole = nv.letter == null and ov.letter == null and @mod(nv.value, 1.0) == 0 and @mod(ov.value, 1.0) == 0;
        // Bonus chapters aren't missing chapters even when they would fit.
        if (bonuses == 0 and whole and nv.value - ov.value - 1 == @as(f64, @floatFromInt(count))) {
            for (first..end) |i| numbers[i] = .{ .value = ov.value + @as(f64, @floatFromInt(last + 1 - i)) };
        } else {
            // Never past the next whole number, which may still be a chapter to come.
            fillBetween(numbers, first, end, ov.value, @min(nv.value, @floor(ov.value) + 1));
        }
    } else if (older) |ov| {
        // Newer chapters without a number may as well be announcements.
        if (bonuses < count or !withinVolume(volumes, first, end, older_volume)) return;
        fillBetween(numbers, first, end, ov.value, @floor(ov.value) + 1);
    } else if (newer) |nv| {
        // When the first chapter is already 0, that's the prologue.
        if (nv.value <= 0) return;
        for (first..end) |i| {
            if (!isPrologue(names[i])) continue;
            numbers[i] = .{ .value = 0 };
            if (volumes[i] == null and volumes[first - 1] != null) volumes[i] = 0;
        }
    }
}

fn eqlVolume(a: ?f64, b: ?f64) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.? == b.?;
}

fn withinVolume(volumes: []const ?f64, first: usize, end: usize, volume: ?f64) bool {
    for (volumes[first..end]) |v| if (v != null and !eqlVolume(v, volume)) return false;
    return true;
}

/// .5, .6 and so on after the lower whole number, the least recent lowest,
/// or evenly spread when those don't fit below `upper`.
fn fillBetween(numbers: []?Recognized, first: usize, end: usize, lower: f64, upper: f64) void {
    const count = end - first;
    var tenths: [5]f64 = undefined;
    var available: usize = 0;
    for (5..10) |t| {
        const value = @floor(lower) + @as(f64, @floatFromInt(t)) / 10.0;
        if (value > lower and value < upper) {
            tenths[available] = value;
            available += 1;
        }
    }
    if (available >= count) {
        var index: usize = 0;
        var i = end;
        while (i > first) {
            i -= 1;
            numbers[i] = .{ .value = roundHalfEven(tenths[index] * 10) / 10 };
            index += 1;
        }
        return;
    }
    const step = (upper - lower) / @as(f64, @floatFromInt(count + 1));
    for (first..end) |i| numbers[i] = .{ .value = roundHalfEven((lower + step * @as(f64, @floatFromInt(end - i))) * 1000) / 1000 };
}

/// Mihon's `ChapterSanitizer`: trims, removes the title prefix
/// (case-sensitively), then trims whitespace and `- _ , :`.
pub fn sanitizeName(name: []const u8, title: []const u8) []const u8 {
    var s = std.mem.trim(u8, name, " \t\n\r\x0b\x0c");
    if (title.len > 0 and std.mem.startsWith(u8, s, title)) s = s[title.len..];
    return trimChapterChars(s);
}

fn trimChapterChars(s: []const u8) []const u8 {
    var start: usize = 0;
    var end = s.len;
    while (start < end) {
        const n = trimmable(s[start..end], .start) orelse break;
        start += n;
    }
    while (end > start) {
        const n = trimmable(s[start..end], .end) orelse break;
        end -= n;
    }
    return s[start..end];
}

/// Length of a trim character at the given end of `s`, or null.
fn trimmable(s: []const u8, side: enum { start, end }) ?usize {
    const ascii = " \t\n\x0b\x0c\r-_,:";
    const c = if (side == .start) s[0] else s[s.len - 1];
    if (std.mem.indexOfScalar(u8, ascii, c) != null) return 1;
    // Multi-byte whitespace: U+0085, U+00A0, U+1680, U+2000..U+200A, U+2028,
    // U+2029, U+202F, U+205F, U+3000.
    const wide = [_][]const u8{ "\u{85}", "\u{a0}", "\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200a}", "\u{2028}", "\u{2029}", "\u{202f}", "\u{205f}", "\u{3000}" };
    for (wide) |w| {
        if (side == .start and std.mem.startsWith(u8, s, w)) return w.len;
        if (side == .end and std.mem.endsWith(u8, s, w)) return w.len;
    }
    return null;
}

// ---- tests (ported from Mihon's ChapterRecognitionTest) ------------------------------

const Expect = struct { []const u8, ?[]const u8, ?[]const u8 };

fn expectNumbers(title: []const u8, expected: []const Expect) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const inputs = try a.alloc(Input, expected.len);
    for (expected, inputs) |e, *in| in.* = .{ .name = e[0] };
    const got = try parseChapterNumbers(a, title, inputs);
    for (expected, got) |e, g| {
        errdefer std.debug.print("name {s}: volume {?s} chapter {?s}, expected {?s} {?s}\n", .{ e[0], g.volume, g.chapter, e[1], e[2] });
        try expectOptional(e[1], g.volume);
        try expectOptional(e[2], g.chapter);
    }
}

fn expectOptional(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected == null or actual == null) return std.testing.expectEqual(expected == null, actual == null);
    try std.testing.expectEqualStrings(expected.?, actual.?);
}

test "ch prefix, decimals and letters" {
    try expectNumbers("Mokushiroku Alice", &.{.{ "Mokushiroku Alice Vol.1 Ch.4: Misrepresentation", "1", "4" }});
    try expectNumbers("Mokushiroku Alice", &.{.{ "Mokushiroku Alice Vol. 1 Ch. 4: Misrepresentation", "1", "4" }});
    try expectNumbers("Mokushiroku Alice", &.{.{ "Mokushiroku Alice Vol.1 Ch.4.1: Misrepresentation", "1", "4.1" }});
    try expectNumbers("Mokushiroku Alice", &.{.{ "Mokushiroku Alice Vol.1 Ch.4.4: Misrepresentation", "1", "4.4" }});
    try expectNumbers("Mokushiroku Alice", &.{.{ "Mokushiroku Alice Vol.1 Ch.4.a: Misrepresentation", "1", "4a" }});
    try expectNumbers("Mokushiroku Alice", &.{.{ "Mokushiroku Alice Vol.1 Ch.4.b: Misrepresentation", "1", "4b" }});
    try expectNumbers("Mokushiroku Alice", &.{.{ "Mokushiroku Alice Vol.1 Ch.4.extra: Misrepresentation", "1", "4.99" }});
    try expectNumbers("Mokushiroku Alice", &.{.{ "Mokushiroku Alice Vol.1 Ch. 4: Misrepresentation", "1", "4" }});
}

test "names with one number" {
    try expectNumbers("Bleach", &.{.{ "Bleach 567 Down With Snowwhite", null, "567" }});
    try expectNumbers("Bleach", &.{.{ "Bleach 567.1 Down With Snowwhite", null, "567.1" }});
    try expectNumbers("Bleach", &.{.{ "Bleach 567.4 Down With Snowwhite", null, "567.4" }});
    try expectNumbers("Bleach", &.{.{ "Bleach 567.a Down With Snowwhite", null, "567a" }});
    try expectNumbers("Bleach", &.{.{ "Bleach 567.b Down With Snowwhite", null, "567b" }});
    try expectNumbers("Bleach", &.{.{ "Bleach 567.extra Down With Snowwhite", null, "567.99" }});
    try expectNumbers("Solanin", &.{.{ "Solanin 028 Vol. 2", "2", "28" }});
    try expectNumbers("Solanin", &.{.{ "Solanin 028.1 Vol. 2", "2", "28.1" }});
    try expectNumbers("Solanin", &.{.{ "Solanin 028.4 Vol. 2", "2", "28.4" }});
    try expectNumbers("Solanin", &.{.{ "Solanin 028.a Vol. 2", "2", "28a" }});
    try expectNumbers("Solanin", &.{.{ "Solanin 028.b Vol. 2", "2", "28b" }});
    try expectNumbers("Solanin", &.{.{ "Solanin 028.extra Vol. 2", "2", "28.99" }});
}

test "versions, titles with numbers and odd separators" {
    try expectNumbers("Onepunch-Man", &.{.{ "Onepunch-Man Punch Ver002 028", null, "28" }});
    try expectNumbers("Onepunch-Man", &.{.{ "Onepunch-Man Punch Ver002 028.1", null, "28.1" }});
    try expectNumbers("Onepunch-Man", &.{.{ "Onepunch-Man Punch Ver002 028.4", null, "28.4" }});
    try expectNumbers("Onepunch-Man", &.{.{ "Onepunch-Man Punch Ver002 028.a", null, "28a" }});
    try expectNumbers("Onepunch-Man", &.{.{ "Onepunch-Man Punch Ver002 028.b", null, "28b" }});
    try expectNumbers("Onepunch-Man", &.{.{ "Onepunch-Man Punch Ver002 028.extra", null, "28.99" }});
    try expectNumbers("random", &.{.{ "Vol.1 Ch.5v.2: Alones", "1", "5" }});
    try expectNumbers("Ayame 14", &.{.{ "Ayame 14 1 - The summer of 14", null, "1" }});
    try expectNumbers("Ayame 14", &.{.{ "Vol.1 Ch.1: March 25 (First Day Cohabiting)", "1", "1" }});
    try expectNumbers("random", &.{.{ "Vol.001 Ch.003: Kaguya Doesn't Know Much", "1", "3" }});
    try expectNumbers("Onepunch-Man", &.{.{ "Onepunch-Man Punch Ver002 086 : Creeping Darkness [3]", null, "86" }});
    try expectNumbers("Ansatsu Kyoushitsu", &.{.{ "Ansatsu Kyoushitsu 011v002: Assembly Time", null, "11" }});
    try expectNumbers("Tokyo ESP", &.{.{ "Tokyo ESP 027: Part 002: Chapter 001", null, "27b" }});
    try expectNumbers("One-punch Man", &.{.{ "Mag Version 195.5", null, "195.5" }});
    try expectNumbers("random", &.{.{ "Foo", null, null }});
    try expectNumbers("random", &.{.{ "Fairy Tail 404: 00:00", null, "404" }});
    try expectNumbers("random", &.{.{ "Asu No Yoichi 19a", null, "19a" }});
}

test "extra, omake and special" {
    try expectNumbers("Fairy Tail", &.{.{ "Fairy Tail 404.extravol002", null, "404.99" }});
    try expectNumbers("Fairy Tail", &.{.{ "Fairy Tail 404 extravol002", null, "404.99" }});
    try expectNumbers("Fairy Tail", &.{.{ "Fairy Tail 404.omakevol002", null, "404.98" }});
    try expectNumbers("Fairy Tail", &.{.{ "Fairy Tail 404 omakevol002", null, "404.98" }});
    try expectNumbers("Fairy Tail", &.{.{ "Fairy Tail 404.specialvol002", null, "404.97" }});
    try expectNumbers("Fairy Tail", &.{.{ "Fairy Tail 404 specialvol002", null, "404.97" }});
}

test "commas and hyphens" {
    try expectNumbers("One Piece", &.{.{ "One Piece 300,a", null, "300a" }});
    try expectNumbers("One Piece", &.{.{ "One Piece Ch,123,extra", null, "123.99" }});
    try expectNumbers("One Piece", &.{.{ "One Piece the sunny, goes swimming 024,005", null, "24.005" }});
    try expectNumbers("Solo Leveling", &.{.{ "ch 122-a", null, "122a" }});
    try expectNumbers("Solo Leveling", &.{.{ "Solo Leveling Ch.123-extra", null, "123.99" }});
    try expectNumbers("Solo Leveling", &.{.{ "Solo Leveling, 024-005", null, "24.005" }});
    try expectNumbers("Solo Leveling", &.{.{ "Ch.191-200 Read Online", null, "191.2" }});
}

test "seasons, ordinals and parts" {
    try expectNumbers("D.I.C.E", &.{.{ "D.I.C.E[Season 001] Ep. 007", "1", "7" }});
    try expectNumbers("The Gamer", &.{.{ "S3 - Chapter 20", "3", "20" }});
    try expectNumbers("One Outs", &.{.{ "One Outs 001", null, "1" }});
    const title = "The Sister of the Woods with a Thousand Young";
    try expectNumbers(title, &.{.{ "The 1st Night", null, "1" }});
    try expectNumbers(title, &.{.{ "The 2nd Night", null, "2" }});
    try expectNumbers(title, &.{.{ "The 3rd Night", null, "3" }});
    try expectNumbers(title, &.{.{ "The 4th Night", null, "4" }});
    try expectNumbers("", &.{.{ "Chapter 1.5 Part I", null, "1.5a" }});
    try expectNumbers("", &.{.{ "Chapter 1.5 Part II", null, "1.5b" }});
    try expectNumbers("", &.{.{ "Chapter 12 Part 3", null, "12c" }});
    try expectNumbers("", &.{.{ "Vol.2 Chapter 7 - Part IV", "2", "7d" }});
    try expectNumbers("", &.{.{ "Part 3", null, "3" }});
    try expectNumbers("Mokushiroku Alice", &.{.{ "Mokushiroku Alice Vol.3", "3", null }});
    try expectNumbers("Mokushiroku Alice", &.{.{ "Vol.3 12", "3", "12" }});
    try expectNumbers("", &.{.{ "Vol-3 Chapter 2", "3", "2" }});
    try expectNumbers("", &.{.{ "Mob's 100", null, "100" }});
}

test "numbers become doubles" {
    try std.testing.expectEqual(12.0, toDouble("12"));
    try std.testing.expectEqual(10.5, toDouble("10.5"));
    try std.testing.expectEqual(19.1, toDouble("19a"));
    try std.testing.expectEqual(19.9, toDouble("19i"));
    try std.testing.expectEqual(1.5, toDouble("1.5a"));
    try std.testing.expectEqual(-2.0, toDouble("-2"));
}

test "the whole list: volumes, shared numbers and parts" {
    try expectNumbers("", &.{ .{ "Vol.2 Ch.5", "2", "5" }, .{ "Ch.4", null, "4" }, .{ "Vol.2 Ch.3", "2", "3" } });
    try expectNumbers("", &.{ .{ "Group 2 Chapter 387", null, "387" }, .{ "Group 2 Chapter 386", null, "386" }, .{ "Group 2 Chapter 385", null, "385" } });
    try expectNumbers("", &.{ .{ "Chapter 5 Part 3", null, "5c" }, .{ "Chapter 5 Part 2", null, "5b" }, .{ "Chapter 5 Part 1", null, "5a" } });
}

test "chapters without a number are filled in" {
    try expectNumbers("", &.{ .{ "Chapter 4", null, "4" }, .{ "The Return", null, "3" }, .{ "Chapter 2", null, "2" } });
    try expectNumbers("", &.{ .{ "Chapter 5", null, "5" }, .{ "Rain", null, "4" }, .{ "Snow", null, "3" }, .{ "Chapter 2", null, "2" } });
    try expectNumbers("", &.{ .{ "Chapter 11", null, "11" }, .{ "Bonus: Beach Episode", null, "10.5" }, .{ "Chapter 10", null, "10" } });
    try expectNumbers("", &.{ .{ "Chapter 13", null, "13" }, .{ "Intermission", null, "10.5" }, .{ "Chapter 10", null, "10" } });
    try expectNumbers("", &.{ .{ "Chapter 11", null, "11" }, .{ "Rain", null, "10.6" }, .{ "Snow", null, "10.5" }, .{ "Chapter 10", null, "10" } });
    try expectNumbers("", &.{ .{ "Chapter 4", null, "4" }, .{ "Side Story", null, "2.5" }, .{ "Chapter 2", null, "2" } });
    try expectNumbers("", &.{ .{ "Chapter 3", null, "3" }, .{ "Extra", null, "2.6" }, .{ "Chapter 2.5", null, "2.5" } });
    try expectNumbers("", &.{ .{ "Chapter 3", null, "3" }, .{ "Extra", null, "2.95" }, .{ "Chapter 2.9", null, "2.9" } });
}

test "chapters without a number at the ends" {
    try expectNumbers("", &.{ .{ "Afterword", null, "100.5" }, .{ "Chapter 100", null, "100" } });
    try expectNumbers("", &.{ .{ "Hiatus Announcement", null, null }, .{ "Chapter 100", null, "100" } });
    try expectNumbers("", &.{ .{ "Chapter 1", null, "1" }, .{ "Prologue", null, "0" } });
    try expectNumbers("", &.{ .{ "Chapter 1", null, "1" }, .{ "Character Profiles", null, null } });
    try expectNumbers("", &.{ .{ "Vol.1 Ch.1", "1", "1" }, .{ "Prologue", "0", "0" } });
    try expectNumbers("", &.{ .{ "Vol.1 Ch.1", "1", "1" }, .{ "Vol.2 Prologue", "2", "0" } });
}

test "chapters without a number are only numbered within a volume" {
    try expectNumbers("", &.{ .{ "Vol.1 Ch.3", "1", "3" }, .{ "Rain", null, "2" }, .{ "Vol.1 Ch.1", "1", "1" } });
    try expectNumbers("", &.{ .{ "Vol.2 Ch.3", "2", "3" }, .{ "Rain", null, null }, .{ "Vol.1 Ch.1", "1", "1" } });
    try expectNumbers("", &.{ .{ "Vol.2 Ch.3", "2", "3" }, .{ "Vol.2 Rain", "2", null }, .{ "Ch.1", null, "1" } });
    try expectNumbers("", &.{ .{ "Vol.2 Ch.3", "2", "3" }, .{ "Vol.1 Rain", "1", null }, .{ "Vol.2 Ch.1", "2", "1" } });
    try expectNumbers("", &.{ .{ "Extra", null, "10.5" }, .{ "Vol.2 Ch.10", "2", "10" } });
    try expectNumbers("", &.{ .{ "Vol.2 Extra", "2", "10.5" }, .{ "Vol.2 Ch.10", "2", "10" } });
    try expectNumbers("", &.{ .{ "Vol.3 Extra", "3", null }, .{ "Vol.2 Ch.10", "2", "10" } });
}

test "numbers from the source are kept" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try parseChapterNumbers(arena_state.allocator(), "", &.{ .{ .name = "Vol.1 Chapter 3", .number = 7.0 }, .{ .name = "Chapter 2" } });
    try std.testing.expectEqualStrings("1", got[0].volume.?);
    try std.testing.expectEqualStrings("7", got[0].chapter.?);
    try std.testing.expect(got[1].volume == null);
    try std.testing.expectEqualStrings("2", got[1].chapter.?);
}

test "names are sanitized like Mihon's" {
    try std.testing.expectEqualStrings("Chapter 3", sanitizeName("  Solo Leveling - Chapter 3 ", "Solo Leveling"));
    try std.testing.expectEqualStrings("solo leveling 3", sanitizeName("solo leveling 3", "Solo Leveling"));
    try std.testing.expectEqualStrings("Ch. 1", sanitizeName("Ch. 1\u{3000}", ""));
}

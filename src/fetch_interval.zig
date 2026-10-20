//! Smart chapter update scheduling, ported from Mihon's FetchInterval,
//! ReleaseSchedule and ReleasePattern (487c313d31ae9cf746a5d324550fdbae5f6c7b99).
//! All instants are Unix milliseconds. Calendar arithmetic uses the supplied
//! fixed UTC offset in seconds: DST transitions are approximated by that offset,
//! while local days, Gregorian months, weekdays and month-end clamping are exact.
//! No clock, I/O or timezone database is used. Only `update` allocates, temporarily
//! through its caller's allocator. Out-of-range instant results saturate to i64.
const std = @import("std");

/// Longest estimated interval or wait after following a release pattern, in days.
pub const max_interval = 28;
const day_ms = 86_400_000;

/// Inclusive bounds, from yesterday's local midnight to tomorrow's midnight.
pub const Window = struct { lower: i64, upper: i64 };

/// Fetch window for the local date containing `now_ms` (one day of grace each way).
pub fn window(now_ms: i64, utc_offset_s: i32) Window {
    const today = localDay(now_ms, utc_offset_s);
    return .{ .lower = instant(today - 1, utc_offset_s), .upper = instant(today + 1, utc_offset_s) };
}

/// Dates of a chapter remaining after the excluded-scanlator filter. A missing
/// upload date is null; an actual Unix epoch upload date is representable.
pub const ChapterDates = struct { upload_ms: ?i64 = null, fetch_ms: i64 };

/// Inputs after a chapter sync. Dates must include the filtered chapter history,
/// in any order; duplicates on a local day count as one release.
pub const Sync = struct {
    chapters: []const ChapterDates,
    /// Count after filtering, before collapsing duplicate release days. Defaults
    /// to chapters.len; eight or fewer use only the three newest release days.
    total_chapters: ?usize = null,
    /// Zero means unestimated, positive means estimated days, negative means a
    /// user override. Overrides keep their sign and do not back off on hiatus.
    fetch_interval: i32 = 0,
    /// Zero means unknown for these two persisted manga timestamps.
    next_update_ms: i64 = 0,
    last_update_ms: i64 = 0,
    /// A newly added, non-excluded release, not a first fetch of the catalogue or
    /// a chapter returning under a deleted number. last_update instead records
    /// any chapter-list change, so is only an anchor for a custom interval.
    found_release: bool = false,
    now_ms: i64,
    utc_offset_s: i32,
    /// Preserve a library job's original window across its chapter syncs. Null
    /// computes the window from now_ms, without reading a system clock.
    fetch_window: ?Window = null,
};

/// Values to persist on the manga. next_update_ms is a local start of day, or
/// the exact previous timestamp when still awaiting it inside the window.
/// The calculation always yields a next check (zero is the unknown sentinel).
pub const Update = struct { fetch_interval: i32, next_update_ms: i64 };

/// Recompute Mihon's schedule after syncing chapters. Upload history is preferred
/// with at least three distinct plausible days, then fetch history; otherwise
/// use seven days. A pending check in the window is retained unless a release
/// reached its expected date. Found releases take precedence and schedule a
/// strictly later check. The caller decides when a sync warrants this update.
pub fn update(gpa: std.mem.Allocator, sync: Sync) std.mem.Allocator.Error!Update {
    const today = localDay(sync.now_ms, sync.utc_offset_s);
    // Overrides need neither the chapter history nor temporary allocation.
    const storage: []i64 = if (sync.fetch_interval < 0) &.{} else try gpa.alloc(i64, sync.chapters.len);
    defer gpa.free(storage);
    const schedule = if (sync.fetch_interval < 0) fixed: {
        const anchor = if (sync.found_release or sync.last_update_ms == 0)
            today
        else
            localDay(sync.last_update_ms, sync.utc_offset_s);
        break :fixed Schedule{
            .interval = -@as(i64, sync.fetch_interval),
            .last_release = anchor,
            .pattern = .{ .every_days = .{ .every = -@as(i64, sync.fetch_interval), .anchor = anchor } },
            .backs_off = false,
        };
    } else estimate(storage, sync.chapters, sync.total_chapters orelse sync.chapters.len, today, sync.utc_offset_s);
    const current_window = sync.fetch_window orelse window(sync.now_ms, sync.utc_offset_s);
    const expected = sync.next_update_ms;
    const awaiting = expected != 0 and expected >= current_window.lower and
        @as(i128, expected) <= @as(i128, current_window.upper) + 1 and
        (schedule.last_release == null or schedule.last_release.? < localDay(expected, sync.utc_offset_s));
    return .{
        .fetch_interval = if (sync.fetch_interval < 0) sync.fetch_interval else @intCast(schedule.interval),
        .next_update_ms = if (sync.found_release)
            instant(schedule.nextCheckAfterRelease(today), sync.utc_offset_s)
        else if (awaiting)
            expected
        else
            instant(schedule.nextCheck(today), sync.utc_offset_s),
    };
}

/// Library update restriction: unknown dates pass; only dates strictly beyond
/// the window's upper bound are outside the release period.
pub fn outsideReleasePeriod(next_update_ms: i64, fetch_window: Window) bool {
    return next_update_ms != 0 and next_update_ms > fetch_window.upper;
}

/// Days shown for either an estimate or a negative user override; zero stays
/// zero until estimated. The unsigned result also handles the full i32 range.
pub fn displayInterval(fetch_interval: i32) u32 {
    return @intCast(@abs(@as(i64, fetch_interval)));
}

// Dates are signed days since 1970-01-01. Wide intermediates let every input
// i64 instant and i32 offset be converted without overflow, including pre-epoch.
fn localDay(ms: i64, offset: i32) i64 {
    return @intCast(@divFloor(@as(i128, ms) + @as(i128, offset) * 1000, day_ms));
}
fn instant(day: i64, offset: i32) i64 {
    return @intCast(std.math.clamp(@as(i128, day) * day_ms - @as(i128, offset) * 1000, std.math.minInt(i64), std.math.maxInt(i64)));
}
const Civil = struct { year: i64, month: i64, day: i64 };

// Howard Hinnant's proleptic Gregorian days_from_civil / civil_from_days.
fn civilDay(year: i64, month: i64, day: i64) i64 {
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = month + @as(i64, if (month > 2) -3 else 9);
    const doy = @divTrunc(153 * mp + 2, 5) + day - 1;
    return era * 146097 + yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy - 719468;
}
fn civil(day: i64) Civil {
    const z = day + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const m = mp + @as(i64, if (mp < 10) 3 else -9);
    return .{ .year = y + @as(i64, if (m <= 2) 1 else 0), .month = m, .day = doy - @divTrunc(153 * mp + 2, 5) + 1 };
}
fn monthStart(c: Civil, delta: i64) i64 {
    const months = c.year * 12 + c.month - 1 + delta;
    return civilDay(@divFloor(months, 12), @mod(months, 12) + 1, 1);
}
fn monthLength(c: Civil) i64 {
    return monthStart(c, 1) - monthStart(c, 0);
}
// Monday = 0, ... Sunday = 6.
fn weekday(day: i64) u3 {
    return @intCast(@mod(day + 3, 7));
}

const Pattern = union(enum) {
    every_days: struct { every: i64, anchor: i64 },
    weekdays: u8,
    batches: struct { every: i64, anchor: i64, length: i64 },
    days_of_month: struct { first: i64, second: ?i64 = null },
    weekday_of_month: struct { week: i64, weekday: u3 }, // -1 means last week

    fn nextAfter(self: Pattern, date: i64) i64 {
        return switch (self) {
            .every_days => |p| date + p.every - @mod(date - p.anchor, p.every),
            .batches => |p| blk: {
                const offset = @mod(date - p.anchor, p.every);
                break :blk date + (if (offset + 1 < p.length) 1 else p.every - offset);
            },
            .weekdays => |mask| blk: {
                var next = date + 1;
                while (mask & (@as(u8, 1) << weekday(next)) == 0) : (next += 1) {}
                break :blk next;
            },
            .days_of_month, .weekday_of_month => self.monthlyAdjacent(date, true),
        };
    }
    fn previousBefore(self: Pattern, date: i64) i64 {
        return switch (self) {
            .every_days => |p| date - @mod(date - p.anchor - 1, p.every) - 1,
            .batches => |p| date - 1 - @max(@mod(date - 1 - p.anchor, p.every) - p.length + 1, 0),
            .weekdays => |mask| blk: {
                var prev = date - 1;
                while (mask & (@as(u8, 1) << weekday(prev)) == 0) : (prev -= 1) {}
                break :blk prev;
            },
            .days_of_month, .weekday_of_month => self.monthlyAdjacent(date, false),
        };
    }
    fn nearest(self: Pattern, date: i64) i64 {
        // A release between fixed weekdays is more likely extra than early.
        if (self == .weekdays) return date;
        const before = self.previousBefore(date + 1);
        const after = self.nextAfter(date - 1);
        // Halfway is considered late, giving the earlier next check.
        return if (date - before <= after - date) before else after;
    }
    fn monthlyAdjacent(self: Pattern, date: i64, forward: bool) i64 {
        var first = monthStart(civil(date), 0);
        while (true) {
            const c = civil(first);
            const length = monthLength(c);
            var dates: [2]i64 = undefined;
            var count: usize = 1;
            switch (self) {
                .days_of_month => |p| {
                    dates[0] = first + @min(p.first, length) - 1;
                    if (p.second) |second| {
                        dates[1] = first + @min(second, length) - 1;
                        count = 2;
                    }
                },
                .weekday_of_month => |p| {
                    dates[0] = if (p.week == -1)
                        first + length - 1 - @mod(@as(i64, weekday(first + length - 1)) - p.weekday, 7)
                    else
                        first + @mod(@as(i64, p.weekday) - weekday(first), 7) + (p.week - 1) * 7;
                },
                else => unreachable,
            }
            var best: ?i64 = null;
            for (dates[0..count]) |candidate| {
                if (forward and candidate > date) best = @min(best orelse candidate, candidate);
                if (!forward and candidate < date) best = @max(best orelse candidate, candidate);
            }
            if (best) |result| return result;
            first = monthStart(c, if (forward) 1 else -1);
        }
    }
};

const Schedule = struct {
    interval: i64,
    last_release: ?i64,
    pattern: Pattern,
    lateness: i64 = 0,
    backs_off: bool = true,
    history: []const i64 = &.{},

    fn nextCheck(self: Schedule, today: i64) i64 {
        const anchor = self.last_release orelse today;
        const elapsed = today - anchor;
        const on_break = self.backs_off and elapsed > self.interval * 4;
        var near_break_end = false;
        var break_end: ?i64 = null;
        if (on_break) {
            for (self.history[0..self.history.len -| 1], self.history[@min(1, self.history.len)..]) |newer, older| {
                const gap = newer - older;
                if (gap <= self.interval * 4) continue;
                if (elapsed >= gap - self.interval and elapsed <= gap + self.interval) near_break_end = true;
                const end = anchor + gap - self.interval;
                if (end > today) break_end = @min(break_end orelse end, end);
            }
        }
        if (on_break and !near_break_end) {
            var backed_off = self.interval;
            while (backed_off < max_interval and elapsed > backed_off * 4) backed_off *= 2;
            backed_off = @min(backed_off, max_interval);
            const next = anchor + -@divFloor(-elapsed, backed_off) * backed_off;
            return @min(next, break_end orelse next);
        }
        const due = self.pattern.nextAfter(self.pattern.nearest(anchor));
        if (today >= due and today <= due + self.lateness) return today;
        var next = due;
        while (next < today) next = self.pattern.nextAfter(next);
        return @min(next, today + max_interval);
    }
    fn nextCheckAfterRelease(self: Schedule, today: i64) i64 {
        const release = @min(self.last_release orelse today, today);
        var next = self.pattern.nextAfter(self.pattern.nearest(release));
        while (next <= today) next = self.pattern.nextAfter(next);
        return @min(next, today + max_interval);
    }
};

fn releaseDays(storage: []i64, chapters: []const ChapterDates, today: i64, offset: i32, uploads: bool) []i64 {
    var count: usize = 0;
    for (chapters) |chapter| {
        const ms = if (uploads) chapter.upload_ms orelse continue else chapter.fetch_ms;
        const day = localDay(ms, offset);
        if (day > today + 1) continue;
        storage[count] = day;
        count += 1;
    }
    std.mem.sort(i64, storage[0..count], {}, std.sort.desc(i64));
    var distinct: usize = 0;
    for (storage[0..count]) |day| {
        if (distinct > 0 and storage[distinct - 1] == day) continue;
        storage[distinct] = day;
        distinct += 1;
    }
    return storage[0..distinct];
}
fn estimate(storage: []i64, chapters: []const ChapterDates, count: usize, today: i64, offset: i32) Schedule {
    var history = releaseDays(storage, chapters, today, offset, true);
    if (history.len < 3) {
        const last_upload: ?i64 = if (history.len > 0) history[0] else null;
        history = releaseDays(storage, chapters, today, offset, false);
        if (history.len < 3) {
            const last = last_upload orelse if (history.len > 0) history[0] else null;
            return .{ .interval = 7, .last_release = last, .pattern = .{ .every_days = .{ .every = 7, .anchor = last orelse today } } };
        }
    }
    const days = history[0..@min(history.len, @as(usize, if (count <= 8) 3 else 10))];
    var gaps_buf: [9]i64 = undefined;
    const gaps = gaps_buf[0 .. days.len - 1];
    for (gaps, days[0 .. days.len - 1], days[1..]) |*gap, newer, older| gap.* = newer - older;
    const median_gap = median(gaps);
    const detected = detect(days, history, median_gap);
    const every = if (detected != null and detected.? == .batches) detected.?.batches.every else median_gap;
    const interval = std.math.clamp(every, 1, max_interval);
    return .{
        .interval = interval,
        .last_release = days[0],
        .pattern = detected orelse .{ .every_days = .{ .every = interval, .anchor = medianPhase(days[0..@min(5, days.len)], interval) } },
        .lateness = std.math.clamp(gaps[gaps.len - 1] - interval, 0, @divTrunc(interval, 2)),
        .history = history,
    };
}
fn median(values: []i64) i64 {
    std.mem.sort(i64, values, {}, std.sort.asc(i64));
    return values[(values.len - 1) / 2];
}
fn phaseDistance(from: i64, to: i64, interval: i64) i64 {
    const offset = @mod(to - from, interval);
    return @min(offset, interval - offset);
}
fn medianPhase(days: []const i64, interval: i64) i64 {
    var phase = days[0];
    var best: i64 = std.math.maxInt(i64);
    for (days) |candidate| {
        var score: i64 = 0;
        for (days) |day| score += phaseDistance(candidate, day, interval);
        if (score < best) {
            phase = candidate;
            best = score;
        }
    }
    var on_phase: usize = 0;
    for (days) |day| {
        if (phaseDistance(phase, day, interval) == 0) on_phase += 1;
    }
    return if (on_phase * 5 >= days.len * 3) phase else days[0];
}

fn detect(days: []const i64, history: []const i64, median_gap: i64) ?Pattern {
    if (days.len < 4) return null;
    if (batches(history)) |pattern| return pattern;
    if (median_gap >= 26 and median_gap <= 35) return monthly(days);
    if (median_gap >= 12 and median_gap <= 18) return twiceMonthly(days);
    return weekdays(days, median_gap);
}
fn monthly(days: []const i64) ?Pattern {
    var buf: [10]i64 = undefined;
    const doms = buf[0..days.len];
    for (doms, days) |*dom, day| dom.* = civil(day).day;
    const middle = median(doms);
    if (doms[doms.len - 1] - doms[0] <= 3) return .{ .days_of_month = .{ .first = middle } };
    if (doms[0] >= 28) return .{ .days_of_month = .{ .first = 31 } };

    // Frequency ties go to the first encountered key, as Kotlin's linked maps.
    var common_weekday: ?u3 = null;
    var common_week: ?i64 = null;
    for (days) |candidate| {
        var weekday_count: usize = 0;
        var week_count: usize = 0;
        const week = @divTrunc(civil(candidate).day - 1, 7) + 1;
        for (days) |day| {
            if (weekday(day) == weekday(candidate)) weekday_count += 1;
            if (@divTrunc(civil(day).day - 1, 7) + 1 == week) week_count += 1;
        }
        if (weekday_count * 5 >= days.len * 4 and common_weekday == null) common_weekday = weekday(candidate);
        if (week_count * 5 >= days.len * 4 and common_week == null) common_week = week;
    }
    const dow = common_weekday orelse return null;
    if (common_week) |week| {
        if (week < 5) return .{ .weekday_of_month = .{ .week = week, .weekday = dow } };
    }
    var last_week: usize = 0;
    for (days) |day| {
        const c = civil(day);
        if (c.day + 7 > monthLength(c)) last_week += 1;
    }
    return if (last_week * 5 >= days.len * 4) .{ .weekday_of_month = .{ .week = -1, .weekday = dow } } else null;
}
fn twiceMonthly(days: []const i64) ?Pattern {
    var buf: [10]i64 = undefined;
    const doms = buf[0..days.len];
    for (doms, days) |*dom, day| dom.* = civil(day).day;
    std.mem.sort(i64, doms, {}, std.sort.asc(i64));
    var split: usize = 1;
    for (1..doms.len) |i| {
        if (doms[i] - doms[i - 1] > doms[split] - doms[split - 1]) split = i;
    }
    if (split < 2 or doms.len - split < 2 or doms[split - 1] - doms[0] > 3 or doms[doms.len - 1] - doms[split] > 3) return null;
    return .{ .days_of_month = .{ .first = median(doms[0..split]), .second = median(doms[split..]) } };
}
fn weekdays(days: []const i64, median_gap: i64) ?Pattern {
    // Keep insertion order for equal frequencies, starting with newest release.
    var order: [7]u3 = undefined;
    var counts: [7]usize = @splat(0);
    var distinct: usize = 0;
    for (days) |day| {
        const dow = weekday(day);
        if (counts[dow] == 0) {
            order[distinct] = dow;
            distinct += 1;
        }
        counts[dow] += 1;
    }
    var mask: u8 = 0;
    var covered: usize = 0;
    var selected: usize = 0;
    while (covered * 5 < days.len * 4) {
        var best: ?u3 = null;
        for (order[0..distinct]) |dow| {
            if (mask & (@as(u8, 1) << dow) != 0) continue;
            if (best == null or counts[dow] > counts[best.?]) best = dow;
        }
        const dow = best orelse break;
        mask |= @as(u8, 1) << dow;
        covered += counts[dow];
        selected += 1;
    }
    if (selected < 2 or selected > 3 or covered * 5 < days.len * 4) return null;
    if (median_gap > 7 / selected + 1) return null;
    return .{ .weekdays = mask };
}
fn batches(history: []const i64) ?Pattern {
    const Run = struct { first: i64, last: i64, count: usize };
    var runs: [40]Run = undefined;
    var count: usize = 0;
    var i = @min(history.len, 40);
    while (i > 0) {
        i -= 1;
        const day = history[i];
        if (count > 0 and day - runs[count - 1].last <= 2) {
            runs[count - 1].last = day;
            runs[count - 1].count += 1;
        } else {
            runs[count] = .{ .first = day, .last = day, .count = 1 };
            count += 1;
        }
    }
    const recent = runs[count - @min(count, 6) .. count];
    if (recent.len < 3) return null;
    var multiple: usize = 0;
    for (recent) |run| {
        if (run.count > 1) multiple += 1;
    }
    if (multiple * 2 < recent.len) return null;
    var gaps_buf: [5]i64 = undefined;
    var lengths_buf: [6]i64 = undefined;
    const gaps = gaps_buf[0 .. recent.len - 1];
    const lengths = lengths_buf[0..recent.len];
    for (gaps, recent[0 .. recent.len - 1], recent[1..]) |*gap, older, newer| gap.* = newer.first - older.first;
    for (lengths, recent) |*length, run| length.* = run.last - run.first + 1;
    const every = median(gaps);
    const length = median(lengths);
    if (every < length * 2) return null;
    for (gaps) |gap| {
        if (@abs(gap - every) > @divTrunc(every, 4)) return null;
    }
    return .{ .batches = .{ .every = every, .anchor = recent[recent.len - 1].first, .length = length } };
}

// ---- Mihon's FetchIntervalTest -------------------------------------------------
// Test names and fixtures mirror the pinned Kotlin tests one for one. Kotlin
// explicitly uses UTC throughout (there are no JVM-default-zone fixtures).
// Its interval-only helper reads the clock; here it is pinned to 2022-01-01,
// after all of those fixtures, so the tests remain pure and deterministic.
const TestChapters = struct {
    buf: [128]ChapterDates = undefined,
    len: usize = 0,

    fn slice(self: *const TestChapters) []const ChapterDates {
        return self.buf[0..self.len];
    }
    fn add(self: *TestChapters, ms: i64) void {
        self.buf[self.len] = .{ .upload_ms = ms, .fetch_ms = ms };
        self.len += 1;
    }
    fn on(self: *TestChapters, dates: []const []const u8, per_day: usize) void {
        for (dates) |date| {
            for (0..per_day) |_| self.add(testMs(date) + 12 * 3_600_000);
        }
    }
    fn every(self: *TestChapters, step: i64, from: []const u8, to: []const u8) void {
        var day = testDay(from);
        while (day <= testDay(to)) : (day += step) self.add(instant(day, 0) + 12 * 3_600_000);
    }
    fn offsets(self: *TestChapters, n: usize, step_ms: i64, base_ms: i64) void {
        for (1..n + 1) |i| self.add(base_ms + @as(i64, @intCast(i)) * step_ms);
    }
    fn noUploads(self: *TestChapters) void {
        for (self.buf[0..self.len]) |*chapter| chapter.upload_ms = null;
    }
};
fn testDay(date: []const u8) i64 {
    return civilDay(std.fmt.parseInt(i64, date[0..4], 10) catch unreachable, std.fmt.parseInt(i64, date[5..7], 10) catch unreachable, std.fmt.parseInt(i64, date[8..10], 10) catch unreachable);
}
fn testMs(date: []const u8) i64 {
    return instant(testDay(date), 0);
}
fn expectInterval(chapters: *const TestChapters, expected: i32) !void {
    const result = try update(std.testing.allocator, .{ .chapters = chapters.slice(), .now_ms = testMs("2022-01-01"), .utc_offset_s = 0 });
    try std.testing.expectEqual(expected, result.fetch_interval);
}
fn expectNext(today: []const u8, chapters: *const TestChapters, expected: []const u8, expecting: ?[]const u8, found: bool, interval: i32) !void {
    const result = try update(std.testing.allocator, .{
        .chapters = chapters.slice(),
        .now_ms = testMs(today) + 10 * 3_600_000,
        .utc_offset_s = 0,
        .next_update_ms = if (expecting) |date| testMs(date) else 0,
        .found_release = found,
        .fetch_interval = interval,
    });
    try std.testing.expectEqual(testMs(expected), result.next_update_ms);
    if (interval < 0) try std.testing.expectEqual(interval, result.fetch_interval);
}
fn expectPattern(chapters: *const TestChapters, today: []const u8, expected: Pattern) !void {
    var buf: [128]i64 = undefined;
    const schedule = estimate(&buf, chapters.slice(), chapters.len, testDay(today), 0);
    try std.testing.expectEqualDeep(expected, schedule.pattern);
}

test "returns default interval of 7 days when not enough distinct days" {
    var chapters: TestChapters = .{};
    for (0..50) |_| chapters.add(testMs("2020-01-01") + day_ms);
    try expectInterval(&chapters, 7);
    chapters.noUploads();
    try expectInterval(&chapters, 7);
}

test "returns interval based on more recent chapters" {
    var chapters: TestChapters = .{};
    chapters.offsets(5, 7 * day_ms, testMs("2020-01-01"));
    chapters.offsets(10, day_ms, testMs("2020-01-01") + 35 * day_ms);
    try expectInterval(&chapters, 1);
}

test "returns interval based on smaller subset of recent chapters if very few chapters" {
    var chapters: TestChapters = .{};
    chapters.offsets(3, 7 * day_ms, testMs("2020-01-01"));
    chapters.offsets(3, 7 * day_ms, testMs("2020-01-01") + (21 + 365) * day_ms);
    try expectInterval(&chapters, 7);
}

test "returns interval of 7 days when multiple chapters in 1 day" {
    var chapters: TestChapters = .{};
    for (0..10) |_| chapters.add(testMs("2020-01-01") + 10 * 3_600_000);
    try expectInterval(&chapters, 7);
}

test "returns interval of 7 days when multiple chapters in 2 days" {
    var chapters: TestChapters = .{};
    for (0..2) |_| chapters.add(testMs("2020-01-01") + day_ms);
    for (0..5) |_| chapters.add(testMs("2020-01-01") + 2 * day_ms);
    try expectInterval(&chapters, 7);
}

test "returns interval of 1 day when chapters are released every 1 day" {
    var chapters: TestChapters = .{};
    chapters.offsets(20, day_ms, testMs("2020-01-01"));
    try expectInterval(&chapters, 1);
}

test "returns interval of 1 day when delta is less than 1 day" {
    var chapters: TestChapters = .{};
    chapters.offsets(20, 15 * 3_600_000, testMs("2020-01-01"));
    try expectInterval(&chapters, 1);
}

test "returns interval of 2 days when chapters are released every 2 days" {
    var chapters: TestChapters = .{};
    chapters.offsets(20, 2 * day_ms, testMs("2020-01-01"));
    try expectInterval(&chapters, 2);
}

test "returns interval with floored value when interval is decimal" {
    var chapters: TestChapters = .{};
    chapters.offsets(5, 25 * 3_600_000, testMs("2020-01-01"));
    try expectInterval(&chapters, 1);
    chapters.noUploads();
    try expectInterval(&chapters, 1);
}

test "returns interval of 2 days when chapters are released just below every 2 days" {
    var chapters: TestChapters = .{};
    chapters.offsets(20, 43 * 3_600_000, testMs("2020-01-01"));
    try expectInterval(&chapters, 2);
}

test "follows releases on a few fixed weekdays" {
    var chapters: TestChapters = .{};
    var day = testDay("2019-12-02");
    while (day <= testDay("2020-01-20")) : (day += 1) {
        if (weekday(day) == 0 or weekday(day) == 3) chapters.add(instant(day, 0) + 12 * 3_600_000);
    }
    try expectPattern(&chapters, "2020-01-21", .{ .weekdays = (1 << 0) | (1 << 3) });
    try expectNext("2020-01-21", &chapters, "2020-01-23", null, false, 0);
}

test "follows releases on a day of the month" {
    var chapters: TestChapters = .{};
    chapters.on(&.{ "2019-09-15", "2019-10-15", "2019-11-14", "2019-12-15", "2020-01-16" }, 2);
    try expectNext("2020-01-20", &chapters, "2020-02-15", null, false, 0);
}

test "follows releases on the last day of the month" {
    var chapters: TestChapters = .{};
    chapters.on(&.{ "2019-09-30", "2019-10-31", "2019-11-30", "2019-12-31", "2020-01-31" }, 2);
    try expectNext("2020-02-05", &chapters, "2020-02-29", null, false, 0);
}

test "follows releases on two days of the month" {
    var chapters: TestChapters = .{};
    chapters.on(&.{ "2019-10-01", "2019-10-15", "2019-11-01", "2019-11-16", "2019-12-01", "2019-12-15", "2020-01-01", "2020-01-15" }, 2);
    try expectPattern(&chapters, "2020-01-20", .{ .days_of_month = .{ .first = 1, .second = 15 } });
    try expectNext("2020-01-20", &chapters, "2020-02-01", null, false, 0);
}

test "follows releases on a weekday of the month" {
    var chapters: TestChapters = .{};
    chapters.on(&.{ "2019-09-07", "2019-10-05", "2019-11-02", "2019-12-07", "2020-01-04" }, 2);
    try expectNext("2020-01-10", &chapters, "2020-02-01", null, false, 0);
}

test "follows releases on a weekday of the last week of the month" {
    var chapters: TestChapters = .{};
    chapters.on(&.{ "2019-09-27", "2019-10-25", "2019-11-29", "2019-12-27", "2020-01-31" }, 2);
    try expectNext("2020-02-03", &chapters, "2020-02-28", null, false, 0);
}

test "follows releases in batches" {
    var partial: TestChapters = .{};
    var all: TestChapters = .{};
    var day = testDay("2019-09-02");
    while (day <= testDay("2019-12-16")) : (day += 21) {
        for (0..3) |i| {
            const release = day + @as(i64, @intCast(i));
            all.add(instant(release, 0) + 12 * 3_600_000);
            if (release <= testDay("2019-12-17")) partial.add(instant(release, 0) + 12 * 3_600_000);
        }
    }
    try expectNext("2019-12-17", &partial, "2019-12-18", null, true, 0);
    try expectNext("2019-12-18", &all, "2020-01-06", null, true, 0);
}

test "checks again around when an earlier break ended" {
    var chapters: TestChapters = .{};
    chapters.every(7, "2019-01-02", "2019-03-27");
    chapters.every(7, "2019-07-03", "2019-09-25");
    try expectNext("2019-12-20", &chapters, "2019-12-25", null, false, 0);
    try expectNext("2019-12-26", &chapters, "2020-01-01", null, false, 0);
}

test "never waits more than 28 days between checks" {
    var chapters: TestChapters = .{};
    chapters.on(&.{ "2019-09-30", "2019-10-31", "2019-11-30", "2019-12-31", "2020-01-31" }, 2);
    try expectNext("2020-01-31", &chapters, "2020-02-28", null, true, 0);
}

test "keeps checking on the expected day" {
    var chapters: TestChapters = .{};
    chapters.every(7, "2019-12-04", "2019-12-25");
    try expectNext("2020-01-01", &chapters, "2020-01-01", null, false, 0);
}

test "keeps a next update in the window while nothing new came out" {
    var chapters: TestChapters = .{};
    chapters.every(7, "2019-12-04", "2019-12-25");
    try expectNext("2020-01-02", &chapters, "2020-01-01", "2020-01-01", false, 0);
}

test "counts from a release on the expected day" {
    var chapters: TestChapters = .{};
    chapters.every(7, "2019-12-04", "2020-01-01");
    try expectNext("2020-01-01", &chapters, "2020-01-08", "2020-01-01", false, 0);
}

test "keeps the schedule for a release uploaded the day before it was found" {
    var chapters: TestChapters = .{};
    chapters.every(7, "2019-10-02", "2019-12-25");
    chapters.on(&.{"2019-12-31"}, 1);
    try expectNext("2020-01-01", &chapters, "2020-01-08", "2020-01-01", true, 0);
}

test "keeps the schedule after a release shortly before the expected day" {
    var chapters: TestChapters = .{};
    chapters.every(7, "2019-10-02", "2019-12-25");
    chapters.on(&.{"2019-12-30"}, 1);
    try expectNext("2019-12-30", &chapters, "2020-01-08", "2020-01-01", true, 0);
}

test "keeps the schedule after a late release" {
    var chapters: TestChapters = .{};
    chapters.every(7, "2019-12-04", "2019-12-25");
    chapters.on(&.{"2020-01-03"}, 1);
    try expectNext("2020-01-03", &chapters, "2020-01-08", "2020-01-01", true, 0);
}

test "keeps expecting the release after an extra one well before it" {
    var chapters: TestChapters = .{};
    chapters.every(7, "2019-10-02", "2020-01-01");
    chapters.on(&.{"2020-01-02"}, 1);
    try expectNext("2020-01-02", &chapters, "2020-01-08", "2020-01-08", true, 0);
}

test "follows the schedule again when releases resume after a hiatus" {
    var chapters: TestChapters = .{};
    chapters.every(7, "2019-09-11", "2019-10-02");
    chapters.on(&.{"2020-01-01"}, 1);
    try expectNext("2020-01-01", &chapters, "2020-01-08", "2020-01-22", true, 0);
}

test "follows the schedule once releases keep coming early" {
    var chapters: TestChapters = .{};
    chapters.every(5, "2019-10-01", "2019-12-15");
    chapters.every(5, "2019-12-19", "2019-12-29");
    try expectNext("2019-12-29", &chapters, "2020-01-03", "2019-12-30", true, 0);
}

test "keeps checking for an overdue release while recent ones came that late" {
    var chapters: TestChapters = .{};
    var day = testDay("2019-10-18");
    chapters.add(instant(day, 0) + 12 * 3_600_000);
    for ([_]i64{ 6, 5, 8, 6, 5, 6, 8, 6, 5 }) |gap| {
        day += gap;
        chapters.add(instant(day, 0) + 12 * 3_600_000);
    }
    try expectNext("2019-12-20", &chapters, "2019-12-20", "2019-12-18", false, 0);
}

test "counts from an early release with a custom interval" {
    try expectNext("2019-12-31", &.{}, "2020-01-07", "2020-01-01", true, -7);
}

test "spreads out checks during a hiatus" {
    var chapters: TestChapters = .{};
    chapters.every(7, "2019-09-11", "2019-10-02");
    try expectNext("2020-01-01", &chapters, "2020-01-22", null, false, 0);
}

test "ignores chapters dated in the future" {
    var chapters: TestChapters = .{};
    chapters.every(7, "2019-12-04", "2019-12-25");
    chapters.on(&.{"2020-06-01"}, 1);
    try expectNext("2020-01-01", &chapters, "2020-01-01", null, false, 0);
}

// ---- fixed-offset and engine integration boundaries ---------------------------
test "local midnight and fetch window use the fixed offset before and after epoch" {
    // 1969-12-31 23:59:59.999 UTC is Jan 1 locally at UTC+05:30.
    const offset = 5 * 3600 + 30 * 60;
    const w = window(-1, offset);
    try std.testing.expectEqual(@as(i64, -106_200_000), w.lower);
    try std.testing.expectEqual(@as(i64, 66_600_000), w.upper);
    try std.testing.expectEqual(@as(i64, -1), localDay(-1, 0));
    // Fractional seconds and a negative, non-hour offset also cross midnight.
    const west = window(testMs("2020-03-01") + 1000, -3 * 3600 - 30 * 60);
    try std.testing.expectEqual(testMs("2020-02-28") + 12_600_000, west.lower);
    try std.testing.expectEqual(testMs("2020-03-01") + 12_600_000, west.upper);
}

test "Gregorian centuries month clamping and weekdays are independent of OS time" {
    try std.testing.expectEqual(@as(i64, 0), civilDay(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, -1), civilDay(1969, 12, 31));
    try std.testing.expectEqual(@as(i64, 28), monthLength(.{ .year = 1900, .month = 2, .day = 1 }));
    try std.testing.expectEqual(@as(i64, 29), monthLength(.{ .year = 2000, .month = 2, .day = 1 }));
    try std.testing.expectEqual(@as(i64, 29), monthLength(.{ .year = 0, .month = 2, .day = 1 }));
    try std.testing.expectEqual(@as(u3, 3), weekday(0)); // Thursday
    try std.testing.expectEqual(@as(u3, 2), weekday(-1)); // Wednesday
    const end: Pattern = .{ .days_of_month = .{ .first = 31 } };
    try std.testing.expectEqual(testDay("1900-02-28"), end.nextAfter(testDay("1900-01-31")));
    try std.testing.expectEqual(testDay("2000-02-29"), end.nextAfter(testDay("2000-01-31")));
    try std.testing.expectEqual(testDay("2000-02-29"), end.previousBefore(testDay("2000-03-31")));
    const year_zero = civilDay(0, 2, 29);
    try std.testing.expectEqual(Civil{ .year = 0, .month = 2, .day = 29 }, civil(year_zero));
    try std.testing.expectEqual(Civil{ .year = -400, .month = 12, .day = 31 }, civil(civilDay(-400, 12, 31)));
}

test "pending checks preserve exact timestamp through upper bound plus one millisecond" {
    var chapters: TestChapters = .{};
    chapters.every(7, "2019-12-04", "2019-12-25");
    const today = testMs("2020-01-01");
    const w = window(today, 0);
    for ([_]i64{ w.lower, today + 1234, w.upper, w.upper + 1 }) |expected| {
        const result = try update(std.testing.allocator, .{ .chapters = chapters.slice(), .now_ms = today, .utc_offset_s = 0, .next_update_ms = expected });
        try std.testing.expectEqual(expected, result.next_update_ms);
    }
    for ([_]i64{ w.lower - 1, w.upper + 2 }) |expected| {
        const result = try update(std.testing.allocator, .{ .chapters = chapters.slice(), .now_ms = today, .utc_offset_s = 0, .next_update_ms = expected });
        try std.testing.expectEqual(today, result.next_update_ms);
    }
    // A batch's window can differ from the sync's date and must be respected.
    const retained = try update(std.testing.allocator, .{
        .chapters = chapters.slice(),
        .now_ms = testMs("2020-01-04"),
        .utc_offset_s = 0,
        .next_update_ms = today,
        .fetch_window = w,
    });
    try std.testing.expectEqual(today, retained.next_update_ms);
}

test "release restriction and displayed interval retain unknown and strict-boundary semantics" {
    const w = window(testMs("2020-01-01"), 0);
    try std.testing.expect(!outsideReleasePeriod(0, w));
    try std.testing.expect(!outsideReleasePeriod(w.upper, w));
    try std.testing.expect(outsideReleasePeriod(w.upper + 1, w));
    try std.testing.expectEqual(@as(u32, 0), displayInterval(0));
    try std.testing.expectEqual(@as(u32, 7), displayInterval(7));
    try std.testing.expectEqual(@as(u32, 7), displayInterval(-7));
    try std.testing.expectEqual(@as(u32, 2_147_483_648), displayInterval(std.math.minInt(i32)));
}

test "custom intervals follow last list change without hiatus backoff and need no allocation" {
    const gpa = std.testing.failing_allocator;
    const result = try update(gpa, .{
        .chapters = &.{},
        .fetch_interval = -7,
        .last_update_ms = testMs("2019-10-02"),
        .now_ms = testMs("2020-01-02"),
        .utc_offset_s = 0,
    });
    try std.testing.expectEqual(@as(i32, -7), result.fetch_interval);
    try std.testing.expectEqual(testMs("2020-01-08"), result.next_update_ms);
    const unknown = try update(gpa, .{ .chapters = &.{}, .fetch_interval = -7, .now_ms = testMs("2020-01-02"), .utc_offset_s = 0 });
    try std.testing.expectEqual(testMs("2020-01-09"), unknown.next_update_ms);
}

test "upload preference fetch fallback future grace and total chapter count" {
    const today = testMs("2020-01-01");
    const data = [_]ChapterDates{
        .{ .upload_ms = testMs("2019-12-25"), .fetch_ms = testMs("2019-12-30") },
        .{ .upload_ms = testMs("2019-12-18"), .fetch_ms = testMs("2019-12-31") },
        .{ .upload_ms = testMs("2019-12-11"), .fetch_ms = today },
    };
    const uploaded = try update(std.testing.allocator, .{ .chapters = &data, .now_ms = today, .utc_offset_s = 0 });
    try std.testing.expectEqual(@as(i32, 7), uploaded.fetch_interval);
    var missing = data;
    missing[0].upload_ms = null;
    const fetched = try update(std.testing.allocator, .{ .chapters = &missing, .now_ms = today, .utc_offset_s = 0 });
    try std.testing.expectEqual(@as(i32, 1), fetched.fetch_interval);
    var buf: [4]i64 = undefined;
    const future = [_]ChapterDates{
        .{ .upload_ms = today, .fetch_ms = today },
        .{ .upload_ms = today + day_ms, .fetch_ms = today },
        .{ .upload_ms = today + 2 * day_ms, .fetch_ms = today },
    };
    const schedule = estimate(&buf, &future, future.len, testDay("2020-01-01"), 0);
    try std.testing.expectEqual(testDay("2020-01-02"), schedule.last_release);
    try std.testing.expectEqual(@as(i64, 7), schedule.interval);

    var history: TestChapters = .{};
    history.on(&.{ "2019-12-19", "2019-12-23", "2019-12-26", "2019-12-30" }, 1);
    const few = try update(std.testing.allocator, .{
        .chapters = history.slice(),
        .total_chapters = 4,
        .now_ms = today,
        .utc_offset_s = 0,
    });
    try std.testing.expectEqual(today, few.next_update_ms);
    const many = try update(std.testing.allocator, .{
        .chapters = history.slice(),
        .total_chapters = 9,
        .now_ms = today,
        .utc_offset_s = 0,
    });
    // Four or more selected days reveal Monday/Thursday; a three-day sample
    // instead follows the median three-day interval and its majority phase.
    try std.testing.expectEqual(testMs("2020-01-02"), many.next_update_ms);
}

test "sync uses local release dates and produces local midnight" {
    // UTC Sundays at 23:30 are already Mondays at UTC+01:00.
    var chapters: TestChapters = .{};
    for ([_][]const u8{ "2019-12-01", "2019-12-08", "2019-12-15" }) |date| chapters.add(testMs(date) + 23 * 3_600_000 + 30 * 60_000);
    const result = try update(std.testing.allocator, .{
        .chapters = chapters.slice(),
        .now_ms = testMs("2019-12-22") + 23 * 3_600_000,
        .utc_offset_s = 3600,
    });
    try std.testing.expectEqual(@as(i32, 7), result.fetch_interval);
    try std.testing.expectEqual(testMs("2019-12-22") + 23 * 3_600_000, result.next_update_ms);
}

test "temporary history is released on allocation failure" {
    const Check = struct {
        fn run(gpa: std.mem.Allocator) !void {
            const chapters = [_]ChapterDates{
                .{ .fetch_ms = testMs("2019-12-18") },
                .{ .fetch_ms = testMs("2019-12-25") },
                .{ .fetch_ms = testMs("2020-01-01") },
            };
            const result = try update(gpa, .{ .chapters = &chapters, .now_ms = testMs("2020-01-01"), .utc_offset_s = 0 });
            try std.testing.expectEqual(@as(i32, 7), result.fetch_interval);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

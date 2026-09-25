//! Reading a date out of a search request, and turning it into a Gmail filter.
//!
//! The bug this exists for: asked to "find an email about Order Consolidated
//! Job from the 24th of September", the query builder turned the date into
//! *search terms* --
//!
//!   ("Order Consolidated Job" OR ... OR "24th September" OR "24 Sept")
//!
//! -- and a message sent on 24 September almost never contains the string
//! "24 September" anywhere in it. So the date, which is the most precise
//! thing in the request, made the search worse instead of better. Gmail can
//! filter on it exactly; it just has to be asked in its own syntax.
//!
//! Parsed by code, not by a model, for the same reason as the quiet-hours
//! clock: a date is a small closed grammar, and a model that reads one wrong
//! sends the search to the wrong week without saying so.

const std = @import("std");

const log = std.log.scoped(.dates);

/// Today, in the owner's timezone. See `ronny_today` in shim.c.
extern fn ronny_today(year: *c_int, month: *c_int, day: *c_int) void;

pub const Day = struct {
    year: u16,
    month: u8,
    day: u8,

    /// Days since 1970-01-01, by the usual civil-calendar algorithm. Used
    /// only to shift a date by N days without writing out month lengths and
    /// leap years twice.
    pub fn epochDay(self: Day) i32 {
        var y: i32 = self.year;
        const m: i32 = self.month;
        const d: i32 = self.day;
        y -= @intFromBool(m <= 2);
        const era = @divFloor(y, 400);
        const yoe = y - era * 400;
        const doy = @divTrunc(153 * (m + (if (m > 2) @as(i32, -3) else 9)) + 2, 5) + d - 1;
        const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
        return era * 146097 + doe - 719468;
    }

    pub fn fromEpochDay(z_in: i32) Day {
        const z = z_in + 719468;
        const era = @divFloor(z, 146097);
        const doe = z - era * 146097;
        const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
        const y = yoe + era * 400;
        const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
        const mp = @divTrunc(5 * doy + 2, 153);
        const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
        const m = mp + (if (mp < 10) @as(i32, 3) else -9);
        return .{
            .year = @intCast(y + @intFromBool(m <= 2)),
            .month = @intCast(m),
            .day = @intCast(d),
        };
    }

    pub fn shift(self: Day, days: i32) Day {
        return fromEpochDay(self.epochDay() + days);
    }

    pub fn order(self: Day, other: Day) std.math.Order {
        return std.math.order(self.epochDay(), other.epochDay());
    }
};

pub fn today() Day {
    var y: c_int = 0;
    var m: c_int = 1;
    var d: c_int = 1;
    ronny_today(&y, &m, &d);
    if (y <= 0) return .{ .year = 1970, .month = 1, .day = 1 };
    return .{ .year = @intCast(y), .month = @intCast(m), .day = @intCast(d) };
}

/// Gmail's own semantics: `after:` includes its day, `before:` excludes it.
/// So a single day is after:D before:D+1.
pub const Range = struct {
    after: Day,
    before: Day,
};

/// A date found in a request, and where it sat in the text so the caller can
/// cut it out before the rest becomes search terms.
pub const Found = struct {
    range: Range,
    start: usize,
    end: usize,
};

/// Gmail results can land a day either side of what you asked for when the
/// account's timezone differs from the machine's, so a named day is widened
/// by a day at each end. The ranker's whole job is discarding near misses;
/// missing the message entirely is the failure that cannot be recovered.
pub const DAY_SLACK = 1;

const MONTHS = [_][]const u8{
    "january", "february", "march",     "april",   "may",      "june",
    "july",    "august",   "september", "october", "november", "december",
};

/// Enough to match "Sept", "Sep" and "September" from the same entry.
fn monthAt(text: []const u8) ?struct { month: u8, len: usize } {
    for (MONTHS, 0..) |name, i| {
        // Longest first: "june" must not match as "jun" and leave an "e".
        var take = name.len;
        while (take >= 3) : (take -= 1) {
            if (take > text.len) continue;
            if (!std.ascii.eqlIgnoreCase(text[0..take], name[0..take])) continue;
            // "sept" is the one abbreviation that is not a simple prefix cut.
            var len = take;
            if (i == 8 and len == 3 and text.len > 3 and std.ascii.toLower(text[3]) == 't') len = 4;
            return .{ .month = @intCast(i + 1), .len = len };
        }
    }
    return null;
}

fn readNumber(text: []const u8) ?struct { value: u32, len: usize } {
    var len: usize = 0;
    while (len < text.len and std.ascii.isDigit(text[len]) and len < 4) len += 1;
    if (len == 0) return null;
    return .{ .value = std.fmt.parseInt(u32, text[0..len], 10) catch return null, .len = len };
}

/// Skips "th", "st", "nd", "rd", and the words between a day and its month.
fn skipFiller(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == ' ' or text[i] == ',') {
            i += 1;
            continue;
        }
        const rest = text[i..];
        const fillers = [_][]const u8{ "th", "st", "nd", "rd", "of", "the" };
        var matched = false;
        for (fillers) |filler| {
            if (rest.len >= filler.len and std.ascii.eqlIgnoreCase(rest[0..filler.len], filler)) {
                // Only when it ends there -- "other" must not eat "the".
                const after = rest[filler.len..];
                if (after.len == 0 or !std.ascii.isAlphabetic(after[0])) {
                    i += filler.len;
                    matched = true;
                    break;
                }
            }
        }
        if (!matched) break;
    }
    return i;
}

/// The most recent occurrence of a month/day that is not in the future.
///
/// "the 24th of September" said in October means this year; said in March it
/// means last year. Searching forward from today would find nothing at all,
/// which is the same silent-nothing the date filter exists to prevent.
fn mostRecent(now: Day, month: u8, day: u8) Day {
    const candidate: Day = .{ .year = now.year, .month = month, .day = day };
    if (candidate.order(now) == .gt) {
        return .{ .year = now.year - 1, .month = month, .day = day };
    }
    return candidate;
}

fn singleDay(day: Day) Range {
    return .{
        .after = day.shift(-DAY_SLACK),
        .before = day.shift(1 + DAY_SLACK),
    };
}

/// Finds the first date expression in `text`.
pub fn find(now: Day, text: []const u8) ?Found {
    // Relative expressions first: they are exact phrases, so matching them
    // before the numeric forms avoids "last 7 days" being read as a day 7.
    const relative = [_]struct { phrase: []const u8, from: i32, to: i32 }{
        .{ .phrase = "the day before yesterday", .from = -2, .to = -2 },
        .{ .phrase = "yesterday", .from = -1, .to = -1 },
        .{ .phrase = "today", .from = 0, .to = 0 },
        .{ .phrase = "this morning", .from = 0, .to = 0 },
        .{ .phrase = "last week", .from = -7, .to = 0 },
        .{ .phrase = "this week", .from = -7, .to = 0 },
        .{ .phrase = "past week", .from = -7, .to = 0 },
        .{ .phrase = "last fortnight", .from = -14, .to = 0 },
        .{ .phrase = "last month", .from = -31, .to = 0 },
        .{ .phrase = "this month", .from = -31, .to = 0 },
        .{ .phrase = "past month", .from = -31, .to = 0 },
    };
    for (relative) |entry| {
        if (indexOfIgnoreCase(text, entry.phrase)) |at| {
            return .{
                .range = .{
                    .after = now.shift(entry.from - DAY_SLACK),
                    .before = now.shift(entry.to + 1 + DAY_SLACK),
                },
                .start = at,
                .end = at + entry.phrase.len,
            };
        }
    }

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        // Only start at a word boundary.
        if (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '/')) continue;
        const rest = text[i..];

        // "24 September", "24th of September", "24/09/2026", "2026-09-24"
        if (readNumber(rest)) |first| {
            const after_first = rest[first.len..];

            // ISO, or a slashed date. Four leading digits mean year first.
            if (after_first.len > 1 and (after_first[0] == '/' or after_first[0] == '-')) {
                if (readNumber(after_first[1..])) |second| {
                    const sep = after_first[0];
                    var rest2 = after_first[1 + second.len ..];
                    var third: ?u32 = null;
                    var third_len: usize = 0;
                    if (rest2.len > 1 and rest2[0] == sep) {
                        if (readNumber(rest2[1..])) |t| {
                            third = t.value;
                            third_len = 1 + t.len;
                        }
                    }
                    rest2 = rest2[third_len..];

                    const parsed: ?Day = if (first.len == 4)
                        // 2026-09-24
                        makeDay(first.value, second.value, third orelse 1)
                    else if (third) |year|
                        // 24/09/2026, day first -- the owner writes European.
                        makeDay(if (year < 100) 2000 + year else year, second.value, first.value)
                    else
                        // 24/09, no year
                        mostRecentChecked(now, second.value, first.value);

                    if (parsed) |day| {
                        return .{
                            .range = singleDay(day),
                            .start = i,
                            .end = text.len - rest2.len,
                        };
                    }
                }
            }

            // "24th of September"
            const skipped = skipFiller(after_first);
            if (monthAt(after_first[skipped..])) |month| {
                if (mostRecentChecked(now, month.month, @intCast(first.value))) |day| {
                    return .{
                        .range = singleDay(day),
                        .start = i,
                        .end = i + first.len + skipped + month.len,
                    };
                }
            }
        }

        // "September 24", or a bare "in September"
        if (monthAt(rest)) |month| {
            const skipped = skipFiller(rest[month.len..]);
            if (readNumber(rest[month.len + skipped ..])) |number| {
                if (number.value <= 31) {
                    if (mostRecentChecked(now, month.month, @intCast(number.value))) |day| {
                        return .{
                            .range = singleDay(day),
                            .start = i,
                            .end = i + month.len + skipped + number.len,
                        };
                    }
                }
            }
            // A month with no day is that whole month.
            const first_of = mostRecent(now, month.month, 1);
            const next = if (month.month == 12)
                Day{ .year = first_of.year + 1, .month = 1, .day = 1 }
            else
                Day{ .year = first_of.year, .month = month.month + 1, .day = 1 };
            return .{
                .range = .{ .after = first_of.shift(-DAY_SLACK), .before = next.shift(DAY_SLACK) },
                .start = i,
                .end = i + month.len,
            };
        }
    }
    return null;
}

fn makeDay(year: u32, month: u32, day: u32) ?Day {
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (year < 1970 or year > 2200) return null;
    return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
}

fn mostRecentChecked(now: Day, month: u32, day: u32) ?Day {
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    return mostRecent(now, @intCast(month), @intCast(day));
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Gmail wants YYYY/MM/DD and nothing else -- dashes return no results.
pub fn render(arena: std.mem.Allocator, range: Range) ![]const u8 {
    return std.fmt.allocPrint(arena, "after:{d:0>4}/{d:0>2}/{d:0>2} before:{d:0>4}/{d:0>2}/{d:0>2}", .{
        range.after.year,  range.after.month,  range.after.day,
        range.before.year, range.before.month, range.before.day,
    });
}

/// The request with the date expression removed, so it does not also become
/// a search term.
pub fn without(arena: std.mem.Allocator, text: []const u8, found: Found) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, std.mem.trimEnd(u8, text[0..found.start], " \t"));
    const tail = std.mem.trimStart(u8, text[found.end..], " \t");
    if (out.items.len > 0 and tail.len > 0) try out.append(arena, ' ');
    try out.appendSlice(arena, tail);

    // "... from the 24th of September" leaves a dangling "from the", so this
    // strips repeatedly rather than once: two filler words in a row is the
    // normal case, not the exception. They are filler in a search either way.
    var trimmed = std.mem.trim(u8, out.items, " \t,");
    var stripping = true;
    while (stripping) {
        stripping = false;
        for ([_][]const u8{ " from", " on", " in", " at", " of", " the", " dated", " sent" }) |word| {
            if (std.ascii.endsWithIgnoreCase(trimmed, word)) {
                trimmed = std.mem.trim(u8, trimmed[0 .. trimmed.len - word.len], " \t,");
                stripping = true;
                break;
            }
        }
    }
    return trimmed;
}

test "civil dates round-trip and shift across month and year ends" {
    const cases = [_]Day{
        .{ .year = 2026, .month = 9, .day = 24 },
        .{ .year = 2024, .month = 2, .day = 29 },
        .{ .year = 1970, .month = 1, .day = 1 },
        .{ .year = 2026, .month = 12, .day = 31 },
    };
    for (cases) |day| {
        try std.testing.expectEqual(day, Day.fromEpochDay(day.epochDay()));
    }

    // Across a month end, a year end, and a leap day.
    try std.testing.expectEqual(
        Day{ .year = 2026, .month = 10, .day = 1 },
        (Day{ .year = 2026, .month = 9, .day = 30 }).shift(1),
    );
    try std.testing.expectEqual(
        Day{ .year = 2026, .month = 1, .day = 1 },
        (Day{ .year = 2025, .month = 12, .day = 31 }).shift(1),
    );
    try std.testing.expectEqual(
        Day{ .year = 2024, .month = 2, .day = 29 },
        (Day{ .year = 2024, .month = 3, .day = 1 }).shift(-1),
    );
}

test "the date that broke the live search is read correctly" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const now: Day = .{ .year = 2026, .month = 9, .day = 25 };
    const question = "Find an email about Order Consolidated Job from the 24th of September";

    const found = find(now, question).?;
    // A day either side, for the timezone skew Gmail is documented to have.
    try std.testing.expectEqual(Day{ .year = 2026, .month = 9, .day = 23 }, found.range.after);
    try std.testing.expectEqual(Day{ .year = 2026, .month = 9, .day = 26 }, found.range.before);

    try std.testing.expectEqualStrings(
        "after:2026/09/23 before:2026/09/26",
        try render(arena, found.range),
    );

    // And the date must not also be searched for as words -- "24 September"
    // appears in almost no message sent on 24 September.
    try std.testing.expectEqualStrings(
        "Find an email about Order Consolidated Job",
        try without(arena, question, found),
    );
}

test "the shapes people actually write a date in" {
    const now: Day = .{ .year = 2026, .month = 9, .day = 25 };

    const cases = [_]struct { text: []const u8, day: Day }{
        .{ .text = "on 24 September", .day = .{ .year = 2026, .month = 9, .day = 24 } },
        .{ .text = "on September 24", .day = .{ .year = 2026, .month = 9, .day = 24 } },
        .{ .text = "24 Sept", .day = .{ .year = 2026, .month = 9, .day = 24 } },
        .{ .text = "24th Sep", .day = .{ .year = 2026, .month = 9, .day = 24 } },
        .{ .text = "dated 2026-09-24", .day = .{ .year = 2026, .month = 9, .day = 24 } },
        .{ .text = "sent 24/09/2026", .day = .{ .year = 2026, .month = 9, .day = 24 } },
        .{ .text = "sent 24/09", .day = .{ .year = 2026, .month = 9, .day = 24 } },
        // Said in September, "3rd of December" has to mean last year -- a
        // search forward from today can only ever return nothing.
        .{ .text = "the 3rd of December", .day = .{ .year = 2025, .month = 12, .day = 3 } },
    };
    for (cases) |case| {
        const found = find(now, case.text) orelse {
            std.debug.print("no date found in: {s}\n", .{case.text});
            return error.NoDateFound;
        };
        try std.testing.expectEqual(case.day.shift(-DAY_SLACK), found.range.after);
    }

    // Relative expressions.
    const yesterday = find(now, "did it arrive yesterday?").?;
    try std.testing.expectEqual(Day{ .year = 2026, .month = 9, .day = 23 }, yesterday.range.after);

    const week = find(now, "the email from last week").?;
    try std.testing.expectEqual(Day{ .year = 2026, .month = 9, .day = 17 }, week.range.after);

    // A bare month is that whole month.
    const august = find(now, "the invoice from August").?;
    try std.testing.expectEqual(Day{ .year = 2026, .month = 7, .day = 31 }, august.range.after);
    try std.testing.expectEqual(Day{ .year = 2026, .month = 9, .day = 2 }, august.range.before);
}

test "requests with no date in them are left alone" {
    const now: Day = .{ .year = 2026, .month = 9, .day = 25 };
    try std.testing.expectEqual(@as(?Found, null), find(now, "find the email about InfluxDB"));
    try std.testing.expectEqual(@as(?Found, null), find(now, "the thread about pricing"));
    // A number that is not a date must not become one.
    try std.testing.expectEqual(@as(?Found, null), find(now, "the email about RZPT-3989"));
}

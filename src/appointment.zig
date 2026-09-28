//! Reading *when* an appointment is out of the owner's own words.
//!
//! Same split as the rest of Ronny: Jev decides that the message is asking
//! for a calendar entry, code reads the day and the time, and the local model
//! is only asked for the thing a closed grammar cannot give -- a tidy title.
//! Then the whole thing is shown back and nothing lands on the calendar until
//! the owner types yes.
//!
//! The day and time are parsed here rather than by a model for the reason
//! dates.zig and the quiet-hours clock give: a date is a small closed
//! grammar, and a model that reads "next Thursday" as this Thursday puts the
//! appointment in the wrong week without saying so. Everything this module
//! reads is echoed in the preview, so a misread is visible before the yes.
//!
//! dates.zig looks *backwards* -- a search is for mail that already arrived
//! -- so it is reused for the pieces (months, numbers, the civil calendar)
//! but not for its resolution: "the 3rd of December" here means the next
//! one, not the last one.

const std = @import("std");
const dates = @import("dates.zig");
const ollama = @import("ollama.zig");

const log = std.log.scoped(.appointment);

pub const Day = dates.Day;

/// An hour when none is given: "lunch with Dana on Friday" is a one-hour
/// slot, and a wrong length is the cheapest thing to fix on the calendar.
pub const DEFAULT_DURATION_MINUTES: i16 = 60;

pub const When = struct {
    day: Day,
    /// Minutes since local midnight. Null is an all-day entry.
    start: ?i16 = null,
    end: ?i16 = null,
};

/// What was read, and the words that were left once the date and time were
/// cut out -- the raw material for a title.
pub const Found = struct {
    /// Null when no day was named. A time on its own is kept in `start` /
    /// `end` so a follow-up that only names the day can complete it.
    when: ?When,
    start: ?i16 = null,
    end: ?i16 = null,
    rest: []const u8,
};

const Span = struct { start: usize, end: usize };

// ---- word helpers ----

fn isWordByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch >= 0x80;
}

fn atWordStart(text: []const u8, i: usize) bool {
    return i == 0 or !isWordByte(text[i - 1]);
}

fn endsWord(text: []const u8, i: usize) bool {
    return i >= text.len or !isWordByte(text[i]);
}

/// `phrase` at `i`, as whole words.
fn phraseAt(text: []const u8, i: usize, phrase: []const u8) bool {
    if (!atWordStart(text, i)) return false;
    if (i + phrase.len > text.len) return false;
    if (!std.ascii.eqlIgnoreCase(text[i .. i + phrase.len], phrase)) return false;
    return endsWord(text, i + phrase.len);
}

/// The first whole-word occurrence of `phrase`.
fn findPhrase(text: []const u8, phrase: []const u8) ?usize {
    var i: usize = 0;
    while (i + phrase.len <= text.len) : (i += 1) {
        if (phraseAt(text, i, phrase)) return i;
    }
    return null;
}

fn skipSpaces(text: []const u8, i: usize) usize {
    var j = i;
    while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
    return j;
}

const Before = struct { word: []const u8, start: usize };

/// The word ending just before `i`, lowercased into `buffer`, and where it
/// starts, so a caller can extend a span back over it.
fn wordBefore(text: []const u8, i: usize, buffer: []u8) Before {
    var end = i;
    while (end > 0 and (text[end - 1] == ' ' or text[end - 1] == '\t')) end -= 1;
    var start = end;
    while (start > 0 and isWordByte(text[start - 1])) start -= 1;
    const word = text[start..end];
    if (word.len > buffer.len) return .{ .word = "", .start = i };
    for (word, 0..) |ch, k| buffer[k] = std.ascii.toLower(ch);
    return .{ .word = buffer[0..word.len], .start = start };
}

fn inList(word: []const u8, list: []const []const u8) bool {
    for (list) |candidate| {
        if (std.ascii.eqlIgnoreCase(word, candidate)) return true;
    }
    return false;
}

// ---- the day ----

/// 0 is Sunday. 1970-01-01 was a Thursday.
pub fn weekday(day: Day) u8 {
    return @intCast(@mod(day.epochDay() + 4, 7));
}

const WEEKDAYS = [_][]const u8{ "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" };
const WEEKDAYS_ES = [_][]const u8{ "domingo", "lunes", "martes", "miércoles", "jueves", "viernes", "sábado" };
const WEEKDAYS_ES_PLAIN = [_][]const u8{ "domingo", "lunes", "martes", "miercoles", "jueves", "viernes", "sabado" };
const MONTHS_ES = [_][]const u8{
    "enero", "febrero", "marzo",      "abril",   "mayo",      "junio",
    "julio", "agosto",  "septiembre", "octubre", "noviembre", "diciembre",
};

fn weekdayAt(text: []const u8, i: usize) ?struct { index: u8, len: usize } {
    if (!atWordStart(text, i)) return null;
    for (0..7) |w| {
        inline for (.{ WEEKDAYS[w], WEEKDAYS_ES[w], WEEKDAYS_ES_PLAIN[w] }) |name| {
            if (phraseAt(text, i, name)) return .{ .index = @intCast(w), .len = name.len };
        }
        // "thu", "fri": the English three-letter forms.
        if (phraseAt(text, i, WEEKDAYS[w][0..3])) return .{ .index = @intCast(w), .len = 3 };
    }
    return null;
}

fn monthAtEither(text: []const u8) ?struct { month: u8, len: usize } {
    // Spanish first: "octubre" and "marzo" would otherwise match the English
    // three-letter cut and leave "ubre" behind in the title.
    for (MONTHS_ES, 0..) |name, i| {
        if (text.len >= name.len and std.ascii.eqlIgnoreCase(text[0..name.len], name) and endsWord(text, name.len)) {
            return .{ .month = @intCast(i + 1), .len = name.len };
        }
    }
    // dates.zig matches prefixes, which is right for a search and wrong
    // here: "marketing" is not March.
    if (dates.monthAt(text)) |m| {
        if (endsWord(text, m.len)) return .{ .month = m.month, .len = m.len };
    }
    return null;
}

/// "de", "del", "el" in Spanish; the English fillers come from dates.zig.
fn skipFillerEither(text: []const u8) usize {
    var i = dates.skipFiller(text);
    var moved = true;
    while (moved) {
        moved = false;
        const j = skipSpaces(text, i);
        for ([_][]const u8{ "del", "de", "el" }) |word| {
            if (phraseAt(text, j, word)) {
                i = j + word.len;
                moved = true;
                break;
            }
        }
        if (!moved) i = j;
    }
    return i;
}

/// The next `month`/`day` on or after `now`. Said in October, "the 3rd of
/// December" is this year; said in December, next year.
fn upcoming(now: Day, month: u32, day: u32) ?Day {
    const this_year = dates.makeDay(now.year, month, day) orelse return null;
    if (this_year.order(now) != .lt) return this_year;
    return dates.makeDay(now.year + 1, month, day);
}

const DayFound = struct { day: Day, span: Span };

/// The first day expression in `text`, resolved forwards from `now`.
pub fn findDay(now: Day, text: []const u8) ?DayFound {
    // Fixed phrases first, longest first, so "day after tomorrow" is not
    // read as "tomorrow" with a stray "day after".
    const relative = [_]struct { phrase: []const u8, days: i32 }{
        .{ .phrase = "the day after tomorrow", .days = 2 },
        .{ .phrase = "day after tomorrow", .days = 2 },
        .{ .phrase = "pasado mañana", .days = 2 },
        .{ .phrase = "pasado manana", .days = 2 },
        .{ .phrase = "tomorrow", .days = 1 },
        .{ .phrase = "tmrw", .days = 1 },
        .{ .phrase = "today", .days = 0 },
        .{ .phrase = "tonight", .days = 0 },
        .{ .phrase = "hoy", .days = 0 },
        .{ .phrase = "esta noche", .days = 0 },
    };
    for (relative) |entry| {
        if (findPhrase(text, entry.phrase)) |at| {
            return .{ .day = now.shift(entry.days), .span = .{ .start = at, .end = at + entry.phrase.len } };
        }
    }
    // "mañana" is "tomorrow" unless it follows "por la" / "de la" / "esta",
    // when it is "morning". Checked after the fixed phrases so "pasado
    // mañana" has already been taken.
    for ([_][]const u8{ "mañana", "manana" }) |word| {
        var from: usize = 0;
        while (from < text.len) {
            const at = findPhraseFrom(text, word, from) orelse break;
            var buffer: [16]u8 = undefined;
            const before = wordBefore(text, at, &buffer).word;
            if (!inList(before, &.{ "la", "esta" })) {
                return .{ .day = now.shift(1), .span = .{ .start = at, .end = at + word.len } };
            }
            from = at + word.len;
        }
    }

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!atWordStart(text, i)) continue;
        const rest = text[i..];

        // "next thursday", "this friday", "el jueves", "el próximo jueves",
        // "on thu".
        if (weekdayAt(text, i)) |found| {
            var start = i;
            var strictly_after = false;
            var buffer: [16]u8 = undefined;
            const before = wordBefore(text, i, &buffer);
            if (inList(before.word, &.{ "next", "próximo", "proximo", "siguiente" })) {
                strictly_after = true;
                start = before.start;
            } else if (inList(before.word, &.{ "this", "este", "el", "on" })) {
                start = before.start;
            }
            // "el próximo jueves": the article before the qualifier.
            var buffer2: [16]u8 = undefined;
            const before2 = wordBefore(text, start, &buffer2);
            if (strictly_after and inList(before2.word, &.{ "el", "the" })) start = before2.start;

            const today = weekday(now);
            var ahead: i32 = @as(i32, found.index) - @as(i32, today);
            if (ahead < 0 or (ahead == 0 and strictly_after)) ahead += 7;
            return .{ .day = now.shift(ahead), .span = .{ .start = start, .end = i + found.len } };
        }

        // "24 October", "24th of October", "24 de octubre", "24/10", "2026-10-24"
        if (dates.readNumber(rest)) |first| {
            const after_first = rest[first.len..];
            if (after_first.len > 1 and (after_first[0] == '/' or after_first[0] == '-')) {
                if (dates.readNumber(after_first[1..])) |second| {
                    const sep = after_first[0];
                    var tail = after_first[1 + second.len ..];
                    var third: ?u32 = null;
                    if (tail.len > 1 and tail[0] == sep) {
                        if (dates.readNumber(tail[1..])) |t| {
                            third = t.value;
                            tail = tail[1 + t.len ..];
                        }
                    }
                    const parsed: ?Day = if (first.len == 4)
                        dates.makeDay(first.value, second.value, third orelse 1)
                    else if (third) |year|
                        dates.makeDay(if (year < 100) 2000 + year else year, second.value, first.value)
                    else
                        upcoming(now, second.value, first.value);
                    if (parsed) |day| {
                        // A clock ("10-11") is two small numbers with no
                        // third part; a date has a month in range and, if
                        // it looks like a range, a slash. Refuse "10-11".
                        if (sep == '-' and third == null) {
                            // fallthrough to the time parser
                        } else {
                            return .{ .day = day, .span = .{ .start = i, .end = text.len - tail.len } };
                        }
                    }
                }
            }
            const skipped = skipFillerEither(after_first);
            if (monthAtEither(after_first[skipped..])) |month| {
                if (upcoming(now, month.month, first.value)) |day| {
                    return .{ .day = day, .span = .{ .start = i, .end = i + first.len + skipped + month.len } };
                }
            }
        }

        // "October 24"
        if (monthAtEither(rest)) |month| {
            const skipped = dates.skipFiller(rest[month.len..]);
            if (dates.readNumber(rest[month.len + skipped ..])) |number| {
                if (upcoming(now, month.month, number.value)) |day| {
                    return .{ .day = day, .span = .{ .start = i, .end = i + month.len + skipped + number.len } };
                }
            }
        }
    }
    return null;
}

fn findPhraseFrom(text: []const u8, phrase: []const u8, from: usize) ?usize {
    if (from >= text.len) return null;
    const at = findPhrase(text[from..], phrase) orelse return null;
    return from + at;
}

// ---- the time ----

const Clock = struct {
    minutes: i16,
    len: usize,
    /// Carried an am/pm, a colon, or an "h": unmistakably a clock time.
    explicit: bool,
};

/// A clock reading starting exactly at `text[0]`.
fn clockAt(text: []const u8) ?Clock {
    var i: usize = 0;
    while (i < text.len and std.ascii.isDigit(text[i]) and i < 2) i += 1;
    if (i == 0) return null;
    var hours = std.fmt.parseInt(i16, text[0..i], 10) catch return null;
    var minutes: i16 = 0;
    var explicit = false;

    if (i + 2 < text.len and (text[i] == ':' or text[i] == '.') and
        std.ascii.isDigit(text[i + 1]) and std.ascii.isDigit(text[i + 2]))
    {
        minutes = std.fmt.parseInt(i16, text[i + 1 .. i + 3], 10) catch return null;
        i += 3;
        explicit = true;
    }
    // A time never runs straight into more digits ("2026").
    if (i < text.len and std.ascii.isDigit(text[i])) return null;

    const j = skipSpaces(text, i);
    if (j < text.len and (text[j] == 'h' or text[j] == 'H') and endsWord(text, j + 1)) {
        i = j + 1;
        explicit = true;
    } else if (j + 1 < text.len and std.ascii.eqlIgnoreCase(text[j .. j + 2], "pm") and endsWord(text, j + 2)) {
        if (hours < 12) hours += 12;
        i = j + 2;
        explicit = true;
    } else if (j + 1 < text.len and std.ascii.eqlIgnoreCase(text[j .. j + 2], "am") and endsWord(text, j + 2)) {
        if (hours == 12) hours = 0;
        i = j + 2;
        explicit = true;
    } else if (j + 3 < text.len and std.ascii.eqlIgnoreCase(text[j .. j + 4], "p.m.")) {
        if (hours < 12) hours += 12;
        i = j + 4;
        explicit = true;
    } else if (j + 3 < text.len and std.ascii.eqlIgnoreCase(text[j .. j + 4], "a.m.")) {
        if (hours == 12) hours = 0;
        i = j + 4;
        explicit = true;
    } else {
        // Spanish: "de la tarde" / "de la noche" are pm, "de la mañana" am.
        const es = [_]struct { phrase: []const u8, pm: bool }{
            .{ .phrase = "de la tarde", .pm = true },
            .{ .phrase = "de la noche", .pm = true },
            .{ .phrase = "de la mañana", .pm = false },
            .{ .phrase = "de la manana", .pm = false },
            .{ .phrase = "de la madrugada", .pm = false },
            .{ .phrase = "in the afternoon", .pm = true },
            .{ .phrase = "in the evening", .pm = true },
            .{ .phrase = "in the morning", .pm = false },
        };
        for (es) |entry| {
            if (phraseAt(text, j, entry.phrase)) {
                if (entry.pm and hours < 12) hours += 12;
                if (!entry.pm and hours == 12) hours = 0;
                i = j + entry.phrase.len;
                explicit = true;
                break;
            }
        }
    }
    if (hours < 0 or hours > 23 or minutes > 59) return null;
    return .{ .minutes = hours * 60 + minutes, .len = i, .explicit = explicit };
}

const TimeFound = struct { start: i16, end: ?i16, span: Span };

const NAMED_TIMES = [_]struct { phrase: []const u8, minutes: i16 }{
    .{ .phrase = "at noon", .minutes = 12 * 60 },
    .{ .phrase = "at midday", .minutes = 12 * 60 },
    .{ .phrase = "at midnight", .minutes = 0 },
    .{ .phrase = "a mediodía", .minutes = 12 * 60 },
    .{ .phrase = "a mediodia", .minutes = 12 * 60 },
    .{ .phrase = "a medianoche", .minutes = 0 },
    .{ .phrase = "noon", .minutes = 12 * 60 },
    .{ .phrase = "midday", .minutes = 12 * 60 },
    .{ .phrase = "midnight", .minutes = 0 },
};

/// Words that make a bare number a time: "at 3", "a las 3", "from 10 to 11".
const TIME_LEADS = [_][]const u8{ "at", "las", "la", "from", "de", "between", "entre", "@" };
const RANGE_LINKS = [_][]const u8{ "to", "until", "till", "and", "a", "hasta", "y" };

/// The first time expression in `text`.
pub fn findTime(text: []const u8) ?TimeFound {
    for (NAMED_TIMES) |entry| {
        if (findPhrase(text, entry.phrase)) |at| {
            return .{ .start = entry.minutes, .end = null, .span = .{ .start = at, .end = at + entry.phrase.len } };
        }
    }

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!atWordStart(text, i) or !std.ascii.isDigit(text[i])) continue;
        const first = clockAt(text[i..]) orelse continue;

        var buffer: [16]u8 = undefined;
        const lead = wordBefore(text, i, &buffer);
        const led = inList(lead.word, &TIME_LEADS);

        var span_start = i;
        if (led) {
            span_start = lead.start;
            // "a las 3": the article and the preposition both go.
            var buffer2: [16]u8 = undefined;
            const lead2 = wordBefore(text, span_start, &buffer2);
            if (inList(lead2.word, &.{ "a", "at", "from", "de" }) and inList(lead.word, &.{ "las", "la" })) span_start = lead2.start;
        }
        var end_at = i + first.len;

        // A range: "10 to 11", "10-11", "3 and 4", "de 10 a 11".
        var second: ?Clock = null;
        var j = skipSpaces(text, end_at);
        if (j < text.len and (text[j] == '-' or std.mem.startsWith(u8, text[j..], "\xE2\x80\x93"))) {
            j = skipSpaces(text, j + (if (text[j] == '-') @as(usize, 1) else 3));
            if (j < text.len and std.ascii.isDigit(text[j])) second = clockAt(text[j..]);
        } else {
            for (RANGE_LINKS) |link| {
                if (phraseAt(text, j, link)) {
                    const k = skipSpaces(text, j + link.len);
                    if (k < text.len and std.ascii.isDigit(text[k])) {
                        second = clockAt(text[k..]);
                        j = k;
                    }
                    break;
                }
            }
        }

        // A bare number is a time only when something marks it as one: a
        // lead word, or a range whose far end is unmistakable ("3 to 4pm").
        const marked_by_range = if (second) |s| s.explicit else false;
        if (!first.explicit and !led and !marked_by_range) continue;

        var start = first.minutes;
        var end: ?i16 = null;
        if (second) |s| {
            end = s.minutes;
            end_at = j + s.len;
            // "3 to 4pm": the first side inherits the afternoon.
            if (!first.explicit and s.explicit and s.minutes >= 12 * 60 and start < 12 * 60 and start + 12 * 60 <= s.minutes) {
                start += 12 * 60;
            }
            if (end.? <= start) end = null;
        }
        return .{ .start = start, .end = end, .span = .{ .start = span_start, .end = end_at } };
    }
    return null;
}

const DurationFound = struct { minutes: i16, span: Span };

/// "for an hour", "for 2 hours", "for 45 minutes", "half an hour", "1h",
/// "durante una hora", "de dos horas", "hora y media".
pub fn findDuration(text: []const u8) ?DurationFound {
    const fixed = [_]struct { phrase: []const u8, minutes: i16 }{
        .{ .phrase = "for an hour and a half", .minutes = 90 },
        .{ .phrase = "for one and a half hours", .minutes = 90 },
        .{ .phrase = "an hour and a half", .minutes = 90 },
        .{ .phrase = "for half an hour", .minutes = 30 },
        .{ .phrase = "half an hour", .minutes = 30 },
        .{ .phrase = "for an hour", .minutes = 60 },
        .{ .phrase = "for one hour", .minutes = 60 },
        .{ .phrase = "for 1 hour", .minutes = 60 },
        .{ .phrase = "durante una hora y media", .minutes = 90 },
        .{ .phrase = "de una hora y media", .minutes = 90 },
        .{ .phrase = "una hora y media", .minutes = 90 },
        .{ .phrase = "hora y media", .minutes = 90 },
        .{ .phrase = "durante media hora", .minutes = 30 },
        .{ .phrase = "de media hora", .minutes = 30 },
        .{ .phrase = "media hora", .minutes = 30 },
        .{ .phrase = "durante una hora", .minutes = 60 },
        .{ .phrase = "de una hora", .minutes = 60 },
        .{ .phrase = "una hora", .minutes = 60 },
    };
    for (fixed) |entry| {
        if (findPhrase(text, entry.phrase)) |at| {
            return .{ .minutes = entry.minutes, .span = .{ .start = at, .end = at + entry.phrase.len } };
        }
    }

    const units = [_]struct { word: []const u8, minutes: i16 }{
        .{ .word = "hours", .minutes = 60 },   .{ .word = "hour", .minutes = 60 },
        .{ .word = "hrs", .minutes = 60 },     .{ .word = "hr", .minutes = 60 },
        .{ .word = "horas", .minutes = 60 },   .{ .word = "hora", .minutes = 60 },
        .{ .word = "minutes", .minutes = 1 },  .{ .word = "minute", .minutes = 1 },
        .{ .word = "mins", .minutes = 1 },     .{ .word = "min", .minutes = 1 },
        .{ .word = "minutos", .minutes = 1 },  .{ .word = "h", .minutes = 60 },
        .{ .word = "m", .minutes = 1 },
    };
    const number_words = [_]struct { word: []const u8, value: i16 }{
        .{ .word = "two", .value = 2 },    .{ .word = "three", .value = 3 },
        .{ .word = "four", .value = 4 },   .{ .word = "dos", .value = 2 },
        .{ .word = "tres", .value = 3 },   .{ .word = "cuatro", .value = 4 },
    };

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!atWordStart(text, i)) continue;
        var value: ?i16 = null;
        var value_len: usize = 0;
        if (dates.readNumber(text[i..])) |n| {
            if (n.value > 0 and n.value <= 600) {
                value = @intCast(n.value);
                value_len = n.len;
            }
        } else {
            for (number_words) |entry| {
                if (phraseAt(text, i, entry.word)) {
                    value = entry.value;
                    value_len = entry.word.len;
                    break;
                }
            }
        }
        const amount = value orelse continue;
        const after = skipSpaces(text, i + value_len);
        for (units) |unit| {
            if (unit.word.len == 1) {
                // A bare "h"/"m" only counts glued to the number ("2h"), not
                // as a word of its own -- and glued means it is not at a
                // word start, so it is matched by hand.
                if (after != i + value_len) continue;
                if (after >= text.len or std.ascii.toLower(text[after]) != unit.word[0] or !endsWord(text, after + 1)) continue;
            } else if (!phraseAt(text, after, unit.word)) continue;
            // "for 2 hours": take the "for"/"durante"/"de" in front too.
            var start = i;
            var buffer: [16]u8 = undefined;
            const lead = wordBefore(text, i, &buffer);
            if (inList(lead.word, &.{ "for", "durante", "de", "lasting" })) start = lead.start;
            const total = amount * unit.minutes;
            if (total <= 0 or total > 24 * 60) return null;
            return .{ .minutes = total, .span = .{ .start = start, .end = after + unit.word.len } };
        }
    }
    return null;
}

// ---- putting it together ----

fn cut(arena: std.mem.Allocator, text: []const u8, span: Span) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, std.mem.trimEnd(u8, text[0..span.start], " \t"));
    const tail = std.mem.trimStart(u8, text[span.end..], " \t");
    if (out.items.len > 0 and tail.len > 0) try out.append(arena, ' ');
    try out.appendSlice(arena, tail);
    return out.items;
}

/// Reads the day, the time and the length out of `text`. A missing day
/// leaves `when` null -- it is asked about, never guessed.
pub fn find(arena: std.mem.Allocator, now: Day, text: []const u8) !Found {
    var rest = text;
    const day = findDay(now, text);
    if (day) |d| rest = try cut(arena, text, d.span);

    var start: ?i16 = null;
    var end: ?i16 = null;
    if (findTime(rest)) |time| {
        start = time.start;
        end = time.end;
        rest = try cut(arena, rest, time.span);
    }
    if (findDuration(rest)) |duration| {
        if (start != null and end == null) end = start.? + duration.minutes;
        rest = try cut(arena, rest, duration.span);
    }
    if (start != null and end == null) end = start.? + DEFAULT_DURATION_MINUTES;
    // Past midnight would be the next day on the calendar; cap it instead.
    if (end) |e| {
        if (e > 24 * 60) end = 24 * 60;
    }
    return .{
        .when = if (day) |d| .{ .day = d.day, .start = start, .end = end } else null,
        .start = start,
        .end = end,
        .rest = rest,
    };
}

/// The words the owner used with the command scaffolding stripped: "add a
/// meeting with Dana to my calendar" becomes "meeting with Dana". Used as the
/// title when the local model is down or produces something not in the
/// request.
pub fn fallbackTitle(arena: std.mem.Allocator, rest: []const u8) ![]const u8 {
    var text = rest;
    // Phrases anywhere.
    const anywhere = [_][]const u8{
        "to my calendar",  "in my calendar",  "on my calendar", "to the calendar",
        "in the calendar", "on the calendar", "to my agenda",   "en mi calendario",
        "en el calendario", "en mi agenda",   "a mi calendario", "al calendario",
        "please",          "por favor",
    };
    for (anywhere) |phrase| {
        while (findPhrase(text, phrase)) |at| {
            text = try cut(arena, text, .{ .start = at, .end = at + phrase.len });
        }
    }
    // Leading scaffolding, word by word.
    const leading = [_][]const u8{
        "add",     "create",  "schedule", "book",   "put",    "set",     "make",   "new",
        "an",      "a",       "the",      "event",  "entry",  "to",      "on",     "in",
        "at",      "for",     "my",       "me",     "remind", "of",      "that",   "i",
        "have",    "i've",    "got",      "up",     "calendar", "appointment", "reminder",
        "apunta",  "apúntame", "añade",   "agrega", "crea",   "pon",     "ponme",  "programa",
        "una",     "un",      "el",       "la",     "en",     "mi",      "cita",   "evento",
        "recuérdame", "recuerdame", "que", "tengo",  "and",    "y",       "with",   "con",
    };
    var stripping = true;
    while (stripping) {
        stripping = false;
        text = std.mem.trim(u8, text, " \t,.:;-");
        for (leading) |word| {
            if (phraseAt(text, 0, word)) {
                // Keep "meeting with Dana": "with" only goes when nothing
                // else would be left in front of it.
                if (inList(word, &.{ "with", "con", "and", "y" }) and text.len > word.len) break;
                text = text[word.len..];
                stripping = true;
                break;
            }
        }
    }
    // Trailing prepositions left behind by the cuts.
    var trailing = true;
    while (trailing) {
        trailing = false;
        text = std.mem.trim(u8, text, " \t,.:;-");
        for ([_][]const u8{ " on", " at", " for", " from", " in", " the", " a", " el", " la", " en", " de", " to" }) |word| {
            if (std.ascii.endsWithIgnoreCase(text, word)) {
                text = text[0 .. text.len - word.len];
                trailing = true;
                break;
            }
        }
    }
    text = std.mem.trim(u8, text, " \t,.:;-");
    if (text.len == 0) return "Appointment";

    const out = try arena.dupe(u8, text);
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

pub const Details = struct {
    title: []const u8,
    location: []const u8 = "",
};

/// Strips everything but letters and digits, lowercased, so a title the
/// model tidied ("Dentist.") still compares against what was said.
fn squash(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |ch| {
        if (std.ascii.isAlphanumeric(ch)) try out.append(arena, std.ascii.toLower(ch));
    }
    return out.items;
}

/// A title is accepted if it is made of the owner's words: every word of
/// three letters or more appears in the request. Otherwise it was produced
/// rather than extracted -- the same shape as an invented address -- and the
/// scaffolding-stripped request is used instead.
pub fn titleIsFromRequest(arena: std.mem.Allocator, request: []const u8, title: []const u8) !bool {
    const haystack = try squash(arena, request);
    var any = false;
    var words = std.mem.tokenizeAny(u8, title, " \t,.:;-()'\"");
    while (words.next()) |word| {
        const needle = try squash(arena, word);
        if (needle.len < 3) continue;
        any = true;
        if (std.mem.indexOf(u8, haystack, needle) == null) return false;
    }
    return any;
}

const TITLE_PROMPT =
    \\A user asked an assistant to add an appointment to their calendar. Give the entry a short title and, if the request names a place, the place. Respond with ONLY a JSON object: {"title": "<the appointment, in the user's own words, 2-6 words, no date, no time, no verbs like add or schedule -- e.g. 'Dentist', 'Meeting with Dana', 'Lunch with Sam'>", "location": "<the place exactly as written in the request, or null if none is named>"}
    \\
    \\Rules:
    \\- Use ONLY words that appear in the request. Never add a name, a place or a topic that is not there.
    \\- The title carries no date or time: those are stored separately.
    \\- Keep the request's language (English or Spanish).
    \\
    \\Request:
;

/// Asks the local model for a title and a place, and keeps only what it can
/// show was in the request. Never fails: the fallback is always available.
pub fn details(
    io: std.Io,
    arena: std.mem.Allocator,
    ollama_url: []const u8,
    model: []const u8,
    request: []const u8,
    rest: []const u8,
) !Details {
    const fallback: Details = .{ .title = try fallbackTitle(arena, rest) };

    const prompt = try std.fmt.allocPrint(arena, "{s} {s}", .{ TITLE_PROMPT, request });
    const answer = ollama.generateJson(io, arena, ollama_url, model, prompt) catch {
        log.warn("local model unavailable for the title; using the owner's words", .{});
        return fallback;
    };
    const object = switch (answer) {
        .object => |o| o,
        else => return fallback,
    };

    var out = fallback;
    if (object.get("title")) |value| {
        if (value == .string) {
            const title = std.mem.trim(u8, value.string, " \t\r\n\"");
            // A digit is a time or a date leaking into the title.
            const has_digit = std.mem.indexOfAny(u8, title, "0123456789") != null;
            if (title.len > 0 and title.len <= 80 and !has_digit and try titleIsFromRequest(arena, request, title)) {
                out.title = try arena.dupe(u8, title);
            } else {
                log.info("model title \"{s}\" is not made of the owner's words; using \"{s}\"", .{ title, fallback.title });
            }
        }
    }
    if (object.get("location")) |value| {
        if (value == .string) {
            const place = std.mem.trim(u8, value.string, " \t\r\n\"");
            const nullish = inList(place, &.{ "null", "none", "n/a", "" });
            if (!nullish and try titleIsFromRequest(arena, request, place)) {
                out.location = try arena.dupe(u8, place);
            }
        }
    }
    return out;
}

// ---- picking one entry out of a day ----

/// What a removal can be matched against: the day's real entries.
pub const Candidate = struct {
    title: []const u8,
    start: ?i16,
};

const ORDINALS = [_][]const u8{ "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth" };
const ORDINALS_ES = [_][]const u8{ "primera", "segunda", "tercera", "cuarta", "quinta", "sexta", "séptima", "octava", "novena", "décima" };

/// "2", "the second one", "number 2", "la segunda": an index into a list
/// of `count`. Only for a short answer to "which one?", so a number inside
/// a longer request is not taken as a pick.
pub fn pickByNumber(text: []const u8, count: usize) ?usize {
    var words: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t,.!?");
    while (it.next()) |_| words += 1;
    if (words == 0 or words > 4) return null;

    it = std.mem.tokenizeAny(u8, text, " \t,.!?");
    while (it.next()) |word| {
        if (std.fmt.parseInt(usize, word, 10)) |n| {
            if (n >= 1 and n <= count) return n - 1;
        } else |_| {}
        for (ORDINALS, 0..) |name, i| {
            if (std.ascii.eqlIgnoreCase(word, name) and i < count) return i;
        }
        for (ORDINALS_ES, 0..) |name, i| {
            if (std.ascii.eqlIgnoreCase(word, name) and i < count) return i;
        }
    }
    return null;
}

/// Which of the day's entries the owner means. Deterministic: a time named
/// in the request narrows to entries starting then; the words of an entry's
/// title found in the request score it; a single clear winner is picked.
/// Null means ask -- guessing wrong here deletes the wrong appointment.
pub fn pick(arena: std.mem.Allocator, candidates: []const Candidate, text: []const u8, start: ?i16) !?usize {
    if (candidates.len == 0) return null;

    const haystack = try squash(arena, text);
    var best: ?usize = null;
    var best_score: usize = 0;
    var tied = false;
    var at_time: usize = 0;
    var last_at_time: usize = 0;

    for (candidates, 0..) |candidate, i| {
        const matches_time = start != null and candidate.start != null and candidate.start.? == start.?;
        if (matches_time) {
            at_time += 1;
            last_at_time = i;
        }
        // Words of the title present in the request.
        var score: usize = 0;
        var words = std.mem.tokenizeAny(u8, candidate.title, " \t,.:;-()'\"");
        while (words.next()) |word| {
            const needle = try squash(arena, word);
            if (needle.len < 3) continue;
            if (std.mem.indexOf(u8, haystack, needle) != null) score += 1;
        }
        // A time match on its own outranks nothing; with words it settles
        // a tie between two entries sharing a word.
        if (matches_time and score > 0) score += 10;
        if (score > best_score) {
            best = i;
            best_score = score;
            tied = false;
        } else if (score == best_score and score > 0) {
            tied = true;
        }
    }
    if (best != null and !tied) return best;
    // No words matched, but exactly one entry sits at the named time.
    if (best_score == 0 and at_time == 1) return last_at_time;
    // One entry on the day and nothing said against it.
    if (best_score == 0 and start == null and candidates.len == 1) return 0;
    return null;
}

test "an entry is picked by its words, its time, or by being the only one" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const day = [_]Candidate{
        .{ .title = "Sam's birthday", .start = null },
        .{ .title = "Free time", .start = 16 * 60 },
        .{ .title = "Meeting with Dana", .start = 10 * 60 },
        .{ .title = "Meeting with Sam", .start = 12 * 60 },
    };
    // The request that was refused live.
    try std.testing.expectEqual(@as(?usize, 1), try pick(arena, &day, "Remove today's appointment from 4pm to 5pm, that says free time.", 16 * 60));
    // Time alone, nothing else said.
    try std.testing.expectEqual(@as(?usize, 2), try pick(arena, &day, "delete the one at 10", 10 * 60));
    // Shared word, settled by the time.
    try std.testing.expectEqual(@as(?usize, 3), try pick(arena, &day, "remove the meeting at 12", 12 * 60));
    // Shared word, no time: ambiguous, so ask.
    try std.testing.expectEqual(@as(?usize, null), try pick(arena, &day, "remove the meeting today", null));
    // Nothing matches: ask.
    try std.testing.expectEqual(@as(?usize, null), try pick(arena, &day, "remove the dentist", null));
    // A day with one entry and no clue at all.
    const one = [_]Candidate{.{ .title = "Dentist", .start = 9 * 60 }};
    try std.testing.expectEqual(@as(?usize, 0), try pick(arena, &one, "remove tomorrow's appointment", null));

    try std.testing.expectEqual(@as(?usize, 1), pickByNumber("2", 4));
    try std.testing.expectEqual(@as(?usize, 1), pickByNumber("the second one", 4));
    try std.testing.expectEqual(@as(?usize, 2), pickByNumber("la tercera", 4));
    try std.testing.expectEqual(@as(?usize, null), pickByNumber("7", 4));
    try std.testing.expectEqual(@as(?usize, null), pickByNumber("remove the one at 2 in the afternoon please", 4));
}

// ---- showing it back ----

const DAY_NAMES = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const MONTH_NAMES = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

fn writeClock(writer: *std.Io.Writer, minutes: i16) !void {
    // Unsigned on purpose: a signed value with zero padding prints "+15:+0".
    // settings.formatTime hit the same thing.
    const hours: u8 = @intCast(@divTrunc(minutes, 60));
    const mins: u8 = @intCast(@mod(minutes, 60));
    try writer.print("{d:0>2}:{d:0>2}", .{ hours, mins });
}

/// "10:00-11:00", or "10:00      " when there is no end, padded so a list
/// of them lines up.
pub fn clockRange(arena: std.mem.Allocator, start: i16, end: ?i16) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeClock(&out.writer, start);
    if (end) |e| {
        try out.writer.writeAll("-");
        try writeClock(&out.writer, e);
    } else {
        try out.writer.writeAll("      ");
    }
    return out.written();
}

/// "Thu 1 Oct 2026, 15:00-16:00" or "Thu 1 Oct 2026, all day". What the
/// owner reads before saying yes, so it says everything that will be sent.
pub fn describe(arena: std.mem.Allocator, when: When) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("{s} {d} {s} {d}", .{
        DAY_NAMES[weekday(when.day)], when.day.day, MONTH_NAMES[when.day.month - 1], when.day.year,
    });
    if (when.start) |start| {
        try out.writer.writeAll(", ");
        try writeClock(&out.writer, start);
        if (when.end) |end| {
            try out.writer.writeAll("-");
            try writeClock(&out.writer, end);
        }
    } else {
        try out.writer.writeAll(", all day");
    }
    return out.written();
}

// ---- tests ----

const NOW: Day = .{ .year = 2026, .month = 9, .day = 27 }; // a Sunday

test "weekdays are computed from the civil calendar" {
    try std.testing.expectEqual(@as(u8, 4), weekday(.{ .year = 1970, .month = 1, .day = 1 })); // Thursday
    try std.testing.expectEqual(@as(u8, 0), weekday(NOW)); // Sunday
    try std.testing.expectEqual(@as(u8, 4), weekday(.{ .year = 2026, .month = 10, .day = 1 })); // Thursday
}

test "relative days and weekdays resolve forwards" {
    const cases = [_]struct { text: []const u8, day: Day }{
        .{ .text = "dentist tomorrow at 3pm", .day = .{ .year = 2026, .month = 9, .day = 28 } },
        .{ .text = "call today at 5", .day = .{ .year = 2026, .month = 9, .day = 27 } },
        .{ .text = "the day after tomorrow", .day = .{ .year = 2026, .month = 9, .day = 29 } },
        // Sunday: "thursday" is this coming Thursday; "next thursday" is the
        // same day, since it is strictly after today either way.
        .{ .text = "meeting on thursday", .day = .{ .year = 2026, .month = 10, .day = 1 } },
        .{ .text = "meeting next thursday", .day = .{ .year = 2026, .month = 10, .day = 1 } },
        // Today is Sunday: bare "sunday" is today, "next sunday" a week on.
        .{ .text = "lunch on sunday", .day = .{ .year = 2026, .month = 9, .day = 27 } },
        .{ .text = "lunch next sunday", .day = .{ .year = 2026, .month = 10, .day = 4 } },
        .{ .text = "reunión el jueves a las 10", .day = .{ .year = 2026, .month = 10, .day = 1 } },
        .{ .text = "cita mañana a las 9", .day = .{ .year = 2026, .month = 9, .day = 28 } },
        .{ .text = "pasado mañana", .day = .{ .year = 2026, .month = 9, .day = 29 } },
        // Dates without a year go to the next occurrence.
        .{ .text = "on 24 October", .day = .{ .year = 2026, .month = 10, .day = 24 } },
        .{ .text = "on the 3rd of March", .day = .{ .year = 2027, .month = 3, .day = 3 } },
        .{ .text = "el 24 de octubre", .day = .{ .year = 2026, .month = 10, .day = 24 } },
        .{ .text = "October 24 at 10", .day = .{ .year = 2026, .month = 10, .day = 24 } },
        .{ .text = "on 24/10 at 10", .day = .{ .year = 2026, .month = 10, .day = 24 } },
        .{ .text = "on 2026-11-05", .day = .{ .year = 2026, .month = 11, .day = 5 } },
        .{ .text = "on 5/1/2027", .day = .{ .year = 2027, .month = 1, .day = 5 } },
    };
    for (cases) |case| {
        const found = findDay(NOW, case.text) orelse {
            std.debug.print("no day found in: {s}\n", .{case.text});
            return error.NoDayFound;
        };
        if (found.day.order(case.day) != .eq) {
            std.debug.print("{s}: got {d}-{d}-{d}\n", .{ case.text, found.day.year, found.day.month, found.day.day });
            return error.WrongDay;
        }
    }
}

test "the Spanish morning is not tomorrow" {
    // "mañana por la mañana": the first is the day, the second the time of
    // day. Only one span may be taken as the day.
    const found = findDay(NOW, "cita mañana por la mañana a las 9").?;
    try std.testing.expectEqual(@as(u8, 28), found.day.day);
    try std.testing.expectEqual(@as(usize, 5), found.span.start);
    // Alone after "la" it is the morning, not a day.
    try std.testing.expectEqual(@as(?DayFound, null), findDay(NOW, "cita por la mañana"));
}

test "times in the shapes people write them" {
    const cases = [_]struct { text: []const u8, start: i16, end: ?i16 }{
        .{ .text = "dentist at 3pm", .start = 15 * 60, .end = null },
        .{ .text = "dentist at 3 pm", .start = 15 * 60, .end = null },
        .{ .text = "dentist at 15:30", .start = 15 * 60 + 30, .end = null },
        .{ .text = "dentist 15h", .start = 15 * 60, .end = null },
        .{ .text = "dentist at 3", .start = 3 * 60, .end = null },
        .{ .text = "dentist from 10 to 11", .start = 10 * 60, .end = 11 * 60 },
        .{ .text = "dentist 10:00-11:30", .start = 10 * 60, .end = 11 * 60 + 30 },
        .{ .text = "dentist 3 to 4pm", .start = 15 * 60, .end = 16 * 60 },
        .{ .text = "dentist between 3 and 4pm", .start = 15 * 60, .end = 16 * 60 },
        .{ .text = "call at noon", .start = 12 * 60, .end = null },
        .{ .text = "at 12am", .start = 0, .end = null },
        .{ .text = "at 12pm", .start = 12 * 60, .end = null },
        .{ .text = "a las 3 de la tarde", .start = 15 * 60, .end = null },
        .{ .text = "a las 9 de la mañana", .start = 9 * 60, .end = null },
        .{ .text = "de 10 a 11", .start = 10 * 60, .end = 11 * 60 },
        .{ .text = "a las 15:30", .start = 15 * 60 + 30, .end = null },
        .{ .text = "at 5 in the afternoon", .start = 17 * 60, .end = null },
    };
    for (cases) |case| {
        const found = findTime(case.text) orelse {
            std.debug.print("no time found in: {s}\n", .{case.text});
            return error.NoTimeFound;
        };
        try std.testing.expectEqual(case.start, found.start);
        try std.testing.expectEqual(case.end, found.end);
    }
    // A bare number with nothing marking it as a clock is not one.
    try std.testing.expectEqual(@as(?TimeFound, null), findTime("meeting room 3"));
    try std.testing.expectEqual(@as(?TimeFound, null), findTime("dentist for 2 hours"));
    try std.testing.expectEqual(@as(?TimeFound, null), findTime("order 2026"));
}

test "durations" {
    const cases = [_]struct { text: []const u8, minutes: i16 }{
        .{ .text = "for an hour", .minutes = 60 },
        .{ .text = "for 2 hours", .minutes = 120 },
        .{ .text = "for two hours", .minutes = 120 },
        .{ .text = "for 45 minutes", .minutes = 45 },
        .{ .text = "for 30 min", .minutes = 30 },
        .{ .text = "half an hour", .minutes = 30 },
        .{ .text = "an hour and a half", .minutes = 90 },
        .{ .text = "2h", .minutes = 120 },
        .{ .text = "durante una hora", .minutes = 60 },
        .{ .text = "de dos horas", .minutes = 120 },
        .{ .text = "hora y media", .minutes = 90 },
    };
    for (cases) |case| {
        const found = findDuration(case.text) orelse {
            std.debug.print("no duration found in: {s}\n", .{case.text});
            return error.NoDurationFound;
        };
        try std.testing.expectEqual(case.minutes, found.minutes);
    }
    try std.testing.expectEqual(@as(?DurationFound, null), findDuration("meeting at 3pm"));
}

test "the whole request: day, time, length, and what is left for the title" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try find(arena, NOW, "add a meeting with Dana next thursday at 3pm for 2 hours to my calendar");
    try std.testing.expectEqual(@as(u8, 1), found.when.?.day.day);
    try std.testing.expectEqual(@as(u8, 10), found.when.?.day.month);
    try std.testing.expectEqual(@as(?i16, 15 * 60), found.when.?.start);
    try std.testing.expectEqual(@as(?i16, 17 * 60), found.when.?.end);
    try std.testing.expectEqualStrings("Meeting with Dana", try fallbackTitle(arena, found.rest));
    try std.testing.expectEqualStrings("Thu 1 Oct 2026, 15:00-17:00", try describe(arena, found.when.?));

    // No time: all day, and said so.
    const all_day = try find(arena, NOW, "put Sam's birthday on 24 October in my calendar");
    try std.testing.expectEqual(@as(?i16, null), all_day.when.?.start);
    try std.testing.expectEqualStrings("Sat 24 Oct 2026, all day", try describe(arena, all_day.when.?));
    try std.testing.expectEqualStrings("Sam's birthday", try fallbackTitle(arena, all_day.rest));

    // Default length is an hour.
    const dentist = try find(arena, NOW, "dentist tomorrow at 9:30");
    try std.testing.expectEqual(@as(?i16, 9 * 60 + 30), dentist.when.?.start);
    try std.testing.expectEqual(@as(?i16, 10 * 60 + 30), dentist.when.?.end);
    try std.testing.expectEqualStrings("Dentist", try fallbackTitle(arena, dentist.rest));

    // Spanish end to end.
    const es = try find(arena, NOW, "apunta una reunión con Vicente el jueves a las 10 de la mañana");
    try std.testing.expectEqual(@as(u8, 1), es.when.?.day.day);
    try std.testing.expectEqual(@as(?i16, 10 * 60), es.when.?.start);
    try std.testing.expectEqualStrings("Reunión con Vicente", try fallbackTitle(arena, es.rest));

    // No day at all: nothing is guessed, but the time is kept for the
    // follow-up that names the day.
    const no_day = try find(arena, NOW, "add a meeting with Dana at 3pm");
    try std.testing.expectEqual(@as(?When, null), no_day.when);
    try std.testing.expectEqual(@as(?i16, 15 * 60), no_day.start);
    try std.testing.expectEqualStrings("Meeting with Dana", try fallbackTitle(arena, no_day.rest));
}

test "a title the model made up is rejected, one from the request is kept" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const request = "schedule the dentist tomorrow at 3pm";
    try std.testing.expect(try titleIsFromRequest(arena, request, "Dentist"));
    try std.testing.expect(try titleIsFromRequest(arena, request, "Dentist appointment") == false);
    try std.testing.expect(try titleIsFromRequest(arena, request, "Dr. Smith") == false);
    // Punctuation and case do not matter.
    try std.testing.expect(try titleIsFromRequest(arena, "Meeting with Dana, thursday", "meeting with dana."));
}

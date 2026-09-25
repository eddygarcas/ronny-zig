//! The knobs the owner can turn from chat.
//!
//! Everything here used to live in `.env` behind a restart, which meant that
//! changing "don't wake me before eight" required editing a file and
//! restarting a service — enough friction that it never got changed.
//!
//! Deliberately *not* here: anything on the send path. `voice_can_confirm_send`
//! stays in `.env` and needs a restart, because a spoken yes not being able to
//! send mail is a safety property, and a safety property that a chat message
//! can switch off is not one. Same reasoning for the model endpoints — a
//! mistyped URL from chat would silently disable the spam gate.

const std = @import("std");

const log = std.log.scoped(.settings);

/// Minutes since local midnight. Zig's standard library has no timezone
/// database, so libc answers this; see `ronny_local_minutes` in shim.c.
extern fn ronny_local_minutes() c_int;

pub const OFF: i16 = -1;

pub const Settings = struct {
    /// Quiet hours, as minutes since local midnight. OFF when unset.
    ///
    /// The watcher does not *drop* notifications during these hours, it stops
    /// scanning: the UID watermark stays put and everything that arrived is
    /// reported in one go when the window ends. Silently swallowing mail
    /// would be the obvious implementation and the wrong one.
    quiet_from: i16 = OFF,
    quiet_to: i16 = OFF,

    /// How far back the mail commands look when the request doesn't say.
    default_days: u16 = 14,

    pub fn quietEnabled(self: Settings) bool {
        return self.quiet_from != OFF and self.quiet_to != OFF;
    }

    /// Is `minutes` inside the quiet window?
    ///
    /// Handles the overnight case, which is the normal one: 22:00–08:00 wraps
    /// past midnight, so the test is "after the start *or* before the end"
    /// rather than "between".
    pub fn isQuietAt(self: Settings, minutes: i16) bool {
        if (!self.quietEnabled()) return false;
        if (self.quiet_from == self.quiet_to) return false;
        if (self.quiet_from < self.quiet_to) {
            return minutes >= self.quiet_from and minutes < self.quiet_to;
        }
        return minutes >= self.quiet_from or minutes < self.quiet_to;
    }

    pub fn isQuietNow(self: Settings) bool {
        const minutes = ronny_local_minutes();
        if (minutes < 0) return false; // can't tell the time: never suppress
        return self.isQuietAt(@intCast(minutes));
    }
};

pub const Store = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    current: Settings = .{},

    const max_bytes: std.Io.Limit = .limited(64 * 1024);

    pub fn init(io: std.Io, gpa: std.mem.Allocator, path: []const u8) Store {
        var store: Store = .{ .io = io, .gpa = gpa, .path = path };
        store.current = store.read();
        return store;
    }

    fn read(self: *Store) Settings {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, self.gpa, max_bytes) catch
            return .{};
        defer self.gpa.free(bytes);

        const parsed = std.json.parseFromSlice(Settings, self.gpa, bytes, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            log.warn("could not read {s} ({s}); using defaults", .{ self.path, @errorName(err) });
            return .{};
        };
        defer parsed.deinit();
        return parsed.value;
    }

    /// Re-reads from disk.
    ///
    /// The bot writes these and the watcher reads them, in separate
    /// processes, so a value cached at startup would go stale the moment the
    /// owner changed anything. Same reason the paused flag is re-read.
    pub fn reload(self: *Store) Settings {
        self.current = self.read();
        return self.current;
    }

    pub fn save(self: *Store, next: Settings) !void {
        self.current = next;

        var buffer: std.Io.Writer.Allocating = .init(self.gpa);
        defer buffer.deinit();
        try std.json.Stringify.value(next, .{ .whitespace = .indent_2 }, &buffer.writer);

        if (std.fs.path.dirname(self.path)) |dir| {
            std.Io.Dir.cwd().createDirPath(self.io, dir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = self.path,
            .data = buffer.writer.buffered(),
        });
        log.info("settings saved to {s}", .{self.path});
    }
};

/// "8am", "08:00", "20:30", "8" -> minutes since midnight, or null.
///
/// Deliberately not a model's job: a time is a small closed grammar, and a
/// model that misreads one sets quiet hours the owner did not ask for.
pub fn parseTime(text: []const u8) ?i16 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n.");
    if (trimmed.len == 0) return null;

    var body = trimmed;
    var pm = false;
    var am = false;
    if (std.ascii.endsWithIgnoreCase(body, "pm")) {
        pm = true;
        body = std.mem.trim(u8, body[0 .. body.len - 2], " \t");
    } else if (std.ascii.endsWithIgnoreCase(body, "am")) {
        am = true;
        body = std.mem.trim(u8, body[0 .. body.len - 2], " \t");
    }

    var hours: i16 = 0;
    var minutes: i16 = 0;
    if (std.mem.indexOfAny(u8, body, ":.h")) |sep| {
        hours = std.fmt.parseInt(i16, std.mem.trim(u8, body[0..sep], " \t"), 10) catch return null;
        const tail = std.mem.trim(u8, body[sep + 1 ..], " \t");
        minutes = if (tail.len == 0) 0 else std.fmt.parseInt(i16, tail, 10) catch return null;
    } else {
        hours = std.fmt.parseInt(i16, body, 10) catch return null;
    }

    if (pm and hours < 12) hours += 12;
    if (am and hours == 12) hours = 0;
    if (hours < 0 or hours > 23 or minutes < 0 or minutes > 59) return null;
    return hours * 60 + minutes;
}

/// Written out by hand rather than with a format spec: a signed value and
/// zero-padding together produced "+8:+0" instead of "08:00", and the digits
/// are simpler than the escape.
pub fn formatTime(minutes: i16, buffer: []u8) []const u8 {
    if (minutes == OFF) return "off";
    if (buffer.len < 5) return "?";
    const hours: u8 = @intCast(@divTrunc(minutes, 60));
    const mins: u8 = @intCast(@mod(minutes, 60));
    buffer[0] = '0' + hours / 10;
    buffer[1] = '0' + hours % 10;
    buffer[2] = ':';
    buffer[3] = '0' + mins / 10;
    buffer[4] = '0' + mins % 10;
    return buffer[0..5];
}

// ---- reading a settings change out of the owner's own words ----
//
// Jev decides *that* the message is a settings change; what the new value is
// gets read from the text here, by code, never by a model. Four prompt
// instructions were ignored by a model in a single afternoon in this project
// -- a runaway query, injected search operators, unbalanced quotes, and an
// address invented from a name -- and a misread time silences the mailbox for
// hours without anyone noticing. A clock is a closed grammar; parsing one is
// not a job that needs a model.

/// Used when the owner names only one end of the window: "don't notify me
/// before 8am" says when to stop, not when to start.
pub const DEFAULT_QUIET_FROM: i16 = 22 * 60;
pub const DEFAULT_QUIET_TO: i16 = 8 * 60;

pub const Change = union(enum) {
    quiet_hours: struct { from: i16, to: i16 },
    quiet_off,
    default_days: u16,
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return lastIndexOfIgnoreCase(haystack, needle) != null;
}

fn lastIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var index = haystack.len - needle.len + 1;
    while (index > 0) {
        index -= 1;
        if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return index;
    }
    return null;
}

fn containsAny(text: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (containsIgnoreCase(text, needle)) return true;
    }
    return false;
}

const Scan = struct { minutes: i16, end: usize };

/// The first thing in `text` that reads as a clock time, and where it ended.
///
/// Hand-rolled rather than tokenised because the separator varies: "10pm-8am",
/// "22:00 to 08:00" and "8 am" are all the same request written three ways.
fn scanTime(text: []const u8) ?Scan {
    var start: usize = 0;
    while (start < text.len) : (start += 1) {
        if (!std.ascii.isDigit(text[start])) continue;
        // A digit inside a word ("v2") or a longer run ("2026") is not a time.
        if (start > 0 and (std.ascii.isAlphanumeric(text[start - 1]))) continue;

        var buffer: [8]u8 = undefined;
        var len: usize = 0;
        var cursor = start;
        while (cursor < text.len and std.ascii.isDigit(text[cursor]) and len < 2) : (cursor += 1) {
            buffer[len] = text[cursor];
            len += 1;
        }
        // Three or more digits: a year or an amount, not an hour.
        if (cursor < text.len and std.ascii.isDigit(text[cursor])) continue;

        if (cursor + 1 < text.len and
            (text[cursor] == ':' or text[cursor] == '.' or std.ascii.toLower(text[cursor]) == 'h') and
            std.ascii.isDigit(text[cursor + 1]))
        {
            buffer[len] = ':';
            len += 1;
            cursor += 1;
            var digits: usize = 0;
            while (cursor < text.len and std.ascii.isDigit(text[cursor]) and digits < 2) : (cursor += 1) {
                buffer[len] = text[cursor];
                len += 1;
                digits += 1;
            }
        }

        // am/pm, with or without the space people leave before it.
        var after = cursor;
        while (after < text.len and text[after] == ' ') after += 1;
        if (after + 1 < text.len) {
            const first = std.ascii.toLower(text[after]);
            if ((first == 'a' or first == 'p') and std.ascii.toLower(text[after + 1]) == 'm') {
                buffer[len] = first;
                buffer[len + 1] = 'm';
                len += 2;
                cursor = after + 2;
            }
        }

        const minutes = parseTime(buffer[0..len]) orelse continue;
        return .{ .minutes = minutes, .end = cursor };
    }
    return null;
}

/// "30 days" -> 30. The number has to be attached to the word, so "8am on
/// weekdays" is not read as a look-back of 8 days.
fn scanDayCount(text: []const u8) ?u16 {
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (!std.ascii.isDigit(text[index])) continue;
        if (index > 0 and std.ascii.isAlphanumeric(text[index - 1])) continue;

        var cursor = index;
        while (cursor < text.len and std.ascii.isDigit(text[cursor])) cursor += 1;
        const digits = text[index..cursor];
        while (cursor < text.len and text[cursor] == ' ') cursor += 1;
        if (!std.ascii.startsWithIgnoreCase(text[cursor..], "day")) {
            index = cursor;
            continue;
        }
        const days = std.fmt.parseInt(u16, digits, 10) catch return null;
        if (days == 0 or days > 3650) return null;
        return days;
    }
    return null;
}

const Role = enum { start, end };

/// Which end of the window a time is, judged by the last preposition in front
/// of it. "before 8am" names the end; "after 10pm" names the start.
fn roleOf(prefix: []const u8) ?Role {
    const ends = [_][]const u8{ "before", "until", "untill", "till", "til", " to ", "up to", "earlier than", "ends", "end at" };
    const starts = [_][]const u8{ "after", "from", "past", "later than", "starting", "start at", "starts", "between", "as of" };

    var best: ?Role = null;
    var best_at: usize = 0;
    for (ends) |word| {
        if (lastIndexOfIgnoreCase(prefix, word)) |at| {
            if (best == null or at >= best_at) {
                best = .end;
                best_at = at;
            }
        }
    }
    for (starts) |word| {
        if (lastIndexOfIgnoreCase(prefix, word)) |at| {
            if (best == null or at >= best_at) {
                best = .start;
                best_at = at;
            }
        }
    }
    return best;
}

/// Reads a settings change out of what the owner actually wrote, or returns
/// null so the caller can say it did not understand rather than guess.
pub fn parseChange(text: []const u8, current: Settings) ?Change {
    // Switching quiet hours off comes first: "notify me at any time" contains
    // a time word but is the opposite of setting one.
    // "quite" is accepted alongside "quiet": it is the transposition everyone
    // makes, it is what a transcript sometimes hears, and there is no other
    // thing "turn off quite hours" could mean. Seen live -- Jev routed it to
    // change_setting at full confidence and this parser then refused it,
    // which looks like the feature is broken rather than the spelling.
    if (containsAny(text, &.{ "any time", "anytime", "all the time", "round the clock", "24/7", "whenever" }) or
        (containsAny(text, &.{ "quiet", "quite" }) and
            containsAny(text, &.{ "off", "no ", "stop", "cancel", "disable", "remove", "clear", "don't", "dont" })))
    {
        return .quiet_off;
    }

    if (scanDayCount(text)) |days| return .{ .default_days = days };

    const first = scanTime(text) orelse return null;
    const first_role = roleOf(text[0..first.end]);

    if (scanTime(text[first.end..])) |second_raw| {
        const second: Scan = .{ .minutes = second_raw.minutes, .end = first.end + second_raw.end };
        // Two times are a window. Written back-to-front ("before 8am and
        // after 10pm") they still mean the same window.
        if (first_role == .end) {
            return .{ .quiet_hours = .{ .from = second.minutes, .to = first.minutes } };
        }
        return .{ .quiet_hours = .{ .from = first.minutes, .to = second.minutes } };
    }

    // One time names one edge; the other keeps its current value, or takes a
    // sensible default when quiet hours were off.
    return switch (first_role orelse .start) {
        .end => .{ .quiet_hours = .{
            .from = if (current.quiet_from == OFF) DEFAULT_QUIET_FROM else current.quiet_from,
            .to = first.minutes,
        } },
        .start => .{ .quiet_hours = .{
            .from = first.minutes,
            .to = if (current.quiet_to == OFF) DEFAULT_QUIET_TO else current.quiet_to,
        } },
    };
}

test "quiet hours wrap past midnight, which is the normal case" {
    const overnight: Settings = .{ .quiet_from = 22 * 60, .quiet_to = 8 * 60 };

    try std.testing.expect(overnight.isQuietAt(23 * 60));      // 23:00
    try std.testing.expect(overnight.isQuietAt(3 * 60));       // 03:00
    try std.testing.expect(overnight.isQuietAt(22 * 60));      // exactly 22:00
    try std.testing.expect(!overnight.isQuietAt(8 * 60));      // exactly 08:00, awake
    try std.testing.expect(!overnight.isQuietAt(12 * 60));     // midday

    // A daytime window must not accidentally wrap.
    const daytime: Settings = .{ .quiet_from = 9 * 60, .quiet_to = 17 * 60 };
    try std.testing.expect(daytime.isQuietAt(12 * 60));
    try std.testing.expect(!daytime.isQuietAt(20 * 60));
    try std.testing.expect(!daytime.isQuietAt(3 * 60));
}

test "quiet hours off by default, and never suppress when unset" {
    const off: Settings = .{};
    try std.testing.expect(!off.quietEnabled());
    for ([_]i16{ 0, 3 * 60, 12 * 60, 23 * 60 }) |minute| {
        try std.testing.expect(!off.isQuietAt(minute));
    }

    // A zero-length window is off, not "always quiet" -- the failure there
    // would be silence, which is indistinguishable from a broken watcher.
    const empty: Settings = .{ .quiet_from = 8 * 60, .quiet_to = 8 * 60 };
    try std.testing.expect(!empty.isQuietAt(8 * 60));
}

test "times are parsed the way people write them" {
    try std.testing.expectEqual(@as(?i16, 8 * 60), parseTime("8am"));
    try std.testing.expectEqual(@as(?i16, 8 * 60), parseTime("08:00"));
    try std.testing.expectEqual(@as(?i16, 8 * 60), parseTime("8"));
    try std.testing.expectEqual(@as(?i16, 20 * 60 + 30), parseTime("20:30"));
    try std.testing.expectEqual(@as(?i16, 22 * 60), parseTime("10pm"));
    try std.testing.expectEqual(@as(?i16, 13 * 60 + 15), parseTime("1.15pm"));
    try std.testing.expectEqual(@as(?i16, 0), parseTime("12am"));
    try std.testing.expectEqual(@as(?i16, 12 * 60), parseTime("12pm"));

    // Nonsense stays nonsense rather than becoming a plausible time.
    try std.testing.expectEqual(@as(?i16, null), parseTime("tomorrow"));
    try std.testing.expectEqual(@as(?i16, null), parseTime("25:00"));
    try std.testing.expectEqual(@as(?i16, null), parseTime("8:99"));
    try std.testing.expectEqual(@as(?i16, null), parseTime(""));
}

test "formatTime round-trips what parseTime accepts" {
    var buffer: [8]u8 = undefined;
    try std.testing.expectEqualStrings("08:00", formatTime(parseTime("8am").?, &buffer));
    try std.testing.expectEqualStrings("22:00", formatTime(parseTime("10pm").?, &buffer));
    try std.testing.expectEqualStrings("off", formatTime(OFF, &buffer));
}

test "a time is found however it was written" {
    try std.testing.expectEqual(@as(?i16, 8 * 60), (scanTime("before 8am").?).minutes);
    try std.testing.expectEqual(@as(?i16, 8 * 60), (scanTime("before 8 am").?).minutes);
    try std.testing.expectEqual(@as(?i16, 22 * 60), (scanTime("after 22:00 please").?).minutes);
    try std.testing.expectEqual(@as(?i16, 20 * 60 + 30), (scanTime("from 8.30pm").?).minutes);

    // Things that merely contain digits are not times.
    try std.testing.expectEqual(@as(?Scan, null), scanTime("since 2026"));
    try std.testing.expectEqual(@as(?Scan, null), scanTime("nothing here"));
    try std.testing.expectEqual(@as(?Scan, null), scanTime("version v2 of it"));
}

test "a day count has to be attached to the word 'day'" {
    try std.testing.expectEqual(@as(?u16, 30), scanDayCount("look back 30 days"));
    try std.testing.expectEqual(@as(?u16, 7), scanDayCount("default to 7day"));

    // The trap: an hour followed by an unrelated word ending in "day".
    try std.testing.expectEqual(@as(?u16, null), scanDayCount("don't notify me before 8am on weekdays"));
    try std.testing.expectEqual(@as(?u16, null), scanDayCount("quiet hours from 10pm"));
    try std.testing.expectEqual(@as(?u16, null), scanDayCount("0 days"));
}

test "settings changes are read from the owner's own wording" {
    const off: Settings = .{};

    // The request that started this feature.
    try std.testing.expectEqual(Change{ .quiet_hours = .{
        .from = DEFAULT_QUIET_FROM,
        .to = 8 * 60,
    } }, parseChange("don't notify me before 8am", off).?);

    // Both ends named, in either order, mean the same window.
    const window = Change{ .quiet_hours = .{ .from = 22 * 60, .to = 7 * 60 } };
    try std.testing.expectEqual(window, parseChange("no notifications between 10pm and 7am", off).?);
    try std.testing.expectEqual(window, parseChange("quiet hours from 22:00 to 07:00", off).?);
    try std.testing.expectEqual(window, parseChange("10pm-7am", off).?);
    try std.testing.expectEqual(window, parseChange("quiet before 7am and after 10pm", off).?);

    // One edge named leaves the other alone rather than resetting it.
    const evening: Settings = .{ .quiet_from = 23 * 60, .quiet_to = 6 * 60 };
    try std.testing.expectEqual(Change{ .quiet_hours = .{
        .from = 23 * 60,
        .to = 9 * 60,
    } }, parseChange("actually let me sleep until 9am", evening).?);
    try std.testing.expectEqual(Change{ .quiet_hours = .{
        .from = 21 * 60,
        .to = 6 * 60,
    } }, parseChange("start quiet hours at 9pm", evening).?);

    try std.testing.expectEqual(Change{ .default_days = 30 }, parseChange("look back 30 days by default", off).?);
}

test "turning quiet hours off is never mistaken for setting them" {
    const on: Settings = .{ .quiet_from = 22 * 60, .quiet_to = 8 * 60 };

    // Each of these mentions a time or a number, and none of them is a window.
    for ([_][]const u8{
        "turn off quiet hours",
        "no quiet hours",
        "cancel quiet hours",
        "notify me at any time",
        "notify me whenever, even at 3am",
    }) |request| {
        try std.testing.expectEqual(Change.quiet_off, parseChange(request, on).?);
    }
}

test "a settings change with nothing to change in it is refused" {
    const off: Settings = .{};
    // Better to say "I didn't understand" than to silence the mailbox on a
    // guess: the failure mode of a wrong quiet window is no notifications,
    // which looks exactly like everything working.
    try std.testing.expectEqual(@as(?Change, null), parseChange("change my settings", off));
    try std.testing.expectEqual(@as(?Change, null), parseChange("make it better", off));
}

test "the quiet/quite transposition is accepted" {
    const on: Settings = .{ .quiet_from = 22 * 60, .quiet_to = 8 * 60 };
    // Typed live, routed correctly by Jev, and refused here -- which reads
    // as a broken feature rather than a misspelling.
    try std.testing.expectEqual(Change.quiet_off, parseChange("Turn off quite hours", on).?);
    try std.testing.expectEqual(Change.quiet_off, parseChange("turn off quiet hours", on).?);
}

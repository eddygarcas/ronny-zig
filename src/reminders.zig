//! Meeting reminders: which calendar entry is due a nudge, and what it says.
//!
//! The bot keeps a copy of today's listing and asks this module, once per
//! poll, whether anything is about to start. Only an entry with a link to
//! join qualifies -- the point of the reminder is to put that link in front
//! of the owner when they need it, and a dentist's appointment has no such
//! moment. The lead and whether reminders go at all are chat settings; see
//! `meeting_reminders` and `reminder_minutes` in settings.zig.
//!
//! Nothing here talks to Google or Telegram. The listing comes in, an entry
//! and its text go out, so the timing rules are all reachable from a test
//! with a clock the test chooses.

const std = @import("std");
const gcal = @import("gcal.zig");
const appointment = @import("appointment.zig");

/// One entry the bot is watching. `start` is minutes since *today's*
/// midnight, so tomorrow's first meetings sit past 1440 and a lead that
/// crosses midnight still finds them.
pub const Entry = struct {
    id: []const u8,
    title: []const u8,
    link: []const u8,
    description: []const u8,
    start: i32,
    end: i32,
    reminded: bool = false,
};

/// The listing as reminders see it: timed entries with a link, with the
/// day offset folded into the start. Entries the previous copy had already
/// reminded stay reminded, matched by id, so a refresh never repeats one.
pub fn collect(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Entry),
    listed: []const gcal.Listed,
    day_offset: i32,
    previous: []const Entry,
) !void {
    for (listed) |entry| {
        const start = entry.start_minutes orelse continue;
        if (entry.link.len == 0) continue;
        if (entry.id.len == 0) continue;
        const end = entry.end_minutes orelse (start + 60);
        try out.append(arena, .{
            .id = try arena.dupe(u8, entry.id),
            .title = try arena.dupe(u8, entry.title),
            .link = try arena.dupe(u8, entry.link),
            .description = try arena.dupe(u8, entry.description),
            .start = @as(i32, start) + day_offset * 24 * 60,
            .end = @as(i32, end) + day_offset * 24 * 60,
            .reminded = wasReminded(previous, entry.id),
        });
    }
}

fn wasReminded(previous: []const Entry, id: []const u8) bool {
    for (previous) |entry| {
        if (entry.reminded and std.mem.eql(u8, entry.id, id)) return true;
    }
    return false;
}

/// The next entry due a reminder at `now` (minutes since today's midnight),
/// or null. Due means the start is at most `lead` minutes away and has not
/// passed: a reminder for a meeting that already started is noise, and one
/// the bot missed while it was down stays missed rather than arriving late.
/// Entries already reminded are skipped, so the caller marks the one it
/// sends and asks again for the next.
pub fn due(entries: []Entry, now: i32, lead: i32) ?*Entry {
    var best: ?*Entry = null;
    for (entries) |*entry| {
        if (entry.reminded) continue;
        const until = entry.start - now;
        if (until < 0 or until > lead) continue;
        if (best == null or entry.start < best.?.start) best = entry;
    }
    return best;
}

/// The reminder itself: what, when, and the link. The agenda, when there
/// is one, is added by the caller because it comes from the local model.
pub fn text(arena: std.mem.Allocator, entry: Entry, now: i32) ![]const u8 {
    const until = entry.start - now;
    const start_clock: i16 = @intCast(@mod(entry.start, 24 * 60));
    const end_clock: i16 = @intCast(@mod(entry.end, 24 * 60));
    const range = try appointment.clockRange(arena, start_clock, end_clock);
    if (until <= 0) {
        return std.fmt.allocPrint(arena, "Starting now: {s} ({s})\n{s}", .{ entry.title, range, entry.link });
    }
    if (until == 1) {
        return std.fmt.allocPrint(arena, "In a minute: {s} ({s})\n{s}", .{ entry.title, range, entry.link });
    }
    return std.fmt.allocPrint(arena, "In {d} minutes: {s} ({s})\n{s}", .{ until, entry.title, range, entry.link });
}

// ---- tests ----

test "only timed entries with a link are watched, and a refresh keeps what was reminded" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const listed = [_]gcal.Listed{
        .{ .id = "a", .title = "Standup", .location = "", .start_minutes = 9 * 60, .end_minutes = 9 * 60 + 15, .link = "https://meet.google.com/a" },
        .{ .id = "b", .title = "Sam's birthday", .location = "", .start_minutes = null, .end_minutes = null, .link = "https://meet.google.com/b" },
        .{ .id = "c", .title = "Dentist", .location = "Calle Mayor 1", .start_minutes = 16 * 60, .end_minutes = 17 * 60 },
        .{ .id = "d", .title = "Review", .location = "", .start_minutes = 15 * 60, .end_minutes = null, .link = "https://zoom.us/j/1" },
    };
    const previous = [_]Entry{
        .{ .id = "a", .title = "Standup", .link = "", .description = "", .start = 0, .end = 0, .reminded = true },
    };
    var out: std.ArrayList(Entry) = .empty;
    try collect(arena, &out, &listed, 0, &previous);
    try collect(arena, &out, &listed, 1, &previous);

    try std.testing.expectEqual(@as(usize, 4), out.items.len);
    try std.testing.expectEqualStrings("a", out.items[0].id);
    try std.testing.expect(out.items[0].reminded);
    try std.testing.expectEqualStrings("d", out.items[1].id);
    try std.testing.expect(!out.items[1].reminded);
    // No end given: an hour, like a new entry.
    try std.testing.expectEqual(@as(i32, 16 * 60), out.items[1].end);
    // Tomorrow's copy of the same meeting is a different moment.
    try std.testing.expectEqual(@as(i32, 24 * 60 + 9 * 60), out.items[2].start);
    try std.testing.expect(out.items[2].reminded); // same id: already done today
}

test "an entry is due inside the lead, once, and the earliest first" {
    var entries = [_]Entry{
        .{ .id = "late", .title = "", .link = "", .description = "", .start = 15 * 60, .end = 16 * 60 },
        .{ .id = "soon", .title = "", .link = "", .description = "", .start = 10 * 60 + 8, .end = 11 * 60 },
        .{ .id = "past", .title = "", .link = "", .description = "", .start = 9 * 60 + 55, .end = 11 * 60 },
    };
    // 10:00, ten-minute lead: the 10:08 one, not the 09:55 one that has
    // started, not the afternoon one.
    const first = due(&entries, 10 * 60, 10).?;
    try std.testing.expectEqualStrings("soon", first.id);
    first.reminded = true;
    try std.testing.expect(due(&entries, 10 * 60, 10) == null);
    // Exactly on the edge counts, at both ends.
    try std.testing.expectEqualStrings("late", due(&entries, 15 * 60 - 10, 10).?.id);
    try std.testing.expectEqualStrings("late", due(&entries, 15 * 60, 10).?.id);
    try std.testing.expect(due(&entries, 15 * 60 + 1, 10) == null);
    // A lead of zero still fires at the start.
    entries[0].reminded = false;
    try std.testing.expectEqualStrings("late", due(&entries, 15 * 60, 0).?.id);
}

test "a lead across midnight finds tomorrow's first meeting" {
    var entries = [_]Entry{
        .{ .id = "t", .title = "", .link = "", .description = "", .start = 24 * 60 + 5, .end = 24 * 60 + 35 },
    };
    try std.testing.expectEqualStrings("t", due(&entries, 23 * 60 + 58, 10).?.id);
}

test "the reminder names the time left, the slot and the link" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entry: Entry = .{ .id = "x", .title = "Weekly sync", .link = "https://meet.google.com/x", .description = "", .start = 15 * 60, .end = 16 * 60 };
    try std.testing.expectEqualStrings(
        "In 10 minutes: Weekly sync (15:00-16:00)\nhttps://meet.google.com/x",
        try text(arena, entry, 15 * 60 - 10),
    );
    try std.testing.expectEqualStrings(
        "Starting now: Weekly sync (15:00-16:00)\nhttps://meet.google.com/x",
        try text(arena, entry, 15 * 60),
    );
    const tomorrow: Entry = .{ .id = "y", .title = "Early", .link = "l", .description = "", .start = 24 * 60 + 30, .end = 24 * 60 + 60 };
    try std.testing.expectEqualStrings("In 5 minutes: Early (00:30-01:00)\nl", try text(arena, tomorrow, 24 * 60 + 25));
}

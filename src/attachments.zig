//! Choosing which attachment the owner meant.
//!
//! The architecture split matters here and is easy to get wrong:
//!
//! - **Jev decides the action** ("they want a file sent to them") from the
//!   owner's words alone. No mail content is involved, so it may go off-box.
//! - **The local model decides which file**, because doing so means showing it
//!   the real filenames — and filenames are email content. "Q3-redundancies.xlsx"
//!   says plenty on its own. That stays on this machine, the same boundary as
//!   the spam gate and summaries.
//!
//! Neither model is asked to produce a filename. Both only ever pick an entry
//! from a list that came off a real message, which is the same rule the reply
//! recipient follows.

const std = @import("std");
const imap = @import("imap.zig");
const ollama = @import("ollama.zig");

const log = std.log.scoped(.attachments);

/// Bigger than Telegram will accept as an upload anyway, and an honest bound
/// on what is worth holding in memory at once.
pub const MAX_BYTES = 45 * 1024 * 1024;

pub fn humanSize(bytes: u64, buffer: []u8) []const u8 {
    if (bytes >= 1024 * 1024) {
        return std.fmt.bufPrint(buffer, "{d:.1} MB", .{
            @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0),
        }) catch "?";
    }
    if (bytes >= 1024) {
        return std.fmt.bufPrint(buffer, "{d} KB", .{bytes / 1024}) catch "?";
    }
    return std.fmt.bufPrint(buffer, "{d} bytes", .{bytes}) catch "?";
}

/// Real files first, inline ones (signature logos, tracking pixels) after.
/// Stable within each group, so the numbering the owner sees does not shuffle
/// between a listing and the request that follows it.
pub fn ranked(arena: std.mem.Allocator, parts: []const imap.Attachment) ![]const imap.Attachment {
    var out: std.ArrayList(imap.Attachment) = .empty;
    for (parts) |part| {
        if (part.is_inline == 0) try out.append(arena, part);
    }
    for (parts) |part| {
        if (part.is_inline == 1) try out.append(arena, part);
    }
    return out.toOwnedSlice(arena);
}

const Choice = struct { index: i64 = -1 };

/// Picks the attachment the owner's words point at.
///
/// Returns an index into `parts`, or null when nothing clearly matches --
/// which the caller turns into a question rather than a guess. Sending the
/// wrong file to a chat is not destructive, but it is a privacy slip, so an
/// unclear request is worth one extra turn.
pub fn choose(
    io: std.Io,
    arena: std.mem.Allocator,
    ollama_url: []const u8,
    model: []const u8,
    request: []const u8,
    parts: []const imap.Attachment,
) ?usize {
    if (parts.len == 0) return null;
    // Nothing to disambiguate, so no model call and no way to get it wrong.
    if (parts.len == 1) return 0;

    var listing: std.Io.Writer.Allocating = .init(arena);
    for (parts, 0..) |part, i| {
        var size_buf: [32]u8 = undefined;
        listing.writer.print("[{d}] {s} ({s}, {s})\n", .{
            i, part.filenameSlice(), part.mimeTypeSlice(),
            humanSize(part.size, &size_buf),
        }) catch return null;
    }

    const prompt = std.fmt.allocPrint(arena,
        \\The user asked for one of the files attached to an email. Which one do they mean?
        \\
        \\Request: {s}
        \\
        \\Files:
        \\{s}
        \\
        \\Reply with ONLY JSON: {{"index": <number>}}. Use -1 if the request does not clearly point at exactly one of them.
    , .{ request, listing.writer.buffered() }) catch return null;

    const answer = ollama.generateJson(io, arena, ollama_url, model, prompt) catch |err| {
        log.warn("attachment selection unavailable ({s})", .{@errorName(err)});
        return null;
    };
    const parsed = std.json.parseFromValue(Choice, arena, answer, .{
        .ignore_unknown_fields = true,
    }) catch return null;

    const index = parsed.value.index;
    if (index < 0 or index >= parts.len) return null;
    return @intCast(index);
}

test "humanSize scales the way a person would write it" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("512 bytes", humanSize(512, &buf));
    try std.testing.expectEqualStrings("72 KB", humanSize(74269, &buf)); // 74269/1024, not the decimal figure
    try std.testing.expectEqualStrings("2.4 MB", humanSize(2_500_000, &buf));
}

test "ranked puts real files ahead of inline ones without reordering within a group" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts: [3]imap.Attachment = undefined;
    for (&parts, 0..) |*part, i| {
        part.* = std.mem.zeroes(imap.Attachment);
        part.index = @intCast(i);
    }
    // A signature logo arriving before the invoice is the common real case.
    parts[0].is_inline = 1;
    parts[1].is_inline = 0;
    parts[2].is_inline = 0;

    const order = try ranked(arena, &parts);
    try std.testing.expectEqual(@as(u32, 1), order[0].index);
    try std.testing.expectEqual(@as(u32, 2), order[1].index);
    try std.testing.expectEqual(@as(u32, 0), order[2].index);
}

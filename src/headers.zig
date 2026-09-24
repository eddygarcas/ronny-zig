//! Reading RFC 5322 headers out of a fetched message.
//!
//! Python got this from the `email` module. There is no equivalent in Zig's
//! std and libetpan's parser wants the whole nested-structure treatment for
//! what is, at this level, line splitting -- so it is done here.
//!
//! This exists mainly to answer one question safely: **who does a reply go
//! to?** The answer must come from real headers, never from model output, so
//! that a hallucinated address cannot become a recipient. See mailer.zig.

const std = @import("std");

/// Returns the value of `name`, unfolded, or null. Continuation lines (a
/// header wrapped across several physical lines, each continuation starting
/// with whitespace) are joined with a single space.
///
/// The result borrows from `arena` when unfolding was needed and from
/// `headers` otherwise, so it is safe to hold for as long as both live.
pub fn value(arena: std.mem.Allocator, headers: []const u8, name: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, headers, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;

        const first = std.mem.trim(u8, line[colon + 1 ..], " \t");

        // Peek ahead for continuations before allocating anything.
        var lookahead = lines;
        const next_line = lookahead.next() orelse return first;
        if (next_line.len == 0 or (next_line[0] != ' ' and next_line[0] != '\t')) return first;

        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.writeAll(first);
        while (lines.next()) |cont_raw| {
            const cont = std.mem.trimEnd(u8, cont_raw, "\r");
            if (cont.len == 0 or (cont[0] != ' ' and cont[0] != '\t')) break;
            try out.writer.writeByte(' ');
            try out.writer.writeAll(std.mem.trim(u8, cont, " \t"));
        }
        return out.writer.buffered();
    }
    return null;
}

/// Pulls the bare address out of a From/Reply-To value: `Name <a@b>` becomes
/// `a@b`, a plain `a@b` is returned unchanged, and anything without an `@` is
/// rejected rather than guessed at.
pub fn address(raw: []const u8) ?[]const u8 {
    var candidate = std.mem.trim(u8, raw, " \t\r\n");

    if (std.mem.lastIndexOfScalar(u8, candidate, '<')) |open| {
        const close = std.mem.indexOfScalarPos(u8, candidate, open, '>') orelse return null;
        candidate = candidate[open + 1 .. close];
    }
    candidate = std.mem.trim(u8, candidate, " \t\"'");

    const at = std.mem.indexOfScalar(u8, candidate, '@') orelse return null;
    if (at == 0 or at == candidate.len - 1) return null;
    if (std.mem.indexOfScalar(u8, candidate[at + 1 ..], '.') == null) return null;
    for (candidate) |ch| {
        if (std.ascii.isWhitespace(ch) or ch == ',') return null;
    }
    return candidate;
}

/// Where a reply should go. Reply-To wins when present, as the sender asked;
/// otherwise From. Only ever the sender -- never reply-all, so the blast
/// radius of a mistake stays one person.
pub fn replyTo(arena: std.mem.Allocator, headers: []const u8) !?[]const u8 {
    if (try value(arena, headers, "Reply-To")) |raw| {
        if (address(raw)) |found| return found;
    }
    if (try value(arena, headers, "From")) |raw| {
        if (address(raw)) |found| return found;
    }
    return null;
}

test "value reads a simple header, case-insensitively" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const headers =
        "From: Sam <sam@example.com>\r\n" ++
        "Subject: Thursday\r\n" ++
        "Message-ID: <abc@mail>\r\n";

    try std.testing.expectEqualStrings("Thursday", (try value(arena, headers, "subject")).?);
    try std.testing.expectEqualStrings("<abc@mail>", (try value(arena, headers, "Message-ID")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try value(arena, headers, "Reply-To"));
}

test "value unfolds a wrapped header" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // References chains are long and always arrive folded.
    const headers =
        "References: <one@mail>\r\n" ++
        "\t<two@mail>\r\n" ++
        " <three@mail>\r\n" ++
        "Subject: after\r\n";

    try std.testing.expectEqualStrings(
        "<one@mail> <two@mail> <three@mail>",
        (try value(arena, headers, "References")).?,
    );
    // Parsing continues correctly past the folded header.
    try std.testing.expectEqualStrings("after", (try value(arena, headers, "Subject")).?);
}

test "address extracts a recipient and refuses anything doubtful" {
    try std.testing.expectEqualStrings("a@b.com", address("Some Name <a@b.com>").?);
    try std.testing.expectEqualStrings("a@b.com", address("  a@b.com  ").?);
    try std.testing.expectEqualStrings("a@b.com", address("\"Last, First\" <a@b.com>").?);

    // A recipient is not something to guess at.
    try std.testing.expectEqual(@as(?[]const u8, null), address("nobody"));
    try std.testing.expectEqual(@as(?[]const u8, null), address(""));
    try std.testing.expectEqual(@as(?[]const u8, null), address("@b.com"));
    try std.testing.expectEqual(@as(?[]const u8, null), address("a@localhost"));
    try std.testing.expectEqual(@as(?[]const u8, null), address("a@b.com, c@d.com"));
}

test "replyTo prefers Reply-To and never reply-all" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const with_reply_to =
        "From: Bot <noreply@example.com>\r\n" ++
        "Reply-To: Real Person <person@example.com>\r\n" ++
        "Cc: someone.else@example.com\r\n";
    try std.testing.expectEqualStrings("person@example.com", (try replyTo(arena, with_reply_to)).?);

    const from_only = "From: Sam <sam@example.com>\r\nCc: team@example.com\r\n";
    try std.testing.expectEqualStrings("sam@example.com", (try replyTo(arena, from_only)).?);

    // No usable address means no reply is drafted at all.
    const unusable = "From: Mailer Daemon\r\n";
    try std.testing.expectEqual(@as(?[]const u8, null), try replyTo(arena, unusable));
}

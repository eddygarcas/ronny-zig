//! A scratch target for exercising one piece against the real mailbox.
//!
//! Read-only and Telegram-free on purpose: the Python service is still live,
//! and a second getUpdates poller on the same token would silently swallow the
//! owner's real messages.

const std = @import("std");
const imap = @import("imap.zig");
const findmail = @import("findmail.zig");
const headers = @import("headers.zig");
const mailer = @import("mailer.zig");

const VOCAB_ENTRY = 96;
const VOCAB_MAX = 300;
extern fn ronny_sender_vocabulary(session: *imap.c.mailimap, days: c_int, out: [*]u8, max_out: c_int) c_int;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const env = init.environ_map;

    var session = try imap.Session.connect(
        try arena.dupeZ(u8, "imap.gmail.com"),
        993,
        try arena.dupeZ(u8, env.get("IMAP_USER").?),
        try arena.dupeZ(u8, env.get("IMAP_APP_PASSWORD").?),
    );
    defer session.deinit();
    _ = try session.examineInbox();

    std.debug.print("=== sender vocabulary (180d) ===\n", .{});
    const flat = try arena.alloc(u8, VOCAB_MAX * VOCAB_ENTRY);
    const count = ronny_sender_vocabulary(session.imap, 180, flat.ptr, VOCAB_MAX);
    std.debug.print("  {d} entries\n", .{count});
    if (count > 0) {
        for (0..@min(@as(usize, @intCast(count)), 30)) |i| {
            std.debug.print("  - {s}\n", .{std.mem.sliceTo(flat[i * VOCAB_ENTRY ..][0..VOCAB_ENTRY], 0)});
        }
    }

    std.debug.print("\n=== headers of the newest example mail ===\n", .{});
    var from_buf: [1]imap.Envelope = undefined;
    const hits = try session.searchFrom(try arena.dupeZ(u8, "example.org"), 60, &from_buf);
    if (hits.len > 0) {
        var message: imap.Message = undefined;
        try session.fetchMessage(hits[0].uid, &message);
        const raw = message.headersSlice();
        std.debug.print("  from:       {s}\n", .{hits[0].fromSlice()});
        std.debug.print("  date:       {s}\n", .{hits[0].dateSlice()});
        std.debug.print("  subject:    {s}\n", .{hits[0].subjectSlice()});
        std.debug.print("  reply-to:   {?s}\n", .{try headers.replyTo(arena, raw)});
        std.debug.print("  message-id: {?s}\n", .{try headers.value(arena, raw, "Message-ID")});
        std.debug.print("  references: {?s}\n", .{try headers.value(arena, raw, "References")});

        // Composed only -- a probe never sends.
        const draft = try mailer.compose(arena, env.get("IMAP_USER").?, .{
            .to = (try headers.replyTo(arena, raw)) orelse "nobody@example.com",
            .subject = if (std.ascii.startsWithIgnoreCase(hits[0].subjectSlice(), "re:"))
                hits[0].subjectSlice()
            else
                try std.fmt.allocPrint(arena, "Re: {s}", .{hits[0].subjectSlice()}),
            .body = "Thanks, noted.",
            .in_reply_to = (try headers.value(arena, raw, "Message-ID")) orelse "",
            .references = (try headers.value(arena, raw, "References")) orelse "",
        });
        std.debug.print("\n=== composed reply (not sent) ===\n{s}\n", .{draft[0..@min(draft.len, 500)]});
    }

    if (hits.len > 0) {
        var message: imap.Message = undefined;
        try session.fetchMessage(hits[0].uid, &message);
        const body = message.bodySlice();
        std.debug.print("\n=== raw body, first 400 chars (what the ranker sees) ===\n{s}\n", .{
            body[0..@min(body.len, 400)],
        });
    }

    std.debug.print("\n=== find: content search ===\n", .{});
    const question = "find the email about self-hosted deployment";
    const found = try findmail.find(
        init.io,
        arena,
        &session,
        "http://127.0.0.1:11434",
        "qwen2.5",
        question,
        120,
    );
    std.debug.print("  query: {s}\n", .{found.query});
    for (found.matches) |match| {
        std.debug.print("  - {s}\n    from {s} | {s}\n    {s}\n", .{
            match.candidate.subject, match.candidate.from, match.candidate.date, match.why,
        });
    }
}

const std = @import("std");
const imap = @import("imap.zig");
const summarize = @import("summarize.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const env = init.environ_map;
    var session = try imap.Session.connect(
        try arena.dupeZ(u8, "imap.gmail.com"), 993,
        try arena.dupeZ(u8, env.get("IMAP_USER").?),
        try arena.dupeZ(u8, env.get("IMAP_APP_PASSWORD").?),
    );
    defer session.deinit();
    _ = try session.examineInbox();

    // Separate buffers: these functions return slices *into* the buffer you
    // pass, so reusing one silently rewrites the earlier results.
    var from_buf: [10]imap.Envelope = undefined;
    var gmail_buf: [10]imap.Envelope = undefined;

    std.debug.print("=== searchFrom example.org (30d) ===\n", .{});
    const a = try session.searchFrom(try arena.dupeZ(u8, "example.org"), 30, &from_buf);
    for (a) |e| std.debug.print("  uid={d} {s} | {s}\n", .{ e.uid, e.fromSlice(), e.subjectSlice()[0..@min(e.subjectSlice().len, 58)] });

    std.debug.print("\n=== searchGmail 'self-hosted deployment' ===\n", .{});
    const b = try session.searchGmail(try arena.dupeZ(u8, "newer_than:120d self-hosted deployment"), &gmail_buf);
    for (b) |e| std.debug.print("  uid={d} {s} | {s}\n", .{ e.uid, e.fromSlice(), e.subjectSlice()[0..@min(e.subjectSlice().len, 58)] });

    if (a.len > 0) {
        var msg: imap.Message = undefined;
        try session.fetchMessage(a[0].uid, &msg);
        std.debug.print("\n=== summarize newest example mail ===\n", .{});
        const s = try summarize.summarize(init.io, arena, "http://127.0.0.1:11434", "qwen2.5",
            a[0].fromSlice(), a[0].subjectSlice(), msg.bodySlice());
        std.debug.print("  {s}\n", .{s});
    }
}

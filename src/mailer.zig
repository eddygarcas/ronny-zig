//! Reply sending. Port of `ronny/mailer.py`.
//!
//! This is the only module that can send an email, and it is deliberately
//! decision-free: it takes an explicit recipient and a body and sends them.
//! All the safety lives at the call site:
//!
//! - replies only ever target a message Ronny has already fetched and shown
//! - the recipient comes from that message's Reply-To/From headers, never
//!   from model output, so a hallucinated address is structurally impossible
//! - it replies to the sender only, never reply-all, keeping the blast radius
//!   of a mistake to one person
//! - nothing reaches here without the owner approving the draft; there is no
//!   send action in the intent vocabulary, so no model misreading can trigger
//!   it, and approval is resolved by decision.zig rather than by a model

const std = @import("std");

const log = std.log.scoped(.mailer);

pub const Error = error{SendFailed};

extern fn ronny_smtp_send(
    host: [*:0]const u8,
    port: u16,
    user: [*:0]const u8,
    password: [*:0]const u8,
    from: [*:0]const u8,
    to: [*:0]const u8,
    message: [*]const u8,
    message_len: usize,
) c_int;

pub const Reply = struct {
    to: []const u8,
    subject: []const u8,
    body: []const u8,
    /// Message-ID of the message being replied to. Threading only; empty is
    /// tolerated, the reply just won't nest in the client.
    in_reply_to: []const u8 = "",
    references: []const u8 = "",
};

/// Builds the RFC 5322 message. Kept separate from sending so it can be
/// inspected in tests without a network connection.
pub fn compose(arena: std.mem.Allocator, from: []const u8, reply: Reply) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);

    try out.writer.print("From: {s}\r\n", .{from});
    try out.writer.print("To: {s}\r\n", .{reply.to});
    try out.writer.print("Subject: {s}\r\n", .{reply.subject});

    if (reply.in_reply_to.len > 0) {
        try out.writer.print("In-Reply-To: {s}\r\n", .{reply.in_reply_to});
        // Append to any existing chain so clients thread it correctly.
        if (reply.references.len > 0) {
            try out.writer.print("References: {s} {s}\r\n", .{ reply.references, reply.in_reply_to });
        } else {
            try out.writer.print("References: {s}\r\n", .{reply.in_reply_to});
        }
    }

    try out.writer.writeAll("MIME-Version: 1.0\r\n");
    try out.writer.writeAll("Content-Type: text/plain; charset=utf-8\r\n");
    try out.writer.writeAll("\r\n");
    try out.writer.writeAll(reply.body);
    if (!std.mem.endsWith(u8, reply.body, "\r\n")) try out.writer.writeAll("\r\n");

    return out.toOwnedSlice();
}

pub fn send(
    gpa: std.mem.Allocator,
    host: []const u8,
    port: u16,
    user: []const u8,
    password: []const u8,
    reply: Reply,
) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const message = try compose(arena, user, reply);

    const host_z = try arena.dupeZ(u8, host);
    const user_z = try arena.dupeZ(u8, user);
    const password_z = try arena.dupeZ(u8, password);
    const to_z = try arena.dupeZ(u8, reply.to);

    const code = ronny_smtp_send(host_z.ptr, port, user_z.ptr, password_z.ptr, user_z.ptr, to_z.ptr, message.ptr, message.len);
    if (code != 0) {
        log.err("SMTP send to {s} failed with code {d}", .{ reply.to, code });
        return Error.SendFailed;
    }
    log.info("sent reply to {s} (subject={s})", .{ reply.to, reply.subject });
}

test "compose builds a threaded reply" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const message = try compose(arena, "me@example.com", .{
        .to = "them@example.org",
        .subject = "Re: Thursday",
        .body = "Thursday works.",
        .in_reply_to = "<abc@example.org>",
        .references = "<start@example.org>",
    });

    try std.testing.expect(std.mem.indexOf(u8, message, "From: me@example.com\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "To: them@example.org\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "In-Reply-To: <abc@example.org>\r\n") != null);
    // The new id is appended to the existing chain, not replacing it.
    try std.testing.expect(std.mem.indexOf(u8, message, "References: <start@example.org> <abc@example.org>\r\n") != null);
    // Headers and body separated by a blank line.
    try std.testing.expect(std.mem.indexOf(u8, message, "\r\n\r\nThursday works.") != null);
}

test "compose omits threading headers when there is nothing to thread to" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const message = try compose(arena, "me@example.com", .{
        .to = "them@example.org",
        .subject = "Hello",
        .body = "Body",
    });

    try std.testing.expect(std.mem.indexOf(u8, message, "In-Reply-To") == null);
    try std.testing.expect(std.mem.indexOf(u8, message, "References") == null);
    try std.testing.expect(std.mem.endsWith(u8, message, "Body\r\n"));
}

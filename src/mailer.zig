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

/// A file to attach. The bytes are whatever they are; this module does the
/// base64 and the framing.
pub const Attachment = struct {
    filename: []const u8,
    content_type: []const u8,
    bytes: []const u8,
};

/// Gmail caps a whole message at 25 MB and base64 inflates by a third, so
/// this is the largest raw payload that reliably fits.
pub const MAX_ATTACHMENT_BYTES = 18 * 1024 * 1024;

pub const Reply = struct {
    to: []const u8,
    subject: []const u8,
    body: []const u8,
    /// Message-ID of the message being replied to. Threading only; empty is
    /// tolerated, the reply just won't nest in the client.
    in_reply_to: []const u8 = "",
    references: []const u8 = "",
    attachments: []const Attachment = &.{},
};

const BOUNDARY_PREFIX = "----ronny";
const BOUNDARY_RANDOM_BYTES = 16;
/// Derived, not guessed. A hand-written size here was wrong by five bytes and
/// made `bufPrint` return NoSpaceLeft, which failed *every* send -- and the
/// compose() tests never caught it because they pass a literal boundary.
const BOUNDARY_LEN = BOUNDARY_PREFIX.len + BOUNDARY_RANDOM_BYTES * 2;

/// Random, because the boundary must not occur inside any attachment and
/// those are arbitrary bytes.
fn makeBoundary(io: std.Io, buffer: *[BOUNDARY_LEN]u8) []const u8 {
    var raw: [BOUNDARY_RANDOM_BYTES]u8 = undefined;
    io.random(&raw);
    // Cannot fail: BOUNDARY_LEN is computed from exactly what is written.
    return std.fmt.bufPrint(buffer, BOUNDARY_PREFIX ++ "{x}", .{&raw}) catch unreachable;
}

/// Base64 wrapped at 76 characters, as RFC 2045 requires.
///
/// 57 input bytes encode to exactly 76 output characters, which is why the
/// chunk size is that rather than a round number.
fn writeBase64(writer: *std.Io.Writer, bytes: []const u8) !void {
    const encoder = std.base64.standard.Encoder;
    var line: [76]u8 = undefined;

    var i: usize = 0;
    while (i < bytes.len) {
        const chunk = bytes[i..@min(i + 57, bytes.len)];
        try writer.writeAll(encoder.encode(&line, chunk));
        try writer.writeAll("\r\n");
        i += chunk.len;
    }
}

/// Filenames reach us from Telegram and can hold anything. Rather than
/// implement RFC 2231 for the rare case, anything outside plain ASCII is
/// replaced so the header stays well-formed and the name stays recognisable.
fn writeSafeFilename(writer: *std.Io.Writer, filename: []const u8) !void {
    if (filename.len == 0) return writer.writeAll("attachment");
    for (filename) |ch| {
        if (ch < 0x20 or ch > 0x7e or ch == '"' or ch == '\\') {
            try writer.writeByte('_');
        } else {
            try writer.writeByte(ch);
        }
    }
}

/// Builds the RFC 5322 message. Kept separate from sending so it can be
/// inspected in tests without a network connection -- which is also why the
/// boundary is a parameter rather than generated in here.
pub fn compose(
    arena: std.mem.Allocator,
    from: []const u8,
    reply: Reply,
    boundary: []const u8,
) ![]u8 {
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

    // Without attachments the message stays flat text/plain -- no reason to
    // wrap a two-line reply in MIME machinery.
    if (reply.attachments.len == 0) {
        try out.writer.writeAll("Content-Type: text/plain; charset=utf-8\r\n\r\n");
        try out.writer.writeAll(reply.body);
        if (!std.mem.endsWith(u8, reply.body, "\r\n")) try out.writer.writeAll("\r\n");
        return out.toOwnedSlice();
    }

    try out.writer.print("Content-Type: multipart/mixed; boundary=\"{s}\"\r\n\r\n", .{boundary});
    try out.writer.writeAll("This is a multi-part message in MIME format.\r\n");

    try out.writer.print("\r\n--{s}\r\n", .{boundary});
    try out.writer.writeAll("Content-Type: text/plain; charset=utf-8\r\n");
    try out.writer.writeAll("Content-Transfer-Encoding: 8bit\r\n\r\n");
    try out.writer.writeAll(reply.body);
    if (!std.mem.endsWith(u8, reply.body, "\r\n")) try out.writer.writeAll("\r\n");

    for (reply.attachments) |attachment| {
        try out.writer.print("\r\n--{s}\r\n", .{boundary});
        try out.writer.print("Content-Type: {s}; name=\"", .{attachment.content_type});
        try writeSafeFilename(&out.writer, attachment.filename);
        try out.writer.writeAll("\"\r\n");
        try out.writer.writeAll("Content-Transfer-Encoding: base64\r\n");
        try out.writer.writeAll("Content-Disposition: attachment; filename=\"");
        try writeSafeFilename(&out.writer, attachment.filename);
        try out.writer.writeAll("\"\r\n\r\n");
        try writeBase64(&out.writer, attachment.bytes);
    }

    try out.writer.print("\r\n--{s}--\r\n", .{boundary});
    return out.toOwnedSlice();
}

pub fn send(
    io: std.Io,
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

    var boundary: [BOUNDARY_LEN]u8 = undefined;
    const message = try compose(arena, user, reply, makeBoundary(io, &boundary));

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
        }, "BOUND");

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
    }, "BOUND");

    try std.testing.expect(std.mem.indexOf(u8, message, "In-Reply-To") == null);
    try std.testing.expect(std.mem.indexOf(u8, message, "References") == null);
    try std.testing.expect(std.mem.endsWith(u8, message, "Body\r\n"));
    // No attachments means no MIME wrapper at all.
    try std.testing.expect(std.mem.indexOf(u8, message, "multipart") == null);
}

test "compose attaches a file as base64 multipart" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const message = try compose(arena, "me@example.com", .{
        .to = "them@example.org",
        .subject = "Here it is",
        .body = "Attached.",
        .attachments = &.{.{
            .filename = "notes.txt",
            .content_type = "text/plain",
            .bytes = "hello",
        }},
    }, "BOUND");

    try std.testing.expect(std.mem.indexOf(u8, message,
        "Content-Type: multipart/mixed; boundary=\"BOUND\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, message,
        "Content-Disposition: attachment; filename=\"notes.txt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, message,
        "Content-Transfer-Encoding: base64") != null);
    // "hello" in base64.
    try std.testing.expect(std.mem.indexOf(u8, message, "aGVsbG8=") != null);
    // The body survives as its own part.
    try std.testing.expect(std.mem.indexOf(u8, message, "Attached.") != null);
    // Closing delimiter carries the trailing dashes.
    try std.testing.expect(std.mem.endsWith(u8, message, "--BOUND--\r\n"));
}

test "base64 wraps at 76 characters" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    // 120 bytes encodes to 160 characters, so it must wrap.
    const payload = "x" ** 120;
    try writeBase64(&out.writer, payload);

    var lines = std.mem.splitSequence(u8, std.mem.trimEnd(u8, out.writer.buffered(), "\r\n"), "\r\n");
    while (lines.next()) |line| {
        try std.testing.expect(line.len <= 76);
    }
}

test "a filename that would break the header is sanitised, not dropped" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    // A quote would end the header value early; non-ASCII needs RFC 2231,
    // which is not worth implementing for the rare case.
    try writeSafeFilename(&out.writer, "in\"voice\u{00e9}.pdf");
    try std.testing.expectEqualStrings("in_voice__.pdf", out.writer.buffered());
}

test "the generated boundary fits the buffer it is sized for" {
    // This is the bug this pins: the buffer was hand-sized at 36 for 41
    // characters of output, so bufPrint returned NoSpaceLeft and every send
    // failed -- including sends with no attachment at all, since the boundary
    // is generated unconditionally. Change the prefix without changing the
    // length and this fails instead of production.
    const raw: [BOUNDARY_RANDOM_BYTES]u8 = @splat(0xAB);
    var buffer: [BOUNDARY_LEN]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, BOUNDARY_PREFIX ++ "{x}", .{&raw});

    try std.testing.expectEqual(BOUNDARY_LEN, text.len);
    try std.testing.expect(std.mem.startsWith(u8, text, BOUNDARY_PREFIX));
}

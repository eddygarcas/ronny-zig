//! IMAP session and new-mail detection.
//!
//! Mirrors the Python `ronny/imap_watcher.py`: select INBOX read-only, sit in
//! IDLE, and on wakeup fetch envelopes for anything newer than the last UID
//! we saw. Sender matching happens on envelope data alone -- the full body is
//! only fetched for messages that actually match, which is what kept the
//! Python version from pulling 50k bodies off the server.
//!
//! The nested libetpan result structures are walked in src/shim.c; this file
//! deals in flat data.

const std = @import("std");

/// Namespaced so each module's output is identifiable in the journal,
/// the way the Python version's per-module loggers were.
const log = std.log.scoped(.imap);

/// Translated by the build system from src/c.h rather than @cImport, which
/// 0.16 deprecates. See build.zig.
pub const c = @import("c");

pub const ADDR_MAX = 256;
pub const SUBJ_MAX = 512;
pub const DATE_MAX = 64;

/// Mirrors `ronny_envelope` in shim.c. Layout must stay in step with it.
pub const Envelope = extern struct {
    uid: u32,
    from: [ADDR_MAX]u8,
    subject: [SUBJ_MAX]u8,
    date: [DATE_MAX]u8,

    pub fn fromSlice(self: *const Envelope) []const u8 {
        return std.mem.sliceTo(&self.from, 0);
    }

    pub fn subjectSlice(self: *const Envelope) []const u8 {
        return std.mem.sliceTo(&self.subject, 0);
    }

    /// The raw Date: header as the sender wrote it, so the owner sees the
    /// same string their mail client shows rather than a reformatted one.
    pub fn dateSlice(self: *const Envelope) []const u8 {
        return std.mem.sliceTo(&self.date, 0);
    }
};

extern fn ronny_selection_exists(session: *c.mailimap) u32;
extern fn ronny_selection_uidnext(session: *c.mailimap) u32;
extern fn ronny_selection_uidvalidity(session: *c.mailimap) u32;
extern fn ronny_fetch_envelopes_since(session: *c.mailimap, first_uid: u32, out: [*]Envelope, max_out: c_int) c_int;
extern fn ronny_fetch_message(session: *c.mailimap, uid: u32, out: *Message) c_int;
extern fn ronny_fetch_attachment(session: *c.mailimap, uid: u32, index: u32, out: [*]u8, cap: usize) c_long;
extern fn ronny_search_from(session: *c.mailimap, sender: [*:0]const u8, days: c_int, out: [*]Envelope, max_out: c_int) c_int;
extern fn ronny_search_recent(session: *c.mailimap, days: c_int, out: [*]Envelope, max_out: c_int) c_int;
extern fn ronny_search_gmail(session: *c.mailimap, query: [*:0]const u8, out: [*]Envelope, max_out: c_int) c_int;

pub const Error = error{
    SessionAlloc,
    Connect,
    Login,
    Select,
    Fetch,
    Idle,
    AttachmentTooLarge,
};

pub const HDR_MAX = 8192;
pub const BODY_MAX = 8192;
pub const ATTACH_MAX = 16;
pub const FNAME_MAX = 200;
pub const CTYPE_MAX = 100;

/// Mirrors `ronny_attachment` in shim.c. Metadata only -- the bytes stay on
/// the server until `fetchAttachment` asks for them, so listing what a
/// message carries costs nothing beyond the fetch already being done.
pub const Attachment = extern struct {
    filename: [FNAME_MAX]u8,
    mime_type: [CTYPE_MAX]u8,
    /// Approximate decoded size, for showing the owner before they commit to
    /// a download. Not an allocation size.
    size: u32,
    /// Ordinal among the message's single parts; what `fetchAttachment` takes.
    index: u32,
    /// Content-Disposition: inline -- a signature logo rather than a file
    /// someone meant to send. Still an attachment, just ranked below.
    is_inline: u8,

    pub fn filenameSlice(self: *const Attachment) []const u8 {
        return std.mem.sliceTo(&self.filename, 0);
    }

    pub fn mimeTypeSlice(self: *const Attachment) []const u8 {
        return std.mem.sliceTo(&self.mime_type, 0);
    }
};

/// Mirrors `ronny_message` in shim.c. Headers and body are separated: the
/// deterministic spam checks read only headers, the model reads only the text.
pub const Message = extern struct {
    headers: [HDR_MAX]u8,
    body: [BODY_MAX]u8,
    attachment_count: i32,
    attachments: [ATTACH_MAX]Attachment,

    pub fn headersSlice(self: *const Message) []const u8 {
        return std.mem.sliceTo(&self.headers, 0);
    }

    pub fn bodySlice(self: *const Message) []const u8 {
        return std.mem.sliceTo(&self.body, 0);
    }

    pub fn attachmentSlice(self: *const Message) []const Attachment {
        const n: usize = if (self.attachment_count < 0) 0 else @intCast(self.attachment_count);
        return self.attachments[0..@min(n, ATTACH_MAX)];
    }
};

pub const Selection = struct {
    exists: u32,
    uid_next: u32,
    uid_validity: u32,
};

/// libetpan has three success codes, not one: NO_ERROR (0) plus
/// NO_ERROR_AUTHENTICATED (1) and NO_ERROR_NON_AUTHENTICATED (2), which
/// report the session's auth state after connecting. Treating anything
/// non-zero as failure rejects a perfectly healthy connection.
pub fn isOk(code: c_int) bool {
    return code == c.MAILIMAP_NO_ERROR or
        code == c.MAILIMAP_NO_ERROR_AUTHENTICATED or
        code == c.MAILIMAP_NO_ERROR_NON_AUTHENTICATED;
}

fn check(code: c_int, comptime err: Error) Error!void {
    if (!isOk(code)) {
        log.err("libetpan returned {d}", .{code});
        return err;
    }
}

pub const Session = struct {
    imap: *c.mailimap,

    pub fn connect(host: [:0]const u8, port: u16, user: [:0]const u8, password: [:0]const u8) Error!Session {
        const imap = c.mailimap_new(0, null) orelse return Error.SessionAlloc;
        errdefer c.mailimap_free(imap);

        try check(c.mailimap_ssl_connect(imap, host.ptr, port), Error.Connect);
        try check(c.mailimap_login(imap, user.ptr, password.ptr), Error.Login);
        return .{ .imap = imap };
    }

    pub fn deinit(self: *Session) void {
        _ = c.mailimap_logout(self.imap);
        c.mailimap_free(self.imap);
    }

    /// Read-only, so the watcher never marks anything as seen -- the same
    /// guarantee the Python version got from `readonly=True`.
    pub fn examineInbox(self: *Session) Error!Selection {
        try check(c.mailimap_examine(self.imap, "INBOX"), Error.Select);
        return .{
            .exists = ronny_selection_exists(self.imap),
            .uid_next = ronny_selection_uidnext(self.imap),
            .uid_validity = ronny_selection_uidvalidity(self.imap),
        };
    }

    /// Envelopes for everything with UID >= first_uid, written into `buffer`.
    pub fn envelopesSince(self: *Session, first_uid: u32, buffer: []Envelope) Error![]Envelope {
        const written = ronny_fetch_envelopes_since(self.imap, first_uid, buffer.ptr, @intCast(buffer.len));
        if (written < 0) return Error.Fetch;
        return buffer[0..@intCast(written)];
    }

    /// Headers and text body for one UID. Fetched with BODY.PEEK, so
    /// inspecting a message never marks it read.
    pub fn fetchMessage(self: *Session, uid: u32, out: *Message) Error!void {
        if (ronny_fetch_message(self.imap, uid, out) != 0) return Error.Fetch;
    }

    /// Decoded bytes of one attachment, written into `buffer`.
    ///
    /// Costs a second fetch of the message: the metadata comes back with
    /// `fetchMessage`, but the bytes are only pulled when actually wanted.
    /// Holding whole multi-megabyte messages for every mail merely *looked*
    /// at would be the wrong trade.
    pub fn fetchAttachment(self: *Session, uid: u32, index: u32, buffer: []u8) Error![]u8 {
        const written = ronny_fetch_attachment(self.imap, uid, index, buffer.ptr, buffer.len);
        if (written == -2) return Error.AttachmentTooLarge;
        if (written < 0) return Error.Fetch;
        return buffer[0..@intCast(written)];
    }

    /// Mail from a sender within the last `days`, newest first. IMAP's FROM
    /// is a substring match, so a bare domain or display name works too.
    ///
    /// The result is a slice *into* `buffer`: reusing one buffer across two
    /// searches silently rewrites the earlier results.
    pub fn searchFrom(self: *Session, sender: [:0]const u8, days: u16, buffer: []Envelope) Error![]Envelope {
        const n = ronny_search_from(self.imap, sender.ptr, days, buffer.ptr, @intCast(buffer.len));
        if (n < 0) return Error.Fetch;
        return buffer[0..@intCast(n)];
    }

    /// Everything from the last `days`, newest first, whoever sent it.
    ///
    /// "What came in this morning" names no sender, so none of the
    /// sender-keyed searches can answer it.
    pub fn searchRecent(self: *Session, days: u16, buffer: []Envelope) Error![]Envelope {
        const n = ronny_search_recent(self.imap, days, buffer.ptr, @intCast(buffer.len));
        if (n < 0) return Error.Fetch;
        return buffer[0..@intCast(n)];
    }

    /// Gmail's own full-text search. No local index to build or keep fresh --
    /// Gmail already has one and answers in well under a second across 50k
    /// messages.
    pub fn searchGmail(self: *Session, query: [:0]const u8, buffer: []Envelope) Error![]Envelope {
        const n = ronny_search_gmail(self.imap, query.ptr, buffer.ptr, @intCast(buffer.len));
        if (n < 0) return Error.Fetch;
        return buffer[0..@intCast(n)];
    }

    /// Blocks until the server reports activity or `timeout_seconds` passes.
    /// Returns true if the server said something, false on timeout -- the
    /// caller rescans either way, since the timeout doubles as the keepalive
    /// and safety net.
    pub fn idleWait(self: *Session, timeout_seconds: u31) Error!bool {
        try check(c.mailimap_idle(self.imap), Error.Idle);
        defer _ = c.mailimap_idle_done(self.imap);

        const fd = c.mailimap_idle_get_fd(self.imap);
        if (fd < 0) return Error.Idle;

        var fds = [_]std.posix.pollfd{.{
            .fd = @intCast(fd),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = std.posix.poll(&fds, @as(i32, timeout_seconds) * 1000) catch |err| {
            log.warn("poll on the IDLE socket failed: {s}", .{@errorName(err)});
            return Error.Idle;
        };
        return ready > 0;
    }
};

/// Exact address match, or a bare domain matching anything at that domain --
/// the same rule as the Python `sender_matches`.
pub fn senderMatches(address: []const u8, allowlist: []const []const u8) bool {
    var lowered_buf: [ADDR_MAX]u8 = undefined;
    if (address.len > lowered_buf.len) return false;
    const lowered = std.ascii.lowerString(&lowered_buf, address);

    const at = std.mem.lastIndexOfScalar(u8, lowered, '@');
    const domain = if (at) |i| lowered[i + 1 ..] else lowered;

    for (allowlist) |entry| {
        if (std.ascii.eqlIgnoreCase(entry, lowered)) return true;
        if (std.ascii.eqlIgnoreCase(entry, domain)) return true;
    }
    return false;
}

extern fn ronny_layout(which: c_int) usize;

test "the C and Zig views of the shared structs agree" {
    // These structs are declared twice, once per language, and a mismatch
    // does not fail to compile -- it silently reads the wrong bytes and
    // surfaces as a garbled filename or a nonsense size far from the cause.
    try std.testing.expectEqual(ronny_layout(0), @sizeOf(Envelope));
    try std.testing.expectEqual(ronny_layout(1), @sizeOf(Message));
    try std.testing.expectEqual(ronny_layout(2), @sizeOf(Attachment));

    try std.testing.expectEqual(ronny_layout(3), @offsetOf(Message, "attachment_count"));
    try std.testing.expectEqual(ronny_layout(4), @offsetOf(Message, "attachments"));

    try std.testing.expectEqual(ronny_layout(5), @offsetOf(Attachment, "size"));
    try std.testing.expectEqual(ronny_layout(6), @offsetOf(Attachment, "index"));
    try std.testing.expectEqual(ronny_layout(7), @offsetOf(Attachment, "is_inline"));
}

test "senderMatches handles addresses, domains and case" {
    const allow = [_][]const u8{ "watched@example.com", "example.org" };

    try std.testing.expect(senderMatches("watched@example.com", &allow));
    try std.testing.expect(senderMatches("WATCHED@EXAMPLE.COM", &allow));
    // A bare domain entry matches anyone at that domain.
    try std.testing.expect(senderMatches("anyone@example.org", &allow));

    // Same domain, different mailbox: the entry was a full address.
    try std.testing.expect(!senderMatches("other@example.com", &allow));
    try std.testing.expect(!senderMatches("someone@elsewhere.net", &allow));
    // A domain that merely ends with an allowed one must not match.
    try std.testing.expect(!senderMatches("me@notexample.org", &allow));
    try std.testing.expect(!senderMatches("", &allow));
}

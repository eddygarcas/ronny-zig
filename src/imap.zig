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

pub const c = @cImport({
    @cInclude("libetpan/libetpan.h");
});

pub const ADDR_MAX = 256;
pub const SUBJ_MAX = 512;

/// Mirrors `ronny_envelope` in shim.c. Layout must stay in step with it.
pub const Envelope = extern struct {
    uid: u32,
    from: [ADDR_MAX]u8,
    subject: [SUBJ_MAX]u8,

    pub fn fromSlice(self: *const Envelope) []const u8 {
        return std.mem.sliceTo(&self.from, 0);
    }

    pub fn subjectSlice(self: *const Envelope) []const u8 {
        return std.mem.sliceTo(&self.subject, 0);
    }
};

extern fn ronny_selection_exists(session: *c.mailimap) u32;
extern fn ronny_selection_uidnext(session: *c.mailimap) u32;
extern fn ronny_selection_uidvalidity(session: *c.mailimap) u32;
extern fn ronny_fetch_envelopes_since(session: *c.mailimap, first_uid: u32, out: [*]Envelope, max_out: c_int) c_int;

pub const Error = error{
    SessionAlloc,
    Connect,
    Login,
    Select,
    Fetch,
    Idle,
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

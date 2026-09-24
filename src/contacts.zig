//! Who a new email can be addressed to.
//!
//! This module exists to preserve one property while adding a feature that
//! would otherwise break it.
//!
//! A reply's recipient comes from the headers of a message Ronny already
//! fetched, so a hallucinated address is structurally impossible. A brand-new
//! email has no such message — the address has to come from somewhere, and the
//! obvious "somewhere" is model output, which is exactly the shape that once
//! wrote the literal string `"null"` into the live allowlist. In a config file
//! that was embarrassing; in a To: header it reaches a stranger.
//!
//! So the model never types an address. It **picks one** from a list built by
//! reading the mailbox, and the owner sees the literal address in the draft
//! and approves it. Every candidate is an address that has really written to
//! this mailbox.
//!
//! **Selection runs locally**, on Ollama, not on Jev. Jev decides the action —
//! "they want to write to someone" — from the owner's words alone, which
//! carries no mail data. Choosing *which* contact means showing the model the
//! address book, and an address book is exactly the kind of thing the "email
//! content does not leave the box" rule is for. Jev picks the verb; the local
//! model picks the person.

const std = @import("std");
const imap = @import("imap.zig");
const ollama = @import("ollama.zig");

const log = std.log.scoped(.contacts);

pub const NAME_MAX = 96;
pub const ADDR_MAX = 128;
pub const MAX_CONTACTS = 400;
/// A year: wide enough that someone you mail quarterly is still reachable.
pub const DEFAULT_DAYS = 365;
/// How many go to the model. The list is frequency-ordered, so the tail is
/// one-off senders, and a prompt with 400 addresses in it selects worse.
pub const SHORTLIST = 60;

/// Mirrors `ronny_contact` in shim.c.
pub const Contact = extern struct {
    name: [NAME_MAX]u8,
    address: [ADDR_MAX]u8,
    count: u32,

    pub fn nameSlice(self: *const Contact) []const u8 {
        return std.mem.sliceTo(&self.name, 0);
    }

    pub fn addressSlice(self: *const Contact) []const u8 {
        return std.mem.sliceTo(&self.address, 0);
    }
};

extern fn ronny_contacts(session: *imap.c.mailimap, days: c_int, out: [*]Contact, max_out: c_int) c_int;

/// Local parts that announce the address cannot be written to.
///
/// Frequency alone ranks a mailbox's most prolific *automated* senders first:
/// on a real mailbox the top ten were no-reply@, postmaster@, DMARC report
/// addresses and newsletters, which pushed actual people past the shortlist
/// entirely. None of them can receive mail, so dropping them is not a
/// heuristic about importance, it is a fact about deliverability.
const UNWRITABLE = [_][]const u8{
    "noreply",    "no-reply",   "no_reply", "donotreply",     "do-not-reply",
    "postmaster", "mailer-daemon", "mailerdaemon", "bounce",  "bounces",
    "dmarc",      "abuse",      "unsubscribe",
};

pub fn isWritable(address: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, address, '@') orelse return false;
    const local = address[0..at];
    for (UNWRITABLE) |pattern| {
        if (std.ascii.indexOfIgnoreCase(local, pattern) != null) return false;
    }
    return true;
}

/// Everyone who has written recently and could receive a reply, most frequent
/// first.
pub fn load(arena: std.mem.Allocator, session: *imap.Session, days: u16) ![]const Contact {
    const buffer = try arena.alloc(Contact, MAX_CONTACTS);
    const count = ronny_contacts(session.imap, days, buffer.ptr, MAX_CONTACTS);
    if (count < 0) return error.ContactsUnavailable;

    var kept: std.ArrayList(Contact) = .empty;
    for (buffer[0..@intCast(count)]) |contact| {
        if (isWritable(contact.addressSlice())) try kept.append(arena, contact);
    }
    return kept.toOwnedSlice(arena);
}

/// Moves the watched senders to the front.
///
/// Whoever the owner cared enough about to put on the allowlist is far more
/// likely to be who they mean than whoever sends the most mail.
pub fn prioritise(
    arena: std.mem.Allocator,
    book: []const Contact,
    allowlist: []const []const u8,
) ![]const Contact {
    if (allowlist.len == 0) return book;

    const matches = struct {
        fn call(address: []const u8, list: []const []const u8) bool {
            const at = std.mem.lastIndexOfScalar(u8, address, '@');
            const domain = if (at) |i| address[i + 1 ..] else address;
            for (list) |entry| {
                if (std.ascii.eqlIgnoreCase(entry, address)) return true;
                if (std.ascii.eqlIgnoreCase(entry, domain)) return true;
            }
            return false;
        }
    }.call;

    var out: std.ArrayList(Contact) = .empty;
    for (book) |contact| {
        if (matches(contact.addressSlice(), allowlist)) try out.append(arena, contact);
    }
    for (book) |contact| {
        if (!matches(contact.addressSlice(), allowlist)) try out.append(arena, contact);
    }
    return out.toOwnedSlice(arena);
}

const Choice = struct { index: i64 = -1 };

/// Picks the contact the owner meant, or null.
///
/// Null is a real answer and the caller must treat it as one: it asks the
/// owner to type the address rather than guessing. Guessing wrong here sends
/// mail to the wrong person, which cannot be taken back.
pub fn resolve(
    io: std.Io,
    arena: std.mem.Allocator,
    ollama_url: []const u8,
    model: []const u8,
    request: []const u8,
    contacts: []const Contact,
) ?usize {
    if (contacts.len == 0) return null;

    const shortlist = contacts[0..@min(contacts.len, SHORTLIST)];

    // An exact address typed by the owner needs no model at all.
    for (shortlist, 0..) |contact, i| {
        if (std.ascii.indexOfIgnoreCase(request, contact.addressSlice()) != null) return i;
    }

    var listing: std.Io.Writer.Allocating = .init(arena);
    for (shortlist, 0..) |contact, i| {
        listing.writer.print("[{d}] {s} <{s}>\n", .{
            i, contact.nameSlice(), contact.addressSlice(),
        }) catch return null;
    }

    const prompt = std.fmt.allocPrint(arena,
        \\The user wants to send an email. Which of these contacts do they mean?
        \\
        \\Request: {s}
        \\
        \\Contacts (most frequently in contact first):
        \\{s}
        \\
        \\Reply with ONLY JSON: {{"index": <number>}}. Use -1 if the request does not clearly point at exactly one of them. Do not guess between similar names.
    , .{ request, listing.writer.buffered() }) catch return null;

    const answer = ollama.generateJson(io, arena, ollama_url, model, prompt) catch |err| {
        log.warn("contact selection unavailable ({s})", .{@errorName(err)});
        return null;
    };
    const parsed = std.json.parseFromValue(Choice, arena, answer, .{
        .ignore_unknown_fields = true,
    }) catch return null;

    const index = parsed.value.index;
    if (index < 0 or index >= shortlist.len) return null;
    return @intCast(index);
}

test "an address the owner typed is matched without consulting a model" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var contacts: [2]Contact = undefined;
    for (&contacts) |*contact| contact.* = std.mem.zeroes(Contact);
    @memcpy(contacts[0].address[0..17], "dana@example.org");
    @memcpy(contacts[1].address[0..20], "sam@example.com");

    // A URL that cannot be reached, proving no model call happens: if one
    // were attempted this would fall through and return null.
    const unreachable_url = "http://127.0.0.1:1";
    try std.testing.expectEqual(@as(?usize, 0), resolve(
        undefined,
        arena,
        unreachable_url,
        "nope",
        "email dana@example.org about thursday",
        &contacts,
    ));
    try std.testing.expectEqual(@as(?usize, 1), resolve(
        undefined,
        arena,
        unreachable_url,
        "nope",
        "send SAM@EXAMPLE.COM the notes",
        &contacts,
    ));
}

test "no contacts means no recipient, never a guess" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    try std.testing.expectEqual(@as(?usize, null), resolve(
        undefined,
        arena_state.allocator(),
        "http://127.0.0.1:1",
        "nope",
        "email dana",
        &.{},
    ));
}

test "addresses that cannot receive mail are excluded" {
    // Every one of these was in the top ten of a real mailbox by frequency.
    try std.testing.expect(!isWritable("no-reply@vendor.example"));
    try std.testing.expect(!isWritable("postmaster@amazonses.com"));
    try std.testing.expect(!isWritable("DMARC@bank.example"));
    try std.testing.expect(!isWritable("noreply-dmarc-support@google.com"));
    try std.testing.expect(!isWritable("MAILER-DAEMON@gmail.com"));

    // Real people and real team addresses stay.
    try std.testing.expect(isWritable("dana@example.org"));
    try std.testing.expect(isWritable("team@example.com"));
    try std.testing.expect(isWritable("support@vendor.example"));

    // Not an address at all.
    try std.testing.expect(!isWritable("nonsense"));
}

test "allowlisted senders sort ahead of everyone else" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var book: [3]Contact = undefined;
    for (&book) |*contact| contact.* = std.mem.zeroes(Contact);
    @memcpy(book[0].address[0..21], "hello@vendor.example"[0..21]);
    @memcpy(book[1].address[0..17], "dana@example.org");
    @memcpy(book[2].address[0..20], "sam@example.com");

    // example.org is allowlisted as a bare domain, sam by full address.
    const allowlist = [_][]const u8{ "example.org", "sam@example.com" };
    const sorted = try prioritise(arena, &book, &allowlist);

    try std.testing.expectEqualStrings("dana@example.org", sorted[0].addressSlice());
    try std.testing.expectEqualStrings("sam@example.com", sorted[1].addressSlice());
    try std.testing.expect(std.mem.startsWith(u8, sorted[2].addressSlice(), "hello@"));
}

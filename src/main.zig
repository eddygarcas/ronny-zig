//! Ronny, in Zig. Currently the IMAP watcher only.
//!
//! Connects to the mailbox, baselines to the current UIDNEXT so a first run
//! doesn't treat 50k existing messages as new, then sits in IDLE reporting
//! mail from allowlisted senders.
//!
//! Configuration comes from the environment:
//!   IMAP_USER, IMAP_APP_PASSWORD, optionally IMAP_HOST
//!   RONNY_SENDERS  comma-separated allowlist

const std = @import("std");
const imap = @import("imap.zig");

const MAX_NEW_PER_SCAN = 256;
const IDLE_TIMEOUT_SECONDS = 300;

const ConfigError = error{MissingEnvironmentVariable};

fn envOptional(init: std.process.Init, name: []const u8) !?[:0]u8 {
    const value = init.environ_map.get(name) orelse return null;
    return try init.arena.allocator().dupeZ(u8, value);
}

fn envRequired(init: std.process.Init, name: []const u8) ![:0]u8 {
    return (try envOptional(init, name)) orelse {
        std.log.err("missing environment variable {s}", .{name});
        return ConfigError.MissingEnvironmentVariable;
    };
}

fn parseAllowlist(allocator: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |piece| {
        const entry = std.mem.trim(u8, piece, " \t\r\n");
        if (entry.len > 0) try list.append(allocator, entry);
    }
    return list.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const user = try envRequired(init, "IMAP_USER");
    const password = try envRequired(init, "IMAP_APP_PASSWORD");
    const host = (try envOptional(init, "IMAP_HOST")) orelse try arena.dupeZ(u8, "imap.gmail.com");
    const senders_raw = init.environ_map.get("RONNY_SENDERS") orelse "";
    const allowlist = try parseAllowlist(arena, senders_raw);

    std.log.info("connecting to {s} as {s}", .{ host, user });
    var session = try imap.Session.connect(host, 993, user, password);
    defer session.deinit();

    const selection = try session.examineInbox();
    std.log.info("INBOX: {d} messages, uidnext {d}, uidvalidity {d}", .{
        selection.exists, selection.uid_next, selection.uid_validity,
    });
    std.log.info("watching {d} sender(s)", .{allowlist.len});
    if (allowlist.len == 0) {
        std.log.warn("allowlist is empty -- nothing will ever be reported", .{});
    }

    // Start from now. A fresh run must not treat the whole mailbox as new;
    // the Python version shipped that bug once and tried to backfill 50k
    // messages on first start.
    var next_uid = selection.uid_next;

    var buffer: [MAX_NEW_PER_SCAN]imap.Envelope = undefined;
    while (true) {
        const woke = session.idleWait(IDLE_TIMEOUT_SECONDS) catch |err| {
            std.log.err("IDLE failed: {s}", .{@errorName(err)});
            return err;
        };
        _ = woke; // rescan either way; the timeout is the keepalive and safety net

        const found = session.envelopesSince(next_uid, &buffer) catch |err| {
            std.log.err("fetch failed: {s}", .{@errorName(err)});
            continue;
        };

        var matched: usize = 0;
        for (found) |*envelope| {
            if (envelope.uid >= next_uid) next_uid = envelope.uid + 1;

            const sender = envelope.fromSlice();
            if (sender.len == 0) continue;
            if (!imap.senderMatches(sender, allowlist)) continue;

            matched += 1;
            std.log.info("MATCH uid={d} from={s} subject={s}", .{
                envelope.uid, sender, envelope.subjectSlice(),
            });
        }

        if (found.len > 0) {
            std.log.info("scanned {d} new message(s), {d} matched the allowlist", .{ found.len, matched });
        }
    }
}

test {
    _ = imap;
}

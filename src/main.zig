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
const state_mod = @import("state.zig");
const controller_mod = @import("controller.zig");

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
    const senders_path = (try envOptional(init, "RONNY_SENDERS_FILE")) orelse
        try arena.dupeZ(u8, "config/senders.yaml");
    const state_path = (try envOptional(init, "RONNY_STATE_FILE")) orelse
        try arena.dupeZ(u8, "data/state.json");
    const controller_state_path = (try envOptional(init, "RONNY_CONTROLLER_STATE_FILE")) orelse
        try arena.dupeZ(u8, "data/controller_state.json");

    var controller = controller_mod.Controller.init(init.io, arena, senders_path, controller_state_path);
    var state = state_mod.State.load(init.io, arena, state_path);

    std.log.info("connecting to {s} as {s}", .{ host, user });
    var session = try imap.Session.connect(host, 993, user, password);
    defer session.deinit();

    const selection = try session.examineInbox();
    std.log.info("INBOX: {d} messages, uidnext {d}, uidvalidity {d}", .{
        selection.exists, selection.uid_next, selection.uid_validity,
    });

    // Baseline to the mailbox's current UIDNEXT, not zero, so a first run
    // watches from now instead of replaying 50k messages.
    try state.syncUidValidity(selection.uid_validity, selection.uid_next -| 1);
    std.log.info("resuming from uid {d} (paused: {})", .{ state.lastUid(), controller.paused });

    var buffer: [MAX_NEW_PER_SCAN]imap.Envelope = undefined;
    while (true) {
        // Scan before waiting, not after. Anything that arrived while Ronny
        // was down should be reported on connect rather than sitting unseen
        // until the first IDLE wakeup.
        scanOnce(&session, &controller, &state, &buffer) catch |err| {
            std.log.err("scan failed: {s}", .{@errorName(err)});
        };

        const woke = session.idleWait(IDLE_TIMEOUT_SECONDS) catch |err| {
            std.log.err("IDLE failed: {s}", .{@errorName(err)});
            return err;
        };
        _ = woke; // rescan either way; the timeout is the keepalive and safety net
    }
}

fn scanOnce(
    session: *imap.Session,
    controller: *controller_mod.Controller,
    state: *state_mod.State,
    buffer: []imap.Envelope,
) !void {
    // Re-read per scan so edits made while running take effect without a
    // restart, the same as the Python version.
    const allowlist = try controller.senders();
    defer controller.freeSenders(allowlist);

    const found = try session.envelopesSince(state.lastUid() + 1, buffer);
    if (found.len == 0) return;

    var matched: usize = 0;
    for (found) |*envelope| {
        const sender = envelope.fromSlice();
        if (sender.len > 0 and imap.senderMatches(sender, allowlist)) {
            matched += 1;
            if (controller.paused) {
                std.log.info("paused -- not reporting uid={d} from={s}", .{ envelope.uid, sender });
            } else {
                std.log.info("MATCH uid={d} from={s} subject={s}", .{
                    envelope.uid, sender, envelope.subjectSlice(),
                });
            }
        }
        // Advance past every scanned message, matched or not, so the
        // watermark can't rewind and report the same mail twice.
        try state.advance(envelope.uid);
    }

    std.log.info("scanned {d} new message(s), {d} matched the allowlist", .{ found.len, matched });
}

test {
    _ = imap;
    _ = state_mod;
    _ = controller_mod;
}

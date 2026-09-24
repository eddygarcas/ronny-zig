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
const http = @import("http.zig");
const telegram = @import("telegram.zig");
const spam = @import("spam.zig");

/// Namespaced so each module's output is identifiable in the journal,
/// the way the Python version's per-module loggers were.
const log = std.log.scoped(.ronny);

const MAX_NEW_PER_SCAN = 256;
const IDLE_TIMEOUT_SECONDS = 300;

const ConfigError = error{MissingEnvironmentVariable};

/// Everything the notification pipeline needs, gathered once at startup.
const Config = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    ollama_url: []const u8,
    ollama_model: []const u8,
    telegram_token: []const u8,
    telegram_chat_id: []const u8,
};

fn envOptional(init: std.process.Init, name: []const u8) !?[:0]u8 {
    const value = init.environ_map.get(name) orelse return null;
    return try init.arena.allocator().dupeZ(u8, value);
}

fn envRequired(init: std.process.Init, name: []const u8) ![:0]u8 {
    return (try envOptional(init, name)) orelse {
        log.err("missing environment variable {s}", .{name});
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

    const cfg: Config = .{
        .io = init.io,
        .gpa = arena,
        .ollama_url = (try envOptional(init, "OLLAMA_URL")) orelse try arena.dupeZ(u8, "http://127.0.0.1:11434"),
        .ollama_model = (try envOptional(init, "OLLAMA_MODEL")) orelse try arena.dupeZ(u8, "qwen2.5"),
        .telegram_token = try envRequired(init, "TELEGRAM_BOT_TOKEN"),
        .telegram_chat_id = try envRequired(init, "TELEGRAM_OWNER_CHAT_ID"),
    };

    var controller = controller_mod.Controller.init(init.io, arena, senders_path, controller_state_path);
    var state = state_mod.State.load(init.io, arena, state_path);

    log.info("connecting to {s} as {s}", .{ host, user });
    var session = try imap.Session.connect(host, 993, user, password);
    defer session.deinit();

    const selection = try session.examineInbox();
    log.info("INBOX: {d} messages, uidnext {d}, uidvalidity {d}", .{
        selection.exists, selection.uid_next, selection.uid_validity,
    });

    // Baseline to the mailbox's current UIDNEXT, not zero, so a first run
    // watches from now instead of replaying 50k messages.
    try state.syncUidValidity(selection.uid_validity, selection.uid_next -| 1);
    log.info("resuming from uid {d} (paused: {})", .{ state.lastUid(), controller.paused });

    var buffer: [MAX_NEW_PER_SCAN]imap.Envelope = undefined;
    while (true) {
        // Scan before waiting, not after. Anything that arrived while Ronny
        // was down should be reported on connect rather than sitting unseen
        // until the first IDLE wakeup.
        scanOnce(cfg, &session, &controller, &state, &buffer) catch |err| {
            log.err("scan failed: {s}", .{@errorName(err)});
        };

        const woke = session.idleWait(IDLE_TIMEOUT_SECONDS) catch |err| {
            log.err("IDLE failed: {s}", .{@errorName(err)});
            return err;
        };
        _ = woke; // rescan either way; the timeout is the keepalive and safety net
    }
}

fn scanOnce(
    cfg: Config,
    session: *imap.Session,
    controller: *controller_mod.Controller,
    state: *state_mod.State,
    buffer: []imap.Envelope,
) !void {
    // Re-read per scan so edits made while running take effect without a
    // restart, the same as the Python version.
    const allowlist = try controller.senders();
    defer controller.freeSenders(allowlist);

    const watermark = state.lastUid();
    const found = try session.envelopesSince(watermark + 1, buffer);
    if (found.len == 0) return;

    var matched: usize = 0;
    var fresh: usize = 0;
    for (found) |*envelope| {
        // IMAP's "N:*" always returns the highest message even when N is past
        // it, so with no new mail the server keeps handing back the newest
        // one. Without this guard it would be re-notified on every scan; the
        // Python version filtered the same way.
        if (envelope.uid <= watermark) continue;
        fresh += 1;

        const sender = envelope.fromSlice();
        if (sender.len > 0 and imap.senderMatches(sender, allowlist)) {
            matched += 1;
            notifyIfWanted(cfg, session, controller, envelope, sender) catch |err| {
                log.err("could not handle uid={d}: {s}", .{ envelope.uid, @errorName(err) });
            };
        }
        // Advance past every scanned message, matched or not, so the
        // watermark can't rewind and report the same mail twice.
        try state.advance(envelope.uid);
    }

    if (fresh == 0) return;
    log.info("scanned {d} new message(s), {d} matched the allowlist", .{ fresh, matched });
}

/// The notification pipeline for one matching message: fetch it, run the
/// spam gate, and report it unless suppressed.
fn notifyIfWanted(
    cfg: Config,
    session: *imap.Session,
    controller: *controller_mod.Controller,
    envelope: *const imap.Envelope,
    sender: []const u8,
) !void {
    const subject = envelope.subjectSlice();

    if (controller.paused) {
        log.info("paused -- not reporting uid={d} from={s}", .{ envelope.uid, sender });
        return;
    }

    // Only matched mail gets a full fetch. Doing this for every message would
    // pull whole bodies for the entire mailbox.
    var message: imap.Message = undefined;
    try session.fetchMessage(envelope.uid, &message);

    const verdict = spam.evaluate(
        cfg.io, cfg.gpa, cfg.ollama_url, cfg.ollama_model,
        sender, subject, message.headersSlice(), message.bodySlice(),
    );

    if (verdict.is_spam) {
        log.info("suppressed uid={d} from={s} ({s})", .{ envelope.uid, sender, verdict.reason });
        return;
    }

    // A skipped check is flagged in the message itself, so it is never
    // mistaken for the model having cleared it.
    const suffix: []const u8 = if (verdict.checked) "" else " [spam check unavailable]";
    const text = try std.fmt.allocPrint(cfg.gpa, "\u{1F4E7} Ronny: mail from {s}\nSubject: {s}{s}", .{
        sender, subject, suffix,
    });
    defer cfg.gpa.free(text);

    var client: telegram.Client = .{
        .io = cfg.io,
        .gpa = cfg.gpa,
        .token = cfg.telegram_token,
        .owner_chat_id = cfg.telegram_chat_id,
    };
    try client.sendMessage(telegram.truncate(text));
    log.info("notified about mail from {s} ({s})", .{ sender, subject });
}

test {
    _ = imap;
    _ = state_mod;
    _ = controller_mod;
    _ = http;
    _ = telegram;
    _ = spam;
}

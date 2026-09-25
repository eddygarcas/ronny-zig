//! Ronny, in Zig. Two subcommands, deliberately two processes.
//!
//!   ronny watch  -- the mailbox watcher (the default)
//!   ronny bot    -- the Telegram control channel
//!
//! They are split rather than threaded because only one process may call
//! Telegram's getUpdates for a given token: a second poller gets 409 Conflict
//! and, worse, silently consumes updates the first one needed. Keeping them
//! separate means either half can be cut over from the Python service on its
//! own, and a crash in one does not take down the other.
//!
//! What they share is on disk: the allowlist file, the paused flag and the
//! settings. The watcher re-reads all three each scan, so a change made from
//! chat takes effect without a restart.
//!
//! Configuration comes from the environment; see .env.example.

const std = @import("std");
const bot_mod = @import("bot.zig");
const watchdog_mod = @import("watchdog.zig");
const imap = @import("imap.zig");
const state_mod = @import("state.zig");
const controller_mod = @import("controller.zig");
const http = @import("http.zig");
const telegram = @import("telegram.zig");
const spam = @import("spam.zig");
const intent = @import("intent.zig");
const decision = @import("decision.zig");
const transcribe = @import("transcribe.zig");
const summarize = @import("summarize.zig");
const ollama = @import("ollama.zig");
const findmail = @import("findmail.zig");
const rerank = @import("rerank.zig");
const attachments = @import("attachments.zig");
const contacts = @import("contacts.zig");
const settings = @import("settings.zig");
const interpret = @import("interpret.zig");
const headers = @import("headers.zig");
const mailer = @import("mailer.zig");

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

fn envFlag(init: std.process.Init, name: []const u8) bool {
    const value = init.environ_map.get(name) orelse return false;
    return std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "yes");
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

    // 0.16 hands the command line to main rather than exposing a global:
    // init.minimal.args, materialised into the process arena.
    const args = try init.minimal.args.toSlice(arena);
    const command: []const u8 = if (args.len > 1) args[1] else "watch";

    if (std.mem.eql(u8, command, "bot")) return runBot(init);
    if (std.mem.eql(u8, command, "watch")) return runWatcher(init);
    if (std.mem.eql(u8, command, "watchdog")) return runWatchdog(init);

    log.err("unknown command '{s}' -- expected 'watch', 'bot' or 'watchdog'", .{command});
    return error.UnknownCommand;
}

/// Its own process on purpose: a watchdog that dies with the thing it watches
/// cannot report that the thing died.
fn runWatchdog(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    return watchdog_mod.run(.{
        .io = init.io,
        .gpa = arena,
        .telegram_token = try envRequired(init, "TELEGRAM_BOT_TOKEN"),
        .telegram_owner_chat_id = (try envOptional(init, "TELEGRAM_OWNER_CHAT_ID")) orelse "",
        .ollama_url = (try envOptional(init, "OLLAMA_URL")) orelse "http://127.0.0.1:11434",
        .ollama_model = (try envOptional(init, "OLLAMA_MODEL")) orelse "qwen2.5",
    });
}

fn runBot(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    const senders_path = (try envOptional(init, "RONNY_SENDERS_FILE")) orelse
        try arena.dupeZ(u8, "config/senders.yaml");
    const controller_state_path = (try envOptional(init, "RONNY_CONTROLLER_STATE_FILE")) orelse
        try arena.dupeZ(u8, "data/controller_state.json");

    const settings_path = (try envOptional(init, "RONNY_SETTINGS_FILE")) orelse
        try arena.dupeZ(u8, "data/settings.json");

    var controller = controller_mod.Controller.init(init.io, arena, senders_path, controller_state_path);
    var settings_store = settings.Store.init(init.io, arena, settings_path);

    const cfg: bot_mod.Config = .{
        .io = init.io,
        .gpa = arena,
        .telegram_token = try envRequired(init, "TELEGRAM_BOT_TOKEN"),
        // Empty is valid: the bot then answers only /start, with the caller's
        // own chat id, so the owner can bootstrap it.
        .telegram_owner_chat_id = (try envOptional(init, "TELEGRAM_OWNER_CHAT_ID")) orelse "",
        .imap_host = (try envOptional(init, "IMAP_HOST")) orelse try arena.dupeZ(u8, "imap.gmail.com"),
        .imap_user = try envRequired(init, "IMAP_USER"),
        .imap_password = try envRequired(init, "IMAP_APP_PASSWORD"),
        .smtp_host = (try envOptional(init, "SMTP_HOST")) orelse "smtp.gmail.com",
        .ollama_url = (try envOptional(init, "OLLAMA_URL")) orelse "http://127.0.0.1:11434",
        .ollama_model = (try envOptional(init, "OLLAMA_MODEL")) orelse "qwen2.5",
        .typesafe_api_key = (try envOptional(init, "TYPESAFE_API_KEY")) orelse "",
        .jev_model = (try envOptional(init, "JEV_MODEL")) orelse "jev-latest",
        .whisper_model_path = try envOptional(init, "WHISPER_MODEL_PATH"),
        .whisper_languages = (try envOptional(init, "WHISPER_LANGUAGES")) orelse "en,es",
        // Stays in the environment on purpose: a safety property a chat
        // message can switch off is not one. See settings.zig.
        .voice_can_confirm_send = envFlag(init, "VOICE_CAN_CONFIRM_SEND"),
        // Off by default: this is the one setting that lets message text
        // leave the machine. See rerank.zig.
        .typesafe_rank_mail = envFlag(init, "TYPESAFE_RANK_MAIL"),
    };

    var bot = bot_mod.Bot.init(cfg, &controller, &settings_store);
    defer bot.deinit();
    try bot.run();
}

fn runWatcher(init: std.process.Init) !void {
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
    const settings_path = (try envOptional(init, "RONNY_SETTINGS_FILE")) orelse
        try arena.dupeZ(u8, "data/settings.json");

    const cfg: Config = .{
        .io = init.io,
        .gpa = arena,
        .ollama_url = (try envOptional(init, "OLLAMA_URL")) orelse try arena.dupeZ(u8, "http://127.0.0.1:11434"),
        .ollama_model = (try envOptional(init, "OLLAMA_MODEL")) orelse try arena.dupeZ(u8, "qwen2.5"),
        .telegram_token = try envRequired(init, "TELEGRAM_BOT_TOKEN"),
        .telegram_chat_id = try envRequired(init, "TELEGRAM_OWNER_CHAT_ID"),
    };

    var controller = controller_mod.Controller.init(init.io, arena, senders_path, controller_state_path);
    var settings_store = settings.Store.init(init.io, arena, settings_path);
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
    var was_quiet = false;
    while (true) {
        // Quiet hours stop the *scan*, not the notification. The watermark
        // stays where it is, so nothing is consumed and marked seen, and
        // everything that arrived overnight is reported in one go when the
        // window ends. Dropping notifications instead would be the obvious
        // implementation and would lose mail silently.
        //
        // Re-read each time round: the bot is a separate process, and it is
        // the one that writes this.
        const quiet = settings_store.reload().isQuietNow();
        if (quiet != was_quiet) {
            log.info("quiet hours {s} -- {s}", .{
                if (quiet) "started" else "ended",
                if (quiet) "holding notifications until they end" else "reporting anything that arrived",
            });
            was_quiet = quiet;
        }

        // Scan before waiting, not after. Anything that arrived while Ronny
        // was down should be reported on connect rather than sitting unseen
        // until the first IDLE wakeup.
        if (!quiet) scanOnce(cfg, &session, &controller, &state, &buffer) catch |err| {
            log.err("scan failed: {s}", .{@errorName(err)});
        };

        const woke = session.idleWait(IDLE_TIMEOUT_SECONDS) catch |err| {
            log.err("IDLE failed: {s}", .{@errorName(err)});
            return err;
        };

        // A hang produces no error line, so without this the watchdog has no
        // way to tell a quiet mailbox from a wedged loop. The marker string is
        // shared with watchdog.zig rather than written out twice.
        if (!woke) log.info("{s}, last uid {d}", .{ watchdog_mod.HEARTBEAT_MARKER, state.lastUid() });
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
/// spam gate, summarise it, and report it unless suppressed.
fn notifyIfWanted(
    cfg: Config,
    session: *imap.Session,
    controller: *controller_mod.Controller,
    envelope: *const imap.Envelope,
    sender: []const u8,
) !void {
    const subject = envelope.subjectSlice();

    // Re-read rather than trust the value cached at startup: the bot is a
    // separate process, and it is the one that writes this flag.
    if (controller.isPaused()) {
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

    const summary = summarize.forNotification(
        cfg.io, cfg.gpa, cfg.ollama_url, cfg.ollama_model,
        sender, subject, message.bodySlice(),
    );
    defer if (summary) |owned| cfg.gpa.free(owned);

    const text = if (summary) |body|
        try std.fmt.allocPrint(cfg.gpa, "\u{1F4E7} Ronny: mail from {s}\nSubject: {s}{s}\n\n{s}", .{
            sender, subject, suffix, body,
        })
    else
        try std.fmt.allocPrint(cfg.gpa, "\u{1F4E7} Ronny: mail from {s}\nSubject: {s}{s}", .{
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
    _ = intent;
    _ = decision;
    _ = transcribe;
    _ = summarize;
    _ = ollama;
    _ = findmail;
    _ = rerank;
    _ = attachments;
    _ = contacts;
    _ = settings;
    _ = bot_mod;
    _ = watchdog_mod;
    _ = interpret;
    _ = headers;
    _ = mailer;
}

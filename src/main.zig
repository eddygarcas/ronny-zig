//! Ronny, in Zig. Two subcommands, deliberately two processes.
//!
//!   ronny watch          -- the mailbox watcher (the default)
//!   ronny bot            -- the Telegram control channel
//!   ronny watchdog       -- watches the other two
//!   ronny calendar-auth  -- the one-time Google Calendar login
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
const dates = @import("dates.zig");
const attachments = @import("attachments.zig");
const contacts = @import("contacts.zig");
const settings = @import("settings.zig");
const speech = @import("speech.zig");
const interpret = @import("interpret.zig");
const headers = @import("headers.zig");
const mailer = @import("mailer.zig");
const gcal = @import("gcal.zig");
const appointment = @import("appointment.zig");
const reminders = @import("reminders.zig");

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
    /// Null when piper is not configured: summaries are then text whatever
    /// the chat setting says.
    speech: ?speech.Config,
    /// The watcher re-reads this per notification; the bot writes it.
    settings: *settings.Store,
};

/// An empty value counts as unset. `.env.example` lists every key, and a
/// copied `CALENDAR_TIMEZONE=` with nothing after it reached Google as
/// `"timeZone":""`, which it refused as missing -- three times, on a real
/// appointment. Nothing in Ronny means anything by an empty setting, so
/// treating it as absent is always the right reading.
fn envOptional(init: std.process.Init, name: []const u8) !?[:0]u8 {
    const value = init.environ_map.get(name) orelse return null;
    if (value.len == 0) return null;
    return try init.arena.allocator().dupeZ(u8, value);
}

fn envFlag(init: std.process.Init, name: []const u8) bool {
    const value = init.environ_map.get(name) orelse return false;
    return std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "yes");
}

/// Text-to-speech is optional and needs four things from .env. The binary
/// being set is what switches it on; the rest default to what a piper venv
/// laid out next to it looks like, so most installs set only PIPER_BIN.
fn loadSpeech(init: std.process.Init) !?speech.Config {
    const arena = init.arena.allocator();
    const bin = (try envOptional(init, "PIPER_BIN")) orelse return null;
    const voices_dir = (try envOptional(init, "PIPER_VOICES_DIR")) orelse blk: {
        // <venv>/bin/piper -> <venv>/voices
        const venv = std.fs.path.dirname(std.fs.path.dirname(bin) orelse ".") orelse ".";
        break :blk try std.fmt.allocPrintSentinel(arena, "{s}/voices", .{venv}, 0);
    };
    return .{
        .bin = bin,
        .voices_dir = voices_dir,
        .voice_en = (try envOptional(init, "PIPER_VOICE_EN")) orelse try arena.dupeZ(u8, "en_US-lessac-medium"),
        .voice_es = (try envOptional(init, "PIPER_VOICE_ES")) orelse try arena.dupeZ(u8, "es_ES-davefx-medium"),
    };
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
    if (std.mem.eql(u8, command, "calendar-auth")) {
        const mode: gcal.AuthMode = if (args.len > 2 and std.mem.eql(u8, args[2], "paste")) .paste else .listen;
        return runCalendarAuth(init, mode);
    }

    log.err("unknown command '{s}' -- expected 'watch', 'bot', 'watchdog' or 'calendar-auth'", .{command});
    return error.UnknownCommand;
}

/// Run by hand, once, on the machine Ronny lives on. Everything else about
/// the calendar happens inside `ronny bot`.
fn runCalendarAuth(init: std.process.Init, mode: gcal.AuthMode) !void {
    const cfg = (try loadCalendar(init)) orelse {
        log.err("GOOGLE_CLIENT_ID is not set in .env -- see the README's calendar section", .{});
        return ConfigError.MissingEnvironmentVariable;
    };
    try gcal.authorize(init.io, init.arena.allocator(), cfg, mode);
}

/// The IANA zone this machine is set to, from the /etc/localtime symlink
/// (".../zoneinfo/Europe/Madrid"). Google needs the name, not an offset, so
/// that an appointment in March keeps its clock time across the DST change.
fn systemTimezone(io: std.Io, arena: std.mem.Allocator) ?[]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.readLinkAbsolute(io, "/etc/localtime", &buffer) catch return null;
    const target = buffer[0..len];
    const marker = "zoneinfo/";
    const at = std.mem.indexOf(u8, target, marker) orelse return null;
    const name = target[at + marker.len ..];
    if (name.len == 0) return null;
    return arena.dupe(u8, name) catch null;
}

/// Google Calendar is optional and switched on by the client id. The rest
/// default to what a single-owner install looks like.
fn loadCalendar(init: std.process.Init) !?gcal.Config {
    const arena = init.arena.allocator();
    const client_id = (try envOptional(init, "GOOGLE_CLIENT_ID")) orelse return null;
    const timezone = (try envOptional(init, "CALENDAR_TIMEZONE")) orelse systemTimezone(init.io, arena) orelse {
        log.err("CALENDAR_TIMEZONE is not set and /etc/localtime does not name a zone", .{});
        return ConfigError.MissingEnvironmentVariable;
    };
    const port_text = (try envOptional(init, "GOOGLE_OAUTH_PORT")) orelse "8765";
    return .{
        .client_id = client_id,
        .client_secret = (try envOptional(init, "GOOGLE_CLIENT_SECRET")) orelse "",
        .token_path = (try envOptional(init, "GOOGLE_TOKEN_FILE")) orelse try arena.dupeZ(u8, "data/google_token.json"),
        .calendar_id = (try envOptional(init, "GOOGLE_CALENDAR_ID")) orelse "primary",
        .timezone = timezone,
        .auth_port = std.fmt.parseInt(u16, port_text, 10) catch {
            log.err("GOOGLE_OAUTH_PORT is not a port number: {s}", .{port_text});
            return ConfigError.MissingEnvironmentVariable;
        },
    };
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
        .speech = try loadSpeech(init),
        .calendar = try loadCalendar(init),
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

    var controller = controller_mod.Controller.init(init.io, arena, senders_path, controller_state_path);
    var settings_store = settings.Store.init(init.io, arena, settings_path);

    const cfg: Config = .{
        .io = init.io,
        .gpa = arena,
        .ollama_url = (try envOptional(init, "OLLAMA_URL")) orelse try arena.dupeZ(u8, "http://127.0.0.1:11434"),
        .ollama_model = (try envOptional(init, "OLLAMA_MODEL")) orelse try arena.dupeZ(u8, "qwen2.5"),
        .telegram_token = try envRequired(init, "TELEGRAM_BOT_TOKEN"),
        .telegram_chat_id = try envRequired(init, "TELEGRAM_OWNER_CHAT_ID"),
        .speech = try loadSpeech(init),
        .settings = &settings_store,
    };
    if (cfg.speech) |tts| log.info("voice summaries available: piper at {s}", .{tts.bin});
    var state = state_mod.State.load(init.io, arena, state_path);

    var buffer: [MAX_NEW_PER_SCAN]imap.Envelope = undefined;
    var watch: Watch = .{
        .cfg = cfg,
        .host = host,
        .user = user,
        .password = password,
        .session = try openInbox(host, user, password, &state),
        .controller = &controller,
        .state = &state,
        .buffer = &buffer,
    };
    defer watch.session.deinit();
    log.info("resuming from uid {d} (paused: {})", .{ state.lastUid(), controller.paused });

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
        if (!quiet) {
            const scanned = scanRecovering(&watch) catch |err| {
                log.err("scan failed, and reconnecting failed: {s}", .{@errorName(err)});
                return err;
            };
            if (scanned.persisted) |err| {
                log.err("scan failed: {s}", .{@errorName(err)});
            } else if (scanned.dropped) |err| {
                log.warn(RECONNECTED_FORMAT, .{ @errorName(err), "a scan" });
            }
        }

        const idled = idleRecovering(&watch, IDLE_TIMEOUT_SECONDS) catch |err| {
            log.err("IDLE failed, and reconnecting failed: {s}", .{@errorName(err)});
            return err;
        };
        if (idled.dropped) |err| log.warn(RECONNECTED_FORMAT, .{ @errorName(err), "IDLE" });
        const woke = idled.woke;

        // A hang produces no error line, so without this the watchdog has no
        // way to tell a quiet mailbox from a wedged loop. The marker string is
        // shared with watchdog.zig rather than written out twice.
        if (!woke) log.info("{s}, last uid {d}", .{ watchdog_mod.HEARTBEAT_MARKER, state.lastUid() });
    }
}

/// Connects, selects INBOX read-only, and reconciles the watermark with it.
/// Used at startup and again whenever Gmail drops the connection.
fn openInbox(
    host: [:0]const u8,
    user: [:0]const u8,
    password: [:0]const u8,
    state: *state_mod.State,
) !imap.Session {
    log.info("connecting to {s} as {s}", .{ host, user });
    var session = try imap.Session.connect(host, 993, user, password);
    errdefer session.deinit();

    const selection = try session.examineInbox();
    log.info("INBOX: {d} messages, uidnext {d}, uidvalidity {d}", .{
        selection.exists, selection.uid_next, selection.uid_validity,
    });

    // Baseline to the mailbox's current UIDNEXT, not zero, so a first run
    // watches from now instead of replaying 50k messages. On a reconnect the
    // uidvalidity is unchanged and the watermark is kept as it is.
    try state.syncUidValidity(selection.uid_validity, selection.uid_next -| 1);
    return session;
}

/// The watcher's mailbox connection, and what it takes to open another.
const Watch = struct {
    cfg: Config,
    host: [:0]const u8,
    user: [:0]const u8,
    password: [:0]const u8,
    session: imap.Session,
    controller: *controller_mod.Controller,
    state: *state_mod.State,
    buffer: []imap.Envelope,

    fn scan(self: *Watch) !void {
        return scanOnce(self.cfg, &self.session, self.controller, self.state, self.buffer);
    }

    fn idle(self: *Watch, timeout_seconds: u31) !bool {
        return self.session.idleWait(timeout_seconds);
    }

    /// The new session is opened before the old one is freed, so a failed
    /// reconnect leaves a session that is still safe to deinit on the way out.
    fn reconnect(self: *Watch) !void {
        const fresh = try openInbox(self.host, self.user, self.password, self.state);
        self.session.deinit();
        self.session = fresh;
    }
};

/// Logged when a fresh connection cleared the failure. Deliberately matches
/// none of the watchdog's incident needles -- see the test below.
const RECONNECTED_FORMAT = "IMAP connection dropped ({s} during {s}); reconnected";

/// What a failure on the mailbox connection turned out to be.
///
/// Gmail drops long-lived IDLE connections every few hours. The watcher used
/// to exit on that and leave the reconnect to systemd, and the journal for
/// 2026-09-29/30 shows the cost: eleven exits, each one writing "scan
/// failed", "libetpan returned 4" and "Main process exited", and each one
/// paging the owner -- twelve alerts in a day for a connection doing what
/// Gmail connections do. Nothing was lost, since the watermark survives a
/// restart; the fault was only in treating routine as an incident.
///
/// So a failure is answered with a fresh connection first, and only what
/// survives one is reported as a fault.
const Recovery = struct {
    /// Cleared by a fresh connection: routine, logged as a warning.
    dropped: ?anyerror = null,
    /// Still failing on a fresh connection: a real fault, logged as one.
    persisted: ?anyerror = null,
};

/// Scans; on failure reconnects once and scans again. Returns an error only
/// when the reconnect itself fails, which the caller exits on.
fn scanRecovering(watch: anytype) !Recovery {
    watch.scan() catch |first| {
        try watch.reconnect();
        watch.scan() catch |again| return .{ .dropped = first, .persisted = again };
        return .{ .dropped = first };
    };
    return .{};
}

const IdleOutcome = struct {
    woke: bool,
    dropped: ?anyerror = null,
};

/// Waits in IDLE; on failure reconnects and reports a wakeup, so the loop
/// rescans for anything that arrived while the connection was down.
fn idleRecovering(watch: anytype, timeout_seconds: u31) !IdleOutcome {
    const woke = watch.idle(timeout_seconds) catch |first| {
        try watch.reconnect();
        return .{ .woke = true, .dropped = first };
    };
    return .{ .woke = woke };
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

    // Re-read here too: the bot writes these, and "summaries as voice" said
    // in chat should apply to the next mail, not the next restart.
    const prefs = cfg.settings.reload();

    const summary = summarize.forNotification(
        cfg.io, cfg.gpa, cfg.ollama_url, cfg.ollama_model, prefs.language,
        sender, subject, message.bodySlice(),
    );
    defer if (summary) |owned| cfg.gpa.free(owned);

    const header = try std.fmt.allocPrint(cfg.gpa, "\u{1F4E7} Ronny: mail from {s}\nSubject: {s}{s}", .{
        sender, subject, suffix,
    });
    defer cfg.gpa.free(header);

    const text = if (summary) |body|
        try std.fmt.allocPrint(cfg.gpa, "{s}\n\n{s}", .{ header, body })
    else
        try cfg.gpa.dupe(u8, header);
    defer cfg.gpa.free(text);

    var client: telegram.Client = .{
        .io = cfg.io,
        .gpa = cfg.gpa,
        .token = cfg.telegram_token,
        .owner_chat_id = cfg.telegram_chat_id,
    };

    // A voice summary is the header as caption and the summary as audio.
    // Anything going wrong on that path -- piper missing, ffmpeg failing,
    // the upload refused -- sends the text instead: the notification is
    // the service, the voice is a nicety on top of it.
    if (prefs.summaries == .voice and summary != null) {
        if (cfg.speech) |tts| {
            if (speakAndSend(cfg, &client, tts.voiceFor(&prefs), header, summary.?)) {
                log.info("notified about mail from {s} ({s}) by voice", .{ sender, subject });
                return;
            }
        } else {
            log.warn("summaries are set to voice but PIPER_BIN is not configured; sending text", .{});
        }
    }

    try client.sendMessage(telegram.truncate(text));
    log.info("notified about mail from {s} ({s})", .{ sender, subject });
}

fn speakAndSend(
    cfg: Config,
    client: *telegram.Client,
    voice: []const u8,
    caption: []const u8,
    summary: []const u8,
) bool {
    var arena_state: std.heap.ArenaAllocator = .init(cfg.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const audio = speech.synthesize(cfg.io, arena, cfg.speech.?, voice, summary) catch |err| {
        log.warn("could not speak the summary ({s}); sending text", .{@errorName(err)});
        return false;
    };
    client.sendVoice(arena, audio, caption) catch |err| {
        log.warn("voice message not sent ({s}); sending text", .{@errorName(err)});
        return false;
    };
    return true;
}

/// Stands in for the watcher's mailbox connection, failing the way the
/// journal showed Gmail dropping it.
const FakeWatch = struct {
    failing_scans: u8 = 0,
    failing_idles: u8 = 0,
    reconnect_fails: bool = false,
    scans: u8 = 0,
    reconnects: u8 = 0,

    fn scan(self: *FakeWatch) !void {
        self.scans += 1;
        if (self.failing_scans > 0) {
            self.failing_scans -= 1;
            return error.Fetch;
        }
    }

    fn idle(self: *FakeWatch, _: u31) !bool {
        if (self.failing_idles > 0) {
            self.failing_idles -= 1;
            return error.ConnectionLost;
        }
        return false;
    }

    fn reconnect(self: *FakeWatch) !void {
        self.reconnects += 1;
        if (self.reconnect_fails) return error.Connect;
    }
};

test "a scan that fails on a dropped connection reconnects and scans again" {
    // The journal, 2026-09-29/30, eleven times: IDLE woke, the scan failed
    // with Fetch, IDLE then got libetpan 4 and the watcher exited -- and the
    // owner was paged for each one.
    var watch: FakeWatch = .{ .failing_scans = 1 };
    const outcome = try scanRecovering(&watch);
    try std.testing.expectEqual(@as(u8, 1), watch.reconnects);
    try std.testing.expectEqual(@as(u8, 2), watch.scans);
    try std.testing.expectEqual(@as(?anyerror, error.Fetch), outcome.dropped);
    try std.testing.expectEqual(@as(?anyerror, null), outcome.persisted);
}

test "a scan that still fails on a fresh connection is reported as a fault" {
    var watch: FakeWatch = .{ .failing_scans = 2 };
    const outcome = try scanRecovering(&watch);
    try std.testing.expectEqual(@as(u8, 1), watch.reconnects);
    try std.testing.expectEqual(@as(?anyerror, error.Fetch), outcome.persisted);
}

test "a healthy scan does not reconnect" {
    var watch: FakeWatch = .{};
    const outcome = try scanRecovering(&watch);
    try std.testing.expectEqual(@as(u8, 0), watch.reconnects);
    try std.testing.expectEqual(@as(?anyerror, null), outcome.dropped);
}

test "an IDLE on a dropped connection reconnects and asks for a rescan" {
    var watch: FakeWatch = .{ .failing_idles = 1 };
    const outcome = try idleRecovering(&watch, IDLE_TIMEOUT_SECONDS);
    try std.testing.expectEqual(@as(u8, 1), watch.reconnects);
    // Mail may have arrived while the connection was down.
    try std.testing.expect(outcome.woke);
    try std.testing.expectEqual(@as(?anyerror, error.ConnectionLost), outcome.dropped);
}

test "a reconnect that fails is still an error, so systemd and the watchdog see it" {
    var scan_watch: FakeWatch = .{ .failing_scans = 1, .reconnect_fails = true };
    try std.testing.expectError(error.Connect, scanRecovering(&scan_watch));
    var idle_watch: FakeWatch = .{ .failing_idles = 1, .reconnect_fails = true };
    try std.testing.expectError(error.Connect, idleRecovering(&idle_watch, IDLE_TIMEOUT_SECONDS));
}

test "a reconnect is logged as routine, not as an incident" {
    // If this line ever matched a watchdog needle, every Gmail drop would
    // page the owner again.
    const line = "warning(ronny): " ++ std.fmt.comptimePrint(RECONNECTED_FORMAT, .{ "Fetch", "a scan" });
    try std.testing.expect(watchdog_mod.classify(line) == null);
    const idle_line = "warning(ronny): " ++ std.fmt.comptimePrint(RECONNECTED_FORMAT, .{ "ConnectionLost", "IDLE" });
    try std.testing.expect(watchdog_mod.classify(idle_line) == null);
    // And a reconnect that fails still does.
    try std.testing.expect(watchdog_mod.classify("error(ronny): scan failed, and reconnecting failed: Connect") != null);
}

test {
    _ = speech;
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
    _ = dates;
    _ = attachments;
    _ = contacts;
    _ = settings;
    _ = bot_mod;
    _ = watchdog_mod;
    _ = interpret;
    _ = headers;
    _ = gcal;
    _ = appointment;
    _ = reminders;
    _ = mailer;
}

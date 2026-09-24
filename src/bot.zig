//! The Telegram control channel: the loop that turns what the owner says into
//! one of Ronny's actions.
//!
//! Port of `ronny/telegram_bot.py`. The shape that matters:
//!
//! - **A pending reply is decided deterministically.** Plain "yes" sends,
//!   plain "no" discards, and both are resolved by decision.zig rather than by
//!   a model. Anything unclear leaves the draft pending and asks again. A bare
//!   yes/no with nothing pending never reaches the classifier at all -- a
//!   stray "yes" once became a brand-new invented draft, one more "yes" from
//!   being sent.
//!
//! - **A reply can only target a message Ronny has already shown.** The
//!   recipient comes from that message's real headers, so a hallucinated
//!   address is structurally impossible.
//!
//! - **The owner is the only user.** Until TELEGRAM_OWNER_CHAT_ID is set the
//!   bot answers only /start, with the sender's own chat id; after that,
//!   anyone else gets a canned refusal.
//!
//! Only one process may call getUpdates for a token -- a second poller gets
//! 409 Conflict and, worse, silently consumes updates the first one needed.
//! That is why this is its own subcommand rather than a thread inside the
//! watcher: the two can be cut over independently.

const std = @import("std");
const imap = @import("imap.zig");
const telegram = @import("telegram.zig");
const controller_mod = @import("controller.zig");
const interpret_mod = @import("interpret.zig");
const decision_mod = @import("decision.zig");
const summarize_mod = @import("summarize.zig");
const findmail = @import("findmail.zig");
const transcribe = @import("transcribe.zig");
const headers_mod = @import("headers.zig");
const mailer = @import("mailer.zig");
const attachments_mod = @import("attachments.zig");
const contacts_mod = @import("contacts.zig");

const log = std.log.scoped(.bot);

pub const MAX_HISTORY = 6;
/// A drafted reply expires, so a forgotten draft cannot be confirmed hours
/// later against a thread that has moved on.
pub const PENDING_REPLY_TTL_SECONDS = 900;
pub const DEFAULT_DAYS = 14;
pub const SEARCH_RESULT_LIMIT = 30;
const POLL_TIMEOUT_SECONDS = 30;
const RETRY_DELAY_SECONDS = 10;
/// The vocabulary costs an IMAP scan, so it is cached between voice notes.
const VOCAB_TTL_SECONDS = 6 * 3600;
const VOCAB_DAYS = 180;
const VOCAB_ENTRY = 96;
const VOCAB_MAX = 300;

extern fn ronny_sender_vocabulary(session: *imap.c.mailimap, days: c_int, out: [*]u8, max_out: c_int) c_int;

pub const HELP_TEXT =
    \\Commands (or just tell me in plain language):
    \\/status - show current state
    \\/senders - list the sender allowlist
    \\/add <address-or-domain> - add to the allowlist
    \\/remove <address-or-domain> - remove from the allowlist
    \\/search <address-or-domain> [days] - list recent mail (dates + subjects)
    \\/find <what it was about> - search mail by topic, not sender
    \\/read <address-or-domain> [days] - show the latest email's content
    \\/summarize <address-or-domain> [days] - summarize the latest email
    \\/attachments - list the files attached to the last email I showed you
    \\/get <name> - send me one of those files
    \\/compose <who> <what to say> - draft a NEW email to someone
    \\/reply <text> - draft a reply to the last email I showed you
    \\/confirm - send the drafted reply
    \\/cancel - discard the drafted reply
    \\/pause - stop notifications temporarily
    \\/resume - resume notifications
    \\
    \\When a reply is drafted, just answer 'yes' to send or 'no' to discard.
    \\I never send email until you say yes.
;

pub const Config = struct {
    io: std.Io,
    gpa: std.mem.Allocator,

    telegram_token: []const u8,
    /// Empty until the owner has run /start and put their id in .env.
    telegram_owner_chat_id: []const u8,

    imap_host: [:0]const u8,
    imap_port: u16 = 993,
    imap_user: [:0]const u8,
    imap_password: [:0]const u8,

    smtp_host: []const u8 = "smtp.gmail.com",
    smtp_port: u16 = 587,

    ollama_url: []const u8,
    ollama_model: []const u8,
    typesafe_api_key: []const u8 = "",
    jev_model: []const u8 = "jev-latest",

    /// Voice notes are off unless a whisper model is configured.
    whisper_model_path: ?[:0]const u8 = null,
    /// Spoken yes/no never confirms a send by default: a misheard word would
    /// send mail the owner did not approve.
    voice_can_confirm_send: bool = false,
};

/// The last message Ronny actually fetched and showed. A reply may only ever
/// target this, which is what keeps recipients coming from real headers.
const LastMessage = struct {
    arena: std.heap.ArenaAllocator,
    /// Needed to fetch an attachment later; the metadata comes back with the
    /// message but the bytes are pulled on demand.
    uid: u32,
    from: []const u8,
    reply_to: ?[]const u8,
    subject: []const u8,
    date: []const u8,
    body: []const u8,
    message_id: []const u8,
    references: []const u8,
    /// Ranked: real files first, inline ones after. The numbering the owner
    /// sees in a listing has to survive into the request that follows it.
    attachments: []const imap.Attachment,
};

const Pending = struct {
    arena: std.heap.ArenaAllocator,
    to: []const u8,
    subject: []const u8,
    body: []const u8,
    in_reply_to: []const u8,
    references: []const u8,
    created_ns: i96,
    /// Shown in the draft preview. The owner has to see what they are
    /// approving; a file they did not notice is a file they did not approve.
    attachments: []const mailer.Attachment,
};

/// A file the owner uploaded, waiting to be attached to the next draft.
///
/// Held separately from the draft because the two arrive in either order --
/// "reply saying here you go" then the file, or the file with a caption.
const Staged = struct {
    arena: std.heap.ArenaAllocator,
    filename: []const u8,
    content_type: []const u8,
    bytes: []const u8,
    created_ns: i96,
};

const Turn = struct {
    owner: []u8,
    assistant: []u8,
};

pub const Bot = struct {
    cfg: Config,
    controller: *controller_mod.Controller,
    client: telegram.Client,

    session: ?imap.Session = null,
    last_message: ?LastMessage = null,
    pending: ?Pending = null,
    staged: ?Staged = null,

    history: std.ArrayList(Turn) = .empty,
    vocabulary: []const []const u8 = &.{},
    vocabulary_arena: ?std.heap.ArenaAllocator = null,
    vocabulary_refreshed_ns: i96 = 0,
    whisper_loaded: bool = false,

    pub fn init(cfg: Config, controller: *controller_mod.Controller) Bot {
        return .{
            .cfg = cfg,
            .controller = controller,
            .client = .{
                .io = cfg.io,
                .gpa = cfg.gpa,
                .token = cfg.telegram_token,
                .owner_chat_id = cfg.telegram_owner_chat_id,
            },
        };
    }

    pub fn deinit(self: *Bot) void {
        if (self.session) |*session| session.deinit();
        if (self.last_message) |*message| message.arena.deinit();
        if (self.pending) |*pending| pending.arena.deinit();
        if (self.staged) |*staged| staged.arena.deinit();
        if (self.vocabulary_arena) |*arena| arena.deinit();
        for (self.history.items) |turn| {
            self.cfg.gpa.free(turn.owner);
            self.cfg.gpa.free(turn.assistant);
        }
        self.history.deinit(self.cfg.gpa);
        if (self.whisper_loaded) transcribe.unload();
    }

    // ---- the loop ----

    pub fn run(self: *Bot) !void {
        if (self.cfg.whisper_model_path) |path| {
            transcribe.load(path) catch |err| {
                // Not fatal: typing still works, and saying so beats failing
                // to start over a feature the owner may not use today.
                log.warn("voice notes disabled -- whisper model did not load ({s})", .{@errorName(err)});
            };
            self.whisper_loaded = true;
        }

        log.info("telegram polling started", .{});
        while (true) {
            self.pollOnce() catch |err| {
                log.err("poll failed ({s}); retrying in {d}s", .{ @errorName(err), RETRY_DELAY_SECONDS });
                // A failing poll is usually the network or a 409 from a second
                // poller; backing off keeps it from spinning.
                self.cfg.io.sleep(
                    .fromNanoseconds(RETRY_DELAY_SECONDS * std.time.ns_per_s),
                    .awake,
                ) catch return err;
            };
        }
    }

    fn pollOnce(self: *Bot) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.cfg.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const updates = try self.client.getUpdates(arena, POLL_TIMEOUT_SECONDS);
        for (updates.value.result) |update| {
            const message = update.message orelse continue;
            if (message.chat.id == 0) continue;

            // Each update gets its own scratch space, so one long reply does
            // not hold memory for the rest of the batch.
            var update_arena: std.heap.ArenaAllocator = .init(self.cfg.gpa);
            defer update_arena.deinit();

            self.handleUpdate(update_arena.allocator(), message) catch |err| {
                log.err("could not handle an update: {s}", .{@errorName(err)});
            };
        }
    }

    fn handleUpdate(self: *Bot, arena: std.mem.Allocator, message: telegram.Message) !void {
        const chat_id = try std.fmt.allocPrint(arena, "{d}", .{message.chat.id});

        if (message.text) |raw| {
            const text = std.mem.trim(u8, raw, " \t\r\n");
            if (text.len > 0) return self.handleText(arena, chat_id, text);
        }
        if (message.voice orelse message.audio) |voice| {
            return self.handleVoice(arena, chat_id, voice);
        }
        if (message.document) |document| {
            return self.handleUpload(arena, chat_id, document, message.caption);
        }
        if (message.photo) |sizes| {
            if (sizes.len == 0) return;
            // Telegram sends every rendition smallest-first and strips the
            // filename, so take the largest and name it here.
            const largest = sizes[sizes.len - 1];
            return self.handleUpload(arena, chat_id, .{
                .file_id = largest.file_id,
                .file_name = "photo.jpg",
                .mime_type = "image/jpeg",
                .file_size = largest.file_size,
            }, message.caption);
        }
    }

    /// Takes an uploaded file and holds it for the next draft.
    ///
    /// Staged rather than acted on immediately, because the file and the
    /// instruction arrive in either order: a caption with the upload, or a
    /// "reply saying here you go" before or after it.
    fn handleUpload(
        self: *Bot,
        arena: std.mem.Allocator,
        chat_id: []const u8,
        document: telegram.Document,
        caption: ?[]const u8,
    ) !void {
        if (!try self.ownerCheck(arena, chat_id, "")) return;

        const filename = document.file_name orelse "attachment";
        var size_buf: [32]u8 = undefined;
        if (document.file_size > mailer.MAX_ATTACHMENT_BYTES) {
            return self.client.sendMessage(try std.fmt.allocPrint(
                arena,
                "{s} is {s}. Mail won't carry more than about 18 MB, so I can't attach it.",
                .{ filename, attachments_mod.humanSize(document.file_size, &size_buf) },
            ));
        }

        self.client.sendTyping();
        const bytes = self.client.downloadFile(arena, document.file_id) catch |err| {
            log.err("could not download upload {s}: {s}", .{ filename, @errorName(err) });
            return self.client.sendMessage(
                "Couldn't download that file from Telegram -- try sending it again.",
            );
        };

        try self.stage(filename, document.mime_type orelse "application/octet-stream", bytes);
        log.info("staged {s} ({d} bytes) for the next draft", .{ filename, bytes.len });

        // A caption is the instruction that came with the file, so act on it
        // rather than making the owner repeat themselves.
        if (caption) |text| {
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len > 0) {
                try self.client.sendMessage(try std.fmt.allocPrint(
                    arena,
                    "Got {s} ({s}).",
                    .{ filename, attachments_mod.humanSize(bytes.len, &size_buf) },
                ));
                return self.handleText(arena, chat_id, trimmed);
            }
        }

        try self.client.sendMessage(try std.fmt.allocPrint(
            arena,
            "Got {s} ({s}). Tell me what to do with it -- \"reply to that saying here's the file\", for example. I'll show you the draft before anything is sent.",
            .{ filename, attachments_mod.humanSize(bytes.len, &size_buf) },
        ));
    }

    /// Allocations finish before the arena is moved into place; see `remember`.
    fn stage(self: *Bot, filename: []const u8, content_type: []const u8, bytes: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.cfg.gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        const owned_name = try arena.dupe(u8, filename);
        const owned_type = try arena.dupe(u8, content_type);
        const owned_bytes = try arena.dupe(u8, bytes);

        if (self.staged) |*previous| previous.arena.deinit();
        self.staged = .{
            .arena = arena_state,
            .filename = owned_name,
            .content_type = owned_type,
            .bytes = owned_bytes,
            .created_ns = std.Io.Clock.now(.boot, self.cfg.io).nanoseconds,
        };
    }

    fn discardStaged(self: *Bot) void {
        if (self.staged) |*staged| staged.arena.deinit();
        self.staged = null;
    }

    /// The staged file, if there is one and it has not gone stale.
    fn freshStaged(self: *Bot) ?*Staged {
        if (self.staged == null) return null;
        const staged = &self.staged.?;
        const age = @divTrunc(
            std.Io.Clock.now(.boot, self.cfg.io).nanoseconds - staged.created_ns,
            std.time.ns_per_s,
        );
        if (age > PENDING_REPLY_TTL_SECONDS) {
            log.info("staged file {s} expired", .{staged.filename});
            self.discardStaged();
            return null;
        }
        return staged;
    }

    /// Until an owner chat id is configured the bot is inert, and says so.
    /// The only thing it will reveal is the caller's own chat id, which is
    /// theirs already.
    fn ownerCheck(self: *Bot, arena: std.mem.Allocator, chat_id: []const u8, text: []const u8) !bool {
        if (self.cfg.telegram_owner_chat_id.len == 0) {
            const reply = if (std.mem.startsWith(u8, text, "/start"))
                try std.fmt.allocPrint(
                    arena,
                    "Hi, I'm Ronny. Your chat id is {s} -- set TELEGRAM_OWNER_CHAT_ID={s} in .env and restart me so I only take commands from you.",
                    .{ chat_id, chat_id },
                )
            else
                "Not configured yet -- send /start first.";
            try self.sendTo(chat_id, reply);
            return false;
        }

        if (!std.mem.eql(u8, chat_id, self.cfg.telegram_owner_chat_id)) {
            log.warn("ignoring a message from non-owner chat id {s}", .{chat_id});
            try self.sendTo(chat_id, "This bot is private.");
            return false;
        }
        return true;
    }

    fn handleText(self: *Bot, arena: std.mem.Allocator, chat_id: []const u8, text: []const u8) !void {
        if (!try self.ownerCheck(arena, chat_id, text)) return;

        log.info("owner message: {s}", .{text});
        // Mailbox fetches and local summarisation take tens of seconds, during
        // which the bot looks dead. Say something first.
        self.client.sendTyping();

        const reply = if (text[0] == '/')
            try self.handleCommand(arena, text)
        else
            try self.handleNaturalLanguage(arena, text);

        try self.client.sendMessage(reply);
        try self.record(text, reply);
    }

    fn handleVoice(self: *Bot, arena: std.mem.Allocator, chat_id: []const u8, voice: telegram.Voice) !void {
        if (!try self.ownerCheck(arena, chat_id, "")) return;
        if (!self.whisper_loaded) {
            return self.client.sendMessage("Voice notes aren't enabled -- set WHISPER_MODEL to turn them on.");
        }
        if (voice.duration > transcribe.MAX_SECONDS) {
            const reply = try std.fmt.allocPrint(
                arena,
                "That's longer than {d}s -- send a shorter note or type it.",
                .{transcribe.MAX_SECONDS},
            );
            return self.client.sendMessage(reply);
        }

        self.client.sendTyping();
        const audio = self.client.downloadFile(arena, voice.file_id) catch |err| {
            // Logged, not just reported to the owner. Swallowing this is what
            // made a dangling file_id take a production round trip to find.
            log.err("could not download voice note {s}: {s}", .{ voice.file_id, @errorName(err) });
            return self.client.sendMessage("Couldn't download that voice note -- try again, or type it.");
        };

        const vocabulary = self.voiceVocabulary();
        const prompt = transcribe.buildPrompt(arena, vocabulary) catch null;

        const raw = transcribe.transcribe(self.cfg.io, arena, audio, prompt) catch |err| {
            log.warn("transcription failed: {s}", .{@errorName(err)});
            return self.client.sendMessage("I couldn't make out any speech in that -- try again, or type it.");
        };
        if (raw.len == 0) {
            return self.client.sendMessage("I couldn't make out any speech in that -- try again, or type it.");
        }

        const text = transcribe.repair(arena, raw, vocabulary) catch raw;
        log.info("voice note transcribed: {s}", .{text});

        // A misheard command is the one failure mode typing does not have, so
        // what was heard is always shown back.
        if (self.pending != null and decision_mod.decide(text) != .unclear and !self.cfg.voice_can_confirm_send) {
            const reply = try std.fmt.allocPrint(arena,
                \\I heard: "{s}"
                \\
                \\A reply is waiting to be sent, and I don't act on spoken yes/no for that -- a misheard word would send mail you didn't approve. Type yes to send it, or no to discard.
            , .{text});
            return self.client.sendMessage(reply);
        }

        try self.client.sendMessage(try std.fmt.allocPrint(arena, "I heard: \"{s}\"", .{text}));
        try self.handleText(arena, chat_id, text);
    }

    fn sendTo(self: *Bot, chat_id: []const u8, text: []const u8) !void {
        var client = self.client;
        client.owner_chat_id = chat_id;
        try client.sendMessage(text);
    }

    fn record(self: *Bot, message: []const u8, reply: []const u8) !void {
        const gpa = self.cfg.gpa;
        const turn: Turn = .{
            .owner = try gpa.dupe(u8, message),
            .assistant = try gpa.dupe(u8, reply[0..@min(reply.len, 400)]),
        };
        try self.history.append(gpa, turn);

        while (self.history.items.len > MAX_HISTORY) {
            const evicted = self.history.orderedRemove(0);
            gpa.free(evicted.owner);
            gpa.free(evicted.assistant);
        }
    }

    fn historyTurns(self: *Bot, arena: std.mem.Allocator) ![]interpret_mod.Turn {
        const turns = try arena.alloc(interpret_mod.Turn, self.history.items.len);
        for (self.history.items, turns) |stored, *turn| {
            turn.* = .{ .owner = stored.owner, .assistant = stored.assistant };
        }
        return turns;
    }

    // ---- exact slash commands ----

    fn handleCommand(self: *Bot, arena: std.mem.Allocator, text: []const u8) ![]const u8 {
        const space = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
        const command = text[0..space];
        const arg = std.mem.trim(u8, text[@min(space + 1, text.len)..], " \t\r\n");

        if (std.mem.eql(u8, command, "/start") or std.mem.eql(u8, command, "/help")) return HELP_TEXT;
        if (std.mem.eql(u8, command, "/status")) return self.statusText(arena);
        if (std.mem.eql(u8, command, "/senders")) return self.sendersText(arena);
        if (std.mem.eql(u8, command, "/confirm")) return self.doConfirm(arena);
        if (std.mem.eql(u8, command, "/cancel")) return self.doCancel(arena);
        if (std.mem.eql(u8, command, "/pause")) return self.doPause();
        if (std.mem.eql(u8, command, "/resume")) return self.doResume();

        if (std.mem.eql(u8, command, "/add")) {
            if (arg.len == 0) return "Usage: /add someone@example.com  (or a bare domain)";
            return self.doAdd(arena, arg);
        }
        if (std.mem.eql(u8, command, "/remove")) {
            if (arg.len == 0) return "Usage: /remove someone@example.com";
            return self.doRemove(arena, arg);
        }
        if (std.mem.eql(u8, command, "/find")) {
            if (arg.len == 0) return "Usage: /find <what the email was about>";
            return self.doFind(arena, arg);
        }
        if (std.mem.eql(u8, command, "/attachments")) return self.doListAttachments(arena);
        if (std.mem.eql(u8, command, "/get")) {
            // No argument means "the only one", which doGetAttachment handles
            // by skipping the model entirely.
            return self.doGetAttachment(arena, arg);
        }
        if (std.mem.eql(u8, command, "/reply")) {
            if (arg.len == 0) return "Usage: /reply <text>  (replies to the last email I showed you)";
            return self.doDraftReply(arena, arg, true);
        }

        const parsed = parseSearchArg(arg);
        if (std.mem.eql(u8, command, "/search")) {
            if (arg.len == 0) return "Usage: /search someone@example.com [days]";
            return self.doSearch(arena, parsed.target, parsed.days);
        }
        if (std.mem.eql(u8, command, "/read")) {
            if (arg.len == 0) return "Usage: /read someone@example.com [days]";
            return self.doRead(arena, parsed.target, parsed.days);
        }
        if (std.mem.eql(u8, command, "/summarize") or std.mem.eql(u8, command, "/summarise")) {
            if (arg.len == 0) return "Usage: /summarize someone@example.com [days]";
            return self.doSummarize(arena, parsed.target, parsed.days);
        }

        return try std.fmt.allocPrint(arena, "Unknown command.\n\n{s}", .{HELP_TEXT});
    }

    // ---- plain language ----

    fn handleNaturalLanguage(self: *Bot, arena: std.mem.Allocator, text: []const u8) ![]const u8 {
        // With a draft pending, a plain yes/no decides it -- and the match is
        // deterministic, so no model ever decides whether to send.
        const answer = decision_mod.decide(text);
        if (self.pending != null) {
            switch (answer) {
                .confirm => {
                    log.info("owner confirmed the pending reply with: {s}", .{text});
                    return self.doConfirm(arena);
                },
                .cancel => {
                    log.info("owner cancelled the pending reply with: {s}", .{text});
                    return self.doCancel(arena);
                },
                .unclear => {},
            }
        } else if (answer != .unclear) {
            // A bare yes/no with nothing pending is inert. It must never reach
            // the classifier, which once turned a stray "yes" into a brand-new
            // invented draft -- one more "yes" from sending it.
            return "There's no draft waiting, so there's nothing to say yes or no to.";
        }

        const understood = interpret_mod.interpret(
            self.cfg.io,
            arena,
            self.cfg.ollama_url,
            self.cfg.ollama_model,
            self.cfg.typesafe_api_key,
            self.cfg.jev_model,
            text,
            try self.historyTurns(arena),
        ) catch {
            log.warn("interpretation unavailable for: {s}", .{text});
            return "Couldn't reach the models to interpret that. Try an exact command -- /help lists them.";
        };

        log.info("interpreted as action={s} target={?s} days={?d}", .{
            understood.action.wireName(), understood.target, understood.days,
        });

        const result: []const u8 = switch (understood.action) {
            .unknown => {
                // Never guess on an unclear answer while a draft is waiting.
                if (self.pending != null) {
                    return "I'm not sure if that's a yes or a no, so I haven't sent anything. Reply 'yes' to send the draft, or 'no' to discard it.";
                }
                return understood.reply;
            },
            .help => HELP_TEXT,
            .status => try self.statusText(arena),
            .list_senders => try self.sendersText(arena),
            .pause => self.doPause(),
            .resume_ => self.doResume(),
            .add_sender => if (understood.target) |target|
                try self.doAdd(arena, target)
            else
                "Which address or domain should I add?",
            .remove_sender => if (understood.target) |target|
                try self.doRemove(arena, target)
            else
                "Which address or domain should I remove?",
            // The whole message is the question, so it is passed through raw.
            .find_mail => try self.doFind(arena, text),
            .list_attachments => try self.doListAttachments(arena),
            // Likewise: which file is decided by matching the owner's own
            // words against the real filenames.
            .get_attachment => try self.doGetAttachment(arena, text),
            .search_mail => if (understood.target) |target|
                try self.doSearch(arena, target, understood.days)
            else
                "Search mail from whom?",
            .read_mail => if (understood.target) |target|
                try self.doRead(arena, target, understood.days)
            else
                "Read the latest mail from whom?",
            .summarize_mail => if (understood.target) |target|
                try self.doSummarize(arena, target, understood.days)
            else
                "Summarize the latest mail from whom?",
            .draft_reply => try self.doDraftReply(arena, understood.message, false),
            .compose_mail => try self.doComposeMail(arena, text, understood.message),
        };

        if (std.mem.eql(u8, result, understood.reply)) return result;
        return std.fmt.allocPrint(arena, "{s}\n{s}", .{ understood.reply, result });
    }

    // ---- actions ----

    fn statusText(self: *Bot, arena: std.mem.Allocator) ![]const u8 {
        const senders = try self.controller.senders();
        defer self.controller.freeSenders(senders);
        return std.fmt.allocPrint(arena, "Ronny is {s}. Watching {d} sender(s).", .{
            if (self.controller.paused) "paused" else "active",
            senders.len,
        });
    }

    fn sendersText(self: *Bot, arena: std.mem.Allocator) ![]const u8 {
        const senders = try self.controller.senders();
        defer self.controller.freeSenders(senders);
        if (senders.len == 0) return "Allowlist:\n(empty)";

        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.writeAll("Allowlist:");
        for (senders) |sender| try out.writer.print("\n- {s}", .{sender});
        return out.writer.buffered();
    }

    fn doAdd(self: *Bot, arena: std.mem.Allocator, target: []const u8) ![]const u8 {
        const added = self.controller.addSender(target) catch |err| {
            if (err != controller_mod.Error.InvalidEntry) return err;
            log.warn("rejected a bogus allowlist entry: {s}", .{target});
            return std.fmt.allocPrint(
                arena,
                "'{s}' doesn't look like an email address or domain, so I didn't add it.",
                .{target},
            );
        };
        return if (added)
            std.fmt.allocPrint(arena, "Added {s}.", .{target})
        else
            std.fmt.allocPrint(arena, "{s} is already on the list.", .{target});
    }

    fn doRemove(self: *Bot, arena: std.mem.Allocator, target: []const u8) ![]const u8 {
        return if (try self.controller.removeSender(target))
            std.fmt.allocPrint(arena, "Removed {s}.", .{target})
        else
            std.fmt.allocPrint(arena, "{s} wasn't on the list.", .{target});
    }

    fn doPause(self: *Bot) []const u8 {
        self.controller.setPaused(true) catch |err| {
            log.err("could not persist the paused flag: {s}", .{@errorName(err)});
            return "I've paused, but couldn't write it to disk -- a restart would resume notifications.";
        };
        return "Paused -- I won't send notifications until /resume.";
    }

    fn doResume(self: *Bot) []const u8 {
        self.controller.setPaused(false) catch |err| {
            log.err("could not persist the paused flag: {s}", .{@errorName(err)});
            return "I've resumed, but couldn't write it to disk.";
        };
        return "Resumed.";
    }

    // ---- mailbox ----

    /// Connects lazily and reconnects on demand. An IMAP session that has been
    /// idle for hours is routinely dropped by the server, and the failure only
    /// shows up on the next command.
    fn mailbox(self: *Bot) !*imap.Session {
        if (self.session) |*session| return session;

        log.info("connecting to {s} as {s}", .{ self.cfg.imap_host, self.cfg.imap_user });
        var session = try imap.Session.connect(
            self.cfg.imap_host,
            self.cfg.imap_port,
            self.cfg.imap_user,
            self.cfg.imap_password,
        );
        // Read-only, so nothing the bot does can mark mail as seen.
        _ = try session.examineInbox();
        self.session = session;
        return &self.session.?;
    }

    fn dropMailbox(self: *Bot) void {
        if (self.session) |*session| session.deinit();
        self.session = null;
    }

    /// Runs `body` against the mailbox, reconnecting once if the session has
    /// gone stale. Every mail command goes through this.
    fn withMailbox(
        self: *Bot,
        context: anytype,
        comptime body: fn (@TypeOf(context), *imap.Session) anyerror!void,
    ) !void {
        const session = self.mailbox() catch |err| {
            self.dropMailbox();
            return err;
        };
        body(context, session) catch {
            log.info("retrying on a fresh IMAP session", .{});
            self.dropMailbox();
            const fresh = try self.mailbox();
            try body(context, fresh);
        };
    }

    const Latest = struct {
        uid: u32,
        from: []const u8,
        subject: []const u8,
        date: []const u8,
        body: []const u8,
        headers: []const u8,
        attachments: []const imap.Attachment,
    };

    /// The newest message from `target` within `days`, or null.
    fn fetchLatest(
        self: *Bot,
        arena: std.mem.Allocator,
        target: []const u8,
        days: u16,
    ) !?Latest {
        const target_z = try arena.dupeZ(u8, target);
        const buffer = try arena.alloc(imap.Envelope, 1);

        const Context = struct {
            arena: std.mem.Allocator,
            target: [:0]const u8,
            days: u16,
            buffer: []imap.Envelope,
            found: ?Latest = null,

            fn run(ctx: *@This(), session: *imap.Session) anyerror!void {
                ctx.found = null;
                // searchFrom returns newest first, so one slot is enough.
                const hits = try session.searchFrom(ctx.target, ctx.days, ctx.buffer);
                if (hits.len == 0) return;

                var message: imap.Message = undefined;
                try session.fetchMessage(hits[0].uid, &message);
                ctx.found = .{
                    .uid = hits[0].uid,
                    .from = try ctx.arena.dupe(u8, hits[0].fromSlice()),
                    .subject = try ctx.arena.dupe(u8, hits[0].subjectSlice()),
                    .date = try ctx.arena.dupe(u8, hits[0].dateSlice()),
                    .body = try ctx.arena.dupe(u8, message.bodySlice()),
                    .headers = try ctx.arena.dupe(u8, message.headersSlice()),
                    .attachments = try attachments_mod.ranked(ctx.arena, message.attachmentSlice()),
                };
            }
        };

        var context: Context = .{ .arena = arena, .target = target_z, .days = days, .buffer = buffer };
        try self.withMailbox(&context, Context.run);

        if (context.found) |latest| try self.remember(latest);
        return context.found;
    }

    /// Records what was shown, so a reply has something real to target.
    ///
    /// Note the ordering: an ArenaAllocator's `allocator()` captures its own
    /// address, so every allocation has to finish *before* the struct is moved
    /// into place. Copying it first would leave the stored copy holding a
    /// stale state and lose everything allocated afterwards.
    fn remember(self: *Bot, latest: Latest) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.cfg.gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        const from = try arena.dupe(u8, latest.from);
        const subject = try arena.dupe(u8, latest.subject);
        const date = try arena.dupe(u8, latest.date);
        const body = try arena.dupe(u8, latest.body);
        const reply_to = if (try headers_mod.replyTo(arena, latest.headers)) |address|
            try arena.dupe(u8, address)
        else
            null;
        const message_id = if (try headers_mod.value(arena, latest.headers, "Message-ID")) |id|
            try arena.dupe(u8, id)
        else
            "";
        const references = if (try headers_mod.value(arena, latest.headers, "References")) |refs|
            try arena.dupe(u8, refs)
        else
            "";

        const attachments = try arena.dupe(imap.Attachment, latest.attachments);

        if (self.last_message) |*previous| previous.arena.deinit();
        self.last_message = .{
            .arena = arena_state,
            .uid = latest.uid,
            .from = from,
            .reply_to = reply_to,
            .subject = subject,
            .date = date,
            .body = body,
            .message_id = message_id,
            .references = references,
            .attachments = attachments,
        };
    }

    // ---- attachments ----

    fn doListAttachments(self: *Bot, arena: std.mem.Allocator) ![]const u8 {
        if (self.last_message == null) {
            return "I can only look at a message I've shown you. Read or find one first.";
        }
        const original = &self.last_message.?;
        if (original.attachments.len == 0) {
            return std.fmt.allocPrint(arena, "\"{s}\" has no attachments.", .{original.subject});
        }

        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.print("\"{s}\" has {d} attachment(s):", .{
            original.subject, original.attachments.len,
        });
        for (original.attachments) |part| {
            var size_buf: [32]u8 = undefined;
            try out.writer.print("\n- {s} ({s}, {s}){s}", .{
                part.filenameSlice(),
                part.mimeTypeSlice(),
                attachments_mod.humanSize(part.size, &size_buf),
                if (part.is_inline == 1) " - inline, probably part of the layout" else "",
            });
        }
        try out.writer.writeAll("\n\nAsk me for one by name and I'll send it.");
        return telegram.truncate(out.writer.buffered());
    }

    fn doGetAttachment(self: *Bot, arena: std.mem.Allocator, request: []const u8) ![]const u8 {
        if (self.last_message == null) {
            return "I can only send a file from a message I've shown you. Read or find one first.";
        }
        const original = &self.last_message.?;
        if (original.attachments.len == 0) {
            return std.fmt.allocPrint(arena, "\"{s}\" has no attachments.", .{original.subject});
        }

        const choice = attachments_mod.choose(
            self.cfg.io,
            arena,
            self.cfg.ollama_url,
            self.cfg.ollama_model,
            request,
            original.attachments,
        ) orelse {
            // Never guess. Sending the wrong file to a chat is a privacy slip,
            // and one extra turn is cheap next to that.
            return try self.doListAttachments(arena);
        };

        const part = original.attachments[choice];
        var size_buf: [32]u8 = undefined;
        if (part.size > attachments_mod.MAX_BYTES) {
            return std.fmt.allocPrint(
                arena,
                "{s} is {s}, which is more than I can pass through Telegram.",
                .{ part.filenameSlice(), attachments_mod.humanSize(part.size, &size_buf) },
            );
        }

        self.client.sendTyping();

        const Context = struct {
            uid: u32,
            index: u32,
            buffer: []u8,
            bytes: []u8 = &.{},

            fn run(ctx: *@This(), session: *imap.Session) anyerror!void {
                ctx.bytes = try session.fetchAttachment(ctx.uid, ctx.index, ctx.buffer);
            }
        };

        // Sized from what the part declared, with room for the estimate being
        // low; the shim refuses rather than overruns if it is too small.
        const capacity = @min(
            @as(usize, part.size) + (part.size / 4) + 64 * 1024,
            attachments_mod.MAX_BYTES,
        );
        var context: Context = .{
            .uid = original.uid,
            .index = part.index,
            .buffer = try arena.alloc(u8, capacity),
        };
        self.withMailbox(&context, Context.run) catch |err| {
            log.err("could not fetch attachment {s}: {s}", .{ part.filenameSlice(), @errorName(err) });
            return "Couldn't pull that file off the server -- try again in a bit.";
        };

        const caption = try std.fmt.allocPrint(arena, "From: {s}\n{s}", .{
            original.from, original.subject,
        });
        self.client.sendDocument(
            arena,
            part.filenameSlice(),
            part.mimeTypeSlice(),
            context.bytes,
            caption,
        ) catch |err| {
            log.err("could not send {s}: {s}", .{ part.filenameSlice(), @errorName(err) });
            return std.fmt.allocPrint(
                arena,
                "Got {s} off the server but Telegram wouldn't take it ({s}).",
                .{ part.filenameSlice(), @errorName(err) },
            );
        };

        // The file itself is the answer; this is just the receipt.
        return std.fmt.allocPrint(arena, "Sent {s} ({s}).", .{
            part.filenameSlice(),
            attachments_mod.humanSize(context.bytes.len, &size_buf),
        });
    }

    fn doSearch(self: *Bot, arena: std.mem.Allocator, target: []const u8, days_opt: ?u16) ![]const u8 {
        const days = days_opt orelse DEFAULT_DAYS;
        const target_z = try arena.dupeZ(u8, target);
        const buffer = try arena.alloc(imap.Envelope, SEARCH_RESULT_LIMIT);

        const Context = struct {
            target: [:0]const u8,
            days: u16,
            buffer: []imap.Envelope,
            hits: []imap.Envelope = &.{},

            fn run(ctx: *@This(), session: *imap.Session) anyerror!void {
                ctx.hits = try session.searchFrom(ctx.target, ctx.days, ctx.buffer);
            }
        };

        var context: Context = .{ .target = target_z, .days = days, .buffer = buffer };
        self.withMailbox(&context, Context.run) catch |err| {
            log.err("mail search failed for {s}: {s}", .{ target, @errorName(err) });
            return "Couldn't search the mailbox right now -- try again in a bit.";
        };

        if (context.hits.len == 0) {
            return std.fmt.allocPrint(arena, "No mail from {s} in the last {d} day(s).", .{ target, days });
        }

        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.print("Found {d} message(s) from {s} in the last {d} day(s):", .{
            context.hits.len, target, days,
        });
        for (context.hits) |*envelope| {
            try out.writer.print("\n- {s}: {s}", .{ envelope.dateSlice(), envelope.subjectSlice() });
        }
        return telegram.truncate(out.writer.buffered());
    }

    fn doRead(self: *Bot, arena: std.mem.Allocator, target: []const u8, days_opt: ?u16) ![]const u8 {
        const days = days_opt orelse DEFAULT_DAYS;
        const latest = self.fetchLatest(arena, target, days) catch |err| {
            log.err("fetching the latest mail failed for {s}: {s}", .{ target, @errorName(err) });
            return "Couldn't read the mailbox right now -- try again in a bit.";
        } orelse {
            return std.fmt.allocPrint(arena, "No mail from {s} in the last {d} day(s).", .{ target, days });
        };

        if (latest.body.len == 0) {
            return std.fmt.allocPrint(
                arena,
                "{s} ({s})\n\n(No plain-text body -- it's probably HTML-only.)",
                .{ latest.subject, latest.date },
            );
        }
        return telegram.truncate(try std.fmt.allocPrint(
            arena,
            "{s}\nFrom: {s}\nDate: {s}\n\n{s}",
            .{ latest.subject, latest.from, latest.date, latest.body },
        ));
    }

    fn doSummarize(self: *Bot, arena: std.mem.Allocator, target: []const u8, days_opt: ?u16) ![]const u8 {
        const days = days_opt orelse DEFAULT_DAYS;
        const latest = self.fetchLatest(arena, target, days) catch |err| {
            log.err("fetching the latest mail failed for {s}: {s}", .{ target, @errorName(err) });
            return "Couldn't read the mailbox right now -- try again in a bit.";
        } orelse {
            return std.fmt.allocPrint(arena, "No mail from {s} in the last {d} day(s).", .{ target, days });
        };

        const summary = summarize_mod.summarize(
            self.cfg.io,
            arena,
            self.cfg.ollama_url,
            self.cfg.ollama_model,
            latest.from,
            latest.subject,
            latest.body,
        ) catch {
            return telegram.truncate(try std.fmt.allocPrint(
                arena,
                "Couldn't summarize that one (no body text, or the model didn't respond). Here's the raw content instead:\n\n{s} ({s})\n\n{s}",
                .{ latest.subject, latest.date, latest.body },
            ));
        };
        return telegram.truncate(try std.fmt.allocPrint(
            arena,
            "{s} ({s})\n\n{s}",
            .{ latest.subject, latest.date, summary },
        ));
    }

    fn doFind(self: *Bot, arena: std.mem.Allocator, question: []const u8) ![]const u8 {
        const Context = struct {
            bot: *Bot,
            arena: std.mem.Allocator,
            question: []const u8,
            found: findmail.Found = .{ .query = "", .matches = &.{} },

            fn run(ctx: *@This(), session: *imap.Session) anyerror!void {
                ctx.found = try findmail.find(
                    ctx.bot.cfg.io,
                    ctx.arena,
                    session,
                    ctx.bot.cfg.ollama_url,
                    ctx.bot.cfg.ollama_model,
                    ctx.question,
                    null,
                );
            }
        };

        var context: Context = .{ .bot = self, .arena = arena, .question = question };
        self.withMailbox(&context, Context.run) catch |err| {
            log.err("content search failed for {s}: {s}", .{ question, @errorName(err) });
            return "Couldn't search the mailbox right now -- try again in a bit.";
        };

        const found = context.found;
        if (found.matches.len == 0) {
            // The query is shown because a bad query and an empty mailbox look
            // identical from the outside.
            return std.fmt.allocPrint(arena, "Nothing matched that. (searched: {s})", .{
                found.query[0..@min(found.query.len, 120)],
            });
        }

        // Remember the best match, so "does that have attachments?" or "reply
        // to it" resolves against what was just found rather than whatever
        // was last read.
        self.rememberFound(arena, found.matches[0].candidate.uid) catch |err| {
            log.warn("could not open the top match: {s}", .{@errorName(err)});
        };

        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.print("Found {d} match(es):", .{found.matches.len});
        for (found.matches) |match| {
            try out.writer.print("\n- {s}\n  from {s} | {s}", .{
                match.candidate.subject, match.candidate.from, match.candidate.date,
            });
            if (match.why.len > 0) try out.writer.print("\n  {s}", .{match.why});
        }
        if (found.matches.len > 1) {
            try out.writer.print("\n\nThe first one is open -- ask about \"it\" and I'll mean that.", .{});
        }
        return telegram.truncate(out.writer.buffered());
    }

    /// Opens a message found by content search, so follow-ups have a target.
    fn rememberFound(self: *Bot, arena: std.mem.Allocator, uid: u32) !void {
        const Context = struct {
            arena: std.mem.Allocator,
            uid: u32,
            found: ?Latest = null,

            fn run(ctx: *@This(), session: *imap.Session) anyerror!void {
                ctx.found = null;
                var message: imap.Message = undefined;
                try session.fetchMessage(ctx.uid, &message);

                const raw = message.headersSlice();
                ctx.found = .{
                    .uid = ctx.uid,
                    .from = if (try headers_mod.value(ctx.arena, raw, "From")) |value|
                        headers_mod.address(value) orelse value
                    else
                        "",
                    .subject = (try headers_mod.value(ctx.arena, raw, "Subject")) orelse "",
                    .date = (try headers_mod.value(ctx.arena, raw, "Date")) orelse "",
                    .body = try ctx.arena.dupe(u8, message.bodySlice()),
                    .headers = try ctx.arena.dupe(u8, raw),
                    .attachments = try attachments_mod.ranked(ctx.arena, message.attachmentSlice()),
                };
            }
        };

        var context: Context = .{ .arena = arena, .uid = uid };
        try self.withMailbox(&context, Context.run);
        if (context.found) |latest| try self.remember(latest);
    }

    // ---- drafting, and the send gate ----

    fn doDraftReply(self: *Bot, arena: std.mem.Allocator, instruction: ?[]const u8, verbatim: bool) ![]const u8 {
        // Taken by pointer: these structs own an arena, and copying one around
        // is how you end up deinit-ing the wrong copy.
        if (self.last_message == null) {
            return "I can only reply to a message I've shown you. Use /read <address-or-domain> first, then ask me to reply.";
        }
        const original = &self.last_message.?;
        const recipient = original.reply_to orelse {
            return "That message has no usable reply address, so I can't draft a reply to it.";
        };

        const instruction_text = instruction orelse return "What should the reply say?";
        const body = if (verbatim)
            instruction_text
        else
            summarize_mod.draftReply(
                self.cfg.io,
                arena,
                self.cfg.ollama_url,
                self.cfg.ollama_model,
                original.subject,
                original.body,
                instruction_text,
            ) catch instruction_text;

        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0) return "The reply came out empty, so I haven't drafted anything.";

        const subject = if (std.ascii.startsWithIgnoreCase(original.subject, "re:"))
            original.subject
        else
            try std.fmt.allocPrint(arena, "Re: {s}", .{original.subject});

        // A re-draft must be obvious: the owner must never confirm a body they
        // believe they reviewed while a different one is actually pending.
        return self.stageDraft(arena, .{
            .to = recipient,
            .subject = subject,
            .body = trimmed,
            .in_reply_to = original.message_id,
            .references = original.references,
        }, "");
    }

    const DraftParts = struct {
        to: []const u8,
        subject: []const u8,
        body: []const u8,
        in_reply_to: []const u8,
        references: []const u8,
    };

    /// Holds a draft pending approval and returns the preview.
    ///
    /// Shared by replies and new mail so both go through exactly one gate.
    /// A second copy of this logic is how the two paths would drift until one
    /// of them sends something unreviewed.
    fn stageDraft(
        self: *Bot,
        arena: std.mem.Allocator,
        parts: DraftParts,
        recipient_label: []const u8,
    ) ![]const u8 {
        // A re-draft must be obvious: the owner must never confirm a body they
        // believe they reviewed while a different one is actually pending.
        const replaced = self.pending != null;

        // Allocations finish before the arena is moved into place; see the
        // note on `remember`.
        var pending_arena: std.heap.ArenaAllocator = .init(self.cfg.gpa);
        errdefer pending_arena.deinit();
        const pending_alloc = pending_arena.allocator();

        const to = try pending_alloc.dupe(u8, parts.to);
        const pending_subject = try pending_alloc.dupe(u8, parts.subject);
        const pending_body = try pending_alloc.dupe(u8, parts.body);
        const in_reply_to = try pending_alloc.dupe(u8, parts.in_reply_to);
        const references = try pending_alloc.dupe(u8, parts.references);

        // A staged upload rides along with the draft, so what gets approved
        // and what gets sent are the same thing.
        var attached: []const mailer.Attachment = &.{};
        var attachment_line: []const u8 = "";
        if (self.freshStaged()) |staged| {
            const copy = try pending_alloc.alloc(mailer.Attachment, 1);
            copy[0] = .{
                .filename = try pending_alloc.dupe(u8, staged.filename),
                .content_type = try pending_alloc.dupe(u8, staged.content_type),
                .bytes = try pending_alloc.dupe(u8, staged.bytes),
            };
            attached = copy;

            var size_buf: [32]u8 = undefined;
            attachment_line = try std.fmt.allocPrint(arena, "Attached: {s} ({s})\n", .{
                staged.filename,
                attachments_mod.humanSize(staged.bytes.len, &size_buf),
            });
        }

        if (self.pending) |*previous| previous.arena.deinit();
        self.pending = .{
            .arena = pending_arena,
            .to = to,
            .subject = pending_subject,
            .body = pending_body,
            .in_reply_to = in_reply_to,
            .references = references,
            .created_ns = std.Io.Clock.now(.boot, self.cfg.io).nanoseconds,
            .attachments = attached,
        };
        log.info("drafted mail to {s} with {d} attachment(s); awaiting confirmation", .{
            parts.to, attached.len,
        });

        // The label names who the address belongs to, so a wrong pick is
        // visible as a name rather than only as an address to squint at.
        const addressed = if (recipient_label.len > 0)
            try std.fmt.allocPrint(arena, "{s} <{s}>", .{ recipient_label, parts.to })
        else
            parts.to;

        return telegram.truncate(try std.fmt.allocPrint(arena,
            \\{s}DRAFT -- not sent.
            \\To: {s}
            \\Subject: {s}
            \\{s}
            \\{s}
            \\
            \\---
            \\Reply 'yes' to send it, or 'no' to discard it (/confirm and /cancel work too). Nothing is sent until you say so.
        , .{
            if (replaced) "*** THIS REPLACES YOUR PREVIOUS DRAFT -- read it again ***\n\n" else "",
            addressed,
            parts.subject,
            attachment_line,
            parts.body,
        }));
    }

    /// Drafts a brand-new email.
    ///
    /// The recipient is *selected* from addresses that have really written to
    /// this mailbox -- never produced by a model. See contacts.zig for why
    /// that distinction is the whole design here.
    fn doComposeMail(self: *Bot, arena: std.mem.Allocator, request: []const u8, instruction: ?[]const u8) ![]const u8 {
        const said = instruction orelse return "What should the email say?";

        const contacts = self.contactBook(arena) catch |err| {
            log.err("could not read contacts: {s}", .{@errorName(err)});
            return "Couldn't read your contacts right now -- try again in a bit.";
        };

        const choice = contacts_mod.resolve(
            self.cfg.io,
            arena,
            self.cfg.ollama_url,
            self.cfg.ollama_model,
            request,
            contacts,
        ) orelse {
            // Never guessed at. Mail to the wrong person cannot be recalled,
            // and there is no allowlist or preview that catches a plausible
            // but wrong name.
            return "I couldn't match that to anyone who's written to you. Include the full address in your request and I'll use it exactly.";
        };

        const contact = contacts[choice];
        const recipient = try arena.dupe(u8, contact.addressSlice());

        self.client.sendTyping();
        const draft = summarize_mod.draftNew(
            self.cfg.io,
            arena,
            self.cfg.ollama_url,
            self.cfg.ollama_model,
            recipient,
            said,
        ) catch {
            return "Couldn't reach the local model to draft that. Try again in a bit.";
        };

        return self.stageDraft(arena, .{
            .to = recipient,
            .subject = draft.subject,
            .body = draft.body,
            .in_reply_to = "",
            .references = "",
        }, contact.nameSlice());
    }

    /// Contacts, cached on the same clock as the voice vocabulary -- both cost
    /// a mailbox scan and neither changes minute to minute.
    fn contactBook(self: *Bot, arena: std.mem.Allocator) ![]const contacts_mod.Contact {
        const Context = struct {
            arena: std.mem.Allocator,
            list: []const contacts_mod.Contact = &.{},

            fn run(ctx: *@This(), session: *imap.Session) anyerror!void {
                ctx.list = try contacts_mod.load(ctx.arena, session, contacts_mod.DEFAULT_DAYS);
            }
        };
        var context: Context = .{ .arena = arena };
        try self.withMailbox(&context, Context.run);

        // Watched senders first: whoever the owner cared enough about to put
        // on the allowlist beats whoever merely sends the most mail.
        const allowlist = try self.controller.senders();
        defer self.controller.freeSenders(allowlist);
        const book = try contacts_mod.prioritise(arena, context.list, allowlist);

        log.info("contact book: {d} writable address(es)", .{book.len});
        return book;
    }

    fn doConfirm(self: *Bot, arena: std.mem.Allocator) ![]const u8 {
        if (self.pending == null) return "Nothing to send -- there's no draft waiting.";
        const pending = &self.pending.?;

        const now = std.Io.Clock.now(.boot, self.cfg.io).nanoseconds;
        const age_seconds = @divTrunc(now - pending.created_ns, std.time.ns_per_s);
        if (age_seconds > PENDING_REPLY_TTL_SECONDS) {
            self.discardPending();
            return "That draft expired, so I discarded it. Ask me to draft the reply again.";
        }

        mailer.send(
            self.cfg.io,
            self.cfg.gpa,
            self.cfg.smtp_host,
            self.cfg.smtp_port,
            self.cfg.imap_user,
            self.cfg.imap_password,
            .{
                .to = pending.to,
                .subject = pending.subject,
                .body = pending.body,
                .in_reply_to = pending.in_reply_to,
                .references = pending.references,
                .attachments = pending.attachments,
            },
        ) catch |err| {
            log.err("failed to send the reply to {s}: {s}", .{ pending.to, @errorName(err) });
            // The draft survives a failed send, so /confirm can be retried.
            return "Sending failed -- the draft is still here, try /confirm again.";
        };

        const reply = try std.fmt.allocPrint(arena, "Sent to {s}.", .{pending.to});
        // The file has been used; leaving it staged would silently attach it
        // to the next unrelated draft.
        self.discardStaged();
        self.discardPending();
        return reply;
    }

    fn doCancel(self: *Bot, arena: std.mem.Allocator) ![]const u8 {
        if (self.pending == null) return "Nothing to cancel.";
        const pending = &self.pending.?;
        const reply = try std.fmt.allocPrint(arena, "Discarded the draft to {s}. Nothing was sent.", .{pending.to});
        log.info("discarded the pending reply to {s}", .{pending.to});
        self.discardStaged();
        self.discardPending();
        return reply;
    }

    fn discardPending(self: *Bot) void {
        if (self.pending) |*pending| pending.arena.deinit();
        self.pending = null;
    }

    // ---- voice vocabulary ----

    /// The allowlist plus whoever actually writes to this mailbox.
    ///
    /// The allowlist alone was not enough: "1Password" and "AcmeSync" both
    /// email here often, are not watched senders, and whisper guessed at both.
    fn voiceVocabulary(self: *Bot) []const []const u8 {
        const now = std.Io.Clock.now(.boot, self.cfg.io).nanoseconds;
        const age_seconds = @divTrunc(now - self.vocabulary_refreshed_ns, std.time.ns_per_s);
        if (self.vocabulary.len > 0 and age_seconds < VOCAB_TTL_SECONDS) return self.vocabulary;

        var arena_state: std.heap.ArenaAllocator = .init(self.cfg.gpa);
        const arena = arena_state.allocator();

        const built = self.buildVocabulary(arena) catch |err| {
            log.warn("could not refresh the voice vocabulary ({s}); keeping what we have", .{@errorName(err)});
            arena_state.deinit();
            return self.vocabulary;
        };

        if (self.vocabulary_arena) |*previous| previous.deinit();
        self.vocabulary_arena = arena_state;
        self.vocabulary = built;
        self.vocabulary_refreshed_ns = now;
        log.info("voice vocabulary refreshed ({d} entries)", .{built.len});
        return built;
    }

    fn buildVocabulary(self: *Bot, arena: std.mem.Allocator) ![]const []const u8 {
        var entries: std.ArrayList([]const u8) = .empty;

        const allowlist = try self.controller.senders();
        defer self.controller.freeSenders(allowlist);
        for (allowlist) |sender| try entries.append(arena, try arena.dupe(u8, sender));
        try entries.append(arena, try arena.dupe(u8, self.cfg.imap_user));

        const Context = struct {
            arena: std.mem.Allocator,
            entries: *std.ArrayList([]const u8),

            fn run(ctx: *@This(), session: *imap.Session) anyerror!void {
                const flat = try ctx.arena.alloc(u8, VOCAB_MAX * VOCAB_ENTRY);
                const count = ronny_sender_vocabulary(session.imap, VOCAB_DAYS, flat.ptr, VOCAB_MAX);
                if (count < 0) return error.VocabularyFetchFailed;

                for (0..@intCast(count)) |i| {
                    const entry = std.mem.sliceTo(flat[i * VOCAB_ENTRY ..][0..VOCAB_ENTRY], 0);
                    if (entry.len == 0) continue;
                    try ctx.entries.append(ctx.arena, entry);
                }
            }
        };

        var context: Context = .{ .arena = arena, .entries = &entries };
        try self.withMailbox(&context, Context.run);

        return entries.toOwnedSlice(arena);
    }
};

const SearchArg = struct { target: []const u8, days: ?u16 };

/// "/search someone@example.com 30" -- a trailing number is a day count.
fn parseSearchArg(arg: []const u8) SearchArg {
    const space = std.mem.lastIndexOfScalar(u8, arg, ' ') orelse return .{ .target = arg, .days = null };
    const tail = arg[space + 1 ..];
    const days = std.fmt.parseInt(u16, tail, 10) catch return .{ .target = arg, .days = null };
    return .{ .target = std.mem.trim(u8, arg[0..space], " \t"), .days = days };
}

test "parseSearchArg splits off a trailing day count" {
    const plain = parseSearchArg("someone@example.com");
    try std.testing.expectEqualStrings("someone@example.com", plain.target);
    try std.testing.expectEqual(@as(?u16, null), plain.days);

    const with_days = parseSearchArg("someone@example.com 30");
    try std.testing.expectEqualStrings("someone@example.com", with_days.target);
    try std.testing.expectEqual(@as(?u16, 30), with_days.days);

    // A non-numeric tail is part of the target, not a day count.
    const name = parseSearchArg("Mail Delivery Subsystem");
    try std.testing.expectEqualStrings("Mail Delivery Subsystem", name.target);
    try std.testing.expectEqual(@as(?u16, null), name.days);
}

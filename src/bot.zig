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
const settings_mod = @import("settings.zig");
const speech_mod = @import("speech.zig");
const gcal = @import("gcal.zig");
const appointment = @import("appointment.zig");
const dates = @import("dates.zig");
const reminders_mod = @import("reminders.zig");

const log = std.log.scoped(.bot);

pub const MAX_HISTORY = 6;
/// A drafted reply expires, so a forgotten draft cannot be confirmed hours
/// later against a thread that has moved on.
pub const PENDING_REPLY_TTL_SECONDS = 900;
pub const DEFAULT_DAYS = 14;
/// A compose gathers its pieces across turns; this bounds how long a
/// half-finished one can capture the next thing the owner says.
pub const COMPOSE_TTL_SECONDS = 300;
/// A spoken settings change waits for a yes. Same reasoning as the compose
/// TTL: an abandoned question must not answer itself later.
pub const PENDING_SETTING_TTL_SECONDS = 300;
/// A calendar entry waits for a typed yes for this long. Longer than a
/// settings change because the owner may be checking the day against
/// something else first; shorter than a reply because "tomorrow" drifts.
pub const PENDING_EVENT_TTL_SECONDS = 600;
/// A calendar login link is good for this long. Google's own code expires
/// in minutes anyway; this only bounds how long a paste is looked for.
pub const PENDING_LOGIN_TTL_SECONDS = 900;
/// A removal waits for a typed yes for this long. Same as an addition.
pub const PENDING_REMOVAL_TTL_SECONDS = 600;
/// How often the day's listing is fetched again for meeting reminders. An
/// entry added or moved after the fetch is seen at the next one, so this
/// bounds how close to its start a new meeting can be and still get its
/// reminder: closer than this and the reminder may go late or not at all.
pub const REMINDER_REFRESH_SECONDS = 180;
pub const SEARCH_RESULT_LIMIT = 30;
const POLL_TIMEOUT_SECONDS = 30;
const RETRY_DELAY_SECONDS = 10;
/// The vocabulary costs an IMAP scan, so it is cached between voice notes.
const VOCAB_TTL_SECONDS = 6 * 3600;
const VOCAB_DAYS = 180;
const VOCAB_ENTRY = 96;
const VOCAB_MAX = 300;

/// Minutes since local midnight; see shim.c.
extern fn ronny_local_minutes() c_int;
extern fn ronny_sender_vocabulary(session: *imap.c.mailimap, days: c_int, out: [*]u8, max_out: c_int) c_int;

pub const HELP_TEXT =
    \\Commands (or just tell me in plain language):
    \\/status - show current state
    \\/senders - list the sender allowlist
    \\/add <address-or-domain> - add to the allowlist
    \\/remove <address-or-domain> - remove from the allowlist
    \\/search <address-or-domain> [days] - list recent mail (dates + subjects)
    \\/recent [days] - what has arrived lately, whoever sent it
    \\/find <what it was about> - search mail by topic, not sender
    \\/read <address-or-domain> [days] - show the latest email's content
    \\/summarize <address-or-domain> [days] - summarize the latest email
    \\/attachments - list the files attached to the last email I showed you
    \\/get <name> - send me one of those files
    \\/compose <who> <what to say> - draft a NEW email to someone
    \\/reply <text> - draft a reply to the last email I showed you
    \\/confirm - send the drafted reply
    \\/cancel - discard the drafted reply
    \\/event <what, and when> - add an appointment to your calendar (shown first, added on a typed yes)
    \\/calendar - connect your Google Calendar: I send a link, you paste back where it lands
    \\/agenda [day] - what's on your calendar that day (today if you don't say)
    \\/delete <which, and when> - remove an entry from your calendar (shown first, removed on a typed yes)
    \\/pause - stop notifications temporarily
    \\/resume - resume notifications
    \\/settings - show my settings (quiet hours, default look-back, summaries as text or voice, meeting reminders)
    \\
    \\Settings change in plain language too: "don't notify me before 8am",
    \\"no notifications between 10pm and 7am", "look back 30 days by default",
    \\"send summaries as voice messages", "summaries in Spanish", "use john's voice",
    \\"remind me 15 minutes before meetings", "turn off meeting reminders".
    \\
    \\Before a calendar entry that has a link to join, I send a reminder with
    \\the link and, if the entry has a description, a summary of the agenda --
    \\as text or as a voice message, whichever summaries are set to.
    \\Spoken out loud, I read the new value back and wait for a typed yes.
    \\
    \\When a reply is drafted, just answer 'yes' to send or 'no' to discard.
    \\I never send email until you say yes. A calendar entry works the same
    \\way: "dentist tomorrow at 10" shows you the entry, and yes adds it.
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

    /// Lets Jev rank content-search results, which means message excerpts
    /// leave the machine. Off unless the owner sets it: everywhere else in
    /// Ronny, bodies stay on local Ollama and only chat commands go to
    /// TypeSafe. See rerank.zig.
    typesafe_rank_mail: bool = false,

    /// Voice notes are off unless a whisper model is configured.
    whisper_model_path: ?[:0]const u8 = null,
    /// Languages the owner actually speaks. Auto-detect stays on -- they
    /// switch mid-conversation -- but a result outside this set is re-decoded
    /// rather than trusted. Null accepts whatever whisper reports.
    whisper_languages: ?[:0]const u8 = null,
    /// Spoken yes/no never confirms a send by default: a misheard word would
    /// send mail the owner did not approve.
    voice_can_confirm_send: bool = false,

    /// Text-to-speech for summaries, when piper is configured. Null means
    /// the "summaries: voice" setting quietly delivers text.
    speech: ?speech_mod.Config = null,

    /// Google Calendar, when GOOGLE_CLIENT_ID is set. Null means a request
    /// to add an appointment is answered with how to set it up.
    calendar: ?gcal.Config = null,
};

/// A reply that should go out as audio: the caption stays text, the body is
/// spoken. Set by the summarising actions for the duration of one turn.
const SpokenReply = struct {
    caption: []const u8,
    body: []const u8,
};

/// The last message Ronny actually fetched and showed. A reply may only ever
/// target this, which is what keeps recipients coming from real headers.
const LastMessage = struct {
    arena: std.heap.ArenaAllocator,
    /// Which mailbox `uid` belongs to. Re-select it before fetching again --
    /// the same UID in another mailbox is a different message, or none.
    mailbox: imap.Mailbox = .inbox,
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

/// A new email being assembled over several turns.
///
/// Compose needs two things -- who, and what to say -- and real requests
/// rarely carry both. "I'd like to email someone an attachment" has neither.
/// Without this the next message gets re-classified from scratch, and
/// "Thanks for the file" is not a recognisable command on its own.
const Composing = struct {
    arena: std.heap.ArenaAllocator,
    /// Empty until known. Once set it is a real address, never a guess.
    recipient: []const u8,
    label: []const u8,
    instruction: []const u8,
    /// Whether a file was asked for, remembered from whichever turn said so.
    /// "Compose an email attaching the invoice" asks on turn one; by the time
    /// the recipient and the body have been gathered two turns later, that
    /// wording is long gone. Treating it as a property of one message rather
    /// than of the compose is how a mail went out promising an invoice it
    /// did not carry.
    wants_attachment: bool,
    created_ns: i96,
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
    /// Where it came from, shown in the draft. A file pulled off a message
    /// the search picked is only as right as that pick, so the preview names
    /// the message too -- a wrong invoice should be visible, not inferred.
    source: []const u8,
    created_ns: i96,
};

/// A settings change that was *spoken* and is waiting to be confirmed.
///
/// Needs no arena: a Change is a couple of integers, and the description
/// shown back is rebuilt from it rather than stored.
const PendingSetting = struct {
    change: settings_mod.Change,
    created_ns: i96,
};

/// A calendar entry being assembled, then waiting for a typed yes.
///
/// The day and time were read from the owner's words by code and the title
/// by the local model, and all of it is shown back before anything is
/// created: a misread "next Thursday" is visible in the preview, and would
/// be silent on the calendar. Same shape as a pending reply, with a lower
/// stake -- nothing here reaches a third party, since attendees are never
/// set -- which is why a spoken no is honoured but a spoken yes still is not.
/// A calendar login that has been started from chat. The verifier never
/// leaves this process, so a link Ronny sent is the only one that can be
/// finished here.
const PendingLogin = struct {
    verifier: [64]u8,
    created_ns: i96,
};

/// A removal being chosen, then waiting for a typed yes.
///
/// The entries are the day's real listing from Google, copied here, so the
/// id that gets deleted can only ever be one Google itself returned. The
/// choice among them is made by word and time matching, never by a model,
/// and an unclear choice asks rather than guesses: this is the one calendar
/// action that destroys something.
const PendingRemoval = struct {
    arena: std.heap.ArenaAllocator,
    day: dates.Day,
    entries: []const gcal.Listed,
    /// Null until one entry has been picked; the next message is tried as
    /// a number or a name.
    chosen: ?usize,
    created_ns: i96,
};

const PendingEvent = struct {
    arena: std.heap.ArenaAllocator,
    title: []const u8,
    location: []const u8,
    /// Null until a day has been named; the next message is tried as one.
    day: ?dates.Day,
    start: ?i16,
    end: ?i16,
    created_ns: i96,

    fn when(self: *const PendingEvent) ?appointment.When {
        const day = self.day orelse return null;
        return .{ .day = day, .start = self.start, .end = self.end };
    }
};

/// Today's meetings as the reminder check last saw them. Refreshed from
/// Google every REMINDER_REFRESH_SECONDS and at midnight; what has been
/// reminded is carried across a refresh by id.
const Reminders = struct {
    arena: std.heap.ArenaAllocator,
    entries: []reminders_mod.Entry,
    day: dates.Day,
    refreshed_ns: i96,
    /// So a listing that keeps failing is logged once, not every refresh.
    failing: bool = false,
};

const Turn = struct {
    owner: []u8,
    assistant: []u8,
};

pub const Bot = struct {
    cfg: Config,
    controller: *controller_mod.Controller,
    /// Owned by main so the watcher process can point at the same file.
    settings: *settings_mod.Store,
    client: telegram.Client,

    session: ?imap.Session = null,
    last_message: ?LastMessage = null,
    pending: ?Pending = null,
    staged: ?Staged = null,
    composing: ?Composing = null,
    pending_setting: ?PendingSetting = null,
    pending_event: ?PendingEvent = null,
    pending_login: ?PendingLogin = null,
    pending_removal: ?PendingRemoval = null,
    reminders: ?Reminders = null,
    /// Set by the login step so the pasted code is not kept in history.
    redact_next_record: bool = false,
    /// Side channel from a summarising action to the send in handleText.
    /// Arena-owned by the turn that set it; cleared at the start of each.
    spoken_reply: ?SpokenReply = null,

    history: std.ArrayList(Turn) = .empty,
    vocabulary: []const []const u8 = &.{},
    vocabulary_arena: ?std.heap.ArenaAllocator = null,
    vocabulary_refreshed_ns: i96 = 0,
    whisper_loaded: bool = false,

    pub fn init(
        cfg: Config,
        controller: *controller_mod.Controller,
        settings_store: *settings_mod.Store,
    ) Bot {
        return .{
            .cfg = cfg,
            .controller = controller,
            .settings = settings_store,
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
        if (self.composing) |*composing| composing.arena.deinit();
        if (self.pending_event) |*event| event.arena.deinit();
        if (self.pending_removal) |*removal| removal.arena.deinit();
        if (self.reminders) |*reminders| reminders.arena.deinit();
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
            // Between polls rather than on a timer: a poll returns within
            // POLL_TIMEOUT_SECONDS whether or not anything was said, which
            // is as close to the minute as a reminder needs to be.
            self.tickReminders();
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

    // ---- meeting reminders ----

    /// Sends the reminder for any meeting that is now within the lead.
    /// Never an error: a reminder that cannot be sent is logged, and the
    /// Telegram poll it sits next to must not stop over it.
    fn tickReminders(self: *Bot) void {
        const calendar = self.cfg.calendar orelse return;
        const prefs = self.settings.reload();
        if (!prefs.meeting_reminders) return;
        const local = ronny_local_minutes();
        if (local < 0) return; // no clock, no reminders
        const now: i32 = local;

        self.refreshReminders(calendar, now);
        if (self.reminders == null) return;
        const state = &self.reminders.?;

        const lead: i32 = prefs.reminder_minutes;
        while (reminders_mod.due(state.entries, now, lead)) |entry| {
            // Marked before the send: a reminder that fails to send once is
            // not worth a retry every poll until the meeting starts.
            entry.reminded = true;
            self.sendReminder(entry.*, now, prefs) catch |err| {
                log.err("could not send the reminder for \"{s}\": {s}", .{ entry.title, @errorName(err) });
            };
        }
    }

    /// Fetches the listing again when it is stale or the day has turned.
    /// The last hour of the day also fetches tomorrow, so a lead that
    /// crosses midnight has something to find.
    ///
    /// One arena, reset and reused: the bot's allocator is the process
    /// arena, so a fresh one per refresh would pile up a listing's worth of
    /// memory every few minutes for as long as the bot runs.
    fn refreshReminders(self: *Bot, calendar: gcal.Config, now: i32) void {
        const today = dates.today();
        const clock_ns = std.Io.Clock.now(.boot, self.cfg.io).nanoseconds;
        if (self.reminders) |state| {
            const age = @divTrunc(clock_ns - state.refreshed_ns, std.time.ns_per_s);
            if (age < REMINDER_REFRESH_SECONDS and state.day.order(today) == .eq) return;
        }
        if (self.reminders == null) {
            self.reminders = .{
                .arena = std.heap.ArenaAllocator.init(self.cfg.gpa),
                .entries = &.{},
                .day = today,
                .refreshed_ns = clock_ns,
            };
        }
        const state = &self.reminders.?;
        state.refreshed_ns = clock_ns;

        var scratch_state: std.heap.ArenaAllocator = .init(self.cfg.gpa);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();

        // Both days into scratch first: a Google hiccup must not cost the
        // copy already held, which may carry a reminder due this minute.
        const today_listing = self.listForReminders(scratch, calendar, today) orelse return self.reminderRefreshFailed();
        const tomorrow_listing: []const gcal.Listed = if (now >= 23 * 60)
            self.listForReminders(scratch, calendar, today.shift(1)) orelse return self.reminderRefreshFailed()
        else
            &.{};

        // What was reminded today survives the reset; a new day starts clean.
        const previous: []const reminders_mod.Entry = if (state.day.order(today) == .eq) state.entries else &.{};
        var kept: std.ArrayList(reminders_mod.Entry) = .empty;
        for (previous) |entry| {
            if (!entry.reminded) continue;
            kept.append(scratch, .{
                .id = scratch.dupe(u8, entry.id) catch return,
                .title = "",
                .link = "",
                .description = "",
                .start = entry.start,
                .end = entry.end,
                .reminded = true,
            }) catch return;
        }

        _ = state.arena.reset(.retain_capacity);
        state.entries = &.{};
        state.day = today;
        const arena = state.arena.allocator();
        var out: std.ArrayList(reminders_mod.Entry) = .empty;
        reminders_mod.collect(arena, &out, today_listing, 0, kept.items) catch return;
        reminders_mod.collect(arena, &out, tomorrow_listing, 1, kept.items) catch return;
        state.entries = out.items;
        if (state.failing) log.info("meeting reminders: the listing is back", .{});
        state.failing = false;
    }

    fn reminderRefreshFailed(self: *Bot) void {
        if (self.reminders) |*state| {
            if (!state.failing) log.warn("meeting reminders: could not refresh the listing; keeping the last one", .{});
            state.failing = true;
        }
    }

    fn listForReminders(self: *Bot, arena: std.mem.Allocator, calendar: gcal.Config, day: dates.Day) ?[]const gcal.Listed {
        return gcal.list(self.cfg.io, arena, calendar, day.year, day.month, day.day) catch |err| {
            const quiet = if (self.reminders) |state| state.failing else false;
            if (!quiet) log.warn("meeting reminders: listing {d:0>4}-{d:0>2}-{d:0>2} failed: {s}", .{ day.year, day.month, day.day, @errorName(err) });
            return null;
        };
    }

    /// The reminder message, with the agenda when the entry has one. The
    /// agenda follows the summaries setting -- spoken when summaries are,
    /// with the reminder itself as the caption so the link stays tappable.
    fn sendReminder(self: *Bot, entry: reminders_mod.Entry, now: i32, prefs: settings_mod.Settings) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.cfg.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const heading = try reminders_mod.text(arena, entry, now);
        log.info("meeting reminder: \"{s}\" at {d} minutes past midnight, {d} minute(s) ahead", .{ entry.title, entry.start, entry.start - now });

        const agenda = summarize_mod.forAgenda(
            self.cfg.io,
            arena,
            self.cfg.ollama_url,
            self.cfg.ollama_model,
            prefs.language,
            entry.title,
            entry.description,
        );

        if (agenda) |body| {
            if (prefs.summaries == .voice) {
                const caption = try std.fmt.allocPrint(arena, "{s}\n\nAgenda:", .{heading});
                if (self.sendSpoken(arena, .{ .caption = caption, .body = body })) return;
            }
            return self.client.sendMessage(try std.fmt.allocPrint(arena, "{s}\n\nAgenda: {s}", .{ heading, body }));
        }
        return self.client.sendMessage(heading);
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
            if (text.len > 0) return self.handleText(arena, chat_id, text, false);
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

        try self.stage(filename, document.mime_type orelse "application/octet-stream", bytes, "");
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
                return self.handleText(arena, chat_id, trimmed, false);
            }
        }

        try self.client.sendMessage(try std.fmt.allocPrint(
            arena,
            "Got {s} ({s}). Tell me what to do with it -- \"reply to that saying here's the file\", for example. I'll show you the draft before anything is sent.",
            .{ filename, attachments_mod.humanSize(bytes.len, &size_buf) },
        ));
    }

    /// Allocations finish before the arena is moved into place; see `remember`.
    fn stage(self: *Bot, filename: []const u8, content_type: []const u8, bytes: []const u8, source: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.cfg.gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        const owned_name = try arena.dupe(u8, filename);
        const owned_type = try arena.dupe(u8, content_type);
        const owned_bytes = try arena.dupe(u8, bytes);
        const owned_source = try arena.dupe(u8, source);

        if (self.staged) |*previous| previous.arena.deinit();
        self.staged = .{
            .arena = arena_state,
            .filename = owned_name,
            .content_type = owned_type,
            .bytes = owned_bytes,
            .source = owned_source,
            .created_ns = std.Io.Clock.now(.boot, self.cfg.io).nanoseconds,
        };
    }

    /// Allocations finish before the arena is moved; see `remember`.
    fn rememberComposing(self: *Bot, recipient: []const u8, label: []const u8, instruction: []const u8, wants_attachment: bool) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.cfg.gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        const owned_recipient = try arena.dupe(u8, recipient);
        const owned_label = try arena.dupe(u8, label);
        const owned_instruction = try arena.dupe(u8, instruction);

        if (self.composing) |*previous| previous.arena.deinit();
        self.composing = .{
            .arena = arena_state,
            .recipient = owned_recipient,
            .label = owned_label,
            .instruction = owned_instruction,
            .wants_attachment = wants_attachment,
            .created_ns = std.Io.Clock.now(.boot, self.cfg.io).nanoseconds,
        };
    }

    fn discardComposing(self: *Bot) void {
        if (self.composing) |*composing| composing.arena.deinit();
        self.composing = null;
    }

    /// Short-lived on purpose: a half-finished compose that outlives the
    /// conversation would swallow an unrelated message hours later.
    fn freshComposing(self: *Bot) ?*Composing {
        if (self.composing == null) return null;
        const composing = &self.composing.?;
        const age = @divTrunc(
            std.Io.Clock.now(.boot, self.cfg.io).nanoseconds - composing.created_ns,
            std.time.ns_per_s,
        );
        if (age > COMPOSE_TTL_SECONDS) {
            self.discardComposing();
            return null;
        }
        return composing;
    }

    /// The staged change, unless it has gone stale.
    fn freshPendingSetting(self: *Bot) ?settings_mod.Change {
        const staged = self.pending_setting orelse return null;
        const age = @divTrunc(
            std.Io.Clock.now(.boot, self.cfg.io).nanoseconds - staged.created_ns,
            std.time.ns_per_s,
        );
        if (age > PENDING_SETTING_TTL_SECONDS) {
            self.pending_setting = null;
            return null;
        }
        return staged.change;
    }

    fn discardStaged(self: *Bot) void {
        if (self.staged) |*staged| staged.arena.deinit();
        self.staged = null;
    }

    fn discardPendingEvent(self: *Bot) void {
        if (self.pending_event) |*event| event.arena.deinit();
        self.pending_event = null;
    }

    /// The calendar entry waiting on the owner, unless it has gone stale.
    fn freshPendingEvent(self: *Bot) ?*PendingEvent {
        if (self.pending_event == null) return null;
        const event = &self.pending_event.?;
        const age = @divTrunc(
            std.Io.Clock.now(.boot, self.cfg.io).nanoseconds - event.created_ns,
            std.time.ns_per_s,
        );
        if (age > PENDING_EVENT_TTL_SECONDS) {
            log.info("pending calendar entry \"{s}\" expired", .{event.title});
            self.discardPendingEvent();
            return null;
        }
        return event;
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

    fn handleText(self: *Bot, arena: std.mem.Allocator, chat_id: []const u8, text: []const u8, spoken: bool) !void {
        if (!try self.ownerCheck(arena, chat_id, text)) return;

        // A pasted login carries a one-time code; the journal gets a note,
        // not the code.
        if (self.pending_login != null and gcal.looksLikeLogin(text)) {
            log.info("owner message: (pasted the calendar login)", .{});
        } else {
            log.info("owner message: {s}", .{text});
        }
        // Mailbox fetches and local summarisation take tens of seconds, during
        // which the bot looks dead. Say something first.
        self.client.sendTyping();

        self.spoken_reply = null;
        const reply = if (text[0] == '/')
            try self.handleCommand(arena, text)
        else
            try self.handleNaturalLanguage(arena, text, spoken);

        // History records the text either way: "reply to it" after a voice
        // summary must know what was said, and the model reads history.
        if (self.spoken_reply) |voice| {
            self.spoken_reply = null;
            if (self.sendSpoken(arena, voice)) return self.record(text, reply);
        }
        try self.client.sendMessage(reply);
        if (self.redact_next_record) {
            self.redact_next_record = false;
            return self.record("(pasted the calendar login)", reply);
        }
        try self.record(text, reply);
    }

    /// Speaks and sends `voice`, or returns false so the caller falls back
    /// to text. Never an error: a summary the owner cannot hear is still one
    /// they can read.
    fn sendSpoken(self: *Bot, arena: std.mem.Allocator, voice: SpokenReply) bool {
        const tts = self.cfg.speech orelse {
            log.warn("summaries are set to voice but PIPER_BIN is not configured; sending text", .{});
            return false;
        };
        const prefs = self.settings.reload();
        const audio = speech_mod.synthesize(self.cfg.io, arena, tts, tts.voiceFor(&prefs), voice.body) catch |err| {
            log.warn("could not speak the summary ({s}); sending text", .{@errorName(err)});
            return false;
        };
        self.client.sendVoice(arena, audio, voice.caption) catch |err| {
            log.warn("voice message not sent ({s}); sending text", .{@errorName(err)});
            return false;
        };
        return true;
    }

    /// Marks the reply being built as one to speak, when the owner has asked
    /// for that. The caller still returns the text form.
    fn offerSpoken(self: *Bot, caption: []const u8, body: []const u8) void {
        if (self.settings.reload().summaries != .voice) return;
        self.spoken_reply = .{ .caption = caption, .body = body };
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

        const raw = transcribe.transcribe(self.cfg.io, arena, audio, prompt, self.cfg.whisper_languages) catch |err| {
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
        try self.handleText(arena, chat_id, text, true);
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
        if (std.mem.eql(u8, command, "/settings")) return self.settingsText(arena);
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
        if (std.mem.eql(u8, command, "/recent")) {
            const days = std.fmt.parseInt(u16, arg, 10) catch null;
            return self.doRecentMail(arena, days);
        }
        if (std.mem.eql(u8, command, "/attachments")) return self.doListAttachments(arena);
        if (std.mem.eql(u8, command, "/get")) {
            // No argument means "the only one", which doGetAttachment handles
            // by skipping the model entirely.
            return self.doGetAttachment(arena, arg);
        }
        if (std.mem.eql(u8, command, "/compose")) {
            if (arg.len == 0) return "Usage: /compose someone@example.com <what to say>";
            // A leading address is taken exactly as given -- typed input, not
            // model output. Anything else goes to the contact book, and a
            // missing body is asked for rather than invented.
            const split = std.mem.indexOfScalar(u8, arg, ' ') orelse arg.len;
            const first = arg[0..split];
            const rest = std.mem.trim(u8, arg[@min(split + 1, arg.len)..], " \t");
            if (headers_mod.address(first) != null and rest.len > 0) {
                return self.doComposeMail(arena, first, rest, false);
            }
            return self.doComposeMail(arena, arg, null, false);
        }
        if (std.mem.eql(u8, command, "/reply")) {
            if (arg.len == 0) return "Usage: /reply <text>  (replies to the last email I showed you)";
            return self.doDraftReply(arena, arg, true);
        }
        if (std.mem.eql(u8, command, "/event")) {
            if (arg.len == 0) return "Usage: /event dentist tomorrow at 10  (what, and when)";
            return self.doCreateEvent(arena, arg);
        }
        if (std.mem.eql(u8, command, "/calendar")) return self.doConnectCalendar(arena);
        if (std.mem.eql(u8, command, "/agenda")) return self.doListEvents(arena, arg);
        if (std.mem.eql(u8, command, "/delete")) {
            if (arg.len == 0) return "Usage: /delete the dentist on thursday  (which entry, and when)";
            return self.doRemoveEvent(arena, arg);
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

    fn handleNaturalLanguage(self: *Bot, arena: std.mem.Allocator, text: []const u8, spoken: bool) ![]const u8 {
        // A login link was sent and this is the browser's address pasted
        // back. Checked first: it is never a yes, a no, or a command, and
        // must not reach a model.
        if (self.freshPendingLogin() != null and gcal.looksLikeLogin(text)) {
            return self.doFinishLogin(arena, text);
        }

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
        } else if (self.freshPendingEvent()) |event| {
            if (event.day != null) {
                switch (answer) {
                    .confirm => {
                        // Typed only, as for a settings change: a spoken yes
                        // commits nothing, and the entry is kept so the
                        // owner only has to type the one word.
                        if (spoken) {
                            log.info("ignoring a spoken yes on a pending calendar entry", .{});
                            return "I don't act on a spoken yes for the calendar -- type yes to add it, or no to drop it.";
                        }
                        log.info("owner confirmed the calendar entry with: {s}", .{text});
                        return self.doAddEvent(arena);
                    },
                    .cancel => {
                        log.info("owner dropped the calendar entry with: {s}", .{text});
                        self.discardPendingEvent();
                        return "Dropped it. Nothing was added to your calendar.";
                    },
                    .unclear => {},
                }
            } else if (answer == .cancel) {
                self.discardPendingEvent();
                return "Dropped it. Nothing was added to your calendar.";
            } else if (try self.fillEventWhen(arena, text)) |reply| {
                // The entry was missing its day, and this message named one.
                return reply;
            }
        } else if (self.freshPendingRemoval()) |removal| {
            if (removal.chosen != null) {
                switch (answer) {
                    .confirm => {
                        if (spoken) {
                            log.info("ignoring a spoken yes on a pending removal", .{});
                            return "I don't act on a spoken yes for the calendar -- type yes to remove it, or no to keep it.";
                        }
                        log.info("owner confirmed the removal with: {s}", .{text});
                        return self.doRemoveConfirmed(arena);
                    },
                    .cancel => {
                        log.info("owner kept the entry with: {s}", .{text});
                        self.discardPendingRemoval();
                        return "Kept it. Nothing was removed.";
                    },
                    .unclear => {},
                }
            } else if (answer == .cancel) {
                self.discardPendingRemoval();
                return "Left your calendar as it is.";
            } else if (try self.chooseRemoval(arena, text)) |reply| {
                return reply;
            }
        } else if (self.freshPendingSetting()) |change| {
            switch (answer) {
                .confirm => {
                    // Same rule as a pending send: a spoken yes does not
                    // commit anything. The staged change is kept, so the
                    // owner only has to type the one word.
                    if (spoken) {
                        log.info("ignoring a spoken yes on a staged settings change", .{});
                        return "I don't act on a spoken yes for settings -- type yes to confirm it, or no to leave things as they are.";
                    }
                    log.info("owner confirmed the staged settings change with: {s}", .{text});
                    self.pending_setting = null;
                    return self.applySetting(arena, change);
                },
                // A spoken no is honoured: declining is the safe direction,
                // and making someone type to *refuse* something is friction
                // with nothing behind it.
                .cancel => {
                    log.info("owner rejected the staged settings change with: {s}", .{text});
                    self.pending_setting = null;
                    return "Left your settings as they were.";
                },
                // Anything else is a new request, not an answer to this one.
                .unclear => {},
            }
        } else if (self.freshComposing() != null and answer == .cancel) {
            self.discardComposing();
            return "Dropped it. Nothing was drafted.";
        } else if (answer != .unclear) {
            // A bare yes/no with nothing pending is inert. It must never reach
            // the classifier, which once turned a stray "yes" into a brand-new
            // invented draft -- one more "yes" from sending it.
            return "There's no draft waiting, so there's nothing to say yes or no to.";
        }

        // A compose still missing a piece takes the next message as that
        // piece. Re-classifying it cannot work: "you@example.com" and
        // "Thanks for the file" are not commands, and the classifier
        // correctly called the second one unknown -- which left the compose
        // stuck with nowhere to go.
        if (self.freshComposing()) |composing| {
            const needs_recipient = composing.recipient.len == 0;
            log.info("filling in the {s} for a pending compose", .{
                if (needs_recipient) "recipient" else "message",
            });
            return self.doComposeMail(arena, text, if (needs_recipient) null else text, spoken);
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
                if (self.pending_event != null and self.pending_event.?.day != null) {
                    return "I'm not sure if that's a yes or a no, so I haven't added anything. Reply 'yes' to add it to your calendar, or 'no' to drop it.";
                }
                if (self.pending_removal != null and self.pending_removal.?.chosen != null) {
                    return "I'm not sure if that's a yes or a no, so I haven't removed anything. Reply 'yes' to remove it, or 'no' to keep it.";
                }
                return understood.reply;
            },
            .help => HELP_TEXT,
            .status => try self.statusText(arena),
            .list_senders => try self.sendersText(arena),
            .show_settings => try self.settingsText(arena),
            // Parsed from the owner's literal words, not from model output --
            // see settings.parseChange.
            .change_setting => try self.doChangeSetting(arena, text, spoken),
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
            // A missing sender means "from anyone" -- unless the words point
            // at the message already open, in which case use that.
            .read_mail => if (understood.target == null and
                refersToOpenMessage(text) and self.last_message != null)
                try self.readOpenMessage(arena)
            else
                try self.doRead(arena, tidyTarget(understood.target orelse ""), understood.days),
            .summarize_mail => if (understood.target == null and
                refersToOpenMessage(text) and self.last_message != null)
                try self.summarizeOpenMessage(arena)
            else
                try self.doSummarize(arena, tidyTarget(understood.target orelse ""), understood.days),
            .recent_mail => try self.doRecentMail(arena, understood.days),
            .draft_reply => try self.doDraftReply(arena, understood.message, false),
            .compose_mail => try self.doComposeMail(arena, text, understood.message, spoken),
            // The whole message is read by code for the day and time; only
            // the title comes from a model, and only in the owner's words.
            .create_event => try self.doCreateEvent(arena, text),
            .connect_calendar => try self.doConnectCalendar(arena),
            .list_events => try self.doListEvents(arena, text),
            .remove_event => try self.doRemoveEvent(arena, text),
        };

        if (std.mem.eql(u8, result, understood.reply)) return result;
        return std.fmt.allocPrint(arena, "{s}\n{s}", .{ understood.reply, result });
    }

    fn ranker(self: *Bot) findmail.Ranker {
        return .{
            .ollama_url = self.cfg.ollama_url,
            .model = self.cfg.ollama_model,
            .typesafe_api_key = self.cfg.typesafe_api_key,
            .jev_model = self.cfg.jev_model,
            .use_typesafe = self.cfg.typesafe_rank_mail,
        };
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

    /// Everything the owner can change, plus the two things they cannot.
    ///
    /// The read-only pair is shown on purpose: "why didn't my spoken yes send
    /// that email" is a question this answers, and a setting nobody can see is
    /// one nobody knows is on.
    fn settingsText(self: *Bot, arena: std.mem.Allocator) ![]const u8 {
        const senders = try self.controller.senders();
        defer self.controller.freeSenders(senders);
        const current = self.settings.reload();

        var from_buffer: [8]u8 = undefined;
        var to_buffer: [8]u8 = undefined;

        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.print("Watching {d} sender(s)", .{senders.len});
        try out.writer.print("\nNotifications: {s}", .{
            if (self.controller.isPaused()) "paused" else "on",
        });
        if (current.quietEnabled()) {
            try out.writer.print("\nQuiet hours: {s}-{s} (I keep watching, and tell you what arrived once they end)", .{
                settings_mod.formatTime(current.quiet_from, &from_buffer),
                settings_mod.formatTime(current.quiet_to, &to_buffer),
            });
        } else {
            try out.writer.writeAll("\nQuiet hours: off");
        }
        try out.writer.print("\nDefault look-back: {d} days", .{current.default_days});
        try out.writer.print("\nSummaries: {s}", .{current.summaries.label()});
        if (current.summaries == .voice and self.cfg.speech == null) {
            try out.writer.writeAll(" -- but PIPER_BIN isn't set in .env, so you get text until it is");
        }
        try out.writer.print("\nLanguage: {s}", .{current.language.name()});
        if (self.cfg.speech) |tts| {
            try out.writer.print("\nVoices: {s} for English, {s} for Spanish", .{
                settings_mod.speakerOfVoice(tts.voiceForLanguage(&current, .en)),
                settings_mod.speakerOfVoice(tts.voiceForLanguage(&current, .es)),
            });
            const installed = speech_mod.available(self.cfg.io, arena, tts);
            if (installed.len > 0) {
                try out.writer.writeAll("\nInstalled voices:");
                for (installed) |name| {
                    const language = settings_mod.languageOfVoice(name) orelse continue;
                    try out.writer.print(" {s} ({s})", .{ settings_mod.speakerOfVoice(name), @tagName(language) });
                }
            }
        }
        if (self.cfg.calendar) |calendar| {
            try out.writer.print("\nCalendar: Google, {s}, {s} (set in .env)", .{
                calendar.calendar_id,
                if (gcal.isAuthorized(self.cfg.io, arena, calendar)) "connected" else "not connected -- say \"connect my calendar\"",
            });
        } else {
            try out.writer.writeAll("\nCalendar: not set up (GOOGLE_CLIENT_ID in .env)");
        }
        if (current.meeting_reminders) {
            try out.writer.print("\nMeeting reminders: {d} minutes before any entry with a link to join, with its agenda as {s}", .{
                current.reminder_minutes, current.summaries.label(),
            });
        } else {
            try out.writer.writeAll("\nMeeting reminders: off");
        }
        try out.writer.print("\nVoice can confirm send: {s} (set in .env)", .{
            if (self.cfg.voice_can_confirm_send) "yes" else "no",
        });
        try out.writer.print("\nModel: {s} (set in .env)", .{self.cfg.ollama_model});
        return out.written();
    }

    fn doChangeSetting(
        self: *Bot,
        arena: std.mem.Allocator,
        text: []const u8,
        spoken: bool,
    ) ![]const u8 {
        const current = self.settings.reload();
        const installed: []const []const u8 = if (self.cfg.speech) |tts| speech_mod.available(self.cfg.io, arena, tts) else &.{};

        const change = settings_mod.parseChange(text, current, installed) orelse {
            // Refusing beats guessing here: a wrong quiet window shows up as
            // no notifications, which is indistinguishable from working.
            log.info("no settings change found in: {s}", .{text});
            return "I didn't catch which setting to change. Try \"don't notify me before 8am\", \"no notifications between 10pm and 7am\", \"turn off quiet hours\", \"look back 30 days by default\", \"send summaries as voice messages\", \"summaries in Spanish\", \"use john's voice\", \"remind me 15 minutes before meetings\" or \"turn off meeting reminders\" -- /settings shows what I have now, including the voices installed.";
        };

        // A typed change is unambiguous and applies immediately. A *spoken*
        // one waits for a yes, because the one failure typing does not have
        // is mishearing -- and "before 8am" heard as "before 9am" produces a
        // quiet window the owner never asked for, whose symptom is silence.
        // Silence is indistinguishable from everything working, so this is
        // the kind of mistake nobody notices for a week.
        //
        // Confirmation has to be *typed*, the same as a pending send: one
        // rule across the whole bot -- nothing a voice note says is committed
        // without a typed yes -- is easier to rely on than a per-feature
        // judgment about which mistakes are recoverable. Declining still
        // works by voice, because refusing is the safe direction.
        if (spoken) {
            self.pending_setting = .{
                .change = change,
                .created_ns = std.Io.Clock.now(.boot, self.cfg.io).nanoseconds,
            };
            return std.fmt.allocPrint(arena, "{s}\n\nType yes to confirm, or say no to leave it.", .{
                try describeChange(arena, change),
            });
        }

        return self.applySetting(arena, change);
    }

    /// What a change would do, in the owner's terms. Shown before a spoken
    /// change is applied so a misheard time is caught by reading it back.
    fn describeChange(arena: std.mem.Allocator, change: settings_mod.Change) ![]const u8 {
        var from_buffer: [8]u8 = undefined;
        var to_buffer: [8]u8 = undefined;
        return switch (change) {
            .quiet_off => "That turns quiet hours off -- I'd notify you whenever mail arrives.",
            .quiet_hours => |window| try std.fmt.allocPrint(
                arena,
                "That sets quiet hours to {s}-{s}.",
                .{
                    settings_mod.formatTime(window.from, &from_buffer),
                    settings_mod.formatTime(window.to, &to_buffer),
                },
            ),
            .default_days => |days| try std.fmt.allocPrint(
                arena,
                "That sets the default look-back to {d} day(s).",
                .{days},
            ),
            .summaries => |delivery| switch (delivery) {
                .voice => "That switches summaries to voice messages.",
                .text => "That switches summaries back to text.",
            },
            .language => |language| try std.fmt.allocPrint(
                arena,
                "That switches summaries to {s}.",
                .{language.name()},
            ),
            .voice => |name| try std.fmt.allocPrint(
                arena,
                "That switches the {s} voice to {s}.",
                .{
                    (settings_mod.languageOfVoice(name.slice()) orelse settings_mod.Language.en).name(),
                    settings_mod.speakerOfVoice(name.slice()),
                },
            ),
            .reminders => |on| if (on)
                "That turns meeting reminders on."
            else
                "That turns meeting reminders off.",
            .reminder_minutes => |minutes| try std.fmt.allocPrint(
                arena,
                "That sets meeting reminders to {d} minute(s) before the start.",
                .{minutes},
            ),
        };
    }

    fn applySetting(self: *Bot, arena: std.mem.Allocator, change: settings_mod.Change) ![]const u8 {
        var current = self.settings.reload();

        switch (change) {
            .quiet_off => {
                current.quiet_from = settings_mod.OFF;
                current.quiet_to = settings_mod.OFF;
            },
            .quiet_hours => |window| {
                current.quiet_from = window.from;
                current.quiet_to = window.to;
            },
            .default_days => |days| current.default_days = days,
            .summaries => |delivery| current.summaries = delivery,
            .language => |language| current.language = language,
            // parseChange only returns names from the installed list, and
            // the list only holds en_/es_ names, so the prefix is known.
            .voice => |name| switch (settings_mod.languageOfVoice(name.slice()) orelse .en) {
                .en => current.voice_en = name,
                .es => current.voice_es = name,
            },
            .reminders => |on| current.meeting_reminders = on,
            .reminder_minutes => |minutes| {
                current.reminder_minutes = minutes;
                current.meeting_reminders = true;
            },
        }

        self.settings.save(current) catch |err| {
            log.err("could not persist settings: {s}", .{@errorName(err)});
            return "I understood that, but couldn't write it to disk -- it would be lost on a restart, so I haven't applied it.";
        };

        var from_buffer: [8]u8 = undefined;
        var to_buffer: [8]u8 = undefined;
        return switch (change) {
            .quiet_off => "Quiet hours off -- I'll notify you whenever mail arrives.",
            .quiet_hours => try std.fmt.allocPrint(
                arena,
                "Quiet hours set: {s}-{s}. Nothing will reach you in that window; whatever arrives is reported once it ends.",
                .{
                    settings_mod.formatTime(current.quiet_from, &from_buffer),
                    settings_mod.formatTime(current.quiet_to, &to_buffer),
                },
            ),
            .default_days => |days| try std.fmt.allocPrint(
                arena,
                "Default look-back set to {d} day(s).",
                .{days},
            ),
            .summaries => |delivery| switch (delivery) {
                // Saved either way: once piper is configured and the bot
                // restarted, the choice is already made. The voice is named
                // so "use the voice amy" with no amy installed -- which lands
                // here as a plain switch to audio -- is visibly not that.
                .voice => if (self.cfg.speech) |tts|
                    try std.fmt.allocPrint(
                        arena,
                        "Summaries will come as voice messages from now on -- new mail from the watcher and any you ask me for. Read by {s}; /settings lists the other voices installed.",
                        .{settings_mod.speakerOfVoice(tts.voiceFor(&current))},
                    )
                else
                    "Saved -- but voice summaries need PIPER_BIN in .env and a restart, so you'll get text until then.",
                .text => "Summaries back to text.",
            },
            .language => |language| try std.fmt.allocPrint(
                arena,
                "Summaries in {s} from now on.",
                .{language.name()},
            ),
            .voice => |name| blk: {
                const language = settings_mod.languageOfVoice(name.slice()) orelse .en;
                const speaker = settings_mod.speakerOfVoice(name.slice());
                // Say when they will not hear it yet, because "I changed the
                // voice and nothing happened" is the obvious next message.
                const caveat: []const u8 = if (current.summaries != .voice)
                    " Summaries are text right now -- say \"send summaries as voice messages\" to hear it."
                else if (current.language != language)
                    try std.fmt.allocPrint(arena, " Summaries are in {s} right now, so you'll hear it once they're in {s}.", .{ current.language.name(), language.name() })
                else
                    "";
                break :blk try std.fmt.allocPrint(arena, "{s} voice set to {s}.{s}", .{ language.name(), speaker, caveat });
            },
            .reminders => |on| if (on)
                try std.fmt.allocPrint(arena, "Meeting reminders on: {d} minute(s) before any calendar entry with a link to join.{s}", .{
                    current.reminder_minutes, self.reminderCaveat(),
                })
            else
                "Meeting reminders off.",
            .reminder_minutes => |minutes| try std.fmt.allocPrint(arena, "Meeting reminders {d} minute(s) before the start, for any calendar entry with a link to join.{s}", .{
                minutes, self.reminderCaveat(),
            }),
        };
    }

    /// Why a reminder setting will not do anything yet, if it will not.
    fn reminderCaveat(self: *Bot) []const u8 {
        const calendar = self.cfg.calendar orelse return " The calendar isn't set up yet, though -- GOOGLE_CLIENT_ID in .env.";
        if (!gcal.isAuthorized(self.cfg.io, self.cfg.gpa, calendar)) return " The calendar isn't connected yet, though -- say \"connect my calendar\".";
        return "";
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
        /// A UID is only meaningful in the mailbox it was found in, and
        /// content search looks in a different one from everything else.
        mailbox: imap.Mailbox = .inbox,
        from: []const u8,
        subject: []const u8,
        date: []const u8,
        body: []const u8,
        headers: []const u8,
        attachments: []const imap.Attachment,
    };

    /// The newest message from `target` within `days`, or null.
    /// The newest message from `target`, or -- when `target` is empty -- the
    /// newest message from anyone.
    ///
    /// "Show me the last email" names no sender, and refusing to answer it
    /// was worse than useless: the follow-up question ("from whom?") cannot
    /// be answered by someone who does not care who sent it.
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
                // INBOX, not All Mail: "the latest email" means one that
                // arrived, and All Mail also holds the owner's own Sent
                // messages, which would win on recency.
                _ = try session.examine(.inbox);
                // Both return newest first, so one slot is enough.
                const hits = if (ctx.target.len == 0)
                    try session.searchRecent(ctx.days, ctx.buffer)
                else
                    try session.searchFrom(ctx.target, ctx.days, ctx.buffer);
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
            .mailbox = latest.mailbox,
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
            mailbox: imap.Mailbox,
            buffer: []u8,
            bytes: []u8 = &.{},

            fn run(ctx: *@This(), session: *imap.Session) anyerror!void {
                _ = try session.examine(ctx.mailbox);
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
            .mailbox = original.mailbox,
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

    /// Re-read rather than cached: the owner may have changed it this session.
    fn defaultDays(self: *Bot) u16 {
        return self.settings.reload().default_days;
    }

    fn doSearch(self: *Bot, arena: std.mem.Allocator, target: []const u8, days_opt: ?u16) ![]const u8 {
        const days = days_opt orelse self.defaultDays();
        const target_z = try arena.dupeZ(u8, target);
        const buffer = try arena.alloc(imap.Envelope, SEARCH_RESULT_LIMIT);

        const Context = struct {
            target: [:0]const u8,
            days: u16,
            buffer: []imap.Envelope,
            hits: []imap.Envelope = &.{},

            fn run(ctx: *@This(), session: *imap.Session) anyerror!void {
                _ = try session.examine(.inbox);
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

    /// Everything that arrived recently, whoever sent it.
    ///
    /// The gap this fills: every other mail action is keyed on a sender or a
    /// topic, so "what came in this morning" had nowhere to go. It routed to
    /// read_mail with no target and asked who -- a question the request has
    /// already answered with "anyone".
    fn doRecentMail(self: *Bot, arena: std.mem.Allocator, days_opt: ?u16) ![]const u8 {
        // IMAP's SINCE has date granularity, so "this morning" is today.
        // Deliberately not the configurable look-back: "anything new?" means
        // today, and answering it with a fortnight of mail is not the same
        // question. The look-back is for "any mail from X", which has to
        // reach back far enough to find something.
        const days = days_opt orelse 1;
        const buffer = try arena.alloc(imap.Envelope, SEARCH_RESULT_LIMIT);

        const Context = struct {
            days: u16,
            buffer: []imap.Envelope,
            hits: []imap.Envelope = &.{},

            fn run(ctx: *@This(), session: *imap.Session) anyerror!void {
                _ = try session.examine(.inbox);
                ctx.hits = try session.searchRecent(ctx.days, ctx.buffer);
            }
        };

        var context: Context = .{ .days = days, .buffer = buffer };
        self.withMailbox(&context, Context.run) catch |err| {
            log.err("recent-mail search failed: {s}", .{@errorName(err)});
            return "Couldn't search the mailbox right now -- try again in a bit.";
        };

        if (context.hits.len == 0) {
            return std.fmt.allocPrint(arena, "Nothing in the last {d} day(s).", .{days});
        }

        // Open the newest, so "read it" or "does it have attachments" works
        // straight after without naming anyone.
        self.rememberFound(arena, context.hits[0].uid, .inbox) catch |err| {
            log.warn("could not open the newest message: {s}", .{@errorName(err)});
        };

        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.print("{d} message(s) in the last {d} day(s):", .{ context.hits.len, days });
        for (context.hits) |*envelope| {
            try out.writer.print("\n- {s}\n  {s} | {s}", .{
                envelope.subjectSlice(), envelope.fromSlice(), envelope.dateSlice(),
            });
        }
        try out.writer.writeAll("\n\nThe newest one is open -- ask about \"it\" and I'll mean that.");
        return telegram.truncate(out.writer.buffered());
    }

    /// Does the request point at the message already open, rather than asking
    /// for a new one?
    ///
    /// "Summarize it" after reading something means *that* message. Treating
    /// it as a sender-less request instead fetches the newest mail from
    /// anyone and summarises a message the owner never asked about -- which
    /// is worse than refusing, because it looks like it worked.
    fn refersToOpenMessage(text: []const u8) bool {
        var words = std.mem.tokenizeAny(u8, text, " \t\r\n.,!?;:\"'");
        while (words.next()) |word| {
            for ([_][]const u8{ "it", "that", "this", "same", "one" }) |pronoun| {
                if (std.ascii.eqlIgnoreCase(word, pronoun)) return true;
            }
        }
        return false;
    }

    /// Trims a target down to something a mail server can match.
    ///
    /// The extractor returns the sender as written, which is right, but as
    /// written can be "Chas from Fleet DM" -- a description, not a search
    /// term. IMAP matches substrings of the From header, so the name alone
    /// hits "Chas <chas@example.org>" while the whole phrase hits nothing.
    fn tidyTarget(target: []const u8) []const u8 {
        var best = std.mem.trim(u8, target, " \t\r\n.,");
        for ([_][]const u8{ " from ", " with ", " at ", " of " }) |joiner| {
            if (std.ascii.indexOfIgnoreCase(best, joiner)) |i| {
                const head = std.mem.trim(u8, best[0..i], " \t");
                if (head.len > 0) best = head;
            }
        }
        return best;
    }

    /// Shows the message already open, without going back to the server.
    fn readOpenMessage(self: *Bot, arena: std.mem.Allocator) ![]const u8 {
        const original = &self.last_message.?;
        if (original.body.len == 0) {
            return std.fmt.allocPrint(
                arena,
                "{s} ({s})\n\n(No plain-text body -- it's probably HTML-only.)",
                .{ original.subject, original.date },
            );
        }
        return telegram.truncate(try std.fmt.allocPrint(
            arena,
            "{s}\nFrom: {s}\nDate: {s}\n\n{s}",
            .{ original.subject, original.from, original.date, original.body },
        ));
    }

    fn summarizeOpenMessage(self: *Bot, arena: std.mem.Allocator) ![]const u8 {
        const original = &self.last_message.?;
        self.client.sendTyping();
        const summary = summarize_mod.summarize(
            self.cfg.io,
            arena,
            self.cfg.ollama_url,
            self.cfg.ollama_model,
            self.settings.reload().language,
            original.from,
            original.subject,
            original.body,
        ) catch {
            return telegram.truncate(try std.fmt.allocPrint(
                arena,
                "Couldn't summarize that one. Here's the raw content instead:\n\n{s} ({s})\n\n{s}",
                .{ original.subject, original.date, original.body },
            ));
        };
        const caption = try std.fmt.allocPrint(arena, "{s} ({s})", .{ original.subject, original.date });
        self.offerSpoken(caption, summary);
        return telegram.truncate(try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ caption, summary }));
    }

    fn doRead(self: *Bot, arena: std.mem.Allocator, target: []const u8, days_opt: ?u16) ![]const u8 {
        const days = days_opt orelse self.defaultDays();
        const latest = self.fetchLatest(arena, target, days) catch |err| {
            log.err("fetching the latest mail failed for {s}: {s}", .{ target, @errorName(err) });
            return "Couldn't read the mailbox right now -- try again in a bit.";
        } orelse {
            if (target.len == 0) {
                return std.fmt.allocPrint(arena, "Nothing in the last {d} day(s).", .{days});
            }
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
        const days = days_opt orelse self.defaultDays();
        const latest = self.fetchLatest(arena, target, days) catch |err| {
            log.err("fetching the latest mail failed for {s}: {s}", .{ target, @errorName(err) });
            return "Couldn't read the mailbox right now -- try again in a bit.";
        } orelse {
            if (target.len == 0) {
                return std.fmt.allocPrint(arena, "Nothing in the last {d} day(s).", .{days});
            }
            return std.fmt.allocPrint(arena, "No mail from {s} in the last {d} day(s).", .{ target, days });
        };

        const summary = summarize_mod.summarize(
            self.cfg.io,
            arena,
            self.cfg.ollama_url,
            self.cfg.ollama_model,
            self.settings.reload().language,
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
        const caption = try std.fmt.allocPrint(arena, "{s} ({s})", .{ latest.subject, latest.date });
        self.offerSpoken(caption, summary);
        return telegram.truncate(try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ caption, summary }));
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
                    ctx.bot.ranker(),
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
        self.rememberFound(arena, found.matches[0].candidate.uid, .all_mail) catch |err| {
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
    fn rememberFound(self: *Bot, arena: std.mem.Allocator, uid: u32, from: imap.Mailbox) !void {
        const Context = struct {
            arena: std.mem.Allocator,
            uid: u32,
            mailbox: imap.Mailbox,
            found: ?Latest = null,

            fn run(ctx: *@This(), session: *imap.Session) anyerror!void {
                ctx.found = null;
                // The UID came from a search in this mailbox; fetching it
                // after a SELECT of another one would quietly return a
                // different message.
                _ = try session.examine(ctx.mailbox);
                var message: imap.Message = undefined;
                try session.fetchMessage(ctx.uid, &message);

                const raw = message.headersSlice();
                ctx.found = .{
                    .uid = ctx.uid,
                    .mailbox = ctx.mailbox,
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

        var context: Context = .{ .arena = arena, .uid = uid, .mailbox = from };
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
        // Same rule as compose: if a file was asked for and none uploaded,
        // take it from the message being replied to, or say why not.
        if (try self.stageFromOpenMessage(arena, instruction_text, mentionsAttaching(instruction_text))) |problem| return problem;

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
            attachment_line = if (staged.source.len > 0)
                try std.fmt.allocPrint(arena, "Attached: {s} ({s}) -- from \"{s}\"\n", .{
                    staged.filename,
                    attachments_mod.humanSize(staged.bytes.len, &size_buf),
                    staged.source,
                })
            else
                try std.fmt.allocPrint(arena, "Attached: {s} ({s})\n", .{
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
    /// Words that mean "put a file on this".
    ///
    /// Deterministic on purpose: this only decides whether the owner *asked*
    /// for an attachment, which their own words answer plainly. Which file
    /// they meant is a judgement, and that goes to the local model below.
    fn mentionsAttaching(text: []const u8) bool {
        const markers = [_][]const u8{
            "attach", "attaching", "attached", "attachment",
            "enclose", "enclosing", "enclosed",
        };
        for (markers) |marker| {
            if (std.ascii.indexOfIgnoreCase(text, marker) != null) return true;
        }
        return false;
    }

    /// Stages a file from the message currently open, when the owner asked
    /// for one and has not uploaded anything.
    ///
    /// Returns null when there is nothing to complain about, or a sentence
    /// explaining why it could not be done. Silence is not an option here:
    /// a body that promises an invoice and a draft that carries none is a
    /// contradiction the owner should never have to notice for themselves,
    /// and it went out that way once already.
    fn stageFromOpenMessage(self: *Bot, arena: std.mem.Allocator, request: []const u8, wanted: bool) !?[]const u8 {
        if (!wanted) return null;
        if (self.freshStaged() != null) return null; // an upload already wins

        if (self.last_message == null) {
            return "You asked me to attach something, but I don't have a message open to take it from. Read or find one first.";
        }
        const original = &self.last_message.?;
        if (original.attachments.len == 0) {
            return try std.fmt.allocPrint(
                arena,
                "You asked me to attach something, but \"{s}\" has no attachments. Upload the file here and I'll put it on the draft.",
                .{original.subject},
            );
        }

        const choice = attachments_mod.choose(
            self.cfg.io,
            arena,
            self.cfg.ollama_url,
            self.cfg.ollama_model,
            request,
            original.attachments,
        ) orelse {
            return try self.doListAttachments(arena);
        };

        const part = original.attachments[choice];
        var size_buf: [32]u8 = undefined;
        if (part.size > mailer.MAX_ATTACHMENT_BYTES) {
            return try std.fmt.allocPrint(
                arena,
                "{s} is {s}, which is more than mail will carry.",
                .{ part.filenameSlice(), attachments_mod.humanSize(part.size, &size_buf) },
            );
        }

        const Context = struct {
            uid: u32,
            index: u32,
            mailbox: imap.Mailbox,
            buffer: []u8,
            bytes: []u8 = &.{},

            fn run(ctx: *@This(), session: *imap.Session) anyerror!void {
                _ = try session.examine(ctx.mailbox);
                ctx.bytes = try session.fetchAttachment(ctx.uid, ctx.index, ctx.buffer);
            }
        };
        const capacity = @min(
            @as(usize, part.size) + (part.size / 4) + 64 * 1024,
            attachments_mod.MAX_BYTES,
        );
        var context: Context = .{
            .uid = original.uid,
            .index = part.index,
            .mailbox = original.mailbox,
            .buffer = try arena.alloc(u8, capacity),
        };
        self.withMailbox(&context, Context.run) catch |err| {
            log.err("could not pull {s} for a draft: {s}", .{ part.filenameSlice(), @errorName(err) });
            return "Couldn't pull that file off the server, so I haven't drafted anything.";
        };

        try self.stage(part.filenameSlice(), part.mimeTypeSlice(), context.bytes, original.subject);
        log.info("staged {s} ({d} bytes) from the open message for the next draft", .{
            part.filenameSlice(), context.bytes.len,
        });
        return null;
    }

    /// A literal address in the owner's own message.
    ///
    /// This outranks everything else and consults no model. An address the
    /// owner typed is owner input, not model output, so the invariant holds
    /// even when that address has never written to this mailbox -- which is
    /// the whole point of being able to write to someone new.
    fn ownerTypedAddress(request: []const u8) ?[]const u8 {
        var tokens = std.mem.tokenizeAny(u8, request, " \t\r\n,;<>()[]\"'");
        while (tokens.next()) |token| {
            if (headers_mod.address(token)) |found| return found;
        }
        return null;
    }

    /// "email myself the notes" -- the owner's own mailbox, which by
    /// definition is rarely in a list built from people who wrote *to* it.
    fn refersToSelf(request: []const u8) bool {
        const markers = [_][]const u8{ "myself", "my own address", "my own email", "my own inbox" };
        for (markers) |marker| {
            if (std.ascii.indexOfIgnoreCase(request, marker) != null) return true;
        }
        return false;
    }

    fn doComposeMail(self: *Bot, arena: std.mem.Allocator, request: []const u8, instruction: ?[]const u8, spoken: bool) ![]const u8 {
        // Carry whatever was already gathered, so a compose can be assembled
        // over several turns rather than demanding one perfect sentence.
        var recipient: []const u8 = "";
        var label: []const u8 = "";
        var said: []const u8 = "";
        // Sticky across turns, like the recipient and the body.
        var wants_attachment = mentionsAttaching(request);
        if (self.freshComposing()) |carried| {
            recipient = try arena.dupe(u8, carried.recipient);
            label = try arena.dupe(u8, carried.label);
            said = try arena.dupe(u8, carried.instruction);
            wants_attachment = wants_attachment or carried.wants_attachment;
        }
        if (instruction) |value| {
            const given = std.mem.trim(u8, value, " \t\r\n");
            if (given.len > 0) {
                said = given;
                wants_attachment = wants_attachment or mentionsAttaching(given);
            }
        }

        if (recipient.len == 0) {
            // A *typed* address is owner input and is taken exactly as given.
            // A *spoken* one is not: transcription adds a failure mode typing
            // does not have, and a corrupted address is still address-shaped,
            // so the form check passes while the meaning is wrong. Observed
            // three times in a row on one real address --
            // "you name@", "you.name@", "name@" -- any of which would
            // have addressed a stranger who really exists. Spoken requests
            // must resolve against the contact book or ask.
            //
            // Same rule as the spoken yes/no on a pending send, for the same
            // reason.
            if (!spoken) {
                if (ownerTypedAddress(request)) |typed| recipient = try arena.dupe(u8, typed);
            }
            if (recipient.len > 0) {
                // taken as given
            } else if (refersToSelf(request)) {
                recipient = self.cfg.imap_user;
                label = "you";
            } else {
                const contacts = self.contactBook(arena) catch |err| {
                    log.err("could not read contacts: {s}", .{@errorName(err)});
                    return "Couldn't read your contacts right now -- try again in a bit.";
                };
                if (contacts_mod.resolve(
                    self.cfg.io,
                    arena,
                    self.cfg.ollama_url,
                    self.cfg.ollama_model,
                    request,
                    contacts,
                )) |choice| {
                    recipient = try arena.dupe(u8, contacts[choice].addressSlice());
                    label = try arena.dupe(u8, contacts[choice].nameSlice());
                }
            }
        }

        // Never guessed at. Mail to the wrong person cannot be recalled, and
        // no preview catches a plausible-but-wrong name skimmed past.
        if (recipient.len == 0) {
            try self.rememberComposing("", "", said, wants_attachment);
            return "Who should this go to? Give me a name I'd recognise from your mail, or type the full address.";
        }
        if (said.len == 0) {
            try self.rememberComposing(recipient, label, "", wants_attachment);
            return std.fmt.allocPrint(arena, "What should I say to {s}?", .{recipient});
        }

        // Asked for an attachment and has not uploaded one: take it from the
        // message currently open, or say plainly why not. Drafting a body
        // that promises a file it does not carry is how one went out empty.
        if (try self.stageFromOpenMessage(arena, said, wants_attachment)) |problem| {
            try self.rememberComposing(recipient, label, said, wants_attachment);
            return problem;
        }
        self.discardComposing();

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
        }, label);
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

    // ---- the calendar ----

    const NOT_SET_UP = "Calendar isn't set up -- put GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET in .env and restart me, then say \"connect my calendar\".";
    const NOT_CONNECTED = "I'm not connected to your calendar yet -- say \"connect my calendar\" and I'll send you the link.";

    fn freshPendingLogin(self: *Bot) ?*PendingLogin {
        if (self.pending_login == null) return null;
        const login = &self.pending_login.?;
        const age = @divTrunc(
            std.Io.Clock.now(.boot, self.cfg.io).nanoseconds - login.created_ns,
            std.time.ns_per_s,
        );
        if (age > PENDING_LOGIN_TTL_SECONDS) {
            log.info("calendar login link expired unused", .{});
            self.pending_login = null;
            return null;
        }
        return login;
    }

    /// Sends the Google link. The browser cannot come back to this machine
    /// from a phone -- Google only allows a loopback redirect for a desktop
    /// client -- so the owner pastes the address it lands on instead.
    fn doConnectCalendar(self: *Bot, arena: std.mem.Allocator) ![]const u8 {
        const calendar = self.cfg.calendar orelse return NOT_SET_UP;
        const login = gcal.beginLogin(self.cfg.io, arena, calendar) catch |err| {
            log.err("could not start the calendar login: {s}", .{@errorName(err)});
            return "Couldn't build the login link -- check the journal.";
        };
        self.pending_login = .{
            .verifier = login.verifier,
            .created_ns = std.Io.Clock.now(.boot, self.cfg.io).nanoseconds,
        };
        log.info("calendar login started; waiting for the pasted address", .{});
        return std.fmt.allocPrint(
            arena,
            "Open this link, signed in as the mailbox owner, and allow the calendar access:\n\n{s}\n\n" ++
                "The browser will then land on a 127.0.0.1 page that fails to load -- that's expected. " ++
                "Copy that page's address from the address bar and paste it here, and I'll finish the login.{s}",
            .{
                login.url,
                if (gcal.isAuthorized(self.cfg.io, arena, calendar)) "\n\n(I'm already connected; this replaces that login.)" else "",
            },
        );
    }

    /// One day of the calendar. The day is read from the owner's words;
    /// none named means today. Nothing here goes near a model.
    fn doListEvents(self: *Bot, arena: std.mem.Allocator, text: []const u8) ![]const u8 {
        const calendar = self.cfg.calendar orelse return NOT_SET_UP;
        const today = dates.today();
        const day = if (appointment.findDay(today, text)) |found| found.day else today;

        const entries = gcal.list(self.cfg.io, arena, calendar, day.year, day.month, day.day) catch |err| switch (err) {
            error.NotAuthorized => return NOT_CONNECTED,
            error.TokenRevoked => return "Google no longer accepts my calendar login -- say \"connect my calendar\" to log in again.",
            else => {
                log.err("could not list the calendar: {s}", .{@errorName(err)});
                return "Couldn't read your calendar just now -- try again in a moment.";
            },
        };
        const label = try appointment.describe(arena, .{ .day = day });
        const day_label = label[0 .. std.mem.indexOf(u8, label, ",") orelse label.len];
        if (entries.len == 0) return std.fmt.allocPrint(arena, "Nothing on your calendar on {s}.", .{day_label});

        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.print("{s}:", .{day_label});
        for (entries) |entry| {
            try out.writer.writeAll("\n");
            if (entry.start_minutes) |start| {
                try out.writer.writeAll(try appointment.clockRange(arena, start, entry.end_minutes));
            } else {
                try out.writer.writeAll("all day    ");
            }
            try out.writer.print("  {s}", .{entry.title});
            if (entry.location.len > 0) try out.writer.print(" ({s})", .{entry.location});
        }
        log.info("listed {d} calendar entr{s} for {s}", .{ entries.len, if (entries.len == 1) "y" else "ies", day_label });
        return out.written();
    }

    fn discardPendingRemoval(self: *Bot) void {
        if (self.pending_removal) |*removal| removal.arena.deinit();
        self.pending_removal = null;
    }

    fn freshPendingRemoval(self: *Bot) ?*PendingRemoval {
        if (self.pending_removal == null) return null;
        const removal = &self.pending_removal.?;
        const age = @divTrunc(
            std.Io.Clock.now(.boot, self.cfg.io).nanoseconds - removal.created_ns,
            std.time.ns_per_s,
        );
        if (age > PENDING_REMOVAL_TTL_SECONDS) {
            log.info("pending calendar removal expired", .{});
            self.discardPendingRemoval();
            return null;
        }
        return removal;
    }

    /// Lists the day, picks the entry the owner means, and holds it for a
    /// yes. An unclear pick shows the day numbered and asks.
    fn doRemoveEvent(self: *Bot, arena: std.mem.Allocator, text: []const u8) ![]const u8 {
        const calendar = self.cfg.calendar orelse return NOT_SET_UP;
        const today = dates.today();
        const day = if (appointment.findDay(today, text)) |found| found.day else today;
        const start: ?i16 = if (appointment.findTime(text)) |time| time.start else null;

        const entries = gcal.list(self.cfg.io, arena, calendar, day.year, day.month, day.day) catch |err| switch (err) {
            error.NotAuthorized => return NOT_CONNECTED,
            error.TokenRevoked => return "Google no longer accepts my calendar login -- say \"connect my calendar\" to log in again.",
            else => {
                log.err("could not list the calendar: {s}", .{@errorName(err)});
                return "Couldn't read your calendar just now -- try again in a moment.";
            },
        };
        const day_label = try dayLabel(arena, day);
        if (entries.len == 0) return std.fmt.allocPrint(arena, "Nothing on your calendar on {s}, so nothing to remove.", .{day_label});

        // Copied into their own arena: the removal outlives this turn.
        var removal_arena: std.heap.ArenaAllocator = .init(self.cfg.gpa);
        errdefer removal_arena.deinit();
        const alloc = removal_arena.allocator();
        const copies = try alloc.alloc(gcal.Listed, entries.len);
        for (entries, copies) |entry, *copy| {
            copy.* = .{
                .id = try alloc.dupe(u8, entry.id),
                .title = try alloc.dupe(u8, entry.title),
                .location = try alloc.dupe(u8, entry.location),
                .start_minutes = entry.start_minutes,
                .end_minutes = entry.end_minutes,
            };
        }

        const candidates = try arena.alloc(appointment.Candidate, entries.len);
        for (entries, candidates) |entry, *candidate| candidate.* = .{ .title = entry.title, .start = entry.start_minutes };
        const chosen = try appointment.pick(arena, candidates, text, start);

        self.discardPendingRemoval();
        self.pending_removal = .{
            .arena = removal_arena,
            .day = day,
            .entries = copies,
            .chosen = chosen,
            .created_ns = std.Io.Clock.now(.boot, self.cfg.io).nanoseconds,
        };
        if (chosen != null) return self.removalPreview(arena);

        log.info("removal on {s}: {d} entries, none picked; asking", .{ day_label, entries.len });
        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.print("Which one? On {s} there {s}:", .{ day_label, if (entries.len == 1) "is" else "are" });
        for (entries, 1..) |entry, n| {
            try out.writer.print("\n{d}. {s}  {s}", .{
                n,
                if (entry.start_minutes) |s| try appointment.clockRange(arena, s, entry.end_minutes) else "all day    ",
                entry.title,
            });
        }
        try out.writer.writeAll("\n\nSay the number or the name, or no to leave it.");
        return out.written();
    }

    /// The follow-up to "which one?": a number or a name. Null when the
    /// message is neither, so it is handled as a new request.
    fn chooseRemoval(self: *Bot, arena: std.mem.Allocator, text: []const u8) !?[]const u8 {
        const removal = &self.pending_removal.?;
        var chosen = appointment.pickByNumber(text, removal.entries.len);
        if (chosen == null) {
            const candidates = try arena.alloc(appointment.Candidate, removal.entries.len);
            for (removal.entries, candidates) |entry, *candidate| candidate.* = .{ .title = entry.title, .start = entry.start_minutes };
            const start: ?i16 = if (appointment.findTime(text)) |time| time.start else null;
            chosen = try appointment.pick(arena, candidates, text, start);
        }
        removal.chosen = chosen orelse return null;
        return try self.removalPreview(arena);
    }

    fn dayLabel(arena: std.mem.Allocator, day: dates.Day) ![]const u8 {
        const label = try appointment.describe(arena, .{ .day = day });
        return label[0 .. std.mem.indexOf(u8, label, ",") orelse label.len];
    }

    fn removalWhen(removal: *const PendingRemoval) appointment.When {
        const entry = removal.entries[removal.chosen.?];
        return .{ .day = removal.day, .start = entry.start_minutes, .end = entry.end_minutes };
    }

    fn removalPreview(self: *Bot, arena: std.mem.Allocator) ![]const u8 {
        const removal = &self.pending_removal.?;
        const entry = removal.entries[removal.chosen.?];
        const when = try appointment.describe(arena, removalWhen(removal));
        log.info("removal of \"{s}\" on {s}; awaiting confirmation", .{ entry.title, when });
        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.print("Remove from your calendar?\n\n{s}\n{s}", .{ entry.title, when });
        if (entry.location.len > 0) try out.writer.print("\n{s}", .{entry.location});
        try out.writer.writeAll("\n\nType yes to remove it, or no to keep it.");
        return out.written();
    }

    fn doRemoveConfirmed(self: *Bot, arena: std.mem.Allocator) ![]const u8 {
        const calendar = self.cfg.calendar orelse return NOT_SET_UP;
        const removal = &self.pending_removal.?;
        const entry = removal.entries[removal.chosen.?];

        gcal.remove(self.cfg.io, arena, calendar, entry.id) catch |err| switch (err) {
            error.NotAuthorized => return NOT_CONNECTED,
            error.TokenRevoked => return "Google no longer accepts my calendar login -- say \"connect my calendar\" to log in again.",
            else => {
                log.err("could not remove \"{s}\": {s}", .{ entry.title, @errorName(err) });
                return "Removing it failed -- it's still on your calendar; say yes to try again.";
            },
        };
        log.info("removed \"{s}\" ({s}) from the calendar", .{ entry.title, entry.id });
        const reply = try std.fmt.allocPrint(arena, "Removed from your calendar: {s}, {s}.", .{
            entry.title, try appointment.describe(arena, removalWhen(removal)),
        });
        self.discardPendingRemoval();
        return reply;
    }

    fn doFinishLogin(self: *Bot, arena: std.mem.Allocator, pasted: []const u8) ![]const u8 {
        const calendar = self.cfg.calendar orelse return NOT_SET_UP;
        const login = self.pending_login.?;
        self.redact_next_record = true;

        // Google's error page rather than the redirect: say why, in
        // Google's words, and what fixes the usual cause.
        if (try gcal.refusalFrom(arena, pasted)) |reason| {
            log.warn("google refused the calendar login: {s}", .{reason});
            self.pending_login = null;
            const testing_hint = if (std.mem.indexOf(u8, reason, "tested") != null)
                "\n\nThat means the OAuth client's consent screen is External and still in Testing, and this mailbox isn't on its test-user list. In the Google Cloud console, under Google Auth platform, either add this mailbox as a test user (logins then expire after 7 days while it stays in Testing), or make the project Internal under the Workspace account. Then say \"connect my calendar\" again."
            else
                "\n\nSay \"connect my calendar\" for a fresh link when that's sorted.";
            return std.fmt.allocPrint(arena, "Google refused the login -- {s}{s}", .{ reason, testing_hint });
        }

        gcal.finishLogin(self.cfg.io, self.cfg.gpa, calendar, &login.verifier, pasted) catch |err| switch (err) {
            error.NoCode => return "That doesn't carry a login code. Paste the whole address the browser landed on (it starts with http://127.0.0.1), or say \"connect my calendar\" for a fresh link.",
            error.NoRefreshToken => {
                self.pending_login = null;
                return "Google logged me in but only for an hour, with nothing to renew it. Remove Ronny at https://myaccount.google.com/permissions and say \"connect my calendar\" again.";
            },
            else => {
                log.err("calendar login failed: {s}", .{@errorName(err)});
                return "Google didn't accept that -- codes only work once and expire in minutes. Say \"connect my calendar\" for a fresh link.";
            },
        };
        self.pending_login = null;

        if (self.freshPendingEvent()) |event| {
            if (event.day != null) {
                return std.fmt.allocPrint(arena, "Connected to your calendar. \"{s}\" is still waiting -- type yes to add it.", .{event.title});
            }
        }
        return "Connected to your calendar. Try \"dentist tomorrow at 10\".";
    }

    /// Reads the appointment out of `text`, asks the local model for a
    /// title, and holds it for a yes. A missing day is asked for; the next
    /// message is then tried as the answer.
    fn doCreateEvent(self: *Bot, arena: std.mem.Allocator, text: []const u8) ![]const u8 {
        if (self.cfg.calendar == null) return NOT_SET_UP;

        const found = try appointment.find(arena, dates.today(), text);
        const info = try appointment.details(
            self.cfg.io,
            arena,
            self.cfg.ollama_url,
            self.cfg.ollama_model,
            text,
            found.rest,
        );
        try self.stageEvent(info.title, info.location, if (found.when) |w| w.day else null, found.start, found.end);

        if (found.when == null) {
            log.info("calendar entry \"{s}\" has no day yet; asking", .{info.title});
            return std.fmt.allocPrint(
                arena,
                "\"{s}\" -- which day? Tell me the day (and the time if there is one), like \"tomorrow at 3pm\" or \"24 October\".",
                .{info.title},
            );
        }
        return self.eventPreview(arena);
    }

    /// Tries `text` as the day (and time) the pending entry was missing.
    /// Null when it names neither, so the message is handled as a new
    /// request instead.
    fn fillEventWhen(self: *Bot, arena: std.mem.Allocator, text: []const u8) !?[]const u8 {
        const event = &self.pending_event.?;
        const found = try appointment.find(arena, dates.today(), text);
        if (found.when) |when| {
            event.day = when.day;
            if (when.start != null) {
                event.start = when.start;
                event.end = when.end;
            }
            log.info("calendar entry \"{s}\" got its day from a follow-up", .{event.title});
            return try self.eventPreview(arena);
        }
        if (found.start) |start| {
            event.start = start;
            event.end = found.end;
            return "Got the time -- and which day?";
        }
        return null;
    }

    /// Holds an entry for approval. Allocations finish before the arena is
    /// moved into place; see the note on `remember`.
    fn stageEvent(
        self: *Bot,
        title: []const u8,
        location: []const u8,
        day: ?dates.Day,
        start: ?i16,
        end: ?i16,
    ) !void {
        var event_arena: std.heap.ArenaAllocator = .init(self.cfg.gpa);
        errdefer event_arena.deinit();
        const alloc = event_arena.allocator();
        const title_copy = try alloc.dupe(u8, title);
        const location_copy = try alloc.dupe(u8, location);

        if (self.pending_event) |*previous| previous.arena.deinit();
        self.pending_event = .{
            .arena = event_arena,
            .title = title_copy,
            .location = location_copy,
            .day = day,
            .start = start,
            .end = end,
            .created_ns = std.Io.Clock.now(.boot, self.cfg.io).nanoseconds,
        };
    }

    /// Everything that will be sent, in the words the owner is approving.
    fn eventPreview(self: *Bot, arena: std.mem.Allocator) ![]const u8 {
        const event = &self.pending_event.?;
        const when = event.when() orelse return "Which day?";
        var out: std.Io.Writer.Allocating = .init(arena);
        try out.writer.print("Add to your calendar?\n\n{s}\n{s}", .{ event.title, try appointment.describe(arena, when) });
        if (event.location.len > 0) try out.writer.print("\n{s}", .{event.location});
        if (self.cfg.calendar) |calendar| {
            if (!gcal.isAuthorized(self.cfg.io, arena, calendar)) {
                try out.writer.writeAll("\n\n" ++ NOT_CONNECTED ++ " The entry will wait.");
            }
        }
        try out.writer.writeAll("\n\nType yes to add it, or no to drop it.");
        log.info("calendar entry \"{s}\" on {s}; awaiting confirmation", .{ event.title, try appointment.describe(arena, when) });
        return out.written();
    }

    fn doAddEvent(self: *Bot, arena: std.mem.Allocator) ![]const u8 {
        const calendar = self.cfg.calendar orelse return NOT_SET_UP;
        const event = &self.pending_event.?;
        const when = event.when() orelse return "Which day?";

        const created = gcal.insert(self.cfg.io, arena, calendar, .{
            .title = event.title,
            .location = event.location,
            .year = when.day.year,
            .month = when.day.month,
            .day = when.day.day,
            .start_minutes = when.start,
            .end_minutes = when.end orelse 0,
        }) catch |err| switch (err) {
            error.NotAuthorized => return NOT_CONNECTED ++ " The entry will wait.",
            error.TokenRevoked => return "Google no longer accepts my calendar login -- say \"connect my calendar\" to log in again; the entry will wait.",
            else => {
                log.err("could not add \"{s}\" to the calendar: {s}", .{ event.title, @errorName(err) });
                // The entry survives a failed request, so yes can be retried.
                return "Adding it failed -- the entry is still here, say yes to try again.";
            },
        };

        log.info("added \"{s}\" to the calendar as {s}", .{ event.title, created.id });
        const reply = try std.fmt.allocPrint(arena, "Added to your calendar: {s}, {s}.\n{s}", .{
            event.title, try appointment.describe(arena, when), created.html_link,
        });
        self.discardPendingEvent();
        return reply;
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

test "an address the owner typed is preferred over anything a model might pick" {
    // Owner input, not model output -- so it is trusted even when the
    // address has never written to this mailbox.
    try std.testing.expectEqualStrings(
        "you@example.com",
        Bot.ownerTypedAddress("you@example.com").?,
    );
    try std.testing.expectEqualStrings(
        "someone@acme.co.uk",
        Bot.ownerTypedAddress("write to someone@acme.co.uk asking for a refund").?,
    );
    try std.testing.expectEqualStrings(
        "bob@acme.com",
        Bot.ownerTypedAddress("email <bob@acme.com>, thanks").?,
    );

    // Nothing address-shaped means fall through to the contact book.
    try std.testing.expectEqual(@as(?[]const u8, null), Bot.ownerTypedAddress("email dana about thursday"));
    try std.testing.expectEqual(@as(?[]const u8, null), Bot.ownerTypedAddress("send it to my accountant"));
}

test "self-reference resolves to the owner rather than the contact book" {
    // The owner's own address is rarely in a list built from people who
    // wrote *to* the mailbox, so this needs handling of its own.
    try std.testing.expect(Bot.refersToSelf("I would like to send an email to myself with an attachment"));
    try std.testing.expect(Bot.refersToSelf("mail it to my own address"));
    try std.testing.expect(Bot.refersToSelf("MYSELF"));

    // "me" alone is far too common to treat as self-addressing -- it appears
    // in "send me the invoice", which is an attachment download.
    try std.testing.expect(!Bot.refersToSelf("send me the invoice from that email"));
    try std.testing.expect(!Bot.refersToSelf("email dana about thursday"));
}

test "a mis-transcribed address is still address-shaped, which is why voice cannot supply one" {
    // All three came out of whisper on one real address in one sitting.
    // Every one passes the form check, and one of them is a real stranger's
    // mailbox. Shape is not meaning, so spoken requests resolve against the
    // contact book instead of being taken literally.
    try std.testing.expectEqualStrings("name@example.com", Bot.ownerTypedAddress("email you name@example.com").?);
    try std.testing.expectEqualStrings("you.name@example.com", Bot.ownerTypedAddress("email you.name@example.com").?);
    try std.testing.expectEqualStrings("youname@example.com", Bot.ownerTypedAddress("email youname@example.com").?);
}

test "an attachment request is recognised from the owner's own words" {
    // Deterministic on purpose: whether a file was *asked for* is plain in
    // the wording. Which file is meant is the judgement, and that goes to
    // the local model.
    try std.testing.expect(Bot.mentionsAttaching("compose an email attaching this last invoice"));
    try std.testing.expect(Bot.mentionsAttaching("reply and attach the pdf"));
    try std.testing.expect(Bot.mentionsAttaching("send it with the invoice attached"));
    try std.testing.expect(Bot.mentionsAttaching("enclose the spreadsheet"));

    // No file mentioned: nothing should be pulled off the open message.
    try std.testing.expect(!Bot.mentionsAttaching("say I'll meet you at 5 tomorrow"));
    try std.testing.expect(!Bot.mentionsAttaching("reply saying Wednesday works"));
}

test "a pronoun means the message already open, not a fresh fetch" {
    // "Summarize it" after reading something must summarise *that* message.
    // Treating it as sender-less fetches the newest mail from anyone and
    // summarises something never asked about -- worse than refusing,
    // because it looks like it worked.
    try std.testing.expect(Bot.refersToOpenMessage("Summarize it"));
    try std.testing.expect(Bot.refersToOpenMessage("show me the content of this email"));
    try std.testing.expect(Bot.refersToOpenMessage("what does that one say?"));

    // A fresh request names no pronoun and should go to the server.
    try std.testing.expect(!Bot.refersToOpenMessage("show me the latest email"));
    try std.testing.expect(!Bot.refersToOpenMessage("read the last email from sam"));
}

test "a target is trimmed to something a mail server can match" {
    // Observed live: the extractor correctly returned the sender as written,
    // and as written it was a description. IMAP matches substrings of the
    // From header, so the name alone hits and the whole phrase does not.
    try std.testing.expectEqualStrings("Chas", Bot.tidyTarget("Chas from Fleet DM"));
    try std.testing.expectEqualStrings("Mike", Bot.tidyTarget("Mike from Fleet DM"));
    try std.testing.expectEqualStrings("Sam", Bot.tidyTarget("Sam at example.com"));

    // Plain names, addresses and domains pass through untouched.
    try std.testing.expectEqualStrings("Vicente Ferrer", Bot.tidyTarget("Vicente Ferrer"));
    try std.testing.expectEqualStrings("sam@example.com", Bot.tidyTarget("sam@example.com"));
    try std.testing.expectEqualStrings("omarchy.org", Bot.tidyTarget("omarchy.org."));
}

test "a spoken settings change is read back as the value that would be stored" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // This read-back is the whole guard. Whisper hearing "nine" for "eight"
    // is invisible in the transcript -- both are plausible sentences -- but
    // wrong in the parsed window, which is what gets shown here.
    const heard = settings_mod.parseChange("don't notify me before 8am", .{}, &.{}).?;
    const misheard = settings_mod.parseChange("don't notify me before 9am", .{}, &.{}).?;

    try std.testing.expectEqualStrings(
        "That sets quiet hours to 22:00-08:00.",
        try Bot.describeChange(arena, heard),
    );
    try std.testing.expectEqualStrings(
        "That sets quiet hours to 22:00-09:00.",
        try Bot.describeChange(arena, misheard),
    );

    try std.testing.expectEqualStrings(
        "That sets the default look-back to 30 day(s).",
        try Bot.describeChange(arena, settings_mod.parseChange("look back 30 days", .{}, &.{}).?),
    );
    try std.testing.expectEqualStrings(
        "That turns quiet hours off -- I'd notify you whenever mail arrives.",
        try Bot.describeChange(arena, settings_mod.parseChange("turn off quiet hours", .{}, &.{}).?),
    );
}

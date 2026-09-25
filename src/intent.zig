//! Turning a chat message into one of Ronny's fixed actions.
//!
//! Port of `ronny/intent.py`, including the hard-won parts:
//!
//! - Jev (TypeSafe) picks the action and returns a probability distribution,
//!   so an unclear or out-of-scope request becomes `unknown` rather than a
//!   confident wrong answer. Three real misroutes drove this: "show me the
//!   content of..." answered with subject lines, "summarise this last email"
//!   doing nothing, and "send me an email saying..." becoming add_sender with
//!   a junk target that reached the live allowlist.
//!
//! - Confidence is a floor, not a gate. It measures how *concentrated* the
//!   distribution is, not whether the answer is right. "Give me the last email
//!   from X" splits between read_mail and search_mail because both are fair
//!   readings, and a flat 0.55 threshold rejected it twice at 0.51 and 0.54.
//!   Fallback now keys on Jev's own `unknown` probability. Conversation
//!   history makes this worse -- the same sentence scores 0.93 alone and 0.73
//!   with history -- so any threshold-based gate degrades as a chat runs on.
//!
//! - There is deliberately **no send action**. Drafting is model-reachable;
//!   sending is not. The only path to sending mail is the owner confirming.
//!
//! Only the chat command is sent to TypeSafe from *this* module -- never
//! email content. The spam gate, summarisation and drafting stay on local
//! Ollama for that reason. The one exception in Ronny is search ranking,
//! which sends message excerpts to TypeSafe when the owner sets
//! TYPESAFE_RANK_MAIL; see rerank.zig, and note it is off by default.

const std = @import("std");
const http = @import("http.zig");

const log = std.log.scoped(.intent);

pub const Action = enum {
    add_sender,
    remove_sender,
    pause,
    resume_,
    status,
    list_senders,
    search_mail,
    recent_mail,
    find_mail,
    read_mail,
    summarize_mail,
    draft_reply,
    compose_mail,
    list_attachments,
    get_attachment,
    show_settings,
    change_setting,
    help,
    unknown,

    /// `resume` is a Zig keyword, so the enum field is spelled with a
    /// trailing underscore while the wire name stays "resume".
    pub fn wireName(self: Action) []const u8 {
        return if (self == .resume_) "resume" else @tagName(self);
    }

    pub fn fromWire(name: []const u8) Action {
        if (std.mem.eql(u8, name, "resume")) return .resume_;
        inline for (@typeInfo(Action).@"enum".fields) |field| {
            if (std.mem.eql(u8, name, field.name)) return @field(Action, field.name);
        }
        return .unknown;
    }

    /// Actions needing no free-text argument. When Jev picks one of these the
    /// Ollama argument-extraction call is skipped entirely.
    pub fn isArgless(self: Action) bool {
        return switch (self) {
            .pause,
            .resume_,
            .status,
            .list_senders,
            .find_mail,
            .list_attachments,
            // Which attachment is chosen by matching the owner's own words
            // against the real filenames, so there is nothing for a
            // general-purpose extractor to pull out first.
            .get_attachment,
            .show_settings,
            // The new value is read out of the owner's own words by
            // settings.parseChange, so there is nothing for a general-purpose
            // extractor to pull out first -- and a model must never be the
            // thing that decides when the mailbox goes silent.
            .change_setting,
            .help,
            .unknown,
            => true,
            else => false,
        };
    }
};

/// Above this, Jev is genuinely saying it does not recognise the request, as
/// opposed to being split between valid options.
pub const UNKNOWN_PROBABILITY_LIMIT = 0.25;
/// A hard floor only, for a genuinely flat distribution.
pub const DEFAULT_MIN_CONFIDENCE = 0.30;

pub const Decision = struct {
    action: Action,
    confidence: f64,
    unknown_probability: f64,
};

/// Applies the fallback rule. Kept separate from the network call so the
/// logic that actually burned us is unit-testable without TypeSafe.
pub fn resolve(decision: Decision, min_confidence: f64) Action {
    if (decision.action == .unknown) return .unknown;
    if (decision.unknown_probability >= UNKNOWN_PROBABILITY_LIMIT) return .unknown;
    if (decision.confidence < min_confidence) return .unknown;
    return decision.action;
}

const ChoiceAnswer = struct {
    choice: []const u8 = "",
    confidence: f64 = 0,
    probabilities: std.json.ArrayHashMap(f64) = .{},
};

const SystemOneResponse = struct {
    answers: std.json.ArrayHashMap(ChoiceAnswer) = .{},
};

/// Descriptions are sent alongside the option names, so they are written to
/// separate the options from each other. The mail actions carry the most
/// detail because they were the ones actually confused in use.
const ACTION_CRITERIA =
    \\{
    \\  "search_mail": "List SEVERAL messages from a NAMED SENDER -- dates and subjects, not content. Not for a request wanting one message, which is read_mail. The request identifies a person or domain, not a topic and not merely a time. If no sender is named, prefer recent_mail. Examples: 'any mail from acme.com?', 'did she email me this week?'",
    \\  "recent_mail": "List SEVERAL messages that arrived recently, with no sender and no topic named -- the request is about *when*, not who or what. Not for a request wanting one message's content, which is read_mail even when no sender is named. Examples: 'what came in this morning', 'any mail today?', 'list the emails from this morning', 'anything new?', 'show me the latest email regardless of who sent it'",
    \\  "find_mail": "Find mail by its TOPIC or CONTENT -- what a message is about, or something someone said in it, when no sender is named. Examples: 'find the email about the pricing discussion', 'where did someone mention the Thursday deadline?'",
    \\  "read_mail": "Show the actual body text of ONE email -- the most recent, whether or not a sender is named. Use this whenever the request is for a single message's content, including 'just the latest one' or 'the last email, whoever sent it'. Examples: 'show me the content of the latest email from acme.com', 'what does his last email say?'",
    \\  "summarize_mail": "Summarize the most recent email from someone rather than showing it in full. Examples: 'summarise the last email from acme.com', 'give me the gist of it', 'tl;dr'",
    \\  "draft_reply": "Draft a reply to the email just shown, for the owner to approve. Drafting only; it never sends. Examples: 'reply saying Wednesday works'",
    \\  "compose_mail": "Start a NEW email to someone, not a reply to anything. The recipient is named or described. Drafting only; it never sends. Examples: 'email dana about thursday', 'send sam the notes', 'write to support@acme.com asking for a refund'",
    \\  "list_attachments": "Say what files are attached to the email just shown, without sending any of them. Examples: 'does that have attachments?', 'what is attached to it?', 'any files on that one?'",
    \\  "get_attachment": "Send the owner a file attached to the email just shown. Examples: 'send me the invoice', 'download the pdf', 'give me that attachment', 'forward me the spreadsheet from it'",
    \\  "add_sender": "Add an email address or domain to the watched-sender allowlist, so that mail arriving from it is notified. The request names the address or the person. Examples: 'add example@example.com to be notified', 'watch acme.com', 'let me know when anna@acme.com writes'",
    \\  "remove_sender": "Remove an email address or domain from the watched-sender allowlist.",
    \\  "list_senders": "Show which PEOPLE the assistant watches -- the sender allowlist. About addresses and domains, never about what the assistant can do. Examples: 'who are you watching?', 'what are you watching?', 'which senders are you monitoring?', 'list the senders', 'show me the allowlist'",
    \\  "pause": "Stop sending notifications entirely, for now, until told to resume. Not for silencing only certain hours of the day, which is change_setting.",
    \\  "resume": "Start sending notifications again after a pause.",
    \\  "status": "Report the assistant's own state: active or paused, and how many senders it watches. Not about mail content, and not its configurable settings, which is show_settings.",
    \\  "show_settings": "Show the assistant's own configuration -- its quiet hours, and how far back mail commands look by default. Examples: 'what are your settings?', 'what are my quiet hours?', 'how far back do you search?'",
    \\  "change_setting": "Change one of the assistant's own settings: the hours during which it must not notify, or the default number of days the mail commands look back. The request is about the assistant's behaviour, NOT about which senders it watches (add_sender/remove_sender) and NOT about stopping notifications altogether (pause). Examples: 'don't notify me before 8am', 'no notifications between 10pm and 7am', 'turn off quiet hours', 'look back 30 days by default'",
    \\  "help": "List what the assistant itself can DO -- its actions, commands or capabilities. Note 'list of actions' and 'list of commands' are this, not the sender list. Examples: 'what can you do?', 'show me the list of actions', 'which commands do you have?', 'help'",
    \\  "unknown": "None of the other options fit, or the request is something this assistant cannot do at all -- forwarding a message on to a third party, deleting or filing mail, calendars, contacts, or anything unrelated to this mailbox."
    \\}
;

const INSTRUCTIONS =
    "An assistant watches its owner's email inbox and is controlled by chat. " ++
    "Which single action is the owner's newest message asking for? " ++
    "Use `recent_conversation` only to resolve a follow-up that refers back to it. " ++
    "If the request is not clearly one of these actions, or is something the " ++
    "assistant cannot do, choose unknown rather than the closest-looking option.";

pub const Error = error{ Unavailable, BadResponse };

/// One past exchange. History resolves follow-ups ("what about last month
/// instead") against the previous turn, and nothing else -- the instructions
/// say to classify only the newest message.
pub const Turn = struct {
    owner: []const u8,
    assistant: []const u8,
};

/// Asks Jev which action the message means.
///
/// Returns Error.Unavailable when TypeSafe cannot be reached, so the caller
/// can fall back to the local model rather than the bot going down.
pub fn classify(
    io: std.Io,
    gpa: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    message: []const u8,
    history: []const Turn,
) Error!Decision {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = buildRequest(arena, model, message, history) catch return Error.Unavailable;

    const auth = std.fmt.allocPrint(arena, "Bearer {s}", .{api_key}) catch return Error.Unavailable;
    var response = http.postJson(
        io,
        arena,
        "https://api.typesafe.ai/v1/systemone",
        body,
        &.{.{ .name = "Authorization", .value = auth }},
    ) catch return Error.Unavailable;
    defer response.deinit(arena);

    if (!response.ok()) {
        log.warn("TypeSafe returned {d}; falling back to the local model", .{@intFromEnum(response.status)});
        return Error.Unavailable;
    }

    const parsed = std.json.parseFromSlice(SystemOneResponse, arena, response.body, .{
        .ignore_unknown_fields = true,
    }) catch return Error.BadResponse;
    defer parsed.deinit();

    const answer = parsed.value.answers.map.get("action") orelse return Error.BadResponse;
    return .{
        .action = Action.fromWire(answer.choice),
        .confidence = answer.confidence,
        .unknown_probability = answer.probabilities.map.get("unknown") orelse 0,
    };
}

fn buildRequest(
    arena: std.mem.Allocator,
    model: []const u8,
    message: []const u8,
    history: []const Turn,
) ![]u8 {
    // The criteria are a literal JSON object, so the request is assembled as
    // text rather than through a Zig struct -- a struct would need a field
    // per action and duplicate the descriptions.
    // With no history the field is left out entirely rather than sent empty,
    // so a fresh conversation asks exactly the one-shot question.
    var state: std.Io.Writer.Allocating = .init(arena);
    if (history.len == 0) {
        try std.json.Stringify.value(.{ .newest_message = message }, .{}, &state.writer);
    } else {
        try std.json.Stringify.value(.{
            .newest_message = message,
            .recent_conversation = history,
        }, .{}, &state.writer);
    }

    var instructions: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(INSTRUCTIONS, .{}, &instructions.writer);

    return std.fmt.allocPrint(arena,
        \\{{"state":{s},"model":"{s}","questions":{{"action":{{"type":"choice","instructions":{s},"criteria":{s}}}}}}}
    , .{ state.writer.buffered(), model, instructions.writer.buffered(), ACTION_CRITERIA });
}

test "resolve keeps a confident answer" {
    const action = resolve(.{ .action = .read_mail, .confidence = 0.99, .unknown_probability = 0.0 }, DEFAULT_MIN_CONFIDENCE);
    try std.testing.expectEqual(Action.read_mail, action);
}

test "resolve accepts a split between two valid actions" {
    // The real failure: "Give me the last email from 1Password" scored 0.51
    // and 0.54 because read_mail and search_mail are both fair readings, and
    // a flat threshold rejected it twice.
    try std.testing.expectEqual(Action.read_mail, resolve(
        .{ .action = .read_mail, .confidence = 0.51, .unknown_probability = 0.0 },
        DEFAULT_MIN_CONFIDENCE,
    ));
    try std.testing.expectEqual(Action.read_mail, resolve(
        .{ .action = .read_mail, .confidence = 0.54, .unknown_probability = 0.01 },
        DEFAULT_MIN_CONFIDENCE,
    ));
}

test "resolve defers when Jev itself signals unknown" {
    try std.testing.expectEqual(Action.unknown, resolve(
        .{ .action = .unknown, .confidence = 1.0, .unknown_probability = 1.0 },
        DEFAULT_MIN_CONFIDENCE,
    ));
    // Top choice is an action, but unknown carries real weight.
    try std.testing.expectEqual(Action.unknown, resolve(
        .{ .action = .draft_reply, .confidence = 0.4, .unknown_probability = 0.35 },
        DEFAULT_MIN_CONFIDENCE,
    ));
}

test "resolve defers on a genuinely flat distribution" {
    try std.testing.expectEqual(Action.unknown, resolve(
        .{ .action = .search_mail, .confidence = 0.12, .unknown_probability = 0.05 },
        DEFAULT_MIN_CONFIDENCE,
    ));
}

test "action wire names round-trip, including the resume keyword clash" {
    try std.testing.expectEqualStrings("resume", Action.resume_.wireName());
    try std.testing.expectEqual(Action.resume_, Action.fromWire("resume"));
    try std.testing.expectEqual(Action.summarize_mail, Action.fromWire("summarize_mail"));
    try std.testing.expectEqual(Action.unknown, Action.fromWire("not_a_real_action"));
}

test "argless actions skip argument extraction" {
    try std.testing.expect(Action.status.isArgless());
    try std.testing.expect(Action.find_mail.isArgless());
    try std.testing.expect(!Action.read_mail.isArgless());
    try std.testing.expect(!Action.draft_reply.isArgless());

    // A settings change must never take its value from the model: the whole
    // request goes to settings.parseChange instead.
    try std.testing.expect(Action.show_settings.isArgless());
    try std.testing.expect(Action.change_setting.isArgless());
}

test "every action Jev can choose is one the criteria describe" {
    // The criteria are hand-written JSON, so an action added to the enum and
    // forgotten there would simply never be picked -- silently, and only in
    // production.
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        const action = @field(Action, field.name);
        const quoted = "\"" ++ (if (action == .resume_) "resume" else field.name) ++ "\":";
        if (std.mem.indexOf(u8, ACTION_CRITERIA, quoted) == null) {
            std.debug.print("action {s} is missing from ACTION_CRITERIA\n", .{field.name});
            return error.ActionNotDescribed;
        }
    }
}

//! Turning a chat message into an action *and its arguments*.
//!
//! Port of `interpret()` in `ronny/intent.py`. Two backends, and the split
//! between them is the point:
//!
//! - **Jev picks the action** (intent.zig). Choice is for closed sets, and it
//!   returns a distribution, so an out-of-scope request becomes `unknown`
//!   rather than the nearest-looking action.
//! - **Ollama extracts the arguments** -- which address, how many days, what
//!   the reply should say. A closed-set Choice cannot produce free text.
//!
//! Actions that take no argument skip the second call entirely, and if
//! TypeSafe is unset or unreachable the Ollama call does both jobs, so the bot
//! keeps working without it.

const std = @import("std");
const ollama = @import("ollama.zig");
const intent = @import("intent.zig");

const log = std.log.scoped(.interpret);

pub const Action = intent.Action;
pub const Turn = intent.Turn;

pub const Error = error{Unavailable};

/// Arguments are owned by the arena passed to `interpret`.
pub const Intent = struct {
    action: Action,
    target: ?[]const u8 = null,
    days: ?u16 = null,
    message: ?[]const u8 = null,
    /// A one-line acknowledgement of what was understood. The caller executes
    /// the action separately -- this never describes what happened.
    reply: []const u8 = "Got it.",
};

pub const DEFAULT_DAYS = 14;

const SYSTEM_PROMPT =
    \\You translate a user's chat message into exactly one action for an email-notification bot called Ronny. Respond with ONLY a JSON object of this exact shape:
    \\{"action": "<one of: add_sender, remove_sender, pause, resume, status, list_senders, search_mail, find_mail, read_mail, summarize_mail, draft_reply, help, unknown>", "target": "<email address or bare domain, for add_sender/remove_sender/search_mail/read_mail/summarize_mail, else null>", "days": <integer days to look back for the mail actions -- e.g. 1 for "today", 7 for "this week", 30 for "this month"; use 14 if not specified>, "message": "<for draft_reply only: what the user wants the reply to say, in their words; else null>", "reply": "<a short, friendly one-sentence acknowledgement of what you understood>"}
    \\
    \\Rules:
    \\- add_sender / remove_sender / search_mail / read_mail / summarize_mail require a "target" that looks like an email address or a bare domain. If the message doesn't clearly give one AND the recent conversation doesn't make one obvious either, use action "unknown".
    \\- The mail actions are distinct, pick carefully:
    \\  - search_mail = "is there mail from X?", "did X email me this week?" -> dates and subjects only.
    \\  - find_mail = "find the email about the pricing discussion" -> searches by topic, no sender named.
    \\  - read_mail = "show me the content of the latest email from X" -> the actual body text.
    \\  - summarize_mail = "summarise the last email from X", "tl;dr" -> a summary of the body.
    \\  Asking to SEE or READ content is read_mail, not search_mail. Asking to SUMMARISE is summarize_mail, not read_mail.
    \\- None of the mail actions are the same as status, which is about Ronny's own watching/paused state, not mail content.
    \\- You may be given recent conversation turns. Use them ONLY to resolve a clear follow-up. Classify only the newest message; the history is context, not something to re-answer.
    \\- Use "unknown" whenever the message isn't clearly one of these actions. Never guess a target that wasn't in the message or a resolvable prior turn, and never force an out-of-scope request into the closest action.
    \\- draft_reply = "reply to that saying X", "answer him that X". Put the user's intended message in "message". It only DRAFTS a reply for the user to approve -- you are never sending anything. If no message content is given, still use draft_reply with "message" null.
    \\- Ronny CANNOT compose new email to arbitrary people, forward, delete or label email, and cannot touch calendars or contacts. Any such request is "unknown", never the nearest-looking action. draft_reply only replies to a message already shown, so "email Bob about X" is "unknown".
    \\- "target" must be an actual address or domain from the message, or JSON null. Never the string "null", never a placeholder, never a person's first name alone.
    \\- "reply" describes what you understood, not what happened.
;

/// Models sometimes emit the *string* "null" instead of JSON null. Taking one
/// literally is how a sender called "null" once reached the live allowlist.
const NULLISH = [_][]const u8{ "null", "none", "nil", "n/a", "na", "undefined", "-" };

fn cleanText(value: ?std.json.Value) ?[]const u8 {
    const raw = switch (value orelse return null) {
        .string => |s| s,
        else => return null,
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    for (NULLISH) |nullish| {
        if (std.ascii.eqlIgnoreCase(trimmed, nullish)) return null;
    }
    return trimmed;
}

fn cleanDays(value: ?std.json.Value) ?u16 {
    return switch (value orelse return null) {
        .integer => |n| if (n > 0 and n <= 3650) @intCast(n) else null,
        .float => |f| if (f > 0 and f <= 3650) @intFromFloat(f) else null,
        // Some models quote the number.
        .string => |s| std.fmt.parseInt(u16, std.mem.trim(u8, s, " \t\r\n"), 10) catch null,
        else => null,
    };
}

/// The full local path: action *and* arguments from one Ollama call. Used
/// both as the fallback classifier and, after Jev has chosen, for arguments
/// alone -- the action it returns is simply ignored in that case.
fn askOllama(
    io: std.Io,
    arena: std.mem.Allocator,
    ollama_url: []const u8,
    model: []const u8,
    message: []const u8,
    history: []const Turn,
) Error!Intent {
    var prompt: std.Io.Writer.Allocating = .init(arena);
    prompt.writer.writeAll(SYSTEM_PROMPT) catch return Error.Unavailable;
    if (history.len > 0) {
        prompt.writer.writeAll(
            "\n\nRecent conversation (oldest first, context only -- classify only the newest message below):\n",
        ) catch return Error.Unavailable;
        for (history) |turn| {
            prompt.writer.print("User: {s}\nRonny: {s}\n", .{ turn.owner, turn.assistant }) catch
                return Error.Unavailable;
        }
    }
    prompt.writer.print("\nNewest user message: {s}", .{message}) catch return Error.Unavailable;

    // Parsed loosely: a model that returns a number where a string belongs
    // should cost one field, not the whole interpretation.
    const answer = try ollama.generateJson(io, arena, ollama_url, model, prompt.writer.buffered());
    const object = switch (answer) {
        .object => |o| o,
        else => return Error.Unavailable,
    };

    const action_name = cleanText(object.get("action")) orelse "unknown";
    return .{
        .action = Action.fromWire(action_name),
        .target = cleanText(object.get("target")),
        .days = cleanDays(object.get("days")),
        .message = cleanText(object.get("message")),
        .reply = cleanText(object.get("reply")) orelse "Got it.",
    };
}

/// Interprets one chat message. The result borrows from `arena`.
pub fn interpret(
    io: std.Io,
    arena: std.mem.Allocator,
    ollama_url: []const u8,
    ollama_model: []const u8,
    typesafe_api_key: []const u8,
    jev_model: []const u8,
    message: []const u8,
    history: []const Turn,
) Error!Intent {
    if (typesafe_api_key.len == 0) return askOllama(io, arena, ollama_url, ollama_model, message, history);

    const decision = intent.classify(io, arena, typesafe_api_key, jev_model, message, history) catch |err| {
        log.warn("Jev unavailable ({s}); using the local classifier", .{@errorName(err)});
        return askOllama(io, arena, ollama_url, ollama_model, message, history);
    };

    const action = intent.resolve(decision, intent.DEFAULT_MIN_CONFIDENCE);
    log.info("Jev chose action={s} confidence={d:.2} unknown={d:.2} -> {s}", .{
        decision.action.wireName(), decision.confidence, decision.unknown_probability, action.wireName(),
    });

    if (action.isArgless()) return .{ .action = action };

    // Jev owns the action; Ollama only fills in what a closed-set Choice
    // cannot produce. If it is down, the action still stands -- the caller
    // asks which address it should use.
    const args = askOllama(io, arena, ollama_url, ollama_model, message, history) catch {
        return .{ .action = action };
    };
    return .{
        .action = action,
        .target = args.target,
        .days = args.days,
        .message = args.message,
        .reply = args.reply,
    };
}

test "cleanText rejects the placeholders a model actually emits" {
    const gpa = std.testing.allocator;

    // The exact value that once reached the live allowlist.
    const nulls = [_][]const u8{ "\"null\"", "\"none\"", "\"  \"", "\"N/A\"", "null", "42" };
    for (nulls) |text| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, text, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(?[]const u8, null), cleanText(parsed.value));
    }

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, "\"  someone@example.com \"", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("someone@example.com", cleanText(parsed.value).?);
}

test "cleanDays tolerates a quoted number and rejects nonsense" {
    const gpa = std.testing.allocator;

    const cases = [_]struct { json: []const u8, want: ?u16 }{
        .{ .json = "7", .want = 7 },
        .{ .json = "\"30\"", .want = 30 },
        .{ .json = "14.0", .want = 14 },
        .{ .json = "0", .want = null },
        .{ .json = "-3", .want = null },
        .{ .json = "\"soon\"", .want = null },
        .{ .json = "null", .want = null },
    };
    for (cases) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.want, cleanDays(parsed.value));
    }
}

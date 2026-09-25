//! Prose generation over email: summaries and reply drafts.
//!
//! Port of `ronny/summarize.py`. Runs on local Ollama, not a hosted model,
//! because both of these read message bodies -- the same boundary as the spam
//! gate. Unlike intent classification these ask for prose, so no JSON format
//! constraint is set.
//!
//! Reply drafts are always shown to the owner for approval before anything is
//! sent; see decision.zig for the gate itself.

const std = @import("std");
const ollama = @import("ollama.zig");
const settings = @import("settings.zig");

const log = std.log.scoped(.summarize);

pub const Error = error{Unavailable};

/// Caller owns the returned text.
fn generate(
    io: std.Io,
    gpa: std.mem.Allocator,
    ollama_url: []const u8,
    model: []const u8,
    prompt: []const u8,
) Error![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try ollama.generate(io, arena, ollama_url, model, prompt, .text);
    return gpa.dupe(u8, text) catch Error.Unavailable;
}

pub fn summarize(
    io: std.Io,
    gpa: std.mem.Allocator,
    ollama_url: []const u8,
    model: []const u8,
    language: settings.Language,
    sender: []const u8,
    subject: []const u8,
    body: []const u8,
) Error![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The language is named explicitly even for English: a local model
    // otherwise tends to answer in the email's language, and a summary the
    // owner may hear read by an English voice must be in English.
    const prompt = std.fmt.allocPrint(arena,
        \\Summarize this email in at most 3 short sentences, written in {s}. State what it is about and anything the recipient is being asked to do. Plain text only, no preamble, no markdown.
        \\
        \\From: {s}
        \\Subject: {s}
        \\
        \\{s}
    , .{ language.name(), sender, subject, body[0..@min(body.len, 4000)] }) catch return Error.Unavailable;

    return generate(io, gpa, ollama_url, model, prompt);
}

/// Below this, a body is already shorter than any summary of it would be, so
/// the notification carries the text itself instead of asking the model to
/// restate it. Not a tuned figure -- roughly a phone screen of text -- but it
/// keeps "Thanks, see you Tuesday" from becoming three sentences of summary,
/// and saves an Ollama call on the short mail that makes up most of a day.
pub const SHORT_BODY_CHARS = 300;

/// Collapses the blank-line padding that automated mail is full of.
///
/// The verbatim path shows a short body as-is, and a real one looked like
/// this in Telegram: a line of text, three blank lines, a row of "=", two
/// more blanks, "OK". Honest, but most of the notification was whitespace.
/// Runs of blank lines become one, and trailing spaces go; nothing is
/// removed, so the text still says what the email said.
///
/// Caller owns the result.
fn tidy(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    var blank_run: usize = 0;
    var wrote_any = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) {
            blank_run += 1;
            continue;
        }
        if (wrote_any) try out.writer.writeAll(if (blank_run > 0) "\n\n" else "\n");
        blank_run = 0;
        try out.writer.writeAll(line);
        wrote_any = true;
    }
    return out.toOwnedSlice();
}

/// What goes under the sender and subject in a notification: a summary, the
/// text itself when it is short enough not to need one, or nothing at all.
///
/// Returns null rather than an error. A summary improves a notification; it
/// is never a precondition for one -- the same reasoning as the spam gate
/// failing open. Ollama being slow or down must not cost the owner the mail
/// itself, which is the whole point of the service.
///
/// Caller frees a non-null result.
pub fn forNotification(
    io: std.Io,
    gpa: std.mem.Allocator,
    ollama_url: []const u8,
    model: []const u8,
    language: settings.Language,
    sender: []const u8,
    subject: []const u8,
    body: []const u8,
) ?[]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (trimmed.len <= SHORT_BODY_CHARS) {
        return tidy(gpa, trimmed) catch null;
    }

    return summarize(io, gpa, ollama_url, model, language, sender, subject, trimmed) catch |err| {
        log.warn("no summary for mail from {s}: {s}", .{ sender, @errorName(err) });
        return null;
    };
}

pub const Draft = struct {
    subject: []const u8,
    body: []const u8,
};

/// Drafts a brand-new email from an instruction. Owner-reviewed, like a reply.
///
/// The same prohibition applies and matters more here: with no original
/// message to anchor it, a model asked to "write an email" will happily invent
/// a meeting, a price, or an apology on the owner's behalf. Everything returned
/// is shown before anything is sent.
pub fn draftNew(
    io: std.Io,
    arena: std.mem.Allocator,
    ollama_url: []const u8,
    model: []const u8,
    recipient: []const u8,
    instruction: []const u8,
) Error!Draft {
    const prompt = std.fmt.allocPrint(arena,
        \\Write a short, plain email. Say only what the instruction asks; do not invent commitments, dates, prices, apologies or facts that aren't in the instruction. Sign off simply and do not invent a signature block.
        \\
        \\Recipient: {s}
        \\The email should say: {s}
        \\
        \\Reply with ONLY JSON: {{"subject": "<short subject line>", "body": "<the email body>"}}
    , .{ recipient, instruction }) catch return Error.Unavailable;

    const answer = @import("ollama.zig").generateJson(io, arena, ollama_url, model, prompt) catch
        return Error.Unavailable;
    const parsed = std.json.parseFromValue(Draft, arena, answer, .{
        .ignore_unknown_fields = true,
    }) catch return Error.Unavailable;

    const subject = std.mem.trim(u8, parsed.value.subject, " \t\r\n");
    const body = std.mem.trim(u8, parsed.value.body, " \t\r\n");
    if (body.len == 0) return Error.Unavailable;

    return .{
        // A blank subject is worth filling in; a blank body is not worth
        // guessing at, which is why only this one has a fallback.
        .subject = if (subject.len == 0) "(no subject)" else subject,
        .body = body,
    };
}

/// Drafts the body of a reply. Always reviewed by the owner before sending.
///
/// The prompt forbids inventing commitments: a drafted reply that quietly
/// agrees to a date or a price would be worse than no draft at all.
pub fn draftReply(
    io: std.Io,
    gpa: std.mem.Allocator,
    ollama_url: []const u8,
    model: []const u8,
    subject: []const u8,
    original_body: []const u8,
    instruction: []const u8,
) Error![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prompt = std.fmt.allocPrint(arena,
        \\Write the body of a short email reply. Say only what the instruction asks; do not invent commitments, dates, prices or facts that aren't in the instruction. No subject line, no markdown, plain text only.
        \\
        \\Original subject: {s}
        \\Original message (for context):
        \\{s}
        \\
        \\The reply should say: {s}
    , .{ subject, original_body[0..@min(original_body.len, 1500)], instruction }) catch return Error.Unavailable;

    return generate(io, gpa, ollama_url, model, prompt) catch |err| {
        // Falling back to the owner's own words beats producing nothing --
        // they review it either way.
        log.warn("drafting failed ({s}); using the instruction verbatim", .{@errorName(err)});
        return gpa.dupe(u8, instruction) catch Error.Unavailable;
    };
}

test "a short body keeps its text and loses its padding" {
    const gpa = std.testing.allocator;

    // Observed in the probe against real mail: an automated upload report
    // whose notification was mostly blank lines and a rule of "=".
    const raw = "Upload process report  \n\n\n===========\n\n\nOK\n\nThanks!\n";
    const tidied = try tidy(gpa, raw);
    defer gpa.free(tidied);
    try std.testing.expectEqualStrings("Upload process report\n\n===========\n\nOK\n\nThanks!", tidied);

    // A single newline stays a single newline -- collapsing those would run
    // separate lines together and change what the message says.
    const listy = try tidy(gpa, "one\ntwo\nthree");
    defer gpa.free(listy);
    try std.testing.expectEqualStrings("one\ntwo\nthree", listy);

    const blank = try tidy(gpa, "\n\n   \n");
    defer gpa.free(blank);
    try std.testing.expectEqualStrings("", blank);
}

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
    sender: []const u8,
    subject: []const u8,
    body: []const u8,
) Error![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const prompt = std.fmt.allocPrint(arena,
        \\Summarize this email in at most 3 short sentences. State what it is about and anything the recipient is being asked to do. Plain text only, no preamble, no markdown.
        \\
        \\From: {s}
        \\Subject: {s}
        \\
        \\{s}
    , .{ sender, subject, body[0..@min(body.len, 4000)] }) catch return Error.Unavailable;

    return generate(io, gpa, ollama_url, model, prompt);
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

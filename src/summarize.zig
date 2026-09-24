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

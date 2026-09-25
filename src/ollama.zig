//! The local model.
//!
//! Everything that reads the owner's email -- the spam gate, summaries, reply
//! drafts, search ranking -- runs through here and never leaves the machine.
//! Only the chat command itself goes to a hosted service (see intent.zig).
//! That boundary is the whole reason a local model is in the stack at all, so
//! it is worth having one door rather than four.

const std = @import("std");
const http = @import("http.zig");

const log = std.log.scoped(.ollama);

pub const Error = error{Unavailable};

/// Ollama's own reply envelope; the model's output is the `response` field.
const Reply = struct { response: []const u8 = "" };

pub const Format = enum {
    /// Prose. Summaries and drafts ask for this.
    text,
    /// Constrained decoding, so the model cannot wander off into prose around
    /// its JSON. Anything Ronny parses asks for this.
    json,
};

/// Runs one prompt. The result borrows from `arena`.
///
/// Every failure -- unreachable host, non-2xx, unparseable body, empty answer
/// -- collapses to Unavailable, because every caller's response is the same:
/// fall back to something that doesn't need the model.
/// Replaces invalid UTF-8 so the prompt survives being turned into JSON.
///
/// Not defensive tidying -- without this the request is silently malformed.
/// Zig 0.16's std.json.Stringify, handed a []u8 that is not valid UTF-8,
/// emits it as an ARRAY OF BYTE NUMBERS rather than a string:
///
///   {"prompt":[72,101,32,115,97,105,100,32,147,...]}
///
/// Ollama then answers 400, and every caller degrades quietly: the spam gate
/// fails open and tags the mail "[spam check unavailable]", the notification
/// loses its summary, content search falls back to recency. Seen live as
/// `ollama returned 400 for model qwen2.5` on a content search.
///
/// The trigger is ordinary: one windows-1252 smart quote or a latin-1 accent
/// in a message body, which a bilingual mailbox sees constantly. The deeper
/// fix is honouring each MIME part's charset when decoding, in shim.c;
/// this is the boundary that stops a bad byte breaking the request at all.
fn validUtf8(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(text)) return text;

    var out: std.Io.Writer.Allocating = .init(arena);
    errdefer out.deinit();

    var i: usize = 0;
    var replaced: usize = 0;
    while (i < text.len) {
        const width = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            try out.writer.writeAll("\u{FFFD}");
            replaced += 1;
            i += 1;
            continue;
        };
        if (i + width > text.len or !std.unicode.utf8ValidateSlice(text[i..][0..width])) {
            try out.writer.writeAll("\u{FFFD}");
            replaced += 1;
            i += 1;
            continue;
        }
        try out.writer.writeAll(text[i..][0..width]);
        i += width;
    }

    log.warn("replaced {d} invalid UTF-8 byte(s) in a prompt", .{replaced});
    return out.writer.buffered();
}

pub fn generate(
    io: std.Io,
    arena: std.mem.Allocator,
    url: []const u8,
    model: []const u8,
    prompt: []const u8,
    format: Format,
) Error![]const u8 {
    var payload: std.Io.Writer.Allocating = .init(arena);
    const stringify_options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    std.json.Stringify.value(.{
        .model = model,
        .prompt = validUtf8(arena, prompt) catch prompt,
        .stream = false,
        .format = if (format == .json) @as(?[]const u8, "json") else null,
    }, stringify_options, &payload.writer) catch return Error.Unavailable;

    const endpoint = std.fmt.allocPrint(arena, "{s}/api/generate", .{url}) catch return Error.Unavailable;
    var response = http.postJson(io, arena, endpoint, payload.writer.buffered(), &.{}) catch
        return Error.Unavailable;
    defer response.deinit(arena);

    if (!response.ok()) {
        log.warn("ollama returned {d} for model {s}", .{ @intFromEnum(response.status), model });
        return Error.Unavailable;
    }

    const parsed = std.json.parseFromSlice(Reply, arena, response.body, .{
        .ignore_unknown_fields = true,
    }) catch return Error.Unavailable;

    const text = std.mem.trim(u8, parsed.value.response, " \t\r\n");
    if (text.len == 0) return Error.Unavailable;

    // Copied, not returned by reference. std.json's default `.alloc_if_needed`
    // leaves unescaped strings pointing into `response.body`, which the defer
    // above frees -- so returning `text` directly hands the caller memory that
    // is already gone. It survived by luck for a while, which is the worst way
    // for this to behave. telegram.zig has the same trap and a test for it.
    return arena.dupe(u8, text) catch Error.Unavailable;
}

/// Runs a prompt whose answer is JSON, and hands back the parsed value.
/// Borrows from `arena`.
pub fn generateJson(
    io: std.Io,
    arena: std.mem.Allocator,
    url: []const u8,
    model: []const u8,
    prompt: []const u8,
) Error!std.json.Value {
    const text = try generate(io, arena, url, model, prompt, .json);
    const parsed = std.json.parseFromSlice(std.json.Value, arena, text, .{}) catch {
        log.warn("model returned something that isn't JSON: {s}", .{text[0..@min(text.len, 120)]});
        return Error.Unavailable;
    };
    return parsed.value;
}

test "a prompt with non-UTF-8 bytes still serialises as a JSON string" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Valid text is passed straight through, same pointer, no copy.
    const clean = "Summarise this: hola, ¿qué tal?";
    try std.testing.expectEqual(clean.ptr, (try validUtf8(arena, clean)).ptr);

    // windows-1252 smart quotes, exactly as they arrive in a mail body.
    const dirty = "He said \x93hello\x94 to me";
    const fixed = try validUtf8(arena, dirty);
    try std.testing.expect(std.unicode.utf8ValidateSlice(fixed));
    try std.testing.expectEqualStrings("He said \u{FFFD}hello\u{FFFD} to me", fixed);

    // The regression itself: the encoded payload must contain a JSON string,
    // not the array of byte numbers Stringify produces for invalid UTF-8.
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{ .prompt = fixed }, .{}, &out.writer);
    const json = out.writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"prompt\":\""));
}

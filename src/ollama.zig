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
        .prompt = prompt,
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
    return text;
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

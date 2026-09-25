//! Ranking search candidates with Jev, when the owner has allowed it.
//!
//! **This is the one place email content leaves the machine**, and it does so
//! only when `TYPESAFE_RANK_MAIL=true`. Everywhere else in Ronny the rule
//! still holds: bodies go to local Ollama, and only chat commands go to
//! TypeSafe. The flag defaults to false so the privacy posture of a fresh
//! checkout is unchanged, and the owner of this instance turned it on
//! deliberately, for ranking quality.
//!
//! Why a different model at all: ranking is the step where the local model
//! was weakest. It reads twenty excerpts and answers with prose-shaped JSON,
//! and a wrong answer there is silent -- "no match" reads exactly like "you
//! have no such email".
//!
//! Why Noul rather than Choice: Choice picks one option from a closed set,
//! but ranking needs a comparable number per candidate. A Noul returns a
//! probability between 0 and 1 for "does this genuinely answer the request",
//! which sorts. This follows TypeSafe's own reranking cookbook, except that
//! it asks every candidate in a single request -- the questions are
//! independent and evaluated in parallel, so twenty of them cost about what
//! one does, where the cookbook's request-per-candidate would be twenty
//! round trips on this synchronous client.

const std = @import("std");
const http = @import("http.zig");
const ollama = @import("ollama.zig");

const log = std.log.scoped(.rerank);

pub const Error = error{ Unavailable, BadResponse };

/// Above this a candidate is worth showing. Below it the model is saying the
/// message merely shares a keyword, which is exactly the noise the ranker
/// exists to remove.
pub const MATCH_THRESHOLD = 0.5;

/// How many candidates fit in one request. Well under any plausible limit,
/// and the candidate list is capped below this anyway.
pub const MAX_QUESTIONS = 24;

const INSTRUCTIONS =
    "The owner is searching their own mailbox. Does this email genuinely answer " ++
    "what they asked for, rather than merely containing one of the same words?";

const TRUE_CRITERIA =
    "The email is about the thing asked for -- it discusses it, reports on it, " ++
    "or is the message the request is describing.";
const FALSE_CRITERIA =
    "The email only mentions the words in passing, or shares a keyword while " ++
    "being about something else: a calendar invitation, a notification, a " ++
    "newsletter, an automated report, or an unrelated thread.";

/// A relevance score in 0..1 for each item, in the order given.
///
/// Items are rendered by the caller, so this module never needs to know what
/// a mail message looks like.
pub fn scores(
    io: std.Io,
    gpa: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,
    question: []const u8,
    items: []const []const u8,
) Error![]f64 {
    if (items.len == 0) return &.{};
    if (items.len > MAX_QUESTIONS) return Error.Unavailable;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = buildRequest(arena, model, question, items) catch return Error.Unavailable;

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
        log.warn("TypeSafe returned {d}; ranking locally instead", .{@intFromEnum(response.status)});
        return Error.Unavailable;
    }

    const parsed = std.json.parseFromSlice(Response, arena, response.body, .{
        .ignore_unknown_fields = true,
    }) catch return Error.BadResponse;
    defer parsed.deinit();

    const out = gpa.alloc(f64, items.len) catch return Error.Unavailable;
    errdefer gpa.free(out);

    var key_buffer: [16]u8 = undefined;
    for (out, 0..) |*slot, i| {
        const key = std.fmt.bufPrint(&key_buffer, "c{d}", .{i}) catch return Error.BadResponse;
        // A missing answer scores zero rather than failing the whole ranking:
        // one unanswered candidate should not cost the owner the other
        // nineteen.
        slot.* = if (parsed.value.answers.map.get(key)) |answer| answer.noul else 0;
    }
    return out;
}

const Answer = struct {
    noul: f64 = 0,
};

const Response = struct {
    answers: std.json.ArrayHashMap(Answer) = .{},
};

fn buildRequest(
    arena: std.mem.Allocator,
    model: []const u8,
    question: []const u8,
    items: []const []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    try w.writeAll("{\"state\":{\"request\":");
    try writeString(w, question);
    try w.writeAll(",\"candidates\":[");
    for (items, 0..) |item, i| {
        if (i > 0) try w.writeByte(',');
        try writeString(w, item);
    }
    try w.print("]}},\"model\":", .{});
    try std.json.Stringify.value(model, .{}, w);

    // One question per candidate, each naming its own candidate by path.
    // They are independent, so TypeSafe evaluates them in parallel.
    try w.writeAll(",\"questions\":{");
    for (items, 0..) |_, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"c{d}\":{{\"type\":\"noul\",\"instructions\":", .{i});
        const instruction = try std.fmt.allocPrint(
            arena,
            "{s} The email is `candidates[{d}]`. The request is `request`.",
            .{ INSTRUCTIONS, i },
        );
        try writeString(w, instruction);
        try w.writeAll(",\"criteria\":{\"true\":");
        try writeString(w, TRUE_CRITERIA);
        try w.writeAll(",\"false\":");
        try writeString(w, FALSE_CRITERIA);
        try w.writeAll("}}");
    }
    try w.writeAll("}}");
    return out.writer.buffered();
}

/// Message text reaches here, so the same trap as the Ollama prompt applies:
/// Stringify given invalid UTF-8 emits an array of byte numbers instead of a
/// string, and the request is rejected. See ollama.validUtf8.
fn writeString(w: *std.Io.Writer, text: []const u8) !void {
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const clean = ollama.validUtf8(scratch.allocator(), text) catch text;
    try std.json.Stringify.value(clean, .{}, w);
}

test "the request names one question per candidate, each pointing at its own" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = [_][]const u8{ "first email", "second email" };
    const body = try buildRequest(arena, "jev-latest", "find the InfluxDB thread", &items);

    // It has to be valid JSON before anything else is worth checking.
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    defer parsed.deinit();

    const questions = parsed.value.object.get("questions").?.object;
    try std.testing.expectEqual(@as(usize, 2), questions.count());
    try std.testing.expect(questions.get("c0") != null);
    try std.testing.expect(questions.get("c1") != null);

    // Each question must point at its own candidate, or every score is a
    // judgment about the same message.
    const first = questions.get("c0").?.object.get("instructions").?.string;
    try std.testing.expect(std.mem.indexOf(u8, first, "`candidates[0]`") != null);
    const second = questions.get("c1").?.object.get("instructions").?.string;
    try std.testing.expect(std.mem.indexOf(u8, second, "`candidates[1]`") != null);

    const state = parsed.value.object.get("state").?.object;
    try std.testing.expectEqual(@as(usize, 2), state.get("candidates").?.array.items.len);
}

test "a body that is not valid UTF-8 still produces valid JSON" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A windows-1252 smart quote, as it arrives in a real mail body.
    const items = [_][]const u8{"He said \x93hello\x94 to me"};
    const body = try buildRequest(arena, "jev-latest", "find it", &items);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    defer parsed.deinit();
    const candidates = parsed.value.object.get("state").?.object.get("candidates").?.array;
    // A string, not the array of byte numbers Stringify emits for bad UTF-8.
    try std.testing.expect(candidates.items[0] == .string);
}

//! Voice-note transcription.
//!
//! Port of `ronny/transcribe.py`, on whisper.cpp instead of faster-whisper.
//! Audio never leaves the machine -- the same boundary as the spam gate.
//!
//! Telegram sends OGG/Opus and whisper wants 16kHz mono float PCM, so ffmpeg
//! does the decode. faster-whisper shelled out to ffmpeg for this too; doing
//! it explicitly just makes it visible.
//!
//! The name repair below is the part that matters in practice. Whisper writes
//! "@" as the spoken word and guesses phonetically at names it has not been
//! told about: "1Password" came back as "one password" and "AcmeSync" as
//! "acme synch", both of which write to this mailbox regularly, and the owner
//! was left retrying. Priming the decoder fixes most of it; this repairs the
//! rest.

const std = @import("std");

const log = std.log.scoped(.transcribe);

pub const Error = error{ LoadFailed, DecodeFailed, TranscribeFailed };

extern fn ronny_whisper_load(model_path: [*:0]const u8) c_int;
extern fn ronny_whisper_free() void;
extern fn ronny_whisper_transcribe(samples: [*]const f32, n_samples: c_int, out: [*]u8, cap: c_int) c_int;

pub const SAMPLE_RATE = 16000;
/// Long audio would block the caller while it transcribes.
pub const MAX_SECONDS = 180;
const MAX_TEXT = 8192;

pub fn load(model_path: [:0]const u8) Error!void {
    if (ronny_whisper_load(model_path.ptr) != 0) {
        log.err("could not load the whisper model at {s}", .{model_path});
        return Error.LoadFailed;
    }
    log.info("whisper model loaded from {s}", .{model_path});
}

pub fn unload() void {
    ronny_whisper_free();
}

/// Decodes arbitrary audio to the mono 16kHz float PCM whisper expects.
///
/// The input goes through a temp file rather than ffmpeg's stdin. Piping both
/// ways deadlocks as soon as the input exceeds the pipe buffer (64KB): this
/// side blocks writing input while ffmpeg blocks writing output, and neither
/// drains the other. A 563KB sample hung indefinitely that way.
///
/// 0.16 note: spawning moved onto std.Io -- std.process.spawn(io, options)
/// rather than Child.init -- and a File does not read to end directly; you
/// take a Reader over it.
fn decodeToPcm(io: std.Io, gpa: std.mem.Allocator, audio: []const u8) ![]f32 {
    // Unique enough: one voice note is handled at a time, and the file is
    // removed on the way out.
    var name_buf: [64]u8 = undefined;
    const stamp = std.Io.Clock.now(.real, io);
    const tmp_name = try std.fmt.bufPrint(&name_buf, "/tmp/ronny-voice-{d}.bin", .{stamp.nanoseconds});

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp_name, .data = audio });
    defer std.Io.Dir.cwd().deleteFile(io, tmp_name) catch {};

    var child = try std.process.spawn(io, .{
        .argv = &.{
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-i",     tmp_name,
            "-f",     "f32le",
            "-ac",    "1",
            "-ar",    "16000",
            "pipe:1",
        },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    var read_buf: [64 * 1024]u8 = undefined;
    var stdout_reader = child.stdout.?.readerStreaming(io, &read_buf);
    const raw = try stdout_reader.interface.allocRemaining(gpa, .limited(MAX_SECONDS * SAMPLE_RATE * @sizeOf(f32)));
    defer gpa.free(raw);
    _ = try child.wait(io);

    if (raw.len < @sizeOf(f32)) return Error.DecodeFailed;

    const count = raw.len / @sizeOf(f32);
    const samples = try gpa.alloc(f32, count);
    @memcpy(std.mem.sliceAsBytes(samples), raw[0 .. count * @sizeOf(f32)]);
    return samples;
}

/// Transcribes a voice note. Caller owns the returned text.
pub fn transcribe(io: std.Io, gpa: std.mem.Allocator, audio: []const u8) ![]u8 {
    const samples = try decodeToPcm(io, gpa, audio);
    defer gpa.free(samples);

    if (samples.len > MAX_SECONDS * SAMPLE_RATE) return Error.TranscribeFailed;

    const buffer = try gpa.alloc(u8, MAX_TEXT);
    errdefer gpa.free(buffer);

    const written = ronny_whisper_transcribe(samples.ptr, @intCast(samples.len), buffer.ptr, MAX_TEXT);
    if (written < 0) return Error.TranscribeFailed;

    const text = std.mem.trim(u8, buffer[0..@intCast(written)], " \t\r\n");
    const owned = try gpa.dupe(u8, text);
    gpa.free(buffer);

    log.info("transcribed {d:.1}s of audio", .{@as(f32, @floatFromInt(samples.len)) / @as(f32, SAMPLE_RATE)});
    return owned;
}

// ---- transcript repair ----

const SPOKEN_DIGITS = [_]struct { word: []const u8, digit: []const u8 }{
    .{ .word = "zero", .digit = "0" },  .{ .word = "one", .digit = "1" },
    .{ .word = "two", .digit = "2" },   .{ .word = "three", .digit = "3" },
    .{ .word = "four", .digit = "4" },  .{ .word = "five", .digit = "5" },
    .{ .word = "six", .digit = "6" },   .{ .word = "seven", .digit = "7" },
    .{ .word = "eight", .digit = "8" }, .{ .word = "nine", .digit = "9" },
};

/// Ordinary words that must never be swapped for a sender name. A wide
/// vocabulary picked up "Mail" (from "Mail Delivery Subsystem") and started
/// rewriting "email" as "Mail". Only single words are protected -- "meta
/// call" is still free to become "AcmeSync".
const PROTECTED = [_][]const u8{
    "email", "emails",  "mail",    "mails",   "message", "messages", "note",
    "notes", "search",  "find",    "read",    "send",    "sent",     "reply",
    "draft", "summarise", "summarize", "status", "pause", "resume",  "cancel",
    "confirm", "add",   "remove",  "list",    "show",    "tell",     "give",
    "check", "last",    "first",   "next",    "from",    "about",    "today",
    "yesterday", "tomorrow", "week", "month", "call",    "calls",    "time",
    "team",  "info",    "support", "news",    "billing", "account",  "update",
};

fn isProtected(word: []const u8) bool {
    for (PROTECTED) |candidate| {
        if (std.ascii.eqlIgnoreCase(word, candidate)) return true;
    }
    return false;
}

/// Comparison key: spoken digits normalised, then everything but letters and
/// digits stripped. "one password" and "1Password" both become "1password",
/// which is what makes that case an exact match rather than a fuzzy one.
pub fn matchKey(gpa: std.mem.Allocator, phrase: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var words = std.mem.tokenizeAny(u8, phrase, " \t\r\n");
    while (words.next()) |word| {
        var replaced = false;
        for (SPOKEN_DIGITS) |entry| {
            if (std.ascii.eqlIgnoreCase(word, entry.word)) {
                try out.appendSlice(gpa, entry.digit);
                replaced = true;
                break;
            }
        }
        if (replaced) continue;
        for (word) |ch| {
            if (std.ascii.isAlphanumeric(ch)) try out.append(gpa, std.ascii.toLower(ch));
        }
    }
    return out.toOwnedSlice(gpa);
}

test "matchKey turns spoken digits into an exact match" {
    const gpa = std.testing.allocator;

    const spoken = try matchKey(gpa, "one password");
    defer gpa.free(spoken);
    const written = try matchKey(gpa, "1Password");
    defer gpa.free(written);
    try std.testing.expectEqualStrings(spoken, written);

    const meta_spaced = try matchKey(gpa, "acme sync");
    defer gpa.free(meta_spaced);
    const meta = try matchKey(gpa, "AcmeSync");
    defer gpa.free(meta);
    try std.testing.expectEqualStrings(meta_spaced, meta);
}

test "protected words are never treated as sender names" {
    // "email" once scored 0.89 against "Mail" from "Mail Delivery Subsystem"
    // and ordinary commands started being rewritten.
    try std.testing.expect(isProtected("email"));
    try std.testing.expect(isProtected("Email"));
    try std.testing.expect(isProtected("from"));
    try std.testing.expect(isProtected("call"));

    try std.testing.expect(!isProtected("1Password"));
    try std.testing.expect(!isProtected("AcmeSync"));
    try std.testing.expect(!isProtected("example"));
}

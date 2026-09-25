//! Text to speech, for summaries the owner has asked to hear rather than read.
//!
//! Runs piper locally, the same boundary as whisper and Ollama: a summary is
//! derived from a message body, so it does not leave the machine to be
//! spoken. Piper is shelled out to rather than linked, because its CLI is a
//! Python entry point over onnxruntime and a fresh process per summary costs
//! about a second and a half -- next to the tens of seconds the summary
//! itself took from Ollama, not worth a C boundary.
//!
//! Telegram only shows a voice bubble for OGG/Opus, MP3 or M4A, so piper's
//! WAV goes through ffmpeg, which voice notes already depend on.
//!
//! Everything here fails soft. A caller that cannot get audio sends the text
//! instead; a summary the owner cannot hear is still a summary they can read.

const std = @import("std");
const settings = @import("settings.zig");

const log = std.log.scoped(.speech);

pub const Error = error{ SynthesisFailed, EncodeFailed, TooLong };

/// Where piper lives and which voice speaks each language. All from .env;
/// unset means summaries stay text whatever the chat setting says.
pub const Config = struct {
    /// The piper executable, typically a venv's bin/piper.
    bin: [:0]const u8,
    /// Directory holding <voice>.onnx and <voice>.onnx.json pairs.
    voices_dir: [:0]const u8,
    /// Voice names, without extension, per language the owner speaks.
    voice_en: [:0]const u8,
    voice_es: [:0]const u8,

    /// The voice that reads `language`: the one the owner chose from chat
    /// if they did, otherwise the .env default.
    pub fn voiceForLanguage(self: Config, prefs: *const settings.Settings, language: settings.Language) []const u8 {
        return switch (language) {
            .en => if (prefs.voice_en.isSet()) prefs.voice_en.slice() else self.voice_en,
            .es => if (prefs.voice_es.isSet()) prefs.voice_es.slice() else self.voice_es,
        };
    }

    /// The voice for the language summaries are currently in.
    pub fn voiceFor(self: Config, prefs: *const settings.Settings) []const u8 {
        return self.voiceForLanguage(prefs, prefs.language);
    }
};

/// The voices installed: every <name>.onnx in the voices directory, sorted.
/// This list is the only place a chat-chosen voice can come from. Empty if
/// the directory cannot be read, which then reads as "no voices to choose".
pub fn available(io: std.Io, arena: std.mem.Allocator, cfg: Config) []const []const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, cfg.voices_dir, .{ .iterate = true }) catch |err| {
        log.warn("could not list voices in {s}: {s}", .{ cfg.voices_dir, @errorName(err) });
        return &.{};
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".onnx")) continue;
        const name = arena.dupe(u8, entry.name[0 .. entry.name.len - ".onnx".len]) catch continue;
        names.append(arena, name) catch continue;
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// A summary is three sentences; anything much past this is a body being
/// read verbatim, which nobody wants as audio.
pub const MAX_CHARS = 2000;

/// Opus at this rate is transparent for speech and keeps a summary under
/// 50KB, so upload time is not a factor.
const OPUS_BITRATE = "32k";
const MAX_AUDIO_BYTES = 8 * 1024 * 1024;

/// Speaks `text` with `voice` (a name as `available` lists it, or a .env
/// default) and returns OGG/Opus bytes, owned by `gpa`.
pub fn synthesize(
    io: std.Io,
    gpa: std.mem.Allocator,
    cfg: Config,
    voice: []const u8,
    text: []const u8,
) ![]u8 {
    const spoken = try spokenForm(gpa, text);
    defer gpa.free(spoken);
    if (spoken.len == 0) return Error.SynthesisFailed;
    if (spoken.len > MAX_CHARS) return Error.TooLong;

    // Unique enough: summaries are produced one at a time per process, and
    // the two processes that can speak embed their pid.
    const stamp = std.Io.Clock.now(.real, io).nanoseconds;
    const pid = std.os.linux.getpid();
    var text_buf: [96]u8 = undefined;
    var wav_buf: [96]u8 = undefined;
    var ogg_buf: [96]u8 = undefined;
    const text_path = try std.fmt.bufPrintZ(&text_buf, "/tmp/ronny-say-{d}-{d}.txt", .{ pid, stamp });
    const wav_path = try std.fmt.bufPrintZ(&wav_buf, "/tmp/ronny-say-{d}-{d}.wav", .{ pid, stamp });
    const ogg_path = try std.fmt.bufPrintZ(&ogg_buf, "/tmp/ronny-say-{d}-{d}.ogg", .{ pid, stamp });

    // The text goes through a file rather than argv or stdin: argv because a
    // summary can start with a dash, stdin because piper reads it lazily and
    // the deadlock transcribe.zig documents applies just the same.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = text_path, .data = spoken });
    defer std.Io.Dir.cwd().deleteFile(io, text_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, wav_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, ogg_path) catch {};

    try run(io, &.{
        cfg.bin,        "-m",      voice,           "--data-dir", cfg.voices_dir,
        "--input-file", text_path, "--output-file", wav_path,
    }, Error.SynthesisFailed);

    try run(io, &.{
        "ffmpeg",     "-hide_banner", "-loglevel", "error",   "-y",
        "-i",         wav_path,       "-c:a",      "libopus", "-b:a",
        OPUS_BITRATE, "-ac",          "1",         "-f",      "ogg",
        ogg_path,
    }, Error.EncodeFailed);

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, ogg_path, gpa, .limited(MAX_AUDIO_BYTES)) catch
        return Error.EncodeFailed;
    if (bytes.len == 0) {
        gpa.free(bytes);
        return Error.EncodeFailed;
    }
    log.info("spoke {d} chars as {s} ({d} bytes)", .{ spoken.len, voice, bytes.len });
    return bytes;
}

fn run(io: std.Io, argv: []const []const u8, failure: Error) Error!void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch |err| {
        log.warn("could not start {s}: {s}", .{ argv[0], @errorName(err) });
        return failure;
    };
    const term = child.wait(io) catch |err| {
        log.warn("{s} did not finish: {s}", .{ argv[0], @errorName(err) });
        return failure;
    };
    switch (term) {
        .exited => |code| if (code != 0) {
            log.warn("{s} exited with {d}", .{ argv[0], code });
            return failure;
        },
        else => {
            log.warn("{s} was killed", .{argv[0]});
            return failure;
        },
    }
}

/// What a summary should sound like, as opposed to look like.
///
/// A summary is prose already, so this is light: a URL becomes "a link",
/// because hearing one spelled out is the single worst thing text-to-speech
/// does, and runs of whitespace collapse so a paragraph break is not a long
/// silence. Nothing else is rewritten -- the audio must say what the text
/// says.
///
/// Caller owns the result.
pub fn spokenForm(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();

    var pending_space = false;
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (words.next()) |word| {
        const cleaned = if (isUrl(word)) "a link" else word;
        if (pending_space) try out.writer.writeByte(' ');
        try out.writer.writeAll(cleaned);
        pending_space = true;
    }
    return out.toOwnedSlice();
}

fn isUrl(word: []const u8) bool {
    const stripped = std.mem.trim(u8, word, "()[]<>\"'.,;:!?");
    return std.ascii.startsWithIgnoreCase(stripped, "http://") or
        std.ascii.startsWithIgnoreCase(stripped, "https://") or
        std.ascii.startsWithIgnoreCase(stripped, "www.");
}

test "a URL is spoken as 'a link', and the rest is left alone" {
    const spoken = try spokenForm(std.testing.allocator, "Maria asks you to sign at https://example.com/x?y=1 by Friday.");
    defer std.testing.allocator.free(spoken);
    try std.testing.expectEqualStrings("Maria asks you to sign at a link by Friday.", spoken);
}

test "paragraph breaks collapse rather than becoming a silence" {
    const spoken = try spokenForm(std.testing.allocator, "One.\n\n\nTwo.   Three.");
    defer std.testing.allocator.free(spoken);
    try std.testing.expectEqualStrings("One. Two. Three.", spoken);
}

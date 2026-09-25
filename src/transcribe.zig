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
extern fn ronny_whisper_backend(out: [*]u8, max_out: c_int) c_int;
extern fn ronny_whisper_transcribe(
    samples: [*]const f32,
    n_samples: c_int,
    prompt: ?[*:0]const u8,
    allowed_languages: ?[*:0]const u8,
    out: [*]u8,
    cap: c_int,
    language_out: [*]u8,
    language_cap: c_int,
) c_int;

pub const SAMPLE_RATE = 16000;
/// Long audio would block the caller while it transcribes.
pub const MAX_SECONDS = 180;
const MAX_TEXT = 8192;

pub fn load(model_path: [:0]const u8) Error!void {
    if (ronny_whisper_load(model_path.ptr) != 0) {
        log.err("could not load the whisper model at {s}", .{model_path});
        return Error.LoadFailed;
    }

    // Say which backend is live, loudly if it is the slow one. A CPU-linked
    // build loads and transcribes perfectly well, just ~150x slower, so the
    // only symptom is "voice feels sluggish" -- which took a log dig to
    // diagnose twice. The warning is phrased so the fix is in the message.
    var backend_buffer: [32]u8 = undefined;
    const written = ronny_whisper_backend(&backend_buffer, backend_buffer.len);
    const backend = if (written > 0) backend_buffer[0..@intCast(written)] else "unknown";
    if (written > 0 and std.mem.startsWith(u8, backend, "CPU")) {
        log.warn(
            "whisper is running on {s}, not the GPU -- transcription will be very slow. " ++
                "Rebuild with: zig build -Doptimize=ReleaseSafe -Dwhisper-prefix=\"$HOME/.local/opt/whisper-cuda\"",
            .{backend},
        );
    } else {
        log.info("whisper backend: {s}", .{backend});
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
///
/// `prompt` primes the decoder; see buildPrompt. Pass null to skip priming.
pub fn transcribe(
    io: std.Io,
    gpa: std.mem.Allocator,
    audio: []const u8,
    prompt: ?[:0]const u8,
    allowed_languages: ?[:0]const u8,
) ![]u8 {
    const samples = try decodeToPcm(io, gpa, audio);
    defer gpa.free(samples);

    if (samples.len > MAX_SECONDS * SAMPLE_RATE) return Error.TranscribeFailed;

    const buffer = try gpa.alloc(u8, MAX_TEXT);
    errdefer gpa.free(buffer);

    const started = std.Io.Clock.now(.boot, io);
    var language: [16]u8 = undefined;
    const written = ronny_whisper_transcribe(
        samples.ptr,
        @intCast(samples.len),
        if (prompt) |p| p.ptr else null,
        if (allowed_languages) |l| l.ptr else null,
        buffer.ptr,
        MAX_TEXT,
        &language,
        language.len,
    );
    if (written < 0) return Error.TranscribeFailed;
    const elapsed_ms = @divTrunc(
        std.Io.Clock.now(.boot, io).nanoseconds - started.nanoseconds,
        std.time.ns_per_ms,
    );

    const text = std.mem.trim(u8, buffer[0..@intCast(written)], " \t\r\n");
    const owned = try gpa.dupe(u8, text);
    gpa.free(buffer);

    // Both numbers, because the ratio is the thing worth watching: on the CPU
    // backend this runs near real time, on the GPU it should be a fraction.
    const seconds = @as(f32, @floatFromInt(samples.len)) / @as(f32, SAMPLE_RATE);
    log.info("transcribed {d:.1}s of audio in {d}ms ({d:.2}x real time, {s})", .{
        seconds, elapsed_ms, @as(f32, @floatFromInt(elapsed_ms)) / 1000.0 / seconds,
        std.mem.sliceTo(&language, 0),
    });
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

// ---- priming ----

/// Whisper truncates initial_prompt around 224 tokens, so only a slice of the
/// vocabulary reaches the decoder. The rest still earns its keep in the
/// matching pass below.
pub const PROMPT_VOCAB_LIMIT = 45;

/// Biases the decoder toward the vocabulary actually in use. This is the only
/// customization lever whisper offers -- there is no speaker enrollment.
pub fn buildPrompt(arena: std.mem.Allocator, vocabulary: []const []const u8) ![:0]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll(
        "Commands for an email assistant: read, summarise, search, reply, pause, resume, status, senders.",
    );
    if (vocabulary.len > 0) {
        try out.writer.writeAll(" Names and addresses: ");
        for (vocabulary[0..@min(vocabulary.len, PROMPT_VOCAB_LIMIT)], 0..) |entry, i| {
            if (i > 0) try out.writer.writeAll(", ");
            try out.writer.writeAll(entry);
        }
        try out.writer.writeByte('.');
    }
    return arena.dupeZ(u8, out.writer.buffered());
}

// ---- matching ----

const KEY_MAX = 64;
/// Names are riskier to substitute than addresses -- a wrong swap changes the
/// meaning of a sentence -- so this is stricter than ADDRESS_THRESHOLD.
const NAME_THRESHOLD = 0.85;
const ADDRESS_THRESHOLD = 0.72;
const MIN_NAME_CHARS = 4;

/// Longest-common-subsequence ratio, standing in for Python's difflib. On
/// strings this short the two agree closely enough that the thresholds tuned
/// against difflib carry over.
fn similarity(a: []const u8, b: []const u8) f64 {
    if (a.len == 0 or b.len == 0) return 0;
    if (a.len > KEY_MAX or b.len > KEY_MAX) return 0;

    var prev = [_]u16{0} ** (KEY_MAX + 1);
    var cur = [_]u16{0} ** (KEY_MAX + 1);
    for (a) |ca| {
        cur[0] = 0;
        for (b, 1..) |cb, j| {
            cur[j] = if (ca == cb) prev[j - 1] + 1 else @max(prev[j], cur[j - 1]);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    const common: f64 = @floatFromInt(prev[b.len]);
    return 2 * common / @as(f64, @floatFromInt(a.len + b.len));
}

const Entry = struct { key: []const u8, canonical: []const u8 };

fn buildLookup(arena: std.mem.Allocator, vocabulary: []const []const u8) ![]Entry {
    var lookup: std.ArrayList(Entry) = .empty;
    for (vocabulary) |entry| {
        const key = try matchKey(arena, entry);
        if (key.len < MIN_NAME_CHARS or key.len > KEY_MAX) continue;

        // First spelling wins, the way Python's setdefault did.
        var seen = false;
        for (lookup.items) |existing| {
            if (std.mem.eql(u8, existing.key, key)) {
                seen = true;
                break;
            }
        }
        if (!seen) try lookup.append(arena, .{ .key = key, .canonical = entry });
    }
    return lookup.toOwnedSlice(arena);
}

fn lookupName(entries: []const Entry, key: []const u8) ?[]const u8 {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.canonical;
    }

    var best: ?Entry = null;
    var best_score: f64 = NAME_THRESHOLD;
    for (entries) |entry| {
        const score = similarity(key, entry.key);
        if (score < best_score) continue;

        // A longer phrase can score well simply by containing a shorter name:
        // "from digital ocean" matched "digitalocean" and swallowed the
        // "from". Requiring comparable lengths replaces only the name itself.
        const key_len: f64 = @floatFromInt(key.len);
        const entry_len: f64 = @floatFromInt(entry.key.len);
        if (@abs(key_len - entry_len) > @max(2.0, entry_len * 0.25)) continue;

        best = entry;
        best_score = score;
    }
    return if (best) |entry| entry.canonical else null;
}

fn isProtectedPhrase(phrase: []const u8) bool {
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    for (phrase) |ch| {
        if (!std.ascii.isAlphabetic(ch)) continue;
        if (n == buf.len) return false;
        buf[n] = std.ascii.toLower(ch);
        n += 1;
    }
    return isProtected(buf[0..n]);
}

/// Repairs brand and sender names whisper guessed at phonetically.
/// Caller owns the result.
pub fn snapNames(gpa: std.mem.Allocator, text: []const u8, vocabulary: []const []const u8) ![]u8 {
    if (vocabulary.len == 0) return gpa.dupe(u8, text);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const lookup = try buildLookup(arena, vocabulary);
    if (lookup.len == 0) return gpa.dupe(u8, text);

    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |word| try words.append(arena, word);

    var out: std.Io.Writer.Allocating = .init(arena);
    var i: usize = 0;
    while (i < words.items.len) {
        var replaced = false;

        // Longest n-gram first, so "acme sync" wins over "call".
        var span: usize = 3;
        while (span >= 1) : (span -= 1) {
            if (i + span > words.items.len) continue;

            const phrase = try std.mem.join(arena, " ", words.items[i .. i + span]);
            if (span == 1 and isProtectedPhrase(phrase)) continue;

            const key = try matchKey(arena, phrase);
            if (key.len < MIN_NAME_CHARS or key.len > KEY_MAX) continue;

            const canonical = lookupName(lookup, key) orelse continue;
            if (i > 0) try out.writer.writeByte(' ');
            try out.writer.writeAll(canonical);
            if (!std.mem.eql(u8, phrase, canonical)) {
                log.info("snapped spoken name \"{s}\" to \"{s}\"", .{ phrase, canonical });
            }
            i += span;
            replaced = true;
            break;
        }

        if (!replaced) {
            if (i > 0) try out.writer.writeByte(' ');
            try out.writer.writeAll(words.items[i]);
            i += 1;
        }
    }
    return gpa.dupe(u8, out.writer.buffered());
}

// ---- spoken addresses ----

/// Whisper writes "@" as a word and often drops the dot too, so
/// "sam@example.com" arrives as "sam at example dot com" -- or, at
/// its worst, "sam at example com".
fn isAtToken(word: []const u8) bool {
    return std.mem.eql(u8, word, "@") or std.ascii.eqlIgnoreCase(word, "at");
}

fn isDotToken(word: []const u8) bool {
    return std.mem.eql(u8, word, ".") or std.ascii.eqlIgnoreCase(word, "dot");
}

fn trimPunctuation(word: []const u8) []const u8 {
    return std.mem.trim(u8, word, ".,;:!?\"'()");
}

fn isLocalPart(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "._%+-", ch) == null) return false;
    }
    return true;
}

fn isLabel(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    }
    return true;
}

fn isTld(word: []const u8) bool {
    if (word.len < 2) return false;
    for (word) |ch| {
        if (!std.ascii.isAlphabetic(ch)) return false;
    }
    return true;
}

/// Snaps a rebuilt address onto one Ronny actually knows. The candidate set is
/// known, so this is a lookup rather than a guess; below the threshold the
/// near-miss is left alone, because a confidently wrong address is worse than
/// an unclear one.
fn snapAddress(vocabulary: []const []const u8, candidate: []const u8) ?[]const u8 {
    var lowered_buf: [KEY_MAX * 2]u8 = undefined;
    if (candidate.len > lowered_buf.len) return null;
    const lowered = std.ascii.lowerString(lowered_buf[0..candidate.len], candidate);

    var best: ?[]const u8 = null;
    var best_score: f64 = ADDRESS_THRESHOLD;
    for (vocabulary) |entry| {
        if (std.mem.indexOfScalar(u8, entry, '@') == null) continue;
        if (std.ascii.eqlIgnoreCase(entry, lowered)) return entry;

        var entry_buf: [KEY_MAX * 2]u8 = undefined;
        if (entry.len > entry_buf.len) continue;
        const entry_lowered = std.ascii.lowerString(entry_buf[0..entry.len], entry);

        const score = similarity(lowered, entry_lowered);
        if (score < best_score) continue;
        best = entry;
        best_score = score;
    }
    return best;
}

/// Rebuilds spoken addresses and snaps near-misses onto known senders.
/// Caller owns the result.
pub fn rebuildAddresses(gpa: std.mem.Allocator, text: []const u8, vocabulary: []const []const u8) ![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var words: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |word| try words.append(arena, word);

    var out: std.Io.Writer.Allocating = .init(arena);
    var wrote_any = false;

    const emit = struct {
        fn call(w: *std.Io.Writer, first: *bool, piece: []const u8) !void {
            if (first.*) try w.writeByte(' ');
            first.* = true;
            try w.writeAll(piece);
        }
    }.call;

    var i: usize = 0;
    while (i < words.items.len) {
        const rebuilt: ?struct { address: []const u8, consumed: usize } = blk: {
            if (i + 2 >= words.items.len) break :blk null;
            if (!isAtToken(words.items[i + 1])) break :blk null;

            const local = trimPunctuation(words.items[i]);
            if (!isLocalPart(local)) break :blk null;

            const domain = trimPunctuation(words.items[i + 2]);

            // "local at domain.tld" -- the dot survived.
            if (std.mem.indexOfScalar(u8, domain, '.')) |dot| {
                if (isLabel(domain[0..dot]) and isTld(domain[dot + 1 ..])) {
                    const address = try std.fmt.allocPrint(arena, "{s}@{s}", .{ local, domain });
                    break :blk .{ .address = snapAddress(vocabulary, address) orelse address, .consumed = 3 };
                }
                break :blk null;
            }
            if (!isLabel(domain)) break :blk null;

            // "local at domain dot tld".
            if (i + 4 < words.items.len and isDotToken(words.items[i + 3])) {
                const tld = trimPunctuation(words.items[i + 4]);
                if (isTld(tld)) {
                    const address = try std.fmt.allocPrint(arena, "{s}@{s}.{s}", .{ local, domain, tld });
                    break :blk .{ .address = snapAddress(vocabulary, address) orelse address, .consumed = 5 };
                }
            }

            // "local at domain tld" -- the dot is gone too. Far too loose to
            // trust on its own ("meet at the office" fits it), so it is only
            // accepted when the result matches a sender Ronny actually knows.
            if (i + 3 < words.items.len) {
                const tld = trimPunctuation(words.items[i + 3]);
                if (isTld(tld)) {
                    const address = try std.fmt.allocPrint(arena, "{s}@{s}.{s}", .{ local, domain, tld });
                    if (snapAddress(vocabulary, address)) |known| {
                        log.info("rebuilt spoken address as \"{s}\"", .{known});
                        break :blk .{ .address = known, .consumed = 4 };
                    }
                }
            }
            break :blk null;
        };

        if (rebuilt) |found| {
            try emit(&out.writer, &wrote_any, found.address);
            i += found.consumed;
            continue;
        }

        // An address whisper got mostly right still gets snapped.
        const word = words.items[i];
        const bare = trimPunctuation(word);
        if (std.mem.indexOfScalar(u8, bare, '@') != null) {
            if (snapAddress(vocabulary, bare)) |known| {
                try emit(&out.writer, &wrote_any, known);
                i += 1;
                continue;
            }
        }

        try emit(&out.writer, &wrote_any, word);
        i += 1;
    }
    return gpa.dupe(u8, out.writer.buffered());
}

/// The full repair pass: names first, then addresses. Caller owns the result.
pub fn repair(gpa: std.mem.Allocator, text: []const u8, vocabulary: []const []const u8) ![]u8 {
    const named = try snapNames(gpa, text, vocabulary);
    defer gpa.free(named);
    return rebuildAddresses(gpa, named, vocabulary);
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

test "repair fixes the names whisper actually got wrong" {
    const gpa = std.testing.allocator;
    const vocab = [_][]const u8{ "1Password", "AcmeSync", "example.org", "sam@example.com" };

    // Two shapes, both seen for real: a spoken digit, and a phonetic guess
    // at a compound name. 1Password is the genuine case; the compound is a
    // stand-in for one, since the original was a real correspondent.
    const one = try repair(gpa, "read the last email from one password", &vocab);
    defer gpa.free(one);
    try std.testing.expect(std.mem.indexOf(u8, one, "1Password") != null);

    const near = try repair(gpa, "anything from acme synch today", &vocab);
    defer gpa.free(near);
    try std.testing.expect(std.mem.indexOf(u8, near, "AcmeSync") != null);

    // And the split-compound case, which the digit normalisation also covers.
    const split = try repair(gpa, "anything from acme sync today", &vocab);
    defer gpa.free(split);
    try std.testing.expect(std.mem.indexOf(u8, split, "AcmeSync") != null);
}

test "repair leaves ordinary words alone" {
    const gpa = std.testing.allocator;
    const vocab = [_][]const u8{ "Mail Delivery Subsystem", "example.org" };

    // "email" once scored high enough against "Mail" to be rewritten.
    const text = try repair(gpa, "read the last email from example.org", &vocab);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("read the last email from example.org", text);
}

test "repair rebuilds a spoken address" {
    const gpa = std.testing.allocator;
    const vocab = [_][]const u8{"sam@example.com"};

    const dotted = try repair(gpa, "read the mail from sam at example dot com", &vocab);
    defer gpa.free(dotted);
    try std.testing.expect(std.mem.indexOf(u8, dotted, "sam@example.com") != null);

    // The dot dropped entirely -- only accepted because it lands on a known
    // sender.
    const loose = try repair(gpa, "read the mail from sam at example com", &vocab);
    defer gpa.free(loose);
    try std.testing.expect(std.mem.indexOf(u8, loose, "sam@example.com") != null);
}

test "an unknown spoken address is left alone rather than guessed at" {
    const gpa = std.testing.allocator;
    const vocab = [_][]const u8{"sam@example.com"};

    // Plain English fits the loose shape; it must not become an address.
    const prose = try repair(gpa, "lets meet at the office", &vocab);
    defer gpa.free(prose);
    try std.testing.expect(std.mem.indexOfScalar(u8, prose, '@') == null);
}

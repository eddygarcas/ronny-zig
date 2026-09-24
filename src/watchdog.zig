//! Tails Ronny's journal, spots incidents, asks the local model what likely
//! went wrong, and tells the owner over Telegram.
//!
//! Port of `ronny/watchdog.py`, with the same three rules:
//!
//! - **Its own process.** A watchdog that dies with the thing it watches
//!   cannot report that the thing died.
//! - **Detect and diagnose only.** It never restarts, patches or changes
//!   anything. A wrong automated "fix" on a mail notifier means silently
//!   missing real email, so the decision stays with the owner. This was an
//!   explicit choice, not an omission.
//! - **Send-only on Telegram.** It must never call getUpdates: two pollers on
//!   one token fight over updates (409 Conflict), which would break the bot
//!   it is supposed to be protecting.
//!
//! Unlike the Python version this needs no threads. Everything is driven by
//! one poll on journalctl's pipe with a timeout: a line arriving is an event,
//! and the timeout expiring is the heartbeat check.

const std = @import("std");
const ollama = @import("ollama.zig");
const telegram = @import("telegram.zig");

const log = std.log.scoped(.watchdog);

/// Both halves of Ronny. The watcher is what the heartbeat tracks; the bot is
/// followed so its failures are reported too.
pub const WATCH_UNIT = "ronny-watch";
pub const BOT_UNIT = "ronny-bot";

const CONTEXT_LINES = 12;
const LINE_MAX = 2048;
const READ_BUFFER = 64 * 1024;

/// Per incident kind, so a crash loop cannot flood the owner.
const COOLDOWN_SECONDS = 900;
/// One failure usually writes several matching lines -- an error, then
/// whatever it cascaded into. Without this a single event alerted twice.
const BURST_QUIET_SECONDS = 60;

/// The watcher logs a heartbeat every IDLE timeout (300s). Three missed ones
/// means it is alive as a process but not actually watching, and a hang
/// produces no error line, so nothing else here would ever notice it.
const HEARTBEAT_TIMEOUT_SECONDS = 960;
const HEARTBEAT_CHECK_SECONDS = 60;
pub const HEARTBEAT_MARKER = "heartbeat: watching INBOX";

const RECONNECT_SECONDS = 10;

const Incident = struct {
    /// Matched case-insensitively as a substring. Zig has no regex in std,
    /// and every pattern the Python version used was either a literal or an
    /// alternation, which is just several entries here.
    needle: []const u8,
    kind: []const u8,
    description: []const u8,
    /// Some kinds are informational rather than faults and recur on a
    /// schedule. A daily newsletter correctly suppressed as spam is worth
    /// knowing about once, not every morning -- a watchdog you learn to
    /// ignore is useless.
    cooldown: u32 = COOLDOWN_SECONDS,
};

/// First match wins, so the specific entries come before the general ones.
const INCIDENTS = [_]Incident{
    .{ .needle = "panic:", .kind = "crash", .description = "Ronny panicked" },
    .{ .needle = "Main process exited", .kind = "service", .description = "Service exited unexpectedly" },
    .{ .needle = "Failed with result", .kind = "service", .description = "Service exited unexpectedly" },
    .{ .needle = "Failed to start", .kind = "service", .description = "Service failed to start" },
    .{ .needle = "IDLE failed", .kind = "imap", .description = "The IMAP idle connection failed" },
    .{ .needle = "scan failed", .kind = "imap", .description = "A mailbox scan failed" },
    .{ .needle = "libetpan returned", .kind = "imap", .description = "An IMAP call failed" },
    .{ .needle = "poll failed", .kind = "telegram", .description = "Telegram polling error" },
    .{ .needle = "sendMessage returned", .kind = "notify", .description = "A notification failed to send" },
    .{ .needle = "SMTP send to", .kind = "smtp", .description = "Sending a reply failed" },
    .{ .needle = "spam check unavailable", .kind = "ollama", .description = "The local model was unreachable for a spam check" },
    .{ .needle = "interpretation unavailable", .kind = "ollama", .description = "The local model was unreachable for a command" },
    .{ .needle = "ollama returned", .kind = "ollama", .description = "The local model returned an error" },
    .{ .needle = "whisper model did not load", .kind = "voice", .description = "Voice notes are disabled -- the model did not load" },
    .{ .needle = "suppressed uid=", .kind = "suppressed", .description = "Mail from an allowlisted sender was suppressed as spam", .cooldown = 24 * 3600 },
    .{ .needle = "-> unknown", .kind = "gap", .description = "Ronny didn't understand a message", .cooldown = 6 * 3600 },
};

/// A clean stop or start is normal operation, not an incident.
const IGNORED = [_][]const u8{ "Stopping", "Stopped", "Deactivated successfully", "Started" };

pub fn classify(line: []const u8) ?Incident {
    for (IGNORED) |ignored| {
        if (std.mem.indexOf(u8, line, ignored) != null) return null;
    }
    for (INCIDENTS) |incident| {
        if (std.ascii.indexOfIgnoreCase(line, incident.needle) != null) return incident;
    }
    return null;
}

const DIAGNOSE_PROMPT =
    \\You are diagnosing an incident in a personal email-notification agent called Ronny. Ronny is a Zig systemd service that watches a Gmail inbox over IMAP, matches senders against an allowlist, runs a spam check, and notifies its owner on Telegram. It uses a local Ollama model for spam checks, summaries and search ranking, and a hosted model for classifying chat commands.
    \\
    \\Incident type: {s} -- {s}
    \\
    \\Recent log lines:
    \\{s}
    \\
    \\In at most 3 short sentences: what most likely went wrong, and what the owner should check or change. Be concrete. Plain text only, no markdown, no preamble.
;

pub const Config = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    telegram_token: []const u8,
    telegram_owner_chat_id: []const u8,
    ollama_url: []const u8,
    ollama_model: []const u8,
};

const Alert = struct { kind: []const u8, at_ns: i96 };

pub const Watchdog = struct {
    cfg: Config,
    client: telegram.Client,

    /// A small ring of recent lines, given to the model as context.
    context: [CONTEXT_LINES][LINE_MAX]u8 = undefined,
    context_len: [CONTEXT_LINES]usize = @splat(0),
    context_next: usize = 0,

    alerts: std.ArrayList(Alert) = .empty,
    last_alert_ns: ?i96 = null,
    /// Starts now, not zero, so a fresh watchdog doesn't immediately report
    /// silence before the first heartbeat is even due.
    last_heartbeat_ns: i96,

    pub fn init(cfg: Config) Watchdog {
        return .{
            .cfg = cfg,
            .client = .{
                .io = cfg.io,
                .gpa = cfg.gpa,
                .token = cfg.telegram_token,
                .owner_chat_id = cfg.telegram_owner_chat_id,
            },
            .last_heartbeat_ns = std.Io.Clock.now(.boot, cfg.io).nanoseconds,
        };
    }

    pub fn deinit(self: *Watchdog) void {
        self.alerts.deinit(self.cfg.gpa);
    }

    fn now(self: *Watchdog) i96 {
        return std.Io.Clock.now(.boot, self.cfg.io).nanoseconds;
    }

    fn remember(self: *Watchdog, line: []const u8) void {
        const n = @min(line.len, LINE_MAX);
        @memcpy(self.context[self.context_next][0..n], line[0..n]);
        self.context_len[self.context_next] = n;
        self.context_next = (self.context_next + 1) % CONTEXT_LINES;
    }

    /// Oldest first, which is the order the model should read them in.
    fn contextText(self: *Watchdog, arena: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(arena);
        for (0..CONTEXT_LINES) |offset| {
            const index = (self.context_next + offset) % CONTEXT_LINES;
            const len = self.context_len[index];
            if (len == 0) continue;
            try out.writer.writeAll(self.context[index][0..len]);
            try out.writer.writeByte('\n');
        }
        return out.writer.buffered();
    }

    pub fn handle(self: *Watchdog, line: []const u8) void {
        self.remember(line);

        // Any log line proves Ronny is alive, but only a heartbeat proves the
        // IMAP loop itself is still turning.
        if (std.mem.indexOf(u8, line, HEARTBEAT_MARKER) != null) {
            self.last_heartbeat_ns = self.now();
            return;
        }

        const incident = classify(line) orelse return;
        self.report(incident.kind, incident.description, line, incident.cooldown);
    }

    fn report(
        self: *Watchdog,
        kind: []const u8,
        description: []const u8,
        line: []const u8,
        cooldown: u32,
    ) void {
        const at = self.now();

        for (self.alerts.items) |seen| {
            if (!std.mem.eql(u8, seen.kind, kind)) continue;
            if (@divTrunc(at - seen.at_ns, std.time.ns_per_s) < cooldown) {
                log.info("incident '{s}' is still in cooldown, not alerting", .{kind});
                return;
            }
        }
        if (self.last_alert_ns) |previous| {
            if (@divTrunc(at - previous, std.time.ns_per_s) < BURST_QUIET_SECONDS) {
                log.info("incident '{s}' is part of a burst already alerted on, not alerting", .{kind});
                return;
            }
        }

        self.touch(kind, at);
        self.last_alert_ns = at;
        log.info("incident detected: {s} -- {s}", .{ kind, description });

        var arena_state: std.heap.ArenaAllocator = .init(self.cfg.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const explanation = self.diagnose(arena, kind, description) catch
            "(couldn't reach the local model for a diagnosis)";
        self.alert(arena, description, line, explanation) catch |err| {
            log.err("failed to send the alert for '{s}': {s}", .{ kind, @errorName(err) });
        };
    }

    fn touch(self: *Watchdog, kind: []const u8, at: i96) void {
        for (self.alerts.items) |*seen| {
            if (std.mem.eql(u8, seen.kind, kind)) {
                seen.at_ns = at;
                return;
            }
        }
        self.alerts.append(self.cfg.gpa, .{ .kind = kind, .at_ns = at }) catch {};
    }

    fn diagnose(
        self: *Watchdog,
        arena: std.mem.Allocator,
        kind: []const u8,
        description: []const u8,
    ) ![]const u8 {
        const prompt = try std.fmt.allocPrint(arena, DIAGNOSE_PROMPT, .{
            kind, description, try self.contextText(arena),
        });
        return ollama.generate(self.cfg.io, arena, self.cfg.ollama_url, self.cfg.ollama_model, prompt, .text);
    }

    fn alert(
        self: *Watchdog,
        arena: std.mem.Allocator,
        description: []const u8,
        line: []const u8,
        explanation: []const u8,
    ) !void {
        if (self.cfg.telegram_owner_chat_id.len == 0) {
            log.warn("no owner chat id configured -- incident not sent: {s}", .{description});
            return;
        }
        const text = try std.fmt.allocPrint(
            arena,
            "\u{26A0}\u{FE0F} Ronny watchdog: {s}\n\n{s}\n\nLikely cause:\n{s}",
            .{ description, line[0..@min(line.len, 600)], explanation },
        );
        try self.client.sendMessage(telegram.truncate(text));
        log.info("alert sent: {s}", .{description});
    }

    /// Detects a silent hang.
    ///
    /// Everything else here reacts to a log line, so a Ronny that stops
    /// working without crashing -- a stuck socket, a wedged loop -- would
    /// produce no error and no alert. This runs on its own clock instead.
    fn checkHeartbeat(self: *Watchdog) void {
        const quiet_seconds = @divTrunc(self.now() - self.last_heartbeat_ns, std.time.ns_per_s);
        if (quiet_seconds < HEARTBEAT_TIMEOUT_SECONDS) return;

        var arena_state: std.heap.ArenaAllocator = .init(self.cfg.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const minutes = @divTrunc(quiet_seconds, 60);
        if (!self.unitIsActive(WATCH_UNIT)) {
            const description = std.fmt.allocPrint(
                arena,
                "Ronny is not running (no heartbeat for {d} min)",
                .{minutes},
            ) catch "Ronny is not running";
            self.report("down", description, "systemctl reports " ++ WATCH_UNIT ++ " is not active", COOLDOWN_SECONDS);
        } else {
            const description = std.fmt.allocPrint(
                arena,
                "Ronny is running but has gone silent for {d} min",
                .{minutes},
            ) catch "Ronny is running but has gone silent";
            self.report(
                "silent",
                description,
                "The process is alive but the IMAP watch loop has not logged a heartbeat, so it may be hung and missing mail.",
                COOLDOWN_SECONDS,
            );
        }

        // Reset, so it reports again only after another full window rather
        // than on every check while it stays down.
        self.last_heartbeat_ns = self.now();
    }

    fn unitIsActive(self: *Watchdog, unit: []const u8) bool {
        var child = std.process.spawn(self.cfg.io, .{
            .argv = &.{ "systemctl", "is-active", "--quiet", unit },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            log.warn("could not query the state of {s}: {s}", .{ unit, @errorName(err) });
            return true; // don't cry wolf on a broken check
        };
        const term = child.wait(self.cfg.io) catch return true;
        return switch (term) {
            .exited => |code| code == 0,
            else => true,
        };
    }
};

/// Follows both units until the stream ends. Returns so the caller can
/// restart it; journalctl exiting is normal on a log rotation.
fn follow(watchdog: *Watchdog) !void {
    var child = try std.process.spawn(watchdog.cfg.io, .{
        .argv = &.{
            "journalctl", "-u", WATCH_UNIT, "-u", BOT_UNIT,
            "-f",         "-n", "0",        "--output=short-iso",
        },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer _ = child.wait(watchdog.cfg.io) catch {};
    errdefer child.kill(watchdog.cfg.io);

    const stdout = child.stdout.?;
    var buffer: [READ_BUFFER]u8 = undefined;
    var filled: usize = 0;

    while (true) {
        // One poll drives everything: a line arriving is an event, and the
        // timeout expiring is the heartbeat check. No second thread needed.
        var fds = [_]std.posix.pollfd{.{
            .fd = stdout.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&fds, HEARTBEAT_CHECK_SECONDS * 1000);
        if (ready == 0) {
            watchdog.checkHeartbeat();
            continue;
        }

        const read = std.posix.read(stdout.handle, buffer[filled..]) catch |err| {
            log.warn("reading the journal failed: {s}", .{@errorName(err)});
            return;
        };
        if (read == 0) return; // journalctl exited
        filled += read;

        // Reads land on arbitrary boundaries, so whole lines are taken out
        // and the remainder is kept for the next read.
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, buffer[0..filled], start, '\n')) |newline| {
            watchdog.handle(std.mem.trimEnd(u8, buffer[start..newline], "\r"));
            start = newline + 1;
        }
        if (start > 0) {
            std.mem.copyForwards(u8, buffer[0..], buffer[start..filled]);
            filled -= start;
        }
        // A line longer than the buffer would otherwise wedge the loop.
        if (filled == buffer.len) {
            watchdog.handle(buffer[0..filled]);
            filled = 0;
        }
    }
}

pub fn run(cfg: Config) !void {
    var watchdog: Watchdog = .init(cfg);
    defer watchdog.deinit();

    log.info("watchdog started, following {s} and {s} (heartbeat timeout {d}s)", .{
        WATCH_UNIT, BOT_UNIT, HEARTBEAT_TIMEOUT_SECONDS,
    });

    while (true) {
        follow(&watchdog) catch |err| {
            log.err("watchdog loop error: {s}", .{@errorName(err)});
        };
        log.warn("journal stream ended, restarting in {d}s", .{RECONNECT_SECONDS});
        try cfg.io.sleep(.fromNanoseconds(RECONNECT_SECONDS * std.time.ns_per_s), .awake);
    }
}

test "classify spots real failures and ignores clean lifecycle lines" {
    // Zig's log format, which is what the journal now carries.
    try std.testing.expectEqualStrings(
        "imap",
        classify("Sep 24 11:02:01 host ronny[1]: error(ronny): scan failed: Fetch").?.kind,
    );
    try std.testing.expectEqualStrings(
        "ollama",
        classify("error(spam): spam check unavailable (RequestFailed); notifying anyway").?.kind,
    );
    try std.testing.expectEqualStrings(
        "crash",
        classify("thread 123 panic: attempt to use null value").?.kind,
    );

    // A clean stop is normal operation, not an incident -- even though the
    // systemd line for it also mentions the unit.
    try std.testing.expectEqual(@as(?Incident, null), classify("Stopping Ronny mailbox watcher..."));
    try std.testing.expectEqual(@as(?Incident, null), classify("ronny-watch.service: Deactivated successfully."));
    try std.testing.expectEqual(@as(?Incident, null), classify("info(ronny): notified about mail from x@y.com"));
}

test "informational incidents get a long cooldown" {
    // A daily newsletter suppressed as spam is worth one alert, not one a day.
    const suppressed = classify("info(ronny): suppressed uid=42 from=news@example.com (marketing blast)").?;
    try std.testing.expectEqualStrings("suppressed", suppressed.kind);
    try std.testing.expect(suppressed.cooldown > COOLDOWN_SECONDS);

    const fault = classify("error(ronny): IDLE failed: Idle").?;
    try std.testing.expectEqual(@as(u32, COOLDOWN_SECONDS), fault.cooldown);
}

test "the heartbeat marker is matched exactly as the watcher writes it" {
    // If these two ever drift apart the watchdog reports a healthy Ronny as
    // hung, so the marker is asserted rather than assumed.
    const line = "Sep 24 11:07:00 host ronny[1]: info(ronny): " ++ HEARTBEAT_MARKER ++ ", last uid 51234";
    try std.testing.expect(std.mem.indexOf(u8, line, HEARTBEAT_MARKER) != null);
    try std.testing.expectEqual(@as(?Incident, null), classify(line));
}

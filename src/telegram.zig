//! Telegram delivery and control.
//!
//! Port of the transport half of `ronny/telegram_bot.py`.
//!
//! Sending and polling are separated on purpose. Only one process may call
//! `getUpdates` for a given token -- a second poller gets 409 Conflict -- but
//! any number may send. That asymmetry is what lets the Zig watcher take over
//! notifications while the Python bot still owns commands, and it is the same
//! reason the watchdog is send-only.

const std = @import("std");
const http = @import("http.zig");

const log = std.log.scoped(.telegram);

pub const Error = error{SendFailed};

/// Telegram rejects messages over 4096 characters; leave room for framing.
pub const MAX_MESSAGE_CHARS = 3500;

pub fn truncate(text: []const u8) []const u8 {
    if (text.len <= MAX_MESSAGE_CHARS) return text;
    return text[0..MAX_MESSAGE_CHARS];
}

/// A voice note. Telegram sends a file id; the audio is downloaded separately
/// through getFile.
pub const Voice = struct {
    file_id: []const u8 = "",
    duration: u32 = 0,
};

pub const Chat = struct { id: i64 = 0 };

pub const Message = struct {
    chat: Chat = .{},
    text: ?[]const u8 = null,
    voice: ?Voice = null,
    /// A forwarded audio file behaves the same as a voice note here.
    audio: ?Voice = null,
};

pub const Update = struct {
    update_id: i64 = 0,
    message: ?Message = null,
};

pub const UpdatesResponse = struct {
    ok: bool = false,
    result: []Update = &.{},
};

const FileResult = struct { file_path: []const u8 = "" };
const FileResponse = struct { ok: bool = false, result: FileResult = .{} };

pub const Client = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    token: []const u8,
    owner_chat_id: []const u8,
    /// getUpdates cursor. Only meaningful if this process is the poller.
    offset: i64 = 0,

    fn url(self: *const Client, arena: std.mem.Allocator, method: []const u8) ![]u8 {
        return std.fmt.allocPrint(arena, "https://api.telegram.org/bot{s}/{s}", .{ self.token, method });
    }

    pub fn sendMessage(self: *Client, text: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var payload: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(.{
            .chat_id = self.owner_chat_id,
            .text = truncate(text),
        }, .{}, &payload.writer);

        const endpoint = try self.url(arena, "sendMessage");
        var response = http.postJson(self.io, arena, endpoint, payload.writer.buffered(), &.{}) catch {
            return Error.SendFailed;
        };
        defer response.deinit(arena);

        if (!response.ok()) {
            // Telegram explains refusals in the body, so it is worth logging.
            log.warn("sendMessage returned {d}: {s}", .{
                @intFromEnum(response.status),
                response.body[0..@min(response.body.len, 200)],
            });
            return Error.SendFailed;
        }
    }

    /// Long-polls for new messages. The caller owns the returned `Parsed`.
    pub fn getUpdates(
        self: *Client,
        arena: std.mem.Allocator,
        timeout_seconds: u32,
    ) !std.json.Parsed(UpdatesResponse) {
        var payload: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(.{
            .offset = self.offset,
            .timeout = timeout_seconds,
        }, .{}, &payload.writer);

        const endpoint = try self.url(arena, "getUpdates");
        var response = try http.postJson(self.io, arena, endpoint, payload.writer.buffered(), &.{});
        defer response.deinit(arena);

        if (!response.ok()) {
            log.warn("getUpdates returned {d}: {s}", .{
                @intFromEnum(response.status),
                response.body[0..@min(response.body.len, 200)],
            });
            return Error.SendFailed;
        }

        const parsed = try std.json.parseFromSlice(UpdatesResponse, arena, response.body, .{
            .ignore_unknown_fields = true,
        });

        // Acknowledge everything returned, so updates are not replayed.
        for (parsed.value.result) |update| {
            if (update.update_id >= self.offset) self.offset = update.update_id + 1;
        }
        return parsed;
    }

    /// Shows "typing..." while slow work runs. Mailbox fetches and local
    /// summarisation take tens of seconds, during which the bot otherwise
    /// looks dead -- the owner reported exactly that against the Python
    /// version. Best effort: failures here are never worth surfacing.
    pub fn sendTyping(self: *Client) void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var payload: std.Io.Writer.Allocating = .init(arena);
        std.json.Stringify.value(.{
            .chat_id = self.owner_chat_id,
            .action = "typing",
        }, .{}, &payload.writer) catch return;

        const endpoint = self.url(arena, "sendChatAction") catch return;
        var response = http.postJson(self.io, arena, endpoint, payload.writer.buffered(), &.{}) catch return;
        response.deinit(arena);
    }

    /// Downloads a voice note. Returns the audio bytes, owned by `arena`.
    pub fn downloadFile(self: *Client, arena: std.mem.Allocator, file_id: []const u8) ![]u8 {
        var payload: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(.{ .file_id = file_id }, .{}, &payload.writer);

        const meta_url = try self.url(arena, "getFile");
        var meta = try http.postJson(self.io, arena, meta_url, payload.writer.buffered(), &.{});
        defer meta.deinit(arena);
        if (!meta.ok()) return Error.SendFailed;

        const parsed = try std.json.parseFromSlice(FileResponse, arena, meta.body, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        if (parsed.value.result.file_path.len == 0) return Error.SendFailed;

        const download_url = try std.fmt.allocPrint(
            arena,
            "https://api.telegram.org/file/bot{s}/{s}",
            .{ self.token, parsed.value.result.file_path },
        );
        var audio = try http.get(self.io, arena, download_url);
        if (!audio.ok()) {
            audio.deinit(arena);
            return Error.SendFailed;
        }
        return audio.body;
    }
};

test "truncate leaves short text alone and caps long text" {
    try std.testing.expectEqualStrings("hello", truncate("hello"));

    const long = "x" ** (MAX_MESSAGE_CHARS + 500);
    try std.testing.expectEqual(@as(usize, MAX_MESSAGE_CHARS), truncate(long).len);
}

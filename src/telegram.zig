//! Telegram delivery and control.
//!
//! Port of the send/poll half of `ronny/telegram_bot.py`.
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

pub const Client = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    token: []const u8,
    owner_chat_id: []const u8,
    /// getUpdates offset. Only meaningful if this process is the poller.
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
            .text = text,
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
};

/// Telegram rejects messages over 4096 characters; leave room for framing.
pub const MAX_MESSAGE_CHARS = 3500;

pub fn truncate(text: []const u8) []const u8 {
    if (text.len <= MAX_MESSAGE_CHARS) return text;
    return text[0..MAX_MESSAGE_CHARS];
}

test "truncate leaves short text alone and caps long text" {
    try std.testing.expectEqualStrings("hello", truncate("hello"));

    const long = "x" ** (MAX_MESSAGE_CHARS + 500);
    try std.testing.expectEqual(@as(usize, MAX_MESSAGE_CHARS), truncate(long).len);
}

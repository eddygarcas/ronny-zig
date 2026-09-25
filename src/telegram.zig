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

pub const Error = error{ SendFailed, FileTooLarge };

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

/// A file the owner uploaded. Telegram sends metadata plus a file id; the
/// bytes are fetched separately through getFile, the same as a voice note.
pub const Document = struct {
    file_id: []const u8 = "",
    file_name: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    file_size: u64 = 0,
};

/// A photo arrives as several sizes of the same image, smallest first.
pub const PhotoSize = struct {
    file_id: []const u8 = "",
    file_size: u64 = 0,
};

pub const Chat = struct { id: i64 = 0 };

pub const Message = struct {
    chat: Chat = .{},
    text: ?[]const u8 = null,
    voice: ?Voice = null,
    /// A forwarded audio file behaves the same as a voice note here.
    audio: ?Voice = null,
    /// An uploaded file. `caption` carries any text sent alongside it, which
    /// is how the owner says what the file is for in one message.
    document: ?Document = null,
    /// Telegram strips the filename from photos sent as photos rather than as
    /// files, so these are named on the way out.
    photo: ?[]PhotoSize = null,
    caption: ?[]const u8 = null,
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

        // alloc_always is load-bearing here, not a default worth inheriting.
        // parseFromSlice otherwise uses `.alloc_if_needed`, which leaves
        // unescaped strings pointing *into* `response.body` -- and that is
        // freed on the way out of this function, while the Parsed is handed
        // to the caller. See the test at the bottom of this file.
        const parsed = try std.json.parseFromSlice(UpdatesResponse, arena, response.body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
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

    /// Telegram's documented ceiling for sendDocument on the standard API.
    /// Downloads have their own, lower limit which the docs do not state
    /// plainly, so downloadFile reports Telegram's refusal rather than
    /// second-guessing it with a constant.
    pub const MAX_UPLOAD_BYTES = 50 * 1024 * 1024;

    /// Sends a file to the owner. Used for email attachments.
    ///
    /// JSON cannot carry file contents, so this is the one Telegram call that
    /// goes out as multipart/form-data.
    pub fn sendDocument(
        self: *Client,
        arena: std.mem.Allocator,
        filename: []const u8,
        content_type: []const u8,
        bytes: []const u8,
        caption: []const u8,
    ) !void {
        if (bytes.len > MAX_UPLOAD_BYTES) return Error.FileTooLarge;

        const endpoint = try self.url(arena, "sendDocument");
        var response = http.postMultipart(self.io, arena, endpoint, &.{
            .{ .text = .{ .name = "chat_id", .value = self.owner_chat_id } },
            .{ .text = .{ .name = "caption", .value = truncate(caption) } },
            .{ .file = .{
                .name = "document",
                .filename = filename,
                .content_type = content_type,
                .bytes = bytes,
            } },
        }) catch return Error.SendFailed;
        defer response.deinit(arena);

        if (!response.ok()) {
            log.warn("sendDocument returned {d}: {s}", .{
                @intFromEnum(response.status),
                response.body[0..@min(response.body.len, 200)],
            });
            return Error.SendFailed;
        }
        log.info("sent {s} ({d} bytes) to the owner", .{ filename, bytes.len });
    }

    /// Telegram caps a voice caption at 1024 characters, unlike a message.
    pub const MAX_CAPTION_CHARS = 1000;

    /// Sends a voice message: OGG/Opus bytes that Telegram will show as a
    /// playable bubble, with `caption` as the text beneath it. Used for
    /// summaries when the owner has asked to hear them.
    ///
    /// The caption is what keeps the chat scannable: the sender and subject
    /// stay readable in the list without playing anything.
    pub fn sendVoice(
        self: *Client,
        arena: std.mem.Allocator,
        ogg_opus: []const u8,
        caption: []const u8,
    ) !void {
        if (ogg_opus.len > MAX_UPLOAD_BYTES) return Error.FileTooLarge;

        const endpoint = try self.url(arena, "sendVoice");
        var response = http.postMultipart(self.io, arena, endpoint, &.{
            .{ .text = .{ .name = "chat_id", .value = self.owner_chat_id } },
            .{ .text = .{ .name = "caption", .value = caption[0..@min(caption.len, MAX_CAPTION_CHARS)] } },
            .{ .file = .{
                .name = "voice",
                .filename = "summary.ogg",
                .content_type = "audio/ogg",
                .bytes = ogg_opus,
            } },
        }) catch return Error.SendFailed;
        defer response.deinit(arena);

        if (!response.ok()) {
            log.warn("sendVoice returned {d}: {s}", .{
                @intFromEnum(response.status),
                response.body[0..@min(response.body.len, 200)],
            });
            return Error.SendFailed;
        }
        log.info("sent a voice message ({d} bytes) to the owner", .{ogg_opus.len});
    }

    /// Downloads a voice note. Returns the audio bytes, owned by `arena`.
    pub fn downloadFile(self: *Client, arena: std.mem.Allocator, file_id: []const u8) ![]u8 {
        var payload: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(.{ .file_id = file_id }, .{}, &payload.writer);

        const meta_url = try self.url(arena, "getFile");
        var meta = try http.postJson(self.io, arena, meta_url, payload.writer.buffered(), &.{});
        defer meta.deinit(arena);
        if (!meta.ok()) return Error.SendFailed;

        // Same reason as getUpdates. file_path is only read before meta.body
        // is freed today, but that is an ordering accident, not a guarantee.
        const parsed = try std.json.parseFromSlice(FileResponse, arena, meta.body, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        if (parsed.value.result.file_path.len == 0) {
            log.warn("getFile returned no file_path for {s}: {s}", .{
                file_id, meta.body[0..@min(meta.body.len, 200)],
            });
            return Error.SendFailed;
        }

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

test "a parsed update keeps its own strings once the response body is gone" {
    // The bug this pins: std.json.parseFromSlice defaults to
    // `.alloc_if_needed`, so strings with no escapes point *into* the source
    // buffer. getUpdates frees that buffer and returns the Parsed, so every
    // message text and voice file_id became a dangling pointer. It showed up
    // in production as `owner message: <0xAA repeated>` -- Zig's poison byte
    // -- and as every voice note failing to download, because the file_id
    // handed to getFile was garbage.
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = try arena.dupe(u8,
        \\{"ok":true,"result":[{"update_id":7,"message":{"chat":{"id":42},"text":"hello there","voice":{"file_id":"AwACAgQAA","duration":3}}}]}
    );

    const parsed = try std.json.parseFromSlice(UpdatesResponse, arena, source, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    // Stand in for the response body being freed and its memory reused.
    @memset(source, 0xAA);

    const message = parsed.value.result[0].message.?;
    try std.testing.expectEqualStrings("hello there", message.text.?);
    try std.testing.expectEqualStrings("AwACAgQAA", message.voice.?.file_id);
    try std.testing.expectEqual(@as(i64, 42), message.chat.id);
}

test "truncate leaves short text alone and caps long text" {
    try std.testing.expectEqualStrings("hello", truncate("hello"));

    const long = "x" ** (MAX_MESSAGE_CHARS + 500);
    try std.testing.expectEqual(@as(usize, MAX_MESSAGE_CHARS), truncate(long).len);
}

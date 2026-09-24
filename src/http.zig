//! Thin HTTP helper over `std.http.Client`.
//!
//! Every remote service Ronny talks to -- Telegram, Ollama, TypeSafe -- is
//! HTTPS with a JSON body, so they all funnel through here rather than each
//! module growing its own client handling.
//!
//! 0.16 note: `std.Io.net` is deliberately low level (no `tcpConnectToHost`,
//! and TLS wants entropy and a wall-clock timestamp supplied by hand), but
//! `std.http.Client.fetch` sits above all of that and handles TLS itself.

const std = @import("std");

const log = std.log.scoped(.http);

pub const Error = error{
    RequestFailed,
    HttpStatus,
};

pub const Response = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *Response, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
    }

    pub fn ok(self: *const Response) bool {
        return self.status.class() == .success;
    }
};

/// POSTs `payload` and returns the body. Caller owns `Response.body`.
///
/// A non-2xx status is returned rather than raised: callers generally want to
/// see the body, since both Telegram and Ollama explain failures in it.
pub fn postJson(
    io: std.Io,
    gpa: std.mem.Allocator,
    url: []const u8,
    payload: []const u8,
    extra_headers: []const std.http.Header,
) !Response {
    return send(io, gpa, .POST, url, payload, extra_headers);
}

pub fn get(io: std.Io, gpa: std.mem.Allocator, url: []const u8) !Response {
    return send(io, gpa, .GET, url, null, &.{});
}

fn send(
    io: std.Io,
    gpa: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    extra_headers: []const std.http.Header,
) !Response {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .headers = .{ .content_type = if (payload != null) .{ .override = "application/json" } else .default },
        .extra_headers = extra_headers,
        .response_writer = &body.writer,
    }) catch |err| {
        log.warn("{s} {s} failed: {s}", .{ @tagName(method), redact(url), @errorName(err) });
        body.deinit();
        return Error.RequestFailed;
    };

    return .{ .status = result.status, .body = try body.toOwnedSlice() };
}

/// Bot tokens and API keys travel in URLs (Telegram puts the token in the
/// path), so anything logged has to be stripped first.
pub fn redact(url: []const u8) []const u8 {
    if (std.mem.indexOf(u8, url, "/bot")) |idx| {
        const after = url[idx + 4 ..];
        if (std.mem.indexOfScalar(u8, after, '/')) |slash| {
            _ = slash;
            return url[0 .. idx + 4];
        }
    }
    return url;
}

test "redact strips a telegram bot token from a url" {
    const redacted = redact("https://api.telegram.org/bot123456:SECRET/sendMessage");
    try std.testing.expectEqualStrings("https://api.telegram.org/bot", redacted);

    // URLs without a token are left alone.
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:11434/api/generate",
        redact("http://127.0.0.1:11434/api/generate"),
    );
}

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

/// One part of a multipart/form-data body.
pub const FormPart = union(enum) {
    text: struct { name: []const u8, value: []const u8 },
    file: struct {
        name: []const u8,
        filename: []const u8,
        content_type: []const u8,
        bytes: []const u8,
    },
};

/// Assembles an RFC 7578 body. Split out from the request so the part with
/// actual rules in it -- framing, CRLFs, the trailing `--` -- is reachable
/// from a test rather than only from a live Telegram call.
fn writeMultipartBody(
    writer: *std.Io.Writer,
    boundary: []const u8,
    parts: []const FormPart,
) !void {
    for (parts) |part| {
        try writer.print("--{s}\r\n", .{boundary});
        switch (part) {
            .text => |field| try writer.print(
                "Content-Disposition: form-data; name=\"{s}\"\r\n\r\n{s}\r\n",
                .{ field.name, field.value },
            ),
            .file => |field| {
                try writer.print(
                    "Content-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\n" ++
                        "Content-Type: {s}\r\n\r\n",
                    .{ field.name, field.filename, field.content_type },
                );
                // Written raw: form-data carries bytes, not text, so no
                // encoding or escaping happens here.
                try writer.writeAll(field.bytes);
                try writer.writeAll("\r\n");
            },
        }
    }
    // The closing delimiter is the one with trailing dashes.
    try writer.print("--{s}--\r\n", .{boundary});
}

/// POSTs multipart/form-data. Telegram's sendDocument needs this; its JSON
/// endpoints cannot carry file contents.
///
/// The whole body is assembled in memory, so the caller is responsible for
/// not handing this something enormous.
pub fn postMultipart(
    io: std.Io,
    gpa: std.mem.Allocator,
    url: []const u8,
    parts: []const FormPart,
) !Response {
    // Random, because the boundary must not appear anywhere in the payload
    // and file bytes are arbitrary. 128 bits of hex makes that a non-issue.
    // 0.16 has no std.crypto.random; entropy comes from Io.
    var raw: [16]u8 = undefined;
    io.random(&raw);
    var boundary: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&boundary, "{x}", .{&raw}) catch unreachable;

    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try writeMultipartBody(&body.writer, &boundary, parts);

    const content_type = try std.fmt.allocPrint(
        gpa,
        "multipart/form-data; boundary={s}",
        .{&boundary},
    );
    defer gpa.free(content_type);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(gpa);
    errdefer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body.writer.buffered(),
        .headers = .{ .content_type = .{ .override = content_type } },
        .response_writer = &response_body.writer,
    }) catch |err| {
        log.warn("multipart POST {s} failed: {s}", .{ redact(url), @errorName(err) });
        response_body.deinit();
        return Error.RequestFailed;
    };

    return .{ .status = result.status, .body = try response_body.toOwnedSlice() };
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

test "multipart body framing" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    // Deliberately includes a NUL and a CR: form-data carries bytes, and
    // nothing here may transform them.
    const payload = "PDF\x00\r binary";
    try writeMultipartBody(&out.writer, "BOUND", &.{
        .{ .text = .{ .name = "chat_id", .value = "42" } },
        .{ .file = .{
            .name = "document",
            .filename = "invoice.pdf",
            .content_type = "application/pdf",
            .bytes = payload,
        } },
    });

    try std.testing.expectEqualStrings(
        "--BOUND\r\n" ++
            "Content-Disposition: form-data; name=\"chat_id\"\r\n\r\n42\r\n" ++
            "--BOUND\r\n" ++
            "Content-Disposition: form-data; name=\"document\"; filename=\"invoice.pdf\"\r\n" ++
            "Content-Type: application/pdf\r\n\r\n" ++
            payload ++ "\r\n" ++
            "--BOUND--\r\n",
        out.writer.buffered(),
    );
}

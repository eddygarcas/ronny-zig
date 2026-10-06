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
    return send(io, gpa, .POST, url, payload, "application/json", extra_headers);
}

/// POSTs an already-encoded `application/x-www-form-urlencoded` body. OAuth
/// token endpoints take this shape and refuse JSON.
pub fn postForm(
    io: std.Io,
    gpa: std.mem.Allocator,
    url: []const u8,
    payload: []const u8,
    extra_headers: []const std.http.Header,
) !Response {
    return send(io, gpa, .POST, url, payload, "application/x-www-form-urlencoded", extra_headers);
}

pub fn get(io: std.Io, gpa: std.mem.Allocator, url: []const u8) !Response {
    return send(io, gpa, .GET, url, null, "", &.{});
}

/// DELETE with headers. Google answers a successful delete with an empty
/// 204, so the body is usually nothing.
pub fn delete(
    io: std.Io,
    gpa: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const std.http.Header,
) !Response {
    return send(io, gpa, .DELETE, url, null, "", extra_headers);
}

pub fn getWithHeaders(
    io: std.Io,
    gpa: std.mem.Allocator,
    url: []const u8,
    extra_headers: []const std.http.Header,
) !Response {
    return send(io, gpa, .GET, url, null, "", extra_headers);
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

    const result = fetch(&client, .{
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

/// TCP keepalive timings for every request socket. A peer that vanishes
/// without closing is given up on after IDLE + INTERVAL * PROBES = 120s.
///
/// What broke: on 2026-10-05 the bot logged nothing from 16:54 for fifteen
/// hours -- no polls, no calendar refreshes, no reminders -- while the process
/// sat asleep in the kernel's `wait_woken`, a blocking socket read.
/// `std.http.Client` has no read timeout (the `timeout` in its connect options
/// is declared and never used), so a connection that dies silently mid-poll
/// is waited on forever. Linux's own keepalive defaults are 7200s idle, then
/// 9 probes 75s apart, so it is effectively off.
///
/// Why keepalive and not a read timeout: a probe is answered by the peer's
/// kernel, so a slow but live server -- Ollama thinking for a minute, a
/// Telegram long poll -- is left alone, and only a dead one is dropped. The
/// read then fails with ETIMEDOUT, which `std.Io` maps to `error.Timeout`, and
/// the callers' existing retry paths take it from there. SO_RCVTIMEO would
/// instead surface as EAGAIN, which `std.Io.Threaded`'s netReadPosix treats
/// as an errno bug.
///
/// Option meanings and defaults from tcp(7) and socket(7):
/// https://man7.org/linux/man-pages/man7/tcp.7.html
/// https://man7.org/linux/man-pages/man7/socket.7.html
/// A request already sent into a dead connection is covered by retransmission
/// instead (tcp_retries2, "approximately between 13 to 30 minutes" per tcp(7)),
/// which already ends in ETIMEDOUT; keepalive is for the idle wait after it.
const KEEPALIVE_IDLE_SECONDS: i32 = 60;
const KEEPALIVE_INTERVAL_SECONDS: i32 = 10;
const KEEPALIVE_PROBES: i32 = 6;

fn keepDeadPeersFromHanging(fd: std.posix.socket_t) !void {
    const posix = std.posix;
    const on: i32 = 1;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.KEEPALIVE, std.mem.asBytes(&on));
    try posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPIDLE, std.mem.asBytes(&KEEPALIVE_IDLE_SECONDS));
    try posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPINTVL, std.mem.asBytes(&KEEPALIVE_INTERVAL_SECONDS));
    try posix.setsockopt(fd, posix.IPPROTO.TCP, posix.TCP.KEEPCNT, std.mem.asBytes(&KEEPALIVE_PROBES));
}

/// `std.http.Client.fetch` from Zig 0.16 (lib/std/http/Client.zig), step for
/// step, with one addition: keepalive on the socket once `request` has
/// connected. `fetch` gives no way to reach the connection, and connecting
/// by hand first would skip the CA bundle load that `request` does before it
/// connects. Every call here makes a fresh Client, so every request gets a
/// fresh socket and the setting is never missed through pooling. A redirect
/// to another host would open a connection without it -- no worse than
/// before, and none of the services Ronny calls redirects.
fn fetch(client: *std.http.Client, options: std.http.Client.FetchOptions) std.http.Client.FetchError!std.http.Client.FetchResult {
    const uri = switch (options.location) {
        .url => |u| try std.Uri.parse(u),
        .uri => |u| u,
    };
    const method: std.http.Method = options.method orelse
        if (options.payload != null) .POST else .GET;

    const redirect_behavior: std.http.Client.Request.RedirectBehavior = options.redirect_behavior orelse
        if (options.payload == null) @enumFromInt(3) else .unhandled;

    var req = try client.request(method, uri, .{
        .redirect_behavior = redirect_behavior,
        .headers = options.headers,
        .extra_headers = options.extra_headers,
        .privileged_headers = options.privileged_headers,
        .keep_alive = options.keep_alive,
    });
    defer req.deinit();

    // The one line that is not upstream. Best effort: a socket without
    // keepalive is what every request had before, so it is not worth failing
    // the request over.
    keepDeadPeersFromHanging(req.connection.?.stream_reader.stream.socket.handle) catch |err| {
        log.warn("could not enable keepalive on a request socket: {s}", .{@errorName(err)});
    };

    if (options.payload) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var body = try req.sendBodyUnflushed(&.{});
        try body.writer.writeAll(payload);
        try body.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    const redirect_buffer: []u8 = if (redirect_behavior == .unhandled) &.{} else options.redirect_buffer orelse
        try client.allocator.alloc(u8, 8 * 1024);
    defer if (options.redirect_buffer == null) client.allocator.free(redirect_buffer);

    var response = try req.receiveHead(redirect_buffer);

    const response_writer = options.response_writer orelse {
        const reader = response.reader(&.{});
        _ = reader.discardRemaining() catch |err| switch (err) {
            error.ReadFailed => return response.bodyErr().?,
        };
        return .{ .status = response.head.status };
    };

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => options.decompress_buffer orelse try client.allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => options.decompress_buffer orelse try client.allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (options.decompress_buffer == null) client.allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);

    _ = reader.streamRemaining(response_writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };

    return .{ .status = response.head.status };
}

fn send(
    io: std.Io,
    gpa: std.mem.Allocator,
    method: std.http.Method,
    url: []const u8,
    payload: ?[]const u8,
    content_type: []const u8,
    extra_headers: []const std.http.Header,
) !Response {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();

    const result = fetch(&client, .{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .headers = .{ .content_type = if (payload != null) .{ .override = content_type } else .default },
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

test "a request socket notices a dead peer within minutes, not never" {
    // The bot sat in a read for 15 hours (2026-10-05 16:54 onward, process
    // asleep in wait_woken) because nothing on its sockets could time out.
    // This checks the socket really carries the settings, read back from the
    // kernel rather than trusted from the setsockopt calls.
    const linux = std.os.linux;
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0);
    try std.testing.expect(linux.errno(rc) == .SUCCESS);
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);

    try keepDeadPeersFromHanging(fd);

    const Expect = struct { level: i32, name: u32, want: i32 };
    for ([_]Expect{
        .{ .level = linux.SOL.SOCKET, .name = linux.SO.KEEPALIVE, .want = 1 },
        .{ .level = linux.IPPROTO.TCP, .name = linux.TCP.KEEPIDLE, .want = KEEPALIVE_IDLE_SECONDS },
        .{ .level = linux.IPPROTO.TCP, .name = linux.TCP.KEEPINTVL, .want = KEEPALIVE_INTERVAL_SECONDS },
        .{ .level = linux.IPPROTO.TCP, .name = linux.TCP.KEEPCNT, .want = KEEPALIVE_PROBES },
    }) |e| {
        var value: i32 = 0;
        var len: linux.socklen_t = @sizeOf(i32);
        const got = linux.getsockopt(fd, e.level, e.name, @ptrCast(&value), &len);
        try std.testing.expect(linux.errno(got) == .SUCCESS);
        try std.testing.expectEqual(e.want, value);
    }

    // The whole point: a vanished peer is given up on in a few minutes.
    try std.testing.expect(KEEPALIVE_IDLE_SECONDS + KEEPALIVE_INTERVAL_SECONDS * KEEPALIVE_PROBES <= 180);
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

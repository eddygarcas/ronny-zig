//! Google Calendar: the one door to the owner's calendar.
//!
//! Two jobs, kept decision-free the way mailer.zig is:
//!
//! - **Getting in.** Gmail's app password does not open the Calendar API;
//!   only OAuth does, and Google no longer accepts the copy-the-code flow, so
//!   `ronny calendar-auth` runs the loopback variant once: it prints a URL,
//!   listens on 127.0.0.1, and swaps the code the browser brings back for a
//!   refresh token that is kept on disk. Every later request mints a
//!   short-lived access token from that.
//!
//! - **Creating an event.** One POST, with the event exactly as the owner
//!   approved it in chat. No attendees, ever: an attendee is an invitation
//!   email to a third party, which is a send, and sends live behind the
//!   reply gate in bot.zig, not here.
//!
//! Everything about the wire format below is from Google's own pages, not
//! memory, and each is named beside the value it justifies so it can be
//! re-checked. See docs/working-on-ronny.md on why.

const std = @import("std");
const http = @import("http.zig");

const log = std.log.scoped(.gcal);

/// https://developers.google.com/identity/protocols/oauth2/native-app
const AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
/// The narrowest scope that can create an event on a calendar the owner
/// owns: "See, create, change, and delete events on Google calendars you
/// own." https://developers.google.com/workspace/calendar/api/auth
pub const SCOPE = "https://www.googleapis.com/auth/calendar.events.owned";
/// https://developers.google.com/workspace/calendar/api/v3/reference/events/insert
const EVENTS_ENDPOINT = "https://www.googleapis.com/calendar/v3/calendars";

/// An access token is good for an hour; one that expires mid-request is
/// refreshed a little early rather than retried.
const EXPIRY_MARGIN_SECONDS = 60;

pub const Config = struct {
    client_id: []const u8,
    /// Google issues one even to desktop clients and the token endpoint
    /// expects it back. Empty is allowed for a client type that has none.
    client_secret: []const u8 = "",
    /// Where the refresh token lives. Written once by `authorize`, read by
    /// every request after.
    token_path: []const u8,
    /// "primary" is the owner's own calendar.
    calendar_id: []const u8 = "primary",
    /// IANA name, e.g. Europe/Madrid. Sent with every event so a naive local
    /// time means what the owner meant.
    timezone: []const u8,
    /// The loopback port the one-time login listens on. Fixed rather than
    /// random so the address can be told to the owner in advance.
    auth_port: u16 = 8765,
};

pub const Error = error{
    /// No refresh token on disk: `ronny calendar-auth` has not been run.
    NotAuthorized,
    /// Google refused the refresh token. Revoked, expired (a consent screen
    /// left in "Testing" issues 7-day tokens), or the client changed.
    TokenRevoked,
    RequestFailed,
    BadResponse,
    OutOfMemory,
};

/// A minute-precise local time, or a whole day.
pub const Event = struct {
    title: []const u8,
    location: []const u8 = "",
    description: []const u8 = "",
    year: u16,
    month: u8,
    day: u8,
    /// Minutes since local midnight. Null means all-day, and `end_minutes`
    /// is then ignored.
    start_minutes: ?i16,
    end_minutes: i16 = 0,
};

pub const Created = struct {
    id: []const u8,
    html_link: []const u8,
};

/// One entry on a day, as shown to the owner. The id is what a removal
/// names, and it only ever comes from here -- a listing Google returned --
/// never from anything a model produced.
pub const Listed = struct {
    id: []const u8,
    title: []const u8,
    location: []const u8,
    /// Minutes since local midnight; null for an all-day entry.
    start_minutes: ?i16,
    end_minutes: ?i16,
    /// Where to join, if this entry has a video link; see `meetingLink`.
    /// Empty when it has none.
    link: []const u8 = "",
    /// The entry's description as plain text -- Google allows HTML in it --
    /// which is where an agenda lives when there is one. Empty when unset.
    description: []const u8 = "",
};

/// The offset in force at a local wall-clock time, from libc. See shim.c.
extern fn ronny_utc_offset_minutes(year: c_int, month: c_int, day: c_int, hour: c_int, minute: c_int) c_int;

// ---- the token on disk ----

const Stored = struct {
    refresh_token: []const u8,
    access_token: []const u8 = "",
    /// Unix seconds.
    expires_at: i64 = 0,
};

fn loadStored(io: std.Io, gpa: std.mem.Allocator, path: []const u8) Error!std.json.Parsed(Stored) {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch |err| {
        if (err == error.FileNotFound) return Error.NotAuthorized;
        log.warn("could not read {s} ({s})", .{ path, @errorName(err) });
        return Error.NotAuthorized;
    };
    defer gpa.free(bytes);
    // Copied out: the file buffer is freed on return. See toolchain.md.
    return std.json.parseFromSlice(Stored, gpa, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        log.warn("{s} is not a token file; run `ronny calendar-auth` again", .{path});
        return Error.NotAuthorized;
    };
}

fn saveStored(io: std.Io, gpa: std.mem.Allocator, path: []const u8, stored: Stored) !void {
    var buffer: std.Io.Writer.Allocating = .init(gpa);
    defer buffer.deinit();
    try std.json.Stringify.value(stored, .{}, &buffer.writer);

    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buffer.writer.buffered() });
}

fn nowSeconds(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
}

// ---- form encoding ----

fn isUnreserved(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.' or ch == '~';
}

/// RFC 3986 percent-encoding of one value, strict enough for both a query
/// string and a form body. Spaces become %20 rather than '+' so the same
/// encoder serves both.
pub fn encodeComponent(writer: *std.Io.Writer, raw: []const u8) !void {
    for (raw) |ch| {
        if (isUnreserved(ch)) {
            try writer.writeByte(ch);
        } else {
            try writer.print("%{X:0>2}", .{ch});
        }
    }
}

const Pair = struct { []const u8, []const u8 };

fn encodeForm(arena: std.mem.Allocator, pairs: []const Pair) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (pairs, 0..) |pair, i| {
        if (i > 0) try out.writer.writeByte('&');
        try encodeComponent(&out.writer, pair[0]);
        try out.writer.writeByte('=');
        try encodeComponent(&out.writer, pair[1]);
    }
    return out.written();
}

fn decodeComponent(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const ch = raw[i];
        if (ch == '%' and i + 2 < raw.len) {
            if (std.fmt.parseInt(u8, raw[i + 1 .. i + 3], 16)) |value| {
                try out.append(arena, value);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(arena, if (ch == '+') ' ' else ch);
    }
    return out.items;
}

/// The value of `key` in a query string, or null.
pub fn queryValue(arena: std.mem.Allocator, query: []const u8, key: []const u8) !?[]const u8 {
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (std.mem.eql(u8, part[0..eq], key)) return try decodeComponent(arena, part[eq + 1 ..]);
    }
    return null;
}

// ---- tokens ----

const TokenResponse = struct {
    access_token: []const u8 = "",
    expires_in: i64 = 3600,
    refresh_token: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    error_description: ?[]const u8 = null,
};

fn postToken(io: std.Io, arena: std.mem.Allocator, pairs: []const Pair) Error!TokenResponse {
    const body = encodeForm(arena, pairs) catch return Error.OutOfMemory;
    var response = http.postForm(io, arena, TOKEN_ENDPOINT, body, &.{}) catch return Error.RequestFailed;
    defer response.deinit(arena);

    const parsed = std.json.parseFromSlice(TokenResponse, arena, response.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        log.warn("token endpoint returned {d} and no JSON", .{@intFromEnum(response.status)});
        return Error.BadResponse;
    };
    const token = parsed.value;

    if (!response.ok() or token.@"error" != null) {
        const code = token.@"error" orelse "";
        log.warn("token endpoint returned {d}: {s} {s}", .{
            @intFromEnum(response.status), code, token.error_description orelse "",
        });
        // Google's word for "this refresh token is dead", whatever the cause.
        if (std.mem.eql(u8, code, "invalid_grant")) return Error.TokenRevoked;
        return Error.RequestFailed;
    }
    if (token.access_token.len == 0) return Error.BadResponse;
    return token;
}

/// A valid access token, refreshed from disk when the cached one is stale.
/// Owned by `arena`.
fn accessToken(io: std.Io, arena: std.mem.Allocator, cfg: Config) Error![]const u8 {
    const stored = try loadStored(io, arena, cfg.token_path);
    defer stored.deinit();

    if (stored.value.access_token.len > 0 and stored.value.expires_at > nowSeconds(io) + EXPIRY_MARGIN_SECONDS) {
        return arena.dupe(u8, stored.value.access_token) catch Error.OutOfMemory;
    }

    // https://developers.google.com/identity/protocols/oauth2/native-app,
    // "Refreshing an access token".
    var pairs: [4]Pair = .{
        .{ "client_id", cfg.client_id },
        .{ "client_secret", cfg.client_secret },
        .{ "grant_type", "refresh_token" },
        .{ "refresh_token", stored.value.refresh_token },
    };
    const fresh = try postToken(io, arena, if (cfg.client_secret.len > 0) &pairs else &.{ pairs[0], pairs[2], pairs[3] });

    saveStored(io, arena, cfg.token_path, .{
        .refresh_token = stored.value.refresh_token,
        .access_token = fresh.access_token,
        .expires_at = nowSeconds(io) + fresh.expires_in,
    }) catch |err| {
        // Not fatal: the token works for this request, it just gets minted
        // again next time.
        log.warn("could not cache the access token in {s} ({s})", .{ cfg.token_path, @errorName(err) });
    };
    log.info("refreshed the calendar access token", .{});
    return fresh.access_token;
}

/// Whether a login exists on disk. Says nothing about whether Google still
/// honours it; that is only known when a request is made.
pub fn isAuthorized(io: std.Io, gpa: std.mem.Allocator, cfg: Config) bool {
    const stored = loadStored(io, gpa, cfg.token_path) catch return false;
    stored.deinit();
    return true;
}

/// Mints an access token and throws it away: a cheap way for the probe to
/// prove the login still works without writing anything to the calendar.
pub fn check(io: std.Io, gpa: std.mem.Allocator, cfg: Config) Error!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    _ = try accessToken(io, arena_state.allocator(), cfg);
}

// ---- events ----

const Moment = struct {
    dateTime: ?[]const u8 = null,
    timeZone: ?[]const u8 = null,
    date: ?[]const u8 = null,
};

const EventBody = struct {
    summary: []const u8,
    location: ?[]const u8,
    description: ?[]const u8,
    start: Moment,
    end: Moment,
};

fn clockText(arena: std.mem.Allocator, event: Event, minutes: i16) ![]const u8 {
    // Unsigned, or the zero padding prints a sign: "+15:+0".
    const hours: u8 = @intCast(@divTrunc(minutes, 60));
    const mins: u8 = @intCast(@mod(minutes, 60));
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:00", .{
        event.year, event.month, event.day, hours, mins,
    });
}

/// Days since 1970-01-01 for the all-day end, which Google takes as
/// exclusive: a one-day event ends on the following date.
fn nextDate(arena: std.mem.Allocator, event: Event) ![]const u8 {
    const dates = @import("dates.zig");
    const next = (dates.Day{ .year = event.year, .month = event.month, .day = event.day }).shift(1);
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ next.year, next.month, next.day });
}

/// The request body, split out so the shape that Google actually receives
/// is reachable from a test.
pub fn eventJson(arena: std.mem.Allocator, timezone: []const u8, event: Event) ![]const u8 {
    // Google reads `"timeZone":""` as no time zone and refuses the event.
    // main.zig never passes an empty one, but this is the one place the
    // rule is actually enforced.
    if (timezone.len == 0 and event.start_minutes != null) return error.MissingTimezone;
    var body: EventBody = .{
        .summary = event.title,
        .location = if (event.location.len > 0) event.location else null,
        .description = if (event.description.len > 0) event.description else null,
        .start = .{},
        .end = .{},
    };
    if (event.start_minutes) |start| {
        // "A time zone offset is required unless a time zone is explicitly
        // specified in timeZone" -- the reference above. So the local clock
        // time goes as written, with the zone beside it.
        body.start = .{ .dateTime = try clockText(arena, event, start), .timeZone = timezone };
        body.end = .{ .dateTime = try clockText(arena, event, event.end_minutes), .timeZone = timezone };
    } else {
        body.start = .{ .date = try std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ event.year, event.month, event.day }) };
        body.end = .{ .date = try nextDate(arena, event) };
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(body, .{ .emit_null_optional_fields = false }, &out.writer);
    return out.written();
}

const InsertResponse = struct {
    id: []const u8 = "",
    htmlLink: []const u8 = "",
};

/// Creates `event` on the configured calendar. Borrows from `arena`.
pub fn insert(io: std.Io, arena: std.mem.Allocator, cfg: Config, event: Event) Error!Created {
    const token = try accessToken(io, arena, cfg);

    var url: std.Io.Writer.Allocating = .init(arena);
    url.writer.print("{s}/", .{EVENTS_ENDPOINT}) catch return Error.OutOfMemory;
    encodeComponent(&url.writer, cfg.calendar_id) catch return Error.OutOfMemory;
    url.writer.writeAll("/events") catch return Error.OutOfMemory;

    const body = eventJson(arena, cfg.timezone, event) catch |err| {
        if (err == error.MissingTimezone) {
            log.err("no time zone configured; set CALENDAR_TIMEZONE or fix /etc/localtime", .{});
            return Error.RequestFailed;
        }
        return Error.OutOfMemory;
    };
    const auth = std.fmt.allocPrint(arena, "Bearer {s}", .{token}) catch return Error.OutOfMemory;

    var response = http.postJson(io, arena, url.written(), body, &.{
        .{ .name = "Authorization", .value = auth },
    }) catch return Error.RequestFailed;
    defer response.deinit(arena);

    if (!response.ok()) {
        log.warn("events.insert returned {d}: {s}", .{
            @intFromEnum(response.status), response.body[0..@min(response.body.len, 300)],
        });
        return Error.RequestFailed;
    }

    const parsed = std.json.parseFromSlice(InsertResponse, arena, response.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return Error.BadResponse;
    if (parsed.value.id.len == 0) return Error.BadResponse;
    return .{ .id = parsed.value.id, .html_link = parsed.value.htmlLink };
}

// ---- listing a day ----

/// RFC 3339 for a local midnight, with the offset libc says applies on
/// that day: the list call refuses a timestamp without one.
fn dayBoundary(arena: std.mem.Allocator, year: u16, month: u8, day: u8) ![]const u8 {
    const offset = ronny_utc_offset_minutes(year, month, day, 0, 0);
    const sign: u8 = if (offset < 0) '-' else '+';
    const magnitude: u16 = @intCast(if (offset < 0) -offset else offset);
    const oh: u8 = @intCast(magnitude / 60);
    const om: u8 = @intCast(magnitude % 60);
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T00:00:00{c}{d:0>2}:{d:0>2}", .{
        year, month, day, sign, oh, om,
    });
}

const ListedMoment = struct {
    dateTime: ?[]const u8 = null,
    date: ?[]const u8 = null,
};

// https://developers.google.com/workspace/calendar/api/v3/reference/events
// "hangoutLink: An absolute link to the Google Hangout associated with this
// event. Read-only." "description: Description of the event. Can contain
// HTML." A conference has "zero or one video entry point", whose uri has an
// http: or https: scheme; phone and sip entry points are not links.
const EntryPoint = struct {
    entryPointType: ?[]const u8 = null,
    uri: ?[]const u8 = null,
};

const ConferenceData = struct {
    entryPoints: []const EntryPoint = &.{},
};

const ListedItem = struct {
    id: ?[]const u8 = null,
    status: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    location: ?[]const u8 = null,
    description: ?[]const u8 = null,
    hangoutLink: ?[]const u8 = null,
    conferenceData: ?ConferenceData = null,
    start: ListedMoment = .{},
    end: ListedMoment = .{},
};

const ListResponse = struct {
    items: []const ListedItem = &.{},
};

/// "2026-10-01T15:00:00+02:00" -> minutes since midnight, from the clock
/// as written. The response is asked for in the calendar's own zone, so the
/// clock is already the local one.
fn minutesOf(date_time: []const u8) ?i16 {
    if (date_time.len < 16 or date_time[10] != 'T' or date_time[13] != ':') return null;
    const hours = std.fmt.parseInt(i16, date_time[11..13], 10) catch return null;
    const minutes = std.fmt.parseInt(i16, date_time[14..16], 10) catch return null;
    if (hours > 23 or minutes > 59) return null;
    return hours * 60 + minutes;
}

/// Hosts whose links are, in practice, always a place to join a call. A
/// description is full of links -- documents, tickets, unsubscribe pages --
/// so only one of these counts as a meeting link there. The location field
/// is different: a link put where the *place* goes is the place.
const MEETING_HOSTS = [_][]const u8{
    "meet.google.com",
    "zoom.us",
    "teams.microsoft.com",
    "teams.live.com",
    "webex.com",
    "whereby.com",
    "meet.jit.si",
    "gotomeeting.com",
    "gotomeet.me",
    "bluejeans.com",
};

/// The link to join this entry's call, or empty when it has none.
///
/// In order of how reliable each source is: Google's own Meet link, then
/// the video entry point of an add-on conference (Zoom, Teams and the like
/// register there), then a link in the location, then a link to a known
/// meeting host in the description. Never anything else in the description:
/// "has a meeting link" is what decides whether the owner gets a reminder,
/// and a link to the agenda document is not a reason to be reminded.
fn meetingLink(item: ListedItem) []const u8 {
    if (item.hangoutLink) |link| {
        if (isHttp(link)) return link;
    }
    if (item.conferenceData) |conference| {
        for (conference.entryPoints) |point| {
            const kind = point.entryPointType orelse continue;
            if (!std.mem.eql(u8, kind, "video")) continue;
            const uri = point.uri orelse continue;
            if (isHttp(uri)) return uri;
        }
    }
    if (item.location) |location| {
        if (firstLink(location, false)) |link| return link;
    }
    if (item.description) |description| {
        if (firstLink(description, true)) |link| return link;
    }
    return "";
}

fn isHttp(text: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(text, "https://") or std.ascii.startsWithIgnoreCase(text, "http://");
}

/// The first http(s) link in `text`, ending at whitespace or at anything
/// that closes an HTML attribute or a sentence. With `known_only`, only a
/// link to one of MEETING_HOSTS qualifies and the rest are skipped.
pub fn firstLink(text: []const u8, known_only: bool) ?[]const u8 {
    var from: usize = 0;
    while (from < text.len) {
        const at = std.ascii.indexOfIgnoreCasePos(text, from, "http") orelse return null;
        const rest = text[at..];
        if (!isHttp(rest)) {
            from = at + 4;
            continue;
        }
        var end: usize = 0;
        while (end < rest.len) : (end += 1) {
            const c = rest[end];
            if (std.ascii.isWhitespace(c) or c == '"' or c == '\'' or c == '<' or c == '>' or c == ')' or c == ']') break;
        }
        // A link at the end of a sentence carries the full stop with it.
        while (end > 0 and (rest[end - 1] == '.' or rest[end - 1] == ',' or rest[end - 1] == ';')) end -= 1;
        const link = rest[0..end];
        if (!known_only or isMeetingHost(link)) return link;
        from = at + end;
    }
    return null;
}

fn isMeetingHost(link: []const u8) bool {
    const after_scheme = (std.mem.indexOf(u8, link, "://") orelse return false) + 3;
    var host_end = after_scheme;
    while (host_end < link.len and link[host_end] != '/' and link[host_end] != ':' and link[host_end] != '?') host_end += 1;
    const host = link[after_scheme..host_end];
    for (MEETING_HOSTS) |known| {
        if (std.ascii.eqlIgnoreCase(host, known)) return true;
        if (host.len > known.len and host[host.len - known.len - 1] == '.' and
            std.ascii.eqlIgnoreCase(host[host.len - known.len ..], known)) return true;
    }
    return false;
}

/// A description as text: tags dropped, the ones that break a line kept as
/// a newline, the common entities decoded, runs of blank lines folded. Good
/// enough for a summary to read; nothing here is shown verbatim except in
/// the journal.
pub fn plainText(arena: std.mem.Allocator, html: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, html, '<') == null and std.mem.indexOfScalar(u8, html, '&') == null) {
        return std.mem.trim(u8, html, " \t\r\n");
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    var i: usize = 0;
    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            const close = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
            const tag = html[i + 1 .. close];
            var name_end: usize = 0;
            while (name_end < tag.len and (std.ascii.isAlphanumeric(tag[name_end]) or tag[name_end] == '/')) name_end += 1;
            const name = tag[0..name_end];
            if (std.ascii.eqlIgnoreCase(name, "br") or std.ascii.eqlIgnoreCase(name, "br/") or
                std.ascii.eqlIgnoreCase(name, "/p") or std.ascii.eqlIgnoreCase(name, "/div") or
                std.ascii.eqlIgnoreCase(name, "/li") or std.ascii.eqlIgnoreCase(name, "/tr") or
                std.ascii.eqlIgnoreCase(name, "/h1") or std.ascii.eqlIgnoreCase(name, "/h2") or
                std.ascii.eqlIgnoreCase(name, "/h3"))
            {
                try out.writer.writeByte('\n');
            } else if (std.ascii.eqlIgnoreCase(name, "li")) {
                try out.writer.writeAll("- ");
            }
            i = close + 1;
            continue;
        }
        if (c == '&') {
            const entities = [_]struct { name: []const u8, text: []const u8 }{
                .{ .name = "&amp;", .text = "&" },   .{ .name = "&lt;", .text = "<" },
                .{ .name = "&gt;", .text = ">" },    .{ .name = "&quot;", .text = "\"" },
                .{ .name = "&#39;", .text = "'" },   .{ .name = "&apos;", .text = "'" },
                .{ .name = "&nbsp;", .text = " " },  .{ .name = "&#160;", .text = " " },
            };
            var matched = false;
            for (entities) |entity| {
                if (std.mem.startsWith(u8, html[i..], entity.name)) {
                    try out.writer.writeAll(entity.text);
                    i += entity.name.len;
                    matched = true;
                    break;
                }
            }
            if (matched) continue;
        }
        try out.writer.writeByte(c);
        i += 1;
    }
    // Fold the blank-line padding that HTML descriptions carry.
    var folded: std.Io.Writer.Allocating = .init(arena);
    var blank_run: usize = 0;
    var wrote_any = false;
    var lines = std.mem.splitScalar(u8, out.written(), '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) {
            blank_run += 1;
            continue;
        }
        if (wrote_any) try folded.writer.writeAll(if (blank_run > 0) "\n\n" else "\n");
        blank_run = 0;
        try folded.writer.writeAll(line);
        wrote_any = true;
    }
    return folded.written();
}

/// Turns the response body into entries. Split from the request so the
/// shape Google actually sends is reachable from a test.
pub fn parseListing(arena: std.mem.Allocator, body: []const u8, day_text: []const u8) ![]const Listed {
    const parsed = try std.json.parseFromSlice(ListResponse, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    var out: std.ArrayList(Listed) = .empty;
    for (parsed.value.items) |item| {
        if (item.status) |status| {
            if (std.mem.eql(u8, status, "cancelled")) continue;
        }
        var entry: Listed = .{
            .id = item.id orelse "",
            .title = item.summary orelse "(no title)",
            .location = item.location orelse "",
            .start_minutes = null,
            .end_minutes = null,
            .link = meetingLink(item),
            .description = try plainText(arena, item.description orelse ""),
        };
        if (item.start.dateTime) |start| {
            entry.start_minutes = minutesOf(start);
            // An entry that started on an earlier day runs from midnight
            // as far as this day is concerned.
            if (!std.mem.startsWith(u8, start, day_text)) entry.start_minutes = 0;
            if (item.end.dateTime) |end| {
                entry.end_minutes = if (std.mem.startsWith(u8, end, day_text)) minutesOf(end) else 24 * 60;
            }
        }
        try out.append(arena, entry);
    }
    return out.items;
}

/// Everything on `day`, in start order. Borrows from `arena`.
pub fn list(io: std.Io, arena: std.mem.Allocator, cfg: Config, year: u16, month: u8, day: u8) Error![]const Listed {
    const token = try accessToken(io, arena, cfg);

    const dates = @import("dates.zig");
    const next = (dates.Day{ .year = year, .month = month, .day = day }).shift(1);
    const time_min = dayBoundary(arena, year, month, day) catch return Error.OutOfMemory;
    const time_max = dayBoundary(arena, next.year, next.month, next.day) catch return Error.OutOfMemory;
    const day_text = std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day }) catch return Error.OutOfMemory;

    // https://developers.google.com/workspace/calendar/api/v3/reference/events/list
    // singleEvents expands recurring entries into the instance on this day;
    // orderBy=startTime is only allowed together with it.
    var url: std.Io.Writer.Allocating = .init(arena);
    url.writer.print("{s}/", .{EVENTS_ENDPOINT}) catch return Error.OutOfMemory;
    encodeComponent(&url.writer, cfg.calendar_id) catch return Error.OutOfMemory;
    url.writer.writeAll("/events?") catch return Error.OutOfMemory;
    const query = encodeForm(arena, &.{
        .{ "timeMin", time_min },
        .{ "timeMax", time_max },
        .{ "timeZone", cfg.timezone },
        .{ "singleEvents", "true" },
        .{ "orderBy", "startTime" },
        .{ "maxResults", "50" },
    }) catch return Error.OutOfMemory;
    url.writer.writeAll(query) catch return Error.OutOfMemory;

    const auth = std.fmt.allocPrint(arena, "Bearer {s}", .{token}) catch return Error.OutOfMemory;
    var response = http.getWithHeaders(io, arena, url.written(), &.{
        .{ .name = "Authorization", .value = auth },
    }) catch return Error.RequestFailed;
    defer response.deinit(arena);

    if (!response.ok()) {
        log.warn("events.list returned {d}: {s}", .{
            @intFromEnum(response.status), response.body[0..@min(response.body.len, 300)],
        });
        return Error.RequestFailed;
    }
    return parseListing(arena, response.body, day_text) catch Error.BadResponse;
}

/// Deletes one entry by the id a listing gave it.
/// https://developers.google.com/workspace/calendar/api/v3/reference/events/delete
pub fn remove(io: std.Io, arena: std.mem.Allocator, cfg: Config, event_id: []const u8) Error!void {
    if (event_id.len == 0) return Error.BadResponse;
    const token = try accessToken(io, arena, cfg);

    var url: std.Io.Writer.Allocating = .init(arena);
    url.writer.print("{s}/", .{EVENTS_ENDPOINT}) catch return Error.OutOfMemory;
    encodeComponent(&url.writer, cfg.calendar_id) catch return Error.OutOfMemory;
    url.writer.writeAll("/events/") catch return Error.OutOfMemory;
    encodeComponent(&url.writer, event_id) catch return Error.OutOfMemory;

    const auth = std.fmt.allocPrint(arena, "Bearer {s}", .{token}) catch return Error.OutOfMemory;
    var response = http.delete(io, arena, url.written(), &.{
        .{ .name = "Authorization", .value = auth },
    }) catch return Error.RequestFailed;
    defer response.deinit(arena);

    if (!response.ok()) {
        log.warn("events.delete returned {d}: {s}", .{
            @intFromEnum(response.status), response.body[0..@min(response.body.len, 300)],
        });
        return Error.RequestFailed;
    }
}

// ---- the one-time login ----

/// RFC 7636: the verifier is 43..128 characters from the unreserved set;
/// the challenge is base64url(sha256(verifier)) without padding.
const PKCE = struct {
    verifier: [64]u8,
    challenge: [43]u8,

    fn generate(io: std.Io) PKCE {
        const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
        var raw: [64]u8 = undefined;
        io.random(&raw);
        var pkce: PKCE = undefined;
        for (raw, 0..) |byte, i| pkce.verifier[i] = alphabet[byte % alphabet.len];
        pkce.challenge = challengeFor(&pkce.verifier);
        return pkce;
    }

    fn challengeFor(verifier: []const u8) [43]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
        var out: [43]u8 = undefined;
        _ = std.base64.url_safe_no_pad.Encoder.encode(&out, &digest);
        return out;
    }
};

pub const AuthMode = enum {
    /// Listen on the loopback port for the browser's redirect.
    listen,
    /// Read the redirected URL from stdin instead, for when the browser is
    /// on another machine and cannot reach this one's loopback.
    paste,
};

fn redirectUri(arena: std.mem.Allocator, cfg: Config) ![]const u8 {
    return std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{cfg.auth_port});
}

/// The URL the owner opens. Public so the probe and a test can look at it.
pub fn authorizationUrl(arena: std.mem.Allocator, cfg: Config, challenge: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll(AUTH_ENDPOINT ++ "?");
    const pairs = [_]Pair{
        .{ "client_id", cfg.client_id },
        .{ "redirect_uri", try redirectUri(arena, cfg) },
        .{ "response_type", "code" },
        .{ "scope", SCOPE },
        .{ "code_challenge", challenge },
        .{ "code_challenge_method", "S256" },
        // Refresh tokens are always issued to installed apps, but asking is
        // harmless and makes the intent explicit.
        .{ "access_type", "offline" },
    };
    try out.writer.writeAll(try encodeForm(arena, &pairs));
    return out.written();
}

/// Pulls the `code` out of whatever the browser was sent to: a full URL, a
/// bare query string, or the code on its own.
pub fn codeFrom(arena: std.mem.Allocator, pasted: []const u8) !?[]const u8 {
    var trimmed = std.mem.trim(u8, pasted, " \t\r\n");
    // A raw request line ("GET /?code=... HTTP/1.1") ends at the space.
    if (std.mem.indexOfScalar(u8, trimmed, ' ')) |space| trimmed = trimmed[0..space];
    if (trimmed.len == 0) return null;
    const query = if (std.mem.indexOfScalar(u8, trimmed, '?')) |q| trimmed[q + 1 ..] else trimmed;
    const without_fragment = if (std.mem.indexOfScalar(u8, query, '#')) |h| query[0..h] else query;
    if (try queryValue(arena, without_fragment, "code")) |code| return code;
    if (try queryValue(arena, without_fragment, "error")) |problem| {
        log.err("google refused the login: {s}", .{problem});
        return null;
    }
    // No key at all: treat the whole thing as the code.
    if (std.mem.indexOfScalar(u8, without_fragment, '=') == null) return without_fragment;
    return null;
}

/// Serves exactly one request on the loopback port and returns the code
/// from its query string.
fn awaitRedirect(io: std.Io, arena: std.mem.Allocator, cfg: Config) !?[]const u8 {
    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", cfg.auth_port);
    var server = address.listen(io, .{ .reuse_address = true }) catch |err| {
        std.debug.print("could not listen on 127.0.0.1:{d} ({s}); try GOOGLE_OAUTH_PORT=<another port> or `ronny calendar-auth paste`\n", .{ cfg.auth_port, @errorName(err) });
        return err;
    };
    defer server.deinit(io);

    var stream = try server.accept(io);
    defer stream.close(io);

    var read_buffer: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const request_line = reader.interface.takeDelimiterExclusive('\n') catch |err| {
        std.debug.print("the browser connected but sent nothing readable ({s})\n", .{@errorName(err)});
        return null;
    };

    // "GET /?code=...&scope=... HTTP/1.1"
    var code: ?[]const u8 = null;
    var words = std.mem.tokenizeScalar(u8, request_line, ' ');
    _ = words.next();
    if (words.next()) |target| code = try codeFrom(arena, target);

    const page = if (code != null)
        "<!doctype html><title>Ronny</title><p>Ronny is connected to your calendar. You can close this tab.</p>"
    else
        "<!doctype html><title>Ronny</title><p>That did not carry a code. Go back to the terminal.</p>";
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    writer.interface.print(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ page.len, page },
    ) catch {};
    writer.interface.flush() catch {};
    return code;
}

fn readPasted(io: std.Io, arena: std.mem.Allocator) !?[]const u8 {
    var buffer: [8192]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &buffer);
    const line = stdin.interface.takeDelimiterExclusive('\n') catch |err| {
        if (err == error.EndOfStream) return null;
        return err;
    };
    return codeFrom(arena, line);
}

/// A login that has been started: the URL to open, and the PKCE verifier
/// that only the same process can finish it with.
pub const Login = struct {
    verifier: [64]u8,
    url: []const u8,
};

/// Starts a login. The URL is what the owner opens; `finishLogin` takes
/// what the browser ends up on. The bot does this from chat; the CLI does
/// it from a terminal. Neither writes anything until the code comes back.
pub fn beginLogin(io: std.Io, arena: std.mem.Allocator, cfg: Config) !Login {
    const pkce = PKCE.generate(io);
    return .{
        .verifier = pkce.verifier,
        .url = try authorizationUrl(arena, cfg, &pkce.challenge),
    };
}

pub const LoginError = error{
    /// Nothing in the pasted text carried a code: a wrong paste, or the
    /// owner declined on Google's page.
    NoCode,
    /// Google issued an access token without a refresh token, which would
    /// last an hour.
    NoRefreshToken,
} || Error;

/// Exchanges the code in `pasted` (a full redirect URL, its query string,
/// or the bare code) and saves the refresh token.
///
/// https://developers.google.com/identity/protocols/oauth2/native-app,
/// step 5: the same redirect_uri as the authorization request, and the
/// PKCE verifier the challenge was built from.
pub fn finishLogin(io: std.Io, gpa: std.mem.Allocator, cfg: Config, verifier: []const u8, pasted: []const u8) LoginError!void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const code = (codeFrom(arena, pasted) catch return Error.OutOfMemory) orelse return LoginError.NoCode;
    const redirect = redirectUri(arena, cfg) catch return Error.OutOfMemory;
    var pairs: [6]Pair = .{
        .{ "client_id", cfg.client_id },
        .{ "client_secret", cfg.client_secret },
        .{ "code", code },
        .{ "code_verifier", verifier },
        .{ "grant_type", "authorization_code" },
        .{ "redirect_uri", redirect },
    };
    const token = try postToken(io, arena, if (cfg.client_secret.len > 0) &pairs else &.{ pairs[0], pairs[2], pairs[3], pairs[4], pairs[5] });
    const refresh = token.refresh_token orelse return LoginError.NoRefreshToken;

    saveStored(io, gpa, cfg.token_path, .{
        .refresh_token = refresh,
        .access_token = token.access_token,
        .expires_at = nowSeconds(io) + token.expires_in,
    }) catch |err| {
        log.err("could not write {s}: {s}", .{ cfg.token_path, @errorName(err) });
        return Error.RequestFailed;
    };
    log.info("calendar login saved to {s}", .{cfg.token_path});
}

/// The terminal version of the login, for a machine with a browser on it.
/// The chat version in bot.zig is the usual way in.
pub fn authorize(io: std.Io, gpa: std.mem.Allocator, cfg: Config, mode: AuthMode) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const login = try beginLogin(io, arena, cfg);
    const url = login.url;

    std.debug.print(
        \\Open this in a browser, signed in as the mailbox owner, and allow the calendar access:
        \\
        \\{s}
        \\
        \\
    , .{url});
    const code = switch (mode) {
        .listen => blk: {
            std.debug.print("Waiting for the browser to come back to http://127.0.0.1:{d} ...\n", .{cfg.auth_port});
            break :blk try awaitRedirect(io, arena, cfg);
        },
        .paste => blk: {
            std.debug.print("The browser will end up on a 127.0.0.1 page that fails to load. Paste that page's full URL here and press Enter:\n> ", .{});
            break :blk try readPasted(io, arena);
        },
    } orelse {
        std.debug.print("No authorization code arrived. Nothing was saved.\n", .{});
        return error.NoCode;
    };

    finishLogin(io, gpa, cfg, &login.verifier, code) catch |err| {
        if (err == LoginError.NoRefreshToken) {
            std.debug.print("Google returned an access token but no refresh token, so this login would last an hour. Revoke Ronny at https://myaccount.google.com/permissions and run this again.\n", .{});
        }
        return err;
    };
    std.debug.print("Connected. The refresh token is in {s}.\n", .{cfg.token_path});
}

/// Whether a chat message is the owner pasting the login back: the address
/// the browser landed on, its query string, or the bare code. A refusal is
/// a paste too -- Google's error page, not the redirect -- and has to be
/// caught here or it goes to the classifier as a very long unknown.
pub fn looksLikeLogin(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.indexOf(u8, trimmed, "code=") != null) return true;
    if (std.mem.indexOf(u8, trimmed, "error=") != null) return true;
    if (std.mem.indexOf(u8, trimmed, "authError=") != null) return true;
    if (std.mem.indexOf(u8, trimmed, "accounts.google.com/") != null) return true;
    if (std.mem.startsWith(u8, trimmed, "http://127.0.0.1") or std.mem.startsWith(u8, trimmed, "http://localhost")) return true;
    // A bare code, as Google issues them.
    if (std.mem.startsWith(u8, trimmed, "4/") and std.mem.indexOfScalar(u8, trimmed, ' ') == null) return true;
    return false;
}

// ---- tests ----

test "form encoding keeps unreserved bytes and escapes the rest" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try encodeForm(arena, &.{
        .{ "scope", "https://www.googleapis.com/auth/calendar.events.owned" },
        .{ "note", "a b&c=d~" },
    });
    try std.testing.expectEqualStrings(
        "scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcalendar.events.owned&note=a%20b%26c%3Dd~",
        body,
    );
}

test "the code is found in a full redirect URL, a query string, or bare" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "4/0AbC-dEf_g",
        (try codeFrom(arena, "http://127.0.0.1:8765/?code=4%2F0AbC-dEf_g&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcalendar.events.owned")).?,
    );
    try std.testing.expectEqualStrings("abc", (try codeFrom(arena, "/?state=x&code=abc HTTP/1.1")).?);
    try std.testing.expectEqualStrings("abc", (try codeFrom(arena, "  abc \n")).?);
    // A refusal carries no code and must not be mistaken for one.
    try std.testing.expectEqual(@as(?[]const u8, null), try codeFrom(arena, "http://127.0.0.1:8765/?error=access_denied"));
    try std.testing.expectEqual(@as(?[]const u8, null), try codeFrom(arena, ""));
}

fn readVarint(bytes: []const u8, i: *usize) ?usize {
    var value: usize = 0;
    var shift: u6 = 0;
    while (i.* < bytes.len) {
        const byte = bytes[i.*];
        i.* += 1;
        value |= @as(usize, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return value;
        if (shift >= 56) return null;
        shift += 7;
    }
    return null;
}

/// Why Google refused, when the owner pasted its error page instead of the
/// redirect. Null when the paste is not a refusal.
///
/// The page is accounts.google.com/signin/oauth/error?authError=<base64>,
/// and the payload is a protobuf whose first two fields are the error code
/// and the sentence shown to the user -- read from a real refusal, not from
/// any documentation, so it is parsed leniently and anything unreadable
/// falls back to the bare code.
pub fn refusalFrom(arena: std.mem.Allocator, pasted: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, pasted, " \t\r\n");

    if (std.mem.indexOf(u8, trimmed, "authError=")) |at| {
        var value = trimmed[at + "authError=".len ..];
        if (std.mem.indexOfAny(u8, value, "&# ")) |stop| value = value[0..stop];
        value = std.mem.trimEnd(u8, value, "=");
        const decoder = std.base64.url_safe_no_pad.Decoder;
        const size = decoder.calcSizeForSlice(value) catch return "access_denied";
        const bytes = try arena.alloc(u8, size);
        decoder.decode(bytes, value) catch return "access_denied";

        var code: []const u8 = "";
        var message: []const u8 = "";
        var i: usize = 0;
        while (i < bytes.len) {
            const tag = bytes[i];
            i += 1;
            if (tag & 7 != 2) break; // only length-delimited fields are read
            const len = readVarint(bytes, &i) orelse break;
            if (i + len > bytes.len) break;
            const field = bytes[i .. i + len];
            i += len;
            switch (tag >> 3) {
                1 => code = field,
                2 => message = field,
                else => break,
            }
        }
        if (code.len == 0) return "access_denied";
        if (message.len == 0) return code;
        return try std.fmt.allocPrint(arena, "{s}: {s}", .{ code, message });
    }

    // The redirect itself can carry a refusal: ?error=access_denied.
    const query = if (std.mem.indexOfScalar(u8, trimmed, '?')) |q| trimmed[q + 1 ..] else trimmed;
    if (try queryValue(arena, query, "error")) |problem| return problem;
    return null;
}

test "a refusal page is decoded into Google's own words" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The payload a real refusal carried (identifiers replaced), cut after
    // the message: the fields that follow are not read.
    const page = "https://accounts.google.com/signin/oauth/error?authError=Cg1hY2Nlc3NfZGVuaWVkElNUaGUgZGV2ZWxvcGVyIGhhc27igJl0IGdpdmVuIHlvdSBhY2Nlc3MgdG8gdGhpcyBhcHAuIEl04oCZcyBjdXJyZW50bHkgYmVpbmcgdGVzdGVkLg";
    const reason = (try refusalFrom(arena, page)).?;
    try std.testing.expectEqualStrings(
        "access_denied: The developer hasn\u{2019}t given you access to this app. It\u{2019}s currently being tested.",
        reason,
    );
    try std.testing.expect(looksLikeLogin(page));

    // A refusal on the redirect itself.
    try std.testing.expectEqualStrings("access_denied", (try refusalFrom(arena, "http://127.0.0.1:8765/?error=access_denied")).?);
    // A good paste is not a refusal.
    try std.testing.expectEqual(@as(?[]const u8, null), try refusalFrom(arena, "http://127.0.0.1:8765/?code=4%2Fabc&scope=x"));
    // Garbage after authError= still names the code rather than crashing.
    try std.testing.expectEqualStrings("access_denied", (try refusalFrom(arena, "?authError=!!!")).?);
}

test "a pasted login is told apart from an ordinary message" {
    try std.testing.expect(looksLikeLogin("http://127.0.0.1:8765/?code=4%2Fabc&scope=x"));
    try std.testing.expect(looksLikeLogin("127.0.0.1:8765/?code=4%2Fabc"));
    try std.testing.expect(looksLikeLogin("4/0AbC-dEf"));
    try std.testing.expect(looksLikeLogin("http://127.0.0.1:8765/?error=access_denied"));
    try std.testing.expect(!looksLikeLogin("dentist tomorrow at 4/5"));
    try std.testing.expect(!looksLikeLogin("yes"));
    try std.testing.expect(!looksLikeLogin("connect my calendar"));
}

test "PKCE challenge matches the RFC 7636 appendix B vector" {
    // https://www.rfc-editor.org/rfc/rfc7636#appendix-B
    const challenge = PKCE.challengeFor("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk");
    try std.testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", &challenge);
}

test "an event body carries the local clock time with its zone, or a date for all day" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The failure seen live: an empty zone must not reach Google.
    try std.testing.expectError(error.MissingTimezone, eventJson(arena, "", .{
        .title = "Free time",
        .year = 2026,
        .month = 9,
        .day = 28,
        .start_minutes = 16 * 60,
        .end_minutes = 17 * 60,
    }));

    const timed = try eventJson(arena, "Europe/Madrid", .{
        .title = "Dentist",
        .location = "Calle Mayor 1",
        .year = 2026,
        .month = 10,
        .day = 1,
        .start_minutes = 15 * 60 + 30,
        .end_minutes = 16 * 60,
    });
    try std.testing.expectEqualStrings(
        "{\"summary\":\"Dentist\",\"location\":\"Calle Mayor 1\",\"start\":{\"dateTime\":\"2026-10-01T15:30:00\",\"timeZone\":\"Europe/Madrid\"},\"end\":{\"dateTime\":\"2026-10-01T16:00:00\",\"timeZone\":\"Europe/Madrid\"}}",
        timed,
    );

    // All-day: date only, exclusive end on the next day, and the year end
    // has to roll.
    const all_day = try eventJson(arena, "Europe/Madrid", .{
        .title = "Holiday",
        .year = 2026,
        .month = 12,
        .day = 31,
        .start_minutes = null,
    });
    try std.testing.expectEqualStrings(
        "{\"summary\":\"Holiday\",\"start\":{\"date\":\"2026-12-31\"},\"end\":{\"date\":\"2027-01-01\"}}",
        all_day,
    );
}

test "a day's listing is read from the shape Google sends" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"kind":"calendar#events","items":[
        \\ {"id":"abc123","status":"confirmed","summary":"Sam's birthday","start":{"date":"2026-10-01"},"end":{"date":"2026-10-02"}},
        \\ {"status":"confirmed","summary":"Reunión con Vicente","location":"Calle Mayor 1","start":{"dateTime":"2026-10-01T10:00:00+02:00","timeZone":"Europe/Madrid"},"end":{"dateTime":"2026-10-01T11:00:00+02:00"}},
        \\ {"status":"cancelled","summary":"Gone","start":{"dateTime":"2026-10-01T12:00:00+02:00"},"end":{"dateTime":"2026-10-01T13:00:00+02:00"}},
        \\ {"status":"confirmed","summary":"Offsite","start":{"dateTime":"2026-09-30T18:00:00+02:00"},"end":{"dateTime":"2026-10-01T12:30:00+02:00"}},
        \\ {"status":"confirmed","start":{"dateTime":"2026-10-01T15:00:00+02:00"},"end":{"dateTime":"2026-10-02T09:00:00+02:00"}}
        \\]}
    ;
    const entries = try parseListing(arena, body, "2026-10-01");
    try std.testing.expectEqual(@as(usize, 4), entries.len);

    try std.testing.expectEqualStrings("Sam's birthday", entries[0].title);
    try std.testing.expectEqualStrings("abc123", entries[0].id);
    try std.testing.expectEqual(@as(?i16, null), entries[0].start_minutes);

    try std.testing.expectEqualStrings("Reunión con Vicente", entries[1].title);
    try std.testing.expectEqualStrings("Calle Mayor 1", entries[1].location);
    try std.testing.expectEqual(@as(?i16, 10 * 60), entries[1].start_minutes);
    try std.testing.expectEqual(@as(?i16, 11 * 60), entries[1].end_minutes);

    // Started yesterday: shown from midnight.
    try std.testing.expectEqual(@as(?i16, 0), entries[2].start_minutes);
    try std.testing.expectEqual(@as(?i16, 12 * 60 + 30), entries[2].end_minutes);

    // Ends tomorrow, and has no title.
    try std.testing.expectEqualStrings("(no title)", entries[3].title);
    try std.testing.expectEqual(@as(?i16, 15 * 60), entries[3].start_minutes);
    try std.testing.expectEqual(@as(?i16, 24 * 60), entries[3].end_minutes);
}

test "the meeting link comes from Meet, a conference entry point, the location or a known host" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body =
        \\{"items":[
        \\ {"id":"a","summary":"Standup","hangoutLink":"https://meet.google.com/abc-defg-hij","description":"<p>Agenda:</p><ul><li>numbers &amp; plans</li><li>hiring</li></ul>","start":{"dateTime":"2026-10-01T09:00:00+02:00"},"end":{"dateTime":"2026-10-01T09:15:00+02:00"}},
        \\ {"id":"b","summary":"Zoom call","conferenceData":{"entryPoints":[{"entryPointType":"phone","uri":"tel:+34123"},{"entryPointType":"video","uri":"https://us02web.zoom.us/j/123?pwd=x"}]},"start":{"dateTime":"2026-10-01T10:00:00+02:00"},"end":{"dateTime":"2026-10-01T11:00:00+02:00"}},
        \\ {"id":"c","summary":"Teams","location":"https://teams.microsoft.com/l/meetup-join/xyz","start":{"dateTime":"2026-10-01T12:00:00+02:00"},"end":{"dateTime":"2026-10-01T13:00:00+02:00"}},
        \\ {"id":"d","summary":"Review","description":"Doc: https://docs.google.com/document/d/1 and join at <a href=\"https://acme.zoom.us/j/999\">Zoom</a>.","start":{"dateTime":"2026-10-01T14:00:00+02:00"},"end":{"dateTime":"2026-10-01T15:00:00+02:00"}},
        \\ {"id":"e","summary":"Dentist","location":"Calle Mayor 1","description":"Bring the x-rays https://example.com/portal","start":{"dateTime":"2026-10-01T16:00:00+02:00"},"end":{"dateTime":"2026-10-01T17:00:00+02:00"}}
        \\]}
    ;
    const entries = try parseListing(arena, body, "2026-10-01");
    try std.testing.expectEqual(@as(usize, 5), entries.len);
    try std.testing.expectEqualStrings("https://meet.google.com/abc-defg-hij", entries[0].link);
    try std.testing.expectEqualStrings("Agenda:\n- numbers & plans\n- hiring", entries[0].description);
    try std.testing.expectEqualStrings("https://us02web.zoom.us/j/123?pwd=x", entries[1].link);
    try std.testing.expectEqualStrings("https://teams.microsoft.com/l/meetup-join/xyz", entries[2].link);
    try std.testing.expectEqualStrings("https://acme.zoom.us/j/999", entries[3].link);
    // A portal link in the description is not a meeting.
    try std.testing.expectEqualStrings("", entries[4].link);
    try std.testing.expectEqualStrings("Bring the x-rays https://example.com/portal", entries[4].description);
}

test "a link is cut at what ends it, and a lookalike host is not a meeting host" {
    try std.testing.expectEqualStrings("https://meet.google.com/x", firstLink("Join https://meet.google.com/x.", false).?);
    try std.testing.expectEqualStrings("https://zoom.us/j/1", firstLink("(https://zoom.us/j/1)", false).?);
    try std.testing.expect(firstLink("https://zoom.us.example.com/j/1", true) == null);
    try std.testing.expect(firstLink("httpsomething http://", true) == null);
    try std.testing.expect(firstLink("no links here", false) == null);
}

test "a day boundary carries the offset libc says applies on that day" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Whatever the machine's zone, the shape is fixed and the offset is
    // the machine's, not a guess.
    const text = try dayBoundary(arena, 2026, 10, 1);
    try std.testing.expectEqual(@as(usize, 25), text.len);
    try std.testing.expect(std.mem.startsWith(u8, text, "2026-10-01T00:00:00"));
    try std.testing.expect(text[19] == '+' or text[19] == '-');
}

test "the authorization URL names the scope, the loopback redirect and PKCE" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const url = try authorizationUrl(arena, .{
        .client_id = "id.apps.googleusercontent.com",
        .token_path = "unused",
        .timezone = "Europe/Madrid",
        .auth_port = 8765,
    }, "CHALLENGE");
    try std.testing.expect(std.mem.startsWith(u8, url, "https://accounts.google.com/o/oauth2/v2/auth?client_id=id.apps.googleusercontent.com&"));
    try std.testing.expect(std.mem.indexOf(u8, url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A8765") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "code_challenge=CHALLENGE&code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcalendar.events.owned") != null);
}

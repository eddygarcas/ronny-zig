//! The live-editable parts of Ronny's behaviour: the sender allowlist and the
//! paused flag. Port of `ronny/controller.py`.
//!
//! Two things carry over deliberately:
//!
//! - The allowlist file keeps its comment header. Entries can be changed from
//!   chat, and rewriting the file through a YAML serialiser would throw away
//!   the explanation of what the file is for. Only the list is rewritten.
//!
//! - Entries are validated before being stored. An LLM once interpreted "send
//!   me an email saying all ready" as add_sender with the literal string
//!   "null", which was written straight into the live allowlist. Validation is
//!   the durable guard: it holds regardless of how a bad value arrives.

const std = @import("std");

/// Namespaced so each module's output is identifiable in the journal,
/// the way the Python version's per-module loggers were.
const log = std.log.scoped(.controller);

pub const Error = error{InvalidEntry};

/// Accepts a full address or a bare domain: an optional `local@` part, then
/// dot-separated labels, then a 2+ letter TLD.
///
/// Python used a regex for this. Zig has no regex in std, and spelling the
/// rules out is arguably clearer about what is actually allowed.
pub fn isValidEntry(raw: []const u8) bool {
    const entry = std.mem.trim(u8, raw, " \t\r\n");
    if (entry.len == 0 or entry.len > 254) return false;

    // Split off an optional local part. More than one '@' is malformed.
    var domain = entry;
    if (std.mem.indexOfScalar(u8, entry, '@')) |at| {
        const local = entry[0..at];
        domain = entry[at + 1 ..];
        if (local.len == 0) return false;
        for (local) |ch| {
            if (ch == '@' or std.ascii.isWhitespace(ch)) return false;
        }
        if (std.mem.indexOfScalar(u8, domain, '@') != null) return false;
    }

    if (domain.len == 0) return false;

    var labels = std.mem.splitScalar(u8, domain, '.');
    var label_count: usize = 0;
    var last_label: []const u8 = "";

    while (labels.next()) |label| {
        label_count += 1;
        last_label = label;
        if (label.len == 0) return false;

        // Labels may contain hyphens but must not start or end with one.
        if (label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
        }
    }

    // A bare word like "null" has no dot and must be rejected.
    if (label_count < 2) return false;

    if (last_label.len < 2) return false;
    for (last_label) |ch| {
        if (!std.ascii.isAlphabetic(ch)) return false;
    }
    return true;
}

pub const Controller = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    senders_path: []const u8,
    state_path: []const u8,
    mutex: std.Io.Mutex = .init,
    paused: bool = false,

    const max_file_bytes: std.Io.Limit = .limited(1024 * 1024);
    const PausedState = struct { paused: bool = false };

    pub fn init(io: std.Io, gpa: std.mem.Allocator, senders_path: []const u8, state_path: []const u8) Controller {
        var controller: Controller = .{
            .io = io,
            .gpa = gpa,
            .senders_path = senders_path,
            .state_path = state_path,
        };
        controller.paused = controller.loadPaused();
        return controller;
    }

    fn loadPaused(self: *Controller) bool {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.state_path, self.gpa, max_file_bytes) catch return false;
        defer self.gpa.free(bytes);

        const parsed = std.json.parseFromSlice(PausedState, self.gpa, bytes, .{
            .ignore_unknown_fields = true,
        }) catch return false;
        defer parsed.deinit();

        return parsed.value.paused;
    }

    /// Persisted, so a restart doesn't silently resume notifications the
    /// owner had paused.
    pub fn setPaused(self: *Controller, value: bool) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        self.paused = value;

        var buffer: std.Io.Writer.Allocating = .init(self.gpa);
        defer buffer.deinit();
        try std.json.Stringify.value(PausedState{ .paused = value }, .{}, &buffer.writer);

        if (std.fs.path.dirname(self.state_path)) |dir| {
            std.Io.Dir.cwd().createDirPath(self.io, dir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = self.state_path,
            .data = buffer.writer.buffered(),
        });
    }

    /// Caller owns the returned entries and the slice.
    pub fn senders(self: *Controller) ![]const []const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return self.readSenders();
    }

    fn readSenders(self: *Controller) ![]const []const u8 {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.senders_path, self.gpa, max_file_bytes) catch |err| {
            if (err == error.FileNotFound) return &.{};
            return err;
        };
        defer self.gpa.free(bytes);

        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |item| self.gpa.free(item);
            list.deinit(self.gpa);
        }

        var in_list = false;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            if (std.mem.eql(u8, line, "senders:")) {
                in_list = true;
                continue;
            }
            if (!in_list) continue;

            // Any non-list line ends the block; this parser only understands
            // the small subset of YAML the file actually uses.
            if (!std.mem.startsWith(u8, line, "- ")) break;

            const entry = std.mem.trim(u8, line[2..], " \t\"'");
            if (entry.len == 0) continue;

            const lowered = try self.gpa.alloc(u8, entry.len);
            _ = std.ascii.lowerString(lowered, entry);
            try list.append(self.gpa, lowered);
        }

        return list.toOwnedSlice(self.gpa);
    }

    pub fn freeSenders(self: *Controller, entries: []const []const u8) void {
        for (entries) |entry| self.gpa.free(entry);
        self.gpa.free(entries);
    }

    /// Returns false when the entry was already present. Rejects anything
    /// that isn't a plausible address or domain.
    pub fn addSender(self: *Controller, raw: []const u8) !bool {
        var lowered_buf: [256]u8 = undefined;
        const entry = std.mem.trim(u8, raw, " \t\r\n");
        if (entry.len == 0 or entry.len > lowered_buf.len) return Error.InvalidEntry;
        if (!isValidEntry(entry)) return Error.InvalidEntry;
        const lowered = std.ascii.lowerString(lowered_buf[0..entry.len], entry);

        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const current = try self.readSenders();
        defer self.freeSenders(current);

        for (current) |existing| {
            if (std.mem.eql(u8, existing, lowered)) return false;
        }

        var updated: std.ArrayList([]const u8) = .empty;
        defer updated.deinit(self.gpa);
        try updated.appendSlice(self.gpa, current);
        try updated.append(self.gpa, lowered);

        try self.writeSenders(updated.items);
        return true;
    }

    /// Returns false when the entry wasn't present.
    pub fn removeSender(self: *Controller, raw: []const u8) !bool {
        var lowered_buf: [256]u8 = undefined;
        const entry = std.mem.trim(u8, raw, " \t\r\n");
        if (entry.len == 0 or entry.len > lowered_buf.len) return false;
        const lowered = std.ascii.lowerString(lowered_buf[0..entry.len], entry);

        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const current = try self.readSenders();
        defer self.freeSenders(current);

        var kept: std.ArrayList([]const u8) = .empty;
        defer kept.deinit(self.gpa);

        var removed = false;
        for (current) |existing| {
            if (std.mem.eql(u8, existing, lowered)) {
                removed = true;
                continue;
            }
            try kept.append(self.gpa, existing);
        }
        if (!removed) return false;

        try self.writeSenders(kept.items);
        return true;
    }

    /// Rewrites only the list, keeping whatever comment header the file has.
    fn writeSenders(self: *Controller, entries: []const []const u8) !void {
        const existing = std.Io.Dir.cwd().readFileAlloc(self.io, self.senders_path, self.gpa, max_file_bytes) catch "";
        defer if (existing.len > 0) self.gpa.free(existing);

        const header = if (std.mem.indexOf(u8, existing, "senders:")) |idx|
            std.mem.trimEnd(u8, existing[0..idx], " \t\r\n")
        else
            "# Ronny sender allowlist";

        var buffer: std.Io.Writer.Allocating = .init(self.gpa);
        defer buffer.deinit();

        try buffer.writer.writeAll(header);
        try buffer.writer.writeAll("\n\nsenders:\n");
        for (entries) |entry| {
            try buffer.writer.print("  - {s}\n", .{entry});
        }

        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = self.senders_path,
            .data = buffer.writer.buffered(),
        });
    }
};

test "isValidEntry accepts real addresses and domains" {
    try std.testing.expect(isValidEntry("someone@example.com"));
    try std.testing.expect(isValidEntry("example.com"));
    try std.testing.expect(isValidEntry("sub.example.co.uk"));
    try std.testing.expect(isValidEntry("first.last@example.org"));
    try std.testing.expect(isValidEntry("with-hyphen.example.com"));
    try std.testing.expect(isValidEntry("  padded@example.com  "));
}

test "isValidEntry rejects what an LLM might hand it" {
    // The exact value that once reached the live allowlist.
    try std.testing.expect(!isValidEntry("null"));
    try std.testing.expect(!isValidEntry("none"));
    try std.testing.expect(!isValidEntry("all ready"));
    try std.testing.expect(!isValidEntry("Send me an email"));
    try std.testing.expect(!isValidEntry(""));
    try std.testing.expect(!isValidEntry("notadomain"));
    try std.testing.expect(!isValidEntry("a b@c d"));
    try std.testing.expect(!isValidEntry("@example.com"));
    try std.testing.expect(!isValidEntry("two@at@example.com"));
    try std.testing.expect(!isValidEntry("trailing.dot."));
    try std.testing.expect(!isValidEntry("-leading.example.com"));
    try std.testing.expect(!isValidEntry("example.c"));
    try std.testing.expect(!isValidEntry("example.12"));
}

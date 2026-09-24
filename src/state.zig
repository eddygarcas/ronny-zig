//! Which message UID has already been scanned, per IMAP UIDVALIDITY.
//!
//! Port of `ronny/state.py`, and deliberately JSON-compatible with it: both
//! implementations read and write `{"uidvalidity": N, "last_uid": N}`, so the
//! Python service and this one can share a state file while the migration is
//! in progress.
//!
//! The baseline behaviour is the load-bearing part. When UIDVALIDITY changes
//! -- or on a first run, when there is no file -- the watermark resets to the
//! mailbox's *current* UIDNEXT rather than to zero. Resetting to zero makes
//! the next scan treat every message in the mailbox as new; the Python
//! version shipped that bug once and tried to backfill 50,000 messages.

const std = @import("std");

pub const Snapshot = struct {
    uidvalidity: u32 = 0,
    last_uid: u32 = 0,
};

pub const State = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    snapshot: Snapshot,

    const max_file_bytes: std.Io.Limit = .limited(64 * 1024);

    /// Missing or unreadable state is not an error: it means a first run, and
    /// the caller baselines with `syncUidValidity` immediately afterwards.
    pub fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8) State {
        var state: State = .{ .io = io, .gpa = gpa, .path = path, .snapshot = .{} };

        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, max_file_bytes) catch |err| {
            if (err != error.FileNotFound) {
                std.log.warn("could not read {s} ({s}); starting fresh", .{ path, @errorName(err) });
            }
            return state;
        };
        defer gpa.free(bytes);

        const parsed = std.json.parseFromSlice(Snapshot, gpa, bytes, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.warn("could not parse {s} ({s}); starting fresh", .{ path, @errorName(err) });
            return state;
        };
        defer parsed.deinit();

        state.snapshot = parsed.value;
        return state;
    }

    pub fn lastUid(self: *const State) u32 {
        return self.snapshot.last_uid;
    }

    /// Only ever moves forward, so an out-of-order fetch can't rewind the
    /// watermark and cause messages to be reported twice.
    pub fn advance(self: *State, uid: u32) !void {
        if (uid <= self.snapshot.last_uid) return;
        self.snapshot.last_uid = uid;
        try self.save();
    }

    /// `baseline_uid` should be the highest UID that already exists, so a
    /// reset starts watching from now instead of replaying the mailbox.
    pub fn syncUidValidity(self: *State, uidvalidity: u32, baseline_uid: u32) !void {
        if (self.snapshot.uidvalidity == uidvalidity) return;

        std.log.info("uidvalidity {d} -> {d}; baselining watermark to {d}", .{
            self.snapshot.uidvalidity, uidvalidity, baseline_uid,
        });
        self.snapshot = .{ .uidvalidity = uidvalidity, .last_uid = baseline_uid };
        try self.save();
    }

    fn save(self: *State) !void {
        var buffer: std.Io.Writer.Allocating = .init(self.gpa);
        defer buffer.deinit();

        try std.json.Stringify.value(self.snapshot, .{}, &buffer.writer);

        if (std.fs.path.dirname(self.path)) |dir| {
            std.Io.Dir.cwd().createDirPath(self.io, dir) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = self.path,
            .data = buffer.writer.buffered(),
        });
    }
};

test "a fresh state starts empty" {
    const state: State = .{
        .io = undefined,
        .gpa = std.testing.allocator,
        .path = "unused",
        .snapshot = .{},
    };
    try std.testing.expectEqual(@as(u32, 0), state.lastUid());
}

test "snapshot round-trips through the Python-compatible JSON shape" {
    const json = "{\"uidvalidity\": 1, \"last_uid\": 139740}";
    const parsed = try std.json.parseFromSlice(Snapshot, std.testing.allocator, json, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 1), parsed.value.uidvalidity);
    try std.testing.expectEqual(@as(u32, 139740), parsed.value.last_uid);
}

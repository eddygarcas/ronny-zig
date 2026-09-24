//! Second-line spam and phishing check.
//!
//! Port of `ronny/spam_filter.py`. Being on the allowlist is necessary but not
//! sufficient: a compromised account, a spoofed display name, or an
//! allowlisted sender running a marketing blast all still look like spam.
//!
//! Cheap deterministic header checks run first, then a judgment call to the
//! local Ollama model. Ollama is deliberate -- this is the one step that reads
//! message bodies, and email content does not leave the machine. Only the
//! routing decision (chat commands, no mail content) is allowed off-box.

const std = @import("std");
const ollama = @import("ollama.zig");

const log = std.log.scoped(.spam);

pub const Verdict = struct {
    is_spam: bool,
    /// Distinguishes "the model cleared it" from "the model was unreachable",
    /// which the notification text surfaces so a skipped check is never
    /// mistaken for a clean bill of health.
    checked: bool,
    reason: []const u8,
};

/// Header-only checks. These need no model and catch the clearest cases.
///
/// Returns the reason to suppress, or null to continue to the model.
pub fn headerVerdict(headers: []const u8) ?[]const u8 {
    if (containsIgnoreCase(headers, "spf=fail") or containsIgnoreCase(headers, "spf=softfail")) {
        return "SPF check failed";
    }
    if (containsIgnoreCase(headers, "dkim=fail")) {
        return "DKIM check failed";
    }
    // Bulk mail announces itself. Both markers together are a mailing list or
    // marketing blast rather than correspondence.
    if (containsIgnoreCase(headers, "list-unsubscribe:") and
        (containsIgnoreCase(headers, "precedence: bulk") or containsIgnoreCase(headers, "precedence: list")))
    {
        return "marked as bulk/list mail (List-Unsubscribe + Precedence: bulk)";
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

const Answer = struct {
    is_spam: bool = false,
    reason: []const u8 = "",
};

/// Fails **open**: if the model is unreachable the mail is still reported,
/// because silently dropping real mail is a worse failure than an extra
/// notification. The caller marks such notifications so the owner knows the
/// second line of defence did not run.
pub fn evaluate(
    io: std.Io,
    gpa: std.mem.Allocator,
    ollama_url: []const u8,
    model: []const u8,
    sender: []const u8,
    subject: []const u8,
    headers: []const u8,
    body: []const u8,
) Verdict {
    if (headerVerdict(headers)) |reason| {
        return .{ .is_spam = true, .checked = true, .reason = reason };
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const verdict = askModel(io, arena, ollama_url, model, sender, subject, body) catch |err| {
        log.warn("spam check unavailable ({s}); notifying anyway", .{@errorName(err)});
        return .{ .is_spam = false, .checked = false, .reason = "spam check unavailable" };
    };

    // The reason is arena-allocated, so it is copied out for the caller.
    const owned = gpa.dupe(u8, verdict.reason) catch "";
    return .{ .is_spam = verdict.is_spam, .checked = true, .reason = owned };
}

fn askModel(
    io: std.Io,
    arena: std.mem.Allocator,
    ollama_url: []const u8,
    model: []const u8,
    sender: []const u8,
    subject: []const u8,
    body: []const u8,
) !Answer {
    const prompt = try std.fmt.allocPrint(arena,
        \\You are a strict email security filter. Decide if this email is spam, an unsolicited marketing blast, or a phishing/social-engineering attempt -- even though it comes from an address the recipient normally trusts. Legitimate, expected correspondence from this sender should NOT be flagged.
        \\
        \\From: {s}
        \\Subject: {s}
        \\Body (truncated):
        \\{s}
        \\
        \\Respond with ONLY a JSON object of the form {{"is_spam": true|false, "reason": "short reason"}}
    , .{ sender, subject, body[0..@min(body.len, 1500)] });

    const text = try ollama.generate(io, arena, ollama_url, model, prompt, .json);
    const answer = try std.json.parseFromSlice(Answer, arena, text, .{
        .ignore_unknown_fields = true,
    });
    defer answer.deinit();

    return .{
        .is_spam = answer.value.is_spam,
        .reason = try arena.dupe(u8, answer.value.reason),
    };
}

test "headerVerdict catches authentication failures" {
    try std.testing.expect(headerVerdict("Authentication-Results: mx.google.com; spf=fail") != null);
    try std.testing.expect(headerVerdict("authentication-results: SPF=SoftFail") != null);
    try std.testing.expect(headerVerdict("Authentication-Results: dkim=fail header.i=@x.com") != null);
}

test "headerVerdict catches bulk mail only when both markers are present" {
    const bulk =
        "List-Unsubscribe: <https://example.com/u>\r\nPrecedence: bulk\r\n";
    try std.testing.expect(headerVerdict(bulk) != null);

    // An unsubscribe link alone is common on legitimate transactional mail.
    try std.testing.expect(headerVerdict("List-Unsubscribe: <https://example.com/u>\r\n") == null);
}

test "headerVerdict passes ordinary correspondence" {
    const ordinary =
        "From: someone@example.com\r\n" ++
        "Authentication-Results: mx.google.com; spf=pass; dkim=pass\r\n" ++
        "Subject: Thursday\r\n";
    try std.testing.expect(headerVerdict(ordinary) == null);
}

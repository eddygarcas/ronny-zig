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
    if (receiverResults(headers)) |results| {
        // The allowlist matches the From: header, which is what a phisher
        // forges, and SPF and DKIM alone do not vouch for it: SPF checks the
        // envelope sender and DKIM can pass on the forger's own domain.
        // DMARC is the result tied to the From: domain (RFC 7489 section 3,
        // "header.from" in its section 11.2 registration), so a fail here is
        // a stranger writing as an allowlisted sender.
        if (resultIs(results, "dmarc", "fail")) {
            return "DMARC check failed: the From address is not one its domain vouches for";
        }
        if (resultIs(results, "spf", "fail") or resultIs(results, "spf", "softfail")) {
            return "SPF check failed";
        }
        if (resultIs(results, "dkim", "fail")) {
            return "DKIM check failed";
        }
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

/// The value of the Authentication-Results header the receiving server
/// added, continuation lines included, or null when there is none.
///
/// Only the topmost one counts. The receiving server inserts its header
/// above the other trace fields (RFC 8601 section 4) and deletes any that
/// claim its own authserv-id (section 5), so whatever sits below came from
/// upstream: a forwarder's verdict on an earlier hop, or a header the sender
/// wrote. Reading anywhere in the headers, as this once did, let a sender
/// supply results of their own and let a forwarded message be dropped for
/// an old hop's failure. ARC-Authentication-Results is a different field,
/// and does not match because the name has to start the line.
pub fn receiverResults(headers: []const u8) ?[]const u8 {
    const name = "authentication-results:";
    var start: usize = 0;
    while (start < headers.len) {
        const end = std.mem.indexOfScalarPos(u8, headers, start, '\n') orelse headers.len;
        if (std.ascii.startsWithIgnoreCase(headers[start..end], name)) {
            // A folded field continues on lines that begin with whitespace
            // (RFC 5322 section 2.2.3).
            var stop = end;
            while (stop + 1 < headers.len and (headers[stop + 1] == ' ' or headers[stop + 1] == '\t')) {
                stop = std.mem.indexOfScalarPos(u8, headers, stop + 1, '\n') orelse headers.len;
            }
            return headers[start + name.len .. stop];
        }
        start = end + 1;
    }
    return null;
}

/// The result one method reported ("fail" for "dmarc=fail"), or null when
/// the method is not in the header. Only a name standing at the start of a
/// result counts, so "arc=" is not read out of "dmarc=".
pub fn methodResult(results: []const u8, method: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.ascii.findIgnoreCasePos(results, from, method)) |at| {
        from = at + 1;
        const equals = at + method.len;
        if (equals >= results.len or results[equals] != '=') continue;
        if (at > 0 and std.mem.indexOfScalar(u8, "; \t\r\n", results[at - 1]) == null) continue;
        var end = equals + 1;
        while (end < results.len and std.ascii.isAlphanumeric(results[end])) end += 1;
        if (end > equals + 1) return results[equals + 1 .. end];
    }
    return null;
}

/// Methods and results are keywords, which RFC 8601 section 2.2 makes
/// case-insensitive.
fn resultIs(results: []const u8, method: []const u8, wanted: []const u8) bool {
    const result = methodResult(results, method) orelse return false;
    return std.ascii.eqlIgnoreCase(result, wanted);
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

test "headerVerdict catches a From address its domain does not vouch for" {
    // A forger writing as an allowlisted domain from their own server: SPF
    // and DKIM pass for the forger's domain, DMARC fails for the From one.
    const forged =
        "Delivered-To: owner@example.net\r\n" ++
        "Received: by 2002:a05:6000:1::1 with SMTP id x; Mon, 5 Oct 2026 09:00:00 -0700\r\n" ++
        "Authentication-Results: mx.google.com;\r\n" ++
        "       dkim=pass header.i=@forger.example header.s=s1;\r\n" ++
        "       spf=pass (google.com: domain of x@forger.example designates 192.0.2.1 as permitted sender) smtp.mailfrom=x@forger.example;\r\n" ++
        "       dmarc=fail (p=NONE sp=NONE dis=NONE) header.from=allowlisted.example\r\n" ++
        "From: Boss <boss@allowlisted.example>\r\n";
    try std.testing.expect(headerVerdict(forged) != null);
    try std.testing.expect(headerVerdict("Authentication-Results: mx.google.com; DMARC=Fail header.from=x.example") != null);

    // Errors and a missing policy are not a forgery.
    try std.testing.expect(headerVerdict("Authentication-Results: mx.google.com; dmarc=temperror header.from=x.example") == null);
    try std.testing.expect(headerVerdict("Authentication-Results: mx.google.com; dmarc=none header.from=x.example") == null);
}

test "headerVerdict reads only the receiving server's own results" {
    // A failure further down is an earlier hop's or the sender's own; the
    // receiver's verdict above it is the one that counts.
    const forwarded =
        "Authentication-Results: mx.google.com; spf=pass; dkim=pass; dmarc=pass\r\n" ++
        "Received: from relay.example by mx.example\r\n" ++
        "Authentication-Results: relay.example; dkim=fail; dmarc=fail\r\n";
    try std.testing.expect(headerVerdict(forwarded) == null);

    // A sender cannot vouch for itself below the receiver's failure.
    const self_vouched =
        "Authentication-Results: mx.google.com;\r\n\tdmarc=fail header.from=allowlisted.example\r\n" ++
        "Authentication-Results: mx.google.com; dmarc=pass\r\n";
    try std.testing.expect(headerVerdict(self_vouched) != null);

    // The ARC copy is a different field, and a fail in it alone is not read.
    const arc_only =
        "ARC-Authentication-Results: i=1; mx.google.com; dmarc=fail\r\n" ++
        "Authentication-Results: mx.google.com; dmarc=pass\r\n";
    try std.testing.expect(headerVerdict(arc_only) == null);
}

test "methodResult reads a method only where a result starts" {
    const results = " mx.google.com; arc=pass (i=1); dmarc=fail (p=NONE) header.from=x.example";
    try std.testing.expectEqualStrings("fail", methodResult(results, "dmarc").?);
    try std.testing.expectEqualStrings("pass", methodResult(results, "arc").?);
    try std.testing.expect(methodResult(" mx.google.com; dmarc=fail", "arc") == null);
    try std.testing.expect(methodResult(" mx.google.com; spf=pass", "dkim") == null);

    // The field ends where the next header starts, folded lines included.
    const headers = "Authentication-Results: mx.google.com;\r\n spf=pass\r\nSubject: dkim=fail\r\n";
    try std.testing.expect(methodResult(receiverResults(headers).?, "dkim") == null);
    try std.testing.expectEqualStrings("pass", methodResult(receiverResults(headers).?, "spf").?);
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

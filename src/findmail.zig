//! Finding mail by what it is about, not who sent it.
//!
//! Port of `ronny/find_mail.py`. Three stages, and deliberately no local
//! index: the mailbox holds tens of thousands of messages, and embedding all
//! of it would be a lot of machinery to keep fresh for a personal tool when
//! Gmail already maintains a good full-text index for free.
//!
//!   1. the local model turns the question into Gmail search terms
//!   2. Gmail returns candidates -- fast, high recall, routinely far too many
//!      ("invoice" alone matches over a thousand)
//!   3. the local model ranks those candidates against the original question,
//!      which is where the precision comes from
//!
//! Stage 3 reads message bodies, so it runs locally and never on a hosted
//! service -- the same boundary as the spam gate. Only the routing decision,
//! which is just the owner's chat command, goes to Jev.

const std = @import("std");
const imap = @import("imap.zig");
const ollama = @import("ollama.zig");

const log = std.log.scoped(.findmail);

/// Gmail's recall is the point of stage 2, but fetching bodies is the
/// expensive part, so the candidate list is capped well below what Gmail
/// returns.
pub const CANDIDATE_LIMIT = 20;
pub const RESULT_LIMIT = 5;
pub const SNIPPET_CHARS = 400;
pub const DEFAULT_DAYS = 365;

/// Room to drop bulk mail and still have a full candidate list. Bounded
/// tightly because each candidate costs its own IMAP round trip -- Python
/// fetched them in one batch, which libetpan does not make easy -- so this is
/// the difference between a two-second answer and a thirty-second one.
const SCAN_LIMIT = CANDIDATE_LIMIT * 2;

pub const Error = error{SearchFailed};

pub const Candidate = struct {
    uid: u32,
    from: []const u8,
    subject: []const u8,
    date: []const u8,
    snippet: []const u8,
};

pub const Match = struct {
    candidate: Candidate,
    /// The model's one-line justification, or empty when ranking was skipped.
    why: []const u8 = "",
};

pub const Found = struct {
    /// The Gmail query actually used. Shown to the owner when nothing matched,
    /// since a bad query and an empty mailbox look identical otherwise.
    query: []const u8,
    matches: []const Match,
};

/// Turns a natural question into Gmail search terms.
///
/// Falls back to the raw question, which Gmail handles acceptably as a bag of
/// words, when the model is unavailable or unhelpful.
pub fn buildQuery(
    io: std.Io,
    arena: std.mem.Allocator,
    ollama_url: []const u8,
    model: []const u8,
    question: []const u8,
    days: u16,
) ![]const u8 {
    const prompt = try std.fmt.allocPrint(arena,
        \\Convert this request into a Gmail search query.
        \\People rarely word an email the way the request words it, so include likely alternative phrasings joined with OR inside parentheses -- the words that would actually appear in such an email.
        \\Example: a request about someone proposing a meeting time becomes
        \\(calendly OR schedule OR availability OR invitation OR "are you free")
        \\Drop filler like 'find' or 'the email about'. Do not add from:, newer_than: or category: operators. Reply with the query only.
        \\
        \\Request: {s}
    , .{question});

    const answer = ollama.generate(io, arena, ollama_url, model, prompt, .text) catch |err| blk: {
        log.warn("query building failed ({s}); using the raw question", .{@errorName(err)});
        break :blk question;
    };

    // Models like to explain themselves on a second line, and to quote.
    var first_line = answer;
    if (std.mem.indexOfScalar(u8, first_line, '\n')) |nl| first_line = first_line[0..nl];
    first_line = std.mem.trim(u8, first_line, " \t\r\"");
    if (first_line.len == 0) first_line = question;
    first_line = try balanceQuotes(arena, first_line);
    first_line = try trimToTerms(arena, first_line);

    // Filtering promotions Gmail-side is far cheaper than fetching newsletters
    // and discarding them; isBulk below stays as a backstop for the rest.
    const query = try std.fmt.allocPrint(arena, "newer_than:{d}d {s} -category:promotions", .{ days, first_line });
    log.info("gmail query: {s}", .{query});
    return query;
}

/// A Gmail query worth sending. Past this the model has stopped generating
/// alternative phrasings and started generating variations on its own
/// variations: one real run produced 47 OR terms, over half of them exact
/// duplicates, and broadening a query that far is the same as not filtering.
const MAX_QUERY_CHARS = 400;

/// Cuts an over-long query back at an OR boundary, closing any parenthesis
/// the cut left open so what goes to Gmail is still a valid query.
fn trimToTerms(arena: std.mem.Allocator, query: []const u8) ![]const u8 {
    if (query.len <= MAX_QUERY_CHARS) return query;

    const head = query[0..MAX_QUERY_CHARS];
    const cut = std.mem.lastIndexOf(u8, head, " OR ") orelse return head;
    const trimmed = std.mem.trim(u8, head[0..cut], " \t");
    log.warn("query ran long ({d} chars); cut back to its first terms", .{query.len});

    var open: usize = 0;
    var close: usize = 0;
    for (trimmed) |ch| {
        if (ch == '(') open += 1;
        if (ch == ')') close += 1;
    }
    if (open <= close) return trimmed;

    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll(trimmed);
    try out.writer.splatByteAll(')', open - close);
    return out.writer.buffered();
}

/// Strips every quote when they don't pair up.
///
/// Observed in practice: the model produced
///   (self-hosted OR "self hosted" OR ...) deployment OR "self-hosted deployment
/// with the last quote never closed. Gmail accepted it and quietly returned
/// almost nothing, which reads from the outside like an empty mailbox. Dropping
/// the quotes turns the phrase back into a bag of words, which is what an
/// unquoted query means anyway.
fn balanceQuotes(arena: std.mem.Allocator, query: []const u8) ![]const u8 {
    var quotes: usize = 0;
    for (query) |ch| {
        if (ch == '"') quotes += 1;
    }
    if (quotes % 2 == 0) return query;

    log.warn("model returned an unbalanced quote; dropping quotes from the query", .{});
    var out: std.Io.Writer.Allocating = .init(arena);
    for (query) |ch| {
        if (ch != '"') try out.writer.writeByte(ch);
    }
    return out.writer.buffered();
}

/// Newsletters and marketing blasts announce themselves. Their boilerplate
/// matches almost any generic phrase, so they drown out real correspondence
/// in the candidate list unless they are filtered out.
fn isBulk(message_headers: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(message_headers, "list-unsubscribe:") != null or
        std.ascii.indexOfIgnoreCase(message_headers, "list-id:") != null;
}

/// Readable text for the ranker.
///
/// HTML-only mail otherwise reaches the model as raw markup
/// ("<!DOCTYPE html>..."), which tells it nothing about the content.
fn snippet(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var in_tag = false;
    var pending_space = false;
    var written: usize = 0;

    var i: usize = 0;
    while (i < body.len and written < SNIPPET_CHARS) {
        const ch = body[i];

        // Script and style bodies are noise even after tag stripping.
        if (ch == '<' and (std.ascii.startsWithIgnoreCase(body[i..], "<script") or
            std.ascii.startsWithIgnoreCase(body[i..], "<style")))
        {
            const close: []const u8 = if (std.ascii.startsWithIgnoreCase(body[i..], "<script")) "</script" else "</style";
            i += (std.ascii.indexOfIgnoreCase(body[i..], close) orelse (body.len - i));
            in_tag = true;
            continue;
        }
        if (ch == '<') {
            in_tag = true;
            i += 1;
            continue;
        }
        if (ch == '>') {
            in_tag = false;
            pending_space = true;
            i += 1;
            continue;
        }
        i += 1;
        if (in_tag) continue;

        if (std.ascii.isWhitespace(ch)) {
            pending_space = true;
            continue;
        }
        if (pending_space and written > 0) {
            try out.writer.writeByte(' ');
            written += 1;
        }
        pending_space = false;
        try out.writer.writeByte(ch);
        written += 1;
    }
    return out.writer.buffered();
}

/// Runs the Gmail search and fetches enough of each hit to rank it.
///
/// Fetching is the slow part -- one round trip per candidate -- which is why
/// SCAN_LIMIT is bounded and personal mail short-circuits the loop.
pub fn collect(
    arena: std.mem.Allocator,
    session: *imap.Session,
    query: [:0]const u8,
) Error![]const Candidate {
    var uid_buffer: [SCAN_LIMIT]imap.Envelope = undefined;
    const hits = session.searchGmail(query, &uid_buffer) catch return Error.SearchFailed;
    if (hits.len == 0) return &.{};

    var personal: std.ArrayList(Candidate) = .empty;
    var bulk: std.ArrayList(Candidate) = .empty;

    // Newest first: a question about "the email where X said Y" is far more
    // often recent than ancient.
    var index = hits.len;
    while (index > 0 and personal.items.len < CANDIDATE_LIMIT) {
        index -= 1;
        const envelope = &hits[index];

        var message: imap.Message = undefined;
        session.fetchMessage(envelope.uid, &message) catch continue;

        const candidate: Candidate = .{
            .uid = envelope.uid,
            .from = arena.dupe(u8, envelope.fromSlice()) catch return Error.SearchFailed,
            .subject = arena.dupe(u8, envelope.subjectSlice()) catch return Error.SearchFailed,
            .date = arena.dupe(u8, envelope.dateSlice()) catch return Error.SearchFailed,
            .snippet = snippet(arena, message.bodySlice()) catch return Error.SearchFailed,
        };

        const target = if (isBulk(message.headersSlice())) &bulk else &personal;
        target.append(arena, candidate) catch return Error.SearchFailed;
    }

    if (bulk.items.len > 0) {
        log.info("set aside {d} bulk message(s) from the candidates", .{bulk.items.len});
    }
    // Real correspondence first, but fall back to bulk rather than telling the
    // owner nothing exists when only newsletters matched.
    const chosen = if (personal.items.len > 0) personal.items else bulk.items;
    return chosen[0..@min(chosen.len, CANDIDATE_LIMIT)];
}

const RankedMatch = struct { index: i64 = -1, why: []const u8 = "" };
const Ranking = struct { matches: []RankedMatch = &.{} };

/// Picks the candidates that actually answer the question.
///
/// Runs locally because it reads message bodies. Falls back to recency when
/// the model can't be reached -- a recency-ordered answer is still useful,
/// and it is honest about being unranked because every `why` comes back empty.
pub fn rank(
    io: std.Io,
    arena: std.mem.Allocator,
    ollama_url: []const u8,
    model: []const u8,
    question: []const u8,
    candidates: []const Candidate,
) []const Match {
    const byRecency = struct {
        fn call(a: std.mem.Allocator, items: []const Candidate) []const Match {
            var out: std.ArrayList(Match) = .empty;
            for (items[0..@min(items.len, RESULT_LIMIT)]) |candidate| {
                out.append(a, .{ .candidate = candidate }) catch break;
            }
            return out.items;
        }
    }.call;

    if (candidates.len <= 1) return byRecency(arena, candidates);

    var listing: std.Io.Writer.Allocating = .init(arena);
    for (candidates, 0..) |candidate, i| {
        listing.writer.print("[{d}] From: {s} | Subject: {s} | {s}\n", .{
            i, candidate.from, candidate.subject,
            candidate.snippet[0..@min(candidate.snippet.len, 250)],
        }) catch return byRecency(arena, candidates);
    }

    const prompt = std.fmt.allocPrint(arena,
        \\Below are candidate emails. Pick the ones that genuinely answer the user's request, best first. Ignore candidates that merely share a keyword. If none are a real match, return an empty list.
        \\
        \\Request: {s}
        \\
        \\Candidates:
        \\{s}
        \\
        \\Reply with ONLY JSON: {{"matches": [{{"index": <number>, "why": "<short reason>"}}]}}
    , .{ question, listing.writer.buffered() }) catch return byRecency(arena, candidates);

    const raw = ollama.generate(io, arena, ollama_url, model, prompt, .json) catch |err| {
        log.warn("ranking failed ({s}); returning the most recent candidates", .{@errorName(err)});
        return byRecency(arena, candidates);
    };

    const parsed = std.json.parseFromSlice(Ranking, arena, raw, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        log.warn("ranking reply didn't parse ({s}): {s}", .{
            @errorName(err), raw[0..@min(raw.len, 300)],
        });
        return byRecency(arena, candidates);
    };

    var out: std.ArrayList(Match) = .empty;
    for (parsed.value.matches) |match| {
        if (out.items.len >= RESULT_LIMIT) break;
        if (match.index < 0 or match.index >= candidates.len) continue;
        out.append(arena, .{
            .candidate = candidates[@intCast(match.index)],
            .why = match.why[0..@min(match.why.len, 160)],
        }) catch break;
    }

    // An empty list is a legitimate answer -- the model looked and found
    // nothing that genuinely matched, which beats handing back five keyword
    // hits -- but it is also what a subtly wrong reply shape looks like, so
    // the raw text is logged to tell the two apart.
    if (out.items.len == 0) {
        log.info("ranker matched none of {d} candidate(s); it replied: {s}", .{
            candidates.len, raw[0..@min(raw.len, 300)],
        });
    }
    return out.items;
}

/// The whole pipeline. Everything returned borrows from `arena`.
pub fn find(
    io: std.Io,
    arena: std.mem.Allocator,
    session: *imap.Session,
    ollama_url: []const u8,
    model: []const u8,
    question: []const u8,
    days: ?u16,
) !Found {
    const query = try buildQuery(io, arena, ollama_url, model, question, days orelse DEFAULT_DAYS);
    const query_z = try arena.dupeZ(u8, query);

    const candidates = try collect(arena, session, query_z);
    log.info("gmail returned {d} candidate(s)", .{candidates.len});
    if (candidates.len == 0) return .{ .query = query, .matches = &.{} };

    return .{
        .query = query,
        .matches = rank(io, arena, ollama_url, model, question, candidates),
    };
}

test "snippet turns HTML-only mail into something the ranker can read" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const html =
        "<!DOCTYPE html><html><head><style>body{color:red}</style></head>" ++
        "<body><p>Pricing   discussion</p><p>Thursday works</p></body></html>";

    const text = try snippet(arena, html);
    try std.testing.expectEqualStrings("Pricing discussion Thursday works", text);
}

test "snippet leaves plain text alone apart from collapsing whitespace" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try snippet(arena, "  Hi there,\r\n\r\nThursday works for me.\n");
    try std.testing.expectEqualStrings("Hi there, Thursday works for me.", text);
}

test "an unbalanced quote is stripped rather than sent to Gmail" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Shortened from a query a model actually produced.
    const broken = "(self-hosted OR \"self hosted\") OR \"self-hosted deployment";
    try std.testing.expectEqualStrings(
        "(self-hosted OR self hosted) OR self-hosted deployment",
        try balanceQuotes(arena, broken),
    );

    // A well-formed query is passed through untouched.
    const fine = "(invoice OR \"payment due\")";
    try std.testing.expectEqualStrings(fine, try balanceQuotes(arena, fine));
}

test "isBulk spots newsletters by their own headers" {
    try std.testing.expect(isBulk("List-Unsubscribe: <https://example.com/u>\r\n"));
    try std.testing.expect(isBulk("list-id: <news.example.com>\r\n"));
    try std.testing.expect(!isBulk("From: sam@example.com\r\nSubject: Thursday\r\n"));
}

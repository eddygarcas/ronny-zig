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
const rerank = @import("rerank.zig");

const log = std.log.scoped(.findmail);

/// Gmail's recall is the point of stage 2, but fetching bodies is the
/// expensive part, so the candidate list is capped well below what Gmail
/// returns.
pub const CANDIDATE_LIMIT = 20;
pub const RESULT_LIMIT = 5;
pub const SNIPPET_CHARS = 400;
/// How much of a body is read looking for the matched words. A 250-character
/// window taken from the top of the message is what the ranker used to see,
/// while Gmail had matched on the whole body -- so a mention below the
/// greeting was invisible and the ranker rejected mail that did match.
pub const SCAN_CHARS = 6000;
pub const DEFAULT_DAYS = 365;

/// Room to drop bulk mail and still have a full candidate list. Bounded
/// tightly because each candidate costs its own IMAP round trip -- Python
/// fetched them in one batch, which libetpan does not make easy -- so this is
/// the difference between a two-second answer and a thirty-second one.
/// How many matches are looked at before choosing which to read.
///
/// Wider than CANDIDATE_LIMIT because the newest matches are not always the
/// relevant ones: "InfluxDB" matches 111 messages in this mailbox, and taking
/// the newest 20 means a thread from two months ago is never considered.
/// Envelopes arrive in one batched FETCH, so widening this is nearly free --
/// it is fetching *bodies* that costs, and that stays at CANDIDATE_LIMIT.
const SCAN_LIMIT = CANDIDATE_LIMIT * 4;

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
/// The search terms for a question, in the order the owner would recognise:
/// their own wording first, invented synonyms last.
pub fn buildTerms(
    io: std.Io,
    arena: std.mem.Allocator,
    ollama_url: []const u8,
    model: []const u8,
    question: []const u8,
) ![]const []const u8 {
    const prompt = try std.fmt.allocPrint(arena,
        \\Convert this request into a Gmail search query.
        \\People rarely word an email the way the request words it, so include likely alternative phrasings joined with OR inside parentheses -- the words that would actually appear in such an email.
        \\Example: a request about someone proposing a meeting time becomes
        \\(calendly OR schedule OR availability OR invitation OR "are you free")
        \\Put the user's own wording FIRST, before any alternative you add -- the literal phrase they used, then its obvious spelling variants, then looser synonyms last.
        \\Quote any term of more than one word: "influx db", not influx db.
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
    first_line = try stripOperators(arena, first_line);

    const terms = try cleanTerms(arena, try parseTerms(arena, first_line));
    if (terms.len == 0) return cleanTerms(arena, try parseTerms(arena, question));
    return terms;
}

/// Gmail search operators the model is told not to emit, and does anyway.
///
/// Observed live: asked for "the last invoice email from AcmeSync", it
/// produced `(...) FROM AcmeSync`. Gmail needs `from:` with a colon, so bare
/// `FROM` became a literal word that had to appear in the message, and the
/// search returned nothing at all -- which reads from the outside exactly
/// like an empty mailbox.
///
/// The prompt already forbids these. It is the third thing that prompt has
/// been ignored about today, after quoting and length, so the rule is
/// enforced here instead of requested there.
const OPERATORS = [_][]const u8{
    "from",  "to",     "cc",    "bcc",      "subject", "label",
    "has",   "in",     "is",    "category", "filename", "list",
    "newer", "older",  "newer_than", "older_than", "after", "before",
    "larger", "smaller", "rfc822msgid", "deliveredto",
};

fn isOperatorToken(token: []const u8) bool {
    // `from:` and friends, with the colon.
    if (std.mem.indexOfScalar(u8, token, ':')) |colon| {
        const name = token[0..colon];
        for (OPERATORS) |operator| {
            if (std.ascii.eqlIgnoreCase(name, operator)) return true;
        }
        return false;
    }
    // Bare `FROM`, which is how it actually came out. Only all-caps, so the
    // ordinary English words are left alone -- "invoice from AcmeSync" in a
    // quoted phrase is a legitimate search term.
    for (token) |ch| {
        if (std.ascii.isLower(ch)) return false;
    }
    for (OPERATORS) |operator| {
        if (std.ascii.eqlIgnoreCase(token, operator)) return true;
    }
    return false;
}

/// Drops operator tokens the model added on its own. The caller supplies the
/// date window and the promotions filter; nothing else belongs here.
fn stripOperators(arena: std.mem.Allocator, query: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var dropped: usize = 0;

    var quoted = false;
    var tokens = std.mem.tokenizeAny(u8, query, " \t");
    while (tokens.next()) |token| {
        // Never touch anything inside a quoted phrase.
        if (!quoted and isOperatorToken(token)) {
            dropped += 1;
            continue;
        }
        for (token) |ch| {
            if (ch == '"') quoted = !quoted;
        }
        if (out.writer.buffered().len > 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(token);
    }

    if (dropped == 0) return query;
    log.warn("dropped {d} search operator(s) the model added on its own", .{dropped});
    return out.writer.buffered();
}

/// Splits whatever the model returned into search terms.
///
/// Deliberately indifferent to the shape it used. Every pass below used to
/// key on a parenthesised group, and the model simply stopped emitting one:
///
///   newer_than:365d influx db OR influx db OR influxdb OR time series database
///
/// No parentheses, so quoting, de-duplication, exact-match pinning and the
/// narrow-first ladder all silently did nothing, and the search went out with
/// `influx db` meaning `influx AND db`. Depending on a model's formatting is
/// the same mistake as depending on its content. The terms are parsed out,
/// operated on as a list, and the query is rendered here -- so the only thing
/// taken from the model is which words to look for.
fn parseTerms(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var terms: std.ArrayList([]const u8) = .empty;

    // Anything outside a group is still terms; the parens carry no meaning
    // once the query is re-rendered.
    var body = std.mem.trim(u8, text, " \t");
    if (std.mem.indexOfScalar(u8, body, '(')) |open| {
        if (std.mem.lastIndexOfScalar(u8, body, ')')) |close| {
            if (close > open + 1) body = body[open + 1 .. close];
        }
    }

    var start: usize = 0;
    var i: usize = 0;
    while (i < body.len) {
        // " OR " in any case, and only outside quotes.
        if (body[i] == '"') {
            i += 1;
            while (i < body.len and body[i] != '"') i += 1;
            i += 1;
            continue;
        }
        if (i + 4 <= body.len and body[i] == ' ' and
            std.ascii.eqlIgnoreCase(body[i + 1 .. @min(body.len, i + 3)], "or") and
            i + 3 < body.len and body[i + 3] == ' ')
        {
            try appendTerm(arena, &terms, body[start..i]);
            i += 4;
            start = i;
            continue;
        }
        i += 1;
    }
    try appendTerm(arena, &terms, body[start..]);

    // If quote-aware splitting produced a single term that still reads as a
    // list, the quoting was malformed and the scan skipped over the
    // separators. Seen live: the whole answer came back as one term, and the
    // keyword fallback then chopped it on spaces, producing search terms like
    // `migration"` and `"influx`. Retry ignoring quotes entirely -- a bag of
    // words beats one nonsense phrase.
    if (terms.items.len == 1 and looksLikeList(terms.items[0])) {
        log.warn("could not split the query on quotes; splitting on OR alone", .{});
        var flat: std.ArrayList([]const u8) = .empty;
        var parts = std.mem.splitSequence(u8, terms.items[0], " ");
        var current: std.ArrayList(u8) = .empty;
        while (parts.next()) |word| {
            if (std.ascii.eqlIgnoreCase(word, "OR")) {
                try appendTerm(arena, &flat, current.items);
                current = .empty;
                continue;
            }
            if (current.items.len > 0) try current.append(arena, ' ');
            try current.appendSlice(arena, word);
        }
        try appendTerm(arena, &flat, current.items);
        if (flat.items.len > 1) return flat.items;
    }

    return terms.items;
}

/// A term that still contains a bare " OR " separator was never really one
/// term.
fn looksLikeList(term: []const u8) bool {
    var parts = std.mem.splitSequence(u8, term, " ");
    while (parts.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, "OR")) return true;
    }
    return false;
}

fn appendTerm(arena: std.mem.Allocator, terms: *std.ArrayList([]const u8), raw: []const u8) !void {
    const term = std.mem.trim(u8, raw, " \t()");
    if (term.len == 0) return;
    if (std.ascii.eqlIgnoreCase(term, "or")) return;
    // An operator the model added on its own is not a search term.
    if (std.mem.indexOfScalar(u8, term, ':') != null) return;
    try terms.append(arena, term);
}

/// Quotes multi-word terms, drops repeats, and pins distinctive names.
///
/// Observed live, asked twice for the same thing:
///
///   (InfluxDB OR influx db OR "influx db" OR influxdb OR "influx db" OR influx db)
///   (InfluxDB OR influxdb)
///
/// The second found the mail. The first found seven unrelated messages --
/// calendar invitations, wiki notifications -- because a bare `influx db` is
/// not one term to Gmail, it is `influx AND db`, and a space binds tighter
/// than OR. The group stopped meaning "any of these". From the outside that
/// is indistinguishable from "there is no such email", which is what the
/// owner was told.
fn cleanTerms(arena: std.mem.Allocator, terms: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;

    for (terms) |raw| {
        if (out.items.len >= MAX_TERMS) break;

        // Every quote goes, not just the ones at the ends. A term that kept
        // an internal one went out as
        //   ... OR "consolidated job" 24th September" OR ...
        // which is a broken query: the quote that should have closed the
        // phrase opened a new one, and everything after it shifted meaning.
        const bare = try stripQuotes(arena, std.mem.trim(u8, raw, " \t+"));
        if (bare.len == 0) continue;

        // Gmail search is case-insensitive, so a case variant is not a second
        // term -- it is the same search run twice.
        var seen = false;
        for (out.items) |existing| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, existing, "\"+"), bare)) seen = true;
        }
        if (seen) continue;

        if (std.mem.indexOfScalar(u8, bare, ' ') != null) {
            try out.append(arena, try std.fmt.allocPrint(arena, "\"{s}\"", .{bare}));
        } else if (isDistinctive(bare)) {
            try out.append(arena, try std.fmt.allocPrint(arena, "+{s}", .{bare}));
        } else {
            try out.append(arena, bare);
        }
    }
    return out.items;
}

/// Forces exact matching on distinctive terms.
///
/// Gmail stems and expands by default, so a product name matches anything
/// sharing a root and a search for "Influx" drags in "influence". A leading
/// `+` turns that off for one term -- documented in Gmail's operator list
/// alongside AROUND and the brace form of OR.
///
/// Applied only to single words carrying an internal capital or a digit --
/// InfluxDB, S3, RZPT-3989 -- which are names rather than vocabulary. Doing
/// it to ordinary words would be worse than useless: "invoice" would stop
/// matching "invoices".
fn isDistinctive(term: []const u8) bool {
    // Two is enough: "S3" is a name, and a short one is exactly the kind
    // that stemming mangles.
    if (term.len < 2 or term.len > 40) return false;
    if (std.mem.indexOfScalar(u8, term, ' ') != null) return false;

    for (term[1..]) |ch| {
        if (std.ascii.isUpper(ch) or std.ascii.isDigit(ch)) return true;
    }
    return false;
}

fn stripQuotes(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '"') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    for (text) |ch| {
        if (ch != '"') try out.append(arena, ch);
    }
    return std.mem.trim(u8, out.items, " \t");
}

/// Words too ordinary to search on their own.
const STOPWORDS = [_][]const u8{
    "the",   "and",   "for",   "with",  "from",  "that",  "this",  "about",
    "email", "mail",  "message", "find", "search", "was",  "were",  "has",
    "have",  "into",  "our",   "your",  "their", "there", "where", "when",
    "what",  "which", "would", "could", "should", "been", "being", "some",
};

fn isStopword(word: []const u8) bool {
    for (STOPWORDS) |stop| {
        if (std.ascii.eqlIgnoreCase(word, stop)) return true;
    }
    return false;
}

/// The individual words behind the phrases, as a last resort.
///
/// Quoting a multi-word term is right -- unquoted, Gmail reads it as AND --
/// but it also makes it an exact phrase, and the model likes to answer a
/// request with phrases rather than words. Asked about "the InfluxDB
/// migration" it produced only
///   "influxdb migration" OR "influx db migration" OR "migrating to influxdb"
/// none of which appears verbatim in any message, so the search returned
/// nothing at all -- and nothing reads as "you have no such email" when the
/// thread is sitting right there.
///
/// So when phrases find nothing, the phrases are broken into their words and
/// the distinctive ones are searched instead.
fn keywordTerms(arena: std.mem.Allocator, terms: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;

    for (terms) |term| {
        var words = std.mem.tokenizeAny(u8, term, " \t-");
        while (words.next()) |raw| {
            // Strip punctuation from both ends rather than only the term's,
            // so a quote that survived the split cannot reach the query.
            const word = std.mem.trim(u8, raw, "\"'+.,;:()[]!?");
            if (word.len < 3 or isStopword(word)) continue;
            if (std.ascii.eqlIgnoreCase(word, "or")) continue;
            if (out.items.len >= MAX_TERMS) break;

            var seen = false;
            for (out.items) |existing| {
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, existing, "+"), word)) seen = true;
            }
            if (seen) continue;

            if (isDistinctive(word)) {
                try out.append(arena, try std.fmt.allocPrint(arena, "+{s}", .{word}));
            } else {
                try out.append(arena, word);
            }
        }
    }
    return out.items;
}

/// The canonical query. The only thing that came from the model is the words.
pub fn renderQuery(arena: std.mem.Allocator, terms: []const []const u8, days: u16) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.print("newer_than:{d}d (", .{days});
    for (terms, 0..) |term, i| {
        if (i > 0) try out.writer.writeAll(" OR ");
        try out.writer.writeAll(term);
    }
    // Filtering promotions Gmail-side is far cheaper than fetching newsletters
    // and discarding them; isBulk stays as a backstop for the rest.
    try out.writer.writeAll(") -category:promotions");
    return out.writer.buffered();
}

/// Past this the model has stopped generating alternative phrasings and
/// started generating variations on its own variations: one real run produced
/// 47 OR terms, over half of them exact duplicates, and broadening a query
/// that far is the same as not filtering.
const MAX_TERMS = 8;

/// A Gmail query worth sending. Past this the model has stopped generating
/// alternative phrasings and started generating variations on its own
/// variations: one real run produced 47 OR terms, over half of them exact
/// duplicates, and broadening a query that far is the same as not filtering.
const MAX_QUERY_CHARS = 400;


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

/// Readable text, tags stripped and whitespace collapsed.
///
/// HTML-only mail otherwise reaches the model as raw markup
/// ("<!DOCTYPE html>..."), which tells it nothing about the content.
///
/// Reads far more than the ranker will be shown, because `excerpt` has to
/// find the matching words before it can decide which part to show.
fn stripTags(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var in_tag = false;
    var pending_space = false;
    var written: usize = 0;

    var i: usize = 0;
    while (i < body.len and written < SCAN_CHARS) {
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
/// The words Gmail actually matched on, read back out of the query.
///
/// Recovered from the query rather than the question because the question is
/// full of words that are not search terms ("find the email about ..."),
/// while the OR group is exactly what the server matched.
pub fn queryTerms(arena: std.mem.Allocator, query: []const u8) ![]const []const u8 {
    var terms: std.ArrayList([]const u8) = .empty;

    const open = std.mem.indexOfScalar(u8, query, '(');
    const close = std.mem.lastIndexOfScalar(u8, query, ')');
    if (open != null and close != null and close.? > open.? + 1) {
        var parts = std.mem.splitSequence(u8, query[open.? + 1 .. close.?], " OR ");
        while (parts.next()) |raw| {
            const term = std.mem.trim(u8, std.mem.trim(u8, raw, " \t"), "\"");
            if (term.len >= 3) try terms.append(arena, term);
        }
        return terms.items;
    }

    // No group: take the bare words, minus anything operator-shaped.
    var tokens = std.mem.tokenizeAny(u8, query, " \t");
    while (tokens.next()) |token| {
        if (std.mem.indexOfScalar(u8, token, ':') != null) continue;
        if (token[0] == '-') continue;
        const term = std.mem.trim(u8, token, "\"()");
        if (term.len >= 3) try terms.append(arena, term);
    }
    return terms.items;
}

/// Where the first search term appears in `text`.
fn firstTermAt(text: []const u8, terms: []const []const u8) ?usize {
    var earliest: ?usize = null;
    for (terms) |term| {
        if (std.ascii.indexOfIgnoreCase(text, term)) |at| {
            if (earliest == null or at < earliest.?) earliest = at;
        }
    }
    return earliest;
}

/// The part of `text` worth showing the ranker: a window around the first
/// match, or the opening when nothing matched.
///
/// The bug this fixes: Gmail searched the entire body, the ranker was shown
/// the first 250 characters of it, and mail whose only mention of the term
/// sat below the greeting was rejected as irrelevant. Asked for the email
/// about InfluxDB, the ranker was handed seven openings that read "Christian
/// has accepted this invitation" and correctly said none of them matched.
/// Showing it the part that matched is the whole point of having matched.
fn excerpt(text: []const u8, terms: []const []const u8) []const u8 {
    const head = text[0..@min(text.len, SNIPPET_CHARS)];
    const at = firstTermAt(text, terms) orelse return head;
    if (at < SNIPPET_CHARS) return head;

    // Leave a third of the window before the match, so it reads in context
    // rather than starting mid-sentence on the term itself.
    var start = at - SNIPPET_CHARS / 3;
    // Don't start mid-word.
    while (start > 0 and start < text.len and !std.ascii.isWhitespace(text[start - 1])) start -= 1;
    const end = @min(text.len, start + SNIPPET_CHARS);
    return text[start..end];
}

/// SCAN_LIMIT is bounded and personal mail short-circuits the loop.
pub fn collect(
    arena: std.mem.Allocator,
    session: *imap.Session,
    query: [:0]const u8,
    terms: []const []const u8,
) Error![]const Candidate {
    var uid_buffer: [SCAN_LIMIT]imap.Envelope = undefined;
    const hits = session.searchGmail(query, &uid_buffer) catch return Error.SearchFailed;
    if (hits.len == 0) return &.{};

    var personal: std.ArrayList(Candidate) = .empty;
    var bulk: std.ArrayList(Candidate) = .empty;

    // Read the ones whose subject names the thing first, then the rest in
    // recency order. Subject matching is free -- the envelopes are already
    // here -- while reading a body costs a round trip, so this decides which
    // bodies are worth fetching rather than just taking the newest.
    //
    // "The email about X" very often says X in its subject line, and before
    // this a subject-line match two months old lost to twenty newer messages
    // that merely mentioned the word somewhere.
    var order: std.ArrayList(usize) = .empty;
    for ([_]bool{ true, false }) |want_subject_match| {
        var i = hits.len;
        while (i > 0) {
            i -= 1;
            const matched = firstTermAt(hits[i].subjectSlice(), terms) != null;
            if (matched == want_subject_match) order.append(arena, i) catch return Error.SearchFailed;
        }
    }

    for (order.items) |index| {
        if (personal.items.len >= CANDIDATE_LIMIT) break;
        const envelope = &hits[index];

        var message: imap.Message = undefined;
        session.fetchMessage(envelope.uid, &message) catch continue;

        const candidate: Candidate = .{
            .uid = envelope.uid,
            .from = arena.dupe(u8, envelope.fromSlice()) catch return Error.SearchFailed,
            .subject = arena.dupe(u8, envelope.subjectSlice()) catch return Error.SearchFailed,
            .date = arena.dupe(u8, envelope.dateSlice()) catch return Error.SearchFailed,
            .snippet = excerpt(
                stripTags(arena, message.bodySlice()) catch return Error.SearchFailed,
                terms,
            ),
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
/// Scores every candidate in one request and sorts by the result.
fn rankWithJev(
    io: std.Io,
    arena: std.mem.Allocator,
    ranker: Ranker,
    question: []const u8,
    candidates: []const Candidate,
) ![]const Match {
    var items: std.ArrayList([]const u8) = .empty;
    for (candidates) |candidate| {
        try items.append(arena, try std.fmt.allocPrint(
            arena,
            "From: {s}\nDate: {s}\nSubject: {s}\n\n{s}",
            .{ candidate.from, candidate.date, candidate.subject, candidate.snippet },
        ));
    }

    const scores = try rerank.scores(
        io,
        arena,
        ranker.typesafe_api_key,
        ranker.jev_model,
        question,
        items.items,
    );
    defer arena.free(scores);

    const Scored = struct { candidate: Candidate, score: f64 };
    var scored: std.ArrayList(Scored) = .empty;
    for (candidates, scores) |candidate, score| {
        if (score >= rerank.MATCH_THRESHOLD) {
            try scored.append(arena, .{ .candidate = candidate, .score = score });
        }
    }

    std.mem.sort(Scored, scored.items, {}, struct {
        fn lessThan(_: void, a: Scored, b: Scored) bool {
            return a.score > b.score;
        }
    }.lessThan);

    var out: std.ArrayList(Match) = .empty;
    for (scored.items) |item| {
        if (out.items.len >= RESULT_LIMIT) break;
        try out.append(arena, .{
            .candidate = item.candidate,
            // Jev returns a number, not a sentence. Saying how sure it is
            // beats inventing a justification it never gave.
            .why = try std.fmt.allocPrint(arena, "relevance {d:.2}", .{item.score}),
        });
    }

    log.info("Jev ranked {d} of {d} candidate(s) above the threshold", .{
        out.items.len, candidates.len,
    });

    // Nothing cleared the bar, but a score is a measurement and the best one
    // is worth naming. "Nothing matched" was the original complaint, and
    // "here is the closest, and it is weak" is strictly more use than
    // silence -- the owner can tell in a second whether it is the message
    // they meant, which is exactly what the number cannot.
    if (out.items.len == 0) {
        var best: ?Scored = null;
        for (candidates, scores) |candidate, score| {
            if (best == null or score > best.?.score) {
                best = .{ .candidate = candidate, .score = score };
            }
        }
        if (best) |item| {
            try out.append(arena, .{
                .candidate = item.candidate,
                .why = try std.fmt.allocPrint(
                    arena,
                    "closest of {d}, relevance {d:.2} -- probably not the one",
                    .{ candidates.len, item.score },
                ),
            });
        }
    }
    return out.items;
}

/// Runs locally because it reads message bodies. Falls back to recency when
/// the model can't be reached -- a recency-ordered answer is still useful,
/// and it is honest about being unranked because every `why` comes back empty.
/// How the candidates get ordered.
///
/// Ranking is where the local model was weakest, and where a wrong answer is
/// silent: "no match" reads exactly like "you have no such email". Jev is
/// better at it, at the cost of sending message excerpts off the machine --
/// so it is off unless the owner turned it on.
pub const Ranker = struct {
    ollama_url: []const u8,
    model: []const u8,
    /// Empty disables the TypeSafe path entirely, whatever the flag says.
    typesafe_api_key: []const u8 = "",
    jev_model: []const u8 = "jev-latest",
    /// The owner's explicit decision to let mail excerpts leave the machine.
    use_typesafe: bool = false,
};

pub fn rank(
    io: std.Io,
    arena: std.mem.Allocator,
    ranker: Ranker,
    question: []const u8,
    candidates: []const Candidate,
) []const Match {
    const ollama_url = ranker.ollama_url;
    const model = ranker.model;
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

    // Jev first when allowed, local model as the fallback, recency as the
    // fallback's fallback. Each step down is a worse answer, never a missing
    // one.
    if (ranker.use_typesafe and ranker.typesafe_api_key.len > 0 and
        candidates.len <= rerank.MAX_QUESTIONS)
    {
        if (rankWithJev(io, arena, ranker, question, candidates)) |matches| {
            return matches;
        } else |err| {
            log.warn("Jev ranking unavailable ({s}); ranking locally", .{@errorName(err)});
        }
    }

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
    ranker: Ranker,
    question: []const u8,
    days: ?u16,
) !Found {
    const ollama_url = ranker.ollama_url;
    const model = ranker.model;
    // All Mail, not INBOX. Measured on a real 53k-message mailbox: "InfluxDB"
    // returns 91 hits in INBOX and 111 in All Mail, because archived mail has
    // left INBOX. `in:anywhere` does not reach it either -- also measured, 91
    // either way -- since IMAP confines X-GM-RAW to the selected mailbox.
    // "I know I got that email" is usually about something long since filed.
    _ = try session.examine(.all_mail);

    const window = days orelse DEFAULT_DAYS;
    const terms_all = try buildTerms(io, arena, ollama_url, model, question);

    // Narrow first, broad only if narrow came up short.
    //
    // The model expands a request into likely phrasings, which is what makes
    // vague questions work and what ruins precise ones. Asked for mail about
    // "Influx TV" it produced
    //   Influx TV OR "influx tv" OR streaming OR "online platform"
    //   OR "video content" OR "TV show" OR "media platform"
    // and the candidate list filled with newsletters that mention streaming.
    // The owner's own words are the best query when they are enough; the
    // synonyms are a fallback, not a default. Deciding *when* to broaden is a
    // count, so code does it rather than the prompt.
    const narrow_terms = terms_all[0..@min(terms_all.len, NARROW_TERMS)];

    var terms = narrow_terms;
    var query = try renderQuery(arena, terms, window);
    log.info("gmail query: {s}", .{query});
    var candidates = try collect(arena, session, try arena.dupeZ(u8, query), terms);

    if (candidates.len < ENOUGH_CANDIDATES and terms_all.len > narrow_terms.len) {
        log.info("narrow query found {d}; broadening", .{candidates.len});
        terms = terms_all;
        query = try renderQuery(arena, terms, window);
        log.info("gmail query: {s}", .{query});
        candidates = try collect(arena, session, try arena.dupeZ(u8, query), terms);
    }

    // Still nothing: the terms were all exact phrases that appear nowhere.
    // Search their words instead. A loose answer the ranker can filter beats
    // "no such email" about a thread that exists.
    if (candidates.len == 0) {
        const words = try keywordTerms(arena, terms_all);
        if (words.len > 0 and !sameTerms(words, terms)) {
            log.info("phrases matched nothing; falling back to their keywords", .{});
            terms = words;
            query = try renderQuery(arena, terms, window);
            log.info("gmail query: {s}", .{query});
            candidates = try collect(arena, session, try arena.dupeZ(u8, query), terms);
        }
    }

    log.info("gmail returned {d} candidate(s)", .{candidates.len});
    if (candidates.len == 0) return .{ .query = query, .matches = &.{} };

    return .{
        .query = query,
        .matches = rank(io, arena, ranker, question, candidates),
    };
}

fn sameTerms(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// Below this a search has not really found anything, so the synonyms are
/// worth the noise they bring. Above it they only dilute what is already
/// there.
pub const ENOUGH_CANDIDATES = 3;

/// How many terms count as "what the owner asked for" before it becomes
/// paraphrase. Two covers the common pair -- a name and its spacing variant,
/// "InfluxDB" and "influx db" -- without reaching the invented synonyms.
pub const NARROW_TERMS = 2;

test "stripTags turns HTML-only mail into something the ranker can read" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const html =
        "<!DOCTYPE html><html><head><style>body{color:red}</style></head>" ++
        "<body><p>Pricing   discussion</p><p>Thursday works</p></body></html>";

    const text = try stripTags(arena, html);
    try std.testing.expectEqualStrings("Pricing discussion Thursday works", text);
}

test "stripTags leaves plain text alone apart from collapsing whitespace" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try stripTags(arena, "  Hi there,\r\n\r\nThursday works for me.\n");
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

test "search operators the model invents are stripped" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Exactly what came back from a real request, which returned 0 results:
    // Gmail wants `from:` with a colon, so bare FROM had to appear as a word.
    try std.testing.expectEqualStrings(
        "(last invoice OR billing) AcmeSync",
        try stripOperators(arena, "(last invoice OR billing) FROM AcmeSync"),
    );
    try std.testing.expectEqualStrings(
        "invoice",
        try stripOperators(arena, "from:someone@x.com invoice newer_than:30d"),
    );

    // Ordinary words and quoted phrases are left alone -- "from" inside a
    // phrase is a legitimate search term, not an operator.
    const plain = "(invoice OR \"payment from AcmeSync\") billing";
    try std.testing.expectEqualStrings(plain, try stripOperators(arena, plain));
}


test "the excerpt shows where the term matched, not the top of the message" {
    // The real shape: a calendar-style opening, with the term only appearing
    // well past the 250 characters the ranker used to be shown.
    const opening = "Christian has accepted this invitation. Objectives review, Tuesday 11 Aug 2026 2:30pm to 3pm Central European Time Madrid. Join with Google Meet, join by phone, more phone numbers, view all guest info, reply for this event, notification settings. ";
    const body = opening ++ "Separately, the InfluxDB retention policy needs a decision before Friday.";
    const terms = [_][]const u8{"InfluxDB"};

    const shown = excerpt(body, &terms);
    try std.testing.expect(std.mem.indexOf(u8, shown, "InfluxDB") != null);

    // And the old behaviour would not have.
    try std.testing.expect(std.mem.indexOf(u8, body[0..250], "InfluxDB") == null);

    // A term near the top still reads from the top rather than jumping.
    const early = "InfluxDB is billing us again. Details below.";
    try std.testing.expectEqualStrings(early, excerpt(early, &terms));

    // No match anywhere: fall back to the opening rather than nothing.
    const unrelated = "Nothing to do with databases at all.";
    try std.testing.expectEqualStrings(unrelated, excerpt(unrelated, &terms));
}

test "query terms are read back out of the query, not the question" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const terms = try queryTerms(arena, "newer_than:365d (InfluxDB OR \"influx db\") -category:promotions");
    try std.testing.expectEqual(@as(usize, 2), terms.len);
    try std.testing.expectEqualStrings("InfluxDB", terms[0]);
    try std.testing.expectEqualStrings("influx db", terms[1]);

    // Operators and negations are not search terms.
    const bare = try queryTerms(arena, "newer_than:365d invoice -category:promotions");
    try std.testing.expectEqual(@as(usize, 1), bare.len);
    try std.testing.expectEqualStrings("invoice", bare[0]);
}


test "terms are parsed whatever shape the model returned them in" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // With parentheses, as the prompt asks for.
    const grouped = try parseTerms(arena, "(InfluxDB OR \"influx db\" OR influxdb)");
    try std.testing.expectEqual(@as(usize, 3), grouped.len);

    // Without them, as it actually came back one run -- the case that made
    // every later pass silently do nothing.
    const bare = try parseTerms(arena, "influx db OR influxdb OR time series database");
    try std.testing.expectEqual(@as(usize, 3), bare.len);
    try std.testing.expectEqualStrings("influx db", bare[0]);
    try std.testing.expectEqualStrings("time series database", bare[2]);

    // Lowercase "or" is still a separator; quoted text is not split.
    const mixed = try parseTerms(arena, "\"pricing or budget\" or invoice");
    try std.testing.expectEqual(@as(usize, 2), mixed.len);
    try std.testing.expectEqualStrings("\"pricing or budget\"", mixed[0]);
}

test "cleaning quotes phrases, pins names, and drops repeats" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The exact list behind the search that returned seven unrelated messages.
    const cleaned = try cleanTerms(arena, try parseTerms(
        arena,
        "InfluxDB OR influx db OR \"influx db\" OR influxdb OR \"influx db\" OR influx db",
    ));
    try std.testing.expectEqual(@as(usize, 2), cleaned.len);
    // A name is pinned exact so stemming cannot widen it.
    try std.testing.expectEqualStrings("+InfluxDB", cleaned[0]);
    // A multi-word term is quoted, or Gmail reads it as AND.
    try std.testing.expectEqualStrings("\"influx db\"", cleaned[1]);

    // Ordinary vocabulary must keep stemming: pinning "invoice" would stop it
    // matching "invoices", which is worse than not pinning at all.
    const words = try cleanTerms(arena, try parseTerms(arena, "invoice OR receipt"));
    try std.testing.expectEqualStrings("invoice", words[0]);
    try std.testing.expectEqualStrings("receipt", words[1]);

    try std.testing.expect(isDistinctive("S3"));
    try std.testing.expect(isDistinctive("RZPT-3989"));
    try std.testing.expect(!isDistinctive("Thursday"));
}

test "the rendered query is canonical whatever the model did" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const terms = try cleanTerms(arena, try parseTerms(arena, "influx db OR influxdb"));
    try std.testing.expectEqualStrings(
        "newer_than:365d (\"influx db\" OR influxdb) -category:promotions",
        try renderQuery(arena, terms, 365),
    );
}

test "phrases fall back to the words inside them" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The real failure: every term an exact phrase, none of them present
    // verbatim in any message, so the search returned nothing at all.
    const phrases = try cleanTerms(arena, try parseTerms(
        arena,
        "\"influxdb migration\" OR \"influx db migration\" OR \"migrating to influxdb\"",
    ));
    const words = try keywordTerms(arena, phrases);

    // The distinctive word survives. Written lowercase it carries no
    // internal capital, so it is not pinned -- the heuristic cannot tell
    // "influxdb" from a normal word, and guessing wrong towards pinning
    // would stop it stemming for no gain.
    try std.testing.expectEqualStrings("influxdb", words[0]);
    // The ordinary one is kept too, unpinned so it can still stem.
    try std.testing.expectEqualStrings("migration", words[1]);
    // "to" is too short and "migrating" is a duplicate root, but neither of
    // those matters as much as not emitting filler.
    for (words) |word| {
        try std.testing.expect(!std.ascii.eqlIgnoreCase(word, "the"));
        try std.testing.expect(!std.ascii.eqlIgnoreCase(word, "email"));
    }
}


test "a query the quote scan cannot split is still broken into terms" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Malformed quoting: an odd quote makes the scanner run past the
    // separators and return the lot as one term. Live, the keyword fallback
    // then searched for `migration"` and `"influx`.
    const terms = try parseTerms(arena, "\"influxdb migration OR \"influx db migration\" OR switch");
    try std.testing.expect(terms.len > 1);

    // Whatever the shape, no term may carry a stray quote into the query.
    const words = try keywordTerms(arena, terms);
    for (words) |word| {
        try std.testing.expect(std.mem.indexOfScalar(u8, word, '"') == null);
        try std.testing.expect(!std.ascii.eqlIgnoreCase(word, "or"));
    }
}

test "no term reaches the query carrying a quote" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Seen live: an unbalanced quote survived into a term, and the rendered
    // query read  ... OR "consolidated job" 24th September" OR ...
    const terms = try cleanTerms(arena, &.{ "\"consolidated job\" 24th September\"", "order" });
    for (terms) |term| {
        const inner = term[1 .. term.len - 1];
        try std.testing.expect(std.mem.indexOfScalar(u8, inner, '"') == null);
    }

    const query = try renderQuery(arena, terms, 365);
    var quotes: usize = 0;
    for (query) |ch| {
        if (ch == '"') quotes += 1;
    }
    try std.testing.expect(quotes % 2 == 0);
}

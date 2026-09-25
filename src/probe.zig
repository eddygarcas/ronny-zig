//! A scratch target for exercising one piece against the real mailbox.
//!
//! Read-only and Telegram-free on purpose: the Python service is still live,
//! and a second getUpdates poller on the same token would silently swallow the
//! owner's real messages.

const std = @import("std");
const imap = @import("imap.zig");
const findmail = @import("findmail.zig");
const headers = @import("headers.zig");
const mailer = @import("mailer.zig");
const intent = @import("intent.zig");
const contacts = @import("contacts.zig");
const summarize = @import("summarize.zig");

const VOCAB_ENTRY = 96;
const VOCAB_MAX = 300;
extern fn ronny_sender_vocabulary(session: *imap.c.mailimap, days: c_int, out: [*]u8, max_out: c_int) c_int;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const env = init.environ_map;

    // Routing first, because it needs no mailbox and the criteria changing is
    // the thing most likely to have broken something already working.
    if (env.get("TYPESAFE_API_KEY")) |key| {
        if (key.len > 0) {
            std.debug.print("=== Jev routing ===\n", .{});
            const cases = [_]struct { text: []const u8, want: intent.Action }{
                // The three that historically misrouted.
                .{ .text = "show me the content of the latest email from example.org", .want = .read_mail },
                .{ .text = "give me the last email from 1Password", .want = .read_mail },
                .{ .text = "Send me an email saying: all ready", .want = .unknown },
                // Existing behaviour that must survive the new options.
                .{ .text = "summarise the last email from sam", .want = .summarize_mail },
                .{ .text = "find the email about self-hosted deployment", .want = .find_mail },
                .{ .text = "any mail from example.org this week?", .want = .search_mail },
                .{ .text = "reply saying Wednesday works", .want = .draft_reply },
                .{ .text = "add alex@example.com to the list", .want = .add_sender },
                .{ .text = "stop bugging me for a bit", .want = .pause },
                // The new ones.
                .{ .text = "does that email have any attachments?", .want = .list_attachments },
                .{ .text = "send me the invoice from it", .want = .get_attachment },
                .{ .text = "download the pdf", .want = .get_attachment },
                .{ .text = "email dana about thursday", .want = .compose_mail },
                .{ .text = "write to support@acme.com asking for a refund", .want = .compose_mail },
                // The generic, sender-less requests that had nowhere to go.
                .{ .text = "List all the emails from this morning.", .want = .recent_mail },
                .{ .text = "what came in today?", .want = .recent_mail },
                .{ .text = "anything new?", .want = .recent_mail },
                .{ .text = "Just the latest one from this morning, regardless of who sent it.", .want = .read_mail },
                // A person's NAME, not an address -- must stay read_mail and
                // must not become a search for an invented address.
                .{ .text = "Show me the latest email from Vicente Ferrer.", .want = .read_mail },
                .{ .text = "any mail from Vicente Ferrer this week?", .want = .search_mail },
                // Settings, and the neighbours they could plausibly steal
                // from. "add ... to be notified" reads like a notification
                // setting and is not one: it is a sender joining the
                // allowlist.
                .{ .text = "add example@example.com email account to be notified", .want = .add_sender },
                .{ .text = "notify me when acme.com writes", .want = .add_sender },
                .{ .text = "don't notify me before 8am", .want = .change_setting },
                .{ .text = "no notifications between 10pm and 7am", .want = .change_setting },
                .{ .text = "turn off quiet hours", .want = .change_setting },
                .{ .text = "look back 30 days by default", .want = .change_setting },
                .{ .text = "what are your settings?", .want = .show_settings },
                .{ .text = "what are my quiet hours?", .want = .show_settings },
                // "list of actions" went to list_senders twice in real use --
                // both are "a list", and only one is about people.
                .{ .text = "Show me the list of actions please.", .want = .help },
                .{ .text = "I need the list of the actions that I can do in this bot.", .want = .help },
                .{ .text = "who are you watching?", .want = .list_senders },
                .{ .text = "show me the list of senders", .want = .list_senders },
                // Silencing everything indefinitely is still pause, not a
                // quiet window.
                .{ .text = "stop notifying me until I say otherwise", .want = .pause },
                // Still out of scope.
                .{ .text = "forward that to my accountant", .want = .unknown },
                .{ .text = "delete all the newsletters", .want = .unknown },
                .{ .text = "what is the weather tomorrow", .want = .unknown },
            };

            var correct: usize = 0;
            for (cases) |case| {
                const decision = intent.classify(init.io, arena, key, "jev-latest", case.text, &.{}) catch |err| {
                    std.debug.print("  ERR  {s}: {s}\n", .{ case.text, @errorName(err) });
                    continue;
                };
                const got = intent.resolve(decision, intent.DEFAULT_MIN_CONFIDENCE);
                const ok = got == case.want;
                if (ok) correct += 1;
                std.debug.print("  {s} {s}\n       want={s} got={s} conf={d:.2} unk={d:.2}\n", .{
                    if (ok) "ok  " else "FAIL",
                    case.text,
                    case.want.wireName(),
                    got.wireName(),
                    decision.confidence,
                    decision.unknown_probability,
                });
            }
            std.debug.print("  {d}/{d} correct\n\n", .{ correct, cases.len });
        }
    }

    var session = try imap.Session.connect(
        try arena.dupeZ(u8, "imap.gmail.com"),
        993,
        try arena.dupeZ(u8, env.get("IMAP_USER").?),
        try arena.dupeZ(u8, env.get("IMAP_APP_PASSWORD").?),
    );
    defer session.deinit();
    _ = try session.examineInbox();

    std.debug.print("=== sender vocabulary (180d) ===\n", .{});
    const flat = try arena.alloc(u8, VOCAB_MAX * VOCAB_ENTRY);
    const count = ronny_sender_vocabulary(session.imap, 180, flat.ptr, VOCAB_MAX);
    std.debug.print("  {d} entries\n", .{count});
    if (count > 0) {
        for (0..@min(@as(usize, @intCast(count)), 30)) |i| {
            std.debug.print("  - {s}\n", .{std.mem.sliceTo(flat[i * VOCAB_ENTRY ..][0..VOCAB_ENTRY], 0)});
        }
    }

    std.debug.print("\n=== headers of the newest example mail ===\n", .{});
    var from_buf: [1]imap.Envelope = undefined;
    const hits = try session.searchFrom(try arena.dupeZ(u8, "example.org"), 60, &from_buf);
    if (hits.len > 0) {
        var message: imap.Message = undefined;
        try session.fetchMessage(hits[0].uid, &message);
        const raw = message.headersSlice();
        std.debug.print("  from:       {s}\n", .{hits[0].fromSlice()});
        std.debug.print("  date:       {s}\n", .{hits[0].dateSlice()});
        std.debug.print("  subject:    {s}\n", .{hits[0].subjectSlice()});
        std.debug.print("  reply-to:   {?s}\n", .{try headers.replyTo(arena, raw)});
        std.debug.print("  message-id: {?s}\n", .{try headers.value(arena, raw, "Message-ID")});
        std.debug.print("  references: {?s}\n", .{try headers.value(arena, raw, "References")});

        // Composed only -- a probe never sends.
        const draft = try mailer.compose(arena, env.get("IMAP_USER").?, .{
            .to = (try headers.replyTo(arena, raw)) orelse "nobody@example.com",
            .subject = if (std.ascii.startsWithIgnoreCase(hits[0].subjectSlice(), "re:"))
                hits[0].subjectSlice()
            else
                try std.fmt.allocPrint(arena, "Re: {s}", .{hits[0].subjectSlice()}),
            .body = "Thanks, noted.",
            .in_reply_to = (try headers.value(arena, raw, "Message-ID")) orelse "",
            .references = (try headers.value(arena, raw, "References")) orelse "",
        }, "PROBE-BOUNDARY");
        std.debug.print("\n=== composed reply (not sent) ===\n{s}\n", .{draft[0..@min(draft.len, 500)]});
    }

    if (hits.len > 0) {
        var message: imap.Message = undefined;
        try session.fetchMessage(hits[0].uid, &message);
        const body = message.bodySlice();
        std.debug.print("\n=== raw body, first 400 chars (what the ranker sees) ===\n{s}\n", .{
            body[0..@min(body.len, 400)],
        });
    }

    // The notification body, exactly as the watcher would build it. Run
    // against real recent mail because that is where the shapes are: bulk
    // HTML, one-line replies, threads quoting themselves.
    std.debug.print("\n=== notification summaries (real recent mail) ===\n", .{});
    {
        var recent: [5]imap.Envelope = undefined;
        const found = try session.searchRecent(3, &recent);
        for (found) |envelope| {
            var message: imap.Message = undefined;
            session.fetchMessage(envelope.uid, &message) catch continue;

            const started = std.Io.Clock.now(.boot, init.io).nanoseconds;
            const summary = summarize.forNotification(
                init.io,
                arena,
                env.get("OLLAMA_URL") orelse "http://127.0.0.1:11434",
                env.get("OLLAMA_MODEL") orelse "qwen2.5",
                envelope.fromSlice(),
                envelope.subjectSlice(),
                message.bodySlice(),
            );
            const elapsed_ms = @divTrunc(
                std.Io.Clock.now(.boot, init.io).nanoseconds - started,
                std.time.ns_per_ms,
            );

            const body_len = std.mem.trim(u8, message.bodySlice(), " \t\r\n").len;
            std.debug.print("\n  subject: {s}\n  body {d} chars -> {s} in {d}ms\n  {?s}\n", .{
                envelope.subjectSlice(),
                body_len,
                if (body_len == 0) "nothing" else if (body_len <= summarize.SHORT_BODY_CHARS) "verbatim" else "summarised",
                elapsed_ms,
                summary,
            });
        }
    }

    std.debug.print("\n=== contact book ===\n", .{});
    {
        const book = try contacts.load(arena, &session, contacts.DEFAULT_DAYS);
        std.debug.print("  {d} contacts; top 10 by frequency:\n", .{book.len});
        for (book[0..@min(book.len, 10)]) |contact| {
            std.debug.print("    {d:>3}x  {s} <{s}>\n", .{ contact.count, contact.nameSlice(), contact.addressSlice() });
        }
    }

    std.debug.print("\n=== attachments on real mail ===\n", .{});
    {
        var found: [8]imap.Envelope = undefined;
        const hits_att = try session.searchGmail(
            try arena.dupeZ(u8, "newer_than:120d has:attachment"),
            &found,
        );
        std.debug.print("  {d} message(s) with attachments\n", .{hits_att.len});

        for (hits_att[0..@min(hits_att.len, 3)]) |*envelope| {
            var message: imap.Message = undefined;
            session.fetchMessage(envelope.uid, &message) catch continue;
            const parts = message.attachmentSlice();
            std.debug.print("\n  uid={d} from={s}\n    {s}\n    {d} attachment(s):\n", .{
                envelope.uid, envelope.fromSlice(),
                envelope.subjectSlice()[0..@min(envelope.subjectSlice().len, 60)],
                parts.len,
            });
            for (parts) |*part| {
                std.debug.print("      [{d}] {s}  {s}  ~{d} bytes{s}\n", .{
                    part.index, part.filenameSlice(), part.mimeTypeSlice(), part.size,
                    if (part.is_inline == 1) "  (inline)" else "",
                });
            }

            // Actually pull the first non-inline one down and check the bytes
            // are real -- a wrong part index would still "succeed" otherwise.
            for (parts) |*part| {
                if (part.is_inline == 1) continue;
                const buffer = try arena.alloc(u8, 25 * 1024 * 1024);
                const bytes = session.fetchAttachment(envelope.uid, part.index, buffer) catch |err| {
                    std.debug.print("      -> fetch of [{d}] failed: {s}\n", .{ part.index, @errorName(err) });
                    break;
                };
                std.debug.print("      -> fetched [{d}] {s}: {d} bytes, first 8: {x}\n", .{
                    part.index, part.filenameSlice(), bytes.len,
                    bytes[0..@min(bytes.len, 8)],
                });
                break;
            }
        }
    }

    // `zig build probe -- "find the email about X"` to chase a specific
    // failure; the default keeps the step useful with no arguments.
    const args = try init.minimal.args.toSlice(arena);
    const question: []const u8 = if (args.len > 1)
        args[1]
    else
        "find the email about self-hosted deployment";

    std.debug.print("\n=== find: content search ===\n  question: {s}\n", .{question});

    // Both halves are printed separately because they fail differently: a bad
    // Gmail query returns nothing to rank, whereas a good query whose text
    // the ranker cannot see returns plenty and matches none. The second one
    // looks like "no such email" and is not.
    _ = session.examine(.all_mail) catch {};
    const terms = findmail.buildTerms(init.io, arena, "http://127.0.0.1:11434", "qwen2.5", question) catch &[_][]const u8{};
    const query = findmail.renderQuery(arena, terms, 365) catch "";
    std.debug.print("  query: {s}\n", .{query});

    const candidates = findmail.collect(arena, &session, try arena.dupeZ(u8, query), terms) catch &[_]findmail.Candidate{};
    std.debug.print("  {d} candidate(s); what the ranker is shown of each:\n", .{candidates.len});
    for (candidates, 0..) |candidate, i| {
        const seen = candidate.snippet[0..@min(candidate.snippet.len, 250)];
        const terms_present = std.ascii.indexOfIgnoreCase(seen, "influx") != null;
        std.debug.print("\n  [{d}] {s}\n      snippet {d} chars, shown {d}{s}\n      {s}\n", .{
            i,
            candidate.subject,
            candidate.snippet.len,
            seen.len,
            if (terms_present) "  <-- term IS visible" else "",
            seen,
        });
    }

    const found = try findmail.find(
        init.io,
        arena,
        &session,
        .{
            .ollama_url = "http://127.0.0.1:11434",
            .model = "qwen2.5",
            .typesafe_api_key = env.get("TYPESAFE_API_KEY") orelse "",
            .use_typesafe = env.get("TYPESAFE_RANK_MAIL") != null,
        },
        question,
        365,
    );
    std.debug.print("\n  ranked {d} match(es):\n", .{found.matches.len});
    for (found.matches) |match| {
        std.debug.print("  - {s}\n    from {s} | {s}\n    {s}\n", .{
            match.candidate.subject, match.candidate.from, match.candidate.date, match.why,
        });
    }
}

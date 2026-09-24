# Values that look arbitrary and are not

Several numbers and word lists in this repo look like magic values a tidy-up
would happily replace. Each came from a specific failure seen in real use.
Changing one without knowing why it exists reintroduces a bug that has already
been fixed once.

When refactoring, preserve the behaviour these encode even if the shape
changes, and keep the explanation next to whatever replaces them.

## Intent routing — `src/intent.zig`

**Confidence is a floor, not a gate.** `DEFAULT_MIN_CONFIDENCE` was once 0.55
and used as "is this answer right?". It rejected "Give me the last email from
1Password" twice while Jev had correctly chosen `read_mail`, at 0.51 and 0.54.

Confidence measures how *concentrated* the distribution is, not whether the
answer is correct — a request split between two reasonable actions looks
identical to genuine confusion. The fallback now keys on
`UNKNOWN_PROBABILITY_LIMIT`, Jev's own `unknown` probability; the floor only
catches a genuinely flat distribution.

**Conversation history depresses confidence** — the same sentence scored 0.93
alone and 0.73 with history, and it drops further as a conversation grows. So
any threshold-based gate gets *worse* the longer someone talks to Ronny. That
is the real argument against the simple version, not the two misses.

## Voice — `src/transcribe.zig`

**`PROTECTED`** exists because a wide sender vocabulary made "email" score
0.89 against "Mail" — from "Mail Delivery Subsystem" — and start rewriting
ordinary commands. Only single words are protected, so "acme sync" can still
become "AcmeSync".

**The length guard in `lookupName`** exists because "from digital ocean"
scored 0.86 against "digitalocean" merely by containing it, and swallowed the
"from". Comparable lengths are required so only the name is replaced.

**The sender vocabulary is wide on purpose** (180 days, 300 names in
`src/bot.zig`). A 40-name list missed 1Password at rank 75 and AcmeSync at
rank 201 — precisely the two senders that were being misheard. Only
`PROMPT_VOCAB_LIMIT` is small, because whisper truncates `initial_prompt`
near 224 tokens; matching has no such limit and should not inherit it.

**`n_threads = 8` in `src/whisper_shim.c`** is measured, not guessed. On the
development host (6 cores / 12 threads), encode per 30s window on the medium
model: 13.2s at 4 threads, 6.6s at 8, 6.1s at 12. Eight is the knee;
hyperthreads add 7% while contending with Ollama. Irrelevant once running on
a GPU — see [toolchain.md](toolchain.md).

## Approval — `src/decision.zig`

**`YES_WORDS` / `NO_WORDS` / `FILLER` are split by polarity** so "do it" reads
as yes and "don't do it" as no, with negation checked first. `MAX_WORDS = 5`
because anything longer is prose, not an answer. This one gates sending real
email — see [send-safety.md](send-safety.md).

## Watchdog — `src/watchdog.zig`

**Per-kind cooldowns.** A correctly-suppressed daily newsletter would
otherwise alert every morning. Alert fatigue is the failure mode that makes a
watchdog worthless, so informational kinds get hours and faults get minutes.

**`BURST_QUIET_SECONDS`** exists because one failure usually writes several
matching lines, and a single event was alerting twice.

**`HEARTBEAT_TIMEOUT_SECONDS` is three missed heartbeats, not one.** Everything
else in the watchdog reacts to a log line, so a Ronny that stops working
*without* crashing produces no error and no alert. An idle Ronny with no new
mail also logs nothing, so silence alone proves nothing — hence an explicit
heartbeat, and a timeout wide enough not to fire on one slow cycle.

`HEARTBEAT_MARKER` is a shared constant between the watcher and the watchdog,
with a test asserting they still agree. If they drift, the watchdog reports a
perfectly healthy Ronny as hung.

## Mailbox — `src/main.zig`, `src/findmail.zig`

**`if (envelope.uid <= watermark) continue`.** IMAP's `N:*` returns the highest
message even when `N` is past it, so with no new mail the server keeps handing
back the newest one. Without this guard it is re-notified on every scan. This
bug was reintroduced during the port and caught by running it.

**UIDNEXT baseline, not zero**, so a first run watches from now instead of
replaying the whole mailbox.

**The spam gate fails open** and flags the notification when the model is
unreachable, rather than silently dropping real mail. Losing mail is a worse
failure than one extra notification.

**Only matched mail is fully fetched**; scanning stays on envelopes. This is
what stops a 50k-message mailbox pulling 50k bodies.

**`MAX_QUERY_CHARS` and quote balancing in `findmail.zig`** are both from real
model output. One generated query reached 47 OR terms, over half exact
duplicates — past a point the model stops producing alternative phrasings and
starts producing variations on its own variations. Another left a quote
unclosed, which Gmail accepted and answered with almost nothing, looking
identical to an empty mailbox from the outside.

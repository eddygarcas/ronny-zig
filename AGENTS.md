# ronny-zig — email → Telegram agent, in Zig

"Ronny" watches a mailbox over IMAP and notifies its owner on Telegram when
mail arrives from an allowlisted sender — but never for anything that reads as
spam, marketing or phishing, **even from an allowlisted sender**. The same
Telegram bot is the control channel: search, read, summarise, draft replies,
change the allowlist, pause, all by text or voice.

This file is the map. `README.md` is the setup walkthrough; `docs/` holds the
reasoning that isn't obvious from any single file.

## Read this first if you are changing behaviour

| | |
|---|---|
| [docs/send-safety.md](docs/send-safety.md) | The reply-send gate. The most load-bearing design here — three real bugs shaped it. **Don't loosen it without asking.** |
| [docs/tuned-values.md](docs/tuned-values.md) | Constants that look arbitrary and each fixed a real failure. Read before refactoring. |
| [docs/toolchain.md](docs/toolchain.md) | Zig 0.16 API changes, why there is C here, and build workarounds that look removable and are not. |
| [docs/working-on-ronny.md](docs/working-on-ronny.md) | Practices that followed real mistakes: run it against real data, never write a third-party detail from memory, check `.env.example`. |
| [docs/new-deployment.md](docs/new-deployment.md) | Pointing an instance at a different mailbox. |

## Architecture

```
IMAP IDLE ──► allowlist ──► spam gate ──► Telegram          ronny watch
              controller    spam.zig      telegram.zig
              senders.yaml  (local)       (send only)
                   ▲
                   │ /add /remove /pause
                   │
              Telegram poll ──► intent ──► action            ronny bot
              telegram.zig      Jev +      search/read/
                                Ollama     summarise/draft

              journalctl ──► classify ──► diagnose ──► alert  ronny watchdog
```

**Three processes, not three threads.** Only one process may call Telegram's
`getUpdates` for a token — a second poller gets 409 Conflict and *silently
consumes updates the first one needed*. The split also lets the watchdog
outlive what it watches, which a thread inside the watcher could not.

What they share is on disk: `config/senders.yaml` and the paused flag, both
re-read each scan so chat commands take effect without a restart.

## Where things live

| Path | Role |
|---|---|
| `src/main.zig` | Subcommand dispatch (`watch` / `bot` / `watchdog`) and the watcher loop |
| `src/imap.zig` | Session, IDLE, UID-based detection, sender matching on envelopes only |
| `src/state.zig` | `{uidvalidity, last_uid}` watermark |
| `src/controller.zig` | Live-editable allowlist and paused flag |
| `src/spam.zig` | Header checks, then a local judgment call. **Fails open** |
| `src/bot.zig` | Polling, dispatch, pending-reply state, conversation history, voice |
| `src/decision.zig` | Whether a drafted reply gets sent. Deterministic, never the model |
| `src/intent.zig` | Jev picks the action from a closed set |
| `src/interpret.zig` | Jev for the action, Ollama for the free-text arguments |
| `src/findmail.zig` | Content search: model writes the query, Gmail recalls, model ranks |
| `src/summarize.zig` | Summaries and reply drafts |
| `src/headers.zig` | RFC 5322 header reading — where a reply's recipient comes from |
| `src/mailer.zig` | The only code that can send mail. Decision-free by design |
| `src/attachments.zig` | Which attached file the owner meant (local model) |
| `src/contacts.zig` | Who a new email can go to. Selected, never generated |
| `src/transcribe.zig` | Voice notes, plus the transcript repair pass |
| `src/watchdog.zig` | Journal tailing, incident classification, diagnosis |
| `src/ollama.zig` | The one door to the local model |
| `src/*.c` | libetpan (IMAP/MIME/SMTP) and whisper.cpp boundaries |
| `src/probe.zig` | Scratch target for exercising a piece against the real mailbox |

## The three rules the structure exists to enforce

1. **Nothing sends mail without an explicit yes.** There is no send action in
   the intent vocabulary, so no misclassification can reach the mailer.
   Approval is resolved by word matching, never by a model.
2. **No address ever originates from model output.** A reply takes its
   recipient from the headers of a message already shown; a new email
   selects one from addresses that have really written to this mailbox. The
   model returns an index, never a string.
3. **Email content never leaves the machine.** Spam checks, summaries, drafts
   and search ranking all run on local Ollama. Only the chat command itself
   goes to a hosted model, and that is optional.

## Configuration

Everything account-specific is in `.env` (gitignored, copy from
`.env.example`) and `config/senders.yaml`. No addresses, tokens or paths are
baked into the code. Nothing here should ever be hardcoded into source.

## Managing it

```
systemctl status|restart ronny-watch ronny-bot ronny-watchdog
journalctl -u ronny-watch -u ronny-bot -f
```

Rebuilds need the whisper prefix flag or voice silently regresses — see
`README.md`. No firewall rule is needed; Ronny only makes outbound
connections.

## Known limitations

- The spam check is a judgment call by a local model, not a guarantee. Treat
  it as a second opinion.
- Allowlist matching is exact-address or exact-domain only; no wildcards.
- Ownership is enforced purely by Telegram chat id, so the bot token is a
  credential — anyone holding it can impersonate the bot.
- Content search depends on Gmail's `X-GM-RAW` extension and will not work
  against other IMAP providers.

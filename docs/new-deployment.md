# Pointing Ronny at a different mailbox

Everything account-specific lives in two files. The code has no addresses,
tokens or paths baked into it.

| | |
|---|---|
| `.env` | credentials, model endpoints, file paths — gitignored, copy from `.env.example` |
| `config/senders.yaml` | the allowlist: full addresses or bare domains — gitignored like `.env`, copy `config/senders.example.yaml` |

Nothing else needs touching to run a second Ronny against a different account.

## What a second instance needs of its own

**Its own Telegram bot.** This is not optional and it is the one that bites.
Only one process may call `getUpdates` for a given bot token — a second poller
gets 409 Conflict and, worse, *silently consumes updates the first one
needed*, so messages vanish into whichever poller won the race. Two mailboxes
sharing a token means two owners losing messages at random. Make a second bot
with BotFather and give it its own `TELEGRAM_BOT_TOKEN`.

**Its own state files.** `RONNY_STATE_FILE` holds the IMAP UID watermark and
`RONNY_CONTROLLER_STATE_FILE` the paused flag. Two instances sharing either
will re-notify or silently skip mail. Point them at separate paths (or run
each instance from its own working directory, which is simpler).

**Its own systemd unit names.** The shipped units are `ronny-watch`,
`ronny-bot` and `ronny-watchdog`. For a second account use a distinct prefix
and update `WATCH_UNIT` / `BOT_UNIT` in `src/watchdog.zig` to match, or the
watchdog will follow the wrong journal and report the wrong service as hung.

**What it can share:** the Ollama instance, the TypeSafe key, the binary
itself, and the whisper model file. None of those hold per-account state.

## First run

Leave `TELEGRAM_OWNER_CHAT_ID` empty to start. `ronny bot` then answers only
`/start`, replying with the caller's own chat id and refusing everything
else. Put that id in `.env`, restart, and from then on every other chat gets
a flat refusal.

The watcher baselines to the mailbox's current `UIDNEXT` on a fresh run rather
than starting from zero — otherwise the first scan treats every message in the
mailbox as new. On a 50k-message mailbox that is 50k notifications. If you are
migrating an existing instance rather than starting fresh, copy its
`state.json` across instead, so nothing that arrived during the switch is
missed.

## Gmail specifics

- IMAP needs an **app password**, not the account password, and therefore 2FA
  on the account.
- Content search uses Gmail's own full-text index through the `X-GM-RAW` IMAP
  search extension. On a non-Gmail provider `find_mail` will not work and
  wants replacing with something else — the rest is ordinary IMAP.
- SMTP is `smtp.gmail.com:587` with STARTTLS. `EHLO` has to be repeated after
  the TLS handshake because the server advertises a different capability set
  once encrypted; `src/smtp_shim.c` does this and the comment says why.

## Things worth deciding per account, not copying

The allowlist is a **strict** allowlist — mail from anyone not on it is never
evaluated at all, regardless of subject. That is the whole design. A match is
still not sufficient on its own: every matching message also has to clear the
spam gate before a notification goes out.

`VOICE_CAN_CONFIRM_SEND` is false by default and should stay that way unless
the owner of *that* account asks. See [send-safety.md](send-safety.md).

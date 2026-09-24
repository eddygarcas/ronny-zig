# Working on Ronny

Practices that came out of building this, kept because each one followed a
real mistake. Aimed at whoever picks the repo up next, human or agent.

## Run it against real data

Reading the code did not catch these; running it did.

- A first run tried to backfill every message in a 50k-mailbox as "new".
- MIME-encoded subjects rendered as raw `=?UTF-8?Q?...?=`.
- The `uid > watermark` guard was dropped during the port, so the newest
  message was re-notified on every scan.
- The content-search ranker rejected a message whose answer was sitting in
  the candidate list, because the snippet it was given was all MIME
  boundary markers.
- A use-after-free in JSON parsing that only showed up as garbled text in a
  live chat.

`zig build probe` exists for this: a scratch target that exercises one piece
against the real mailbox, read-only and with no Telegram polling. Prefer
extending it over assuming something works.

**Do not start a second Telegram poller while one is live.** A second
`getUpdates` on the same token gets 409 and silently consumes updates the
first one needed, so the owner's real messages disappear into the test. Use a
deliberately invalid token if you need to exercise startup.

## Never write a third-party detail from memory

During this project a phone number was given to the user as a service's
official contact, with full confidence and no hedge. It was wrong —
fabricated from recall. The instruction attached to it was to message that
number and grant it permission to send messages, so a wrong number there was
not a typo; it was directing someone to hand contact permissions to an
unknown party. It was caught only because the profile picture looked like a
person rather than a bot.

For any third-party phone number, contact handle, API endpoint, bot username
or setup step: **fetch the official documentation and quote it.** This applies
even when the detail seems well known, and even when it feels too trivial to
look up. External details also go stale, so a once-correct recollection is not
safe either. When writing one into docs or config, put a pointer to the
authoritative source beside it so it can be re-verified independently.

## Check `.env.example` before every commit

Real secrets reached `.env.example` — which *is* tracked, unlike `.env` —
twice in one session. Both times a human edited the wrong file; the two have
near-identical structure. Both were caught before pushing.

A leaked token in a *private* repo is still a real leak: repos get shared,
forked, and made public. "It's private" is not a reason to skip the check, and
gitignore does not stop someone typing a real value into the wrong file.

Before staging anything that touches `.env.example`, diff it specifically and
read it for anything that looks like a credential rather than a placeholder.
If you find one, move it into `.env` — checking it is not about to be lost —
and restore the placeholder before continuing.

The same check is worth running across the whole history before a repo's first
push: grep the live secrets literally against `git rev-list --all`.

## The data boundary is the thing to state

The owner's preference is **not** local-only dogma. A hosted model was adopted
for intent routing once the boundary was made explicit: only *chat commands*
leave the machine, never email content, and the spam check stays local for
exactly that reason. The real line is **"email content does not leave the
box"**, not "nothing leaves the box".

Graceful degradation mattered to that decision too — the hosted classifier
falls back to the local one automatically.

So when proposing an integration: lead with what data would leave the machine
and what happens when the service is down. Default to local for anything
touching message bodies. Don't assume a hosted option is off the table; state
the boundary and let the owner judge.

`src/ollama.zig` exists to make that boundary one door rather than four.

## Operational notes

- **`sudo` needs an interactive password** in this setup, which an agent
  session cannot provide. Hand each sudo step to the user one at a time.
  **Never chain several** — a chained install silently stopped partway twice,
  leaving units copied but not enabled. Verify end state with
  `systemctl is-enabled` / `is-active` rather than trusting "done".
- **Code changes and `.env` edits need a restart.** Changes made *through the
  bot* (`/add`, `/remove`, `/pause`) and hand-edits to `senders.yaml` apply
  live, because both are re-read each scan.
- **Rebuilding needs the whisper prefix flag.** A plain `zig build` produces a
  Debug binary linked against the CPU-only system whisper, which is a large
  and silent voice regression. See [toolchain.md](toolchain.md).
- **Routine IMAP disconnects are not incidents.** Gmail drops long-lived IDLE
  connections every few hours. Escalating those paged the owner twice per
  blip until it was fixed; alert fatigue is how a watchdog becomes ignored.

## Where the sharp edges are

- [send-safety.md](send-safety.md) — the reply gate. The most load-bearing
  design in the repo; do not loosen it without asking.
- [tuned-values.md](tuned-values.md) — constants that each fixed a real bug.
  Read before refactoring.
- [toolchain.md](toolchain.md) — Zig 0.16 changes, the C boundary, and the
  build workarounds that look removable and are not.
- [new-deployment.md](new-deployment.md) — pointing an instance at a
  different mailbox.

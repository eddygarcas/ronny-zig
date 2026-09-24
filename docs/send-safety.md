# The reply-send gate

Ronny can reply to email. The original instruction was explicit: **"do not
send this reply unless I give permission."** That is enforced structurally
rather than by prompting, and every piece below exists because of a specific
failure, not out of general caution.

If you are changing anything in this document's blast radius, treat it as a
change to a safety boundary and get explicit agreement first — not as a UX
tweak. In particular, "just let the model confirm it" and "skip confirmation
for trusted senders" are both requests to remove the thing that makes this
safe.

## The invariants

- **No address ever originates from model output.** This is the invariant;
  the two rules below are how it is kept in the two cases that exist.

  - **A reply** may only target a message Ronny has already fetched and
    shown. The recipient comes from that message's `Reply-To`/`From` headers
    (`src/headers.zig`). Sender only, never reply-all — the blast radius of a
    mistake stays one person.

  - **A new email** has no such message, so the recipient is *selected* from
    a list of addresses that have really written to this mailbox
    (`src/contacts.zig`). The model returns an index, never a string. If
    nothing clearly matches, Ronny asks the owner to include the full address
    rather than guessing between similar names.

  Both then show the literal address in the draft, and both go through the
  same approval gate. Note what is *not* allowed: a model producing an
  address as free text. That is the shape that once wrote the literal string
  `"null"` into the live allowlist — embarrassing in a config file, and a
  stranger's inbox in a `To:` header.

- **There is no send action in the intent vocabulary** (`src/intent.zig`).
  Drafting is model-reachable; sending is not. No misclassification can reach
  `src/mailer.zig`, because there is no path.

- **Approval is deterministic, never the model** (`src/decision.zig`). The
  owner answers in plain language — "yes", "no", "go ahead", "dont" — but it
  is resolved by word matching. If a model could turn "yes" into a send, a
  misreading would send mail, which is the whole thing being guarded against.

- **Negation is checked first**, so "dont send it" cancels rather than
  matching on "send".

- **Ambiguity never sends.** An unclear answer leaves the draft pending and
  asks again. Guessing wrong toward sending is irreversible and reaches
  another person; guessing wrong toward asking costs one word.

- **A bare yes/no with nothing pending is inert.** It is answered directly and
  must never reach the classifier.

- **A spoken yes/no does not approve a send** unless `voice_can_confirm_send`
  is set. Transcription adds a failure mode typing does not have: a misheard
  word would send mail the owner declined. Ronny always echoes what it heard
  first, so a misheard command is visible.

- **A re-draft is announced loudly.** The owner must never confirm a body they
  believe they reviewed while a different one is actually pending.

- **Drafts expire** (`PENDING_REPLY_TTL_SECONDS`), so a forgotten draft cannot
  be confirmed hours later against a thread that has moved on.

- **An attachment is named in the draft preview.** A file the owner did not
  notice is a file they did not approve, so the draft says what is attached
  before the yes, and the staged upload is cleared on send *and* on cancel —
  leaving it would quietly ride along on the next unrelated draft.

- **`src/mailer.zig` is the only code that can send, and is decision-free.**
  It takes an explicit recipient and a body. All policy lives at the call
  site. Both drafting paths funnel through one `stageDraft`, so there is a
  single gate rather than two that can drift.

## The three bugs that produced these rules

All three were found by *using* the thing, not by reading the code.

1. **`"ok go ahead"`** missed a fixed-phrase list, fell through to the
   classifier, and silently **re-drafted** the pending reply — which would
   have let the owner approve a body they never read. Hence per-word matching
   with polarity split from filler, and the loud re-draft warning.

2. **A stray `"yes"`** after a completed send reached the classifier and
   **invented a brand-new draft**, leaving one reflexive "yes" between the
   owner and an email they never composed. Hence the inert rule.

3. **`"Send me an email saying: all ready"`** — something Ronny cannot do —
   was classified as `add_sender` with the literal string `"null"` as its
   target, and that was written into the live allowlist. Hence entry
   validation in `src/controller.zig`, the nullish-placeholder filter in
   `src/interpret.zig`, and ultimately Jev returning `unknown` rather than the
   nearest-looking action.

Note the shape they share: none was a failure of the model to understand.
Each was the plumbing around the model turning an ambiguous input into an
action. That is where the guards belong.

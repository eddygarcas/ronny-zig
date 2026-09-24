<p align="center">
  <img src="docs/ronny-logo.png" alt="Ronny" width="200">
</p>

<h1 align="center">Ronny email manager</h1>

An email assistant that watches a Gmail inbox, notifies over Telegram for an
allowlist of senders, suppresses anything that looks like spam — *even from an
allowlisted sender* — and can be talked to, in text or by voice, to search,
read, summarise and reply.

Written in Zig 0.16 over C libraries for mail and its content: **libetpan**
for IMAP, MIME and SMTP, **whisper.cpp** for voice. It is a personal tool, run
as three small systemd services against one mailbox.

```
you   › any mail from the bank this week?
Ronny › Found 2 message(s) from bank.example in the last 7 day(s):
        - Tue, 23 Sep: Statement ready
        - Fri, 19 Sep: Payment received

you   › [voice note] "show me the statement attachment"
Ronny › Sent Statement-September.pdf (240 KB).

you   › reply saying thanks, received
Ronny › DRAFT — not sent.
        To: support@bank.example
        Subject: Re: Statement ready

        Thanks, received.
        ---
        Reply 'yes' to send it, or 'no' to discard it.

you   › yes
Ronny › Sent to support@bank.example.
```

## The rules that shape it

Three constraints drove most of the design, and they are worth knowing before
reading any of the code.

**Nothing sends mail without an explicit yes.** Drafting is model-reachable;
sending is not. There is deliberately no send action in the intent vocabulary,
so no misclassification can reach the mailer. Approval is resolved by word
matching in `src/decision.zig`, never by a model — if a model could turn "yes"
into a send, a misreading would send mail, which is the whole thing being
guarded against. Anything ambiguous leaves the draft pending and asks again.

**A reply can only target a message Ronny has already shown you**, and its
recipient comes from that message's real `Reply-To`/`From` headers. A
hallucinated address is structurally impossible, not merely unlikely. It
replies to the sender only, never reply-all.

**Email content never leaves the machine.** The spam gate, summaries, reply
drafts and search ranking all read message bodies, so they all run on local
Ollama. Only the chat command itself — your words, no mail — goes to a hosted
model for classification, and even that is optional.

## How it decides things

Three layers, and keeping them apart is most of the design.

**Jev decides *what* you asked for.** [Jev](https://typesafe.ai) is a System
One model: it returns a typed answer from a closed set with a probability
attached, rather than generating text. Ronny asks it one question — which of
about fifteen actions is this message? — and gets back something like
`read_mail` at 0.94 with `unknown` at 0.01. A model that can only pick from a
list cannot invent an action, and one that reports its own uncertainty can say
*I don't know* instead of confidently choosing the nearest-looking thing.

**Local models do the reasoning.** Which attachment did you mean. Which
contact. What should this reply say. Is this message spam. Does this search
result actually answer the question. All of that needs to see your mail, so
all of it runs on Ollama, on your machine.

**Zig does everything else.** Fetching, parsing, sending, the allowlist, the
approval gate. No model is anywhere near the decision to actually send an
email.

That split is also where the privacy boundary falls out for free. Jev only
ever sees the sentence you typed — never a subject line, never a body, never a
filename. Anything that would require showing a model your mail is, by
construction, a job for the local one.

**Confidence is a floor, not a gate**, and that distinction cost real
debugging. Jev's confidence measures how *concentrated* its answer is, not
whether it is right. "Give me the last email from X" legitimately splits
between reading it and searching for it — both fair readings — and a flat 0.55
threshold rejected that twice at 0.51 and 0.54 while the answer was correct.
Ronny now falls back on Jev's own `unknown` probability instead. Conversation
history makes this worse, not better: the same sentence scores 0.93 alone and
0.73 with context, so any threshold-based gate degrades the longer you talk.

**It is optional.** Leave `TYPESAFE_API_KEY` empty and the local model does
the routing too, using a prompt that asks for the same closed set as JSON.
Everything still works; Jev is just better at refusing to guess.

## What you need

| | Why | Notes |
|---|---|---|
| **Zig 0.16** | builds it | 0.15 will not work — the standard library moved a lot |
| **libetpan** | IMAP, MIME, SMTP | `pacman -S libetpan`, `apt install libetpan-dev`, `brew install libetpan` |
| **whisper.cpp** | voice notes | optional; skip it and Ronny is text-only |
| **Ollama** | everything that reads mail | a local model — see below for which |
| **A Gmail account with 2-Step Verification** | the mailbox | app passwords require it |
| **A Telegram account** | the control channel | one bot per mailbox, never shared |
| **systemd** | running it unattended | or run the three commands yourself |

Not required: a GPU (voice is ~10× slower without one), and a
[TypeSafe](https://typesafe.ai) key for Jev — leave `TYPESAFE_API_KEY` empty
and the local model routes commands too. See
[How it decides things](#how-it-decides-things) for what that changes.

## Setup

### 1. Ollama and a model

Everything that reads your mail runs here, on your machine. Install Ollama,
then pull a model:

```
ollama pull qwen2.5
```

Anything that follows instructions and returns JSON will do; `qwen2.5` is what
this has been tuned against. Ronny talks to it over HTTP at
`http://127.0.0.1:11434`.

### 2. A Gmail app password

IMAP and SMTP need an **app password**, not your account password. Google
requires 2-Step Verification on the account before it will issue one — turn
that on first if it is not already, then create one at
[myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords).

You get a 16-character string. Keep the spaces or strip them, either works.

### 3. A Telegram bot

Message [@BotFather](https://t.me/botfather) and send `/newbot`. It asks for a
display name and a username ending in `bot`, then gives you a token like
`110201543:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw`.

**One bot per mailbox.** Only one process may poll a given token — a second
one gets 409 Conflict and silently eats messages meant for the first.

### 4. A TypeSafe key, if you want one (optional)

Sign up at [typesafe.ai](https://typesafe.ai) and put the key in `.env` as
`TYPESAFE_API_KEY`. Jev then decides which action a message means, and is
better than a small local model at answering *I don't know* rather than
guessing — see [How it decides things](#how-it-decides-things).

Skip it and everything still works; the local model routes commands too. Only
your typed words are ever sent, never mail.

### 5. Build

```
git clone https://github.com/eddygarcas/ronny-zig
cd ronny-zig
zig build test                     # 62 tests, no network needed
zig build -Doptimize=ReleaseSafe   # -> zig-out/bin/ronny
```

### 6. Configure

```
cp .env.example .env
cp config/senders.example.yaml config/senders.yaml
```

Fill in `.env` with the app password and the bot token. **Leave
`TELEGRAM_OWNER_CHAT_ID` empty for now.** Then list the senders you actually
want to hear about in `config/senders.yaml` — full addresses or bare domains:

```yaml
senders:
  - someone@example.com
  - example.org
```

That list is a *strict* allowlist. Mail from anyone not on it is never
evaluated at all, whatever the subject says. Both files are gitignored.

### 7. Claim the bot

```
./zig-out/bin/ronny bot
```

Message your bot `/start` in Telegram. It replies with your chat id and
refuses everything else. Put that id in `.env` as `TELEGRAM_OWNER_CHAT_ID`,
stop the process and start it again — from then on every other chat gets a
flat refusal.

### 8. Run it

Three processes, and they are separate on purpose:

```
ronny watch      # the mailbox watcher — notifies you
ronny bot        # the Telegram control channel — answers you
ronny watchdog   # tails the journal and reports incidents
```

Only one process may call Telegram's `getUpdates` for a token, so the bot has
to stand alone; the split also lets the watchdog report that the watcher died,
which it could not do if it died alongside it.

To run them unattended, edit the three unit files in `systemd/` — each needs
`User=` and three paths changed — then:

```
sudo cp systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ronny-watch ronny-bot ronny-watchdog
journalctl -u ronny-watch -u ronny-bot -f
```

On first run the watcher baselines to the mailbox's current position rather
than treating every existing message as new — otherwise a large mailbox would
produce one notification per message.

## Talking to it

Plain language works; the slash commands are the same actions, spelled out.

| | |
|---|---|
| `/status`, `/senders` | what it is doing, who it watches |
| `/add`, `/remove` | change the allowlist, live |
| `/search <who> [days]` | recent mail from someone, dates and subjects |
| `/recent [days]` | what has arrived lately, whoever sent it |
| `/find <topic>` | search by what a message was *about* |
| `/read`, `/summarize [who]` | the latest message, in full or summarised — the sender is optional |
| `/attachments`, `/get <name>` | what is attached; send me one |
| `/reply <text>` | draft a reply to the last message shown |
| `/compose <who> <what>` | draft a new email |
| `/confirm`, `/cancel` | send the draft, or discard it |
| `/pause`, `/resume` | stop and start notifications |

Send a **voice note** instead of typing and it does the same things. Send a
**file** and it is held for the next draft.

Nothing is sent until you reply `yes` to a draft you can see — and a *spoken*
yes will not do it, because a misheard word should not be able to send mail.

## Voice on the GPU

Voice works on CPU but transcribes at roughly real time. The distro
`whisper-cpp` package ships **CPU backends only** — on Arch, `/usr/lib/ggml`
holds fourteen `libggml-cpu-*.so` and no `libggml-cuda.so`. Measured encode
time per 30s of audio, medium model:

| | encode |
|---|---|
| CPU, 4 threads | 13.2 s |
| CPU, 8 threads | 6.6 s |
| **CUDA, RTX 3060** | **0.09 s** |

Nothing in Ronny changes between those; it is purely which ggml backend is
present. There is no CUDA whisper.cpp packaged, so build one:

```
git clone --depth 1 --branch v1.9.3 https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
PATH=/opt/cuda/bin:$PATH cmake -B build \
  -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES=86 \
  -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/gcc-15 \
  -DBUILD_SHARED_LIBS=ON -DWHISPER_BUILD_TESTS=OFF \
  -DCMAKE_INSTALL_RPATH='$ORIGIN' -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON \
  -DCMAKE_INSTALL_PREFIX="$HOME/.local/opt/whisper-cuda"
cmake --build build -j && cmake --install build
```

Then point the build at it, and download a model:

```
zig build -Doptimize=ReleaseSafe -Dwhisper-prefix="$HOME/.local/opt/whisper-cuda"
mkdir -p models && curl -L -o models/ggml-medium.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin
```

Set `WHISPER_MODEL_PATH=models/ggml-medium.bin` in `.env`. Leave it unset and
voice notes are simply disabled.

Four flags above are load-bearing, each found the hard way:

- **`CMAKE_CUDA_HOST_COMPILER`** — nvcc rejects host compilers newer than it
  supports (13.3 refuses anything above GCC 15). Point it at an older one you
  have installed, or configure fails outright.
- **`CMAKE_INSTALL_RPATH='$ORIGIN'`** — CMake strips rpaths on install, which
  leaves `libggml.so` unable to find `libggml-cuda.so` beside it. It does not
  fail cleanly: the loader falls back to the distro's `libggml-base`, quietly
  mixing two builds.
- **`v1.9.3`**, matching the packaged version `src/whisper_shim.c` compiles
  against.
- **`CMAKE_CUDA_ARCHITECTURES`** — just your card (86 is a 3060). Omit it and
  you compile kernels for every GPU generation.

Check it took with `ldd zig-out/bin/ronny | grep ggml`: every line should
point at your prefix, none at `/usr/lib`. A plain `zig build` reverts to the
system package, which is a large and silent voice regression.

## Running a second instance

Point it at a different mailbox with its own `.env` and `config/senders.yaml`.
It needs **its own Telegram bot token**, its own state files, and its own unit
names — see [docs/new-deployment.md](docs/new-deployment.md) for what shares
and what must not.

## Layout

| File | What it does |
|---|---|
| `src/main.zig` | Subcommand dispatch and the watcher loop |
| `src/bot.zig` | Telegram polling, intent dispatch, the pending-reply state |
| `src/decision.zig` | Whether a drafted reply gets sent. The load-bearing file |
| `src/intent.zig` | Jev picks the action from a closed set |
| `src/interpret.zig` | Jev for the action, Ollama for the arguments |
| `src/findmail.zig` | Content search: model writes the query, Gmail recalls, model ranks |
| `src/mailer.zig` | The only code that can send mail. Decision-free by design |
| `src/headers.zig` | RFC 5322 header reading; where a recipient comes from |
| `src/spam.zig` | Header checks, then a local judgment call. Fails open |
| `src/watchdog.zig` | Journal tailing, incident detection, diagnosis |
| `src/shim.c` | libetpan: IMAP, MIME walking, transfer decoding |
| `src/smtp_shim.c` | libetpan SMTP, STARTTLS |
| `src/whisper_shim.c` | whisper.cpp |

The C shims exist because Zig's translate-c cannot represent C bitfields —
`mailimap_selection_info` ends in one, which makes the whole struct opaque —
and because libetpan returns nested clists of tagged unions that are far more
pleasant to walk in C. They hand Zig flat data.

## Why things are the way they are

`AGENTS.md` is the map of the repo. `docs/` holds the reasoning that isn't
visible in any single file — worth reading before changing behaviour:

- [docs/send-safety.md](docs/send-safety.md) — the reply-send gate, and the
  three real bugs that shaped it
- [docs/tuned-values.md](docs/tuned-values.md) — constants that look arbitrary
  and each fixed a failure
- [docs/toolchain.md](docs/toolchain.md) — Zig 0.16 changes, the C boundary,
  and the build workarounds
- [docs/working-on-ronny.md](docs/working-on-ronny.md) — practices that
  followed real mistakes
- [docs/new-deployment.md](docs/new-deployment.md) — running an instance
  against a different mailbox

## Known gaps

**`build.zig` is pinned to one machine's toolchain, and that may well bite
you first.** It names an explicit `x86_64-linux-gnu` target with glibc 2.43
and hardcodes `/usr/include` and `/usr/lib`, because Zig 0.16's ELF linker
could not handle the `.sframe` relocations this host's GCC 16 emits into
`crt1.o` — a hello-world with `-lc` failed the same way, so it is a toolchain
disagreement rather than anything about this code.

If you are on a different distro, architecture or glibc, that is the first
thing to change. Try `zig build -Dtarget=native` — if it links, delete the
default target and the explicit paths entirely, they exist only for that one
problem. If it does not link, adjust the glibc version to match yours
(`ldd --version`); naming one newer than Zig ships stubs for is rejected
outright. Patches welcome; it should not need pinning at all.

Other things worth knowing:

- **Gmail-specific in one place.** `find_mail` searches by topic using
  Gmail's `X-GM-RAW` IMAP extension. Everything else is ordinary IMAP, so
  another provider works if you drop or replace that one command.
- **The spam check is a judgement call by a small local model**, not a
  guarantee. Treat it as a second opinion, not a filter you rely on.
- **Allowlist matching is exact address or exact domain.** No wildcards, no
  regex.
- **The bot token is a credential.** Anyone holding it can impersonate the
  bot; ownership is enforced only by Telegram chat id.
- **A CUDA whisper build lives outside your package manager**, so upgrades
  will neither break it nor update it. If the API drifts far enough that
  `src/whisper_shim.c` stops compiling, rebuild from a newer tag.

## Licence

MIT — see [LICENSE](LICENSE).

The code here is MIT, but it links libraries with their own terms, none of
which conflict:

| | |
|---|---|
| [libetpan](https://github.com/dinhvh/libetpan) | BSD-3-Clause, BSD-3-Clause-Attribution and BSD-4-Clause |
| [whisper.cpp / ggml](https://github.com/ggml-org/whisper.cpp) | MIT |
| Zig standard library | MIT |

Worth knowing rather than worrying about: part of libetpan is **BSD-4-Clause**,
which carries the old advertising clause — anything advertising a product that
includes it has to acknowledge the authors. Distributing source, as this repo
does, doesn't trigger it; libetpan is a system dependency the user installs.
Shipping a compiled binary would mean reproducing libetpan's copyright notices
alongside it. Not legal advice, just the thing to look at before publishing a
release artefact.

<p align="center">
  <img src="docs/ronny-logo.png" alt="Ronny" width="200">
</p>

<h1 align="center">Ronny email manager</h1>

An email assistant that watches a Gmail inbox, notifies over Telegram for an
allowlist of senders, suppresses anything that looks like spam — *even from an
allowlisted sender* — and can be talked to, in text or by voice, to search,
read, summarise and reply.

A rewrite of the Python original (`../ronny-email-manager`), in Zig 0.16, to
get at C libraries for mail and its content: libetpan for IMAP, MIME and SMTP,
whisper.cpp for voice.

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

## Running it

```
zig build test
cp .env.example .env                              # then fill it in
cp config/senders.example.yaml config/senders.yaml # then list who to watch

zig build -Doptimize=ReleaseSafe \
          -Dwhisper-prefix=$HOME/.local/opt/whisper-cuda   # -> zig-out/bin/ronny
```

`-Dwhisper-prefix` is optional but matters a great deal for voice. See below.

### Voice on the GPU

The distro `whisper-cpp` package ships **CPU backends only** — `/usr/lib/ggml`
holds fourteen `libggml-cpu-*.so` and no `libggml-cuda.so` — so voice notes
transcribe at roughly real time on a machine with an idle RTX 3060. Measured
encode time per 30s window of audio, medium model:

| | encode |
|---|---|
| CPU, 4 threads (whisper's default here) | 13.2 s |
| CPU, 8 threads | 6.6 s |
| **CUDA on the 3060** | **0.09 s** |

Nothing in Ronny changes between those; it is purely which ggml backend is
available. There is no CUDA whisper.cpp in the repos or the AUR, so build one:

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
cmake --build build -j12 && cmake --install build
```

Four details in there are load-bearing, each found the hard way:

- **`CMAKE_CUDA_HOST_COMPILER=/usr/bin/gcc-15`.** nvcc 13.3 refuses any host
  compiler above GCC 15 and this host defaults to 16.2. `gcc15` is packaged,
  so this costs nothing — but without it the configure step fails outright.
- **`CMAKE_INSTALL_RPATH='$ORIGIN'`.** CMake strips rpaths on install by
  default, which leaves `libggml.so` unable to find `libggml-cuda.so` sitting
  right beside it. The symptom is nastier than a clean failure: the loader
  falls back to the *distro's* `libggml-base` from `/usr/lib`, quietly mixing
  two builds.
- **`v1.9.3`**, matching the distro package, so `src/whisper_shim.c` keeps
  compiling against the API it was written for.
- **`CMAKE_CUDA_ARCHITECTURES=86`** is just the 3060. Omit it and you compile
  kernels for every GPU generation, for no benefit here.

It installs under `$HOME`, needs no sudo, and overwrites nothing — the system
`whisper-cpp` stays as it is, so dropping `-Dwhisper-prefix` reverts to it.
`build.zig` bakes the prefix in as an rpath, so the unit files need no
`LD_LIBRARY_PATH`. Check it took with `ldd zig-out/bin/ronny | grep ggml`:
every line should point at the prefix, none at `/usr/lib`.

Three subcommands, three processes:

```
ronny watch      # the mailbox watcher (the default)
ronny bot        # the Telegram control channel
ronny watchdog   # journal incident detection
```

They are separate processes rather than threads for a specific reason: only
one process may call Telegram's `getUpdates` for a given token. A second
poller gets 409 Conflict and, worse, silently consumes updates the first one
needed — so your messages disappear into whichever poller won the race. The
split also means either half can be cut over from the Python service on its
own, and the watchdog can report that the watcher died, which it could not do
if it died with it.

What they share is on disk: `config/senders.yaml` and the paused flag. Both
are re-read each scan, so changes made from chat take effect without a
restart.

## Cutting over from the Python service

The Python service is the one in production. Nothing here is enabled, and the
cutover is a deliberate step.

The units declare `Conflicts=ronny-email-manager.service`, so systemd will
refuse to run the Zig and Python halves at the same time rather than letting
two pollers fight over your messages. `ronny-watchdog.service` shares a name
with the Python watchdog's unit — installing it *is* the watchdog cutover.

```
sudo cp systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl disable --now ronny-email-manager ronny-watchdog
cp ../ronny-email-manager/data/state.json data/    # byte-compatible
sudo systemctl enable --now ronny-watch ronny-bot ronny-watchdog
```

`state.json` carries the UID watermark. Copying it is what stops the first
Zig run from either re-notifying recent mail or silently skipping it; without
it the watcher baselines to the mailbox's current UIDNEXT, which is safe but
loses anything that arrived during the switch.

To go back, reverse the last two lines.

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

- The whisper.cpp CUDA build lives outside pacman, so a `whisper-cpp` package
  upgrade won't touch it and won't update it either. If the API ever drifts
  far enough that `whisper_shim.c` stops compiling, rebuild from a newer tag.
- `build.zig` pins an explicit glibc target to work around Zig 0.16's ELF
  linker not handling the `.sframe` relocations this host's GCC emits. When
  `zig build -Dtarget=native` links cleanly, that workaround and the explicit
  system paths can all go.

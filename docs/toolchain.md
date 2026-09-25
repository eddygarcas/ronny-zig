# Zig 0.16, the C boundary, and the build workarounds

Two kinds of thing are recorded here: what Zig 0.16 moved (because most
examples online are written for 0.15 and are wrong), and the host-specific
workarounds in `build.zig` that look removable and are not.

Anything below labelled **host-specific** was observed on the development
machine — Arch, GCC 16.2, glibc 2.44, RTX 3060 — and should be re-checked
rather than copied onto a different box.

## Zig 0.16 moved a great deal

None of this is guesswork; it was found by reading the stdlib source after
online examples failed.

| Was | Is |
|---|---|
| `std.net` | `std.Io.net` |
| `std.fs` filesystem calls | `std.Io.Dir`, taking an explicit `io` |
| `makePath` | `createDirPath` |
| `std.Thread.Mutex` | `std.Io.Mutex`, takes `io` per lock, is cancelable |
| `std.mem.trimLeft` / `trimRight` | `trimStart` / `trimEnd` |
| `linkLibC()` / `linkSystemLibrary()` on the Compile step | module properties |
| `std.process.getEnvVarOwned` | `init.environ_map.get()` |
| `std.process.argsAlloc` | `init.minimal.args.toSlice(arena)` |
| `std.process.Child.init` | `std.process.spawn(io, options)` |
| `std.ArrayList.init(allocator)` | `.empty`, with the allocator passed per call |
| `@cImport` | `b.addTranslateC` in the build graph, imported as `@import("c")` |

`main` now takes a `std.process.Init` carrying the arena, a gpa, `io`, the
environment and the command line. A `File` no longer reads to end directly —
take `readerStreaming(io, buf)` and then `.interface.allocRemaining()`.
`std.Io.Clock.now(.real, io)` returns a `Timestamp` rather than an error
union; `.awake` and `.boot` are the monotonic clocks, and `.boot` is the right
one for a TTL because it includes time spent suspended.

**Useful reference:** the `zig-0.16` skill at `github.com/zigcc/skills` is
accurate and 0.16-specific. By contrast `alleneubank/claude-code` is archived
and targets 0.15 — its build examples are already wrong.

## `zig build` only analyses reachable code

A green build proves nothing about code that no test and no call path
touches. `controller.zig` carried a 0.15-era `std.mem.trimRight` for days
behind a passing build, because nothing reachable called the function it was
in. Run `zig build test` *and* build the executable, and do not read a clean
`zig build` as "it all compiles".

## `ArenaAllocator` captures its own address

`ArenaAllocator.allocator()` returns an `Allocator` pointing at the arena
struct. A struct that *holds* an arena can therefore only be moved into place
**after** every allocation is finished — copying it first leaves the stored
copy with a stale state, and everything allocated afterwards is lost. Both
the pending draft and the last-shown message in `src/bot.zig` allocate into
locals first and assign last for exactly this reason.

## `std.json` borrows from the source buffer by default

`parseFromSlice` defaults to `.alloc_if_needed`, which leaves strings
containing no escape sequences pointing **into the input**. Parse a response
body, free it, and hand the result to a caller and you have a use-after-free
that survives on whatever the allocator does next.

This shipped. The symptom was `owner message: <0xAA repeated>` — Zig's poison
byte — and every voice note failing to download, because the `file_id` passed
to `getFile` was garbage. Pass `.allocate = .alloc_always` when the parsed
value outlives the buffer, or copy out explicitly. There is a regression test
in `src/telegram.zig`.

## Why there is C in a Zig project

`src/shim.c`, `src/smtp_shim.c`, `src/whisper_shim.c` exist for two concrete
reasons, not out of preference:

1. **translate-c cannot represent C bitfields.** Any libetpan struct
   containing one arrives fully opaque with none of its fields reachable —
   `mailimap_selection_info` ends in `uint8_t sel_has_exists:1`, which is
   enough to hide the message count.
2. **libetpan returns nested clists of tagged unions**, and whisper's
   `whisper_full_params` is a large struct with nested unions. Walking and
   assembling those is ordinary C and genuinely unpleasant through
   translate-c.

The rule that has worked: **C for wrangling C data structures, Zig for
anything with logic in it.** The shims hand Zig flat structs and make no
decisions.

Two libetpan details worth knowing before debugging it:

- **libetpan has three success codes**, not one: `NO_ERROR` (0) plus
  `NO_ERROR_AUTHENTICATED` (1) and `NO_ERROR_NON_AUTHENTICATED` (2). Treating
  anything non-zero as failure rejects a perfectly healthy connection.
- **Fetch the whole message and walk the MIME tree**, don't use
  `RFC822.TEXT`. For multipart mail its first few hundred bytes are boundary
  markers and `Content-Type` lines, so a short snippet is entirely MIME
  boilerplate and the actual sentences never arrive — and quoted-printable is
  left undecoded, so "We'll" reaches the model as `We=E2=80=99ll`.
- **`-std=c11` hides POSIX.** `gmtime_r` and `strdup` need `gnu11`.

## Host-specific: the explicit target in `build.zig`

Zig 0.16 cannot link libc on this host with `native`: GCC 16.2 emits
`.sframe` relocations into `crt1.o` that Zig's ELF linker rejects
(`unhandled relocation type R_X86_64_PC64`), and `-flld` segfaults the
compiler. A hello-world with `-lc` fails identically, so it is a toolchain
disagreement, not this project.

`build.zig` therefore names an explicit `x86_64-linux-gnu` triple, which makes
Zig use its own bundled start files. The cost is that an explicit target stops
Zig searching system paths, so `/usr/include` and `/usr/lib` are named by
hand.

The glibc version has to be named too, and this one only bites at release
time: Debug tolerates the default baseline, but ReleaseSafe links through lld
with `--no-allow-shlib-undefined`, and the system libetpan, libgcrypt and
libgpg-error all reference symbols from newer glibc (`fstat@2.33`,
`__isoc23_strtol@2.38`, `closefrom@2.34`). Pinned to 2.43, the highest Zig
0.16 ships stubs for — the host is on 2.44 and naming that is rejected
outright. The ceiling is what matters, not an exact match.

**Test for removal:** when `zig build -Dtarget=native` links cleanly, the
default, the explicit paths and the glibc pin can all go together.

## Host-specific: whisper on the GPU

The distro `whisper-cpp` package ships CPU backends only — `/usr/lib/ggml`
holds fourteen `libggml-cpu-*.so` and no `libggml-cuda.so` — so voice
transcribes at roughly real time next to an idle GPU. Encode per 30s window,
medium model: 13.2s at 4 CPU threads, 6.6s at 8, **0.09s on an RTX 3060**.

Nothing in the Zig or C code changes; it is purely which ggml backend is
present. `-Dwhisper-prefix` points the build at a CUDA-enabled whisper.cpp,
and defaults to the system package so a machine without a GPU still builds.
The full recipe is in the repo README. Four flags in it each cost a round
trip to discover:

- **`CMAKE_CUDA_HOST_COMPILER=/usr/bin/gcc-15`** — nvcc 13.3 refuses any host
  compiler above GCC 15, and this host defaults to 16.2.
- **`CMAKE_INSTALL_RPATH='$ORIGIN'`** — CMake strips rpaths on install, which
  leaves `libggml.so` unable to find `libggml-cuda.so` sitting beside it. The
  failure is not clean: the loader falls back to the *distro's*
  `libggml-base` from `/usr/lib`, silently mixing two builds. Verify with
  `ldd zig-out/bin/ronny | grep ggml` — nothing should resolve to `/usr/lib`.
- **A version tag matching the distro package**, so the shim keeps compiling
  against the API it was written for.
- **`CMAKE_CUDA_ARCHITECTURES`** set to just the card you have.

## Host-specific: piper for voice summaries

Text-to-speech is not linked at all. `src/speech.zig` spawns the `piper`
command-line tool, which in the maintained
[piper1-gpl](https://github.com/OHF-Voice/piper1-gpl) is a Python entry
point over onnxruntime — there is no C library to shim, and a fresh process
costs about 1.5 s per summary on this CPU, next to the tens of seconds the
summary itself took. It lives in a venv under `~/.local/opt/piper` beside
`whisper-cuda`, with voices in `~/.local/opt/piper/voices`; `.env` points at
both. Nothing about it is in the build, so a plain rebuild cannot regress it
the way the whisper prefix can. The failure to watch for is different: the
venv's Python being upgraded underneath it, which shows up in the journal as
`could not speak the summary (SynthesisFailed); sending text` and costs the
owner nothing but the voice.

`addWhisperPaths` in `build.zig` sets an **rpath** as well as a library path.
Without it the binary links fine and then fails to start under systemd, which
has no `LD_LIBRARY_PATH` — a failure that appears only in production.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An MCP server, written in OCaml, that gives an MCP client live OCaml
toplevels. A bytecode worker process owns the toplevel over
`compiler-libs.toplevel`; the native server supervises one worker per named
session and speaks MCP over stdio. Eighteen tools: `eval`, `describe`, `require`,
`load`, `reset`, `continue`, `inspect` (session state), `markers` (the
breakpoints and watches a session knows), `locate`, `type_at`,
`outline`, `uses`, `search_type`, `document`, `expand` (what a ppx generated at
a position), `diagnostics` (errors for one file, or for an edit not yet
written), `context` (the opens that put a
session in a file's context; merlin, no session needed) and
`signature` (an installed package's interfaces, no session needed). There is
no build tool; see ticket 025.

## Commands

`opam env` is **not** loaded in the user's fish shell, so evaluate it first:

```sh
eval (opam env)     # fish; bash: eval $(opam env)
dune build
dune test
```

Run one suite or one case (Alcotest filtering; consult the `ocaml-alcotest`
skill before touching the suite):

```sh
dune exec test/test_server.exe -- test load          # one suite
dune exec test/test_server.exe -- test load 0        # one case
dune exec test/test_camlkit.exe -- list
```

Both suites are `\`Slow`, so plain `dune test` runs them. Running an executable
directly needs `opam env` evaluated first, or the Lwt test kills its worker
loading `lwt.unix` and reports a dead session instead. Tests spawn the real
worker and the real server binary and depend on `test/fixtures/mylib`.

Drive the server by hand, one JSON-RPC object per line on stdin:

```sh
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"eval","arguments":{"session":"a","code":"1 + 41;;"}}}' | dune exec camlkit
```

Cancellation is unreachable from the tool surface, so it has its own driver:

```sh
python3 scripts/cancel-check.py "$(opam var bin)/camlkit" "$(opam var bin)/camlkit-worker"
```

`load` is out of reach the same way, because dune refuses to run inside dune:

```sh
python3 scripts/load-check.py "$(opam var bin)/camlkit" "$(opam var bin)/camlkit-worker" .
```

## Architecture

Two processes, one shared codec library.

| Path | Role |
| --- | --- |
| `wire/` | frame codec (`frame.ml`), channel I/O (`frame_io.ml`), IPC message types (`msg.ml`) |
| `worker/` | the toplevel: capture, two-pass evaluation, printers, loader, request loop |
| `lib/` | session supervision, tool declarations, rendering, merlin |
| `bin/main.ml` | the server's `Unix.select` loop and tool dispatch |

Neither process runs Eio, Lwt or threads. The server is a single `select`
loop waking on stdin, any worker's answer, or the earliest deadline. The
worker is sequential so that `Lwt_main.run` still works inside evaluated
code. **Nothing in the server may print to stdout** — that descriptor is the
MCP channel; diagnostics go to stderr.

A frame is a header and two length-prefixed segments: metadata, then raw
bytes. The metadata is a `Marshal` of the request or response, which is why
the header carries a stamp: Marshal casts blind, so a peer built from other
source must be refused before its bytes are read. Bump `Frame.format_version`
when the types in `wire/msg.ml` change shape. Captured program output rides in
the raw segment and is addressed by per-phrase offsets, so it is never encoded
at all.

Both binaries adopt their own switch at startup, in `Wire.Exe.adopt_switch`:
a client launches them from a shell without `opam env`, and dune cannot
resolve a project's packages without it. The switch is derived from where the
binary is, because `opam env` would answer for the shell's switch rather than
the one the worker was built in; `CAMLKIT_SWITCH` overrides it, and `CAMLKIT_SWITCH=none` (or empty) turns
adoption off entirely, which is what a nix-built toolchain wants. Only `PATH`
and `OPAM_SWITCH_PREFIX` are set, and `CAML_LD_LIBRARY_PATH` deliberately is
not: ticket 028 reaches the same end through `Dll.add_path` rather than
overwrite a variable the user may have set. See ticket 039.

The worker is bytecode (`modes byte_complete`, `-linkall`) and the server is
native. Bytecode is version-locked to the compiler, so a worker only loads
artifacts from its own switch. The server finds the worker beside its own
executable, falling back to the dune build-tree path;
`CAMLKIT_WORKER` overrides both.

## Conventions

**Functional core, imperative shell.** Decision logic is pure and separate
from the I/O acting on it: `Frame` is the codec and `Frame_io` does the
channel work; `Supervision` is the escalation state machine and `Session`
owns the process obeying it. Time and process state arrive as arguments. The
test is whether the interesting logic can be tested without a pipe, a clock
or a subprocess. `worker/eval.ml` is the unavoidable exception, since
`Toploop` and `Typemod` work through global compiler state.

**Results are structural.** A tool result carries typed fields in
`structuredContent`, not prose the caller has to parse back. Counts are
numbers, errors carry spans and line ranges as data, a failure names the
failing thing in a field. Human-readable text ships alongside, never instead.
Structure that merely restates the text is not worth its bytes.

**A result pays for itself in tokens.** A field with nothing to say is absent,
not present and empty. A qualifier folds into what it qualifies: truncated
output ends with `[output truncated, N more characters]` rather than carrying
a flag beside it. A default is not echoed back, and nothing is carried twice:
a phrase's bindings are read out of its rendering, not repeated beside it. The
converse still holds where there is no text to read - a breakpoint's locals
are fields, because a stop prints nothing. See ticket 004.

**A call says only what is unusual.** The session name defaults to `main` and
`load` defaults to the project the server was started in, so a one-off
evaluation invents no names.

**Evaluation is all or nothing.** Several phrases per request, and nothing
executes unless every phrase parses and typechecks. That is why `eval`
rejects directives (`#require` and friends are not typeable) and why loading
a library and showing a signature are separate tools.

**A runaway phrase is interrupted before it is killed.** `Sys.Break` is
swallowed by `execute_phrase`, so interrupts are detected by a flag set in
the signal handler; toplevel state survives. Only an unanswered interrupt
escalates to a kill.

**A phrase that allocates without bound is stopped too.** A Gc alarm armed
only while a phrase runs raises past a heap ceiling (2048 MiB, or
`CAMLKIT_HEAP_LIMIT_MIB`), so the session survives instead of the allocator
killing the worker. Ticket 030 has the three details that are easy to get
wrong.

**Sessions are hermetic.** `~/.config/utop/init.ml` is not loaded. Three
reserved names are injected, for breakpoints; see ticket 035.

**A phrase can stop in the middle.** `[%break "name"]` in evaluated code
performs an effect, the handler around the phrase keeps the continuation, and
evaluation returns to the request loop, so the session stays usable while the
rest of the phrase waits as a value. Locals in scope are bound under `bp_`
names. The `continue` and `inspect` tools drive it. The worker is still
sequential: nothing is blocked, a parked phrase is a value in a table.

**A phrase can also be watched without stopping.** `[%watch "name" expr]`
records every value flowing through the expression and returns it, which is the
complement of a stop rather than a variant of it: a break replaces an expression
in unit position, a watch wraps one and gives its value back. Both are named,
because a marker compiles into the code holding it and keeps firing whenever
that code runs; `markers` lists them and disarms them, which is the only way to
stop one short of redefining its function. See ticket 049.

Prefer stability over linking: merlin is shelled out to in single mode rather
than linked, and the reasoning is a long comment at the top of
`lib/merlin.ml`; read it before reversing it. `load` and the `uses` index call
shell out to dune for the same reason.

`ponytail` governs scope: the laziest thing that works, no speculative
abstraction.

## Design record

`docs/wayfinder/MAP.md` is the index; each decision is a ticket under
`docs/wayfinder/tickets/` recording what was chosen, what was rejected and
why, and what was measured rather than assumed. Superseded decisions keep
their reasoning instead of being deleted. Add a ticket when making a decision
of that kind, and update MAP.md's list.

Note that utop was removed as a dependency (ticket 022) and the project was
renamed from utop-mcp to camlkit afterwards. The tickets keep the old name and
their utop history, which is the record rather than drift.

## Security posture

This executes arbitrary OCaml with the user's privileges and is deliberately
not sandboxed (ticket 012). It is a trusted local developer tool, and stdio
is assumed to imply a local parent the user launched. Do not add a non-stdio
transport.

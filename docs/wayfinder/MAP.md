# Map: MCP interface for UTOP

## Notes

**Domain.** An MCP server, written in OCaml, that gives an MCP client (an
agent) one or more live OCaml toplevels. A worker binary links the utop
library and owns the eval loop; the server supervises one worker per
session. OCaml 5.3.0 or newer. No fork of utop, no patch to it.

**Purpose.** Both an agent scratchpad REPL and a codebase exploration
tool, built eval-first. Completion and library loading follow once eval
is solid.

**Skills every session should consult.** `ocaml-alcotest` for anything
touching the test suite. `ponytail` governs scope: the laziest thing that
works, and no speculative abstraction.

**Functional core, imperative shell.** Decision logic is pure and lives
apart from the I/O that acts on it. `Frame` is the codec and `Frame_io`
does the channel work; `Supervision` is the escalation state machine and
`Session` owns the process that obeys it. Time and process state arrive as
arguments rather than being read inside the core. The test for this is
whether the interesting logic can be tested without a pipe, a clock or a
subprocess.

The toplevel itself is the exception and cannot be purified: `Toploop` and
`Typemod` work through global compiler state, so `worker/eval.ml` is shell
by nature. Keep the pure parts of it, such as directive rejection and
response construction, separable anyway.

**Standing preferences.** Build against opam's utop, never the reference
checkout at `/home/lyh/pullground/mina/utop`, which is behind opam. The
worker is bytecode because utop has no native archive; the server is
native.
`opam env` is not loaded in the user's fish shell, so every build command
must evaluate it first. Tests are Alcotest.

## Decisions so far

- [Architecture baseline](tickets/001-architecture-baseline.md) — subprocess
  speaking utop's `-emacs` protocol; named multiple sessions; Eio for
  concurrency and cancellation; poisoned sessions are killed, not repaired;
  output framed by a fully-qualified sentinel phrase.
- [JSON-RPC codec: library or hand-rolled](tickets/008-jsonrpc-codec.md) — use
  the `jsonrpc` package from ocaml-lsp; it is a pure message codec with no
  transport, so it carries no LSP framing and no rival runtime.
- [How a session is spawned and supervised](tickets/009-session-spawn-and-supervision.md)
  — spawn `opam exec -- utop -emacs` hermetically with `-init /dev/null
  -no-autoload -implicit-bindings`; on deadline escalate SIGINT, grace, kill;
  child stderr to the log, never into the protocol stream.
- [MCP semantics to target](tickets/002-mcp-wire-contract.md) — target
  2026-07-28 but answer both handshakes; the stateless core blesses session
  ids as tool arguments; `isError` only for infrastructure failure; declare
  an `outputSchema`.
- [Worker linked to utop replaces the subprocess protocol](tickets/014-worker-architecture.md)
  — the eval loop is ~30 lines and owning it removes the sentinel, the output
  race and stdin theft outright; supersedes the subprocess baseline. Neither
  server nor worker runs Eio or Lwt: the server is a `Unix.select` loop.
- [Serialization format for worker IPC](tickets/017-serialization-benchmark.md)
  — no serialization dependency; frame is JSON metadata plus a raw byte
  segment, which measured faster than every library tested.
- [Protocol between server and worker](tickets/015-worker-ipc.md) — two-segment
  frames, per-phrase records with offsets, warnings split out via
  `Location.formatter_for_warnings`, and a two-pass evaluation so neither a
  syntax error nor a type error runs anything; `eval` rejects directives,
  which get their own tools.
- [Exploring the environment: describe, not complete](tickets/005-completion-path.md)
  — completion returns names without types and suits a human typing; `#show`
  already returns full signatures, so the agent-facing tool is describe.
- [Interrupting a runaway phrase in the worker](tickets/016-worker-interrupt.md)
  — `Sys.Break` is swallowed by `execute_phrase`, so interrupts are detected
  by a flag set in the signal handler; toplevel state survives intact.
- [Trust boundary](tickets/012-trust-boundary.md) — trusted local developer
  tool, deliberately not sandboxed; stdio implies a local parent and that
  assumption is load-bearing.
- [Testing strategy](tickets/013-testing-strategy.md) — one tier, integration
  tests spawn a real utop in the default `dune test`.

## Fog

- **Project launch context.** Deferred deliberately. Whether a session can
  be started inside a dune project so its libraries are preloaded. The
  mechanism is known to work: utop's README documents
  `opam exec -- dune utop . -- -emacs`. What is undecided is whether a
  session names a project directory, and how that interacts with hermetic
  spawn flags.
- **Toplevel printers.** Hermetic spawn suppresses the ones a user
  installs in `init.ml`, so their own types print as `<abstr>`. Tracked as
  [Let a session opt out of hermetic spawn](tickets/010-hermetic-opt-out.md);
  noted here only because it is a visible behavioural difference.
- **Jump to source, and documentation.** Type lookup is settled by the
  describe tool; these two are not. Merlin may fit better than anything in
  utop, at the cost of a second subsystem.
- **Toplevel directives.** How `#use`, `#load` and `#directory` interact
  with a server-managed session. Possibly a security boundary, possibly a
  feature. The init file and autoload questions are settled by hermetic
  spawn; these remain.
- **Resource limits.** A phrase can allocate until the machine dies. A
  deadline bounds time but nothing bounds memory.
- **History.** utop's protocol exposes history navigation and
  `save-history`. Unclear whether an agent client wants any of it.
- **Packaging.** How this gets installed and registered with an MCP client,
  and whether it is worth publishing to opam.

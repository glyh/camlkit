# Map: camlkit

## Notes

**Domain.** An MCP server, written in OCaml, that gives an MCP client (an
agent) one or more live OCaml toplevels, merlin-backed source queries and a
dune build. A worker binary owns the eval loop over `compiler-libs.toplevel`;
the server supervises one worker per session. OCaml 5.3.0 or newer.

**Named camlkit.** utop was the original substrate and has been removed, see
[Removing the utop dependency](tickets/022-drop-utop.md), and the surface grew
past a toplevel besides. The project was utop-mcp until then, which the
tickets below still say; that is the record, not drift.

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

**Verified on OCaml 5.3.0 and 5.4.0.** Every compiler-libs signature the
worker touches is identical across those releases. The one that does differ,
`Longident.Ldot`, is reached through `Longident.unflatten` instead, which is
not version-dependent.

**Keep what an endpoint serves as structural as possible.** A tool result
carries typed fields in `structuredContent`, not prose the caller has to
parse back out. Counts are numbers, lists are arrays, errors carry spans and
line ranges as data, and a failure names the thing that failed in a field
rather than only inside a sentence. Human-readable text ships alongside for
display, never instead. The test is whether a caller could act on the result
without reading the prose: if it has to regex a message to learn which
library failed, the shape is wrong. The converse also holds - structure that
merely restates readable text is not worth its bytes. The eval rendering is a
utop transcript and stays one; see
[What an eval returns to the agent](tickets/004-eval-result-contract.md).

**Standing preferences.** The worker is bytecode because the toplevel it
links loads bytecode archives; the server is native.
`opam env` is not loaded in the user's fish shell, so every build command
must evaluate it first. Tests are Alcotest.

## Decisions so far

- [Architecture baseline](tickets/001-architecture-baseline.md) — **largely
  superseded.** Kept for the protocol analysis and for why the `-emacs` route
  was tried first. What survives: named multiple sessions. What does not: the
  subprocess, the sentinel, Eio.
- [JSON-RPC codec: library or hand-rolled](tickets/008-jsonrpc-codec.md) — use
  the `jsonrpc` package from ocaml-lsp; it is a pure message codec with no
  transport, so it carries no LSP framing and no rival runtime.
- [How a session is spawned and supervised](tickets/009-session-spawn-and-supervision.md)
  — **spawn decisions superseded**, supervision decisions stand: on deadline
  escalate SIGINT, grace, then kill; concurrent evals on one session are
  refused, not queued. There is no utop binary to spawn or pass flags to; the
  server spawns its own worker.
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
- [Session driver: the select loop](tickets/003-session-driver.md) — the loop,
  plus two process-lifetime bugs it exposed: pipes must be `cloexec`, and a
  worker mid-phrase needs a signal rather than a closed pipe.
- [What an eval returns to the agent](tickets/004-eval-result-contract.md) —
  `lib/render.ml`, pure; per-phrase rendering, warnings, output and spans;
  `isError` only for the server failing at its own job.
- [Session lifecycle and the tool surface](tickets/006-tool-surface.md) — four
  tools, all with output schemas; sessions created on first use; a dead name is
  reusable and the first result after a restart says the toplevel is fresh.
- [Automatic toplevel printers](tickets/018-automatic-toplevel-printers.md) —
  `[@@ocaml.toplevel_printer]` support was silently absent, so a project's own
  types printed as `<abstr>`; reimplemented in `worker/printers.ml`, both the
  required-package half and the in-session half, the latter by folding over the
  environment rather than copying utop's Env-summary walk.
- [Making it installable](tickets/020-installability.md) — only the server was
  installed, so an installed copy could never start a session; the worker now
  has a `public_name` and the installed pair is verified end to end.
- [Loading a dune project's own libraries](tickets/021-dune-aware-load.md) —
  the `load` tool: discover archives, add the hidden `.objs/byte` directories,
  retry until dependency order settles, and `reset` before reloading a rebuild.
- [Removing the utop dependency](tickets/022-drop-utop.md) — 22 packages down
  to 2; the remaining helpers were reimplemented over compiler-libs, which also
  fixed incomplete input killing the worker.
- [Loading libraries into a session](tickets/007-library-loading.md) — calls
  `Topfind` directly rather than a directive, so a missing package fails
  honestly; largely superseded by `dune top` reporting externals too.
- [Honour a cancellation notification](tickets/023-mcp-cancellation.md) —
  interrupt rather than kill, so the session survives; the answer is read and
  discarded rather than replied with, and the completed-request race is ignored.
- [Let a session opt out of hermetic spawn](tickets/010-hermetic-opt-out.md) —
  closed unimplemented: attribute printers already work regardless of an init
  file, and there is no init file to opt back into.
- [Merlin-backed source queries](tickets/027-merlin-source-queries.md) — five
  session-less tools over `ocamlmerlin`, shelled out rather than linked, in
  server mode; answers about source rather than values.
- [Building the project from a tool](tickets/025-build-from-a-tool.md) — `dune
  build` shelled out, after five obstacles on the RPC route, the last of which
  was unexplained; diagnostics are parsed into fields, dune emits no structured
  form.
- [Should Lwt and Async expressions auto-run](tickets/019-lwt-async-auto-run.md)
  — yes, as utop does, rewriting bare expressions only; configurable per session
  as a list of rule names, and self-gating so it is inert without the library.
  Every eval reports the list in force, and a rewritten phrase names the rule
  that ran it, since neither was observable without a probe.
- [Toplevel directives are not part of the tool surface](tickets/029-directives-are-not-the-surface.md)
  — none of them get exposed: `#require` reports failure as prose where the
  tool reports fields, `load` is not expressible as directives at all, and a
  buffer containing one cannot be typed before it runs. Wording only; `eval`
  already rejected them. `#trace` is the one real loss and stays in the fog.
- [Trust boundary](tickets/012-trust-boundary.md) — trusted local developer
  tool, deliberately not sandboxed; stdio implies a local parent and that
  assumption is load-bearing.
- [C stubs are unreachable in a bare environment](tickets/028-c-stubs-in-a-bare-environment.md)
  — **fixed.** `require` of any package carrying C stubs killed the worker
  unless `CAML_LD_LIBRARY_PATH` was set, because `ld.conf` names
  `lib/ocaml/stublibs` and opam installs stubs to `lib/stublibs`; the worker now
  adds that directory itself through `Dll.add_path`. Separately, a dynlink
  failure raises `Compenv.Exit_with_status`, which `require_packages` did not
  catch, so it ended the process instead of filling in `failed`; it now catches
  everything and carries the captured stderr back with it.
- [Testing strategy](tickets/013-testing-strategy.md) — one tier, integration
  tests spawn a real worker and the real server in the default `dune test`.

**Not forking utop.** Reconsidered once and re-declined on measurement: 76
lines reimplemented here against 4,426 lines and 28 cppo version branches
inherited. The full list of what `UTop_main` does and we do not is in
[Should Lwt and Async expressions auto-run](tickets/019-lwt-async-auto-run.md);
one item remains and it is a choice, not a gap.

**Prior art.** [ocaml-mcp](https://github.com/tmattio/ocaml-mcp), by tmattio,
ISC, last commit August 2025. It is both an MCP SDK for OCaml and a
development server built on merlin, Dune RPC and ocamlformat. Its overlap
with this is narrow: its `ocaml/eval` spawns a fresh `ocaml -noprompt` per
call and discards it, so there is no session and the project reloads every
time. Its breadth is where it is ahead, and its README and TODO were
surveyed; what came out of that is in the tickets and the fog below. Reading
it is also where `dune top` came from.

## Fog

- **Project launch context.** No longer fog: the mechanism is confirmed and
  the work is specified in
  [Loading a dune project's own libraries](tickets/021-dune-aware-load.md).
- **Toplevel printers.** Hermetic spawn suppresses the ones a user
  installs in `init.ml`, so their own types print as `<abstr>`. Tracked as
  [Let a session opt out of hermetic spawn](tickets/010-hermetic-opt-out.md);
  noted here only because it is a visible behavioural difference.
- **Documentation lookup.** Reading odoc or docstrings for a value. merlin
  has a `document` command; whether that is worth a tool is unclear. Jump to
  source is no longer fog, see
  [Merlin-backed source queries](tickets/027-merlin-source-queries.md).

- **A project as a tree of modules rather than files.** From ocaml-mcp's
  TODO, and the most interesting idea in it: an agent working on an OCaml
  project arguably wants to address modules, not paths. What that would mean
  for a tool surface here is not yet sharp.

- **Package search and an opam index.** ocaml-mcp plans to process
  opam-repository into a cached index keyed by commit, to resolve package
  versions and later to support semantic search over source. Large, and only
  worth anything if exploration turns out to be limited by not knowing what
  exists rather than by not being able to load it.

- **Formatting.** ocamlformat as a tool, as ocaml-mcp exposes. Probably
  belongs to whatever writes files, which is not this.

- **File tools with OCaml awareness.** ocaml-mcp wraps read, write and edit
  with merlin diagnostics and formatting, plus a rule forbidding an edit to a
  file that was not read. Deliberately out of scope here: an agent already
  has file tools, and duplicating them earns nothing. Recorded so the
  decision is visible rather than absent.

- **Sandboxing, revisited.** ocaml-mcp's TODO proposes bubblewrap around its
  eval, build and file tools. [Trust boundary](tickets/012-trust-boundary.md)
  declined to sandbox, deliberately, because confining the worker breaks
  library loading and project exploration. Worth reopening only if this ever
  runs anywhere but beside the person who launched it.

- **Logging.** No structured logging here beyond stderr, and MCP has a
  `logging/setLevel`. ocaml-mcp lists improving logging as a TODO too.

- **Transports beyond stdio.** ocaml-mcp offers socket and HTTP, and lists
  WebSocket and SSE as missing. Out of scope here for the reason in the trust
  boundary ticket: stdio implies a local parent, and that assumption is what
  makes running unsandboxed acceptable.
- **Tracing a function.** `#trace` is the one directive whose absence costs a
  capability rather than a redundancy, see
  [Toplevel directives are not part of the tool surface](tickets/029-directives-are-not-the-surface.md).
  Whether an agent wants a call trace at all is the open part; the machinery
  for it already exists.
- **Resource limits.** A phrase can allocate until the machine dies. A
  deadline bounds time but nothing bounds memory.
- **History.** utop's protocol exposes history navigation and
  `save-history`. Unclear whether an agent client wants any of it.
- **Publishing.** Installing and client registration are done. What remains
  is whether this is worth releasing to opam, and what a version-1 promise
  about the tool surface would be.

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

**Sane defaults, so a call says only what is unusual.** The session name
defaults to "main", because a name is a handle and most callers want one
toplevel; `load` defaults to the project the server was started in. A caller
that needs two independent toplevels, or another project, still says so.

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
  `isError` only for the server failing at its own job. **Revised for token
  cost:** a field with nothing to say is absent, truncation is folded into the
  output as a count of what was lost, the autorun rules are reported only when
  they were not the default, and a phrase's bindings are gone because the
  transcript beside them already said the same thing.
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
- [Building the project from a tool](tickets/025-build-from-a-tool.md) —
  **superseded, the tool was removed.** `dune build` was shelled out, after
  five obstacles on the RPC route, the last of which was unexplained, and
  diagnostics were parsed into fields. Removed because a caller with a shell
  gets the same answer from `dune build` itself; the wrapper only paid for a
  client with no shell. The analysis of what driving dune costs still holds up
  the `dune top` call in `load` and the index call in `uses`.
- [Should Lwt and Async expressions auto-run](tickets/019-lwt-async-auto-run.md)
  — yes, as utop does, rewriting bare expressions only, self-gating so it is
  inert without the library. **The setting is now per call, not per session:**
  it meant three things in one argument and made a session's behaviour depend
  on a call nobody remembers. Every result names the rules the call ran under
  and a rewritten phrase credits the rule that ran it.
- [Toplevel directives are not part of the tool surface](tickets/029-directives-are-not-the-surface.md)
  — none of them get exposed: `#require` reports failure as prose where the
  tool reports fields, `load` is not expressible as directives at all, and a
  buffer containing one cannot be typed before it runs. Wording only; `eval`
  already rejected them. `#trace` is the one real loss and stays in the fog.
- [A ceiling on a phrase's heap](tickets/030-heap-ceiling.md) — a Gc alarm
  armed only while a phrase runs, raising at 2048 MiB by default, so a runaway
  allocation is stopped the way a runaway loop is interrupted rather than by
  the allocator killing the worker. Detected by a flag because execute_phrase
  swallows the exception, and the catch compacts or the next phrase trips on
  the dead one's garbage.
- [A reset can carry the code that follows it](tickets/031-reset-carries-its-preamble.md)
  — `reset` takes optional code and evaluates it in the fresh toplevel in the
  same call, so a preamble goes back atomically. Nothing is stored: a session
  carrying a preamble would make "empty" conditional and put an init file back
  under another name.
- [Module signatures without loading](tickets/026-signatures-without-loading.md)
  — the `signature` tool: findlib's recursive directories on a throwaway
  toplevel's search path and `#show`, so an installed package's signature can
  be read without linking it; local rungs only, no network.
- [Reading a name's documentation](tickets/032-documentation-lookup.md) — the
  `document` tool over merlin: ask by name and the server supplies position
  1:0, because merlin infers the namespace to search from the node under the
  cursor and a module path narrows it to modules alone; merlin's failures are
  strings that read like docstrings, so the sentinel set is decoded into an
  error field; odoc markup is passed through unrendered.
- [Breakpoints in a session](tickets/035-breakpoints.md) — `[%break]` parks a
  phrase as a continuation and binds the locals in scope under `bp_` names, so
  the session stays usable while the rest of the phrase waits; `continue` and
  `inspect` are the tools, a local whose type cannot leave the phrase is
  skipped with the compiler's own reason, and a marker under autorun is
  refused before anything runs.
- [A raise in a phrase had no position](tickets/034-locating-a-raise.md) —
  **fixed.** The worker never set `Clflags.debug`, so phrases compiled without
  debug events and an exception reported "Called from unknown location";
  positions now count into the code the caller sent, as error spans already do.
- [Stopping inside a running phrase](tickets/033-breakpoints-are-an-effect.md)
  — a breakpoint here would be an effect handler around a phrase, keeping the
  continuation and leaving the session alive, not a debugger: the debug
  protocol has no command that runs code, ocamldebug cannot apply a function,
  earlybird has no evaluate at all and did not complete a handshake here, and
  the runtime patch that would fix all of it is a compiler fork. Nothing built;
  the limits are measured in the ticket, including which one turned out not to
  be a limit: a caller's locals come back through a shadow stack, which
  replaces its top frame at a tail call rather than pushing, so space stays
  constant and a ring buffer keeps the trail a debugger cannot.
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
- [Loading what the worker already is](tickets/038-loading-what-the-worker-already-is.md)
  — **fixed.** `load` loaded the externals the worker is itself built from, and
  replacing the live `Toploop` left the session dead on the next phrase, with
  the death reported against that phrase rather than the load. An external
  archive the worker already contains is now skipped, and `require` stopped
  reloading them too. Bisected, not guessed; checked by a script, because dune
  will not run inside dune.
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
- **Documentation lookup.** No longer fog for a name a project file can see:
  the `document` tool, see
  [Reading a name's documentation](tickets/032-documentation-lookup.md). What
  remains is a comment on a name in a package nothing references, which merlin
  cannot reach and `signature` reads without comments; it would mean reading
  the installed `.mli`. Jump to source is no longer fog either, see
  [Merlin-backed source queries](tickets/027-merlin-source-queries.md), and
  neither is reading an uninstalled-in-the-session signature, see
  [Module signatures without loading](tickets/026-signatures-without-loading.md).

- **A project as a tree of modules rather than files.** From ocaml-mcp's
  TODO, and the most interesting idea in it: an agent working on an OCaml
  project arguably wants to address modules, not paths. What that would mean
  for a tool surface here is not yet sharp.

- **Package search and an opam index.** Declined. ocaml-mcp plans to process
  opam-repository into a cached index keyed by commit, to resolve package
  versions and later to support semantic search over source. Large, and it
  would answer about packages that are not installed, which is the half of the
  ladder that [Module signatures without loading](tickets/026-signatures-without-loading.md)
  refused for the same reason the network rung was refused there: everything
  here stays beside the person who launched it, and what is installed is what
  a session can load anyway.

- **Formatting.** Declined. ocamlformat as a tool, as ocaml-mcp exposes, but
  formatting belongs to whatever writes the file and this server never writes
  one. A caller that edits already reaches ocamlformat through its shell, the
  way it reaches dune since the build tool was removed, see
  [Building the project from a tool](tickets/025-build-from-a-tool.md). Same
  reasoning, same answer.

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
- **Tracing a function, and stopping in one.** No longer fog, see
  [Stopping inside a running phrase](tickets/033-breakpoints-are-an-effect.md):
  `#trace` shows the boundary and never the interior, the debuggers cannot
  evaluate, and a breakpoint here would be an effect handler rather than
  either. Nothing is built; what is open is whether an agent ever asks for it.
- **Resource limits beyond time and heap.** Both are now bounded, see
  [A ceiling on a phrase's heap](tickets/030-heap-ceiling.md). File
  descriptors, subprocesses and disk are not, and a phrase can still spawn
  something the worker's death would not reap.
- **History.** Declined. utop's history serves a human recalling a line to
  retype it; an agent has the conversation for that, and what a session holds
  is its bindings rather than a list of what was typed. Nothing would read it.
- **Publishing.** Installing and client registration are done. What remains
  is whether this is worth releasing to opam, and what a version-1 promise
  about the tool surface would be.

### From the conversational-dev clients

Surveyed September 2026: [sly](https://github.com/joaotavora/sly) and its
slynk backend, [CIDER](https://github.com/clojure-emacs/cider) with the nREPL
op surface it drives, and [conjure](https://github.com/Olical/conjure).
Comparison was against every `defslyfun` in slynk, CIDER's lisp modules, and
conjure's mapping documentation, and against merlin's own command list, where
several of the same ideas turned out to be sitting unused. Two are settled
rather than fog. A last-value binding, CL's `*` and CIDER's `*1`, is already
here as the `_N` implicit names. Conjure has nothing architectural to take: it
is a thin editor client and its log buffer is the transcript an agent's
conversation already is, which History below declined.

- **Stickers.** From `sly-stickers`, and the best fit of anything surveyed. A
  marked expression records the value that flowed through it on every hit and
  the phrase runs to completion; sly keeps a hit count, the recorded values,
  and whether the site exited non-locally instead of returning. Against
  [Breakpoints in a session](tickets/035-breakpoints.md) it is the complement:
  a breakpoint stops once and shows locals, a sticker watches a loop body a
  thousand times and never stops. Most of the cost is already paid, since the
  typed-tree rewrite injects a hook and prints a local's type at compile time,
  which is what a sticker needs to print its value at record time. Open:
  whether an agent wants this, and what a recording table costs to keep.

- **Type-directed construction.** Merlin's `construct` and `holes`, reachable
  through the shell-out that [Merlin-backed source queries](tickets/027-merlin-source-queries.md)
  already owns. `holes` lists every `_` in a file and `construct` returns the
  expressions that could fill one at its inferred type, with a depth knob;
  `case-analysis` turns an expression into a match with a branch per
  constructor. Not from the Lisps, but the same family, and an agent writing
  OCaml has no way to ask for it today.

- **Macroexpansion.** Specified in [What a ppx generated](tickets/037-ppx-expansion.md),
  open. Core to both CIDER and SLY, and the OCaml equivalent is ppx,
  currently invisible. Merlin's `expand-ppx` expands at a position, which
  is cheaper than `dune describe pp`, which builds the file and prints the
  whole preprocessed source.

- **Tracing, again.** `sly-trace-dialog` builds a real call tree with
  arguments and return values per frame, which is more than `#trace` gives and
  more than [Stopping inside a running phrase](tickets/033-breakpoints-are-an-effect.md)
  found reachable. Weaker now than it looks, because stickers would cover most
  of what a caller actually wants from a trace at less cost.

- **Evaluating a form at a source position.** Conjure evaluates the form or
  root form under the cursor rather than pasted code. Here that would be
  `file` and `line` instead of `code`, saving the round trip and pointing
  error spans at real file lines; `outline` already knows the ranges. Against
  it: a second way to say what `eval` says, on a surface that is fourteen
  tools already.

- **The namespace an evaluation happens in.** Specified in
  [Evaluating in a file's context](tickets/036-a-file-s-context.md), open.
  Both CIDER's ns and SLY's
  `set-package` evaluate inside an ambient namespace, so a snippet lifted out
  of a file resolves the way the file does. OCaml has no such thing, and a
  session evaluating code from a project file sees none of that file's opens.
  Merlin supplies dune's `-open` through `dump-configuration` and both opens
  were measured to work in a loaded session, so it is lazier than it first
  looked. The real impedance mismatch of the three.

- **The inspector.** Declined. The most-used feature in both CIDER and SLY,
  and it does not transfer: it exists because a Lisp value carries its own
  structure at runtime, an OCaml value does not, and an agent that wants a
  field evaluates the projection. Frame locals and restarts are settled by
  [Stopping inside a running phrase](tickets/033-breakpoints-are-an-effect.md).
  Session cloning, completion, apropos and the test runner are covered,
  human-facing, or belong in the caller's shell.

- **Print limits per call.** Declined as stated. nREPL's `print-length` and
  `print-level` have a counterpart already: Toploop caps at
  `max_printer_steps`. What is missing is only a per-call knob, not a bound.

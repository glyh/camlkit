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

**A tool description is a trigger.** It says when to reach for the tool and
the one mistake that would make a call wrong, nothing more; it is loaded
whether or not the tool is called. Limits, edge cases and what result fields
mean go in the tool's manual in `lib/guide.ml`, read through `help`. See
[Descriptions are triggers](tickets/062-descriptions-are-triggers.md).

**The interface is consistent.** A new tool follows what the others do: the
same argument names for the same things (`session`, `file`, `line`, `col`,
`path`), `session` defaulting to `main`, absent rather than empty fields, a
negative answer rather than `isError` when the question was fine, and a manual
behind a short description. A deviation needs a reason recorded in its ticket.

**Report, don't guess.** When a result could be tidied by a clever rule, such
as replacing a watch site when its definition is sent again, do not build the
rule. Report what happened, with the ids and counts that let the calling agent
act on it (a warning naming the site and the total, which `markers
disarm_sites` can then use), and leave the cleanup to that agent. A heuristic
that hides or replaces something guesses at intent the caller has and we do
not.

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
  — no serialization dependency; frame is metadata plus a raw byte
  segment, which measured faster than every library tested. **The metadata
  half is superseded**: it was JSON, and the survey missed `Marshal` because
  that is stdlib rather than a library. The raw segment stands.
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
- [One point, several behaviours](tickets/049-one-point-several-behaviours.md)
  — **done, and the factoring it proposed was declined.** Stickers are built,
  as `[%watch "name" expr]`, but as a second marker rather than as a behaviour
  on the first: a break replaces an expression in unit position and types as
  unit, a watch wraps one and returns its value, so the rewrites cannot be
  shared. What is shared is the registry, the naming, the disarm flag and a
  location-matching walk over the typed tree - fifteen lines. Every marker is
  named now, which makes a bare `[%break]` a compile error, because a marker
  compiles into the code holding it and fires whenever that code runs: measured,
  and the reason a marker in a hot function was a trap. The `markers` tool lists
  them, disarms them and arms them again. A result carries what its own phrase
  recorded; `inspect` carries the whole trail.
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
- [Evaluating in a file's context](tickets/036-a-file-s-context.md) — the
  `context` tool: dune's `-open` asked of merlin, the file's own opens, and the
  file's own module last, returned as a preamble to evaluate rather than
  applied per call. An open is session state already, and prepending to the
  caller's source would shift every span.
- [Marshal instead of JSON metadata](tickets/043-marshal-for-worker-ipc.md)
  — the metadata segment is a `Marshal`, not hand-written encoders, which took
  167 lines out of `wire/msg.ml` and the yojson dependency out of `wire`. Not
  for speed: the saving is microseconds against a process round trip. Marshal
  casts blind, so the frame gained a magic and a build stamp and refuses a peer
  built from other source instead of reading a pointer as an integer.
- [dune cannot see the switch a client did not pass on](tickets/039-dune-in-a-bare-environment.md)
  — **fixed.** Both processes adopt their own switch at startup, derived from
  where the binary is rather than from `opam env`, which would answer for the
  shell's switch instead of the one the worker's bytecode was built in. `PATH`
  and `OPAM_SWITCH_PREFIX` only: `CAML_LD_LIBRARY_PATH` stays untouched so
  ticket 028's `Dll.add_path` decision stands. `CAMLKIT_SWITCH` overrides,
  soundly only for a switch of the same OCaml version.
- [What a phrase cost](tickets/045-what-a-phrase-cost.md) — **done.**
  `cost: true` on `eval` reports each phrase's wall clock and bytes allocated.
  Opt-in rather than reported above a threshold, because no threshold suits
  every caller and a caller who is not measuring should not pay two numbers per
  line. The first implementation was wrong in a way that looked right:
  `Gc.quick_stat` alone measured `Array.make 1000` as 3.2 MB and
  `String.make 10000` as nothing, because its `minor_words` lags the young
  region and a large allocation skips the minor heap. A minor collection before
  each reading fixes it, and is paid for only when asked. The reading still
  covers compiling, running and printing the phrase, so there is a floor of 70
  to 300 kB that the description names.
- [Diagnostics without a build](tickets/042-diagnostics-without-a-build.md) —
  **done.** The `diagnostics` tool: merlin's errors for one file, warnings kept
  apart from errors, in 12 ms standalone and 43 ms on a real project file. It
  takes the edit rather than the file when given one, which is the half nothing
  else on this surface can do and the question the ticket turned on; the file is
  still named, because that is how the configuration to type against is found.
  Not a build, and the description says so twice, because a clean answer here is
  not a passing build.
- [What a ppx generated](tickets/037-ppx-expansion.md) — **done.** The `expand`
  tool over merlin's `expand-ppx`: the code a deriver or extension produced at a
  position, as source rather than as JSON with its newlines escaped, so an agent
  stops guessing whether `[@@deriving yojson]` gave `to_yojson` or
  `yojson_of_t`. A position, like every other source tool, because merlin takes
  only one and `outline` already supplies them. Verified against a rewriter the
  suite grew for itself over compiler-libs, since no ppx package is installed
  here: dune's `pps` refuses a plain `Ast_mapper` rewriter, and merlin still
  reads a `.merlin`, which is what made an expansion testable at all.
- [A warning arrives several times over](tickets/050-a-warning-arrives-several-times-over.md)
  — **fixed.** One warning reached the caller five times: once as a warning and
  four times as the phrase's own output, because the typecheck passes print to
  the worker's stderr and that is the file program output is read from.
  Capturing the passes took it to three; the last two turned out to come from a
  printer inside the compiler that does not read
  `Location.formatter_for_warnings` at all, proved by discarding everything
  that ref receives and watching both copies survive. Fixed by resetting the
  capture between typing and running rather than by finding that printer:
  nothing in it before execution can be program output, since a phrase cannot
  print before it runs.
- [A tree built by another compiler](tickets/044-a-tree-built-by-another-compiler.md)
  — **fixed.** The worker is bytecode and loads only archives its own compiler
  produced, and a tree from another one reported "is not a bytecode object
  file", once per archive, naming no version and no cause. Twelve bytes against
  `Config.cma_magic_number` now decide it, once per load, reported as the
  load's own failure since nothing in such a tree can load. The ticket's own
  measurement was wrong - it named 5.4.0 and `Caml1999A036` from a probe
  compiled outside the worker's switch, which is 5.3.0 and `Caml1999A035` - and
  the correction is kept there, because it cost a debugging detour and is the
  same mistake ticket 039 is about.
- [A built index is not a populated one](tickets/046-a-built-index-is-not-a-populated-one.md)
  — **fixed.** `uses` trusted the exit status of `dune build @ocaml-index`, and
  a zero exit is not an index with occurrences in it: the data it is built from
  is written by OCaml 5.2 and later only, and the merlin tools answer about
  whatever project they are pointed at, including one no session could run.
  It now asks whether an index file was written, which needs no theory about
  why one was not. Answered with the existing `incomplete` field rather than
  refused, unlike ticket 040, because a buffer-local answer is correct as far
  as it goes where a scanned load was not.
- [context lost the wrapper](tickets/051-context-lost-the-wrapper.md) —
  **fixed.** A relative `file` argument silently cost every merlin query the
  project's configuration: the query runs in the file's own directory so merlin
  can find that configuration, and the path no longer resolved after the `cd`.
  merlin answered without it rather than refusing, so `context` lost dune's
  `-open` and the file's own module, the two a reader cannot guess. One
  resolution in `lib/merlin.ml`, shared by every merlin-backed tool. The ticket
  had guessed a regression in how the reply was read; the reading was correct
  all along and the caller's spelling was the trigger.
- [A failed dune top degrades in silence](tickets/040-a-silent-fallback.md) —
  **fixed.** `dune top` failing was indistinguishable from a directory that is
  not a dune project, and both fell through to scanning `_build` for archives.
  Reproduced on camlkit itself: the scan dropped both externals, pulled a test
  fixture into the session, and advised `require` for a package the project
  declares. The call now keeps dune's stderr instead of discarding it, and a
  dune project whose dune could not answer is refused with what dune said
  rather than scanned. Refused rather than scanned-with-a-field, because a
  field beside a wrong answer does not stop a caller acting on the message.
- [Typecheck without running](tickets/041-typecheck-without-running.md) —
  **done.** `check: true` on `eval` stops after the typecheck pass: types back,
  nothing runs, no implicit name consumed, the same warnings and the same
  typecheck failures a run would give. An argument rather than a fifteenth tool,
  because a separate one would duplicate autorun, several phrases and every
  failure shape to change one thing; the result says `checked`, because a
  checked rendering is a run's with the value missing and that is too quiet a
  difference to rest on. It also found
  [A warning arrives several times over](tickets/050-a-warning-arrives-several-times-over.md),
  where one warning reached the caller five times, now three.
- [A breakpoint reached inside a run](tickets/052-a-breakpoint-reached-inside-a-run.md)
  — **fixed.** A breakpoint defined earlier and reached from inside an autorun
  phrase stops, and while it is parked every other promise phrase fails with
  Lwt's "Nested calls to Lwt_main.run". That failure now also names the parked
  phrase by id and says to continue or abandon it. Whether 035's static refusal
  is still earned waits on measuring Async.
- [merlin fields with nothing to say](tickets/053-merlin-fields-with-nothing-to-say.md)
  — **fixed.** `outline`, `uses` and `type_at` forwarded merlin's empty and
  default fields (`children: []`, `deprecated: false`, `stale: false`,
  `tail: "no"`) on every item; one recursive trim drops them. `selection` stays,
  as the only span on the name itself.
- [Swapping a function in a loaded project](tickets/054-swapping-a-function-in-a-loaded-project.md)
  — **done.** `[%swap M.f replacement]` in `eval` reaches every caller, those in
  `f`'s own module included, because load builds the project through the worker
  as a ppx and every top-level function checks a cell on entry. Overwriting the
  module's field was measured to miss calls inside the module; the indirection
  costs 1-2 ns a call, and a fast path proving when overwriting is enough was
  rejected as a whole-program analysis for that saving.
- [Swapping a function the interface hides](tickets/055-swapping-a-function-the-interface-hides.md)
  — **open.** Hidden functions have cells but no type in scope to check a
  replacement against; the `.cmt` has one.
- [Swapping a function not written as one](tickets/056-swapping-a-function-not-written-as-one.md)
  — **done.** Measured first: 1.4% of fun's top-level functions and 6.7% of
  mina's are computed by an expression, mostly aliases. The ppx now types a unit
  that has one, with the context the compiler hands it, and wraps a binding
  whose type is an arrow on its first parameter. The rewritten unit is typed
  again and falls back to the syntactic rewrite if it fails. A cold load of fun
  costs 0.6s more. Externals and values stay out of reach.
- [Swapping a function inside a functor](tickets/057-swapping-a-function-inside-a-functor.md)
  — **open.** A unit-level cell would be shared by every application, and no
  path names one application.
- [Swapping a function defined in the session](tickets/058-swapping-a-function-defined-in-the-session.md)
  — **open.** Session definitions have no cells; whether redefinition itself
  should fill one is the surface question.
- [A swap path under a local open](tickets/059-a-swap-path-under-a-local-open.md)
  — **fixed.** The path is resolved in the environment at the swap, read from a
  first typing pass with the swap as `ignore <path>`, so a local open or a local
  module reaches it.
- [load replaces the user's OCAMLPARAM](tickets/060-load-replaces-the-user-s-ocamlparam.md)
  — **fixed.** Merged after the user's `_`, the way the compiler parses it, and
  the separator is chosen so a comma in the worker's path does not split it.
- [A swap under an open takes a name](tickets/061-a-swap-under-an-open-takes-a-name.md)
  — **declined.** A bare swap phrase renders only what it did; the same swap
  under `let open` or `let module` renders `val _0 : unit = ()` too. That line
  is true and cheap, and hiding it would add rules to the rewrite.
- [Descriptions are triggers](tickets/062-descriptions-are-triggers.md)
  — **decided.** Descriptions say when to use a tool; the detail moved to a
  manual behind a nineteenth tool, `help`. 16.4 KB loaded with the tools
  became 7.2 KB.
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
  for a tool surface here is not yet sharp. `dune describe` was measured as the
  obvious source and is weaker than it looks: s-expressions rather than JSON,
  library dependencies named by opaque hashes that have to be resolved back,
  and it needs the dune environment that
  [dune cannot see the switch a client did not pass on](tickets/039-dune-in-a-bare-environment.md)
  is about. Most of what it gives is readable off the file tree anyway.

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
- **Resource limits beyond time and heap.** File descriptors, subprocesses and
  disk are still unbounded, and a phrase can spawn something the worker's death
  would not reap. Time and heap are not, see
  [A ceiling on a phrase's heap](tickets/030-heap-ceiling.md).

- **Two silences and a missing number.** Surveyed September 2026 against
  `mina-agent`, a sibling harness for the Mina monorepo, which reaches OCaml
  through dune from Python and has met several of the same walls.
  [A tree built by another compiler](tickets/044-a-tree-built-by-another-compiler.md)
  is a `load` that reports "not a bytecode object file", once per archive,
  naming no version and no cause, where twelve bytes against
  `Config.cma_magic_number` would say it outright.
  [A built index is not a populated one](tickets/046-a-built-index-is-not-a-populated-one.md)
  is `uses` trusting the exit status of the index build rather than whether an
  index was written, which is the same silence the index build exists to
  prevent. [What a phrase cost](tickets/045-what-a-phrase-cost.md) asks whether
  `eval` should report allocation and wall clock, which the heap ceiling's
  `Gc.quick_stat` already has in hand. What did not transfer from that harness,
  and why, is in each ticket: its `_build/log` provenance read is tied to a dune
  that no longer writes the file, and its hand-written `compiler-libs`
  occurrence walker serves a 4.14 tree this server cannot start a session for.

- **The environment a client launches us in.** No longer fog. The cause is
  fixed, see ticket 039 below, and the fallback it used to trigger now says so:
  [A failed dune top degrades in silence](tickets/040-a-silent-fallback.md).

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

- **Stickers.** No longer fog: built as `[%watch "name" expr]`, see
  [One point, several behaviours](tickets/049-one-point-several-behaviours.md).
  The entry below is the survey that proposed them, kept for its reasoning. A
  marked expression records the value that flowed through it on every hit and
  the phrase runs to completion; sly keeps a hit count, the recorded values,
  and whether the site exited non-locally instead of returning. Against
  [Breakpoints in a session](tickets/035-breakpoints.md) it is the complement:
  a breakpoint stops once and shows locals, a sticker watches a loop body a
  thousand times and never stops. Most of the cost is already paid, since the
  typed-tree rewrite injects a hook and prints a local's type at compile time,
  which is what a sticker needs to print its value at record time. Open:
  whether an agent wants this, and what a recording table costs to keep.
  Whether it is a second marker or a behaviour on the first is
  [One point, several behaviours](tickets/049-one-point-several-behaviours.md).

  On that last one, the idea worth borrowing is a cutoff, from Jane Street's
  [incremental](https://github.com/janestreet/incremental), whose `Cutoff` is a
  function of a node's old and new value saying whether the change is worth
  propagating at all, with `of_equal` and `phys_equal` ready-made. A sticker
  that records only when the value differs from the last one it saw, while
  still counting every hit, is bounded by the number of distinct values rather
  than by the iteration count, which is what makes a sticker in a hot loop
  affordable. sly already keeps the hit count apart from the recorded values,
  so half the shape is in the prior art.

  The library itself is declined twice over. It instruments its own dataflow
  graph, where `Observer` and `on_update` fire per stabilization on nodes the
  author built with `map` and `bind`, so reaching a sticker's actual target - an
  expression in code the caller wrote and never designed as a graph - would mean
  rewriting the phrase into an incremental computation and changing what it
  means. The typed-tree rewrite from
  [Breakpoints in a session](tickets/035-breakpoints.md) already reaches
  arbitrary code, which is the harder half and is paid for. And it depends on
  core, core_kernel, ppx_jane, ppx_optcomp, janestreet_lru_cache and
  textutils_kernel: [Removing the utop dependency](tickets/022-drop-utop.md)
  took this project from 22 packages to 2, and six back for an introspection
  shape buys less than utop did.

- **Type-directed construction.** Merlin's `construct` and `holes`, reachable
  through the shell-out that [Merlin-backed source queries](tickets/027-merlin-source-queries.md)
  already owns. `holes` lists every `_` in a file and `construct` returns the
  expressions that could fill one at its inferred type, with a depth knob;
  `case-analysis` turns an expression into a match with a branch per
  constructor. Not from the Lisps, but the same family, and an agent writing
  OCaml has no way to ask for it today.

- **Macroexpansion.** No longer fog, see
  [What a ppx generated](tickets/037-ppx-expansion.md): the `expand` tool.
  Merlin's `expand-ppx` answers at a position without a build, where
  `dune describe pp` builds the file and prints the whole preprocessed source.
  What remains open is only whether a structure-level extension such as
  `let%test_module` ever expands, measured once against one ppx and not a rule.

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

### From the live-image systems

Surveyed September 2026: [SBCL](https://github.com/sbcl/sbcl) itself rather
than the slynk backend already surveyed above, and
[Pharo](https://github.com/pharo-project/pharo), which was not surveyed at all
before. Comparison was against `sb-introspect`'s exports, `sb-cover`,
`sb-sprof` and the condition system, and against Pharo's `DebugPoints`,
`Reflectivity` and `Calypso-NavigationModel` packages. Three things came out of
it as tickets and the rest is below.

- **Stopping where it raised.** From SBCL, and the largest gap anything
  surveyed has found. A condition is signalled before the stack unwinds, so
  the debugger runs on top of the frame that failed and the values that
  produced the failure are still there.
  [A raise in a phrase had no position](tickets/034-locating-a-raise.md) gives
  a span read after every frame is gone. Specified in
  [Stopping where it raised](tickets/047-stopping-where-it-raised.md), open,
  and open on a real obstacle: an OCaml exception unwinds where an effect does
  not, so the trigger is cheap and the harvest is not.

- **A breakpoint in code the caller did not write.** From Pharo's
  Reflectivity, which installs a link on a node of an already-compiled method
  and removes it again without touching source.
  [Breakpoints in a session](tickets/035-breakpoints.md) deleted positional
  breakpoints on the argument that the agent writes the phrase, which is true
  of a phrase and false of a project loaded into the session. Specified in
  [A breakpoint in code the caller did not write](tickets/048-a-breakpoint-in-code-the-caller-did-not-write.md),
  open, and open on whether the module can be reached without a recompile that
  invalidates the session's existing values.

- **Reference queries split by kind.** `sb-introspect` exports `who-calls`,
  `who-references`, `who-binds`, `who-sets`, `who-macroexpands` and
  `who-specializes` as six questions where `uses` here asks one. The OCaml
  analogue is narrower than the Lisp one, because there is no `setf` and no
  method specialisation, but "who calls this" and "who mentions this type" are
  different questions asked for different reasons, and merlin's occurrence
  index does not distinguish them either. Fog, not a ticket: nothing says yet
  that a caller wants the split badly enough to pay for it.

- **Coverage and a profiler.** `sb-cover` records per-form coverage from the
  compiler and `sb-sprof` is a statistical profiler with call counting and a
  call graph, both driven from the REPL. These are the larger siblings of
  [What a phrase cost](tickets/045-what-a-phrase-cost.md): two numbers say what
  a phrase cost, a profile says where it went, and coverage says which branches
  a run reached. Against them, hard: `dune test --instrument-with bisect_ppx`
  and a profiler both exist outside this server and belong in the caller's
  shell, which is where the test runner was already sent.

- **Epicea.** Pharo records every change as a replayable log that survives a
  crashed image. This looks like the History that the map declines above and is
  not the same thing: its purpose is not recall but rebuilding. A camlkit
  worker that dies loses every binding, and a log of the phrases a session
  accepted would restore it. Fog, because it is unclear whether a session dying
  is common enough to be worth a log, and because a replay of a session that
  loaded a file which has since changed rebuilds something else.

- **The rest of Pharo, declined.** Senders and implementors are `uses` and
  `locate`. The method finder, which finds a selector from an example input and
  output, is `search_type` reached from the other end. Spotter is completion,
  which the map has already covered. The refactoring engine, the test runner
  and the quality rules belong in the caller's shell for the same reason the
  build tool does, see
  [Building the project from a tool](tickets/025-build-from-a-tool.md).

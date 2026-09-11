---
status: closed
type: grilling
blocked-by: []
assignee: lyh
---

# Protocol between server and worker

## Question

The worker is our own binary, so the protocol is ours to design and has
none of the constraints that made utop's awkward.

## Settled so far

**Length-prefixed framing in two segments**, JSON metadata followed by raw
output bytes, with no serialization dependency. See
[Serialization format for worker IPC](017-serialization-benchmark.md).

**The descriptor layout is forced by `Unix.create_process`**, which passes
only fds 0, 1 and 2, leaving no spare channel to hand the worker. So the
worker rearranges its own descriptors at startup: dup the inherited pipes
to private fds, then put `/dev/null` on fd 0 and the capture file on fds 1
and 2. After that, evaluated code cannot reach the IPC channel through any
standard descriptor. This needs confirming in code, not assumed.

**Output capture is a temp file, truncated at the start of each eval.**
The prototype accumulated into one file and read from a saved offset,
which grows without bound over a long session. Truncating per eval keeps
it flat. Open it `O_TMPFILE` so it disappears when the worker dies. A file
rather than a pipe because a phrase that outruns a draining reader would
fill the pipe buffer and block the toplevel mid-evaluation, which is the
class of bug the worker architecture just escaped.

**The worker announces its capture file path at handshake, and sends
nothing during an evaluation.** No heartbeats: a timer inside an otherwise
purely sequential blocking worker is most of what would complicate it. The
path is free progress instead, since the server can read partial output
from the file at any time with no protocol traffic. It also means output
survives a kill: today a hung worker that gets killed loses everything the
phrase printed. Truncate-per-eval means the file holds exactly the current
evaluation.

**A worker that dies mid-phrase kills its session.** Return an `isError`
result, consistent with the rule that `isError` means infrastructure
failure, and require the caller to create a new session. The toplevel
state is genuinely gone, and an agent that kept using the name would be
reasoning about an environment that no longer exists. Rejected respawning
transparently behind a state-lost flag, which saves a round trip at the
risk of the flag being ignored.

**One eval request carries many phrases and stops at the first failure.**
An agent pasting a chunk of code containing several terminators is the
common case, and requiring it to split would mean reimplementing OCaml
lexing client-side. Evaluate in order, halt on the first failure, and
report how many succeeded so the caller knows where it stopped. Rejected
running all phrases regardless, which happily executes code depending on a
binding an earlier failed phrase never created.

**Per-phrase records with offsets into the raw segment.** Evaluation
yields two genuinely different things and the prototype wrongly glued them
together: the toplevel's own rendering (`val x : int = 42`,
`Exception: Failure "boom".`) comes from the formatter passed to
`execute_phrase`, while program output comes from the capture file. Each
phrase gets a record carrying its rendering, its warnings, and a start and
length into the raw segment. The offsets are free, since capture is
truncated per eval and the file size after each phrase gives the span.

**Warnings are their own field.** `Location.formatter_for_warnings` is a
ref in compiler-libs; pointing it at a separate buffer separates warning
text from value rendering cleanly. Verified: an unused-variable warning and
a non-exhaustive-match warning both moved out of the rendering buffer
intact. Free, so taken.

**Error locations carry both forms.** `UTop.check_phrase` returns
`location list` where `location = int * int` byte offsets, plus a
`lines option list` for line ranges. Both are already there, so both are
reported.

**Parse the whole buffer first; a parse error executes nothing.**
`UTop.parse_use_file` yields the phrase list in one go, so a syntax error
in the last phrase is known before the first runs. The agent then fixes
and resubmits against unchanged state instead of reconstructing which
phrases took effect.

**Type errors also execute nothing. The contract is uniform.** An earlier
draft accepted an asymmetry here, on the reasoning that whether a later
phrase typechecks depends on what earlier phrases did to the environment.
That reasoning was wrong: typing depends on earlier phrases being *typed*,
not on their being *run*.

The mechanism is a two-pass evaluation, verified in
[assets/precheck-prototype.ml](../assets/precheck-prototype.ml):

1. Snapshot `Toploop.toplevel_env`.
2. For each phrase, `Typemod.type_toplevel_phrase` types it and returns a
   new environment, which we install before typing the next. Nothing is
   evaluated.
3. On any failure, restore the snapshot and execute nothing.
4. If all phrases type, restore the snapshot and execute them normally.

Verified: `let a = 5;; a + 1;;` passes, since pass one advances the
environment so the second phrase sees `a`. `let b = 5;; b + true;;` fails
at the second phrase and leaves `b` unbound, so the first genuinely did
not run.

Note this is not what `UTop.check_phrase` does. That wraps items in
`let _ () = let module _ = struct ... end in ()` and then *restores* the
environment, so checks do not compose across phrases. It also returns
`None` for directives without checking them.

**`eval` accepts only phrases, never directives.** Directives are not
typeable, so skipping them in pass one falsely rejects valid code:
`#require "yojson";; Yojson.Safe.from_string "[]";;` failed pre-check with
`Unbound module Yojson`, because the library was never loaded. A
stdlib-adjacent case like `str` passed only by accident of OCaml 5's
auto-include, which does not apply to findlib packages.

Rather than special-casing directives inside `eval`, they get their own
tools. `#show` is already the describe tool, and library loading already
has its own ticket. This removes the last unskippable case, so the
guarantee holds unconditionally with no fallback mode.

A request containing a directive is **rejected before anything executes**,
with an error naming the tool to use instead. Parsing already distinguishes
`Ptop_dir`, so this is free. Rejected executing directives in place, which
would make the promise that nothing runs conditional in a way the caller
cannot see, and rejected stripping them, which executes something other
than what was submitted.

Which directives earn a tool belongs to
[Session lifecycle and the tool surface](006-tool-surface.md).

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

**Type errors are necessarily asymmetric, and this is documented rather
than papered over.** Whether a later phrase typechecks depends on what
earlier phrases did to the environment, so typing is checked as execution
reaches each phrase. Partial execution is therefore possible on a type
error but not on a syntax error. Say so in the tool description. Rejected
making it uniform by rolling back, which the toplevel cannot do and whose
side effects have already happened, so it would be a lie.

---
status: open
type: grilling
blocked-by: []
assignee:
---

# Protocol between server and worker

## Question

The worker is our own binary, so the protocol is ours to design and has
none of the constraints that made utop's awkward.

## Settled so far

**Length-prefixed framing**, with a fast maintained binary serialization
rather than JSON. The concrete library is pending a benchmark; see
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

## Still open

The request and response shapes, what a worker reports during a long
evaluation, and what the server does with a worker that dies mid-phrase.

Keep it minimal. The server already holds the process handle, so liveness
and kill need no protocol support.

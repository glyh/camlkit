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

Decide the framing, most likely length-prefixed JSON rather than
line-delimited, since evaluated output contains newlines freely. Decide
which descriptor carries it, given fd 0 goes to `/dev/null` and fd 1 is
`dup2`'d to the capture file. Decide the request and response shapes, how
a worker reports that it is still alive during a long evaluation, and what
the server does with a worker that dies mid-phrase.

Keep it minimal. The server already has the process handle, so liveness
and kill do not need protocol support.

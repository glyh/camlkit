---
status: resolved
type: decision
blocked-by: []
assignee: lyh
---

# A reset can carry the code that follows it

## Question

An agent working through camlkit reported retyping the same three-line helper
preamble after every reset, and in three sessions rather than one. It asked
for a way to define a preamble.

## Rejected: a stored preamble

A session remembering source to replay would fight two settled decisions.

**Reset means empty.** An explicit reset already forgets the findlib packages
the session had required; only the reset inside `load` replays them, because
there the reset is a means rather than the request, see
[Loading a dune project's own libraries](021-dune-aware-load.md). A preamble
surviving reset makes "empty" conditional, and the caller can no longer tell
what is in the session from what it sent.

**Sessions are hermetic.** No init file is evaluated, so a session does not
vary with the machine it runs on. A stored preamble is an init file scoped to
a session name instead of a home directory: the same surprise, nearer.

Against that, re-sending three lines is one `eval` call, and the caller has
the text in its context already.

## Chosen: a `code` argument on `reset`

The code is evaluated in the fresh toplevel inside the same call. Nothing is
stored, nothing survives anything, and the caller sends the text every time,
which is what makes it different from an init file. What it buys is that
reset-then-define is atomic: no call from anywhere else can reach the empty
toplevel in between.

The result is an eval's rather than the bare `status: "reset"`, since the
caller needs to know whether its own preamble typechecked. The output schema
declares `phrases` as present only when the reset carried code.

The agent's own remedy - keep one session and reload rather than starting
fresh ones - was the larger part of its problem and needed no code at all.

## Left alone

A worker that dies on its own, from the heap ceiling or a kill after an
unanswered interrupt, still comes back empty, and the caller learns of it from
a note in the next result. Replaying anything there is something a caller
cannot do as cheaply, and it is the one case that would justify stored state.
Nobody has hit it. If it is ever built, the findlib packages are lost the same
way and should be part of the same answer.

---
status: resolved
type: decision
blocked-by: []
assignee: lyh
---

# A ceiling on a phrase's heap

## Question

A deadline bounds how long a phrase runs, and nothing bounded how much it
allocates. The fog entry read: "a phrase can allocate until the machine dies."

## What happened before

Measured at `333cd97`, with the server run under `ulimit -v 2000000` so the
failure was reachable without taking the machine with it. The phrase built a
300-million-element list.

| | Result |
| --- | --- |
| the request | `the worker died during evaluation; session state is gone` |
| the session | restarted on the next call, bindings and loaded packages lost |
| the server | unharmed |

So the failure mode was already contained to one session, and the worker was
killed by the allocator rather than by us. Without the address-space limit the
same phrase would have gone on to exhaust the machine, since nothing here
would have stopped it.

## Chosen: a Gc alarm, armed only while a phrase runs

`Gc.create_alarm` runs its function at the end of every major cycle. The alarm
compares `(Gc.quick_stat ()).heap_words` against a ceiling and raises, which
stops the phrase while the heap is still ours to unwind. The session survives
with its bindings, exactly as an interrupt leaves it.

Three details that the first attempt got wrong, all of them found by running it:

**The trip is detected by a flag, not by catching the exception.**
`Toploop.execute_phrase` catches whatever evaluated code raises and renders it,
so the exception never reaches the caller; the first version reported
`Exception: Dune__exe__Eval.Over_heap_limit.` to the agent. This is the same
shape the interrupt already uses and for the same reason.

**The catch compacts.** The reading is the heap's size, not its live words, so
after a runaway phrase the heap stays at the ceiling and the next phrase trips
immediately on the dead one's garbage. `Gc.compact ()` on the way out gives it
back. Size rather than live words because `Gc.quick_stat` does not walk the
heap, and a heap that has grown this far is the thing being bounded.

**The alarm is deleted as the phrase ends.** Otherwise it can raise while the
response is being serialised, which is not evaluated code and has no business
being interrupted.

Default 2048 MiB, the same kind of constant as the 30-second `eval_timeout`
in `bin/main.ml`. `CAMLKIT_HEAP_LIMIT_MIB` overrides it, which is what lets
the test trip the ceiling in a second rather than at 2 GiB, and lets a small
machine lower it.

## Rejected

**`setrlimit` on the worker.** OCaml's `Unix` does not bind it, so it would
mean spawning through a shell, and the outcome is the failure this ticket set
out to remove: the process dies and the session with it. A limit that can only
kill is worse than one that can raise.

**A per-session argument.** No caller has asked for a different ceiling, and
the tool surface would grow an argument that every call has to ignore. The
environment variable covers the machine-sized case.

**Bounding the minor heap or allocation rate.** Neither is the thing that
kills a machine, and both would cost on every phrase rather than on the
pathological one.

## Measured after

Default ceiling, no address-space limit, a phrase looping to a billion:

| | Result |
| --- | --- |
| the request | `failed` at execute, naming the 2048 MiB ceiling |
| the session | alive, an earlier binding still readable |

The suite covers it at a 64 MiB ceiling, which trips in about a second.

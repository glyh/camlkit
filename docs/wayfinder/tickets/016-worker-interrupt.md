---
status: closed
type: prototype
blocked-by: [015]
assignee: lyh
---

# Interrupting a runaway phrase in the worker

## Question

Against the subprocess, SIGINT was verified to abort a spinning phrase and
leave the session usable. The worker must do the same, but now we own the
handler: the toplevel runs in our process, so the signal has to raise
inside `Toploop.execute_phrase` and be caught without killing the loop.

## Resolution

**Interruption works in-process and state survives, but not by the
mechanism this ticket assumed.** Verified in
[assets/interrupt-prototype.ml](../assets/interrupt-prototype.ml).

**`Sys.Break` does not escape `Toploop.execute_phrase`.** It is caught
internally, prints `Interrupted.`, and the call returns `false`. So there
is no exception to catch, and an interrupted phrase is indistinguishable
from an ordinary failure by return value alone.

**Discrimination needs our own flag.** The SIGINT handler sets a ref
before raising `Sys.Break`; after `execute_phrase` returns, that ref says
whether the failure was an interrupt. Measured behaviour:

| Phrase | returns | interrupted flag |
| --- | --- | --- |
| `let keep = 99;;` | true | false |
| spinning loop, SIGINT sent | false | true |
| `1 + true;;` | raises | false |

**State fully survives an interrupt.** After interrupting a spinning loop,
`keep` still read back as 99 and `let after = keep + 1` evaluated to 100.
This matches what was measured against the subprocess, so the escalation
settled in
[How a session is spawned and supervised](009-session-spawn-and-supervision.md)
carries over unchanged: signal, grace, then kill.

**`execute_phrase` raises on compile errors rather than returning false.**
An uncaught `Typecore.Error` killed the prototype outright. The worker
must wrap execution and convert via `UTop.get_message Errors.report_error`.
The two-pass pre-check in
[Protocol between server and worker](015-worker-ipc.md) catches type errors
before execution, so this should be unreachable, but the guard stays
because an unreachable path that kills the worker is not worth the saving.

Runtime exceptions are different again: `execute_phrase` catches those
itself and renders them, as `Exception: Failure "boom".`, returning false.
So does `Stack_overflow`.

**The swallow case was not genuinely proven.** The intended test recursed
non-tail and hit a stack overflow before it could ignore a `Sys.Break`. A
phrase that truly swallows the signal would simply never return, which is
exactly what the kill step of the escalation exists for, and the server
holds the process handle regardless. Left unproven rather than claimed.

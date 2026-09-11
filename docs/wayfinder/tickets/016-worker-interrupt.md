---
status: open
type: prototype
blocked-by: [015]
assignee:
---

# Interrupting a runaway phrase in the worker

## Question

Against the subprocess, SIGINT was verified to abort a spinning phrase and
leave the session usable. The worker must do the same, but now we own the
handler: the toplevel runs in our process, so the signal has to raise
inside `Toploop.execute_phrase` and be caught without killing the loop.

Confirm `Sys.Break` propagates out of evaluation, that the toplevel
environment survives it, and that a phrase which swallows `Sys.Break`
still ends at the deadline via the server killing the worker.

The escalation settled in
[How a session is spawned and supervised](009-session-spawn-and-supervision.md)
carries over unchanged in shape: signal, grace, then kill.

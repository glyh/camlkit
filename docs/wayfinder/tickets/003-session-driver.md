---
status: closed
type: prototype
blocked-by: [015]
assignee: lyh
---

# Session driver: the select loop

## Question

Build the core: a session that owns a worker child process and turns a
phrase into a captured result.

Covers the `Unix.select` loop over MCP stdin and every worker's response
descriptor, with the timeout set to the earliest pending deadline. Also
spawning, the interrupt escalation, and reaping a dead worker with
`waitpid`. The framing problems that
dominated this ticket are gone now that the worker owns its own output
channel; see
[Worker linked to utop replaces the subprocess protocol](014-worker-architecture.md).

Deliberately excludes the MCP layer. Drive it from a test or a scratch
binary. The question it answers is whether supervision holds up against real
phrases: long output, exceptions, warnings, and phrases that never
terminate.

## Resolution

Implemented in `bin/main.ml`, with the pure parts split out as
`lib/line_reader.ml` and `lib/render.ml`. Seven end-to-end tests drive the
real server binary over JSON-RPC in `test/test_server.ml`, including one
that proves a second session is served while the first spins.

**Two process-lifetime bugs surfaced only under the end-to-end tests**, and
both would have leaked in production:

**Pipes must be `cloexec`.** OCaml's `Unix.pipe` defaults `?cloexec` to
false, so the worker inherited every descriptor the server held, including
the write end of its own input pipe and the read end of its output pipe. It
therefore never saw EOF when the server died and span forever. Confirmed by
reading `/proc/<pid>/fd` on an orphan: four pipe descriptors where there
should have been two. `Unix.create_process` dup2s onto 0, 1 and 2 and dup2
clears the flag on the copy, so the worker still gets its pipes.

**A worker mid-phrase needs a signal, not just a closed pipe.** Closing the
pipes retires an idle worker, which reads EOF and exits, but one inside
`execute_phrase` is not reading anything. The server now kills its workers
from `at_exit`, and handles SIGTERM and SIGHUP so that path runs. A SIGKILL
of the server still strands them; nothing can prevent that.

**`Location` keeps error-reporting state across requests.**
`UTop.get_ocaml_error_message` recovers spans by `Scanf`-ing its own
rendering, and OCaml inserts a separating newline before every report after
the first, which shifts the text and silently yields `(0, 0)`. Rendering the
message separately beforehand triggered the same thing. Fixed by taking
message and location from one call and calling `Location.reset ()` first.
Both halves are pinned by a test.

---
status: closed
type: grilling
blocked-by: []
assignee: lyh
---

# How a session is spawned and supervised

## Question

Where does the utop binary come from, what flags does a session start
with, what happens when an eval overruns its deadline, and where does the
child's real stderr go.

## Resolution

Much of this is answered by utop's own README and man page rather than by
experiment; the rest was verified against opam utop 2.16.0.

**Spawn via `opam exec -- utop -emacs`.** This is the invocation upstream
documents for Emacs, and it resolves the current opam switch at spawn
time. It matters because an MCP client launches the server with a minimal
environment in which `utop` is very likely not on PATH, and because utop
needs `CAML_LD_LIBRARY_PATH` set correctly or it fails to load its stubs,
which the README calls out as a common failure.

Verified that `opam exec` uses `execve` rather than forking, so the child
pid *is* utop. No intermediate process, and signals land directly on the
toplevel.

**Sessions are hermetic: add `-init /dev/null -no-autoload`.** Otherwise
the user's `~/.config/utop/init.ml` and the autoload directory run inside
every session, so results differ per machine and toplevel printers appear
from nowhere. An agent cannot see the session it is driving and should not
be fighting invisible local config.

**Also pass `-implicit-bindings`**, which rewrites `<expr>;;` into
`let _N = <expr>;;`. Verified: `1 + 41;;` yields `val _0 : int = 42` and
`_0` is then referenceable. This gives an agent a handle on every previous
result. The sentinel is a `let () =` binding, so it creates no `_N` of its
own and does not perturb the numbering.

The welcome banner still prints even with `-init /dev/null`. It arrives as
`stdout:` lines before the first `prompt:`, so the existing startup drain
absorbs it. `UTop.set_show_welcome false` is the alternative if it ever
becomes a nuisance.

**Deadline escalation: SIGINT, grace, then kill.** Verified that SIGINT
interrupts a runaway phrase without destroying the session: utop prints
`Interrupted.` and a binding made before the hang was still intact
afterwards. So on deadline, signal and wait a short grace for the
sentinel. If it arrives, return a timeout result with the session alive
and its state intact. If it does not, the stream is most likely
desynchronized by the stdin theft described in the architecture baseline,
which no signal can repair, so kill the child and mark the session dead.
One mechanism covers both failure modes and only destroys state when it
is genuinely unrecoverable.

**The child's real stderr gets its own pipe, routed to the server's log.**
Never merged into the protocol stream. utop's emacs mode redirects the
toplevel's stderr into the protocol as `stderr:` lines, so the real fd
carries only crashes and runtime warnings. Those arrive as lines with no
`command:` prefix and would corrupt the parser. An early prototype merged
them and passed only because utop happened to stay silent.

**Concurrent evals on one session are rejected, not queued.** A toplevel
is strictly sequential. A second eval arriving while one is running
returns a busy error, because an agent firing concurrent evals at a single
session has made a mistake and should see it. Queueing hides the bug, and
the waiting call then spends its deadline sitting in a queue, which
surfaces as an indistinguishable timeout.

**The server's own stdout is the MCP channel.** Nothing in this process
may print to it. All logging goes to stderr.

**Cap captured output per eval and truncate with an explicit marker.** A
phrase can print without bound and an MCP result is a single payload with
no streaming.

## Amendment: no Eio, no Lwt

The Eio recipe verified here worked, but the server does not need it. Its
job is I/O multiplexing, which `Unix.select` covers directly: select over
MCP stdin and every worker's response descriptor, with the timeout set to
the earliest pending deadline. That yields cross-session concurrency and
keeps the server responsive while one session is stuck, single-threaded
and with no runtime.

`Unix.create_process`, `Unix.kill` and `Unix.waitpid` cover spawn, signal
and reap. Dependencies reduce to `unix`, `jsonrpc` and `yojson`.

The worker was already free of both. See
[Worker linked to utop replaces the subprocess protocol](014-worker-architecture.md)
for why keeping it that way matters: evaluated code calling `Lwt_main.run`
works natively, and nothing needs `lwt_eio` to bridge.

Note that the opam-exec spawn decision above is also obsolete. The worker
links utop at build time, so there is no runtime binary lookup.

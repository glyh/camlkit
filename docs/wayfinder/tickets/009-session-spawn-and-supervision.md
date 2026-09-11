---
status: closed
type: grilling
blocked-by: []
assignee: lyh
---

# How a session is spawned and supervised

> **Partly superseded.** Everything about spawning the utop binary and its
> command-line flags is obsolete: the server spawns its own worker, which
> links utop. See
> [Worker linked to utop replaces the subprocess protocol](014-worker-architecture.md)
> and the amendment at the end of this ticket. The supervision decisions -
> deadline escalation, refusing concurrent evals, keeping the server's stdout
> clear - all still stand.

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

## Amendment: what replaced the spawn flags

The flags settled above have no binary to be passed to. Their intent is
carried in the worker instead, and each was verified there rather than
assumed:

- `-short-paths` is `Clflags.real_paths := false`. Confirmed working.
- `-init /dev/null` and `-no-autoload` are unnecessary: the worker never
  calls utop's init-file path, so a session is hermetic by construction.
  Confirmed by pointing `XDG_CONFIG_HOME` at a config directory holding an
  `init.ml` and observing that its binding is unbound in a session.
- `-implicit-bindings` **did not survive the move and was silently a no-op.**
  `UTop.set_create_implicits` only sets a flag read by
  `UTop_main.bind_expressions`, which is not exported. The rewrite of
  `<expr>;;` into `let _N = <expr>;;` is now ours, in `worker/eval.ml`.

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

## Amendment: the capture file is unlinked once both ends hold it

The server names the capture file and opens it before spawning; the worker
opens it too and then unlinks the name. The file lives only as long as those
two descriptors, so it is reclaimed however either process dies, including a
SIGKILL that runs no cleanup.

Before this, a server killed rather than asked to stop left its capture files
behind permanently. That was found the way such things usually are: 161 of
them had accumulated in /tmp from a session's worth of ad-hoc scripts.

Reading partial output still works, because the server holds its own
descriptor and does not need the name.

## Amendment: a worker outlives a killed server no longer

Measured across three ways of stopping the server:

| how it stops | the worker |
| --- | --- |
| stdin closed | survives while in-flight work finishes, then both exit at the deadline |
| SIGTERM | killed, because `at_exit` runs |
| SIGKILL, worker mid-phrase | **was orphaned** |

The last one is the hole: nothing the server owns runs, and a worker
mid-phrase is not reading its pipe either, so it neither sees EOF nor gets
told to stop. It span forever.

The worker now watches for its parent going away, on an alarm armed only
while a request is being handled. That is the only window in which this can
happen, and arming it no wider avoids a signal interrupting the blocking read
between requests. The handler runs during evaluation for the same reason the
interrupt does: OCaml delivers signals at safepoints.

The stdin-closed row is not a leak. Confirmed by watching: the server waits,
the deadline fires at thirty seconds, and both processes exit.

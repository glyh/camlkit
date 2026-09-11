---
status: closed
type: prototype
blocked-by: []
assignee: lyh
---

# Worker linked to utop replaces the subprocess protocol

## Question

Driving `utop -emacs` meant a workaround per quirk: a sentinel to beat the
output race, SIGINT escalation, poison detection for stdin theft, and then
a dead end when a dedicated output socket proved impossible because `Unix`
is not bound in the toplevel. Is owning the eval loop actually small
enough to justify the switch?

## Resolution

**Yes. The loop is about thirty lines and the prototype does everything
the protocol did, better.** Architecture flips: a worker binary links the
utop library and the MCP server drives workers over an protocol we own.
This supersedes the subprocess decision in
[Architecture baseline](001-architecture-baseline.md).

Verified in the prototype, now seeded at `worker/utop_worker.ml`:

| Case | Result |
| --- | --- |
| `let x = 6 * 7;;` | `val x : int = 42` |
| side effects then value | captured in order |
| `x + 1;;` | `- : int = 43`, state persists |
| `1 + true;;` | type error caught before execution |
| `failwith "boom";;` | `Exception: Failure "boom".` |
| `List.ma` completion | `map map2 mapi`, start offset 5 |

**Output capture is a temp file `dup2`'d onto fd 1.** No pipe buffer, no
copy thread, so there is nothing to race. We flush, then read from the
offset we last stopped at. This is what kills the sentinel: framing is
exact because we own the channel, not because we guessed a marker.

**The entry points we need are exported.** `UTop.parse_toplevel_phrase_default`,
`UTop.check_phrase`, `UTop.get_message`, `UTop_complete.complete`, plus
`Toploop.execute_phrase` and `Toploop.initialize_toplevel_env`. Only
`rewrite` and `bind_expressions` are internal, and those are Lwt auto-run
and implicit bindings, both replaceable.

**Neither the worker nor the server runs Eio or Lwt.** The worker's case
first, then the server's.

**The worker runs no Eio and no Lwt runtime, deliberately.** It is
sequential by nature: one toplevel, one phrase at a time, blocking reads.
Concurrency belongs to the server, which supervises N workers. Keeping the
worker free of Eio means evaluated code calling `Lwt_main.run` works
natively, so `lwt_eio` is not needed. Adding Eio to the worker is what
would create the conflict that `lwt_eio` exists to bridge.

**The server drops Eio too, for `Unix.select`.** It is an I/O
multiplexer: select over MCP stdin and each worker's response descriptor,
timeout set to the earliest pending deadline. Single-threaded, no runtime,
and still responsive while a session is stuck. Dependencies reduce to
`unix`, `jsonrpc` and `yojson`.

**The worker is bytecode.** utop has no native archive, so the worker is
built `byte_complete`. The server stays native.

## Consequences to propagate

- `lib/proto.ml` and its tests are deleted. The `-emacs` line codec,
  sentinel and terminator handling have no remaining caller.
- Spawning `opam exec -- utop` is obsolete. The worker links utop at build
  time, so there is no runtime binary lookup and no PATH problem.
- The hermetic spawn flags become our own settings rather than argv:
  `Clflags.real_paths := false` for short paths, not loading an init file,
  and `UTop.set_create_implicits` for implicit bindings.
- Stdin theft is designed out. The worker points fd 0 at `/dev/null` and
  keeps its IPC on a separate descriptor.

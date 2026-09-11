---
status: closed
type: grilling
blocked-by: []
assignee: lyh
---

# Architecture baseline

## Question

What shape does this server have? Process model, session model,
concurrency, and how a request is framed against a stream that has no
end-of-output marker.

## Resolution

**Drive stock utop as a child process over its `-emacs` protocol.** The
protocol is complete and stable: the client sends `input:<flags>` then one
`data:` line per input line then `end:`, and utop answers `prompt:`,
`accept:<locs>`, `continue:`, `stdout:<line>`, `stderr:<line>`. Also
available: `complete-company:`, `require:<pkg>`, `input-multi:`, `exit:`.
Verified working unmodified against opam utop 2.16.0. Rejected linking
utop as a library, which couples to unstable internals and lets a toplevel
crash take the server down.

**opam's utop announces `protocol-version:1` on startup**; the reference
checkout does not emit this line. Build against opam.

**A phrase must carry the terminator.** `end:` delimits the transmission,
not the phrase. Input not ending in `;;` gets `continue:`, meaning utop
wants more. utop announces its own terminator as `phrase-terminator:;;` at
startup, so read it rather than hardcoding it.

**Frame output with a sentinel, not with `prompt:`.** utop copies the
toplevel's stdout through an internal pipe read by a separate thread that
is scheduled only when the main thread blocks. Feeding commands back to
back starved it entirely and every result arrived at exit; pacing them put
results in the right place but always *after* the following `prompt:`.
There is no in-band end-of-output signal. So: send the phrase, then send
`let () = Stdlib.print_endline "@@utop-mcp:<id>@@";;` and read stdout until
that marker. It yields exactly one line and no `- : unit = ()` to strip.
Costs one extra round trip per eval.

**Fully qualify the sentinel.** A bare `print_endline` is shadowed by any
`open` of a module defining one; the marker then never appears and the
framing loop hangs forever. Confirmed by experiment. `Stdlib.print_endline`
survives.

**Evaluated code that reads stdin poisons the session, and that is
unsupported.** utop's emacs mode redirects stdout and stderr but leaves
stdin alone, so the toplevel's `Stdlib.stdin` and the protocol reader are
two buffers over one file descriptor. A phrase containing `read_line ()`
consumed the next protocol command and bound the result to the literal
string `"input:"`. Confirmed by experiment; the desync is unrecoverable.
Every eval therefore carries a deadline, and a missing sentinel means the
session is poisoned: kill the child and return an error naming stdin as
the likely cause. State is lost. Rejected replaying phrase history to
rebuild state, which has its own side effects and can diverge.

**Named multiple sessions**, each owning its own child process.

**Eio for concurrency and cancellation.** Chosen over a thread per session
and over full serialization. Structured cancellation is what the deadline
design needs anyway, and this is the OCaml 5 story. The cost is a large
dependency for a server this size.

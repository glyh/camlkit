---
status: closed
type: decision
blocked-by: []
assignee: lyh
---

# Stopping inside a running phrase

## Question

[Toplevel directives are not part of the tool surface](029-directives-are-not-the-surface.md)
left `#trace` in the fog as the one capability given up rather than
duplicated. The question behind it is bigger than tracing: can an agent stop
inside running code, look at what is there, and carry on. A debugger is the
obvious answer, so the debuggers were measured before anything was designed.

## Measured

**`#trace` is narrower than it looks.** Recursion defined in a session traces
fully, calls made through a name defined earlier are traced too because the
toplevel patches the global slot, and a raise is reported as `boom raises
Failure "nope"`. Against that: a polymorphic function prints its arguments as
`<poly>`, currying costs a line per argument, and a compiled unit's internal
calls never route through the traced name, so tracing the standard library's
`map` showed one entry and one exit for a three element list and none of its
recursion. It shows the boundary, never the interior.

**ocamldebug works and cannot evaluate.** Driven in batch on a bytecode
program built with `-g`: breakpoints hit, locals printed with real types,
`backstep` moved execution backwards through its fork checkpoints. Then
`print sum 0 xs` answered `Syntax error.` Its expression grammar is
identifiers, field access, indexing and dereference. It inspects values and
cannot apply a function.

**earlybird is a reimplementation, and currently offers less.** The string
"ocamldebug" appears nowhere in its source; it speaks the runtime's debug
socket itself, with the same single-character commands the compiler's own
client uses. It registers no evaluate command at all, and its declared
capabilities omit stepping backwards. Version 1.3.6 on OCaml 5.4.0 never
completed a handshake here: over TCP its log showed the request parsed and the
response written and flushed, while a client holding the socket open for
twenty seconds received nothing; over stdio it never logged reading the
message. Both transports, reproducible.

**The protocol can never run code.** The request set in
`runtime/caml/debugger.h` is twenty commands: set an event or a breakpoint,
control execution, walk frames, read a header, a field, a local, a global, the
accumulator, and marshal a value out. There is no write, no set-pc, no call.
The interpreter's event and break instructions call the debugger function
directly, which does socket I/O, so there is no in-process hook to borrow
either.

**Effects already do what we actually wanted.** Measured in a live session,
with no change to this project: a phrase performed an effect mid-function, the
handler kept the continuation and returned to the prompt, the locals were
ordinary values in the session, arbitrary code ran against them across two
further calls, and the phrase then resumed and finished. A stopped debuggee is
frozen; a parked phrase leaves the session fully alive.

## Decided

**A breakpoint here is an effect handler around a phrase, not a debugger.**
The evaluator performs an effect at the stop, the handler stores the
continuation, and evaluation returns to the request loop. The worker's
sequential loop is untouched: the suspended phrase is a value, not a blocked
channel read, so nothing about supervision or the deadline has to change.
Locals are in scope by construction because we compile the code that performs
the effect, so nothing is copied, mutation is visible, identity holds, and the
session's own printers render everything, including a project's.

**Four limits, each measured rather than assumed.** A prebuilt dependency
cannot be instrumented, so no breakpoint reaches inside one. A caller's locals
are not reachable: the continuation is not a stack walk, and
`Printexc.get_callstack` gives the chain without the values. Continuations are
one-shot, so there is no going back; only forking the worker would give that.
And an effect does not cross a frame the runtime entered: performing one from
a signal handler raised `Unhandled` even with the handler installed in the
enclosing scope.

**Debugger integration is declined.** Not because it is redundant, because it
is a different tool that already exists. What it adds over the effect design
is exactly the four limits above, and the only mechanism that would deliver
them is the out-of-process protocol, which cannot evaluate. Anyone wanting
ocamldebug-grade stepping on their project is one `ocamlc -g` away from it,
and a DAP route exists in principle through earlybird and a generic MCP bridge
without anything here.

**Patching the runtime is declined, and the patch was specified anyway.** The
minimal one is not an eval request: it is letting an OCaml closure be called
at a stop instead of entering the socket loop, after which the whole debugger
is in-process and evaluation is native. It is a small patch with large
leverage, and it is still a compiler fork. Bytecode is version-locked to the
switch, so a patched runtime means the user's whole switch, tracked against
upstream forever. Upstreaming that hook is the only sane version, and it is an
RFC, not a weekend. Recorded so the next person does not rediscover the idea
and mistake it for cheap.

**Marshalling values out was considered and is not the shape.** A stopped
debuggee will marshal any value on request, closures flag included, sending a
deliberately bad magic number when marshalling raises. A controller that is
itself a toplevel could unmarshal into a live environment, which would delete
earlybird's largest layer, a value reader per shape. It is still a copy, it
loses identity and write-back, closures only survive where the same code runs,
and channels and mutexes refuse outright. Worth knowing if the out-of-process
route is ever reopened; not worth building instead of the effect handler.

**Nothing is built.** No tool is added for this. The decision is what a
breakpoint would be if one is ever wanted, and that the debuggers are not it.

## Noted separately

Sessions report worse backtraces than the stock toplevel. An exception in a
session says "Called from unknown location", where `ocaml` says
`Called from <unknown> in file "//toplevel//", line 1, characters 12-20`. The
cause is that the worker never sets `Clflags.debug`, so phrases compile
without debug events. Setting it at worker init, with
`Printexc.record_backtrace`, produced
`Called from _0 in file "//toplevel//", line 1, characters 12-20` for session
code. Reverted rather than committed here, because it is a change to what
every session reports and belongs in its own ticket, but it is two lines and
the positions land inside the code the caller sent.

---
status: open
type: research
blocked-by: [033, 035]
assignee:
---

# Stopping where it raised

## Question

A phrase that raises is over. [A raise in a phrase had no
position](034-locating-a-raise.md) made the failure say where it happened, and
that is all a caller gets: a name, a message and a span, read after every
frame is gone. The values that produced the raise are not in the answer and
cannot be asked for, because there is nothing left to ask. The agent's next
move is to rewrite the phrase with a `[%break]` above the line that failed and
run it again, which only works when the failure is deterministic and when the
raise was in code the agent typed.

The proposal is that an uncaught exception parks the phrase the way
`[%break]` parks it: locals in scope at the raise reported as fields, the
session still usable, the continuation held in the table.

## Why it is nearly free here

[Stopping inside a running phrase](033-breakpoints-are-an-effect.md) put an
effect handler around every phrase and
[Breakpoints in a session](035-breakpoints.md) built the typed-tree rewrite
that harvests locals and binds them under `bp_` names. Both are paid for. What
an uncaught exception needs is the same harvest at a different trigger, and
the trigger is the cheaper of the two: `[%break]` had to be written by the
caller and typechecked, whereas a raise arrives on its own.

The hard part is not the handler, it is that an OCaml exception unwinds. By
the time the phrase's `try` sees it the frames that held the locals are gone,
which is exactly what an effect does not do. So the honest version of this is
not "catch at the top" but "rewrite every raise site", or rewrite the sites the
caller names, which is the same machinery 035 already applies to `[%break]`
markers pointing at a different set of nodes.

## Prior art

SBCL, and Common Lisp generally. A condition is signalled before the stack
unwinds, the debugger runs on top of the frame that signalled, and the
available restarts are computed from handlers established further down. The
caller picks one and execution continues from the signalling point: retry the
operation, return a value from this frame, use a different value for the
variable that was unbound. `sb-debug` exposes the frame's locals, and slynk
reaches them as `frame-locals-and-catch-tags`, `inspect-frame-var`,
`eval-string-in-frame` and `sly-db-return-from-frame`.

What transfers is the trigger and the locals. What does not is the restart
menu: a restart is a named continuation a library author established
deliberately, and OCaml libraries establish none, so there would be exactly
one restart on offer and it would be "abort". `continue` already is that.

## Open

**Whether the rewrite is affordable.** 035's rewrite runs on the phrase the
caller typed, at the markers the caller wrote, which is a handful of nodes.
Wrapping every raise site, or every application that might raise, is every
node. The cost has to be measured before this is more than an idea, and if it
is only affordable at named sites then the caller is naming sites again, which
is `[%break]` with extra steps.

**What a parked raise means for the value.** A `[%break]` parks a phrase that
will continue and produce something. A raise parks a phrase that has already
decided it will not. `continue` on it either re-raises, which makes the park a
read-only look at the corpse, or it would need a value to substitute, which is
CL's `use-value` restart and needs a type the caller cannot generally supply.
Re-raising is the lazy answer and probably the right one.

**Against the whole thing.** An agent can wrap the phrase in its own handler
and print what it wants. That costs a round trip and requires knowing what to
print, which is the thing it does not know. This buys the case where the
failure is a surprise.

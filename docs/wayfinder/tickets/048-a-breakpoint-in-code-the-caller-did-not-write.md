---
status: open
type: research
blocked-by: [035]
assignee:
---

# A breakpoint in code the caller did not write

## Question

[Breakpoints in a session](035-breakpoints.md) decided that the caller writes
the stop, and deleted the whole position-resolution layer on the strength of
one sentence: "the agent writes the phrase, so asking it to type a marker
where it wants to stop costs nothing."

That is true of a phrase and false of a project. After `load`, a session holds
libraries the agent did not type and cannot edit into. The interesting failure
is nearly always a few frames down, inside a function in `lib/` that the
phrase merely called, and there is no way to put a marker there. The agent's
only route is to copy the function's body into a phrase, paste a marker into
the copy, and debug the copy - which is a different function, compiled in a
different environment, closing over different values.

The proposal is a breakpoint addressed by `file` and `line` rather than by an
edit: the same park, the same `bp_` locals, on a node the caller points at
instead of one it rewrote.

## Prior art

Pharo's Reflectivity. A `MetaLink` is installed on an AST node of an
already-compiled method and removed again; the source file is never touched.
The link carries a position on the node - `before`, `instead`, `after`,
`onError` - a metaobject and a selector to send it, and an optional condition.
`ReflectiveMethod` holds the annotated tree and the compiled twin is
regenerated on the fly, so installing and uninstalling a breakpoint is not a
source edit and leaves nothing behind. `DebugPointNodeTarget` is the
breakpoint-shaped use of it.

SBCL reaches the same end differently and less well: `trace` with `:break`
stops at a function's boundary, not at a line inside it, which is the
distinction [Stopping inside a running phrase](033-breakpoints-are-an-effect.md)
already drew against `#trace`.

## What it would cost here

Resolution, which 035 deleted on purpose. A `file` and `line` has to become a
typed-tree node, and the tree that matters belongs to a module already
compiled and loaded, not to the phrase being evaluated. Either the module is
recompiled from source with the marker injected, which means the session's
existing values of its types are from the old module and will not match, or
the node is reached without recompiling, which the bytecode toplevel gives no
obvious handle on.

`outline` already turns a file into ranges, so the position half of the
problem has a tool. The module-identity half is the one that decides whether
this is possible at all, and nothing in the record answers it yet.

## Open

**Whether recompiling the module is acceptable.** It is the obvious
implementation and it silently invalidates every existing value of that
module's types. A session that has to be reset to place a breakpoint is a
session where the breakpoint is placed before the interesting state exists,
which is most of the value gone.

**Whether this is a `load` question rather than a breakpoint question.** If a
project's modules were loaded from source under the session's own compilation
rather than from `_build` archives, marker injection would be a compile-time
rewrite of code the worker compiles, which is 035's machinery unchanged.
That is a large change to `load` for one feature, and
[Loading a dune project's own libraries](021-dune-aware-load.md) chose
archives for reasons that still hold.

**Against the whole thing.** 035's argument is not wrong, only narrower than
it claimed. If the measured answer is that an agent overwhelmingly debugs
phrases it wrote and not libraries it loaded, this stays closed and the record
says why on better evidence than the original sentence.

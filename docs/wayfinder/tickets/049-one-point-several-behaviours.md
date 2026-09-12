---
status: open
type: research
blocked-by: [035]
assignee:
---

# One point, several behaviours

## Question

The record is accumulating one tool per way of watching a phrase.
[Breakpoints in a session](035-breakpoints.md) built the stop. The map's
survey of the conversational-dev clients proposes stickers, from
`sly-stickers`, as a second thing: a site that records every value that flows
through it and never stops. Both want the same typed-tree rewrite, the same
locals harvest, the same site addressing, and differ only in what happens when
the site is reached.

The proposal is to build the site once and make the reaction a list, rather
than ship `break` and `sticker` as two tools that share their implementation
and nothing else.

## Prior art

Pharo's `DebugPoints` package, which is this refactoring already performed on
a system that had grown breakpoints, watchpoints and conditional breakpoints
separately. A `DebugPoint` is a **target** crossed with a list of
**behaviours**. Targets are an AST node, a class and method, an instance
variable slot, or one specific object. Behaviours are `ConditionBehavior`,
`CountBehavior`, `OnceBehavior`, `ChainBehavior`, `ScriptBehavior`,
`TranscriptBehavior`, and `WatchDebugPoint`'s value history. The behaviours
split into checks, which decide whether the point counts as hit, and side
effects, which run if it did - so the count only advances on hits that passed
the predicate, which is the composition a separate conditional-breakpoint
feature has to reimplement.

Pharo's watch behaviour is sly's sticker, reached independently and from the
other direction. sly grew a sticker beside a breakpoint; Pharo had both and
factored them. That two systems converged on the same pair, and only one of
them on the same mechanism, is the argument.

Two behaviours here have no counterpart in anything else surveyed.
`ChainBehavior` arms the next point only once the current one has fired,
which is how a caller stops on the second path through a function rather than
the first. `OnceBehavior` disables the point after one hit, which is the
common case and currently would be a condition the caller has to write and a
reset it has to remember.

## What it would look like here

`[%break]` is already an extension point, and an extension point already takes
a payload. `[%break]` stays the stop, and the behaviours are attributes on it
rather than new markers - which keeps the surface at one marker and does not
add a tool per behaviour. A watch is then the marker that records and does not
park, and the cutoff the map already proposes for stickers, recording only
when the value differs while still counting every hit, is a behaviour in the
check list rather than a special case of a separate feature.

## Open

**Whether more than one behaviour is ever asked for.** This is a factoring
argument, and a factoring argument for code that does not exist is
speculation. The lazy reading is that stickers should be built as a second
marker, and only if a third arrives should the list appear. The reading
against it is that the second is the cheap moment to factor and the third is
not.

**What the payload is.** An attribute on an extension point has to parse and
typecheck, and a condition is an expression in the scope at the marker, which
is exactly the scope 035 already harvests. A count is a literal. A script is
an expression evaluated for its effect. None of these is new machinery, but
the syntax is a decision and there is no obvious precedent in OCaml to copy.

**Against the whole thing.** Nothing here is asked for by a caller yet. The
map's sticker entry is open on "whether an agent wants this", and this ticket
is open on the same question one level up.

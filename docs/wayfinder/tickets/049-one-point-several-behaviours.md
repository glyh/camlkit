---
status: resolved
type: research
blocked-by: [035]
assignee: lyh
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

## Decided

Grilled through, September 2026. The factoring this ticket proposed is
**declined**, and the sticker it was factoring for is **accepted**.

**Two markers, not one point with a behaviour list.** `[%break "name"]` and
`[%watch "name" expr]`. The premise that both want the same typed-tree rewrite
turned out to be half true: a break *replaces* an expression in unit position
and types as `unit`, while a watch must *wrap* a subexpression and give back its
value, so it is `'a -> 'a`. What they genuinely share is the site addressing and
the location-matching typed-tree walk, where a break takes `exp_env` at the node
and a watch takes `exp_type`. That is fifteen lines, not an abstraction.

**Every marker is named, and a bare `[%break]` becomes a compile error.** This
is a breaking change to [Breakpoints in a session](035-breakpoints.md) and to
every example in it and in
[Stopping inside a running phrase](033-breakpoints-are-an-effect.md). Taken
deliberately: a name is what makes a marker disarmable, and without one the
uniformity has a hole exactly where the trap is.

**A site lives as long as the definition holding it, which is what breakpoints
already do.** Measured rather than assumed:

    let f x = let doubled = x * 2 in [%break]; doubled;;   val f : int -> int
    f 21;;   Stopped at [%break] in phrase 1, id 1
    f 5;;    Stopped at [%break] in phrase 1, id 2

The marker compiles into the function body, so the server has nothing to delete
and a single-call lifetime is not available to choose. A fresh park id is issued
per hit, so a name identifies the site and an id identifies one hit of it.

**Destroying a marker means disarming it,** a flag the compiled hook consults,
not code removal. This closes a gap that predates stickers: nothing today stops
a breakpoint firing short of redefining its function, so a marker in a hot
function is a trap.

**An eval result carries this call's recordings; `inspect` carries the full
trail.** The hit count is the site's lifetime total, because "this has fired
4000 times" is what a caller wants before reading any values. Accumulating the
values in the result would need a cap and an eviction rule, and a value from
three calls ago is context nobody asked for.

**A new tool, `markers`, lists and disarms.** It answers what markers exist,
whether each is armed and how often it has fired, and disarms by name. Listing
is the half a caller needs before disarming, and neither belongs on `eval`,
which requires code to run, nor on `inspect`, which exists because looking is
not resuming and by the same reasoning is not disarming.

**Values are printed by the worker after the phrase,** with
`Toploop.print_value : Env.t -> Obj.t -> formatter -> Types.type_expr -> unit`.
The type and environment are stashed at typecheck time from the site's typed
node; the hook stores only `Obj.repr v`. This is the locals harvest's trick
without its temporary bindings.

## Open

**What a recording table costs.** Holding `Obj.repr v` keeps every recorded
value alive, so a watch in a hot loop is a leak with a printer attached. The
cutoff the map proposes - record only when the value differs from the last,
while counting every hit - bounds it by distinct consecutive values rather than
by iterations, and a hard cap is still needed above that.

**A value printed after the fact may have changed.** The table holds the value,
not a copy, so a mutable one reads as it is at print time rather than at record
time. Printing at record time would mean generating printing code in the phrase,
which is the machinery this design avoids.

**What Pharo's other behaviours would cost here.** `ChainBehavior` and
`OnceBehavior` have no counterpart on this surface and are not built. `once` is
the common case and is currently a condition the caller writes plus a disarm it
remembers - which the `markers` tool at least makes possible.

## Built

`[%break "name"]` and `[%watch "name" expr]`, a registry both share, and the
`markers` tool. Checked end to end in the server suite by "a watch records
without stopping" and "markers list and disarm".

What the two share turned out to be the registry, the naming, the disarm flag
and a location-matching walk over the typed tree. That is fifteen lines, which
is the measurement this ticket's factoring argument needed and did not have.

The pieces that only a watch needed: a wrapping rewrite that binds the value
once and returns it, a type stashed from the site's typed node, and printing
through `Toploop.print_value` when the result is built rather than in generated
code. A phrase that failed to type therefore reports a count and no values,
rather than guessing at a printer.

The cutoff works as the map predicted: a loop recording the same value five
times keeps one entry and counts five hits. Above that a fixed cap of 100
bounds each site's trail.

Two windows, both used: an eval result carries what its own phrase recorded,
`inspect` carries the whole trail, and `inspect` no longer requires a parked
phrase when there is something watched.

## Fixed afterwards

**A name, and the sites written under it.** Two watches sharing a name shared
one stored type, so one site's ints were printed with the other's string type
and the worker died.

The first fix refused a reused name whose watched type differed, comparing with
`Ctype.is_equal`. It refused ordinary work. Types are recorded while a call is
typechecked, before it runs, and typing and running each define a call's types
afresh, so a watch on a type defined in the same call held a type the session
never had: redefining that function later, or re-sending the chunk after an
edit, was refused with the type unchanged. Re-sending `type t` is a new type in
plain OCaml too, so even a correct comparison refuses the edit loop.

Built instead: every place a watch is written is a site with an id, and the
rewritten code records by id. Each site keeps its own type, where it is written
(the enclosing definition, its line in the call, the watched text) and its own
trail, so a value is always printed with the type it was recorded under and
nothing is compared. A name groups its sites for counting and disarming, and
`markers` arms or disarms one site by id. A breakpoint name written again is
accepted with a warning, since every stop of it then reports and disarms as
one. One name for both kinds is still refused: disarming the name would turn off
the other kind with it. Markers are registered once a call is going to run, so a
failed or checked call leaves nothing in `markers`.

Every re-evaluation adds a site, and nothing can tell whether code holding an
older one is still reachable, so nothing guesses. A watch added under a name
that already has sites comes back with a warning naming the new site and the
others, and the caller disarms what it knows to be dead. Replacing a site
automatically when its definition is sent again was considered and rejected:
a closure kept from before the redefinition still fires, and a rule that hides
it is a rule the caller has to learn and can be wrong about.

**The cutoff was one slot shared too widely.** It compared against a single
last value across calls and sites, so a call repeating the previous call's
final value reported nothing. Each list now compares against its own head. And
since that comparison is physical, a loop recomputing an equal string stored it
every time; equal consecutive printings are collapsed when the result is built.

